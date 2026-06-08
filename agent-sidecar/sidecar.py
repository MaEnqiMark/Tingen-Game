#!/usr/bin/env python3
"""
Tingen Agent Sidecar (scaffold)
===============================
The external LLM brain for the Tingen agent-sim. Godot (the deterministic substrate)
POSTs perception snapshots; this service returns ONE validated action per snapshot,
chosen from the constrained verb schema shared with the engine
(tingen/data/action_schema.json). All LLM nondeterminism is quarantined here.

This scaffold returns safe `idle` actions by default and validates every action against
the shared schema. Wiring real Claude calls is a later task — the contract is what
matters now, so the engine can talk to a stable boundary.

Key handling (mirrors asset-gen/generate_tingen_assets.py):
  Reads ANTHROPIC_API_KEY from the environment, else from --env-file. The token value is
  NEVER printed or logged. API keys live here, never in the Godot engine.

Run:
  python3 agent-sidecar/sidecar.py --port 8777
  curl -s localhost:8777/health
  curl -s -X POST localhost:8777/propose -d '{"snapshots":[{"agent_id":"voss"}]}'

Requires: Python 3.8+ standard library only (no pip installs).
"""

from __future__ import annotations

import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Shared schema: one source of truth with the engine.
SCHEMA_PATH = Path(__file__).resolve().parent.parent / "tingen" / "data" / "action_schema.json"


def load_schema() -> dict:
    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        return json.load(f).get("verbs", {})


def validate_action(action: dict, verbs: dict) -> tuple[bool, str]:
    if not action.get("actor"):
        return False, "missing actor"
    verb = action.get("verb", "")
    if verb not in verbs:
        return False, f"unknown verb '{verb}'"
    args = action.get("args", {})
    if not isinstance(args, dict):
        return False, "args must be an object"
    for req in verbs[verb]:
        if req not in args:
            return False, f"verb '{verb}' missing arg '{req}'"
    return True, ""


def decide(snapshot: dict, verbs: dict) -> dict:
    """Pick one action for one agent. Scaffold default: idle. (LLM call goes here later.)"""
    return {"actor": snapshot.get("agent_id", ""), "verb": "idle", "args": {}}


class Handler(BaseHTTPRequestHandler):
    verbs: dict = {}
    has_key: bool = False

    def log_message(self, *_args) -> None:  # keep logs quiet + key-safe
        pass

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send(200, {"ok": True, "have_key": self.has_key, "verbs": list(self.verbs)})
        else:
            self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/propose":
            self._send(404, {"ok": False, "error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send(400, {"ok": False, "error": "invalid json"})
            return
        snapshots = req.get("snapshots", [])
        actions = []
        for snap in snapshots:
            action = decide(snap, self.verbs)
            ok, reason = validate_action(action, self.verbs)
            if not ok:
                action = {"actor": snap.get("agent_id", ""), "verb": "idle", "args": {}, "_invalid": reason}
            actions.append(action)
        self._send(200, {"ok": True, "actions": actions})


def read_key(env_file: str | None) -> str:
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key and env_file and Path(env_file).exists():
        for line in Path(env_file).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("ANTHROPIC_API_KEY="):
                key = line.split("=", 1)[1].strip().strip('"').strip("'")
                break
    return key


def main() -> None:
    ap = argparse.ArgumentParser(description="Tingen agent sidecar (scaffold)")
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--env-file", default=None, help="path to a .env with ANTHROPIC_API_KEY")
    args = ap.parse_args()

    key = read_key(args.env_file)
    Handler.verbs = load_schema()
    Handler.has_key = bool(key)  # store presence only; NEVER the value

    # Key presence only — never echo the token.
    print(f"[sidecar] schema verbs: {sorted(Handler.verbs)}")
    print(f"[sidecar] ANTHROPIC_API_KEY {'present' if key else 'MISSING (idle-only mode)'}")
    print(f"[sidecar] listening on http://127.0.0.1:{args.port}")
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
