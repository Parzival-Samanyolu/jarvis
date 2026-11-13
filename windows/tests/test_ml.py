"""The real "Hey Mycroft" model on synthetic speech. Silent: macOS `say -o` writes files without playing them.

Skipped unless the models are in MYCROFT_TEST_MODELS (the Mac app's models folder works) and `say` exists.
"""
import os
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

MODELS = Path(os.environ.get("MYCROFT_TEST_MODELS", Path.home() / "Library/Application Support/Mycroft/models"))
pytestmark = pytest.mark.skipif(not (MODELS / "hey_mycroft_v0.1.onnx").exists() or not shutil.which("say"),
                                reason="wake-word models or say not available")


def synth(text, voice, tmp):
    out = tmp / f"{voice}.wav"
    subprocess.run(["say", "-v", voice, "-o", str(out), "--data-format=LEI16@16000", text], check=True)
    import wave
    with wave.open(str(out)) as w:
        pcm = np.frombuffer(w.readframes(w.getnframes()), np.int16)
    return pcm.astype(np.float32) / 32768


def fires(detector, audio):
    padded = np.concatenate([np.zeros(16000, np.float32), audio, np.zeros(16000, np.float32)])
    return any(detector.feed(padded[i:i + 1280]) for i in range(0, len(padded) - 1280, 1280))


def test_wake_word(tmp_path):
    from mycroft_win.audio import WakeDetector
    hits = 0
    for v in ("Daniel", "Samantha", "Karen"):
        d = WakeDetector(MODELS)
        hits += fires(d, synth("Hey Mycroft", v, tmp_path))
    assert hits >= 2
    d = WakeDetector(MODELS)
    assert not fires(d, synth("I bought a new Microsoft keyboard yesterday.", "Daniel", tmp_path))


def test_speech_to_text_english_and_turkish(tmp_path):
    from mycroft_win.audio import Transcriber, whisper_path
    try:
        whisper_path()
    except Exception:
        pytest.skip("whisper model not downloaded (scripts/fetch_models.py)")
    t = Transcriber()
    heard = t.transcribe(synth("Set a timer for five minutes.", "Daniel", tmp_path), "en").lower()
    assert "timer" in heard and ("five" in heard or "5" in heard), heard
    turkish = [v for v in ("Yelda", "Cem") if subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout.find(v) >= 0]
    if turkish:
        heard = t.transcribe(synth("Bugün hava nasıl?", turkish[0], tmp_path), None).lower()
        assert "hava" in heard
