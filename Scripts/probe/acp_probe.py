#!/usr/bin/env python3
"""Probe `claude-agent-acp` over ACP: does it advertise the ai-migration-kit
plugin skills as slash commands?

Read-only. Sends `initialize` and `session/new` only — never `session/prompt`,
so nothing is executed in the target checkout.

The lesson from CLAUDE.md about elliot-mcp applies to any stdio JSON-RPC child:
never close stdin. subprocess.communicate() would close it and the child exits
having written nothing, which reads exactly like a child that failed to start.
"""
import json
import os
import subprocess
import sys
import threading
import time

PKG = os.environ.get("ACP_PKG", "@agentclientprotocol/claude-agent-acp@0.66.0")
CWD = os.environ.get("ACP_CWD", os.getcwd())
WAIT = float(os.environ.get("ACP_WAIT", "60"))

proc = subprocess.Popen(
    ["npx", "-y", PKG],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    cwd=CWD, text=True, bufsize=1,
)

inbox, lock = [], threading.Lock()
stderr_lines = []


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


def pump_stderr():
    for line in proc.stderr:
        stderr_lines.append(line.rstrip())


threading.Thread(target=pump_stdout, daemon=True).start()
threading.Thread(target=pump_stderr, daemon=True).start()

_id = 0


def send(method, params=None, notify=False):
    global _id
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        _id += 1
        msg["id"] = _id
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    print(f"--> {method}" + ("" if notify else f" (id={_id})"), file=sys.stderr)
    return None if notify else _id


def wait_for(pred, timeout):
    deadline = time.time() + timeout
    seen = 0
    while time.time() < deadline:
        with lock:
            batch = inbox[seen:]
            seen = len(inbox)
        for m in batch:
            if pred(m):
                return m
        if proc.poll() is not None:
            return None
        time.sleep(0.15)
    return None


def snapshot():
    with lock:
        return list(inbox)


# --- 1. initialize -----------------------------------------------------------
init_id = send("initialize", {
    "protocolVersion": 1,
    "clientCapabilities": {
        "fs": {"readTextFile": False, "writeTextFile": False},
        "terminal": False,
    },
    "clientInfo": {"name": "elliot-probe", "version": "0.0.1"},
})
init = wait_for(lambda m: m.get("id") == init_id, WAIT)
print("\n===== INITIALIZE RESPONSE =====")
print(json.dumps(init, indent=2) if init else "!! no response")

if init is None or "error" in (init or {}):
    print("\n===== STDERR =====")
    print("\n".join(stderr_lines[-40:]))
    proc.kill()
    sys.exit(1)

# --- 2. session/new ----------------------------------------------------------
new_id = send("session/new", {"cwd": CWD, "mcpServers": []})
new = wait_for(lambda m: m.get("id") == new_id, WAIT)
print("\n===== SESSION/NEW RESPONSE =====")
print(json.dumps(new, indent=2) if new else "!! no response")

# --- 3. let commands land ----------------------------------------------------
time.sleep(6)

msgs = snapshot()
print("\n===== ALL NOTIFICATION METHODS SEEN =====")
methods = {}
for m in msgs:
    k = m.get("method") or ("<response>" if "id" in m else "<other>")
    methods[k] = methods.get(k, 0) + 1
for k, v in sorted(methods.items()):
    print(f"  {v:>3}  {k}")

print("\n===== available_commands_update =====")
found = False
for m in msgs:
    if m.get("method") != "session/update":
        continue
    upd = (m.get("params") or {}).get("update") or {}
    if upd.get("sessionUpdate") != "available_commands_update":
        continue
    found = True
    cmds = upd.get("availableCommands") or []
    print(f"{len(cmds)} commands advertised")
    for c in cmds:
        print(f"  - {c.get('name')!r:<48} {str(c.get('description'))[:70]}")
if not found:
    print("!! no available_commands_update notification arrived")

print("\n===== grep: ai-migration-kit / create-issue =====")
blob = json.dumps(msgs)
for needle in ("ai-migration-kit", "create-issue", "implement-issue",
               "merge-pr", "superpowers", "brainstorming"):
    print(f"  {needle:<20} {'PRESENT' if needle in blob else 'absent'}")

print("\n===== STDERR (last 40) =====")
print("\n".join(stderr_lines[-40:]) or "(empty)")

with open(os.environ.get("ACP_DUMP", "/tmp/acp_probe_dump.json"), "w") as fh:
    json.dump(msgs, fh, indent=1)
print(f"\nfull transcript -> {os.environ.get('ACP_DUMP', '/tmp/acp_probe_dump.json')}")

proc.kill()
