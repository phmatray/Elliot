#!/usr/bin/env python3
"""How long does Preflight's `agent.adapter` handshake cost?

`PreflightService.globalChecks` spawns the ACP adapter once per launch, runs `initialize` and
`session/new`, reads the first `available_commands_update`, and ends the agent. That is the only
row on that screen whose cost is a network-dependent subprocess, so the number matters and the
plan required it be measured rather than asserted.

Read-only: no `session/prompt` is ever sent, so nothing is executed in the target checkout.

    python3 Scripts/probe/acp_preflight_cost.py            # warm
    rm -rf "$(npm config get cache)/_npx" && python3 Scripts/probe/acp_preflight_cost.py   # cold

Prints one line per stage with seconds since spawn. ⚠️ Never close the child's stdin — see
`acp_probe.py`'s header; `communicate()` would make a healthy adapter look like one that failed
to start.
"""
import json
import os
import subprocess
import sys
import threading
import time

PKG = os.environ.get("ACP_PKG", "@agentclientprotocol/claude-agent-acp@0.66.0")
CWD = os.environ.get("ACP_CWD", os.getcwd())
WAIT = float(os.environ.get("ACP_WAIT", "120"))

t0 = time.monotonic()
proc = subprocess.Popen(
    ["npx", "--yes", PKG],
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
            continue
        with lock:
            inbox.append(msg)


def pump_stderr():
    for line in proc.stderr:
        stderr_lines.append(line.rstrip())


threading.Thread(target=pump_stdout, daemon=True).start()
threading.Thread(target=pump_stderr, daemon=True).start()

_id = 0


def send(method, params):
    global _id
    _id += 1
    proc.stdin.write(json.dumps(
        {"jsonrpc": "2.0", "id": _id, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    return _id


def wait_for(pred, timeout):
    deadline = time.monotonic() + timeout
    seen = 0
    while time.monotonic() < deadline:
        with lock:
            batch, seen = inbox[seen:], len(inbox)
        for m in batch:
            if pred(m):
                return m
        if proc.poll() is not None:
            return None
        time.sleep(0.02)
    return None


def mark(label):
    print(f"{time.monotonic() - t0:7.2f}s  {label}", flush=True)


mark("spawned npx")
init_id = send("initialize", {
    "protocolVersion": 1,
    "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False},
                           "terminal": False},
    "clientInfo": {"name": "elliot-preflight", "version": "0.0.1"},
})
init = wait_for(lambda m: m.get("id") == init_id, WAIT)
if init is None:
    mark("!! initialize never answered")
    print("\n".join(stderr_lines[-20:]), file=sys.stderr)
    proc.kill()
    sys.exit(1)
info = (init.get("result") or {}).get("agentInfo") or {}
mark(f"initialize answered — {info.get('name')} {info.get('version')}")

new_id = send("session/new", {"cwd": CWD, "mcpServers": []})
new = wait_for(lambda m: m.get("id") == new_id, WAIT)
mark("session/new answered" if new else "!! session/new never answered")


def is_commands(m):
    return (m.get("method") == "session/update"
            and ((m.get("params") or {}).get("update") or {}).get("sessionUpdate")
            == "available_commands_update")


note = wait_for(is_commands, WAIT)
if note is None:
    mark("!! no available_commands_update arrived")
else:
    commands = (note["params"]["update"].get("availableCommands") or [])
    names = {c.get("name") for c in commands}
    wanted = ["ai-migration-kit:create-issue", "ai-migration-kit:implement-issue",
              "ai-migration-kit:merge-pr"]
    mark(f"available_commands_update — {len(commands)} commands, "
         f"{sum(1 for w in wanted if w in names)}/3 ai-migration-kit ones present")

proc.kill()
mark("agent ended")
