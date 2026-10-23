# Status

Last updated 2026-10-22. `swift run selftest` passes (376 checks, silent, no API calls).

## Built and verified here
| Spec step | State |
| --- | --- |
| 1 Terminal Q&A, persona, web search | Done. Live-tested on Haiku, Sonnet and Opus. |
| 2 Spoken answers (`say`) | Done. Arthur (Enhanced), British, chosen 2026-10-21 after the compact voices (Daniel, Eddy, Reed, Rocko, Grandpa) were all rejected. Set by `voice` in `state.json`; otherwise the first British Premium, then Enhanced voice, then Daniel. Enhanced/Premium voices are downloaded in System Settings → Accessibility → Spoken Content → System voice → ⓘ. |
| 6 `run_command`, safety, log, retry cap, secret stripping | Done and tested (46 safety checks). A live `ls` ran. |
| 8 Memory, forget, weekly review logic | Done and tested. Haiku extraction live-tested. |
| 9 Modes, usage log, $80 cap | Done and tested. Auto = Sonnet for everything, Opus for "think deeply", Haiku only at the cap (2026-10-20). |
| 4 Wake word | Done. openWakeWord pipeline in Swift via onnxruntime. Wake phrase is "Hey Mycroft" (openWakeWord `hey_mycroft_v0.1`, switched from "Hey Jarvis" 2026-10-20). Tests: four synthetic voices fire, near-misses ("Microsoft", "Hey, my friend") and other speech do not. |
| 10 Notes, morning greeting | Written. Notes ordering unit-tested; live run waits on the Automation permission (see below). |
| 11 Menu bar, mute, bundle, LaunchAgent | Done. App launches and stays up, with and without an enrolled voiceprint. LaunchAgent installed and running. App icon in `assets/` (redraw with `swift scripts/make-icon.swift`). |

## Settings (2026-10-21)
Settings… (⌘,) in the menu bar, or `mycroft --settings`. Saved in `state.json`, applied immediately. General: voice + sample, speaking speed, jokes (every reply / every other / rarely / never), opening line, shutdown line, daily briefing, wake word, follow-up listening, home city, start at login (`launchctl enable/disable`). Brain & Usage: model, fast/cheaper web search, monthly cap, this month by model. Memory: learned facts, delete one or all. Clicking through the controls has not been tested by hand; the General tab was checked by screenshot.

## Added 2026-10-22
- **Power actions need a yes:** `pmset sleepnow` / `shutdown` / `restart` / schedules, and osascript "shut down", "restart", "sleep", "log out". Both had run unasked on 2026-10-21. (A Music playlist named "Sleep" now asks too.)
- **Name fix:** a transcript starting "Minecraft," / "Microsoft," / "My craft," is read as "Mycroft," (it had tried `open -a Minecraft`). "Open Minecraft" is left alone.
- **No false "done":** the prompt says to check the result (e.g. Music player state) before saying it worked, and lists the installed apps so `open -a` uses real names (it had tried Google Chrome, Chrome, then Chromium).
- **"Say that again"** replays the last line locally: free, word for word.
- **Timers and reminders:** "set a timer for 25 minutes", "pomodoro" (25 min), "remind me in 10 minutes to stretch", "how long is left", "cancel the timer" run locally (offline too). The model also has a `timer` tool for anything else. "Remind me at 6 to ..." works too (6 means the next 6 o'clock). When one ends: Glass chime, then the line, once no conversation is open. Saved in `timers.json`, so they survive a restart; they run on the wall clock, so one due during sleep fires on wake, and one that ended while Mycroft was closed (within 12 hours) is announced at launch.
- **Wake-word pre-roll:** audio after "Hey Mycroft" is kept by the wake listener and put in front of the recording; the wake listener stays open until the recorder's mic delivers audio, so two engines share the mic for a moment.
- **"Hey Mycroft" interrupts** an answer: the wake listener also runs while Mycroft speaks in a conversation. Risk: it could, rarely, trigger on its own voice.
- **Voiceprint code removed** (`Voiceprint.swift` had never been committed: `.gitignore`'s `voiceprint.*` matched it case-insensitively).
- **Robotic arm (Arduino):** `arm/mycroft_arm` sketch (6 servos, smooth moves, firmware limits, line protocol) and `Arm.swift` (USB serial, `arm.json` joints and poses, `arm` tool: move, nudge, gripper, home, poses, sequences, speed, stop, relax). "Stop the arm" / "freeze" / ⌥ Space / "stop" halt it at once; gripper and home commands run locally. Tested against a simulated Arduino on a pseudo-terminal; the sketch hasn't been compiled here (no arduino-cli) or run on hardware. SO-101 (Feetech bus servos) is next.
- **Undercover mode** (menu bar → Undercover mode, or say "go undercover" / "blow your cover"): American voice (a Premium US voice if installed, else Evan (Enhanced)), a friendly, casual persona with no politics, countries or "sir", its own opening, error, shutdown, offline and gesture lines, and every fixed butler line rewritten casually. The menu-bar icon becomes sunglasses. Saved in `state.json` as `undercover`; toggling clears the short-term history. The Settings voice picker sets the butler's voice only.
- None of this has been run on the real mic or heard yet.

## Not verified (needs a person at the Mac)
1. **Microphone path.** `Recorder`, `WakeListener` and the VAD thresholds have never run on a real mic. Grant Microphone permission, then check the end-of-speech timing and wake-word sensitivity (`WakeWordDetector.threshold`, 0.5).
2. **Voice recognition removed** (2026-10-20, owner's call; code deleted 2026-10-22).
3. **Permissions:** Microphone, Screen Recording (for `look_at_screen`), Automation (Notes), and Accessibility only if Mac-control commands need it. Ad-hoc signing means grants may reset after a rebuild.
4. **Notes** (`Notes.swift`): first run creates the "Mycroft" folder (an existing "Jarvis" folder is renamed, notes kept). A test run timed out waiting for the Automation prompt ("allow control of Notes"); click Allow on first use. "Latest notes" now sorts by modification date.
5. **Opening line** fires on launch and on `com.apple.screenIsUnlocked` (at most once a minute). Not yet seen to fire after a real unlock. **Shutdown line before sleep** has not been heard on a real lid close.
6. **Stopping Mycroft mid-answer:** say "Hey Mycroft" (2026-10-22) or press ⌥ Space.
7. **Wake word pre-roll** (2026-10-22): check that "Hey Mycroft what time is it" in one breath keeps "what".
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
