"""The OpenRouter key (Windows Credential Manager via keyring) and stripping secrets from command output."""
from __future__ import annotations

import os
import re

SERVICE = "mycroft"
ACCOUNT = "openrouter-api-key"


def api_key() -> str | None:
    if k := os.environ.get("OPENROUTER_API_KEY"):
        return k
    try:
        import keyring
        return keyring.get_password(SERVICE, ACCOUNT) or None
    except Exception:
        return None


def set_api_key(key: str) -> bool:
    try:
        import keyring
        keyring.set_password(SERVICE, ACCOUNT, key.strip())
        return True
    except Exception:
        return False


def looks_like_key(key: str) -> bool:
    return bool(re.fullmatch(r"sk-or-[A-Za-z0-9_\-]{20,}", key.strip()))


_PATTERNS = [
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----", "[REDACTED PRIVATE KEY]"),
    (r"sk-ant-[A-Za-z0-9_\-]{8,}", "[REDACTED]"),
    (r"sk-or-[A-Za-z0-9_\-]{8,}", "[REDACTED]"),
    (r"sk-[A-Za-z0-9_\-]{20,}", "[REDACTED]"),
    (r"gh[pousr]_[A-Za-z0-9]{20,}", "[REDACTED]"),
    (r"github_pat_[A-Za-z0-9_]{20,}", "[REDACTED]"),
    (r"xox[abprs]-[A-Za-z0-9\-]{10,}", "[REDACTED]"),
    (r"AKIA[0-9A-Z]{16}", "[REDACTED]"),
    (r"AIza[0-9A-Za-z_\-]{30,}", "[REDACTED]"),
    (r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}", "[REDACTED JWT]"),
    (r"(?i)(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{16,}", r"\1 [REDACTED]"),
    (r"(?i)://([^/\s:@]+):([^@\s/]+)@", r"://\1:[REDACTED]@"),
    (r"(?i)\b([A-Za-z0-9_.\-]*(?:password|passwd|passphrase|secret|token|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|credential|auth)[A-Za-z0-9_.\-]*)(\s*[=:]\s*)(\"[^\"]*\"|'[^']*'|[^\s\"',;]+)",
     r"\1\2[REDACTED]"),
]
_COMPILED = [(re.compile(p), r) for p, r in _PATTERNS]


def strip(text: str) -> str:
    for rx, rep in _COMPILED:
        text = rx.sub(rep, text)
    return text
