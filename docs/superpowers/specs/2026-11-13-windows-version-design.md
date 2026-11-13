# Mycroft for Windows — design

## Why
The owner wants Mycroft on a friend's or family member's Windows PC. The owner has no Windows PC, so whatever ships must be testable from the Mac and set up without the owner present.

## Decisions (owner's)
- Separate Windows app, not a shared Swift core.
- Core voice assistant **with all seven personas** (Butler, Undercover, Comrade, Big Brother, Pasha, Steve, Trump).
- Brain via **OpenRouter** with a separate key (the owner can cap or revoke it on openrouter.ai).
- Voices: **Microsoft online neural voices** (edge-tts).
- PC control: **yes, same safety rules** (risky commands need a spoken yes).

## Approaches considered
1. **Python + PyInstaller + Inno Setup installer** — picked. Wake word (openWakeWord, built-in `hey_mycroft`), voices (edge-tts) and speech-to-text (faster-whisper, multilingual for Pasha) are existing tested packages, and most of the code runs and is tested on the Mac. Cost: ~300 MB install, occasional antivirus false positives.
2. C# / .NET — most native, but wake word and voice protocol hand-written and untestable without Windows.
3. Electron — heavy, weak audio. Rejected.

## Shape (my calls)
- `windows/mycroft_win/`: pure-Python core (prompts, lines, intents, timers, memory, usage, safety, brain) importable on any OS; Windows-only pieces (tray, hotkey, SAPI fallback, volume, startup) imported lazily.
- OpenRouter's Anthropic-compatible endpoint `https://openrouter.ai/api/v1/messages` (Bearer key), models `anthropic/claude-{sonnet,opus,haiku}-5.5`, same tool loop, Anthropic `web_search` server tool, cost read from `usage.cost`. Router unchanged: Sonnet, Opus for "think deeply", Haiku at the cap. Default cap $20/month (it's someone else's PC).
- `run_command` runs **PowerShell**; the safety checker is rewritten for PowerShell/cmd (Remove-Item, Stop-Process, Stop-Computer, registry writes, iex, downloads piped to a shell, writes outside the user folder…).
- Extra tools `open` (installed app from the Start Menu, or URL) and `media` (play/pause, next, volume) since there is no AppleScript.
- Notes: plain text files in `Documents\Mycroft Notes`. Screen: Pillow `ImageGrab`.
- Hotkey **Ctrl+Alt+Space** (Alt+Space is the Windows window menu). Tray icon (pystray) with persona, model, mute, settings, quit.
- Voices: Ryan (en-GB) butler, Andrew (en-US) undercover, Dmitry (ru-RU reading English) comrade, Thomas (en-GB, deeper) Big Brother, Ahmet (tr-TR) Pasha, Prabhat (en-IN) Steve. Offline or edge failure → Windows SAPI voice, so offline lines still speak.
- Trump clips: `%USERPROFILE%\Mycroft\trump\*.mp3|wav` (m4a can't be decoded; `windows/scripts/convert-trump-clips.sh` converts the Mac clips to WAV).
- First run: a settings window asks for the OpenRouter key (stored in Windows Credential Manager via keyring), city, persona.
- Build: GitHub Actions on `windows-latest` runs the tests, downloads the wake-word and whisper models, builds with PyInstaller and packs an Inno Setup installer as an artifact.

## Non-goals (for now)
Robotic arm, opening line on unlock, shutdown line on sleep, voiceprint.

## Left to the builder
Exact VAD tuning on real mics, which needs a person at the PC.
