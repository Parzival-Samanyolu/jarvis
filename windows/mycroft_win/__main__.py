"""mycroft [--cli [--speak]] [--set-key KEY] [--check]

No arguments: the tray app. --cli: chat in the terminal. --check: what's working (mic, models, key).
"""
from __future__ import annotations

import argparse
import asyncio
import sys


def cli(speak: bool) -> None:
    from . import tools
    from .brain import Brain, BrainError, LiveSpeech
    from .speech import Speaker

    speaker = Speaker(muted=not speak)

    async def confirm(desc: str) -> bool:
        return input(f"{desc}. Proceed? [y/N] ").strip().lower().startswith("y")

    brain = Brain(runner=tools.CommandRunner(confirm=confirm))

    async def loop() -> None:
        while True:
            try:
                text = input("you> ").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if not text:
                continue
            if text in ("quit", "exit"):
                break
            try:
                reply = await brain.respond(text, LiveSpeech(speaker.enqueue) if speak else None)
                print("mycroft>", reply)
                await speaker.drain()
            except BrainError as e:
                print("error:", e)
        await brain.learn()

    asyncio.run(loop())


def check(voices: bool) -> int:
    """Prints what works. Returns the number of failures (the mic and key don't count: CI has neither)."""
    import numpy as np

    from . import keys, tools
    from .audio import Transcriber, WakeDetector
    from .config import IS_WINDOWS, Paths
    failures = 0

    def step(name: str, fn) -> None:
        nonlocal failures
        try:
            print(f"ok    {name}: {fn()}")
        except Exception as e:
            failures += 1
            print(f"FAIL  {name}: {type(e).__name__}: {e}")

    print("data folder:", Paths.dir())
    print("logs:", Paths.logs())
    print("bundled models:", Paths.bundled_models())
    print("OpenRouter key:", "saved" if keys.api_key() else "not set yet")
    try:
        import sounddevice as sd
        print("default mic:", sd.query_devices(kind="input")["name"])
    except Exception as e:
        print("default mic: none found:", e)

    def wake() -> str:
        d = WakeDetector()
        fired = any(d.feed(np.zeros(1280, np.float32)) for _ in range(30))
        return f"loaded, silence fired={fired}"
    step("wake word", wake)

    def stt() -> str:
        t = Transcriber()
        if not t.prepare():
            raise RuntimeError(t.error)
        return f"loaded, silence -> {t.transcribe(np.zeros(16000, np.float32))!r}"
    step("speech to text", stt)
    step("start menu apps", lambda: f"{len(tools.installed_apps())} found")
    step("battery", tools.battery)
    if IS_WINDOWS:
        step("tray", lambda: __import__("pystray").Icon.__name__)
        step("hotkey", lambda: __import__("pynput.keyboard", fromlist=["GlobalHotKeys"]).GlobalHotKeys.__name__)
        step("volume", lambda: f"{tools.get_volume()} percent (None on a machine without speakers)")
        step("key store", lambda: type(__import__("keyring").get_keyring()).__name__)

        def sapi() -> str:
            import win32com.client
            v = win32com.client.Dispatch("SAPI.SpVoice")
            return ", ".join(t.GetDescription() for t in v.GetVoices())
        step("windows voices", sapi)
    if voices:
        import asyncio

        from .speech import VOICES, _edge
        for persona, v in VOICES.items():
            step(f"voice {persona.value} ({v.edge})",
                 lambda v=v: f"{len(asyncio.run(_edge('Testing, one two three.', v))) / 24000:.1f} s of audio")
    print("failures:", failures)
    return failures


def main() -> None:
    ap = argparse.ArgumentParser(prog="mycroft")
    ap.add_argument("--cli", action="store_true")
    ap.add_argument("--speak", action="store_true")
    ap.add_argument("--set-key")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--voices", action="store_true", help="with --check: synthesise each persona's voice (silent)")
    a = ap.parse_args()
    if a.set_key:
        from . import keys
        ok = keys.set_api_key(a.set_key)
        print("saved" if ok else "could not save the key")
        sys.exit(0 if ok else 1)
    if a.check:
        sys.exit(1 if check(a.voices) else 0)
    elif a.cli:
        cli(a.speak)
    else:
        from .app import main as app_main
        app_main()


if __name__ == "__main__":
    main()
