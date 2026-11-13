import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    """Every test gets its own data folder and no real key; the persona starts as the butler."""
    monkeypatch.setenv("MYCROFT_HOME", str(tmp_path))
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    from mycroft_win.config import Settings
    Settings.persona_override = None
    yield tmp_path
    Settings.persona_override = None
