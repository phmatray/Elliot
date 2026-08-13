#!/usr/bin/env python3
"""Drive one full ACP prompt turn against claude-agent-acp, in a sandbox.

Measures the four things the Elliot/ACP design hangs on:
  1. does `mode = bypassPermissions` actually suppress session/request_permission
     (adapter issue #585 says it does not)
  2. the real shape of every session/update variant, for the RunEvent model
  3. whether usage_update arrives, and whether `cost` is populated
  4. the stopReason on the session/prompt response

Answers any session/request_permission that DOES arrive (the client MUST), and
records it — an arriving request is the finding, not a failure.
"""
import json
import os
import subprocess
import sys
import threading
import time

PKG = os.environ.get("ACP_PKG", "@agentclientprotocol/claude-agent-acp@0.66.0")
CWD = os.environ["ACP_CWD"]
MODE = os.environ.get("ACP_MODE", "bypassPermissions")
PROMPT = os.environ["ACP_PROMPT"]
DUMP = os.environ["ACP_DUMP"]
TURN_WAIT = float(os.environ.get("ACP_TURN_WAIT", "300"))

proc = subprocess.Popen(
    ["npx", "-y", PKG],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    cwd=CWD, text=True, bufsize=1,
)

inbox, lock = [], threading.Lock()
stderr_lines = []
permission_requests = []
_id = 0
_id_lock = threading.Lock()


def write(msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()


def send(method, params=None, notify=False):
    global _id
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if notify:
        write(msg)
        return None
    with _id_lock:
        _id += 1
        mid = _id
    msg["id"] = mid
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
        # The client MUST answer session/request_permission. Answering here,
        # on the reader thread, is what keeps a turn from deadlocking.
        if msg.get("method") == "session/request_permission" and "id" in msg:
            permission_requests.append(msg)
            opts = (msg.get("params") or {}).get("options") or []
            pick = next((o for o in opts if str(o.get("kind", "")).startswith("allow")),
                        opts[0] if opts else None)
            print(f"!!! session/request_permission arrived "
                  f"({len(permission_requests)}) -> answering "
                  f"{pick.get('optionId') if pick else 'CANCEL'}", file=sys.stderr)
            if pick:
                write({"jsonrpc": "2.0", "id": msg["id"],
                       "result": {"outcome": {"outcome": "selected",
                                              "optionId": pick.get("optionId")}}})
            else:
                write({"jsonrpc": "2.0", "id": msg["id"],
                       "result": {"outcome": {"outcome": "cancelled"}}})
        # Any other agent->client request gets a refusal rather than silence,
        # so a missing capability shows up as an error and not as a hang.
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


init_id = send("initialize", {
    "protocolVersion": 1,
    "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False},
                           "terminal": False},
    "clientInfo": {"name": "elliot-probe", "version": "0.0.1"},
})
if wait_for(lambda m: m.get("id") == init_id, 120) is None:
    print("!! initialize failed"); print("\n".join(stderr_lines[-30:])); sys.exit(1)

new_id = send("session/new", {"cwd": CWD, "mcpServers": []})
new = wait_for(lambda m: m.get("id") == new_id, 120)
sid = ((new or {}).get("result") or {}).get("sessionId")
print(f"sessionId = {sid}", file=sys.stderr)

mode_id = send("session/set_config_option",
               {"sessionId": sid, "configId": "mode", "value": MODE})
mode_resp = wait_for(lambda m: m.get("id") == mode_id, 60)
print("\n===== set_config_option(mode) RESPONSE =====")
print(json.dumps(mode_resp, indent=2)[:1500] if mode_resp else "!! none")

t0 = time.time()
prompt_id = send("session/prompt",
                 {"sessionId": sid, "prompt": [{"type": "text", "text": PROMPT}]})
final = wait_for(lambda m: m.get("id") == prompt_id, TURN_WAIT)
elapsed = time.time() - t0

print("\n===== session/prompt RESPONSE =====")
print(json.dumps(final, indent=2) if final else f"!! no response in {TURN_WAIT}s")
print(f"turn wall-clock: {elapsed:.1f}s")

with lock:
    msgs = list(inbox)

print("\n===== PERMISSION REQUESTS =====")
print(f"count = {len(permission_requests)}  (mode was {MODE!r})")
for p in permission_requests:
    print(json.dumps(p, indent=2)[:2000])

print("\n===== sessionUpdate kinds =====")
kinds = {}
for m in msgs:
    if m.get("method") == "session/update":
        k = ((m.get("params") or {}).get("update") or {}).get("sessionUpdate")
        kinds[k] = kinds.get(k, 0) + 1
for k, v in sorted(kinds.items(), key=lambda t: -t[1]):
    print(f"  {v:>4}  {k}")

print("\n===== one verbatim sample of each kind (commands elided) =====")
seen = set()
for m in msgs:
    if m.get("method") != "session/update":
        continue
    u = (m.get("params") or {}).get("update") or {}
    k = u.get("sessionUpdate")
    if k in seen or k == "available_commands_update":
        continue
    seen.add(k)
    print(f"\n--- {k} ---")
    print(json.dumps(u, indent=1)[:1800])

print("\n===== usage_update =====")
us = [((m.get("params") or {}).get("update") or {}) for m in msgs
      if m.get("method") == "session/update"
      and ((m.get("params") or {}).get("update") or {}).get("sessionUpdate") == "usage_update"]
print(f"{len(us)} usage_update notifications")
for u in us[-3:]:
    print(json.dumps(u, indent=1))

print("\n===== agent->client REQUESTS (fs/terminal/permission) =====")
for m in msgs:
    if m.get("method") and "id" in m:
        print(f"  {m['method']}")

print("\n===== STDERR (last 30) =====")
print("\n".join(stderr_lines[-30:]) or "(empty)")

with open(DUMP, "w") as fh:
    json.dump(msgs, fh, indent=1)
print(f"\nfull transcript -> {DUMP}")
proc.kill()
