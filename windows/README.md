# Mycroft for Windows

The Mac Mycroft, ported to Python for a Windows 10/11 PC: the same seven personas, voice chat, timers, memory, notes and PC control with the same safety rules. The brain runs through **OpenRouter** (Claude Sonnet 5.5 by default, Opus 5.5 for "think deeply", Haiku 5.5 once the monthly limit is hit).

## Getting the installer

GitHub builds it: **Actions → Windows build → latest run → Artifacts → Mycroft-Setup** (a zip with `Mycroft-Setup-0.1.N.exe`, about 300 MB). Every push that touches `windows/` builds a new one; "Run workflow" builds one by hand.

## Setting it up on the PC

1. Make an OpenRouter key for this PC at <https://openrouter.ai/keys> and **give it a credit limit** (say $10). That limit is the real safety net: the key can be switched off there at any time.
2. Run `Mycroft-Setup-….exe`. No administrator password is needed. Windows SmartScreen may say "Windows protected your PC": click **More info → Run anyway** (the installer isn't code-signed).
3. The settings window opens: paste the key (`sk-or-…`), check it, type a name and city, pick a persona, then **Save**.
4. Allow microphone access if Windows asks (Settings → Privacy & security → Microphone → "Let desktop apps access your microphone").

Mycroft lives by the clock as a round icon (behind the **^** arrow at first; drag it out to keep it visible). The colour shows what it's doing: dark = idle, red = listening, amber = thinking, blue = speaking, grey = muted, purple = waiting for a yes or no.

## Using it

- **Ctrl + Alt + Space** or **"Hey Mycroft"** to talk. Press the shortcut again to stop him mid-answer.
- Works without a model call (and offline): "set a timer for 25 minutes", "pomodoro", "remind me in 10 minutes to stretch", "remind me at 6 to call mum", "how long is left", "cancel the timer", "say that again", "mute", "stop", "use Opus", "how much have I spent", "what do you know about me", "forget that I…", "go undercover" / "blow your cover", "comrade mode", "big brother mode", "pasha mode", "steve mode", "trump mode".
- Offline he can still tell the time and date, read the battery, change the volume, open apps and take notes.
- Risky PowerShell (deleting, closing programs, shutdown, registry, installing, writing outside the user folder…) is read out first and only runs after a spoken "yes". The shortcut, silence or "no" cancels it. Rules: `mycroft_win/safety.py`.
- Notes are text files in `Documents\Mycroft Notes`.

**Trump mode** needs the clips: on the Mac run `windows/scripts/convert-trump-clips.sh`, then copy `~/Desktop/trump-for-windows` to the PC as `C:\Users\<name>\Mycroft\trump`.

## Where things are on the PC

| What | Where |
|---|---|
| App | `%LOCALAPPDATA%\Programs\Mycroft` |
| Memory, usage, settings, timers | `%APPDATA%\Mycroft` |
| Logs (`conversation.log`, `commands.log`, `mycroft.log`) | `%LOCALAPPDATA%\Mycroft\Logs` |
| OpenRouter key | Windows Credential Manager, `mycroft` |
| Start with Windows | `HKCU\…\CurrentVersion\Run\Mycroft` (installer option, or Settings) |

**Something wrong?** Start menu → **Mycroft settings check** shows what works (mic, wake word, speech model, voices, key). Send that and `mycroft.log`.

## Developing (on the Mac)

```sh
cd windows
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest
.venv/bin/python scripts/fetch_models.py     # wake-word + whisper models into build/models
.venv/bin/python -m pytest -q                # silent: no sound, no API calls
.venv/bin/python -m mycroft_win --check --voices
OPENROUTER_API_KEY=sk-or-… .venv/bin/python -m mycroft_win --cli   # text chat (paid calls)
```

The core (prompts, personas, intents, timers, memory, safety, brain) runs on any OS; tray, hotkey, SAPI voices, volume and start-at-login are Windows-only and imported only there. The tests include the real wake-word and Whisper models on speech made silently with `say -o`.

## Not ported (yet)

The robotic arm, the opening line on unlock and the goodbye before sleep. None of it has been run on a real Windows PC yet: the CI build installs, tests and starts the built app (`--check --voices`), but the mic, tray and hotkey need a person at the PC.
