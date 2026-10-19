# Status

Last updated 2026-10-19. `swift run selftest --ml` passes (177 checks).

## Built and verified here
| Spec step | State |
| --- | --- |
| 1 Terminal Q&A, persona, web search | Done. Live-tested on Haiku, Sonnet and Opus. |
| 2 Spoken answers (`say -v Daniel`) | Done. Uses "Daniel (Premium)" or "(Enhanced)" if installed, else Daniel. |
| 6 `run_command`, safety, log, retry cap, secret stripping | Done and tested (46 safety checks). A live `ls` ran. |
| 8 Memory, forget, weekly review logic | Done and tested. Haiku extraction live-tested. |
| 9 Modes, usage log, $80 cap | Done and tested (Auto routing, cap, monthly reset). |
| 4 Wake word | Done. openWakeWord pipeline in Swift via onnxruntime. Scores 0.99+ on synthetic "Hey Jarvis", about 0.00001 on other speech and silence. |
| 5 Voiceprint | Done. Wespeaker ResNet34 + Swift fbank. Enrolled voice accepted, two other voices rejected (synthetic voices). |
| 10 Notes, morning greeting | Written. AppleScript compiles but has never run. |
| 11 Menu bar, mute, bundle, LaunchAgent | Written. App launches and stays up, with and without an enrolled voiceprint. |

## Not verified (needs a person at the Mac)
1. **Microphone path.** `Recorder`, `WakeListener` and the VAD thresholds have never run on a real mic. Grant Microphone permission, then check the end-of-speech timing and wake-word sensitivity (`WakeWordDetector.threshold`, 0.5).
2. **Voiceprint threshold** is 0.6, chosen from synthetic voices. Enroll with your real voice, watch `voice score` in Console (`log stream --process jarvis`), then edit `threshold` in `voiceprint.json`.
3. **Permissions:** Microphone, Screen Recording (for `look_at_screen`), Automation (Notes), and Accessibility only if Mac-control commands need it. Ad-hoc signing means grants may reset after a rebuild.
4. **Notes** (`Notes.swift`): first run creates the "Jarvis" folder. "Latest notes" assumes Notes returns newest first, which is not guaranteed.
5. **Morning greeting** fires on `com.apple.screenIsUnlocked`. Not yet seen to fire after a real unlock.
6. **"Stop" by voice while Jarvis speaks** relies on the voiceprint rejecting Jarvis's own voice through the speakers. Untested with real audio. The hotkey always works.
7. **Wake word pre-roll:** recording starts after the wake word fires, so a request spoken in the same breath may lose its first syllable. Add a ring buffer if that happens.
8. **Screen capture** (`screencapture -x` + resize) has not been run.
9. **LaunchAgent** is written but not installed. Run `scripts/install-launchagent.sh`.
10. **Private GitHub repo `jarvis`:** not created, nothing pushed. Needs `gh auth login` then `gh repo create jarvis --private --source . --push`.

## Decisions and deviations
- **Swift, not Python** (user request). Replacements: Carbon hotkey, energy VAD, whisper.cpp CLI, openWakeWord and Wespeaker on onnxruntime, `URLSession` for the API (no Swift SDK exists).
- **Tests are an executable** (`selftest`): Command Line Tools ship neither XCTest nor the Swift Testing macros.
- **Wake word needs an enrolled voice.** Without one it stays off, so a TV cannot trigger Jarvis. Hotkey always works.
- **Hotkey skips the voice check** for the first request only. Follow-ups, confirmations ("Shall I proceed, sir?") and "stop" are all voice-checked.
- **Risky-command yes** also goes through the voiceprint when one is enrolled.
- **API:** `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) is sent for Sonnet and Opus, per the API guidance. It falls back to no fallbacks if rejected. Haiku uses the older `web_search_20250305`, Sonnet/Opus the `20260209` one. Effort is `low` for Haiku, `medium` for Sonnet/Opus, `high` when asked to think deeply.
- Short-term context stores only user text and final replies (8 exchanges, 5 min idle reset), not tool traffic.
- The Haiku cost tier above 100K prompt tokens is not modelled. Spend is estimated from `usage` plus $0.01 per web search.
- Cost so far in testing: about $0.25.

## Known quirks
- Haiku sometimes drags a stale remark from an earlier turn into a new answer.
- Debug builds are used for the bundle by default in testing. Use `scripts/bundle.sh` (release) for daily use.
