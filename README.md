# Mycroft for Mac

A voice assistant for the M1 MacBook Air: answers questions, runs terminal commands, reads the screen on request, keeps notes and learns about its owner. Swift, one menu-bar app, Claude API for the brain. Spec: `Jarvis for Mac — Spec.md` (written before the rename).

## Quick start

```sh
brew install whisper-cpp onnxruntime        # speech-to-text and wake-word runtime
scripts/setup-whisper.sh                     # fetches the whisper base.en model
swift run mycroft --set-key                   # stores the Anthropic key in the Keychain (or export ANTHROPIC_API_KEY)
swift run mycroft --cli                       # terminal chat (add --speak to hear it)
scripts/install.sh                           # builds, installs /Applications/Mycroft.app, starts it at login
```

`scripts/install.sh uninstall` removes the app and login item and keeps your data. `mycroft --test-record 5` checks the current mic.

## Where things live

| What | Where |
|---|---|
| App | `/Applications/Mycroft.app` (called Jarvis before 2026-10-20; the installer and app move old Jarvis data, key and Notes folder over) |
| Memory, usage, settings (`memory.md`, `usage.jsonl`, `state.json`) | `~/Library/Application Support/Mycroft/` |
| Models (`models/`: whisper `ggml-base.en.bin`, openWakeWord `melspectrogram.onnx`, `embedding_model.onnx`, `hey_mycroft_v0.1.onnx`) | `~/Library/Application Support/Mycroft/models/` |
| Logs: `conversation.log` (what Mycroft heard and said), `commands.log`, `mycroft.log` (errors) | `~/Library/Logs/Mycroft/` |
| API key | Keychain, service `mycroft` |
| Login item | `~/Library/LaunchAgents/com.mycroft.app.plist` |

`MYCROFT_HOME` puts data and logs in one folder instead (for development). The installer moves data from the old Jarvis folders on first run.

## Layout

- `Sources/MycroftCore/` — everything testable: `Brain` (Messages API over `URLSession`, tool loop), `Models` (router, intents), `Usage` ($80 cap), `Safety`, `Secrets`, `Tools` (run_command, screen, battery, installed apps), `Memory`, `Notes`, `Speech`, `Audio` (VAD, WAV), `Timers`, `WakeWord`, `Onnx`, `Prompts`.
- `Sources/COrt/` — C shim over the onnxruntime C API.
- `Sources/mycroft/` — the app: `App` (menu bar, state machine), `Audio` (recorder, wake listener, whisper), `Hotkey`, `main` (`--cli`, `--set-key`).
- `arm/` — Arduino sketch for the robotic arm (see `arm/README.md`); `MycroftCore/Arm.swift` drives it over USB serial.
- `Sources/selftest/` — test runner (`swift run selftest`, `--ml` adds the wake-word tests).
- Prompts are in `Prompts.swift` rather than a `prompts/` folder.



## Usage

⌥ Space starts listening; pressing it again stops Mycroft mid-answer. Or say "Hey Mycroft", which also cuts Mycroft short while it is talking. There is no voice recognition: Mycroft answers anyone it hears. Voice commands: "use Opus", "how much have I spent", "what do you know about me", "forget that I…", "mute", "stop", "say that again" (replays the last reply for free), "set a timer for 25 minutes", "pomodoro", "remind me in 10 minutes to stretch", "remind me at 6 to call mum", "how long is left", "cancel the timer", "go undercover" / "blow your cover" (undercover mode: American voice, friendly, no politics; also in the menu). These run on the Mac without a model call, offline too.
