"""Countdown timers and reminders, saved to disk so a restart doesn't lose them. Ported from Timers.swift."""
from __future__ import annotations

import json
import re
import threading
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable

LATE_LIMIT = 12 * 3600


def spoken(seconds: int, plural: bool = True) -> str:
    """1500 -> "25 minutes", 5400 -> "1 hour and 30 minutes". plural=False: "your 25 minute timer"."""
    h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60

    def unit(n: int, word: str) -> str:
        return f"{n} {word}{'s' if plural and n != 1 else ''}"

    parts = []
    if h:
        parts.append(unit(h, "hour"))
    if m:
        parts.append(unit(m, "minute"))
    if s and not h:
        parts.append(unit(s, "second"))
    return " and ".join(parts) if parts else unit(0, "second")


@dataclass(frozen=True)
class Item:
    id: int
    seconds: int
    label: str
    ends: float  # unix time

    @property
    def announcement(self) -> str:
        if not self.label:
            return f"Sir, your {spoken(self.seconds, plural=False)} timer is up."
        return f"Sir, you asked me to remind you to {self.label}."


class Timers:
    def __init__(self, file: Path | None = None) -> None:
        self.file = file
        self.on_fire: Callable[[Item], None] | None = None
        self._lock = threading.Lock()
        self._items: dict[int, tuple[Item, threading.Timer]] = {}
        self._next = 1

    def restore(self, now: float | None = None) -> None:
        """Schedules saved timers; ones that ended while Mycroft was closed (within 12 h) fire at once."""
        now = time.time() if now is None else now
        if not self.file:
            return
        try:
            saved = [Item(**d) for d in json.loads(self.file.read_text(encoding="utf-8"))]
        except (OSError, ValueError, TypeError):
            return
        with self._lock:
            for it in saved:
                if it.ends > now - LATE_LIMIT:
                    self._next = max(self._next, it.id + 1)
                    self._schedule(it, now)
        self._save()

    def _schedule(self, item: Item, now: float) -> None:
        def fire() -> None:
            with self._lock:
                if self._items.pop(item.id, None) is None:
                    return
            self._save()
            if self.on_fire:
                self.on_fire(item)

        t = threading.Timer(max(0.0, item.ends - now), fire)
        t.daemon = True
        self._items[item.id] = (item, t)
        t.start()

    def _save(self) -> None:
        if not self.file:
            return
        self.file.parent.mkdir(parents=True, exist_ok=True)
        self.file.write_text(json.dumps([asdict(i) for i in self.active()]), encoding="utf-8")

    def active(self) -> list[Item]:
        with self._lock:
            return sorted((v[0] for v in self._items.values()), key=lambda i: i.ends)

    def start(self, seconds: int, label: str = "", now: float | None = None) -> Item:
        now = time.time() if now is None else now
        with self._lock:
            item = Item(self._next, seconds, label, now + seconds)
            self._next += 1
            self._schedule(item, now)
        self._save()
        return item

    def cancel_all(self) -> int:
        with self._lock:
            n = len(self._items)
            for _, t in self._items.values():
                t.cancel()
            self._items = {}
        self._save()
        return n

    def status(self, now: float | None = None) -> str:
        now = time.time() if now is None else now
        items = self.active()
        if not items:
            return "There's no timer running, sir."
        out = []
        for i in items:
            left = spoken(max(1, round(i.ends - now)))
            if i.label:
                out.append(f"{left[0].upper() + left[1:]} until I remind you to {i.label}, sir.")
            else:
                out.append(f"Your {spoken(i.seconds, plural=False)} timer has {left} left, sir.")
        return " ".join(out)


NUMBER_WORDS = {
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "twenty five": 25, "twenty-five": 25,
    "thirty": 30, "forty": 40, "forty five": 45, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
}
_WORDS = "|".join(sorted(NUMBER_WORDS, key=len, reverse=True))
_DURATION = re.compile(r"\b(\d+|" + _WORDS + r")\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b")
_CLOCK = re.compile(r"\bat (\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?|o'clock)?(?=\W|$)")


def duration(t: str) -> tuple[int, list[tuple[int, int]]] | None:
    """Total seconds of every "25 minutes", "an hour", "half an hour" in t (lowercase) and the spans they cover."""
    total, spans = 0, []
    for phrase, secs in (("an hour and a half", 5400), ("half an hour", 1800), ("a minute and a half", 90)):
        i = t.find(phrase)
        if i >= 0:
            total += secs
            spans.append((i, i + len(phrase)))
    for m in _DURATION.finditer(t):
        if any(a < m.end() and m.start() < b for a, b in spans):
            continue
        n = int(m.group(1)) if m.group(1).isdigit() else NUMBER_WORDS.get(m.group(1), 0)
        u = m.group(2)
        total += n * (3600 if u.startswith("h") else 60 if u.startswith("m") else 1)
        spans.append(m.span())
    return (total, spans) if total > 0 else None


def seconds_until_clock_time(t: str, now: datetime) -> tuple[int, tuple[int, int]] | None:
    """ "at 6", "at 6pm", "at 18:30". Without am/pm, the next time the clock shows it."""
    m = _CLOCK.search(t)
    if not m:
        return None
    h = int(m.group(1))
    minute = int(m.group(2) or 0)
    if h >= 24 or minute >= 60:
        return None
    suffix = (m.group(3) or "").replace(".", "")
    if suffix == "pm" and h < 12:
        h += 12
    if suffix == "am" and h == 12:
        h = 0
    hours = [h] if suffix.endswith("m") or h > 12 or h == 0 else [h, (h + 12) % 24]
    best = None
    for hour in hours:
        cand = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if cand <= now:
            cand += timedelta(days=1)
        best = cand if best is None or cand < best else best
    return round((best - now).total_seconds()), m.span()
