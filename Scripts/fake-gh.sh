#!/bin/bash
# A stand-in for the `gh` binary, driven entirely by environment variables.
#
# The sibling of `Scripts/fake-claude.sh`, and deliberately the same shape: a
# test points `ToolConfig.ghPath` at this script and the real `ProcessRunner`
# spawn, the real subprocess and the real ISO-8601 `JSONDecoder` all stay under
# test. `gh` is the easier of the two — one shot, JSON on stdout, no streaming.
#
#   FAKE_GH_ISSUES     path to a JSON file printed for `issue list` (default [])
#   FAKE_GH_PRS        path to a JSON file printed for `pr list`    (default [])
#   FAKE_GH_PR_VIEW    path to a JSON file printed for `pr view`    (NO default —
#                      unset or missing exits 65). `gh` answers a list with `[]`
#                      for an empty repository, so an absent list fixture has a
#                      correct stand-in; there is no such thing as an empty
#                      object, so inventing one here would be a decode error
#                      dressed up as a missing fixture
#   FAKE_GH_MODE       ok   = print the fixtures (default)
#                      fail = write to stderr and exit non-zero
#   FAKE_GH_FAIL_REPO  fail only when `--repo` is this exact value, and answer
#                      normally for every other repository. `importAll` shares
#                      one `GHClient` across a pass, so this is the only way to
#                      express "this repository is unreachable and that one is
#                      not" — which is the actual claim #17's criterion 7 makes
#                      and a blanket FAKE_GH_MODE=fail cannot test
#   FAKE_GH_EXIT       exit code used by `fail` (default 1)
#   FAKE_GH_ARGV_OUT   file to dump argv into, one argument per line, so a test
#                      can assert what was actually asked of `gh`
#   FAKE_GH_REPOS      path to a JSON file printed for `repo list` (default [])
#   FAKE_GH_FAIL_OWNER fail only when the owner argument of `repo list` is this
#                      exact value, and answer normally for every other owner.
#                      The sibling of FAKE_GH_FAIL_REPO, one subcommand over:
#                      `RepoRegistryService.rows` shares one `GHClient` across
#                      its fan-out over owners, so this is the only way to state
#                      #148's criterion 5 — one owner's failed listing must not
#                      change what the page says about a healthy one
#
# Anything other than `issue list`, `pr list`, `pr view` or `repo list` exits
# non-zero on purpose: an unexpected call has to fail loudly rather than return
# an empty list, which would look exactly like a repository with no open work.
#
# There is no ready-file and no delay here, and that is not an oversight —
# nothing about this fake is asynchronous, so a test has nothing to wait for.
# `fake-claude.sh` needs `FAKE_CLAUDE_READY` because it stays alive; this one
# prints and exits.

set -u

# Trap before anything else, for the same reason `fake-claude.sh` does: a
# SIGTERM arriving during the preamble must not leave a child holding the
# runner's stdout pipe open. This one is short-lived, so the window is small —
# but "small" is how issue #7 got written, and a wedged child here would hold
# the SwiftPM build lock exactly the same way.
terminated() { exit 143; }
trap terminated TERM INT

if [ -n "${FAKE_GH_ARGV_OUT:-}" ]; then
  for arg in "$@"; do printf '%s\n' "$arg" >>"$FAKE_GH_ARGV_OUT"; done
fi

if [ "${FAKE_GH_MODE:-ok}" = "fail" ]; then
  echo "fake-gh: simulated failure" >&2
  exit "${FAKE_GH_EXIT:-1}"
fi

# Fail for one named repository only. The value is read from the argument after
# `--repo`, which is how `GHClient` always passes it.
if [ -n "${FAKE_GH_FAIL_REPO:-}" ]; then
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--repo" ] && [ "$arg" = "$FAKE_GH_FAIL_REPO" ]; then
      echo "fake-gh: simulated failure for $arg" >&2
      exit "${FAKE_GH_EXIT:-1}"
    fi
    prev="$arg"
  done
fi

# Fail for one named owner only. `GHClient.repos` passes the owner positionally,
# as the argument right after `list`, so that is what is matched — by position
# rather than by flag, because there is no flag to key off.
if [ -n "${FAKE_GH_FAIL_OWNER:-}" ] && [ "${1:-} ${2:-}" = "repo list" ]; then
  if [ "${3:-}" = "$FAKE_GH_FAIL_OWNER" ]; then
    echo "fake-gh: simulated failure for owner $3" >&2
    exit "${FAKE_GH_EXIT:-1}"
  fi
fi

# `gh issue list …` / `gh pr list …` — dispatch on the first two arguments.
# Printing an empty array rather than nothing when no fixture is configured:
# `[]` is what `gh` returns for a repository with no matching items, and it is
# what the decoder expects. Emitting nothing would be a decode error dressed up
# as a missing fixture.
emit() {
  if [ -n "${1:-}" ] && [ -f "$1" ]; then
    cat "$1"
  else
    printf '[]\n'
  fi
}

# `pr view` answers a single object, so it has no empty stand-in — a missing
# fixture is a wiring mistake and says so, with its own exit code so a test can
# tell "you forgot the fixture" from "you called something I do not know" (64).
emit_object() {
  if [ -n "${1:-}" ] && [ -f "$1" ]; then
    cat "$1"
  else
    echo "fake-gh: pr view needs FAKE_GH_PR_VIEW to name a readable file" >&2
    exit 65
  fi
}

case "${1:-} ${2:-}" in
  "issue list") emit "${FAKE_GH_ISSUES:-}" ;;
  "pr list")    emit "${FAKE_GH_PRS:-}" ;;
  "pr view")    emit_object "${FAKE_GH_PR_VIEW:-}" ;;
  "repo list")  emit "${FAKE_GH_REPOS:-}" ;;
  *)
    echo "fake-gh: unexpected invocation: $*" >&2
    exit 64
    ;;
esac

exit 0
