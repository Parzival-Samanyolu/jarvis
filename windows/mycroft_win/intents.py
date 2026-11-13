"""Things the owner says that Mycroft handles locally, without a model call. Ported from Models.swift."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from . import timers as T
from .config import Mode, Persona

DEEP_THINKING = ["think deeply", "think hard", "think carefully", "deep thinking", "think this through",
                 "really think", "use your best", "deeply"]

MODELS = {"haiku": "anthropic/claude-haiku-5.5", "sonnet": "anthropic/claude-sonnet-5.5", "opus": "anthropic/claude-opus-5.5"}


def route(text: str, mode: Mode, cap_reached: bool) -> str:
    """Auto: Sonnet for everything, Opus when asked to think deeply, Haiku only once the cap is reached."""
    if cap_reached:
        return "haiku"
    if mode != Mode.auto:
        return mode.value
    return "opus" if any(p in text.lower() for p in DEEP_THINKING) else "sonnet"


@dataclass(frozen=True)
class Intent:
    kind: str           # mute stop set_mode spend what_do_you_know forget repeat timer timer_status cancel_timers persona none
    arg: object = None
    label: str = ""


NONE = Intent("none")

REPEAT = {
    "say that again", "say again", "say it again", "repeat that", "repeat", "repeat it", "repeat yourself",
    "what did you say", "what was that", "come again", "pardon", "pardon me", "sorry what", "what", "one more time",
}

PERSONA_PHRASES = {
    Persona.undercover: ["go undercover", "undercover mode", "undercover mode on", "turn on undercover mode", "undercover on"],
    Persona.butler: ["undercover mode off", "undercover off", "turn off undercover mode", "blow your cover", "drop the act",
                     "be yourself", "back to normal", "butler mode"],
    Persona.comrade: ["comrade mode"], Persona.bigBrother: ["big brother mode"], Persona.pasha: ["pasha mode", "paşa modu"],
    Persona.techSupport: ["steve mode", "tech support mode"], Persona.trump: ["trump mode"],
}


def _strip(t: str, chars: str) -> str:
    return t.strip().strip(chars)


def parse(raw: str, now: datetime | None = None) -> Intent:
    now = now or datetime.now()
    t = _strip(raw.lower(), ".!?,")
    for name in ("mycroft",):
        if t.startswith(name + ","):
            t = t[len(name) + 1:].strip()
        elif t.startswith(name + " "):
            t = t[len(name) + 1:]
    polite = t
    for p in ("sorry, ", "sorry ", "please ", "can you ", "could you ", "would you "):
        if polite.startswith(p):
            polite = polite[len(p):]
    for p in (" please", " for me", " sir"):
        if polite.endswith(p):
            polite = polite[: -len(p)]
    bare = _strip(polite, ",.?! ")
    if bare in REPEAT:
        return Intent("repeat")
    if (tm := parse_timer(polite, now)) is not None:
        return tm
    for persona, phrases in PERSONA_PHRASES.items():
        if bare in phrases:
            return Intent("persona", persona)
    if t in ("stop", "stop it", "be quiet", "quiet", "shut up", "enough"):
        return Intent("stop")
    if t in ("mute", "mute yourself", "go mute", "mute listening"):
        return Intent("mute")
    for m in Mode:
        v = m.value
        if t in (f"use {v}", f"switch to {v}", f"{v} mode", f"use {v} mode", f"go to {v}"):
            return Intent("set_mode", m)
    if t in ("use auto", "automatic mode"):
        return Intent("set_mode", Mode.auto)
    if "how much" in t and any(w in t for w in ("spent", "spend", "cost")):
        return Intent("spend")
    if "what do you know about me" in t or "what have you learned about me" in t:
        return Intent("what_do_you_know")
    for p in ("forget that i'm ", "forget that i ", "forget i ", "forget that "):
        if t.startswith(p):
            rest = t[len(p):]
            return Intent("forget", ("am " + rest) if p == "forget that i'm " else rest)
    return NONE


def parse_timer(t: str, now: datetime) -> Intent | None:
    about = any(w in t for w in ("timer", "countdown", "pomodoro", "reminder"))
    reminder = t.startswith("remind me ") or "reminder" in t
    if t in ("how long left", "how much time left", "how much time is left", "how long is left"):
        return Intent("timer_status")
    if not (about or reminder):
        return None
    found = T.duration(t)
    if found is None and reminder:
        c = T.seconds_until_clock_time(t, now)
        found = (c[0], [c[1]]) if c else None
    if found is None:
        if any(w in t for w in ("cancel", "stop", "clear", "delete", "remove", "turn off")):
            return Intent("cancel_timers")
        if any(w in t for w in ("how long", "how much", "left", "remaining")):
            return Intent("timer_status")
        return Intent("timer", 25 * 60) if "pomodoro" in t and not reminder else None
    seconds, spans = found
    if not reminder:
        return Intent("timer", seconds)
    rest = t
    for a, b in sorted(spans, reverse=True):
        rest = rest[:a] + " " + rest[b:]
    for p in ("remind me ", "reminder "):
        i = rest.find(p)
        if i >= 0:
            rest = rest[i + len(p):]
            break
    words = rest.split()
    filler = {"in", "after", "for", "and", "to", "about", "that", "i", "need", "should", "have", "of"}
    while words and words[0] in filler:
        words.pop(0)
    while words and words[-1] in ("in", "after", "for", "and"):
        words.pop()
    label = " ".join(words).strip(",. ")
    return Intent("timer", seconds, label or "check the time")


YES = [" evet ", " tamam ", " olur ", " devam ", " yes ", " yeah ", " yep ", " yup ", " proceed ", " go ahead ", " do it ",
       " sure ", " please do ", " affirmative ", " okay ", " ok ", " absolutely ", " certainly ", " da "]
NO = [" hayır ", " hayir ", " yok ", " iptal ", " dur ", " no ", " nope ", " don't ", " dont ", " do not ", " stop ",
      " cancel ", " negative ", " nah ", " never ", " nyet "]


def yes_no(raw: str) -> str:
    t = " " + "".join(c for c in raw.lower() if c.isalpha() or c in " '") + " "
    if any(w in t for w in NO):
        return "no"
    if any(w in t for w in YES):
        return "yes"
    return "unclear"


def keep_or_delete(raw: str) -> bool | None:
    t = raw.lower()
    if any(w in t for w in ("delete", "remove", "forget")):
        return False
    if any(w in t for w in ("keep", "yes", "fine", "good")):
        return True
    return None
