"""Long-term memory (memory.md, one "- [yyyy-mm-dd] fact" per line) and short-term conversation. Ported from Memory.swift."""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path

from .config import Paths

STOP = {"i", "a", "an", "the", "that", "is", "am", "are", "my", "me", "to", "of", "and", "in", "on", "at", "for", "sir",
        "user", "he", "his", "has", "have", "was", "it", "this", "i'm", "im", "you", "your", "about", "with", "do", "does",
        "like", "likes"}


def normalise(s: str) -> str:
    return " ".join("".join(c for c in s.lower() if c.isalnum() or c == " ").split())


def keywords(s: str) -> list[str]:
    return [w for w in normalise(s).split() if w not in STOP]


def fact_of(line: str) -> str:
    s = line.strip()
    if s.startswith("- "):
        s = s[2:]
    if s.startswith("[") and "]" in s:
        s = s[s.index("]") + 1:].strip()
    return s


def date_of(line: str) -> str | None:
    m = re.search(r"\[([^\]]+)\]", line)
    return m.group(1) if m else None


class Memory:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or Paths.memory()

    def text(self) -> str:
        try:
            return self.path.read_text(encoding="utf-8")
        except OSError:
            return ""

    def lines(self) -> list[str]:
        return [l for l in self.text().split("\n") if l.strip()]

    def _write(self, s: str) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(s, encoding="utf-8")

    def append(self, facts: list[str], today: date | None = None) -> list[str]:
        seen = {normalise(fact_of(l)) for l in self.lines()}
        added = []
        for f in facts:
            t = f.strip()
            if t and normalise(t) not in seen:
                seen.add(normalise(t))
                added.append(t)
        if not added:
            return []
        out = self.text()
        if out and not out.endswith("\n"):
            out += "\n"
        d = (today or date.today()).isoformat()
        out += "".join(f"- [{d}] {a}\n" for a in added)
        self._write(out)
        return added

    def forget(self, phrase: str) -> list[str]:
        keys = keywords(phrase)
        if not keys:
            return []
        lines = self.lines()
        scored = []
        for line in lines:
            words = set(keywords(fact_of(line)))
            hit = sum(1 for k in keys if k in words or any(w.startswith(k) or (k.startswith(w) and len(w) > 3) for w in words))
            scored.append((line, hit / len(keys)))
        best = max((s for _, s in scored), default=0)
        if best < 0.6:
            return []
        doomed = {l for l, s in scored if s == best}
        keep = [l for l in lines if l not in doomed]
        self._write("\n".join(keep) + ("\n" if keep else ""))
        return [fact_of(l) for l in doomed]

    def remove(self, line: str) -> None:
        keep = [l for l in self.lines() if l != line]
        self._write("\n".join(keep) + ("\n" if keep else ""))

    def new_this_week(self, today: date | None = None) -> list[str]:
        cutoff = ((today or date.today()) - timedelta(days=7)).isoformat()
        return [l for l in self.lines() if (date_of(l) or "") > cutoff]

    def read_back(self) -> str:
        facts = [fact_of(l) for l in self.lines()]
        if not facts:
            return "I haven't learned anything about you yet, sir."
        return "Here is what I know, sir. " + " ".join(facts)


@dataclass
class Action:
    id: str
    name: str
    input: dict
    result: str
    is_error: bool = False


@dataclass
class Exchange:
    user: str
    assistant: str
    actions: list[Action] = field(default_factory=list)


class Conversation:
    """The last few exchanges, reset after five minutes of silence."""

    def __init__(self, max_exchanges: int = 8, idle_reset: float = 300) -> None:
        self.exchanges: list[Exchange] = []
        self.max_exchanges = max_exchanges
        self.idle_reset = idle_reset
        self.last_activity: float | None = None

    def add(self, user: str, assistant: str, actions: list[Action] | None = None, now: float | None = None) -> None:
        now = time.time() if now is None else now
        self.expire_if_idle(now)
        self.exchanges.append(Exchange(user, assistant, actions or []))
        self.exchanges = self.exchanges[-self.max_exchanges:]
        self.last_activity = now

    def expire_if_idle(self, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        if self.last_activity is not None and now - self.last_activity > self.idle_reset and self.exchanges:
            self.exchanges = []
            return True
        return False

    def reset(self) -> None:
        self.exchanges, self.last_activity = [], None

    def messages(self) -> list[dict]:
        """History for the next request; tool calls replayed as tool_use/tool_result pairs."""
        out: list[dict] = []
        for e in self.exchanges:
            out.append({"role": "user", "content": e.user})
            if e.actions:
                out.append({"role": "assistant", "content": [
                    {"type": "tool_use", "id": a.id, "name": a.name, "input": a.input} for a in e.actions]})
                results = []
                for a in e.actions:
                    r = {"type": "tool_result", "tool_use_id": a.id, "content": a.result}
                    if a.is_error:
                        r["is_error"] = True
                    results.append(r)
                out.append({"role": "user", "content": results})
            out.append({"role": "assistant", "content": e.assistant or "(no reply)"})
        return out

    @property
    def transcript(self) -> str:
        return "\n".join(f"User: {e.user}\nMycroft: {e.assistant}" for e in self.exchanges)
