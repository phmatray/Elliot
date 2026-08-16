#!/usr/bin/env python3
"""An ACP agent that answers, for tests.

`fake-claude.sh` prints and exits; ACP is a conversation, so this reads JSON-RPC on stdin and
replies. It replays a fixture of `session/update` frames on `session/prompt`, then answers the
prompt request with a stop reason.

Env:
  FAKE_ACP_FIXTURE      JSON array of `update` objects to replay. Required for a useful turn.
  FAKE_ACP_MODE         ok | hang | crash | permission | deaf | deaf-after-fixture  (default: ok)
  FAKE_ACP_READY        path touched once trap-protected
  FAKE_ACP_ARGV_OUT     path to write argv to, one element per line
  FAKE_ACP_STOP_REASON  default: end_turn
  FAKE_ACP_DELAY_MS     pause before every line written                (default: 0, no pause)
  FAKE_ACP_STDERR       text to emit on stderr at start-up
  FAKE_ACP_EXIT_AFTER_REPLY  exit 0 the instant session/prompt is answered
  FAKE_ACP_FORKABLE     the one sessionId session/fork will fork; unset = every fork is refused
  FAKE_ACP_FORK_UNREADABLE  answer session/fork with a result that will not decode (see below)
  FAKE_ACP_FORK_DIES    exit at session/fork without answering it at all (see below)

FAKE_ACP_STDERR is the counterpart of fake-claude.sh's FAKE_CLAUDE_STDERR, and it exists for one
path in particular: MODE=crash exits without a word, so a test asserting that a died-mid-turn run
still carries a *reason* would be asserting on an empty string. This is where a failed `npx`
resolution or a Node stack trace lands for real. Written before the trap and before any stdout, so
it is present however early the double is killed.

FAKE_ACP_EXIT_AFTER_REPLY makes the double flush its `session/prompt` response and exit in the same
breath, instead of looping back to block on stdin until the client closes it. It exists to widen a
window rather than to simulate anything: Elliot writes `elliot/terminal` **after** `waitForExit()`
has returned, so a log writer closed from whichever of "the prompt returned" and "the child exited"
happens first would lose that line. With this set the child is gone before Elliot has written a
byte of its own record, so the ordering is exercised rather than reasoned about.

FAKE_ACP_DELAY_MS is what lets a test reach a client's idle watchdog, and it is the counterpart
of `fake-claude.sh`'s FAKE_CLAUDE_DELAY_MS — the knob `ClaudeRunnerTests.silenceAndRecoveryAlternate`
rides on. A client that announces a silence and then withdraws it can only be exercised by a turn
that genuinely goes quiet and genuinely talks again, and this double otherwise writes its whole
conversation as fast as the pipe takes it. ⚠️ It is a pause per *line*, not a total: the gaps are
what a test needs, so the pause is what is configured, and no test may assert on how long the run
took.


MODE=permission genuinely gates on the client's answer: it fires `session/request_permission`
and then BLOCKS on stdin for the matching response before doing anything else — a double that
fired the request and replayed the fixture regardless would test nothing about the answering
path. `allow` replays the fixture and answers with FAKE_ACP_STOP_REASON, same as MODE=ok;
anything else (`deny`, `cancelled`, an error reply) skips the fixture entirely and answers
`stopReason: "refusal"` — a double that behaved identically either way could not test a client's
refusal path, which is the only reason this mode exists. If the client's stdin feed closes before
an answer arrives, the permission request (and the `session/prompt` it came from) is simply never
answered: a genuine hang, the same shape as MODE=hang, so a client's own timeout is what is
actually under test rather than a canned delay. This double answers one outstanding request at a
time; anything else received while waiting for that one answer is dropped rather than queued or
handled — and the drop is announced on stderr (never stdout, which stays clean JSON-RPC), naming
what was dropped and which id it was waiting for, so a client that sends a second request mid-wait
sees a diagnosable line instead of silence.

MODE=deaf answers the handshake normally, never answers `session/prompt` — and, the point,
**does not exit when its stdin closes**: it blocks on a sleep instead of returning from the main
loop. MODE=hang cannot stand in for it, and the difference is the whole reason this mode exists.
`read_message` returns None on EOF and the main loop `break`s, so under MODE=hang closing stdin ends
this double on its own — which means a test asserting "the child is gone after a cancel" passes with
the SIGTERM→SIGKILL backstop deleted, because the kill was never needed. Under MODE=deaf nothing but
that backstop ends it. The SIGTERM trap is installed before any of this, exactly as it is for every
other mode, so the escalation's first rung is enough and no child outlives the suite.

MODE=deaf-after-fixture replays the fixture and *then* goes deaf: every `session/update` frame is
written and `session/prompt` is never answered. Neither of the two modes above can stand in for it,
and the gap is the reason it exists. MODE=deaf returns *before* `for update in fixture()`, so a
client whose behaviour is driven by a frame — the spend brake, which can only fire on a
`usage_update` reporting a cost — has nothing to fire on under it. MODE=ok does emit the frame, but
replies to `session/prompt` in the same breath, so whatever the client does in response is racing
that client's own teardown: measured, a `session/cancel` sent from Elliot's brake under MODE=ok
reached this double in 2 of 15 runs. The reason is that answering the prompt lets Elliot's turn task
close this double's stdin (its `session.end()` → transport `close()`), so the brake's notification is
written into a pipe that has already gone and the write fails — instrumented at Elliot's send site,
19 of 20 MODE=ok samples threw `stdinClosed` while this process was still very much alive. (It is
NOT Elliot standing its own cancel deadline down, which is what this paragraph used to say: measured
at the same site, that task was not even cancelled in 19 of those 20 samples.) Here the frame lands
and the turn stays open, so stdin stays open, the only thing that can end the turn is the client,
and what the client did is observable rather than intermittent.

⚠️ Unlike MODE=deaf this one DOES take the EOF exit in the main loop. Nothing that uses it tests a
SIGTERM backstop, so sleeping through stdin closing would only give this double a way to outlive a
wedged test — the property MODE=deaf holds deliberately is a liability here rather than a stricter
version of the same thing.

`session/cancel` stays a no-op — it is a notification and there is nothing to answer — but its
arrival is announced on stderr, the same way a dropped message is: this double's protocol behaviour
is unchanged, and a client that believes it sent one can tell whether it did. ⚠️ That announcement
is the *receipt*, not the effect: this double never lets a `session/cancel` end a turn, so nothing
here covers an agent answering its in-flight requests and coming back with `stopReason: cancelled`.
A test wanting that stop reason asks for it with FAKE_ACP_STOP_REASON, which exercises the plumbing
and not the agent.

`session/prompt` is refused (a JSON-RPC error, never an empty-looking success) for any
`sessionId` that was never returned by a `session/new` on this connection — including one sent
before `session/new` has happened at all. A plausible success here would hide a client bug behind
a turn that looks like it worked, the same instinct as `fake-gh.sh` exiting 64 on an unexpected
subcommand rather than returning an empty list.

`session/fork` follows that same discipline: it forks exactly one session id, the one named by
FAKE_ACP_FORKABLE, and answers a JSON-RPC error for anything else — which, with the variable
unset, is every fork. The fork returns a session id DIFFERENT from `session/new`'s
(FORK_SESSION_ID below), because a double that handed back the same string could not tell a client
that adopted the fork's answer from one that quietly opened a new session instead. Its arrival is
announced on stderr, exactly as `session/cancel`'s is and for the same reason: without a receipt, a
client that never called it and one that called it and was refused look identical from the outside.

⚠️ **The refusal here is measured; the successful reply's payload is this double's own invention.**
`Scripts/probe/acp_fork.py` drove the real adapter (@agentclientprotocol/claude-agent-acp 0.66.0) on
2026-08-16, and what it saw was: a fork of a live session returns a **new** session id, and a turn on
it carries the parent's context (a nonce planted in the parent turn came back from the fork). A fork
of a well-formed session id that never existed answers **`-32002 "Resource not found: <uuid>"`**,
which is the code this double uses for the same case. A fork of a *junk* string answers something
else entirely — `-32603 Internal error`, whose details read `--resume requires a valid session ID …
is not a UUID` — i.e. argument validation, not a missing session; this double does not model that
second shape, because every id Elliot forks from is one an agent issued.

FAKE_ACP_FORK_UNREADABLE and FAKE_ACP_FORK_DIES exist to drive the two ways a fork can fail
WITHOUT the agent having answered, which is the distinction the runner narrows on. UNREADABLE
answers `result: {}` — successful-looking, undecodable — so the client throws a bare
`DecodingError`; DIES exits without answering, so the client's pending request is failed with
`ClientError.connectionClosed`. Neither is `ClientError.agentError`, so neither may set
`sessionResumeFailed`, and between them they cover both sides of `AgentRun.isForkRefusal`'s type
test: an error that is not a `ClientError` at all, and one that is a `ClientError` of the wrong
case. That second one had no double until the narrowing was found to be unpinned.

⛔ What is still invented is the **successful** reply's body: the real adapter's fork response was
not recorded field by field, so `modes`/`configOptions` below are copied from this file's own
`session/new` rather than from a recording. Tests riding on it can therefore claim things about
*Elliot's* side — that a fork is what a resumed run asks for, that the id it answers with is the one
adopted, and that a refusal ends the run instead of silently opening a fresh session — and nothing
about the adapter's payload. Same posture as `session/cancel` above, which exercises the plumbing
and not the agent.
"""
import json
import os
import signal
import sys
import time

MODE = os.environ.get("FAKE_ACP_MODE", "ok")
STOP_REASON = os.environ.get("FAKE_ACP_STOP_REASON", "end_turn")
DELAY_MS = int(os.environ.get("FAKE_ACP_DELAY_MS", "0"))
EXIT_AFTER_REPLY = bool(os.environ.get("FAKE_ACP_EXIT_AFTER_REPLY"))
FORKABLE = os.environ.get("FAKE_ACP_FORKABLE")
FORK_UNREADABLE = bool(os.environ.get("FAKE_ACP_FORK_UNREADABLE"))
FORK_DIES = bool(os.environ.get("FAKE_ACP_FORK_DIES"))
SESSION_ID = "sess-fake-0001"
# Deliberately not SESSION_ID: see the module docstring — the same string back would make a client
# that adopted the fork's answer indistinguishable from one that opened a new session instead.
FORK_SESSION_ID = "sess-fake-fork-0002"

# Before the trap and before a single byte of stdout: a crash reason that arrives only if the
# double survives long enough to write it is not a crash reason.
if stderr_text := os.environ.get("FAKE_ACP_STDERR"):
    print(stderr_text, file=sys.stderr, flush=True)

# Trap first, before anything else can fail: a child that outlives its parent holding the
# runner's stdout pipe open is how a test suite stops terminating.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))

if path := os.environ.get("FAKE_ACP_ARGV_OUT"):
    with open(path, "w") as fh:
        fh.write("\n".join(sys.argv[1:]))

if path := os.environ.get("FAKE_ACP_READY"):
    open(path, "w").close()


def write(message):
    # Before the write, not after: what a client's watchdog measures is the gap since the last
    # byte it saw, so the pause has to be on this side of the flush to become one. Zero by
    # default, which is every other test in the tree — this costs them a comparison.
    if DELAY_MS:
        time.sleep(DELAY_MS / 1000)
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply(request_id, result):
    write({"jsonrpc": "2.0", "id": request_id, "result": result})


def respond_error(request_id, code, message):
    write({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def notify(update):
    write({"jsonrpc": "2.0", "method": "session/update",
           "params": {"sessionId": SESSION_ID, "update": update}})


def fixture():
    path = os.environ.get("FAKE_ACP_FIXTURE")
    if not path:
        return []
    with open(path) as fh:
        return json.load(fh)


# Shapes below are copied from Fixtures/acp/session-new-commands.json — the real adapter
# (@agentclientprotocol/claude-agent-acp 0.66.0), recorded 2026-08-12 — rather than invented.
# Everything is Optional in ACPModel, so a thinner double never fails to decode; the risk a thin
# double hides is a client that only ever meets an unfamiliar field for real. Only the identifying
# strings (agentInfo, sessionId) are this double's own; the nesting, keys and the vendor-specific
# top-level `_meta` are the real shape verbatim. Refresh these literals if that recording is
# regenerated.
AGENT_CAPABILITIES = {
    "_meta": {"claudeCode": {"promptQueueing": True}},
    "promptCapabilities": {"image": True, "embeddedContext": True},
    "mcpCapabilities": {"http": True, "sse": True},
    "auth": {"logout": {}},
    "providers": {},
    "loadSession": True,
    "sessionCapabilities": {
        "additionalDirectories": {}, "close": {}, "delete": {}, "fork": {}, "list": {}, "resume": {},
    },
}

INITIALIZE_META = {
    "steering": {"supported": True},
    "goal": {"version": 1, "controlMethod": "_session/goal", "actions": ["set", "clear"]},
}

AVAILABLE_MODES = [
    {"id": "auto", "name": "Auto",
     "description": "Use a model classifier to approve/deny permission prompts"},
    {"id": "default", "name": "Manual",
     "description": "Standard behavior, prompts for dangerous operations"},
    {"id": "acceptEdits", "name": "Accept Edits", "description": "Auto-accept file edit operations"},
    {"id": "plan", "name": "Plan Mode", "description": "Planning mode, no actual tool execution"},
    {"id": "dontAsk", "name": "Don't Ask",
     "description": "Don't prompt for permissions, deny if not pre-approved"},
    {"id": "bypassPermissions", "name": "Bypass Permissions", "description": "Bypass all permission checks"},
]

CONFIG_OPTIONS = [
    {
        "id": "mode", "name": "Mode", "description": "Session permission mode", "category": "mode",
        "type": "select", "currentValue": "default",
        "options": [{"value": m["id"], "name": m["name"], "description": m["description"]}
                    for m in AVAILABLE_MODES],
    },
    {
        "id": "model", "name": "Model", "description": "AI model to use", "category": "model",
        "type": "select", "currentValue": "opus[1m]",
        "options": [
            {"value": "default", "name": "Default (recommended)",
             "description": "Opus 5 with 1M context · Best for everyday, complex tasks"},
            {"value": "opus[1m]", "name": "Opus (1M context)",
             "description": "Opus 5 with 1M context · Best for everyday, complex tasks"},
            {"value": "claude-fable-5[1m]", "name": "Fable",
             "description": "Fable 5 · Most capable for your hardest and longest-running tasks"},
            {"value": "sonnet", "name": "Sonnet", "description": "Sonnet 5 · Efficient for routine tasks"},
            {"value": "haiku", "name": "Haiku", "description": "Haiku 4.5 · Fastest for quick answers"},
        ],
    },
    {
        "id": "effort", "name": "Effort", "description": "Available effort levels for this model",
        "category": "thought_level", "type": "select", "currentValue": "xhigh",
        "options": [
            {"value": "default", "name": "Default"},
            {"value": "low", "name": "Low"},
            {"value": "medium", "name": "Medium"},
            {"value": "high", "name": "High"},
            {"value": "xhigh", "name": "Xhigh"},
            {"value": "max", "name": "Max"},
        ],
    },
    {
        "id": "fast", "name": "Fast mode", "description": "Faster responses on supported models",
        "category": "model_config", "type": "select", "currentValue": "off",
        "options": [{"value": "on", "name": "On"}, {"value": "off", "name": "Off"}],
    },
    {
        "id": "agent", "name": "Agent", "description": "Main-thread agent persona",
        "type": "select", "currentValue": "default",
        "options": [
            {"value": "default", "name": "Default", "description": "Standard Claude Code agent"},
            {"value": "stripe:Company Researcher", "name": "stripe:Company Researcher",
             "description": "Research a company from its URL or description to infer Stripe Connect integration shape"},
        ],
    },
]

# sessionId values this connection has actually issued via session/new. session/prompt checks
# against this rather than trusting whatever sessionId a client sends.
known_sessions = set()


def read_message(stdin_iter):
    """Block for the next well-formed JSON-RPC line on stdin. Blank lines are skipped; a
    malformed line gets a parse-error reply and is skipped too. Returns None once stdin closes
    with nothing left to read."""
    for line in stdin_iter:
        line = line.strip()
        if not line:
            continue
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            respond_error(None, -32700, "parse error")
    return None


def is_response(message):
    # A JSON-RPC *response* carries an id and no method; a request or notification carries method.
    return message.get("method") is None and "id" in message


def describe(message):
    """Name a dropped message for the stderr line below — the shape a reader needs to tell a
    stray notification from a request from an answer to the wrong id, without dumping the whole
    frame."""
    method, mid = message.get("method"), message.get("id")
    if method is not None:
        return f"{'notification' if mid is None else 'request'} {method!r} (id={mid!r})"
    return f"response for id={mid!r}"


def wait_for_response(stdin_iter, expected_id):
    """Block until a response to `expected_id` arrives, or stdin closes. Anything else received
    while waiting — a stray notification, a second request, a response to some other id — is
    dropped rather than answered, queued or handled: this double never has more than one
    outstanding request at a time, and inventing concurrency support here would be exactly the
    kind of too-helpful fake this branch keeps paying for. The drop is announced on stderr, so a
    client that sends a second request mid-wait sees a diagnosable line instead of silence, rather
    than looking like this double is broken. Returns None if stdin closed before a matching answer
    showed up."""
    while True:
        message = read_message(stdin_iter)
        if message is None:
            return None
        if is_response(message) and message.get("id") == expected_id:
            return message
        print(f"fake-acp: dropped {describe(message)} while blocked waiting for the response to "
              f"id {expected_id!r} — this double answers one outstanding request at a time",
              file=sys.stderr, flush=True)


def handle(message, stdin_iter):
    method, request_id = message.get("method"), message.get("id")

    if method == "initialize":
        reply(request_id, {
            "protocolVersion": 1,
            "agentCapabilities": AGENT_CAPABILITIES,
            "agentInfo": {"name": "fake-acp", "version": "0.0.1"},
            "authMethods": [],
            "_meta": INITIALIZE_META,
        })
    elif method == "session/new":
        known_sessions.add(SESSION_ID)
        reply(request_id, {
            "sessionId": SESSION_ID,
            "modes": {"currentModeId": "default", "availableModes": AVAILABLE_MODES},
            "configOptions": CONFIG_OPTIONS,
        })
    elif method == "session/fork":
        params = message.get("params") or {}
        sid = params.get("sessionId")
        # The receipt, on stderr and never stdout: a client that never asked and a client that
        # asked and was refused are otherwise identical from the outside. Printed before the
        # answer, so it is present even for the refusal.
        print(f"fake-acp: session/fork for {sid!r} — forkable is {FORKABLE!r}",
              file=sys.stderr, flush=True)
        if FORK_DIES:
            # Exit without answering at all. The client's read loop sees `transport.messages`
            # finish and `handleTermination` fails every pending request with
            # `ClientError.connectionClosed` — a `ClientError` that is NOT `.agentError`, which is
            # the case the type filter alone could never reach and the one that made deleting the
            # narrowing guard a green break. Deterministic, not a race: the process is gone before
            # anything else can be written, so the only way this request can resolve is through
            # termination.
            sys.exit(0)
        if FORK_UNREADABLE:
            # A *successful-looking* answer whose body cannot be read: `ForkSessionResponse`
            # requires `sessionId`, so the client's decode throws rather than the agent refusing.
            # ⛔ That distinction is the reason this knob exists, and it is not decoration: an
            # agent that ANSWERS "no such session" has established that the transcript is gone,
            # while a reply nobody can read establishes only that nobody could ask. A client that
            # treats them alike reports a missing transcript on evidence it does not have.
            reply(request_id, {})
            return
        if not FORKABLE or sid != FORKABLE:
            # Unknown, or this double was given nothing to fork: refuse rather than hand back a
            # plausible session for a transcript that does not exist — the same instinct as
            # session/prompt below. The code and wording are the real adapter's, measured by
            # Scripts/probe/acp_fork.py; see the module docstring.
            respond_error(request_id, -32002, f"Resource not found: {sid}")
            return
        known_sessions.add(FORK_SESSION_ID)
        # `models` is absent here as it is from session/new, matching the 0.66.0 recording — and
        # ForkSessionResponse declares no such field at all, so the model can only be read off
        # configOptions on this path.
        reply(request_id, {
            "sessionId": FORK_SESSION_ID,
            "modes": {"currentModeId": "default", "availableModes": AVAILABLE_MODES},
            "configOptions": CONFIG_OPTIONS,
        })
    elif method == "session/set_config_option":
        params = message.get("params")
        if not isinstance(params, dict):
            respond_error(request_id, -32602, "session/set_config_option requires an object params")
            return
        notify({"sessionUpdate": "current_mode_update", "currentModeId": params.get("value")})
        reply(request_id, {"configOptions": []})
    elif method == "session/prompt":
        params = message.get("params") or {}
        sid = params.get("sessionId")
        if sid not in known_sessions:
            # Unknown session, or session/new never happened on this connection at all: refuse
            # rather than answer a plausible-looking turn for a session that does not exist.
            respond_error(request_id, -32602, f"unknown sessionId: {sid!r}")
            return
        if MODE in ("hang", "deaf"):
            return                      # never answer; the caller's timeout is the test
        if MODE == "crash":
            sys.exit(9)
        if MODE == "permission":
            permission_id = 9001
            write({"jsonrpc": "2.0", "id": permission_id, "method": "session/request_permission",
                   "params": {"sessionId": SESSION_ID,
                              "toolCall": {"toolCallId": "tc-1"},
                              "options": [
                                  {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                                  {"optionId": "deny", "name": "Deny", "kind": "reject_once"},
                              ]}})
            answer = wait_for_response(stdin_iter, permission_id)
            if answer is None:
                # stdin closed before an answer arrived: a genuine hang. `request_id` (the
                # session/prompt call) is simply never answered, exactly like MODE=hang.
                return
            outcome = (answer.get("result") or {}).get("outcome") or {}
            if outcome.get("optionId") != "allow":
                # Denied, cancelled, or an error reply: end the turn without ever touching the
                # fixture. Replaying regardless of the answer is the "identical either way" defect
                # that makes a client's refusal path untestable.
                reply(request_id, {"stopReason": "refusal"})
                return
        for update in fixture():
            notify(update)
        if MODE == "deaf-after-fixture":
            # The fixture is spoken and the turn is left open on purpose: from here only the client
            # can end it, so what the client does about a frame is observable instead of racing the
            # reply below. See the module docstring for the measurement that made this necessary.
            return
        reply(request_id, {"stopReason": STOP_REASON})
        if EXIT_AFTER_REPLY:
            # `reply` already flushed, so the response is in the pipe and the client will read it
            # before it sees EOF. What goes away is the wait for the client's own stdin close.
            sys.exit(0)
    elif method == "session/cancel":
        # A notification: nothing to answer, and deliberately nothing to change either — this
        # double never lets a cancel end a turn. Announced on stderr (never stdout, which stays
        # clean JSON-RPC) so the *receipt* is observable: without this, a client that sent no
        # cancel at all and one that sent a perfectly good one look identical from the outside.
        sid = (message.get("params") or {}).get("sessionId")
        print(f"fake-acp: session/cancel for {sid!r} — noted, and deliberately a no-op",
              file=sys.stderr, flush=True)
    elif request_id is not None:
        respond_error(request_id, -32601, f"fake-acp does not implement {method}")


STDIN = iter(sys.stdin)
while True:
    incoming = read_message(STDIN)      # ends when the client closes stdin — that is the exit
    if incoming is None:
        if MODE == "deaf":
            # ⛔ The one mode that does NOT take the exit above, and that is its entire point:
            # a client's SIGTERM→SIGKILL backstop can only be tested against a child that the
            # polite ask does not end. The trap installed at the top of this file still applies,
            # so the first rung is enough to reap this.
            while True:
                time.sleep(60)
        break
    handle(incoming, STDIN)
