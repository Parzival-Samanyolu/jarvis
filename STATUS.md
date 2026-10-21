# Status

Last updated 2026-10-19. `swift run selftest --ml` passes (180 checks).

## Built and verified here
| Spec step | State |
| --- | --- |
| 1 Terminal Q&A, persona, web search | Done. Live-tested on Haiku, Sonnet and Opus. |
| 2 Spoken answers (`say`) | Done. Arthur (Enhanced), British, chosen 2026-10-21 after the compact voices (Daniel, Eddy, Reed, Rocko, Grandpa) were all rejected. Set by `voice` in `state.json`; otherwise the first British Premium, then Enhanced voice, then Daniel. Enhanced/Premium voices are downloaded in System Settings → Accessibility → Spoken Content → System voice → ⓘ. |
| 6 `run_command`, safety, log, retry cap, secret stripping | Done and tested (46 safety checks). A live `ls` ran. |
| 8 Memory, forget, weekly review logic | Done and tested. Haiku extraction live-tested. |
| 9 Modes, usage log, $80 cap | Done and tested. Auto = Sonnet for everything, Opus for "think deeply", Haiku only at the cap (2026-10-20). |
| 4 Wake word | Done. openWakeWord pipeline in Swift via onnxruntime. Wake phrase is "Hey Mycroft" (openWakeWord `hey_mycroft_v0.1`, switched from "Hey Jarvis" 2026-10-20). Tests: four synthetic voices fire, near-misses ("Microsoft", "Hey, my friend") and other speech do not. |
| 5 Voiceprint | Done. Wespeaker ResNet34 + Swift fbank. Enrolled voice accepted, two other voices rejected (synthetic voices). |
| 10 Notes, morning greeting | Written. Notes ordering unit-tested; live run waits on the Automation permission (see below). |
| 11 Menu bar, mute, bundle, LaunchAgent | Done. App launches and stays up, with and without an enrolled voiceprint. LaunchAgent installed and running. App icon in `assets/` (redraw with `swift scripts/make-icon.swift`). |

## Settings (2026-10-21)
Settings… (⌘,) in the menu bar, or `mycroft --settings`. Saved in `state.json`, applied immediately. General: voice + sample, speaking speed, jokes (every reply / every other / rarely / never), opening line, shutdown line, daily briefing, wake word, follow-up listening, home city, start at login (`launchctl enable/disable`). Brain & Usage: model, fast/cheaper web search, monthly cap, this month by model. Memory: learned facts, delete one or all. Clicking through the controls has not been tested by hand; the General tab was checked by screenshot.

## Not verified (needs a person at the Mac)
1. **Microphone path.** `Recorder`, `WakeListener` and the VAD thresholds have never run on a real mic. Grant Microphone permission, then check the end-of-speech timing and wake-word sensitivity (`WakeWordDetector.threshold`, 0.5).
2. **Voice recognition removed from the app** (2026-10-20, owner's call). The `Voiceprint` code and its tests remain in MycroftCore, unused by the app.
3. **Permissions:** Microphone, Screen Recording (for `look_at_screen`), Automation (Notes), and Accessibility only if Mac-control commands need it. Ad-hoc signing means grants may reset after a rebuild.
4. **Notes** (`Notes.swift`): first run creates the "Mycroft" folder (an existing "Jarvis" folder is renamed, notes kept). A test run timed out waiting for the Automation prompt ("allow control of Notes"); click Allow on first use. "Latest notes" now sorts by modification date.
5. **Opening line** fires on launch and on `com.apple.screenIsUnlocked` (at most once a minute). Not yet seen to fire after a real unlock. **Shutdown line before sleep** has not been heard on a real lid close.
6. **"Stop" by voice while Mycroft speaks** was removed with the voiceprint (Mycroft would hear itself). Press ⌥ Space to stop it.
7. **Wake word pre-roll:** recording starts after the wake word fires, so a request spoken in the same breath may lose its first syllable. Add a ring buffer if that happens.
8. **Screen capture** (`screencapture -x` + resize) runs and resizes to 1568 px, but the image is black until Screen Recording is granted to Mycroft.

## Decisions and deviations
- **Swift, not Python** (user request). Replacements: Carbon hotkey, energy VAD, whisper.cpp CLI, openWakeWord and Wespeaker on onnxruntime, `URLSession` for the API (no Swift SDK exists).
- **Tests are an executable** (`selftest`): Command Line Tools ship neither XCTest nor the Swift Testing macros.
- **Wake word answers anyone**, including a TV. Mute from the menu when needed. With Bluetooth headphones the always-open mic keeps them in headset mode.
- **Risky-command yes** is accepted from any voice.
- **API:** `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) is sent for Sonnet and Opus, per the API guidance. It falls back to no fallbacks if rejected. Replies stream (SSE) and are spoken sentence by sentence; a short holding line plays before a tool call if nothing has been said yet. All models use the basic `web_search_20250305`: the `20260209` variant's result filtering roughly doubled time to a spoken answer (2026-10-21). Effort is `low`, `high` when asked to think deeply (2026-10-21, was `medium` for Sonnet/Opus).
- **Persona and fixed lines** (2026-10-21) come from the owner's butler brief. Fixed lines (`Lines.swift`) are spoken word for word without the model: the opening line at every launch and unlock ("Bloody hell mate, let's colonize India." before noon, a random "Systems online" line after), error lines when a request fails outright, and a shutdown line on quit and before sleep (IOKit holds sleep until it has been said, 10 s at most). The daily briefing (weather, notes) follows the opening line on the first unlock of the day.
- Short-term context stores only user text and final replies (8 exchanges, 5 min idle reset), not tool traffic.
- The Haiku cost tier above 100K prompt tokens is not modelled. Spend is estimated from `usage` plus $0.01 per web search.
- Cost so far in testing: about $0.25.

## Known quirks
- Haiku sometimes drags a stale remark from an earlier turn into a new answer.
- Code is on GitHub (private): `Parzival-Samanyolu/jarvis`.
- Debug builds are used for the bundle by default in testing. Use `scripts/bundle.sh` (release) for daily use.
