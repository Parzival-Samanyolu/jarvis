"""Spend tracking and the monthly cap. OpenRouter reports each reply's real cost in usage.cost."""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

from .config import Paths, Settings

# USD per million tokens (input, output, cache read): only used if OpenRouter leaves out usage.cost.
PRICES = {"haiku": (0.10, 0.50, 0.01), "sonnet": (2.00, 10.00, 0.20), "opus": (4.00, 20.00, 0.20)}
SEARCH_COST = 0.01
LABELS = {"haiku": "Haiku", "sonnet": "Sonnet", "opus": "Opus"}


@dataclass
class Record:
    ts: str
    model: str
    input: int
    output: int
    cache_read: int
    searches: int
    cost: float


def estimate(model: str, input: int, output: int, cache_read: int, cache_write: int, searches: int) -> float:
    p = PRICES.get(model, PRICES["sonnet"])
    return (input * p[0] + output * p[1] + cache_read * p[2] + cache_write * p[0] * 1.25) / 1e6 + searches * SEARCH_COST


class Usage:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or Paths.usage()

    def record(self, model: str, usage: dict, now: datetime | None = None) -> Record:
        inp = int(usage.get("input_tokens") or 0)
        out = int(usage.get("output_tokens") or 0)
        cache = int(usage.get("cache_read_input_tokens") or 0)
        write = int(usage.get("cache_creation_input_tokens") or 0)
        searches = int(((usage.get("server_tool_use") or {}).get("web_search_requests")) or 0)
        cost = usage.get("cost")
        cost = float(cost) if isinstance(cost, (int, float)) else estimate(model, inp, out, cache, write, searches)
        r = Record((now or datetime.now()).isoformat(timespec="seconds"), model, inp, out, cache, searches, cost)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(asdict(r)) + "\n")
        return r

    def records(self) -> list[Record]:
        try:
            lines = self.path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        out = []
        for l in lines:
            try:
                out.append(Record(**json.loads(l)))
            except (ValueError, TypeError):
                pass
        return out

    def month(self, now: datetime | None = None) -> list[Record]:
        prefix = (now or datetime.now()).strftime("%Y-%m")
        return [r for r in self.records() if r.ts.startswith(prefix)]

    def month_total(self, now: datetime | None = None) -> float:
        return sum(r.cost for r in self.month(now))

    def cap_reached(self, now: datetime | None = None) -> bool:
        return self.month_total(now) >= Settings.cap()

    def near_cap(self, now: datetime | None = None) -> bool:
        t = self.month_total(now)
        return 0.9 * Settings.cap() <= t < Settings.cap()

    def report(self, now: datetime | None = None) -> str:
        split: dict[str, float] = {}
        for r in self.month(now):
            split[r.model] = split.get(r.model, 0) + r.cost
        parts = [f"${v:.2f} on {LABELS.get(k, k)}" for k, v in sorted(split.items(), key=lambda kv: -kv[1]) if v >= 0.005]
        s = f"This month you've spent ${self.month_total(now):.2f} of your {int(Settings.cap())} dollar cap, sir"
        return s + (": " + ", ".join(parts) if parts else "") + "."
