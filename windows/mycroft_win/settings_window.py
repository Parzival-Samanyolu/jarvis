"""Settings window (tkinter), also the first-run setup: OpenRouter key, name, city, persona, cap, switches."""
from __future__ import annotations

import logging
import queue
import threading
import webbrowser

from . import keys
from .config import Humour, Persona, Settings, State

_lock = threading.Lock()
_requests: "queue.Queue" = None   # set when the Tk thread starts
_showing = False


def check_key(key: str) -> str:
    """Asks OpenRouter about the key (free: no model call). Returns a line for the window."""
    import httpx
    try:
        r = httpx.get("https://openrouter.ai/api/v1/key", headers={"authorization": f"Bearer {key}"}, timeout=10)
    except Exception:
        return "Couldn't reach OpenRouter. Is the internet on?"
    if r.status_code != 200:
        return "OpenRouter refused this key. Copy it again from openrouter.ai/keys."
    d = (r.json() or {}).get("data") or {}
    used = d.get("usage") or 0
    limit = d.get("limit")
    if limit is None:
        return f"Key works. Used so far: ${used:.2f} (no limit set on the key)."
    return f"Key works. Used ${used:.2f} of its ${limit:.2f} limit."


def show(ctl=None) -> None:
    """Opens the window (or does nothing if it's open). Safe from any thread.

    Tk lives on one thread for the life of the app: a hidden root, and each window a Toplevel on it.
    Creating Tk roots on several threads makes Tcl crash when an old one is collected.
    """
    global _requests
    with _lock:
        if _requests is None:
            _requests = queue.Queue()
            threading.Thread(target=_tk_thread, name="tk", daemon=True).start()
    _requests.put(ctl)


def _tk_thread() -> None:
    import tkinter as tk
    hidden = tk.Tk()
    hidden.withdraw()

    def poll() -> None:
        global _showing
        try:
            while True:
                ctl = _requests.get_nowait()
                if not _showing:
                    _showing = True
                    try:
                        _window(hidden, ctl)
                    except Exception:
                        _showing = False
                        logging.getLogger("mycroft").exception("settings window failed")
        except queue.Empty:
            pass
        finally:
            hidden.after(200, poll)

    hidden.after(0, poll)
    hidden.mainloop()


def _closed() -> None:
    global _showing
    _showing = False


def _window(hidden, ctl) -> None:
    import tkinter as tk
    from tkinter import ttk

    from .app import set_start_at_login, start_at_login

    root = tk.Toplevel(hidden)
    root.title("Mycroft settings")
    root.bind("<Destroy>", lambda e: _closed() if e.widget is root else None)
    root.resizable(False, False)
    try:
        root.attributes("-topmost", True)
        root.after(500, lambda: root.attributes("-topmost", False))
    except tk.TclError:
        pass
    f = ttk.Frame(root, padding=16)
    f.grid()
    row = 0

    def label(text: str, bold: bool = False) -> None:
        nonlocal row
        ttk.Label(f, text=text, font=("Segoe UI", 10, "bold") if bold else None).grid(row=row, column=0, columnspan=2,
                                                                                     sticky="w", pady=(8 if bold else 2, 2))
        row += 1

    def field(text: str, widget) -> None:
        nonlocal row
        ttk.Label(f, text=text).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=3)
        widget.grid(row=row, column=1, sticky="we", pady=3)
        row += 1

    label("OpenRouter key", bold=True)
    has = keys.api_key()
    key_var = tk.StringVar()
    key_entry = ttk.Entry(f, textvariable=key_var, show="•", width=46)
    field("Key" + (" (saved)" if has else ""), key_entry)
    status = tk.StringVar(value="A key is saved. Paste a new one to replace it." if has else
                          "Paste the key that starts with sk-or-")
    ttk.Label(f, textvariable=status, foreground="#555").grid(row=row, column=0, columnspan=2, sticky="w")
    row += 1
    link = ttk.Label(f, text="Get a key at openrouter.ai/keys", foreground="#1a66d6", cursor="hand2")
    link.grid(row=row, column=0, columnspan=2, sticky="w")
    link.bind("<Button-1>", lambda _: webbrowser.open("https://openrouter.ai/keys"))
    row += 1

    def do_check() -> None:
        k = key_var.get().strip() or keys.api_key() or ""
        if not k:
            status.set("Paste a key first.")
            return
        status.set("Checking…")
        threading.Thread(target=lambda: root.after(0, status.set, check_key(k)), daemon=True).start()
    ttk.Button(f, text="Check key", command=do_check).grid(row=row, column=1, sticky="e")
    row += 1

    label("About you", bold=True)
    name_var = tk.StringVar(value=Settings.owner_name())
    field("Your name", ttk.Entry(f, textvariable=name_var, width=46))
    city_var = tk.StringVar(value=Settings.city())
    field("City, country", ttk.Entry(f, textvariable=city_var, width=46))

    label("Mycroft", bold=True)
    personas = {f"{p.label} — {p.blurb}": p for p in Persona}
    persona_var = tk.StringVar(value=next(k for k, p in personas.items() if p == Settings.persona()))
    field("Persona", ttk.Combobox(f, textvariable=persona_var, values=list(personas), state="readonly", width=60))
    humours = {h.label: h for h in Humour}
    humour_var = tk.StringVar(value=Settings.humour().label)
    field("Jokes", ttk.Combobox(f, textvariable=humour_var, values=list(humours), state="readonly", width=20))
    cap_var = tk.StringVar(value=f"{Settings.cap():.0f}")
    field("Monthly limit ($)", ttk.Spinbox(f, from_=1, to=500, textvariable=cap_var, width=8))

    switches = [
        ("wakeWord", 'Listen for "Hey Mycroft"', Settings.wake_word()),
        ("followUp", "Keep listening after an answer", Settings.follow_up()),
        ("openingLine", "Say hello when starting", Settings.opening_line()),
        ("briefing", "Morning weather briefing", Settings.briefing()),
        ("shutdownLine", "Say goodbye when quitting", Settings.shutdown_line()),
        ("onlineVoices", "Natural online voices (off: Windows voices)", Settings.online_voices()),
    ]
    vars_ = {}
    for key, text, val in switches:
        v = tk.BooleanVar(value=val)
        vars_[key] = v
        ttk.Checkbutton(f, text=text, variable=v).grid(row=row, column=0, columnspan=2, sticky="w")
        row += 1
    login_var = tk.BooleanVar(value=start_at_login())
    ttk.Checkbutton(f, text="Start Mycroft with Windows", variable=login_var).grid(row=row, column=0, columnspan=2, sticky="w")
    row += 1

    ttk.Label(f, text="Talk: press Ctrl+Alt+Space, or say \"Hey Mycroft\". Press it again to stop him.",
              foreground="#555").grid(row=row, column=0, columnspan=2, sticky="w", pady=(10, 0))
    row += 1

    def save() -> None:
        k = key_var.get().strip()
        if k:
            if not keys.looks_like_key(k):
                status.set("That doesn't look like an OpenRouter key (it should start with sk-or-).")
                return
            if not keys.set_api_key(k):
                status.set("Couldn't save the key in Windows Credential Manager.")
                return
        State.set("ownerName", name_var.get().strip())
        State.set("city", city_var.get().strip())
        State.set("humour", humours[humour_var.get()].value)
        try:
            State.set("cap", str(max(1, int(float(cap_var.get())))))
        except ValueError:
            pass
        for key, v in vars_.items():
            State.set(key, "on" if v.get() else "off")
        try:
            set_start_at_login(login_var.get())
        except OSError:
            pass
        new_persona = personas[persona_var.get()]
        if ctl is not None:
            if new_persona != Settings.persona():
                ctl.post(ctl.set_persona(new_persona))
            ctl.call(ctl.update_wake)
            if k:
                ctl.post(ctl.say("Thank you, sir. I'm ready. Press control alt space, or say hey Mycroft."))
        else:
            Settings.set_persona(new_persona)
        root.destroy()

    buttons = ttk.Frame(f)
    buttons.grid(row=row, column=0, columnspan=2, sticky="e", pady=(12, 0))
    ttk.Button(buttons, text="Cancel", command=root.destroy).grid(row=0, column=0, padx=6)
    ttk.Button(buttons, text="Save", command=save).grid(row=0, column=1)
    root.bind("<Return>", lambda _: save())
    root.lift()
    root.focus_force()
    key_entry.focus_set()
