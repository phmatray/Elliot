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
#   FAKE_CLAUDE_MODE       hang  = emit nothing, sleep forever
#                          trap  = trap SIGTERM, sleep, exit 143 like Claude Code
#                          crash = write to stderr and exit non-zero
#   FAKE_CLAUDE_ARGV_OUT   file to dump argv into, one argument per line
#   FAKE_CLAUDE_STDERR     text to emit on stderr

set -u

if [ -n "${FAKE_CLAUDE_ARGV_OUT:-}" ]; then
  : >"$FAKE_CLAUDE_ARGV_OUT"
  for arg in "$@"; do printf '%s\n' "$arg" >>"$FAKE_CLAUDE_ARGV_OUT"; done
fi

if [ -n "${FAKE_CLAUDE_STDERR:-}" ]; then
  printf '%s\n' "$FAKE_CLAUDE_STDERR" >&2
fi

case "${FAKE_CLAUDE_MODE:-replay}" in
  hang)
    while true; do sleep 1; done
    ;;
  trap)
    # Claude Code exits 143 on SIGTERM after shutting down its own children.
    terminated() { exit 143; }
    trap terminated TERM INT
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
