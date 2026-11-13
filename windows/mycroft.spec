# PyInstaller build: two programs sharing one folder.
#   Mycroft.exe      the tray app (no console window)
#   mycroft-cli.exe  the same code with a console: --check, --cli, --set-key
# Run from windows/:  pyinstaller mycroft.spec --noconfirm
from PyInstaller.utils.hooks import collect_all

datas, binaries, hidden = [("build/models", "models"), ("../assets/logo.png", "assets")], [], []
for pkg in ("faster_whisper", "ctranslate2", "onnxruntime", "openwakeword", "edge_tts", "miniaudio", "sounddevice",
            "tokenizers", "pycaw", "comtypes", "certifi"):
    d, b, h = collect_all(pkg)
    datas += d
    binaries += b
    hidden += h
hidden += ["pystray._win32", "pynput.keyboard._win32", "pynput.mouse._win32", "keyring.backends.Windows",
           "win32com.client", "pythoncom", "pywintypes", "winsound", "tkinter", "tkinter.ttk"]

a = Analysis(["run_mycroft.py"], pathex=["."], binaries=binaries, datas=datas, hiddenimports=hidden,
             excludes=["matplotlib", "IPython", "pytest", "torch", "tensorflow"], noarchive=False)
pyz = PYZ(a.pure)

gui = EXE(pyz, a.scripts, [], exclude_binaries=True, name="Mycroft", console=False, icon="mycroft.ico",
          upx=False)
cli = EXE(pyz, a.scripts, [], exclude_binaries=True, name="mycroft-cli", console=True, icon="mycroft.ico",
          upx=False)
coll = COLLECT(gui, cli, a.binaries, a.datas, name="Mycroft", upx=False)
