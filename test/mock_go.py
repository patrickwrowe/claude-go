#!/usr/bin/env python3
"""Mock of the OpenCode Go API for offline testing of claude-go.

Speaks the three protocols Go exposes:
  POST /v1/messages          (Anthropic Messages)      - qwen*, minimax-*
  POST /v1/chat/completions  (OpenAI Chat Completions) - glm-*, kimi-*, deepseek-* ...
  POST /v1/responses         (OpenAI Responses)        - grok-*, gpt-5.6-luna, muse-*
and GET /v1/models.

Every request is appended to $MOCK_LOG as one JSON line (path, headers, model,
stream flag, tool count) so tests can assert on what actually reached upstream.
"""
import json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ.get("MOCK_LOG", "/tmp/mock_go.jsonl")
EXPECTED_KEY = os.environ.get("MOCK_KEY", "test-go-key")
REPLY = "pong from mock"

TOOL_NAME = "Bash"
TOOL_ARGS = json.dumps({"command": "echo TOOL_$((6*7))", "description": "mock tool call"})


def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def _auth_ok(self):
        auth = self.headers.get("authorization", "")
        xkey = self.headers.get("x-api-key", "")
        return auth == f"Bearer {EXPECTED_KEY}" or xkey == EXPECTED_KEY

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse_start(self):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True

    def _sse(self, event, data):
        if event:
            self.wfile.write(f"event: {event}\n".encode())
        self.wfile.write(f"data: {json.dumps(data) if not isinstance(data, str) else data}\n\n".encode())
        self.wfile.flush()

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("content-length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            return self._json(200, {"object": "list", "data": [
                {"id": m, "object": "model"} for m in
                ["minimax-m3", "qwen3.8-flash", "kimi-k2.7-code", "glm-5.2", "gpt-5.6-luna", "brand-new-model"]]})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        raw = self.rfile.read(n) if n else b"{}"
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        path = self.path.split("?")[0]
        log({
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "model": body.get("model"),
            "stream": body.get("stream", False),
            "n_tools": len(body.get("tools") or []),
            "body_keys": sorted(body.keys()),
            "has_claude_md": "CLAUDE-MD-CANARY" in raw.decode("utf-8", "replace"),
        })
        if not self._auth_ok():
            return self._json(401, {"error": {"message": "bad key", "type": "auth"}})
        # Tests force an upstream failure with this header (the proxy forwards x-* headers).
        if self.headers.get("x-mock-status"):
            return self._json(int(self.headers["x-mock-status"]), {"error": {"message": "forced by test", "type": "mock"}})
        model = body.get("model", "?")
        stream = bool(body.get("stream"))
        blob = json.dumps(body)
        # Tool round-trip: the prompt asks for a tool; Claude Code runs it and
        # sends back the output (TOOL_42), which only appears in a tool result.
        if "TOOL_42" in blob:
            self.mode, self.text = "text", "round-trip ok TOOL_42"
        elif "USE_TOOL" in blob:
            self.mode, self.text = "tool", ""
        else:
            self.mode, self.text = "text", REPLY
        if path.endswith("/messages/count_tokens"):
            return self._json(200, {"input_tokens": 42})
        if path.endswith("/messages"):
            return self.anthropic(model, stream)
        if path.endswith("/chat/completions"):
            return self.chat(model, stream)
        if path.endswith("/responses"):
            return self.openai_responses(model, stream)
        self._json(404, {"error": {"message": f"no route {path}"}})

    # ---- Anthropic Messages ----
    def anthropic(self, model, stream):
        mid = "msg_" + uuid.uuid4().hex[:12]
        usage = {"input_tokens": 10, "output_tokens": 4}
        if self.mode == "tool":
            tid = "toolu_" + uuid.uuid4().hex[:12]
            if not stream:
                return self._json(200, {"id": mid, "type": "message", "role": "assistant", "model": model,
                                        "content": [{"type": "tool_use", "id": tid, "name": TOOL_NAME, "input": json.loads(TOOL_ARGS)}],
                                        "stop_reason": "tool_use", "stop_sequence": None, "usage": usage})
            self._sse_start()
            self._sse("message_start", {"type": "message_start", "message": {
                "id": mid, "type": "message", "role": "assistant", "model": model, "content": [],
                "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
            self._sse("content_block_start", {"type": "content_block_start", "index": 0,
                                              "content_block": {"type": "tool_use", "id": tid, "name": TOOL_NAME, "input": {}}})
            for i in range(0, len(TOOL_ARGS), 12):
                self._sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                                  "delta": {"type": "input_json_delta", "partial_json": TOOL_ARGS[i:i+12]}})
            self._sse("content_block_stop", {"type": "content_block_stop", "index": 0})
            self._sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                                        "usage": {"output_tokens": 20}})
            self._sse("message_stop", {"type": "message_stop"})
            return
        if not stream:
            return self._json(200, {"id": mid, "type": "message", "role": "assistant", "model": model,
                                    "content": [{"type": "text", "text": self.text}],
                                    "stop_reason": "end_turn", "stop_sequence": None, "usage": usage})
        self._sse_start()
        self._sse("message_start", {"type": "message_start", "message": {
            "id": mid, "type": "message", "role": "assistant", "model": model, "content": [],
            "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
        self._sse("content_block_start", {"type": "content_block_start", "index": 0,
                                          "content_block": {"type": "text", "text": ""}})
        self._sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                          "delta": {"type": "text_delta", "text": self.text}})
        self._sse("content_block_stop", {"type": "content_block_stop", "index": 0})
        self._sse("message_delta", {"type": "message_delta",
                                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                    "usage": {"output_tokens": 4}})
        self._sse("message_stop", {"type": "message_stop"})

    # ---- OpenAI Chat Completions ----
    def chat(self, model, stream):
        cid = "chatcmpl-" + uuid.uuid4().hex[:12]
        now = int(time.time())
        if self.mode == "tool":
            call_id = "call_" + uuid.uuid4().hex[:12]
            if not stream:
                return self._json(200, {"id": cid, "object": "chat.completion", "created": now, "model": model,
                                        "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {
                                            "role": "assistant", "content": None, "tool_calls": [{"id": call_id, "type": "function",
                                            "function": {"name": TOOL_NAME, "arguments": TOOL_ARGS}}]}}],
                                        "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}})
            self._sse_start()
            base = {"id": cid, "object": "chat.completion.chunk", "created": now, "model": model}
            self._sse(None, {**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": None, "tool_calls": [
                {"index": 0, "id": call_id, "type": "function", "function": {"name": TOOL_NAME, "arguments": ""}}]}, "finish_reason": None}]})
            for i in range(0, len(TOOL_ARGS), 12):
                self._sse(None, {**base, "choices": [{"index": 0, "delta": {"tool_calls": [
                    {"index": 0, "function": {"arguments": TOOL_ARGS[i:i+12]}}]}, "finish_reason": None}]})
            self._sse(None, {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
            self._sse(None, {**base, "choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}})
            self._sse(None, "[DONE]")
            return
        if not stream:
            return self._json(200, {"id": cid, "object": "chat.completion", "created": now, "model": model,
                                    "choices": [{"index": 0, "finish_reason": "stop",
                                                 "message": {"role": "assistant", "content": self.text}}],
                                    "usage": {"prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14}})
        self._sse_start()
        base = {"id": cid, "object": "chat.completion.chunk", "created": now, "model": model}
        self._sse(None, {**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]})
        self._sse(None, {**base, "choices": [{"index": 0, "delta": {"content": self.text}, "finish_reason": None}]})
        self._sse(None, {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self._sse(None, {**base, "choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14}})
        self._sse(None, "[DONE]")

    # ---- OpenAI Responses ----
    def openai_responses(self, model, stream):
        rid = "resp_" + uuid.uuid4().hex[:12]
        oid = "msg_" + uuid.uuid4().hex[:12]
        now = int(time.time())
        item = {"id": oid, "type": "message", "status": "completed", "role": "assistant",
                "content": [{"type": "output_text", "text": self.text, "annotations": []}]}
        if self.mode == "tool":
            item = {"id": "fc_" + uuid.uuid4().hex[:12], "type": "function_call", "status": "completed",
                    "call_id": "call_" + uuid.uuid4().hex[:12], "name": TOOL_NAME, "arguments": TOOL_ARGS}
        usage = {"input_tokens": 10, "output_tokens": 4, "total_tokens": 14,
                 "input_tokens_details": {"cached_tokens": 0}, "output_tokens_details": {"reasoning_tokens": 0}}
        full = {"id": rid, "object": "response", "created_at": now, "status": "completed", "model": model,
                "output": [item], "usage": usage, "parallel_tool_calls": True, "tool_choice": "auto", "tools": []}
        if not stream:
            return self._json(200, full)
        self._sse_start()
        partial = {**full, "status": "in_progress", "output": [], "usage": None}
        seq = iter(range(100))
        self._sse("response.created", {"type": "response.created", "sequence_number": next(seq), "response": partial})
        if self.mode == "tool":
            self._sse("response.output_item.added", {"type": "response.output_item.added", "sequence_number": next(seq), "output_index": 0,
                                                     "item": {**item, "status": "in_progress", "arguments": ""}})
            for i in range(0, len(TOOL_ARGS), 12):
                self._sse("response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta",
                          "sequence_number": next(seq), "item_id": item["id"], "output_index": 0, "delta": TOOL_ARGS[i:i+12]})
            self._sse("response.function_call_arguments.done", {"type": "response.function_call_arguments.done",
                      "sequence_number": next(seq), "item_id": item["id"], "output_index": 0, "arguments": TOOL_ARGS})
            self._sse("response.output_item.done", {"type": "response.output_item.done", "sequence_number": next(seq), "output_index": 0, "item": item})
            self._sse("response.completed", {"type": "response.completed", "sequence_number": next(seq), "response": full})
            return
        self._sse("response.output_item.added", {"type": "response.output_item.added", "sequence_number": next(seq), "output_index": 0,
                                                 "item": {**item, "status": "in_progress", "content": []}})
        self._sse("response.content_part.added", {"type": "response.content_part.added", "sequence_number": next(seq), "item_id": oid,
                                                  "output_index": 0, "content_index": 0,
                                                  "part": {"type": "output_text", "text": "", "annotations": []}})
        self._sse("response.output_text.delta", {"type": "response.output_text.delta", "sequence_number": next(seq), "item_id": oid,
                                                 "output_index": 0, "content_index": 0, "delta": self.text})
        self._sse("response.output_text.done", {"type": "response.output_text.done", "sequence_number": next(seq), "item_id": oid,
                                                "output_index": 0, "content_index": 0, "text": self.text})
        self._sse("response.content_part.done", {"type": "response.content_part.done", "sequence_number": next(seq), "item_id": oid,
                                                 "output_index": 0, "content_index": 0,
                                                 "part": {"type": "output_text", "text": self.text, "annotations": []}})
        self._sse("response.output_item.done", {"type": "response.output_item.done", "sequence_number": next(seq), "output_index": 0, "item": item})
        self._sse("response.completed", {"type": "response.completed", "sequence_number": next(seq), "response": full})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
