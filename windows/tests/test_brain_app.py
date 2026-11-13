"""The tool loop and the app's conversation logic, with a fake OpenRouter, fake mic and muted speaker."""
import asyncio
import json

import pytest

from mycroft_win import tools
from mycroft_win.app import Controller, IDLE, MUTED
from mycroft_win.brain import Brain, BrainError, LiveSpeech
from mycroft_win.config import Persona, Settings
from mycroft_win.speech import Speaker
from mycroft_win.streaming import StreamAssembler


class FakeTransport:
    """Replays canned responses; records every request body."""

    def __init__(self, *responses, status=200):
        self.responses = list(responses)
        self.bodies = []
        self.status = status

    async def stream(self, body, key, on_event):
        self.bodies.append(json.loads(json.dumps(body)))  # snapshot, as sending would
        if self.status != 200:
            return self.status, b'{"error":{"message":"nope"}}'
        for e in StreamAssembler.events_for(self.responses.pop(0)):
            on_event(e)
        return 200, b""


def text(t, stop="end_turn", cost=0.001):
    return {"content": [{"type": "text", "text": t}], "stop_reason": stop, "usage": {"input_tokens": 10, "output_tokens": 5, "cost": cost}}


def tool(name, inp, id_="t1"):
    return {"content": [{"type": "tool_use", "id": id_, "name": name, "input": inp}], "stop_reason": "tool_use",
            "usage": {"cost": 0.002}}


def make_brain(transport, confirm=None, ran=None):
    async def yes(_):
        return True

    def runner(cmd):
        (ran if ran is not None else []).append(cmd)
        return tools.Result("ok output", 0)

    r = tools.CommandRunner(confirm=confirm or yes, runner=runner)
    b = Brain(runner=r, transport=transport, api_key=lambda: "sk-or-test")
    b.apps = {"Spotify": None}
    return b


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_plain_reply_and_request_shape():
    t = FakeTransport(text("Good morning, sir. It is sunny."))
    b = make_brain(t)
    spoken = []
    reply = run(b.respond("hello", LiveSpeech(spoken.append)))
    assert reply == "Good morning, sir. It is sunny."
    assert spoken == ["Good morning, sir.", "It is sunny."]
    body = t.bodies[0]
    assert body["model"] == "anthropic/claude-sonnet-5.5"
    assert body["tools"][0]["type"] == "web_search_20250305"
    assert body["tools"][-1]["cache_control"] == {"type": "ephemeral"}
    assert body["messages"][-1]["content"][1]["text"].startswith("Current date and time:")
    assert "Installed apps: Spotify." in body["system"][0]["text"]
    assert abs(b.usage.month_total() - 0.001) < 1e-9


def test_tool_loop_runs_command_and_keeps_history():
    ran = []
    t = FakeTransport(tool("run_command", {"command": "Get-Date"}), text("It's Friday, sir."))
    b = make_brain(t, ran=ran)
    assert run(b.respond("what day is it")) == "It's Friday, sir."
    assert ran == ["Get-Date"]
    result = t.bodies[1]["messages"][-1]["content"][0]
    assert result["type"] == "tool_result" and "ok output" in result["content"]
    hist = b.conversation.messages()
    assert hist[1]["content"][0]["name"] == "run_command"


def test_risky_command_declined_never_runs():
    ran = []

    async def no(_):
        return False
    t = FakeTransport(tool("run_command", {"command": "Remove-Item ~\\x.txt"}), text("As you wish, sir."))
    b = make_brain(t, confirm=no, ran=ran)
    run(b.respond("delete x"))
    assert ran == []
    assert "declined" in t.bodies[1]["messages"][-1]["content"][0]["content"]


def test_timer_tool_and_notes_tool(isolated_home):
    t = FakeTransport(tool("timer", {"action": "set", "seconds": 60, "reminder": "stretch"}),
                      tool("notes", {"action": "save", "text": "Buy milk"}, "t2"), text("Done, sir."))
    b = make_brain(t)
    run(b.respond("remind me and note"))
    assert b.timers.active()[0].label == "stretch"
    assert "Buy milk" in tools.note_last()
    b.timers.cancel_all()


def test_errors_map_to_kinds():
    for status, kind in ((402, "credits"), (401, "bad_key"), (400, "api")):
        b = make_brain(FakeTransport(status=status))
        with pytest.raises(BrainError) as e:
            run(b.respond("hi"))
        assert e.value.kind == kind
    b = Brain(runner=tools.CommandRunner(confirm=None), transport=FakeTransport(), api_key=lambda: None)
    with pytest.raises(BrainError) as e:
        run(b.respond("hi"))
    assert e.value.kind == "no_key"


def test_learn_appends_facts():
    t = FakeTransport(text("Morning."), text('["Studies medicine."]'))
    b = make_brain(t)
    run(b.respond("I study medicine"))
    assert run(b.learn()) == ["Studies medicine."]
    assert t.bodies[1]["model"] == "anthropic/claude-haiku-5.5"


def test_speaker_muted_queue_drain_stop():
    s = Speaker(muted=True)
    s.enqueue("One.")
    s.enqueue("Two.")
    s.drain_sync(timeout=2)
    assert not s.is_speaking and s.spoken == ["One.", "Two."]
    s.stop()
    assert not s.is_speaking


# The controller, with a fake mic and transcriber

class FakeMic:
    def __init__(self, heard):
        self.heard = list(heard)
        self.wake = None
        self.wake_enabled = False
        self.on_wake = None

    def record(self, *a, **k):
        import numpy as np
        return np.zeros(16000, "float32") if self.heard else None

    def start(self): return True
    def stop(self): pass
    def cancel(self): pass


class FakeTranscriber:
    def __init__(self, mic):
        self.mic = mic

    def prepare(self): return True

    def transcribe(self, audio, language="en"):
        return self.mic.heard.pop(0) if self.mic.heard else ""


def controller(heard, *responses, online=True):
    mic = FakeMic(heard)
    ctl = Controller(speaker=Speaker(muted=True), mic=mic, transcriber=FakeTranscriber(mic),
                     brain=make_brain(FakeTransport(*responses)))
    ctl.brain.runner.confirm = ctl.confirm

    async def is_online():
        return online
    ctl.is_online = is_online
    return ctl


def test_local_intents_need_no_model():
    ctl = controller(["set a timer for 5 minutes", "how long is left", "cancel the timer", "stop"])
    run(ctl.conversation(after_wake=False))
    said = ctl.speaker.spoken
    assert said[0] == "Timer set for 5 minutes, sir."
    assert said[1].startswith("Your 5 minute timer has")
    assert said[2] == "Timer cancelled, sir."


def test_offline_answers_locally():
    ctl = controller(["what time is it", "tell me a joke"], online=False)
    run(ctl.conversation(after_wake=False))
    assert ctl.speaker.spoken[0].startswith("It's ")
    assert any(l in ctl.speaker.spoken[1] for l in ("offline", "connection", "independence", "line"))


def test_spoken_yes_approves_risky_command():
    ctl = controller(["delete the old file", "yes", "stop"],
                     tool("run_command", {"command": "Remove-Item ~\\old.txt"}), text("Deleted, sir."))
    run(ctl.conversation(after_wake=False))
    assert any("Shall I proceed, sir?" in l and "deletes files" in l for l in ctl.speaker.spoken)
    assert "Deleted, sir." in ctl.speaker.spoken


def test_persona_switch_and_mute():
    ctl = controller(["go undercover", "mute"])
    run(ctl.conversation(after_wake=False))
    assert Settings.persona() == Persona.undercover
    assert ctl.speaker.spoken[0].startswith("Undercover mode on.")
    assert ctl.speaker.spoken[-1] == "Going quiet. Press control alt space when you need me."
    assert ctl.state == MUTED


def test_pasha_fixed_lines_in_turkish():
    Settings.persona_override = Persona.pasha
    ctl = controller(["cancel the timer", "set a timer for 1 hour and 30 minutes", "stop"])
    run(ctl.conversation(after_wake=False))
    assert ctl.speaker.spoken[0] == "Çalışan bir zamanlayıcı yok evladım."
    assert ctl.speaker.spoken[1] == "Zamanlayıcı 1 saat 30 dakika için kuruldu evladım."
    ctl.brain.timers.cancel_all()
    Settings.persona_override = None


def test_hotkey_during_confirmation_declines():
    ran = []
    ctl = controller(["delete the old file"], tool("run_command", {"command": "Remove-Item ~\\old.txt"}), text("As you wish."))
    ctl.brain.runner.runner = lambda c: ran.append(c) or tools.Result("", 0)

    async def go():
        async def press_when_asked():
            while ctl.state != "confirming":
                await asyncio.sleep(0.01)
            ctl.hotkey()
        presser = asyncio.ensure_future(press_when_asked())
        ctl.mic.heard = ["delete the old file"]
        await ctl.conversation(after_wake=False)
        await presser
    run(go())
    assert ran == []
