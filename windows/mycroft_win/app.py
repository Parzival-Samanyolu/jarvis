"""The Windows app: tray icon, hotkey, conversation state machine. Ported from App.swift.

Threads: pystray owns the main thread; all conversation logic runs on one asyncio loop in a background
thread; the mic, speech and hotkey have their own threads and only ever post onto that loop.
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys
import threading
from datetime import date, datetime

from . import intents, lines, offline, tools
from .audio import Mic, Transcriber, WakeDetector
from .brain import Brain, BrainError, LiveSpeech
from .config import IS_WINDOWS, Mode, Paths, Persona, Settings, State
from .keys import api_key
from .lines import HOTKEY_SPOKEN, LinePicker
from .memory import fact_of
from .speech import Speaker

log = logging.getLogger("mycroft")

IDLE, LISTENING, THINKING, SPEAKING, MUTED, CONFIRMING = "idle", "listening", "thinking", "speaking", "muted", "confirming"


def chime(kind: str = "wake") -> None:
    if not IS_WINDOWS:
        return
    import winsound
    try:
        if kind == "wake":
            threading.Thread(target=winsound.Beep, args=(988, 90), daemon=True).start()
        else:
            winsound.PlaySound("SystemAsterisk", winsound.SND_ALIAS | winsound.SND_ASYNC)
    except Exception:
        pass


class Controller:
    def __init__(self, speaker: Speaker | None = None, mic: Mic | None = None, transcriber: Transcriber | None = None,
                 brain: Brain | None = None) -> None:
        self.loop = asyncio.new_event_loop()
        self.speaker = speaker or Speaker()
        self.mic = mic or Mic()
        self.transcriber = transcriber or Transcriber()
        self.brain = brain or Brain(runner=tools.CommandRunner(confirm=self.confirm))
        self.brain.conversation_log = Paths.conversation_log()
        self.lines = LinePicker()
        self.state = IDLE
        self.session: asyncio.Task | None = None
        self.cancel_event = threading.Event()
        self.confirm_future: asyncio.Future | None = None
        self.greeting = False
        self.last_reply = ""
        self.quitting = False
        self.on_change = None           # tray refresh
        self.wake_ok = False
        self._online = (True, 0.0)
        self._background: set = set()
        self.speaker.on_speaking = lambda on: None

    # MARK: Threads and state

    def start(self) -> None:
        threading.Thread(target=self.loop.run_forever, name="mycroft-loop", daemon=True).start()
        self.post(self._launch())

    def post(self, coro) -> "asyncio.Future":
        return asyncio.run_coroutine_threadsafe(coro, self.loop)

    def call(self, fn, *args) -> None:
        self.loop.call_soon_threadsafe(fn, *args)

    def set_state(self, s: str) -> None:
        self.state = s
        self.update_wake()
        if self.on_change:
            try:
                self.on_change()
            except Exception:
                pass

    def update_wake(self) -> None:
        """Listen for "Hey Mycroft" while idle, and while answering so it can interrupt."""
        want = (Settings.wake_word() and self.wake_ok and not self.greeting and
                ((self.state == IDLE and self.session is None) or (self.state == SPEAKING and self.session is not None)))
        self.mic.wake_enabled = want
        if self.state == MUTED:
            self.mic.stop()
        elif want:
            self.mic.start()

    async def is_online(self) -> bool:
        ok, when = self._online
        now = asyncio.get_running_loop().time()
        if now - when > 10:
            ok = await asyncio.to_thread(offline.is_online)
            self._online = (ok, now)
        return ok

    # MARK: Launch

    async def _launch(self) -> None:
        self.brain.timers.on_fire = lambda item: self.post(self.announce(item.announcement))
        self.brain.timers.restore()
        await asyncio.to_thread(self.brain.app_names)
        stt = asyncio.ensure_future(asyncio.to_thread(self.transcriber.prepare))
        try:
            self.mic.wake = await asyncio.to_thread(WakeDetector)
            self.mic.on_wake = lambda: self.call(self.wake_heard)
            self.wake_ok = True
        except Exception as e:
            log.error("wake word unavailable: %s", e)
        await self.opening()
        ready = await stt
        if not api_key():
            await self.say("I have no API key, sir. Please open my settings from the icon by the clock and paste one in.")
            if self.on_need_key:
                self.on_need_key()
        elif not ready:
            await self.say("I can't hear you yet, sir. My speech model failed to load.")
        self.update_wake()
        if not self.mic.start():
            await self.say("I can't open the microphone, sir. Please check the microphone privacy settings in Windows.")

    on_need_key = None

    # MARK: Hotkey and wake word (called on the loop)

    def hotkey(self) -> None:
        if self.state == CONFIRMING:
            self.resolve_confirm(False)   # the shortcut always means stop; only a spoken yes approves
        elif self.state in (SPEAKING, LISTENING, THINKING):
            self.cancel_session()
            self.set_state(IDLE)
        else:
            self.start_session()

    def wake_heard(self) -> None:
        if self.state == SPEAKING:
            self.cancel_session()
        if self.state not in (IDLE, SPEAKING) or self.session is not None:
            return
        chime("wake")
        self.start_session(after_wake=True)

    def cancel_session(self) -> None:
        if self.session:
            self.session.cancel()
            self.session = None
        self.cancel_event.set()
        self.mic.cancel()
        self.speaker.stop()

    def start_session(self, after_wake: bool = False) -> None:
        if self.session is not None:
            return
        self.cancel_event = threading.Event()
        self.set_state(LISTENING)
        task = self.loop.create_task(self.conversation(after_wake))

        def done(t: asyncio.Task) -> None:
            if self.session is t:
                self.session = None
                if self.state not in (MUTED,):
                    self.set_state(IDLE)
        task.add_done_callback(done)
        self.session = task

    def toggle_mute(self) -> None:
        if self.state == MUTED:
            self.set_state(IDLE)
        else:
            self.cancel_session()
            self.set_state(MUTED)

    # MARK: Conversation

    async def conversation(self, after_wake: bool) -> None:
        first = True
        try:
            while True:
                self.set_state(LISTENING)
                text = await self.hear(8 if first else 5, calibrate=not after_wake or not first)
                if text is None or not text:
                    break
                first = False
                self.set_state(THINKING)
                if not await self.handle(text):
                    break
                if not Settings.follow_up():
                    break
        finally:
            if self.brain.conversation.exchanges:
                t = asyncio.get_running_loop().create_task(self.brain.learn())
                self._background.add(t)
                t.add_done_callback(self._background.discard)

    async def hear(self, start_timeout: float, calibrate: bool = True) -> str | None:
        audio = await asyncio.to_thread(self.mic.record, start_timeout, Settings.end_silence(), calibrate, self.cancel_event)
        if audio is None:
            return None
        if self.state != CONFIRMING:
            self.set_state(THINKING)
        lang = None if Settings.persona() == Persona.pasha else "en"
        text = await asyncio.to_thread(self.transcriber.transcribe, audio, lang)
        log.info("heard: %s", text)
        return text

    async def handle(self, text: str) -> bool:
        """False ends the conversation."""
        it = intents.parse(text)
        k = it.kind
        if k == "stop":
            return False
        if k == "repeat":
            await self.say(self.last_reply or "I haven't said anything yet, sir.", raw=bool(self.last_reply))
            return True
        if k == "persona":
            if it.arg == Settings.persona():
                await self.say("I'm quite myself already, sir.")
            else:
                await self.set_persona(it.arg)
            return True
        if k == "timer":
            self.brain.timers.start(it.arg, it.label)
            from .timers import spoken
            await self.say(f"Timer set for {spoken(it.arg)}, sir." if not it.label else
                           f"Very good, sir. I'll remind you in {spoken(it.arg)}.")
            return True
        if k == "timer_status":
            await self.say(self.brain.timers.status())
            return True
        if k == "cancel_timers":
            n = self.brain.timers.cancel_all()
            await self.say("There's no timer running, sir." if n == 0 else "Timer cancelled, sir." if n == 1
                           else f"All {n} timers cancelled, sir.")
            return True
        if k == "mute":
            await self.say(f"Muted, sir. Press {HOTKEY_SPOKEN} when you need me.")
            self.set_state(MUTED)
            return False
        if k == "set_mode":
            self.set_mode(it.arg)
            await self.say(f"Using {it.arg.label}, sir.")
            return True
        if k == "spend":
            await self.say(self.brain.usage.report())
            return True
        if k == "what_do_you_know":
            await self.say(self.brain.memory.read_back())
            return True
        if k == "forget":
            r = self.brain.memory.forget(it.arg)
            await self.say("Consider it forgotten, sir." if r else "I couldn't find anything like that, sir.")
            return True
        if not await self.is_online():
            await self.answer_offline(text)
            return True
        try:
            self.last_reply = await self.brain.respond(text, self.live_speech())
            if notice := self.cap_notice():
                self.speaker.enqueue(lines.in_persona(notice))
            await self.speaker.drain()
            if self.state == SPEAKING:
                self.set_state(THINKING)
            return True
        except asyncio.CancelledError:
            raise
        except BrainError as e:
            await self.speaker.drain()
            if e.kind == "offline":
                self._online = (False, asyncio.get_running_loop().time())
                await self.answer_offline(text)
                return True
            log.error("brain error: %s", e)
            if e.kind == "no_key":
                await self.say("I have no API key, sir.")
            elif e.kind == "bad_key":
                await self.say("My API key was refused, sir. Please check it in my settings.")
            elif e.kind == "credits":
                await self.say("The OpenRouter credit has run out, sir. Someone will need to top it up.")
            else:
                await self.say(self.lines.error(), raw=True)
            return False
        except Exception as e:
            log.exception("unexpected error: %s", e)
            await self.say(self.lines.error(), raw=True)
            return False

    async def answer_offline(self, text: str) -> None:
        if a := offline.parse(text):
            await self.say(await asyncio.to_thread(offline.perform, a))
        else:
            await self.say(self.lines.offline(), raw=True)

    def live_speech(self) -> LiveSpeech:
        def say(sentence: str) -> None:
            self.speaker.enqueue(sentence)
            if self.state == THINKING:
                self.call(self.set_state, SPEAKING)
        return LiveSpeech(say)

    def cap_notice(self) -> str:
        month = datetime.now().strftime("%Y-%m")
        cap = int(Settings.cap())
        if self.brain.usage.cap_reached() and State.get("capNotice") != month:
            State.set("capNotice", month)
            return f"Also, sir, you've reached the {cap} dollar monthly cap. I'll use Haiku only until the month resets."
        if self.brain.usage.near_cap() and State.get("warnNotice") != month:
            State.set("warnNotice", month)
            return f"A word of caution, sir: you're nearing the {cap} dollar monthly cap."
        return ""

    async def say(self, text: str, raw: bool = False, plain: bool = False) -> None:
        """Speaks a fixed line (written for the butler, so put in persona unless raw)."""
        line = text if raw else lines.in_persona(text)
        self.last_reply = line
        was = self.state
        self.set_state(SPEAKING)
        await self.speaker.speak(line, plain=plain)
        if self.state == SPEAKING:
            self.set_state(MUTED if was == MUTED else (THINKING if self.session is not None else IDLE))

    async def announce(self, text: str) -> None:
        """A timer ended: chime and the line, once no conversation is open."""
        while self.session is not None or self.greeting or self.state == CONFIRMING:
            await asyncio.sleep(0.5)
        chime("timer")
        await asyncio.sleep(0.6)
        await self.say(text)

    # MARK: Persona and mode

    async def set_persona(self, p: Persona) -> None:
        was = Settings.persona()
        Settings.set_persona(p)
        self.brain.conversation.reset()
        self.set_state(self.state)
        hello = lines.PERSONA_HELLO[p]
        if p == Persona.butler and was == Persona.undercover:
            hello = "Undercover mode off. Good to be back, sir. That accent was exhausting."
        await self.say(hello, raw=True)

    def set_mode(self, m: Mode) -> None:
        self.brain.mode = m
        State.set("mode", m.value)
        self.set_state(self.state)

    # MARK: Risky-command confirmation (spoken yes, or the hotkey)

    async def confirm(self, description: str) -> bool:
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self.confirm_future = fut
        prev = self.state
        self.set_state(CONFIRMING)
        p = Settings.persona()
        if p == Persona.undercover:
            q = f"{description}. Want me to go ahead?"
        elif p == Persona.pasha:
            q = f"{description}. Devam edeyim mi evladım?"
        elif p == Persona.trump:
            q = f"{description}. Shall I go ahead?"
        else:
            q = lines.in_persona(f"{description}. Shall I proceed, sir?")
        await self.speaker.speak(q, plain=True)

        async def listen() -> None:
            for _ in range(2):
                if fut.done():
                    return
                heard = await self.hear(6)
                if fut.done():
                    return
                answer = intents.yes_no(heard or "")
                if answer != "unclear" or heard is None:
                    self.resolve_confirm(answer == "yes")
                    return
            self.resolve_confirm(False)

        listener = loop.create_task(listen())
        try:
            ok = await fut
        finally:
            listener.cancel()
            self.mic.cancel()
            self.confirm_future = None
            self.set_state(THINKING if prev != MUTED else prev)
        return ok

    def resolve_confirm(self, yes: bool) -> None:
        f = self.confirm_future
        if f and not f.done():
            self.speaker.stop()
            self.mic.cancel()
            f.set_result(yes)

    # MARK: Opening, briefing, weekly review

    async def opening(self) -> None:
        if self.greeting or self.quitting or self.session is not None or self.state != IDLE:
            return
        self.greeting = True
        try:
            if Settings.opening_line():
                await self.say(self.lines.opening(), raw=True)
            if Settings.briefing():
                await self.briefing()
        finally:
            self.greeting = False
            if self.state != MUTED:
                self.set_state(IDLE)

    async def briefing(self) -> None:
        if not api_key() or not await self.is_online():
            return
        today = date.today().isoformat()
        if State.get("lastGreeting") == today:
            return
        self.set_state(THINKING)
        notes = tools.note_recent(3)
        prompt = (f"It is the owner's first time at the PC today, and you have just greeted them, so do not greet them again. "
                  f"Give today's weather in {Settings.city()} (use web search; just conditions and temperature in Celsius), "
                  f"and mention their latest notes if there are any. Two sentences in total, no more.\n\n"
                  f"Latest notes (may be empty):\n{notes}")
        try:
            await self.brain.one_shot(prompt, "sonnet", self.live_speech())
            State.set("lastGreeting", today)
            await self.speaker.drain()
            if date.today().weekday() == 6:
                await self.weekly_review()
        except Exception as e:
            log.warning("briefing skipped: %s", e)

    async def weekly_review(self) -> None:
        items = self.brain.memory.new_this_week()[:10]
        if not items:
            return
        await self.say("It's Sunday, sir. Time for the weekly memory review. For each item, say keep or delete.")
        for line in items:
            await self.say(f"I learned: {fact_of(line)}")
            verdict = None
            for _ in range(2):
                self.set_state(LISTENING)
                heard = await self.hear(7)
                if heard is None:
                    break
                verdict = intents.keep_or_delete(heard)
                if verdict is not None:
                    break
            if verdict is False:
                self.brain.memory.remove(line)
                await self.say("Deleted.")
        await self.say("That's the lot, sir.")

    async def shutdown(self) -> None:
        self.quitting = True
        self.resolve_confirm(False)
        self.cancel_session()
        if Settings.shutdown_line():
            try:
                await asyncio.wait_for(self.say(self.lines.shutdown(), raw=True), timeout=10)
            except asyncio.TimeoutError:
                self.speaker.stop()
        self.mic.stop()


# MARK: Startup with Windows

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def launch_command() -> str:
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}"'
    return f'"{sys.executable}" -m mycroft_win'


def start_at_login() -> bool:
    if not IS_WINDOWS:
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, "Mycroft")
            return True
    except OSError:
        return False


def set_start_at_login(on: bool) -> None:
    if not IS_WINDOWS:
        return
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if on:
            winreg.SetValueEx(k, "Mycroft", 0, winreg.REG_SZ, launch_command())
        else:
            try:
                winreg.DeleteValue(k, "Mycroft")
            except OSError:
                pass


# MARK: Tray

STATE_COLOURS = {IDLE: (40, 44, 52), LISTENING: (214, 48, 49), THINKING: (230, 160, 30), SPEAKING: (39, 128, 227),
                 MUTED: (120, 120, 120), CONFIRMING: (155, 89, 182)}
PERSONA_LETTER = {Persona.butler: "M", Persona.undercover: "U", Persona.comrade: "C", Persona.bigBrother: "B",
                  Persona.pasha: "P", Persona.techSupport: "S", Persona.trump: "T"}


def tray_image(state: str, persona: Persona):
    from PIL import Image, ImageDraw, ImageFont
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((2, 2, size - 2, size - 2), fill=STATE_COLOURS.get(state, (40, 44, 52)))
    letter = PERSONA_LETTER.get(persona, "M")
    try:
        font = ImageFont.truetype("segoeuib.ttf" if IS_WINDOWS else "Arial Bold.ttf", 38)
    except OSError:
        font = ImageFont.load_default()
    box = d.textbbox((0, 0), letter, font=font)
    d.text(((size - (box[2] - box[0])) / 2 - box[0], (size - (box[3] - box[1])) / 2 - box[1]), letter,
           fill="white", font=font)
    if state == MUTED:
        d.line((12, 12, size - 12, size - 12), fill="white", width=6)
    return img


def run_tray(ctl: Controller) -> None:
    import pystray
    from pystray import Menu, MenuItem as Item

    def status_text(_=None) -> str:
        online = "" if ctl._online[0] else " (offline)"
        return f"Mycroft — {ctl.state.capitalize()}{online}"

    def spend_text(_=None) -> str:
        return f"Spent this month: ${ctl.brain.usage.month_total():.2f} of ${Settings.cap():.0f}"

    def persona_item(p: Persona):
        return Item(p.label, lambda: ctl.post(ctl.set_persona(p)) if p != Settings.persona() else None,
                    checked=lambda _: Settings.persona() == p, radio=True)

    def mode_item(m: Mode):
        return Item(m.label, lambda: ctl.call(ctl.set_mode, m), checked=lambda _: ctl.brain.mode == m, radio=True)

    def open_settings() -> None:
        from .settings_window import show
        show(ctl)

    def quit_app(icon) -> None:
        try:
            ctl.post(ctl.shutdown()).result(timeout=12)
        except Exception:
            pass
        icon.stop()

    menu = Menu(
        Item(status_text, None, enabled=False),
        Item(spend_text, None, enabled=False),
        Menu.SEPARATOR,
        Item("Listen now  (Ctrl+Alt+Space)", lambda: ctl.call(ctl.hotkey), default=True),
        Item(lambda _: "Unmute" if ctl.state == MUTED else "Mute", lambda: ctl.call(ctl.toggle_mute)),
        Menu.SEPARATOR,
        Item("Persona", Menu(*[persona_item(p) for p in Persona])),
        Item("Model", Menu(*[mode_item(m) for m in Mode])),
        Menu.SEPARATOR,
        Item("Settings…", lambda: open_settings()),
        Item("Open notes folder", lambda: tools.open_target(str(tools.notes_dir()))),
        Item("Quit Mycroft", quit_app),
    )
    icon = pystray.Icon("Mycroft", tray_image(ctl.state, Settings.persona()), "Mycroft", menu)

    def refresh() -> None:
        icon.icon = tray_image(ctl.state, Settings.persona())
        icon.title = status_text()
        try:
            icon.update_menu()
        except Exception:
            pass

    ctl.on_change = refresh
    ctl.on_need_key = open_settings
    icon.run()


def start_hotkey(ctl: Controller):
    from pynput import keyboard
    hk = keyboard.GlobalHotKeys({"<ctrl>+<alt>+<space>": lambda: ctl.call(ctl.hotkey)})
    hk.daemon = True
    hk.start()
    return hk


_MUTEX = None


def already_running() -> bool:
    if not IS_WINDOWS:
        return False
    import ctypes
    global _MUTEX
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.CreateMutexW.restype = ctypes.c_void_p
    _MUTEX = k.CreateMutexW(None, False, "Local\\MycroftVoiceAssistant")   # kept open for the app's life
    return ctypes.get_last_error() == 183   # ERROR_ALREADY_EXISTS


def message_box(text: str) -> None:
    if IS_WINDOWS:
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, text, "Mycroft", 0x40)   # type: ignore[attr-defined]
    else:
        print(text)


def setup_logging() -> None:
    Paths.logs().mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=str(Paths.error_log()), level=logging.INFO, encoding="utf-8",
                        format="%(asctime)s %(levelname)s %(message)s")


def main() -> None:
    if sys.stdout is None or sys.stderr is None:   # the windowed app has no console; libraries still print
        sys.stdout = sys.stderr = open(os.devnull, "w", encoding="utf-8")
    setup_logging()
    if already_running():
        message_box("Mycroft is already running. Look for its round icon by the clock (you may need to click the ^ arrow).")
        return
    first_run = State.get("installed") is None
    if first_run:   # starting with Windows is the installer's choice (and the Settings switch)
        State.set("installed", datetime.now().isoformat(timespec="seconds"))
    ctl = Controller()
    try:
        start_hotkey(ctl)
    except Exception as e:
        log.error("hotkey unavailable: %s", e)
    ctl.start()
    if first_run or not api_key():
        threading.Timer(1.0, lambda: __import__("mycroft_win.settings_window", fromlist=["show"]).show(ctl)).start()
    run_tray(ctl)
    os._exit(0)
