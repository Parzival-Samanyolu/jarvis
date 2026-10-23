# Mycroft arm (Arduino)

1. Wire the servos: base D3, shoulder D5, elbow D6, wrist pitch D9, wrist roll D10, gripper D11. Power the servos from their own 5–6 V supply, not the Arduino's 5 V pin, and join the grounds.
2. Change the `joints[]` table in `mycroft_arm/mycroft_arm.ino` if your pins, limits or home angles differ. Start with narrow limits and widen them once you've seen each joint move.
3. Upload the sketch with the Arduino IDE (board: your Uno/Nano/Mega; ESP32 needs `ESP32Servo`).
4. Plug the Arduino into the Mac by USB. Mycroft finds it on first use (`/dev/cu.usbmodem…` or `cu.usbserial…`).
5. If you changed limits or home angles, put the same values in `~/Library/Application Support/Mycroft/arm.json` (created when you first save a pose; Mycroft also clamps to it).

Say "stop the arm" or "freeze", or press ⌥ Space, to halt it at once. "Open/close the gripper" and "home the arm" run without the model, and so do the gestures, each with a butler line while it moves:

| Say | Gesture |
|---|---|
| "salute", "give me a salute" | salute to the brow, snap back |
| "take a bow" | slow butler's bow |
| "do the royal wave" | slow royal hand-turn |
| "wave", "say hello", "wave goodbye" | quick wave |
| "nod", "say yes" / "shake your head", "say no" | yes / no |
| "pour me some tea", "tea time" | lift, tilt to pour, level |
| "point", "point the way" | arm straight out |
| "mic drop" | hold, then open the gripper |
| "celebrate", "fist pump", "rule Britannia" | three fist pumps |

Their angles are first guesses. To tune one, add it under `"gestures"` in `arm.json`, e.g. `"bow": [{"angles": {"shoulder": 45, "elbow": 120}, "speed": 35, "pause": 1.5}]`. Every gesture ends at home. Anything else ("turn left a bit", "remember this as pick-up") goes through Claude's `arm` tool.

Anyone Mycroft hears can move the arm. Keep the limits safe and the arm clear of faces.
