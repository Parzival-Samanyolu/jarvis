"""Trump mode speaks only real recordings kept in %USERPROFILE%\\Mycroft\\trump (quiet-piggy.mp3, wrong.wav, ...)."""
from __future__ import annotations

import re
from pathlib import Path

from .config import Paths

FALLBACK = "quiet-piggy"
# Formats the player can decode (m4a/AAC can't: convert with scripts/convert-trump-clips.sh).
EXTENSIONS = (".mp3", ".wav", ".flac", ".ogg")

MEANINGS = {
    "quiet-piggy": '"Quiet, quiet, piggy." The default for anything without a better fit',
    "wrong": '"Wrong!" for something false or a failure',
    "fake-news": '"Fake news" for a doubtful claim, bad news, or a failure',
    "tremendous": '"Tremendous" for a task done well',
    "believe-me": '"Believe me" for agreeing or promising',
    "so-complicated": '"Nobody knew it could be so complicated" for something hard or failed',
    "person-woman-man": '"Person, woman, man, camera, TV" for remembering or memory',
    "stable-genius": '"I\'m a very stable genius" for showing off',
    "concepts-of-a-plan": '"I have concepts of a plan" for plans or not knowing how',
    "swear": "A real moment where he swears. Use it rarely, for something really messed up",
    "thank-you": '"Thank you" for thanks, goodbyes, or done',
    "you-are-fired": '"You\'re fired" for cancelling, stopping, or goodbye',
    "maga": '"Make America great again" for hello, starting, or a big win',
}


def available(folder: Path | None = None) -> list[str]:
    folder = folder or Paths.trump()
    try:
        return sorted({p.stem for p in folder.iterdir() if p.suffix.lower() in EXTENSIONS})
    except OSError:
        return []


def name_for(text: str, clips: list[str]) -> str | None:
    """The clip a line means ("Tremendous." -> tremendous); anything else -> quiet-piggy. None if no clips at all."""
    key = re.sub(r"[^a-z0-9 \-]", "", text.lower()).strip()
    key = re.sub(r"[ \-]+", "-", key)
    if key in clips:
        return key
    if FALLBACK in clips:
        return FALLBACK
    return clips[0] if clips else None


def file_for(name: str, folder: Path | None = None) -> Path | None:
    folder = folder or Paths.trump()
    for ext in EXTENSIONS:
        p = folder / f"{name}{ext}"
        if p.exists():
            return p
    return None
