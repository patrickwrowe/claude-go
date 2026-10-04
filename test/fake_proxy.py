#!/usr/bin/env python3
"""Stand-in for the LiteLLM proxy, for tests that drive a real Claude Code.

Invoked like litellm (only --port is used), it answers the health checks that
bin/claude-go makes and speaks Anthropic Messages itself, logging every request
in full to $FAKE_LOG (one JSON line: path, model, system text, message text,
tool names) so tests can assert on exactly what Claude Code sent upstream.

Replies:
  - "pong" by default;
  - with $FAKE_TOOL set to {"name": ..., "input": {...}}, the first reply is that
    tool call; once Claude Code sends the tool result back, the reply echoes it
    as "TOOL_RESULT<<...>>" so tests can see what the tool produced (or why it
    was refused).
"""
import json, os, sys, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ.get("FAKE_LOG", "/dev/null")
KEY = os.environ.get("LITELLM_MASTER_KEY", "")
TOOL = json.loads(os.environ["FAKE_TOOL"]) if os.environ.get("FAKE_TOOL") else None


def text_of(content):
    if isinstance(content, str):
        return content
    parts = []
    for b in content or []:
        t = b.get("type")
        if t == "text":
            parts.append(b.get("text", ""))
        elif t == "tool_result":
            parts.append("TOOL_RESULT:" + text_of(b.get("content")))
        elif t == "tool_use":
            parts.append("TOOL_USE:" + json.dumps(b.get("input")))
    return "\n".join(parts)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        return self.headers.get("authorization", "") == f"Bearer {KEY}"

    def do_GET(self):
        if self.path.startswith("/health/liveliness"):
            return self._json(200, "I'm alive!")
        if self.path.startswith("/v1/models") and self._authed():
            return self._json(200, {"data": []})
        self._json(401 if self.path.startswith("/v1/") else 404, {"error": "no"})

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        system = body.get("system") or ""
        if not isinstance(system, str):
            system = "\n".join(b.get("text", "") for b in system)
        msgs = body.get("messages", [])
        with open(LOG, "a") as f:
            f.write(json.dumps({
                "path": self.path,
                "model": body.get("model"),
                "system": system,
                "messages": [{"role": m.get("role"), "text": text_of(m.get("content"))} for m in msgs],
                "tools": [t.get("name") for t in body.get("tools") or []],
            }) + "\n")
        if not self._authed():
            return self._json(401, {"type": "error", "error": {"type": "authentication_error", "message": "bad key"}})
        if self.path.split("?")[0].endswith("/count_tokens"):
            return self._json(200, {"input_tokens": 42})

        users = [m for m in msgs if m.get("role") == "user"]
        last = text_of(users[-1].get("content")) if users else ""
        tools = [t.get("name") for t in body.get("tools") or []]
        if "TOOL_RESULT:" in last:
            content, stop = [{"type": "text", "text": "TOOL_RESULT<<" + last[last.find("TOOL_RESULT:") + 12:] + ">>"}], "end_turn"
        elif TOOL and TOOL["name"] in tools:
            content = [{"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:12], "name": TOOL["name"], "input": TOOL["input"]}]
            stop = "tool_use"
        else:
            content, stop = [{"type": "text", "text": "pong"}], "end_turn"
        msg = {"id": "msg_" + uuid.uuid4().hex[:12], "type": "message", "role": "assistant", "model": body.get("model"),
               "content": content, "stop_reason": stop, "stop_sequence": None,
               "usage": {"input_tokens": 10, "output_tokens": 5}}
        if not body.get("stream"):
            return self._json(200, msg)

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True

        def ev(name, data):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        ev("message_start", {"type": "message_start", "message": {**msg, "content": [], "stop_reason": None}})
        for i, b in enumerate(content):
            if b["type"] == "text":
                ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}})
                ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": b["text"]}})
            else:
                ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {**b, "input": {}}})
                ev("content_block_delta", {"type": "content_block_delta", "index": i,
                                           "delta": {"type": "input_json_delta", "partial_json": json.dumps(b["input"])}})
            ev("content_block_stop", {"type": "content_block_stop", "index": i})
        ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 5}})
        ev("message_stop", {"type": "message_stop"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[sys.argv.index("--port") + 1])), H).serve_forever()
