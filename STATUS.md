# Status

Last updated 2026-10-19. `swift run selftest --ml` passes (180 checks).

## Built and verified here
| Spec step | State |
| --- | --- |
| 1 Terminal Q&A, persona, web search | Done. Live-tested on Haiku, Sonnet and Opus. |
| 2 Spoken answers (`say -v "Grandpa (English (UK))"`) | Done. Grandpa (UK male), falling back to Daniel. Chosen 2026-10-20 after Daniel and Ava. |
| 6 `run_command`, safety, log, retry cap, secret stripping | Done and tested (46 safety checks). A live `ls` ran. |
| 8 Memory, forget, weekly review logic | Done and tested. Haiku extraction live-tested. |
| 9 Modes, usage log, $80 cap | Done and tested. Auto = Sonnet for everything, Opus for "think deeply", Haiku only at the cap (2026-10-20). |
| 4 Wake word | Done. openWakeWord pipeline in Swift via onnxruntime. Wake phrase is "Hey Mycroft" (openWakeWord `hey_mycroft_v0.1`, switched from "Hey Jarvis" 2026-10-20). Tests: four synthetic voices fire, near-misses ("Microsoft", "Hey, my friend") and other speech do not. |
| 5 Voiceprint | Done. Wespeaker ResNet34 + Swift fbank. Enrolled voice accepted, two other voices rejected (synthetic voices). |
| 10 Notes, morning greeting | Written. Notes ordering unit-tested; live run waits on the Automation permission (see below). |
| 11 Menu bar, mute, bundle, LaunchAgent | Done. App launches and stays up, with and without an enrolled voiceprint. LaunchAgent installed and running. App icon in `assets/` (redraw with `swift scripts/make-icon.swift`). |

## Not verified (needs a person at the Mac)
1. **Microphone path.** `Recorder`, `WakeListener` and the VAD thresholds have never run on a real mic. Grant Microphone permission, then check the end-of-speech timing and wake-word sensitivity (`WakeWordDetector.threshold`, 0.5).
2. **Voice recognition removed from the app** (2026-10-20, owner's call). The `Voiceprint` code and its tests remain in JarvisCore, unused by the app.
3. **Permissions:** Microphone, Screen Recording (for `look_at_screen`), Automation (Notes), and Accessibility only if Mac-control commands need it. Ad-hoc signing means grants may reset after a rebuild.
4. **Notes** (`Notes.swift`): first run creates the "Jarvis" folder. A test run timed out waiting for the Automation prompt ("allow control of Notes"); click Allow on first use. "Latest notes" now sorts by modification date.
5. **Morning greeting** fires on `com.apple.screenIsUnlocked`. Not yet seen to fire after a real unlock.
6. **"Stop" by voice while Jarvis speaks** was removed with the voiceprint (Jarvis would hear itself). Press ⌥ Space to stop it.
7. **Wake word pre-roll:** recording starts after the wake word fires, so a request spoken in the same breath may lose its first syllable. Add a ring buffer if that happens.
8. **Screen capture** (`screencapture -x` + resize) runs and resizes to 1568 px, but the image is black until Screen Recording is granted to Jarvis.

## Decisions and deviations
- **Swift, not Python** (user request). Replacements: Carbon hotkey, energy VAD, whisper.cpp CLI, openWakeWord and Wespeaker on onnxruntime, `URLSession` for the API (no Swift SDK exists).
- **Tests are an executable** (`selftest`): Command Line Tools ship neither XCTest nor the Swift Testing macros.
- **Wake word answers anyone**, including a TV. Mute from the menu when needed. With Bluetooth headphones the always-open mic keeps them in headset mode.
- **Risky-command yes** is accepted from any voice.
- **API:** `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) is sent for Sonnet and Opus, per the API guidance. It falls back to no fallbacks if rejected. Haiku uses the older `web_search_20250305`, Sonnet/Opus the `20260209` one. Effort is `low` for Haiku, `medium` for Sonnet/Opus, `high` when asked to think deeply.
- Short-term context stores only user text and final replies (8 exchanges, 5 min idle reset), not tool traffic.
- The Haiku cost tier above 100K prompt tokens is not modelled. Spend is estimated from `usage` plus $0.01 per web search.
- Cost so far in testing: about $0.25.

## Known quirks
- Haiku sometimes drags a stale remark from an earlier turn into a new answer.
- Code is on GitHub (private): `Parzival-Samanyolu/jarvis`.
- Debug builds are used for the bundle by default in testing. Use `scripts/bundle.sh` (release) for daily use.
