#!/usr/bin/env python3
"""An ACP agent that answers, for tests.

`fake-claude.sh` prints and exits; ACP is a conversation, so this reads JSON-RPC on stdin and
replies. It replays a fixture of `session/update` frames on `session/prompt`, then answers the
prompt request with a stop reason.

Env:
  FAKE_ACP_FIXTURE      JSON array of `update` objects to replay. Required for a useful turn.
  FAKE_ACP_MODE         ok | hang | crash | permission          (default: ok)
  FAKE_ACP_READY        path touched once trap-protected
  FAKE_ACP_ARGV_OUT     path to write argv to, one element per line
  FAKE_ACP_STOP_REASON  default: end_turn

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

`session/prompt` is refused (a JSON-RPC error, never an empty-looking success) for any
`sessionId` that was never returned by a `session/new` on this connection — including one sent
before `session/new` has happened at all. A plausible success here would hide a client bug behind
a turn that looks like it worked, the same instinct as `fake-gh.sh` exiting 64 on an unexpected
subcommand rather than returning an empty list.
"""
import json
import os
import signal
import sys

MODE = os.environ.get("FAKE_ACP_MODE", "ok")
STOP_REASON = os.environ.get("FAKE_ACP_STOP_REASON", "end_turn")
SESSION_ID = "sess-fake-0001"

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
        if MODE == "hang":
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
        reply(request_id, {"stopReason": STOP_REASON})
    elif method == "session/cancel":
        pass                            # a notification; nothing to answer
    elif request_id is not None:
        respond_error(request_id, -32601, f"fake-acp does not implement {method}")


STDIN = iter(sys.stdin)
while True:
    incoming = read_message(STDIN)      # ends when the client closes stdin — that is the exit
    if incoming is None:
        break
    handle(incoming, STDIN)
