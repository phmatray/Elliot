#!/usr/bin/env python3
"""Drive `session/fork` against the real claude-agent-acp adapter, in a sandbox.

`Fixtures/acp/session-new-commands.json` shows the adapter *advertising*
`sessionCapabilities.fork`. Advertised is not invoked, and nothing in this project had ever called
it — so `AgentRun`'s resume path, and `Scripts/fake-acp.py`'s stand-in for it, both rest on a claim
rather than a measurement. This closes that: it is the code behind whatever the commit body says,
kept beside `acp_turn.py` because a probe whose result is written down and whose source is not is an
unverifiable measurement.

Four questions, in order:
  1. does `session/fork` return a session id, and is it a NEW one?
  2. does a turn on the forked session carry the parent turn's context?
  3. what does a fork of an id that never existed answer — an error, and with what code?
  4. and the same for a WELL-FORMED id that never existed, which is not the same question.

Questions 3 and 4 are the ones the runner's behaviour hangs on: `AgentRun.start` treats
`ClientError.agentError` (the agent *answering* a refusal) as "the transcript is gone" and
everything else as "nobody could ask", so an adapter that answered a missing session some other way
— a success carrying a fresh session, a transport-level failure — would put the refusal on the wrong
side of that line.

⚠️ They are two questions because the first run of this probe showed they have different answers.
A junk string is rejected as a malformed **argument** (`Provided value "…" is not a UUID`), which
says nothing about a session that genuinely aged out; and every id Elliot resumes from is one the
agent itself issued, so Q4 is the case that matters and Q3 is the control that shows why.

The context check uses a nonce the model cannot have seen, so "the second turn knows it" cannot be
satisfied by a plausible guess.

Env:
  ACP_CWD        working directory for the sessions (a throwaway git checkout)
  ACP_DUMP       path to write the full JSON-RPC transcript to
  ACP_PKG        adapter package  (default: @agentclientprotocol/claude-agent-acp@0.66.0)
  ACP_MODE       session mode     (default: bypassPermissions)
  ACP_TURN_WAIT  seconds to wait for each session/prompt response (default: 300)

Answers any `session/request_permission` that arrives (the client MUST), and refuses `fs/` and
`terminal/` requests by name rather than in silence, exactly as `acp_turn.py` does — a missing
capability should surface as an error and not as a hang.
"""
import json
import os
import subprocess
import sys
import threading
import time
import uuid

PKG = os.environ.get("ACP_PKG", "@agentclientprotocol/claude-agent-acp@0.66.0")
CWD = os.environ["ACP_CWD"]
MODE = os.environ.get("ACP_MODE", "bypassPermissions")
DUMP = os.environ["ACP_DUMP"]
TURN_WAIT = float(os.environ.get("ACP_TURN_WAIT", "300"))

# Not a word the model can have seen, so "the fork kept the context" cannot be satisfied by a guess.
NONCE = "quillwarden-" + uuid.uuid4().hex[:8]

proc = subprocess.Popen(
    ["npx", "-y", PKG],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    cwd=CWD, text=True, bufsize=1,
)

inbox, lock = [], threading.Lock()
stderr_lines = []
_id = 0
_id_lock = threading.Lock()


def write(msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()


def send(method, params=None):
    global _id
    with _id_lock:
        _id += 1
        mid = _id
    msg = {"jsonrpc": "2.0", "id": mid, "method": method}
    if params is not None:
        msg["params"] = params
    write(msg)
    print(f"--> {method} (id={mid})", file=sys.stderr)
    return mid


def pump_stdout():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            with lock:
                inbox.append({"__nonjson__": line})
            continue
        with lock:
            inbox.append(msg)
        if msg.get("method") == "session/request_permission" and "id" in msg:
            opts = (msg.get("params") or {}).get("options") or []
            pick = next((o for o in opts if str(o.get("kind", "")).startswith("allow")),
                        opts[0] if opts else None)
            print(f"!!! session/request_permission -> answering "
                  f"{pick.get('optionId') if pick else 'CANCEL'}", file=sys.stderr)
            if pick:
                write({"jsonrpc": "2.0", "id": msg["id"],
                       "result": {"outcome": {"outcome": "selected",
                                              "optionId": pick.get("optionId")}}})
            else:
                write({"jsonrpc": "2.0", "id": msg["id"],
                       "result": {"outcome": {"outcome": "cancelled"}}})
        elif msg.get("method", "").startswith(("fs/", "terminal/")) and "id" in msg:
            write({"jsonrpc": "2.0", "id": msg["id"],
                   "error": {"code": -32601, "message": "probe declared no capability"}})


def pump_stderr():
    for line in proc.stderr:
        stderr_lines.append(line.rstrip())


threading.Thread(target=pump_stdout, daemon=True).start()
threading.Thread(target=pump_stderr, daemon=True).start()


def wait_for(pred, timeout):
    deadline, seen = time.time() + timeout, 0
    while time.time() < deadline:
        with lock:
            batch, seen = inbox[seen:], len(inbox)
        for m in batch:
            if pred(m):
                return m
        if proc.poll() is not None:
            return None
        time.sleep(0.1)
    return None


def call(method, params, timeout=120):
    """Send a request and return its response message, or None if none arrived."""
    mid = send(method, params)
    return wait_for(lambda m: m.get("id") == mid, timeout)


def agent_text(after_index):
    """Everything the agent said in `agent_message_chunk` frames from `after_index` on."""
    with lock:
        msgs = inbox[after_index:]
    out = []
    for m in msgs:
        if m.get("method") != "session/update":
            continue
        u = (m.get("params") or {}).get("update") or {}
        if u.get("sessionUpdate") == "agent_message_chunk":
            out.append(((u.get("content") or {}).get("text")) or "")
    return "".join(out)


def bail(why):
    print(f"!! {why}")
    print("\n".join(stderr_lines[-30:]))
    proc.kill()
    sys.exit(1)


if call("initialize", {
    "protocolVersion": 1,
    "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False},
                           "terminal": False},
    "clientInfo": {"name": "elliot-fork-probe", "version": "0.0.1"},
}) is None:
    bail("initialize failed")

new = call("session/new", {"cwd": CWD, "mcpServers": []})
parent = ((new or {}).get("result") or {}).get("sessionId")
if not parent:
    bail(f"session/new returned no sessionId: {new!r}")
print(f"parent sessionId = {parent}", file=sys.stderr)
call("session/set_config_option", {"sessionId": parent, "configId": "mode", "value": MODE})

# ---- turn 1, on the parent: plant the nonce -------------------------------------------------
with lock:
    mark = len(inbox)
first = call("session/prompt", {
    "sessionId": parent,
    "prompt": [{"type": "text", "text":
                f"Remember this codeword for later: {NONCE}. Reply with just: ok"}],
}, TURN_WAIT)
print("\n===== TURN 1 (parent) =====")
print(json.dumps(first, indent=2) if first else f"!! no response in {TURN_WAIT}s")
print(f"agent said: {agent_text(mark)[:400]!r}")

# ---- question 1: fork it ---------------------------------------------------------------------
forked_resp = call("session/fork", {"sessionId": parent, "cwd": CWD, "mcpServers": []})
print("\n===== session/fork (real session) =====")
print(json.dumps(forked_resp, indent=2)[:2500] if forked_resp else f"!! no response")
forked = ((forked_resp or {}).get("result") or {}).get("sessionId")
print(f"\nQ1  returned a sessionId : {forked!r}")
print(f"Q1  it is a NEW id       : {bool(forked) and forked != parent}")

# ---- question 2: does the fork carry the parent's context? ------------------------------------
print("\n===== TURN 2 (forked) =====")
if not forked:
    print("!! no forked session to prompt — Q2 unanswerable")
    second_text = ""
else:
    # Set the mode explicitly rather than assuming a fork inherits it: whether it does is itself
    # unmeasured, and a second turn running under a different mode would confound Q2.
    mode2 = call("session/set_config_option",
                 {"sessionId": forked, "configId": "mode", "value": MODE})
    print("set_config_option(mode) on the fork:")
    print(json.dumps(mode2, indent=2)[:800] if mode2 else "!! none")
    with lock:
        mark = len(inbox)
    second = call("session/prompt", {
        "sessionId": forked,
        "prompt": [{"type": "text", "text":
                    "What was the codeword I asked you to remember? Reply with just the codeword."}],
    }, TURN_WAIT)
    print(json.dumps(second, indent=2) if second else f"!! no response in {TURN_WAIT}s")
    second_text = agent_text(mark)
    print(f"agent said: {second_text[:400]!r}")
print(f"\nQ2  the fork knows the parent's codeword ({NONCE}) : {NONCE in second_text}")

# ---- question 3: fork an id that never existed ------------------------------------------------
ghost = "sess-definitely-not-here-9f3a"
ghost_resp = call("session/fork", {"sessionId": ghost, "cwd": CWD, "mcpServers": []}, 60)
print("\n===== session/fork (id that never existed) =====")
print(json.dumps(ghost_resp, indent=2)[:2000] if ghost_resp else "!! no response at all")
if ghost_resp is None:
    verdict = "NO ANSWER — not a JSON-RPC error; the runner would read this as 'could not ask'"
elif "error" in ghost_resp:
    verdict = f"JSON-RPC error, code {(ghost_resp['error'] or {}).get('code')!r}"
else:
    verdict = "a SUCCESS — ⛔ the runner's refusal path would never fire"
print(f"\nQ3  a fork of a missing session answers : {verdict}")

# ---- question 4: fork a WELL-FORMED id that never existed --------------------------------------
# ⛔ Not the same question as 3, and the first run of this probe proved it. The adapter answered a
# non-UUID ghost with `--resume requires a valid session ID … Provided value "…" is not a UUID`,
# which is ARGUMENT VALIDATION rather than "that session is gone". Every id Elliot actually resumes
# from is one the agent itself issued, i.e. a UUID — so the case the runner depends on is this one.
ghost_uuid = str(uuid.uuid4())
uuid_resp = call("session/fork", {"sessionId": ghost_uuid, "cwd": CWD, "mcpServers": []}, 60)
print("\n===== session/fork (well-formed UUID that never existed) =====")
print(json.dumps(uuid_resp, indent=2)[:2000] if uuid_resp else "!! no response at all")
if uuid_resp is None:
    verdict4 = "NO ANSWER — the runner would read this as 'could not ask', not as a refusal"
elif "error" in uuid_resp:
    verdict4 = f"JSON-RPC error, code {(uuid_resp['error'] or {}).get('code')!r}"
else:
    verdict4 = "a SUCCESS — ⛔ the runner's refusal path would never fire"
print(f"\nQ4  a fork of a well-formed but unknown session answers : {verdict4}")

print("\n===== STDERR (last 30) =====")
print("\n".join(stderr_lines[-30:]) or "(empty)")

with lock:
    msgs = list(inbox)
with open(DUMP, "w") as fh:
    json.dump(msgs, fh, indent=1)
print(f"\nfull transcript -> {DUMP}")
proc.kill()
