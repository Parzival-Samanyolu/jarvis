"""Rebuilds a streamed Messages response, and cuts streamed text into sentences to speak. Ported from Streaming.swift."""
from __future__ import annotations

import json
from typing import Callable


class StreamError(Exception):
    pass


class StreamAssembler:
    def __init__(self, on_text: Callable[[str], None] | None = None, on_tool_start: Callable[[str], None] | None = None) -> None:
        self.blocks: dict[int, dict] = {}
        self.partial_json: dict[int, str] = {}
        self.model: str | None = None
        self.stop_reason = "end_turn"
        self.usage: dict = {}
        self.on_text = on_text
        self.on_tool_start = on_tool_start

    def handle(self, e: dict) -> None:
        i = e.get("index", 0)
        t = e.get("type")
        if t == "message_start":
            m = e.get("message") or {}
            self.model = m.get("model")
            self.usage.update(m.get("usage") or {})
        elif t == "content_block_start":
            b = dict(e.get("content_block") or {})
            self.blocks[i] = b
            if b.get("type") in ("tool_use", "server_tool_use") and self.on_tool_start:
                self.on_tool_start(b.get("name", ""))
            if b.get("type") == "text" and b.get("text") and self.on_text:
                self.on_text(b["text"])
        elif t == "content_block_delta":
            d = e.get("delta") or {}
            b = self.blocks.setdefault(i, {})
            dt = d.get("type")
            if dt == "text_delta":
                b["text"] = b.get("text", "") + d.get("text", "")
                if self.on_text:
                    self.on_text(d.get("text", ""))
            elif dt == "thinking_delta":
                b["thinking"] = b.get("thinking", "") + d.get("thinking", "")
            elif dt == "signature_delta":
                b["signature"] = d.get("signature")
            elif dt == "input_json_delta":
                self.partial_json[i] = self.partial_json.get(i, "") + d.get("partial_json", "")
            elif dt == "citations_delta" and "citation" in d:
                b.setdefault("citations", []).append(d["citation"])
        elif t == "content_block_stop":
            js = self.partial_json.pop(i, "")
            if js:
                try:
                    self.blocks[i]["input"] = json.loads(js)
                except ValueError:
                    self.blocks[i]["input"] = {}
        elif t == "message_delta":
            if s := (e.get("delta") or {}).get("stop_reason"):
                self.stop_reason = s
            self.usage.update(e.get("usage") or {})
        elif t == "error":
            err = e.get("error") or {}
            raise StreamError(err.get("message") or err.get("type") or "stream error")

    @property
    def content(self) -> list[dict]:
        out = []
        for k in sorted(self.blocks):
            b = self.blocks[k]
            if b.get("type") == "tool_use" and "input" not in b:
                b["input"] = {}
            out.append(b)
        return out

    @staticmethod
    def events_for(resp: dict) -> list[dict]:
        """Replays a complete response as events (lets tests use plain JSON replies)."""
        ev = [{"type": "message_start", "message": {"model": resp.get("model", ""), "usage": resp.get("usage", {})}}]
        for i, b in enumerate(resp.get("content", [])):
            if b.get("type") == "text":
                ev.append({"type": "content_block_start", "index": i, "content_block": {**b, "text": ""}})
                ev.append({"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": b.get("text", "")}})
            else:
                ev.append({"type": "content_block_start", "index": i, "content_block": b})
            ev.append({"type": "content_block_stop", "index": i})
        ev.append({"type": "message_delta", "delta": {"stop_reason": resp.get("stop_reason", "end_turn")}, "usage": {}})
        return ev


class SentenceSplitter:
    """A sentence ends at . ! ? followed by whitespace, or a newline; very short fragments wait for more."""

    def __init__(self) -> None:
        self.buffer = ""

    def add(self, text: str) -> list[str]:
        self.buffer += text
        out, start, b = [], 0, self.buffer
        for i, c in enumerate(b):
            nxt = i + 1
            if c == "\n" or (c in ".!?" and nxt < len(b) and b[nxt].isspace()):
                s = b[start:nxt].strip()
                if len(s) >= 6 or c == "\n":
                    if s:
                        out.append(s)
                    start = nxt
        self.buffer = b[start:]
        return out

    def flush(self) -> str | None:
        s = self.buffer.strip()
        self.buffer = ""
        return s or None
