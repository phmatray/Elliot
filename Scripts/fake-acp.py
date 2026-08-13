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


def notify(update):
    write({"jsonrpc": "2.0", "method": "session/update",
           "params": {"sessionId": SESSION_ID, "update": update}})


def fixture():
    path = os.environ.get("FAKE_ACP_FIXTURE")
    if not path:
        return []
    with open(path) as fh:
        return json.load(fh)


def handle(message):
    method, request_id = message.get("method"), message.get("id")

    if method == "initialize":
        reply(request_id, {
            "protocolVersion": 1,
            "agentCapabilities": {"sessionCapabilities": {}},
            "agentInfo": {"name": "fake-acp", "version": "0.0.1"},
            "authMethods": [],
        })
    elif method == "session/new":
        reply(request_id, {
            "sessionId": SESSION_ID,
            "modes": {"currentModeId": "default", "availableModes": [
                {"id": "default", "name": "Manual"},
                {"id": "bypassPermissions", "name": "Bypass Permissions"},
            ]},
        })
    elif method == "session/set_config_option":
        notify({"sessionUpdate": "current_mode_update",
                "currentModeId": message["params"].get("value")})
        reply(request_id, {"configOptions": []})
    elif method == "session/prompt":
        if MODE == "hang":
            return                      # never answer; the caller's timeout is the test
        if MODE == "crash":
            sys.exit(9)
        if MODE == "permission":
            # The client MUST answer this. A double that asks is how the answering path is tested.
            write({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission",
                   "params": {"sessionId": SESSION_ID,
                              "toolCall": {"toolCallId": "tc-1"},
                              "options": [
                                  {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                                  {"optionId": "deny", "name": "Deny", "kind": "reject_once"},
                              ]}})
        for update in fixture():
            notify(update)
        reply(request_id, {"stopReason": STOP_REASON})
    elif method == "session/cancel":
        pass                            # a notification; nothing to answer
    elif request_id is not None:
        write({"jsonrpc": "2.0", "id": request_id,
               "error": {"code": -32601, "message": f"fake-acp does not implement {method}"}})


for line in sys.stdin:                  # ends when the client closes stdin — that is the exit
    line = line.strip()
    if not line:
        continue
    try:
        handle(json.loads(line))
    except json.JSONDecodeError:
        write({"jsonrpc": "2.0", "id": None,
               "error": {"code": -32700, "message": "parse error"}})
