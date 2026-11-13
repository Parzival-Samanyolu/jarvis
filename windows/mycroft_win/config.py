"""Where things live, the small key/value store, and the owner's settings."""
from __future__ import annotations

import json
import os
import sys
import threading
from enum import Enum
from pathlib import Path

IS_WINDOWS = sys.platform == "win32"


class Paths:
    """%APPDATA%\\Mycroft for data, %LOCALAPPDATA%\\Mycroft\\Logs for logs. MYCROFT_HOME puts both in one folder."""

    @staticmethod
    def _override() -> Path | None:
        v = os.environ.get("MYCROFT_HOME")
        return Path(v) if v else None

    @classmethod
    def dir(cls) -> Path:
        if o := cls._override():
            return o
        base = os.environ.get("APPDATA") if IS_WINDOWS else None
        return Path(base) / "Mycroft" if base else Path.home() / ".mycroft-win"

    @classmethod
    def logs(cls) -> Path:
        if o := cls._override():
            return o
        base = os.environ.get("LOCALAPPDATA") if IS_WINDOWS else None
        return Path(base) / "Mycroft" / "Logs" if base else cls.dir() / "logs"

    @classmethod
    def memory(cls) -> Path: return cls.dir() / "memory.md"
    @classmethod
    def usage(cls) -> Path: return cls.dir() / "usage.jsonl"
    @classmethod
    def state(cls) -> Path: return cls.dir() / "state.json"
    @classmethod
    def timers(cls) -> Path: return cls.dir() / "timers.json"
    @classmethod
    def models(cls) -> Path: return cls.dir() / "models"
    @classmethod
    def command_log(cls) -> Path: return cls.logs() / "commands.log"
    @classmethod
    def conversation_log(cls) -> Path: return cls.logs() / "conversation.log"
    @classmethod
    def error_log(cls) -> Path: return cls.logs() / "mycroft.log"

    @staticmethod
    def notes() -> Path:
        if o := Paths._override():
            return o / "notes"
        return Path.home() / "Documents" / "Mycroft Notes"

    @staticmethod
    def trump() -> Path:
        if o := Paths._override():
            return o / "trump"
        return Path.home() / "Mycroft" / "trump"

    @staticmethod
    def bundled_models() -> Path | None:
        """Models shipped inside the installed app (PyInstaller puts data next to the exe)."""
        base = getattr(sys, "_MEIPASS", None)
        p = Path(base) / "models" if base else Path(__file__).resolve().parent.parent / "build" / "models"
        return p if p.exists() else None


class State:
    """Tiny JSON key/value store (state.json). Thread-safe."""
    _lock = threading.Lock()

    @classmethod
    def _load(cls) -> dict[str, str]:
        try:
            d = json.loads(Paths.state().read_text(encoding="utf-8"))
            return d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    @classmethod
    def get(cls, key: str) -> str | None:
        with cls._lock:
            v = cls._load().get(key)
        return v if isinstance(v, str) else None

    @classmethod
    def set(cls, key: str, value: str) -> None:
        with cls._lock:
            d = cls._load()
            d[key] = value
            Paths.dir().mkdir(parents=True, exist_ok=True)
            tmp = Paths.state().with_suffix(".tmp")
            tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
            os.replace(tmp, Paths.state())


class Humour(str, Enum):
    often = "often"
    normal = "normal"
    rare = "rare"
    off = "off"

    @property
    def label(self) -> str:
        return {"often": "Every reply", "normal": "Every other reply", "rare": "Rarely", "off": "Never"}[self.value]

    @property
    def instruction(self) -> str:
        return {
            "often": "Add a dry joke to almost every reply, after the answer.",
            "normal": "Not every reply needs a joke; roughly every other reply is right.",
            "rare": "Joke only occasionally, about one reply in five. Otherwise be crisp and helpful.",
            "off": "Humour is switched off: no jokes or quips at all. Stay polite, formal and brief.",
        }[self.value]

    @property
    def casual_instruction(self) -> str:
        return {
            "often": "Add a light, friendly joke to most replies, after the answer.",
            "normal": "A light joke now and then is great; roughly every other reply.",
            "rare": "Joke only occasionally. Otherwise be quick and helpful.",
            "off": "No jokes: keep it friendly, warm and brief.",
        }[self.value]


class Persona(str, Enum):
    butler = "butler"
    undercover = "undercover"
    comrade = "comrade"
    bigBrother = "bigBrother"
    pasha = "pasha"
    techSupport = "techSupport"
    trump = "trump"

    @property
    def label(self) -> str:
        return {"butler": "Butler", "undercover": "Undercover", "comrade": "Comrade", "bigBrother": "Big Brother",
                "pasha": "Pasha", "techSupport": "Tech Support", "trump": "Trump"}[self.value]

    @property
    def blurb(self) -> str:
        return {
            "butler": "British butler, dry wit",
            "undercover": "American voice, friendly and casual, no politics",
            "comrade": "The Party's proud propaganda man, Russian accent",
            "bigBrother": "Orwell's Ministry of Truth announcer, 1984",
            "pasha": "A grand Ottoman Pasha, speaks Turkish and understands Turkish",
            "techSupport": "Steve, the meme tech-support scammer: hacked computer, gift cards, DO NOT REDEEM",
            "trump": "Only real Donald J. Trump clips from Mycroft\\trump. Nothing fits? Quiet, piggy",
        }[self.value]

    @property
    def address(self) -> str:
        """What the owner is called in fixed lines ("sir" is swapped for this)."""
        return {"butler": "sir", "undercover": "", "comrade": "comrade", "bigBrother": "citizen",
                "pasha": "evladım", "techSupport": "sir", "trump": ""}[self.value]


class Mode(str, Enum):
    auto = "auto"
    haiku = "haiku"
    sonnet = "sonnet"
    opus = "opus"

    @property
    def label(self) -> str:
        return self.value.capitalize()


class Settings:
    """The owner's settings, kept in state.json. Anything unset keeps the default."""
    persona_override: Persona | None = None   # set by tests

    @staticmethod
    def _bool(key: str, fallback: bool) -> bool:
        v = State.get(key)
        return fallback if v is None else v == "on"

    @staticmethod
    def _set_bool(key: str, v: bool) -> None:
        State.set(key, "on" if v else "off")

    @classmethod
    def persona(cls) -> Persona:
        if cls.persona_override:
            return cls.persona_override
        try:
            return Persona(State.get("persona") or "butler")
        except ValueError:
            return Persona.butler

    @classmethod
    def set_persona(cls, p: Persona) -> None: State.set("persona", p.value)

    @classmethod
    def humour(cls) -> Humour:
        try:
            return Humour(State.get("humour") or "normal")
        except ValueError:
            return Humour.normal

    @classmethod
    def mode(cls) -> Mode:
        try:
            return Mode(State.get("mode") or "auto")
        except ValueError:
            return Mode.auto

    @classmethod
    def city(cls) -> str:
        v = (State.get("city") or "").strip()
        return v or "Konya, Turkey"

    @classmethod
    def city_name(cls) -> str: return cls.city().split(",")[0].strip()

    @classmethod
    def cap(cls) -> float:
        try:
            return max(1.0, float(State.get("cap") or "20"))
        except ValueError:
            return 20.0

    @classmethod
    def end_silence(cls) -> float:
        try:
            return min(max(float(State.get("endSilence") or "1.2"), 0.5), 3.0)
        except ValueError:
            return 1.2

    @classmethod
    def owner_name(cls) -> str: return (State.get("ownerName") or "").strip()

    follow_up = classmethod(lambda cls: cls._bool("followUp", True))
    opening_line = classmethod(lambda cls: cls._bool("openingLine", True))
    shutdown_line = classmethod(lambda cls: cls._bool("shutdownLine", True))
    briefing = classmethod(lambda cls: cls._bool("briefing", True))
    wake_word = classmethod(lambda cls: cls._bool("wakeWord", True))
    online_voices = classmethod(lambda cls: cls._bool("onlineVoices", True))

    @classmethod
    def undercover(cls) -> bool: return cls.persona() == Persona.undercover
