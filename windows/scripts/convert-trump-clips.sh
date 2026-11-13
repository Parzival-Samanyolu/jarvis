#!/bin/sh
# Converts the Mac's Trump clips (~/Mycroft/trump/*.m4a) to WAV files Windows can play, into ~/Desktop/trump-for-windows.
# Copy that folder to the PC as C:\Users\<name>\Mycroft\trump. Silent: afconvert only writes files.
set -e
src="${1:-$HOME/Mycroft/trump}"
out="${2:-$HOME/Desktop/trump-for-windows}"
mkdir -p "$out"
for f in "$src"/*.m4a "$src"/*.aiff "$src"/*.caf; do
  [ -e "$f" ] || continue
  name=$(basename "${f%.*}")
  afconvert -f WAVE -d LEI16@24000 -c 1 "$f" "$out/$name.wav"
  echo "$name.wav"
done
for f in "$src"/*.mp3 "$src"/*.wav; do [ -e "$f" ] && cp "$f" "$out/"; done
echo "Done: $out"
