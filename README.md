# Jarvis for Mac

A voice assistant for the M1 MacBook Air: answers questions, runs terminal commands, reads the screen on request, keeps notes and learns about its owner. Swift, one menu-bar app, Claude API for the brain. Spec: `Jarvis for Mac — Spec.md`.

## Quick start

```sh
brew install whisper-cpp onnxruntime        # speech-to-text, wake word and voiceprint runtime
scripts/setup-whisper.sh                     # fetches the whisper base.en model
swift run jarvis --set-key                   # stores the Anthropic key in the Keychain (or export ANTHROPIC_API_KEY)
swift run jarvis --cli                       # terminal chat (add --speak to hear it)
scripts/install.sh                           # builds, installs /Applications/Jarvis.app, starts it at login
```

`scripts/install.sh uninstall` removes the app and login item and keeps your data. `jarvis --test-record 5` checks the current mic.

## Where things live

| What | Where |
|---|---|
| App | `/Applications/Jarvis.app` |
| Memory, usage, settings (`memory.md`, `usage.jsonl`, `state.json`) | `~/Library/Application Support/Jarvis/` |
| Models (`models/`: whisper `ggml-base.en.bin`, openWakeWord `melspectrogram.onnx`, `embedding_model.onnx`, `hey_jarvis_v0.1.onnx`) | `~/Library/Application Support/Jarvis/models/` |
| Logs: `conversation.log` (what Jarvis heard and said), `commands.log`, `jarvis.log` (errors) | `~/Library/Logs/Jarvis/` |
| API key | Keychain, service `jarvis` |
| Login item | `~/Library/LaunchAgents/com.jarvis.app.plist` |

`JARVIS_HOME` puts data and logs in one folder instead (for development). The installer moves data from the old layout (files in the repo folder) on first run.

## Layout

- `Sources/JarvisCore/` — everything testable: `Brain` (Messages API over `URLSession`, tool loop), `Models` (router, intents), `Usage` ($80 cap), `Safety`, `Secrets`, `Tools` (run_command, screen, battery), `Memory`, `Notes`, `Speech`, `Audio` (VAD, WAV), `Voiceprint`, `WakeWord`, `Onnx`, `Prompts`.
- `Sources/COrt/` — C shim over the onnxruntime C API.
- `Sources/jarvis/` — the app: `App` (menu bar, state machine), `Audio` (recorder, wake listener, whisper), `Hotkey`, `main` (`--cli`, `--set-key`).
- `Sources/selftest/` — test runner (`swift run selftest`, `--ml` adds the wake-word and voiceprint tests).
- Prompts are in `Prompts.swift` rather than a `prompts/` folder.



## Usage

⌥ Space starts listening; pressing it again stops Jarvis mid-answer. Or say "Hey Jarvis". There is no voice recognition: Jarvis answers anyone it hears. Voice commands: "use Opus", "how much have I spent", "what do you know about me", "forget that I…", "mute", "stop".
