#!/bin/zsh
# One-time speech-to-text setup: whisper.cpp CLI + the base.en model.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v whisper-cli >/dev/null || brew install whisper-cpp
mkdir -p models
[ -s models/ggml-base.en.bin ] || curl -L -o models/ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
echo "whisper ready: $(command -v whisper-cli)"
