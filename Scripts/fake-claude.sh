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
#   FAKE_CLAUDE_STDERR     text to emit on stderr
#   FAKE_CLAUDE_READY      file to touch once the trap is installed, so a test
#                          can wait on a fact instead of guessing a duration
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

if [ -n "${FAKE_CLAUDE_STDERR:-}" ]; then
  printf '%s\n' "$FAKE_CLAUDE_STDERR" >&2
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

if [ -n "${FAKE_CLAUDE_FIXTURE:-}" ] && [ -f "$FAKE_CLAUDE_FIXTURE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    [ -n "$delay_s" ] && sleep "$delay_s" </dev/null
  done <"$FAKE_CLAUDE_FIXTURE"
fi

exit "${FAKE_CLAUDE_EXIT:-0}"
