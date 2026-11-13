"""What Mycroft can still do without the internet. Ported from Offline.swift."""
from __future__ import annotations

import re
import socket
from dataclasses import dataclass
from datetime import datetime

from . import tools


@dataclass(frozen=True)
class OfflineAction:
    kind: str            # time date battery volume_up volume_down volume_set open note
    arg: object = None


def parse(raw: str) -> OfflineAction | None:
    original = raw.strip().strip(".!?").strip()
    t = original.lower()
    if t.startswith("mycroft"):
        t = t[len("mycroft"):].lstrip(", ")
    for p in ("please ", "can you ", "could you "):
        if t.startswith(p):
            t = t[len(p):]
    for p in ("make a note that ", "make a note ", "take a note that ", "take a note ", "note that ", "note down ", "write down "):
        if t.startswith(p):
            rest = original[len(original) - (len(t) - len(p)):].strip()
            return OfflineAction("note", rest) if rest else None
    if "battery" in t:
        return OfflineAction("battery")
    if "what time" in t or t == "time" or t.endswith("the time"):
        return OfflineAction("time")
    if any(w in t for w in ("what day", "the date", "what's today", "today's date")):
        return OfflineAction("date")
    if any(w in t for w in ("volume", "louder", "quieter")) or t.startswith("turn it "):
        if m := re.search(r"\d{1,3}", t):
            return OfflineAction("volume_set", min(int(m.group()), 100))
        if any(w in t for w in ("up", "louder", "raise", "increase")):
            return OfflineAction("volume_up")
        if any(w in t for w in ("down", "quieter", "lower", "decrease")):
            return OfflineAction("volume_down")
        return None
    for p in ("open ", "launch ", "start "):
        if t.startswith(p):
            app = t[len(p):]
            for s in (" for me", " app", " application"):
                if app.endswith(s):
                    app = app[: -len(s)]
            app = app.strip()
            return OfflineAction("open", " ".join(w.capitalize() for w in app.split())) if app else None
    return None


def perform(a: OfflineAction, now: datetime | None = None) -> str:
    now = now or datetime.now()
    if a.kind == "time":
        return f"It's {now.strftime('%I:%M %p').lstrip('0').lower()}, sir."
    if a.kind == "date":
        return f"It's {now.strftime('%A')} {now.day} {now.strftime('%B')}, sir."
    if a.kind == "battery":
        b = tools.battery()
        if not b:
            return "I can't read the battery, sir. This may be a desktop."
        return f"The battery is at {b[0]} percent, sir{', and on the mains' if b[1] else ''}."
    if a.kind in ("volume_up", "volume_down", "volume_set"):
        msg, failed = tools.media("set_volume" if a.kind == "volume_set" else a.kind, a.arg if a.kind == "volume_set" else None)
        if failed:
            return "The volume refuses to cooperate, sir."
        v = tools.get_volume()
        return f"Volume at {v} percent, sir." if v is not None else "Done, sir."
    if a.kind == "open":
        msg, failed = tools.open_target(str(a.arg))
        return f"I can't find an app called {a.arg}, sir." if failed else f"Opening {a.arg}, sir."
    if a.kind == "note":
        tools.note_save(str(a.arg))
        return "Noted, sir."
    return "Very good, sir."


def is_online(timeout: float = 1.5) -> bool:
    """Cheap check: can we open a socket to OpenRouter (or a public DNS server)?"""
    for host, port in (("openrouter.ai", 443), ("1.1.1.1", 53)):
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return True
        except OSError:
            continue
    return False
