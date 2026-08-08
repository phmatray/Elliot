#!/bin/bash
# A stand-in for the `claude` binary, driven entirely by environment variables.
#
# This is the seam the runner is tested through: it replays a recorded NDJSON
# stream at a controlled pace, and can be told to hang or to trap signals, so
# the idle timeout and the cancellation ladder are exercised without spending
# minutes or tokens on a real agent run.
#
#   FAKE_CLAUDE_FIXTURE    path to an .ndjson file to replay line by line
#   FAKE_CLAUDE_DELAY_MS   milliseconds to wait between lines (default 0)
#   FAKE_CLAUDE_EXIT       exit code (default 0)
#   FAKE_CLAUDE_MODE       hang  = emit nothing and sleep until signalled
#                          trap  = same; kept as a separate name because the
#                                  tests read as documentation of intent
#                          crash = write to stderr and exit non-zero
#   FAKE_CLAUDE_ARGV_OUT   file to dump argv into, one argument per line
#   FAKE_CLAUDE_SPAWN_LOG  file to APPEND one line to per invocation — the first
#                          line of the -p prompt. The lossless counter for "how
#                          many children were actually started". ARGV_OUT cannot
#                          serve: it truncates, so two spawns look like one, and
#                          counting spawns is exactly what a double-spawn test
#                          must do.
#   FAKE_CLAUDE_STDERR     text to emit on stderr
#   FAKE_CLAUDE_READY      file to touch once the trap is installed, so a test
#                          can wait on a fact instead of guessing a duration
#   FAKE_CLAUDE_STORIES    path to a JSON file to drop at the analysis output
#                          path the prompt announces (ELLIOT_OUTPUT=…)
#   FAKE_CLAUDE_TOUCH      path, relative to cwd, to write to — used to prove
#                          the git sentinel notices a run that edits the repo
#   FAKE_CLAUDE_BURST      emit N filler events immediately before the fixture,
#                          so the pipe still holds more than it can carry when
#                          this process exits — the window issue #26 probes
#
# Every mode exits 143 on SIGTERM, as Claude Code documents for its own
# shutdown. `hang` used not to trap at all, which left orphans holding the
# runner's stdout pipe open — see issue #7.

set -u

# Trap before anything else: a SIGTERM arriving during the preamble must not
# leave an orphan holding the runner's stdout pipe open.
terminated() { exit 143; }
trap terminated TERM INT

if [ -n "${FAKE_CLAUDE_ARGV_OUT:-}" ]; then
  : >"$FAKE_CLAUDE_ARGV_OUT"
  for arg in "$@"; do printf '%s\n' "$arg" >>"$FAKE_CLAUDE_ARGV_OUT"; done
fi

# One short line, appended: O_APPEND writes under PIPE_BUF are atomic, so two
# fakes running at once cannot interleave halves of a line. The prompt's first
# line says which run this spawn belongs to.
if [ -n "${FAKE_CLAUDE_SPAWN_LOG:-}" ]; then
  spawn_prompt=""
  spawn_prev=""
  for arg in "$@"; do
    if [ "$spawn_prev" = "-p" ]; then spawn_prompt="$arg"; fi
    spawn_prev="$arg"
  done
  printf '%s\n' "$(printf '%s' "$spawn_prompt" | head -1)" >>"$FAKE_CLAUDE_SPAWN_LOG"
fi

if [ -n "${FAKE_CLAUDE_STDERR:-}" ]; then
  printf '%s\n' "$FAKE_CLAUDE_STDERR" >&2
fi

# Elliot announces the analysis artifact path in the prompt itself, with a
# marker chosen so it can be found in shell as easily as in Swift. Finding it
# here is what makes the whole analysis path testable without a real agent.
#
# Capture to end of line, not to the first whitespace: Elliot's real default
# home is `~/Library/Application Support/Elliot`, and a path that stops at the
# first space is a path that silently loses everything after "Application".
# `AnalysisPromptBuilder.outputPath(in:)` parses the same way — to the
# newline that ends the marker's line, then trims trailing spaces/tabs only
# (never newlines, since there are none left in a single captured line).
if [ -n "${FAKE_CLAUDE_STORIES:-}" ]; then
  prompt=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "-p" ]; then prompt="$arg"; fi
    prev="$arg"
  done
  out="$(printf '%s\n' "$prompt" \
    | sed -n 's/^.*ELLIOT_OUTPUT=\(.*\)$/\1/p' \
    | sed 's/[[:blank:]]*$//' \
    | head -1)"
  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    cp "$FAKE_CLAUDE_STORIES" "$out"
  fi
fi

if [ -n "${FAKE_CLAUDE_TOUCH:-}" ]; then
  printf 'touched by fake-claude\n' >"$FAKE_CLAUDE_TOUCH"
fi

# Observable readiness, so a test can wait on a fact instead of a duration.
if [ -n "${FAKE_CLAUDE_READY:-}" ]; then
  : >"$FAKE_CLAUDE_READY"
fi

case "${FAKE_CLAUDE_MODE:-replay}" in
  hang|trap)
    # Short sleeps: bash runs a trap only between commands, so the sleep
    # interval is the worst-case SIGTERM latency.
    while true; do sleep 0.05; done
    ;;
  crash)
    echo "fake-claude: simulated failure" >&2
    exit "${FAKE_CLAUDE_EXIT:-1}"
    ;;
esac

delay_ms="${FAKE_CLAUDE_DELAY_MS:-0}"
# Formatted with bash's own printf rather than a helper process: anything
# spawned inside the loop below inherits the fixture as its stdin and eats the
# lines that have not been read yet.
delay_s=""
if [ "$delay_ms" -gt 0 ]; then
  printf -v delay_s '%d.%03d' "$((delay_ms / 1000))" "$((delay_ms % 1000))"
fi

# A burst of filler events immediately before the fixture, so that far more is
# still in the pipe than it can hold at the moment this process exits. That is
# the only state in which the streaming reader and the final drain can contend
# for the same descriptor, and the tail at risk is the fixture's own last line —
# the terminal `result` event the whole run is judged by. See issue #26.
#
# `seq -f` and not a loop, and not `seq | sed` either. Both of those were tried
# and neither burst: a bash loop spends 4 000 `printf` round trips, and a pipe
# through `sed` trickles line by line, so in both cases the reader keeps up and
# the pipe is empty again by the time the process exits — which is precisely the
# state where nothing can contend and the test proves nothing. Measured: with
# the historical defect reintroduced, the `sed` form passed and this one fails.
# One process, one burst, written as fast as the kernel will take it.
#
# Placed *outside* the replay loop below, which must keep the fixture as its
# own stdin.
if [ "${FAKE_CLAUDE_BURST:-0}" -gt 0 ]; then
  seq -f '{"type":"assistant","message":{"content":[{"type":"text","text":"burst %.0f"}]}}' \
    1 "$FAKE_CLAUDE_BURST"
fi

if [ -n "${FAKE_CLAUDE_FIXTURE:-}" ] && [ -f "$FAKE_CLAUDE_FIXTURE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    [ -n "$delay_s" ] && sleep "$delay_s" </dev/null
  done <"$FAKE_CLAUDE_FIXTURE"
fi

exit "${FAKE_CLAUDE_EXIT:-0}"
