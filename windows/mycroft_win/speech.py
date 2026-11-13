"""Speaking: Microsoft online neural voices (edge-tts), Windows SAPI when offline, and Trump mode's real clips.

Lines are queued and played in order. While one line plays the next is already being synthesised, so
sentences follow each other without a gap. stop() silences everything at once (hotkey, "Hey Mycroft").
"""
from __future__ import annotations

import asyncio
import logging
import queue
import threading
import time
from dataclasses import dataclass

from . import trump
from .config import IS_WINDOWS, Persona, Settings

log = logging.getLogger("mycroft")


@dataclass(frozen=True)
class Voice:
    edge: str            # edge-tts voice
    rate: str = "+0%"
    pitch: str = "+0Hz"
    sapi_lang: str = "en-GB"   # offline fallback: a Windows voice of this language, if installed


VOICES = {
    Persona.butler: Voice("en-GB-RyanNeural", sapi_lang="en-GB"),
    Persona.undercover: Voice("en-US-AndrewNeural", sapi_lang="en-US"),
    Persona.comrade: Voice("ru-RU-SvetlanaNeural", rate="-12%", sapi_lang="ru-RU"),
    Persona.bigBrother: Voice("en-GB-ThomasNeural", rate="-6%", pitch="-12Hz", sapi_lang="en-GB"),
    Persona.pasha: Voice("tr-TR-AhmetNeural", sapi_lang="tr-TR"),
    Persona.techSupport: Voice("en-IN-PrabhatNeural", rate="+8%", sapi_lang="en-IN"),
    Persona.trump: Voice("en-US-GuyNeural", sapi_lang="en-US"),   # only the plain safety question
}


def voice_for(p: Persona | None = None) -> Voice:
    return VOICES[p or Settings.persona()]


@dataclass
class _Item:
    gen: int
    text: str
    plain: bool
    voice: Voice
    persona: Persona


class Speaker:
    """Thread-safe speech queue. muted=True plays nothing (tests)."""
    SAMPLE_RATE = 24000

    def __init__(self, muted: bool = False) -> None:
        self.muted = muted
        self._gen = 0
        self._pending = 0
        self._cv = threading.Condition()
        self._text_q: queue.Queue[_Item] = queue.Queue()
        self._audio_q: queue.Queue[tuple[int, object]] = queue.Queue()
        self._stop = threading.Event()
        self.on_speaking: callable | None = None   # called with True/False
        self.spoken: list[str] = []                # what was queued, for tests and the log
        self._sapi = None
        self._edge_down_until = 0.0   # after an online-voice failure, use Windows voices for a minute
        self._out_rate: int | None = None
        threading.Thread(target=self._synth_loop, name="speech-synth", daemon=True).start()
        threading.Thread(target=self._play_loop, name="speech-play", daemon=True).start()

    # MARK: Public

    def enqueue(self, text: str, plain: bool = False) -> None:
        t = text.strip()
        if not t:
            return
        p = Settings.persona()
        with self._cv:
            self._pending += 1
            gen = self._gen
        self.spoken.append(t)
        self._text_q.put(_Item(gen, t, plain, voice_for(p), p))

    def stop(self) -> None:
        with self._cv:
            self._gen += 1
            self._pending = 0
            self._cv.notify_all()
        self._stop.set()
        for q in (self._text_q, self._audio_q):
            try:
                while True:
                    q.get_nowait()
            except queue.Empty:
                pass
        self._set_speaking(False)

    @property
    def is_speaking(self) -> bool:
        with self._cv:
            return self._pending > 0

    def drain_sync(self, timeout: float | None = None) -> None:
        with self._cv:
            self._cv.wait_for(lambda: self._pending == 0, timeout=timeout)

    async def drain(self) -> None:
        await asyncio.to_thread(self.drain_sync)

    async def speak(self, text: str, plain: bool = False) -> None:
        self.enqueue(text, plain)
        await self.drain()

    # MARK: Workers

    def _done_one(self, gen: int) -> None:
        with self._cv:
            if gen != self._gen:
                return
            self._pending = max(0, self._pending - 1)
            if self._pending == 0:
                self._cv.notify_all()
                idle = True
            else:
                idle = False
        if idle:
            self._set_speaking(False)

    def _current(self, gen: int) -> bool:
        with self._cv:
            return gen == self._gen

    def _synth_loop(self) -> None:
        loop = asyncio.new_event_loop()
        while True:
            item = self._text_q.get()
            if not self._current(item.gen):
                continue
            if self.muted:
                self._audio_q.put((item.gen, None))
                continue
            audio: object = None
            try:
                clips = trump.available() if item.persona == Persona.trump else []
                if item.persona == Persona.trump and not item.plain and clips:
                    name = trump.name_for(item.text, clips)
                    path = trump.file_for(name) if name else None
                    audio = _decode_file(path) if path else None
                elif Settings.online_voices() and time.monotonic() >= self._edge_down_until:
                    audio = loop.run_until_complete(asyncio.wait_for(_edge(item.text, item.voice), timeout=8))
            except Exception as e:   # offline, edge-tts changed, decoder missing
                log.warning("online voice failed: %s", e)
                self._edge_down_until = time.monotonic() + 60
                audio = None
            if audio is None:
                audio = ("sapi", item.text, item.voice.sapi_lang)
            self._audio_q.put((item.gen, audio))

    def _play_loop(self) -> None:
        while True:
            gen, audio = self._audio_q.get()
            self._stop.clear()
            if not self._current(gen):   # checked after clearing, so a stop() in between still wins
                continue
            if audio is not None and not self.muted:
                self._set_speaking(True)
                try:
                    if isinstance(audio, tuple) and audio and audio[0] == "sapi":
                        self._play_sapi(audio[1], audio[2])
                    else:
                        self._play_pcm(audio)
                except Exception as e:
                    log.warning("playback failed: %s", e)
            self._done_one(gen)

    def _set_speaking(self, on: bool) -> None:
        if self.on_speaking:
            try:
                self.on_speaking(on)
            except Exception:
                pass

    def _open_output(self):
        """24 kHz if the device takes it, otherwise its own rate (the audio is resampled)."""
        import sounddevice as sd
        if self._out_rate is None:
            try:
                sd.check_output_settings(samplerate=self.SAMPLE_RATE, channels=1, dtype="int16")
                self._out_rate = self.SAMPLE_RATE
            except Exception:
                self._out_rate = int(sd.query_devices(kind="output")["default_samplerate"])
        return sd.OutputStream(samplerate=self._out_rate, channels=1, dtype="int16")

    def _play_pcm(self, pcm) -> None:
        if self._out_rate is None:
            self._open_output().close()
        if self._out_rate != self.SAMPLE_RATE:
            pcm = resample(pcm, self.SAMPLE_RATE, self._out_rate)
        with self._open_output() as out:
            step = self._out_rate // 10
            for i in range(0, len(pcm), step):
                if self._stop.is_set():
                    out.abort()
                    return
                out.write(pcm[i:i + step])

    def _play_sapi(self, text: str, lang: str) -> None:
        if not IS_WINDOWS:
            log.info("(would say) %s", text)
            return
        import pythoncom
        import win32com.client
        pythoncom.CoInitialize()
        if self._sapi is None:
            self._sapi = win32com.client.Dispatch("SAPI.SpVoice")
        v = self._sapi
        try:
            for tok in v.GetVoices():
                if lang.lower() in tok.GetAttribute("Language").lower() or _sapi_lang_match(tok, lang):
                    v.Voice = tok
                    break
        except Exception:
            pass
        v.Speak(text, 1)   # SVSFlagsAsync
        while not v.WaitUntilDone(100):
            if self._stop.is_set():
                v.Speak("", 3)   # purge
                return


_LCID = {"en-GB": "809", "en-US": "409", "ru-RU": "419", "tr-TR": "41f", "en-IN": "4009"}


def _sapi_lang_match(token, lang: str) -> bool:
    try:
        return _LCID.get(lang, "?") in token.GetAttribute("Language").lower().split(";")
    except Exception:
        return False


async def _edge(text: str, v: Voice):
    import edge_tts
    mp3 = bytearray()
    async for chunk in edge_tts.Communicate(text, v.edge, rate=v.rate, pitch=v.pitch).stream():
        if chunk.get("type") == "audio":
            mp3 += chunk["data"]
    if not mp3:
        raise RuntimeError("no audio from edge-tts")
    return _decode_bytes(bytes(mp3))


def _decode_bytes(data: bytes):
    import miniaudio
    import numpy as np
    d = miniaudio.decode(data, output_format=miniaudio.SampleFormat.SIGNED16, nchannels=1, sample_rate=Speaker.SAMPLE_RATE)
    return np.frombuffer(d.samples, dtype=np.int16)


def _decode_file(path):
    import miniaudio
    import numpy as np
    d = miniaudio.decode_file(str(path), output_format=miniaudio.SampleFormat.SIGNED16, nchannels=1,
                              sample_rate=Speaker.SAMPLE_RATE)
    return np.frombuffer(d.samples, dtype=np.int16)


def resample(pcm, src: int, dst: int):
    import numpy as np
    n = int(len(pcm) * dst / src)
    x = np.interp(np.linspace(0, len(pcm) - 1, n), np.arange(len(pcm)), pcm.astype(np.float32))
    return x.astype(np.int16)
