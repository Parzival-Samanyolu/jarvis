"""What Mycroft can do on the PC: PowerShell, open apps and links, media keys, notes, screenshots, battery."""
from __future__ import annotations

import base64
import io
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Awaitable, Callable

from . import keys
from .config import IS_WINDOWS, Paths
from .safety import SafetyChecker

MAX_RETRIES = 2
MAX_OUTPUT = 6000
NO_WINDOW = 0x08000000 if IS_WINDOWS else 0   # CREATE_NO_WINDOW: no console flashes up


@dataclass
class Result:
    output: str
    exit_code: int
    declined: bool = False


def log_line(path: Path, *fields: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as f:
            f.write("\t".join([datetime.now().isoformat(timespec="seconds"), *[x.replace("\n", "\\n") for x in fields]]) + "\n")
    except OSError:
        pass


def execute(command: str, timeout: float = 30) -> Result:
    """Runs a PowerShell command (zsh on other systems, for development) in the owner's folder."""
    if IS_WINDOWS:
        # UTF-8 output so Turkish and other non-ASCII text survives.
        prefix = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference='SilentlyContinue'; "
        argv = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", prefix + command]
    else:
        argv = ["/bin/zsh", "-c", command]
    # Output goes to a temp file, not a pipe: a GUI app started by the command (notepad, explorer) inherits
    # the handles and would keep a pipe open until it is closed, hanging Mycroft.
    import tempfile
    with tempfile.TemporaryFile() as out:
        try:
            p = subprocess.Popen(argv, cwd=str(Path.home()), stdin=subprocess.DEVNULL, stdout=out,
                                 stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
        except OSError as e:
            return Result(str(e), 127)
        try:
            code = p.wait(timeout=timeout)
            note = ""
        except subprocess.TimeoutExpired:
            kill_tree(p.pid)
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            code, note = 124, f"\n(stopped after {int(timeout)} seconds)"
        out.seek(0)
        return Result(out.read().decode("utf-8", errors="replace") + note, code)


def kill_tree(pid: int) -> None:
    if IS_WINDOWS:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
    else:
        try:
            os.kill(pid, 9)
        except OSError:
            pass


class CommandRunner:
    """run_command: safety check, a spoken yes for risky commands, a log, a retry cap and secret stripping."""

    def __init__(self, confirm: Callable[[str], Awaitable[bool]], safety: SafetyChecker | None = None,
                 log: Path | None = None, runner: Callable[[str], Result] = execute) -> None:
        self.confirm = confirm
        self.safety = safety or SafetyChecker()
        self.log = log or Paths.command_log()
        self.runner = runner
        self.failures = 0

    def begin_request(self) -> None:
        self.failures = 0

    async def run(self, command: str) -> Result:
        import asyncio
        if self.failures > MAX_RETRIES:
            log_line(self.log, "SKIPPED retry limit", command)
            return Result("Retry limit reached. Stop trying and report the problem to the owner in one line.", 1)
        if why := self.safety.classify(command):
            log_line(self.log, f"RISKY ({why}) - asking", command)
            if not await self.confirm(f"This {why}"):
                log_line(self.log, "DECLINED", command)
                return Result("The owner declined to run this command. Do not retry it or work around it; acknowledge briefly.",
                              126, declined=True)
            log_line(self.log, "APPROVED", command)
        r = await asyncio.to_thread(self.runner, command)
        log_line(self.log, f"exit {r.exit_code}", command)
        if r.exit_code != 0:
            self.failures += 1
        out = keys.strip(r.output).strip()
        if len(out) > MAX_OUTPUT:
            out = out[:MAX_OUTPUT] + "\n[output truncated]"
        if not out:
            out = "(success; the command printed nothing)" if r.exit_code == 0 else "(failed; no error message)"
        return Result(f"exit code {r.exit_code}\n{out}", r.exit_code)


# MARK: Installed apps (Start Menu shortcuts)

def start_menu_dirs() -> list[Path]:
    dirs = []
    for var in ("APPDATA", "PROGRAMDATA"):
        if base := os.environ.get(var):
            dirs.append(Path(base) / "Microsoft" / "Windows" / "Start Menu" / "Programs")
    return dirs


_SKIP_APP = re.compile(r"uninstall|readme|help|documentation|release notes|license|website|manual|support|\bweb site\b", re.I)


def installed_apps(dirs: list[Path] | None = None) -> dict[str, Path]:
    """App name -> Start Menu shortcut, without uninstallers and readmes."""
    apps: dict[str, Path] = {}
    for d in dirs if dirs is not None else start_menu_dirs():
        try:
            for p in d.rglob("*"):
                if p.suffix.lower() in (".lnk", ".url", ".appref-ms") and not _SKIP_APP.search(p.stem):
                    apps.setdefault(p.stem, p)
        except OSError:
            pass
    return dict(sorted(apps.items(), key=lambda kv: kv[0].lower()))


UWP_APPS = {   # built-in apps without Start Menu shortcuts in the folders above
    "Settings": "ms-settings:", "Microsoft Store": "ms-windows-store:", "Calculator": "calculator:",
    "Camera": "microsoft.windows.camera:", "Photos": "ms-photos:", "Clock": "ms-clock:", "Mail": "outlookmail:",
    "Calendar": "outlookcal:", "Weather": "bingweather:", "Xbox": "xbox:", "Spotify": "spotify:",
    "Notepad": "notepad.exe", "Paint": "mspaint.exe", "File Explorer": "explorer.exe", "Task Manager": "taskmgr.exe",
}


RUNNABLE = {".wsh", ".msc", ".application", ".xll", ".py", ".pyw", ".psc1", ".scf", ".sct", ".docm", ".xlsm",
            ".pptm", ".ps1xml", ".vb", ".gadget", ".diagcab", ".settingcontent-ms", ".library-ms", ".exe", ".bat", ".cmd", ".ps1", ".vbs", ".vbe", ".js", ".jse", ".wsf", ".msi", ".msp", ".scr", ".com",
            ".lnk", ".hta", ".reg", ".cpl", ".pif", ".jar", ".appref-ms", ".url"}


def match_app(name: str, apps: dict[str, Path]) -> str | None:
    want = name.lower().strip()
    names = list(apps) + list(UWP_APPS)
    for n in names:
        if n.lower() == want:
            return n
    for n in names:
        if n.lower().startswith(want) or want in n.lower():
            return n
    return None


def open_target(target: str, apps: dict[str, Path] | None = None) -> tuple[str, bool]:
    """Opens an installed app by name, a website, or a file. Returns (what to tell the model, failed)."""
    t = target.strip()
    if not t:
        return "Nothing to open.", True
    if re.match(r"^(https?://|www\.)", t, re.I):
        url = t if t.lower().startswith("http") else "https://" + t
        return _start(url, f"Opened {url} in the browser.")
    apps = installed_apps() if apps is None else apps
    if n := match_app(t, apps):
        return _start(str(apps[n]) if n in apps else UWP_APPS[n], f"Opened {n}.")
    p = Path(os.path.expandvars(os.path.expanduser(t)))
    if p.exists():
        # Documents, pictures, folders: fine. Programs and scripts go through run_command and its safety check.
        if p.suffix.lower() in RUNNABLE:
            return "That is a program or script; it can't be opened this way. Use run_command so the safety check sees it.", True
        return _start(str(p), f"Opened {p}.")
    return f"No app, website or file called {t!r} found. Installed apps are listed in the system prompt.", True


def _start(target: str, ok: str) -> tuple[str, bool]:
    try:
        if IS_WINDOWS:
            os.startfile(target)   # type: ignore[attr-defined]
        else:
            subprocess.Popen(["open", target])
        return ok, False
    except OSError as e:
        return f"Could not open it: {e}", True


# MARK: Media keys and volume

VK = {"play_pause": 0xB3, "next": 0xB0, "previous": 0xB1, "mute": 0xAD, "volume_down": 0xAE, "volume_up": 0xAF}


def press_key(vk: int, times: int = 1) -> None:
    if not IS_WINDOWS:
        return
    import ctypes
    user32 = ctypes.windll.user32   # type: ignore[attr-defined]
    for _ in range(times):
        user32.keybd_event(vk, 0, 0, 0)
        user32.keybd_event(vk, 0, 2, 0)   # KEYEVENTF_KEYUP


class _Com:
    """COM must be initialised on each thread that uses it; these calls run on any worker thread."""

    def __enter__(self):
        import comtypes
        comtypes.CoInitialize()
        return self

    def __exit__(self, *exc):
        import comtypes
        comtypes.CoUninitialize()
        return False


def get_volume() -> int | None:
    try:
        with _Com():
            from pycaw.pycaw import AudioUtilities
            v = AudioUtilities.GetSpeakers().EndpointVolume
            return round(v.GetMasterVolumeLevelScalar() * 100)
    except Exception:
        return None


def set_volume(percent: int) -> bool:
    try:
        with _Com():
            from pycaw.pycaw import AudioUtilities
            v = AudioUtilities.GetSpeakers().EndpointVolume
            v.SetMute(0, None)
            v.SetMasterVolumeLevelScalar(max(0, min(100, percent)) / 100, None)
            return True
    except Exception:
        return False


def media(action: str, percent: int | None = None) -> tuple[str, bool]:
    if action == "set_volume":
        if percent is None:
            return "Missing percent.", True
        if set_volume(percent):
            return f"Volume is now {get_volume() if get_volume() is not None else percent} percent.", False
        press_key(VK["volume_down"], 50)
        press_key(VK["volume_up"], max(0, min(100, percent)) // 2)
        return f"Volume set to about {percent} percent.", False
    if action not in VK:
        return f"Unknown media action {action}.", True
    if action in ("volume_up", "volume_down") and (now := get_volume()) is not None:
        set_volume(now + (15 if action == "volume_up" else -15))
        return f"Volume is now {get_volume()} percent.", False
    press_key(VK[action], 5 if action.startswith("volume") else 1)
    return "Done. (Media keys give no confirmation; if nothing is playing, play_pause has no effect.)", False


# MARK: Notes (plain text files in Documents\Mycroft Notes)

def notes_dir() -> Path:
    d = Paths.notes()
    d.mkdir(parents=True, exist_ok=True)
    return d


def note_save(text: str) -> str:
    now = datetime.now()
    title = re.sub(r"[^\w\- ]", "", text)[:40].strip() or "note"
    p = notes_dir() / f"{now:%Y-%m-%d %H%M%S} {title}.txt"
    p.write_text(text.strip() + "\n", encoding="utf-8")
    return f"Saved the note: {text.strip()}"


def _notes() -> list[Path]:
    return sorted(notes_dir().glob("*.txt"), key=lambda p: p.stat().st_mtime, reverse=True)


def _show(p: Path) -> str:
    when = datetime.fromtimestamp(p.stat().st_mtime).strftime("%d %B %Y %H:%M")
    return f"[{when}] {p.read_text(encoding='utf-8', errors='replace').strip()}"


def note_last() -> str:
    n = _notes()
    return _show(n[0]) if n else "There are no notes yet."


def note_recent(count: int = 5) -> str:
    n = _notes()[:count]
    return "\n".join(_show(p) for p in n) if n else "There are no notes yet."


def note_search(words: str) -> str:
    keys_ = [w for w in words.lower().split() if len(w) > 2] or [words.lower()]
    hits = [p for p in _notes() if any(k in p.read_text(encoding="utf-8", errors="replace").lower() for k in keys_)]
    return "\n".join(_show(p) for p in hits[:5]) if hits else f"No notes mention {words}."


# MARK: Screen and battery

def screenshot_b64() -> str | None:
    try:
        from PIL import ImageGrab
        img = ImageGrab.grab(all_screens=False)
        img.thumbnail((1568, 1568))
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode()
    except Exception:
        return None


def battery() -> tuple[int, bool] | None:
    try:
        import psutil
        b = psutil.sensors_battery()
        return (round(b.percent), bool(b.power_plugged)) if b else None
    except Exception:
        return None


def is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))
