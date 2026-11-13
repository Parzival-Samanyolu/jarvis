"""Downloads the models bundled into the installer: openWakeWord (hey_mycroft + feature models) and faster-whisper base.

    python scripts/fetch_models.py            -> windows/build/models
"""
import sys
from pathlib import Path

out = Path(__file__).resolve().parent.parent / "build" / "models"
out.mkdir(parents=True, exist_ok=True)

from openwakeword import utils  # noqa: E402

utils.download_models(["hey_mycroft"], target_directory=str(out))
# Keep only what the app loads.
keep = {"melspectrogram.onnx", "embedding_model.onnx"}
for p in out.iterdir():
    if p.is_file() and p.name not in keep and not p.name.startswith("hey_mycroft") or p.suffix == ".tflite":
        p.unlink()

from faster_whisper import download_model  # noqa: E402

download_model("base", output_dir=str(out / "whisper-base"))
import shutil  # noqa: E402

shutil.rmtree(out / "whisper-base" / ".cache", ignore_errors=True)   # download bookkeeping, not needed

missing = [n for n in ("melspectrogram.onnx", "embedding_model.onnx", "whisper-base/model.bin") if not (out / n).exists()]
if missing or not list(out.glob("hey_mycroft*.onnx")):
    sys.exit(f"missing models: {missing or 'hey_mycroft'}")
print("models ready in", out)
for p in sorted(out.rglob("*")):
    if p.is_file():
        print(f"  {p.relative_to(out)}  {p.stat().st_size // 1024} KB")
