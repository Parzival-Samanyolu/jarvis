from datetime import date, datetime

import numpy as np

from mycroft_win import intents, lines, offline, prompts, trump
from mycroft_win.audio import EndpointDetector, Mic, clean_transcript
from mycroft_win.config import Mode, Persona, Settings, State
from mycroft_win.memory import Conversation, Memory
from mycroft_win.streaming import SentenceSplitter, StreamAssembler
from mycroft_win.timers import Timers, duration, seconds_until_clock_time, spoken
from mycroft_win.usage import Usage
from mycroft_win import keys


# Intents

def test_timer_intents():
    assert intents.parse("Set a timer for 25 minutes") == intents.Intent("timer", 1500)
    assert intents.parse("pomodoro") == intents.Intent("timer", 1500)
    assert intents.parse("Mycroft, remind me in 10 minutes to drink water") == intents.Intent("timer", 600, "drink water")
    assert intents.parse("set a timer for an hour and a half").arg == 5400
    assert intents.parse("how long is left").kind == "timer_status"
    assert intents.parse("cancel the timer").kind == "cancel_timers"
    r = intents.parse("remind me at 6 to call mum", now=datetime(2026, 11, 13, 16, 0))
    assert r.kind == "timer" and r.arg == 2 * 3600 and r.label == "call mum"


def test_other_intents():
    assert intents.parse("say that again").kind == "repeat"
    assert intents.parse("Pardon?").kind == "repeat"
    assert intents.parse("stop").kind == "stop"
    assert intents.parse("mute").kind == "mute"
    assert intents.parse("use opus") == intents.Intent("set_mode", Mode.opus)
    assert intents.parse("how much have I spent").kind == "spend"
    assert intents.parse("what do you know about me").kind == "what_do_you_know"
    assert intents.parse("forget that I'm vegan") == intents.Intent("forget", "am vegan")
    assert intents.parse("go undercover") == intents.Intent("persona", Persona.undercover)
    assert intents.parse("blow your cover") == intents.Intent("persona", Persona.butler)
    assert intents.parse("pasha mode") == intents.Intent("persona", Persona.pasha)
    assert intents.parse("what's the weather like").kind == "none"


def test_router():
    assert intents.route("hello", Mode.auto, False) == "sonnet"
    assert intents.route("think deeply about this", Mode.auto, False) == "opus"
    assert intents.route("think deeply", Mode.opus, True) == "haiku"
    assert intents.route("hi", Mode.haiku, False) == "haiku"
    assert intents.MODELS["sonnet"] == "anthropic/claude-sonnet-5.5"


def test_yes_no():
    assert intents.yes_no("Yes please") == "yes"
    assert intents.yes_no("Evet") == "yes"
    assert intents.yes_no("no, don't") == "no"
    assert intents.yes_no("hayır") == "no"
    assert intents.yes_no("hmm") == "unclear"
    assert intents.keep_or_delete("delete it") is False
    assert intents.keep_or_delete("keep") is True


# Timers

def test_timer_words():
    assert spoken(1500) == "25 minutes"
    assert spoken(5400) == "1 hour and 30 minutes"
    assert spoken(1500, plural=False) == "25 minute"
    assert duration("in half an hour")[0] == 1800
    assert duration("nothing here") is None
    s, _ = seconds_until_clock_time("at 6:30 pm", datetime(2026, 1, 1, 18, 0))
    assert s == 1800
    s, _ = seconds_until_clock_time("at 6", datetime(2026, 1, 1, 7, 0))
    assert s == 11 * 3600


def test_timers_persist_and_fire(isolated_home):
    f = isolated_home / "timers.json"
    t = Timers(f)
    t.start(3600, "stretch", now=1000)
    assert "remind you to stretch" in t.status(now=1000)
    t2 = Timers(f)
    fired = []
    t2.on_fire = fired.append
    t2.restore(now=1000 + 3600 + 5)    # ended while closed: fires late
    import time
    time.sleep(0.2)
    assert fired and fired[0].announcement == "Sir, you asked me to remind you to stretch."
    assert t.cancel_all() == 1


# Lines and personas

def test_in_persona():
    assert lines.in_persona("Timer set for 25 minutes, sir.", Persona.undercover) == "Timer set for 25 minutes."
    assert lines.in_persona("Very good, sir.", Persona.comrade) == "Very good, comrade."
    assert lines.in_persona("Sir, your 5 minute timer is up.", Persona.pasha) == "Evladım, zamanlayıcın doldu."
    assert lines.in_persona("Very good, sir.", Persona.techSupport) == "Very good, sir."
    assert lines.casual("I'm afraid I can't help with that one, sir.") == "Sorry, I can't help with that one."


def test_picker_never_repeats():
    p = lines.LinePicker()
    seen = [p.error() for _ in range(30)]
    assert all(a != b for a, b in zip(seen, seen[1:]))
    assert p.opening(datetime(2026, 1, 1, 9)) == lines.MORNING
    for persona in Persona:
        for kind in ("errors", "offline", "shutdown", "working", "searching"):
            assert lines.for_persona(kind, persona)


def test_prompts_mention_windows_not_mac():
    for p in Persona:
        Settings.persona_override = p
        s = prompts.system("- [2026-01-01] Likes tea.", ["Spotify", "Google Chrome"])
        assert "Windows" in s and "MacBook" not in s and "osascript" not in s and "zsh" not in s
        assert "Likes tea." in s and "Installed apps: Spotify, Google Chrome." in s
    assert "Turkish" in prompts.PASHA


# Memory and conversation

def test_memory(isolated_home):
    m = Memory(isolated_home / "memory.md")
    assert m.append(["Prefers metric units.", "Has a cat named Pamuk."], today=date(2026, 11, 13)) == [
        "Prefers metric units.", "Has a cat named Pamuk."]
    assert m.append(["prefers metric units"]) == []
    assert m.forget("I have a cat") == ["Has a cat named Pamuk."]
    assert "Pamuk" not in m.text()
    assert m.new_this_week(today=date(2026, 11, 15))
    assert m.read_back().startswith("Here is what I know")


def test_conversation_expires_and_replays_tools():
    from mycroft_win.memory import Action
    c = Conversation()
    c.add("open youtube", "Done, sir.", [Action("t1", "open", {"target": "https://youtube.com"}, "Opened")], now=0)
    msgs = c.messages()
    assert [m["role"] for m in msgs] == ["user", "assistant", "user", "assistant"]
    assert msgs[1]["content"][0]["type"] == "tool_use"
    assert c.expire_if_idle(now=400) and c.messages() == []


# Usage

def test_usage_uses_openrouter_cost(isolated_home):
    u = Usage(isolated_home / "usage.jsonl")
    u.record("sonnet", {"input_tokens": 100, "output_tokens": 50, "cost": 0.0123})
    u.record("haiku", {"input_tokens": 1_000_000, "output_tokens": 0})
    assert abs(u.month_total() - (0.0123 + 0.10)) < 1e-9
    State.set("cap", "0.05")          # raised to the $1 minimum
    assert not u.cap_reached()
    u.record("opus", {"cost": 0.9})
    assert u.cap_reached()
    assert "of your 1 dollar cap" in u.report()


# Streaming

def test_sentence_splitter():
    s = SentenceSplitter()
    assert s.add("It is 3.5 degrees. And") == ["It is 3.5 degrees."]
    assert s.add(" sunny! Ok") == ["And sunny!"]
    assert s.flush() == "Ok"


def test_stream_assembler_tool_input():
    texts, tools_ = [], []
    a = StreamAssembler(on_text=texts.append, on_tool_start=tools_.append)
    for e in [
        {"type": "message_start", "message": {"model": "x", "usage": {"input_tokens": 5}}},
        {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hi."}},
        {"type": "content_block_stop", "index": 0},
        {"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": "t", "name": "timer"}},
        {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": '{"action":'}},
        {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": '"list"}'}},
        {"type": "content_block_stop", "index": 1},
        {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 9, "cost": 0.001}},
    ]:
        a.handle(e)
    assert texts == ["Hi."] and tools_ == ["timer"]
    assert a.content[1]["input"] == {"action": "list"} and a.stop_reason == "tool_use"
    assert a.usage == {"input_tokens": 5, "output_tokens": 9, "cost": 0.001}


# Offline, trump, keys, transcripts

def test_offline_parse():
    assert offline.parse("what time is it") == offline.OfflineAction("time")
    assert offline.parse("Mycroft, open spotify") == offline.OfflineAction("open", "Spotify")
    assert offline.parse("volume 30") == offline.OfflineAction("volume_set", 30)
    assert offline.parse("make a note that Buy Milk") == offline.OfflineAction("note", "Buy Milk")
    assert offline.parse("tell me a joke") is None
    assert offline.perform(offline.OfflineAction("time"), datetime(2026, 1, 1, 15, 5)) == "It's 3:05 pm, sir."


def test_trump_clip_names(tmp_path):
    for n in ("quiet-piggy.mp3", "tremendous.wav", "maga.m4a"):
        (tmp_path / n).write_bytes(b"x")
    clips = trump.available(tmp_path)
    assert clips == ["quiet-piggy", "tremendous"]          # m4a can't be played on Windows
    assert trump.name_for("Tremendous.", clips) == "tremendous"
    assert trump.name_for("Hello there", clips) == "quiet-piggy"
    assert trump.name_for("x", []) is None


def test_secret_stripping_and_key_shape():
    out = keys.strip("token=abc123 key sk-or-v1-abcdefghijklmnopqrstuvwxyz password: hunter2")
    assert "abc123" not in out and "sk-or-v1-abc" not in out and "hunter2" not in out
    assert keys.looks_like_key("sk-or-v1-" + "a" * 64)
    assert not keys.looks_like_key("sk-ant-123")


def test_transcript_cleanup():
    assert clean_transcript("[BLANK_AUDIO]") == ""
    assert clean_transcript(" Minecraft, open YouTube.") == "Mycroft, open YouTube."
    assert clean_transcript("Open Minecraft") == "Open Minecraft"


# Audio pipeline without a real mic

def tone(seconds, amp=0.1):
    t = np.arange(int(16000 * seconds)) / 16000
    return (amp * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


def test_endpoint_detector():
    d = EndpointDetector(start_timeout=2, end_silence=0.5)
    evs = [d.feed(0.001) for _ in range(20)] + [d.feed(0.1) for _ in range(30)] + [d.feed(0.001) for _ in range(30)]
    assert "speaking" in evs and evs[-1] == "done"
    d2 = EndpointDetector(start_timeout=1)
    assert [d2.feed(0.001) for _ in range(60)][-1] == "nothing"


def test_mic_record_with_fed_audio():
    import threading
    mic = Mic()
    mic.start = lambda: True                    # no real device
    mic._stream = object()
    audio = np.concatenate([np.zeros(8000, np.float32), tone(1.0), np.zeros(32000, np.float32)])
    got = {}
    th = threading.Thread(target=lambda: got.setdefault("a", mic.record(3, 0.6)))
    th.start()
    import time
    time.sleep(0.1)
    for i in range(0, len(audio), 1280):
        mic.feed(audio[i:i + 1280])
    th.join(3)
    assert got["a"] is not None and len(got["a"]) >= 16000
