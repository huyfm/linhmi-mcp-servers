#!/usr/bin/env python3
"""Tiny read-only MCP client used by the test scripts.

The deployment is now a remote **streamable-http** MCP server (the auth-proxy in
front of mcp-atlassian), so this client speaks streamable-http over HTTP the same
way Claude Code / Claude Desktop do, instead of spawning a stdio container.

It can ONLY call tools — there is no write helper here, and the server itself is
locked to read-only (READ_ONLY_MODE + ENABLED_TOOLS on mcp-atlassian).

Configuration (env):
  MCP_BASE_URL     full URL of the MCP endpoint, e.g. http://localhost:8000/mcp
                   (local dev) or https://<fqdn>/mcp (Azure). Required.
  MCP_BEARER_TOKEN optional Authorization bearer for the auth-proxy. Omit when
                   running locally with AUTH_DISABLED=true.

Streamable HTTP notes: each call is an HTTP POST of a JSON-RPC message. The
server may answer with a plain JSON body or a `text/event-stream` (SSE) body; we
parse both. The session id from `initialize` (Mcp-Session-Id response header) is
echoed on every subsequent request.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

DEFAULT_PROTOCOL_VERSION = "2024-11-05"


class MCPError(RuntimeError):
    pass


def _parse_body(content_type: str, raw: bytes) -> dict | None:
    """Return the JSON-RPC message from a JSON or SSE (text/event-stream) body."""
    text = raw.decode("utf-8", "replace").strip()
    if not text:
        return None
    if "text/event-stream" in (content_type or ""):
        # SSE frames: gather the `data:` lines and JSON-parse the last message.
        data_lines = [ln[5:].strip() for ln in text.splitlines()
                      if ln.startswith("data:")]
        for chunk in reversed(data_lines):
            try:
                return json.loads(chunk)
            except json.JSONDecodeError:
                continue
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


class MCPClient:
    def __init__(self, base_url: str | None = None, token: str | None = None) -> None:
        self._url = base_url or os.environ.get("MCP_BASE_URL", "")
        if not self._url:
            raise MCPError("MCP_BASE_URL is not set")
        self._token = token if token is not None else os.environ.get("MCP_BEARER_TOKEN", "")
        self._id = 0
        self._session_id: str | None = None
        self._protocol_version = DEFAULT_PROTOCOL_VERSION

    def _headers(self) -> dict[str, str]:
        h = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self._protocol_version,
        }
        if self._token:
            h["Authorization"] = f"Bearer {self._token}"
        if self._session_id:
            h["Mcp-Session-Id"] = self._session_id
        return h

    def _post(self, payload: dict, timeout: float) -> tuple[dict | None, dict]:
        body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(self._url, data=body, headers=self._headers(),
                                     method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                ctype = resp.headers.get("Content-Type", "")
                # Lower-case keys so callers can look up headers case-insensitively
                # (servers may return e.g. `mcp-session-id` in any casing).
                resp_headers = {k.lower(): v for k, v in resp.headers.items()}
                return _parse_body(ctype, raw), resp_headers
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:300]
            raise MCPError(f"HTTP {exc.code} from {self._url}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise MCPError(f"could not reach {self._url}: {exc.reason}") from exc

    def initialize(self, timeout: float = 120) -> dict:
        self._id += 1
        result, headers = self._post({
            "jsonrpc": "2.0", "id": self._id, "method": "initialize",
            "params": {"protocolVersion": self._protocol_version, "capabilities": {},
                       "clientInfo": {"name": "vnpay-mcp-test", "version": "0.1"}},
        }, timeout)
        if not result or "result" not in result:
            raise MCPError(f"MCP did not initialize: {result}")
        # Capture the session id and negotiated protocol version for later calls.
        self._session_id = headers.get("mcp-session-id") or self._session_id
        self._protocol_version = result["result"].get("protocolVersion", self._protocol_version)
        # Notify initialized (no id -> notification).
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, timeout=30)
        return result["result"]

    def list_tools(self, timeout: float = 30) -> list[dict]:
        """Return the list of tools the server exposes (a read operation)."""
        self._id += 1
        result, _ = self._post({"jsonrpc": "2.0", "id": self._id,
                                "method": "tools/list"}, timeout)
        if not result or "result" not in result:
            raise MCPError("tools/list failed")
        return result["result"].get("tools", [])

    def call(self, name: str, arguments: dict | None = None, timeout: float = 60) -> str:
        """Call a tool, return its text content. Raises MCPError on tool error."""
        self._id += 1
        result, _ = self._post({
            "jsonrpc": "2.0", "id": self._id, "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        }, timeout)
        if result is None:
            raise MCPError(f"{name}: no response")
        if "error" in result:
            raise MCPError(f"{name}: {result['error']}")
        payload = result.get("result", {})
        texts = [b.get("text", "") for b in payload.get("content", [])
                 if b.get("type") == "text"]
        text = "\n".join(texts)
        if payload.get("isError"):
            raise MCPError(f"{name} returned error: {text[:300]}")
        return text

    def call_json(self, name: str, arguments: dict | None = None, timeout: float = 60):
        """Call a tool and parse its text as JSON (tools return JSON text)."""
        text = self.call(name, arguments, timeout)
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text  # not JSON — return raw

    def close(self) -> None:
        # HTTP is connectionless here; nothing to tear down.
        self._session_id = None
