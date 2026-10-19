# Jarvis for Mac

A voice assistant for the M1 MacBook Air: answers questions, runs terminal commands, reads the screen on request, keeps notes and learns about its owner. Swift, one menu-bar app, Claude API for the brain. Spec: `Jarvis for Mac — Spec.md`.

## Quick start

```sh
brew install whisper-cpp onnxruntime        # speech-to-text, wake word and voiceprint runtime
scripts/setup-whisper.sh                     # fetches the whisper base.en model into models/
swift run jarvis --set-key                   # stores the Anthropic key in the Keychain (or export ANTHROPIC_API_KEY)
swift run jarvis --cli                       # terminal chat (add --speak to hear it)
scripts/bundle.sh                            # builds Jarvis.app (menu-bar only, ad-hoc signed)
open Jarvis.app
scripts/install-launchagent.sh               # optional: start at login
```

Models for the wake word and voiceprint live in `models/` (git-ignored): `melspectrogram.onnx`, `embedding_model.onnx`, `hey_jarvis_v0.1.onnx` (openWakeWord v0.5.1 releases) and `voxceleb_resnet34_LM.onnx` (Wespeaker, Hugging Face).

## Layout

- `Sources/JarvisCore/` — everything testable: `Brain` (Messages API over `URLSession`, tool loop), `Models` (router, intents), `Usage` ($80 cap), `Safety`, `Secrets`, `Tools` (run_command, screen, battery), `Memory`, `Notes`, `Speech`, `Audio` (VAD, WAV), `Voiceprint`, `WakeWord`, `Onnx`, `Prompts`.
- `Sources/COrt/` — C shim over the onnxruntime C API.
- `Sources/jarvis/` — the app: `App` (menu bar, state machine), `Audio` (recorder, wake listener, whisper), `Hotkey`, `main` (`--cli`, `--set-key`).
- `Sources/selftest/` — test runner (`swift run selftest`, `--ml` adds the wake-word and voiceprint tests).
- Prompts are in `Prompts.swift` rather than a `prompts/` folder.

Personal data (`memory.md`, `usage.jsonl`, `commands.log`, `voiceprint.json`, `state.json`, `models/`) is git-ignored. `JARVIS_HOME` overrides the data directory.

## Usage

⌥ Space starts listening; pressing it again stops Jarvis mid-answer. Say "Hey Jarvis" once your voice is enrolled (menu → Enroll my voice…). Voice commands: "use Opus", "how much have I spent", "what do you know about me", "forget that I…", "mute", "stop".
