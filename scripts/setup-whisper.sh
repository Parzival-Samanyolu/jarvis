#!/bin/zsh
# One-time speech-to-text setup: whisper.cpp CLI + the base.en model.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v whisper-cli >/dev/null || brew install whisper-cpp
MODELS="${JARVIS_HOME:-$HOME/Library/Application Support/Jarvis}/models"
mkdir -p "$MODELS"
[ -s "$MODELS/ggml-base.en.bin" ] || curl -L -o "$MODELS/ggml-base.en.bin" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
echo "whisper ready: $(command -v whisper-cli)"
