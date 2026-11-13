"""The microphone, end-of-speech detection, "Hey Mycroft" and speech-to-text.

One input stream runs while Mycroft is unmuted. Its 80 ms chunks go to the wake-word detector while
idle and to the recorder during a conversation, so nothing said straight after "Hey Mycroft" is lost.
"""
from __future__ import annotations

import logging
import queue
import re
import threading
import time
from pathlib import Path
from typing import Callable

import numpy as np

from .config import Paths

log = logging.getLogger("mycroft")
RATE = 16000
CHUNK = 1280            # 80 ms, what openWakeWord wants
FRAME = 320             # 20 ms, for the endpoint detector


class EndpointDetector:
    """Energy-based end of speech. Feed 20 ms RMS values. Ported from Audio.swift."""

    def __init__(self, start_timeout: float, end_silence: float = 1.2, max_duration: float = 40,
                 min_speech: float = 0.18, calibration: float = 0.3) -> None:
        self.start_timeout, self.end_silence, self.max_duration = start_timeout, end_silence, max_duration
        self.min_speech, self.calibration = min_speech, calibration
        self.elapsed = self.speech = self.silence = self.cal_sum = 0.0
        self.cal_n = 0
        self.started = False

    @property
    def threshold(self) -> float:
        floor = self.cal_sum / self.cal_n if self.cal_n else 0.0
        return max(0.015, min(floor, 0.02) * 3)

    def feed(self, rms: float) -> str:
        """'waiting', 'speaking', 'done' (had speech) or 'nothing' (nobody spoke)."""
        dt = FRAME / RATE
        self.elapsed += dt
        if self.elapsed <= self.calibration:
            self.cal_sum += rms
            self.cal_n += 1
            return "waiting"
        loud = rms > self.threshold
        if not self.started:
            self.speech = self.speech + dt if loud else 0.0
            if self.speech >= self.min_speech:
                self.started = True
                return "speaking"
            return "nothing" if self.elapsed >= self.start_timeout else "waiting"
        self.silence = 0.0 if loud else self.silence + dt
        if self.silence >= self.end_silence or self.elapsed >= self.max_duration:
            return "done"
        return "speaking"


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(x)))) if len(x) else 0.0


def voiced_seconds(samples: np.ndarray) -> float:
    n = len(samples) // FRAME
    return sum(1 for i in range(n) if rms(samples[i * FRAME:(i + 1) * FRAME]) > 0.015) * FRAME / RATE


class _Recording:
    def __init__(self, start_timeout: float, end_silence: float, calibrate: bool) -> None:
        self.det = EndpointDetector(start_timeout, end_silence, calibration=0.3 if calibrate else 0.0)
        self.chunks: list[np.ndarray] = []
        self.done = threading.Event()
        self.had_speech = False

    def feed(self, chunk: np.ndarray) -> None:
        if self.done.is_set():
            return
        self.chunks.append(chunk)
        for i in range(0, len(chunk), FRAME):
            ev = self.det.feed(rms(chunk[i:i + FRAME]))
            if ev in ("done", "nothing"):
                self.had_speech = ev == "done"
                self.done.set()
                return


class Mic:
    """Owns the input stream; hands chunks to the wake detector and the current recording."""

    def __init__(self) -> None:
        self._stream = None
        self._q: queue.Queue[np.ndarray] = queue.Queue(maxsize=200)
        self._rec: _Recording | None = None
        self._lock = threading.Lock()
        self.wake: WakeDetector | None = None
        self.wake_enabled = False
        self.on_wake: Callable[[], None] | None = None
        self.level = 0.0
        self._rate = RATE
        self._start_lock = threading.Lock()
        self.error: str | None = None
        self._worker = threading.Thread(target=self._loop, name="mic", daemon=True)
        self._worker.start()

    @property
    def running(self) -> bool:
        return self._stream is not None

    def start(self) -> bool:
        with self._start_lock:   # called from the loop and from recording threads
            return self._start()

    def _start(self) -> bool:
        if self._stream is not None:
            return True
        try:
            import sounddevice as sd
            try:
                sd.check_input_settings(samplerate=RATE, channels=1, dtype="float32")
                self._rate = RATE
            except Exception:   # some devices only take their own rate: record at that and resample
                self._rate = int(sd.query_devices(kind="input")["default_samplerate"])
            self._stream = sd.InputStream(samplerate=self._rate, channels=1, dtype="float32",
                                          blocksize=int(CHUNK * self._rate / RATE), callback=self._callback)
            self._stream.start()
            self.error = None
            return True
        except Exception as e:
            log.error("could not open the microphone: %s", e)
            self.error = str(e)
            self._stream = None
            return False

    def stop(self) -> None:
        with self._start_lock:
            s, self._stream = self._stream, None
        if s is not None:
            try:
                s.stop()
                s.close()
            except Exception:
                pass
        self.cancel()

    def _callback(self, indata, frames, t, status) -> None:
        x = indata[:, 0].copy()
        if self._rate != RATE:
            x = np.interp(np.linspace(0, len(x) - 1, CHUNK), np.arange(len(x)), x).astype(np.float32)
        try:
            self._q.put_nowait(x)
        except queue.Full:
            pass

    def feed(self, chunk: np.ndarray) -> None:
        """For tests: push audio as if the mic heard it."""
        self._handle(chunk)

    def _loop(self) -> None:
        while True:
            self._handle(self._q.get())

    def _handle(self, chunk: np.ndarray) -> None:
        self.level = rms(chunk)
        with self._lock:
            rec = self._rec
        if rec is not None:
            rec.feed(chunk)
            return
        if self.wake_enabled and self.wake is not None:
            try:
                if self.wake.feed(chunk) and self.on_wake:
                    self.on_wake()
            except Exception as e:
                log.error("wake word failed: %s", e)
                self.wake_enabled = False

    def record(self, start_timeout: float, end_silence: float, calibrate: bool = True,
               cancel: threading.Event | None = None) -> np.ndarray | None:
        """Blocks until the owner stops talking. None if nobody spoke (or cancelled)."""
        if not self.start():
            return None
        rec = _Recording(start_timeout, end_silence, calibrate)
        with self._lock:
            self._rec = rec
        try:
            while not rec.done.wait(0.05):
                if cancel is not None and cancel.is_set():
                    return None
                if self._stream is None:
                    return None
        finally:
            with self._lock:
                if self._rec is rec:
                    self._rec = None
            if self.wake:
                self.wake.reset()
        if not rec.had_speech:
            return None
        return np.concatenate(rec.chunks) if rec.chunks else None

    def cancel(self) -> None:
        with self._lock:
            rec, self._rec = self._rec, None
        if rec:
            rec.done.set()


def model_dir() -> Path:
    from .config import Paths as P
    return P.bundled_models() or P.models()


class WakeDetector:
    """openWakeWord's "hey_mycroft" model on onnxruntime."""
    THRESHOLD = 0.5
    COOLDOWN = 2.0

    def __init__(self, folder: Path | None = None) -> None:
        from openwakeword.model import Model
        d = folder or ensure_wake_models()
        wake = next(iter(sorted(d.glob("hey_mycroft*.onnx"))))
        self.model = Model(wakeword_models=[str(wake)], inference_framework="onnx",
                           melspec_model_path=str(d / "melspectrogram.onnx"),
                           embedding_model_path=str(d / "embedding_model.onnx"))
        self.last = 0.0

    def feed(self, chunk: np.ndarray) -> bool:
        pcm = np.clip(chunk * 32767, -32768, 32767).astype(np.int16)
        scores = self.model.predict(pcm)
        score = max(scores.values()) if scores else 0.0
        now = time.monotonic()
        if score >= self.THRESHOLD and now - self.last >= self.COOLDOWN:
            self.last = now
            self.model.reset()
            return True
        return False

    def reset(self) -> None:
        try:
            self.model.reset()
        except Exception:
            pass


def ensure_wake_models() -> Path:
    for d in (Paths.bundled_models(), Paths.models()):
        if d and list(d.glob("hey_mycroft*.onnx")) and (d / "melspectrogram.onnx").exists():
            return d
    d = Paths.models()
    d.mkdir(parents=True, exist_ok=True)
    from openwakeword import utils
    utils.download_models(["hey_mycroft"], target_directory=str(d))
    return d


# MARK: Speech to text

_BLANK = re.compile(r"^\s*[\[(].*?[\])]\s*$")
# "Minecraft, open YouTube" means Mycroft; "Open Minecraft" is left alone.
_NAME_FIX = re.compile(r"^(minecraft|microsoft|my craft|mike roft|my kraft|microft),", re.I)


def clean_transcript(text: str) -> str:
    t = " ".join(text.split())
    if _BLANK.match(t):
        return ""
    return _NAME_FIX.sub("Mycroft,", t).strip()


class Transcriber:
    """faster-whisper, multilingual base model: English normally, Turkish too for the Pasha."""

    def __init__(self) -> None:
        self.model = None
        self.error: str | None = None
        self._lock = threading.Lock()

    def prepare(self) -> bool:
        with self._lock:
            if self.model is not None:
                return True
            try:
                from faster_whisper import WhisperModel
                path = whisper_path()
                self.model = WhisperModel(str(path), device="cpu", compute_type="int8")
                return True
            except Exception as e:
                self.error = str(e)
                log.error("speech recognition unavailable: %s", e)
                return False

    def transcribe(self, audio: np.ndarray, language: str | None = "en") -> str:
        if voiced_seconds(audio) < 0.25 or not self.prepare():
            return ""
        segments, _ = self.model.transcribe(audio.astype(np.float32), language=language, beam_size=1,
                                            initial_prompt="Mycroft", condition_on_previous_text=False,
                                            vad_filter=False)
        return clean_transcript(" ".join(s.text for s in segments))


def whisper_path() -> Path:
    for d in (Paths.bundled_models(), Paths.models()):
        if d and (d / "whisper-base" / "model.bin").exists():
            return d / "whisper-base"
    from faster_whisper import download_model
    out = Paths.models() / "whisper-base"
    out.mkdir(parents=True, exist_ok=True)
    return Path(download_model("base", output_dir=str(out)))
