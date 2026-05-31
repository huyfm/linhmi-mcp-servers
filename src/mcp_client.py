#!/usr/bin/env python3
"""Tiny read-only MCP stdio client used by the test scripts.

Launches the Atlassian MCP container exactly as Claude Code does
(`docker compose run --rm -T atlassian-mcp`), does the MCP handshake, and lets
you call read tools. It can ONLY call tools — there is no write helper here, and
the server itself is locked to read-only (READ_ONLY_MODE + ENABLED_TOOLS).
"""

from __future__ import annotations

import json
import queue
import subprocess
import threading
import time

COMPOSE_FILE = "/Users/huy/Documents/proj/linhmi/docker-compose.yml"
_CMD = ["docker", "compose", "-f", COMPOSE_FILE, "run", "--rm", "-T", "atlassian-mcp"]


class MCPError(RuntimeError):
    pass


class MCPClient:
    def __init__(self) -> None:
        self._proc = subprocess.Popen(
            _CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        self._inbox: "queue.Queue[dict]" = queue.Queue()
        self._err: list[str] = []
        self._id = 0
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self._proc.stdout
        for line in self._proc.stdout:
            line = line.strip()
            if line:
                try:
                    self._inbox.put(json.loads(line))
                except json.JSONDecodeError:
                    pass

    def _read_stderr(self) -> None:
        assert self._proc.stderr
        for line in self._proc.stderr:
            self._err.append(line.rstrip())
            if len(self._err) > 40:
                del self._err[0]

    def _send(self, obj: dict) -> None:
        assert self._proc.stdin
        self._proc.stdin.write(json.dumps(obj) + "\n")
        self._proc.stdin.flush()

    def _wait(self, msg_id: int, timeout: float) -> dict | None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self._inbox.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if msg.get("id") == msg_id:
                return msg
        return None

    def initialize(self, timeout: float = 120) -> dict:
        self._id += 1
        self._send({
            "jsonrpc": "2.0", "id": self._id, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "vnpay-mcp-test", "version": "0.1"}},
        })
        resp = self._wait(self._id, timeout)
        if not resp or "result" not in resp:
            raise MCPError("MCP did not initialize:\n" + "\n".join(self._err[-15:]))
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return resp["result"]

    def list_tools(self, timeout: float = 30) -> list[dict]:
        """Return the list of tools the server exposes (a read operation)."""
        self._id += 1
        self._send({"jsonrpc": "2.0", "id": self._id, "method": "tools/list"})
        resp = self._wait(self._id, timeout)
        if not resp or "result" not in resp:
            raise MCPError("tools/list failed")
        return resp["result"].get("tools", [])

    def call(self, name: str, arguments: dict | None = None,
             timeout: float = 60) -> str:
        """Call a tool, return its text content. Raises MCPError on tool error."""
        self._id += 1
        self._send({
            "jsonrpc": "2.0", "id": self._id, "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        })
        resp = self._wait(self._id, timeout)
        if resp is None:
            raise MCPError(f"{name}: timed out")
        if "error" in resp:
            raise MCPError(f"{name}: {resp['error']}")
        result = resp.get("result", {})
        texts = [b.get("text", "") for b in result.get("content", [])
                 if b.get("type") == "text"]
        text = "\n".join(texts)
        if result.get("isError"):
            raise MCPError(f"{name} returned error: {text[:300]}")
        return text

    def call_json(self, name: str, arguments: dict | None = None,
                  timeout: float = 60):
        """Call a tool and parse its text as JSON (tools return JSON text)."""
        text = self.call(name, arguments, timeout)
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text  # not JSON — return raw

    def close(self) -> None:
        try:
            self._proc.terminate()
            self._proc.wait(timeout=10)
        except Exception:
            self._proc.kill()
