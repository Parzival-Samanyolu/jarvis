"""The brain: OpenRouter's Anthropic-compatible Messages API, the tool loop, memory learning. Ported from Brain.swift."""
from __future__ import annotations

import asyncio
import json
import random
from dataclasses import dataclass
from datetime import datetime
from typing import Awaitable, Callable, Protocol

from . import intents, keys, lines, prompts, tools
from .config import Mode, Paths, Settings
from .memory import Action, Conversation, Memory
from .streaming import SentenceSplitter, StreamAssembler, StreamError
from .timers import Timers, spoken
from .usage import Usage

URL = "https://openrouter.ai/api/v1/messages"
MAX_TOOL_ROUNDS = 8


class BrainError(Exception):
    def __init__(self, kind: str, status: int = 0, message: str = "") -> None:
        super().__init__(f"{kind} {status} {message}".strip())
        self.kind, self.status, self.message = kind, status, message   # kind: no_key, offline, credits, api


class Transport(Protocol):
    async def stream(self, body: dict, key: str, on_event: Callable[[dict], None]) -> tuple[int, bytes]: ...


class HttpTransport:
    """Streams server-sent events from OpenRouter with httpx."""

    async def stream(self, body: dict, key: str, on_event: Callable[[dict], None]) -> tuple[int, bytes]:
        import httpx
        headers = {"authorization": f"Bearer {key}", "content-type": "application/json",
                   "anthropic-version": "2023-06-01", "x-title": "Mycroft"}
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(120, connect=10)) as client:
                async with client.stream("POST", URL, json={**body, "stream": True}, headers=headers) as r:
                    if r.status_code != 200:
                        return r.status_code, await r.aread()
                    async for line in r.aiter_lines():
                        if line.startswith("data:"):
                            data = line[5:].strip()
                            if data and data != "[DONE]":
                                try:
                                    on_event(json.loads(data))
                                except ValueError:
                                    pass
                    return 200, b""
        except httpx.TransportError as e:   # connect, read, write, timeouts, resets (WinError 10054)
            raise BrainError("offline", 0, str(e)) from e


class LiveSpeech:
    """Speaks whole sentences as they stream in, plus a short holding line before a slow tool."""

    def __init__(self, say: Callable[[str], None]) -> None:
        self.say = say
        self.splitter = SentenceSplitter()
        self.spoke = False

    def text(self, t: str) -> None:
        for s in self.splitter.add(t):
            self.speak(s)

    def flush(self) -> None:
        if s := self.splitter.flush():
            self.speak(s)

    def speak(self, s: str) -> None:
        self.spoke = True
        self.say(s)

    def tool_starting(self, name: str) -> None:
        self.flush()
        if name == "timer" or self.spoke:
            return
        kind = "working" if name in ("run_command", "notes", "look_at_screen", "open", "media") else "searching"
        self.speak(random.choice(lines.for_persona(kind)))


def _schema(props: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": props, "required": required, "additionalProperties": False}


def tool_definitions(model: str) -> list[dict]:
    return [
        {"type": "web_search_20250305", "name": "web_search", "max_uses": 3,
         "user_location": {"type": "approximate", "city": Settings.city_name()}},
        {"name": "run_command",
         "description": "Run a Windows PowerShell command on the owner's PC (working folder: their user folder) and return its output.",
         "input_schema": _schema({"command": {"type": "string", "description": "The PowerShell command line"}}, ["command"])},
        {"name": "open",
         "description": "Open an installed app by its exact name from the installed-apps list, a website (https://...), or a document or folder.",
         "input_schema": _schema({"target": {"type": "string", "description": "App name, URL, or path"}}, ["target"])},
        {"name": "media",
         "description": "Media keys and volume: play_pause, next, previous, mute, volume_up, volume_down, set_volume (with percent).",
         "input_schema": _schema({"action": {"type": "string", "enum": ["play_pause", "next", "previous", "mute", "volume_up",
                                                                      "volume_down", "set_volume"]},
                                  "percent": {"type": "integer", "description": "For set_volume, 0 to 100"}}, ["action"])},
        {"name": "look_at_screen",
         "description": "Take a screenshot of the owner's screen. Only use when the owner asks about what is on their screen.",
         "input_schema": _schema({}, [])},
        {"name": "notes",
         "description": "Save to or read from the owner's Mycroft Notes folder.",
         "input_schema": _schema({"action": {"type": "string", "enum": ["save", "search", "last", "recent"]},
                                  "text": {"type": "string", "description": "Note text for save, or search words for search"}},
                                 ["action"])},
        {"name": "timer",
         "description": "Set, list or cancel countdown timers and reminders. Mycroft says aloud when one ends.",
         "input_schema": _schema({"action": {"type": "string", "enum": ["set", "list", "cancel"]},
                                  "seconds": {"type": "integer", "description": "Length, for set"},
                                  "reminder": {"type": "string", "description": "For a reminder, what to remind the owner to do, phrased to follow \"remind you to\" (\"call your sister\"). Leave out for a plain timer."}},
                                 ["action"])},
    ]


@dataclass
class Response:
    content: list[dict]
    stop_reason: str


def text_of(content: list[dict]) -> str:
    return "".join(b.get("text", "") for b in content if b.get("type") == "text").strip()


def parse_facts(s: str) -> list[str]:
    a, b = s.find("["), s.rfind("]")
    if a < 0 or b <= a:
        return []
    try:
        arr = json.loads(s[a:b + 1])
    except ValueError:
        return []
    return [x.strip() for x in arr if isinstance(x, str) and x.strip()]


class Brain:
    def __init__(self, runner: tools.CommandRunner, transport: Transport | None = None, usage: Usage | None = None,
                 memory: Memory | None = None, conversation: Conversation | None = None,
                 api_key: Callable[[], str | None] = keys.api_key, timers: Timers | None = None) -> None:
        self.runner = runner
        self.transport = transport or HttpTransport()
        self.usage = usage or Usage()
        self.memory = memory or Memory()
        self.conversation = conversation or Conversation()
        self.api_key = api_key
        self.timers = timers or Timers(Paths.timers())
        self.mode: Mode = Settings.mode()
        self.last_model: str | None = None
        self.conversation_log = None
        self.clock: Callable[[], datetime] = datetime.now
        self.apps: dict | None = None   # Start Menu apps, read once per launch
        self.screenshot: Callable[[], str | None] = tools.screenshot_b64

    def app_names(self) -> list[str]:
        if self.apps is None:
            self.apps = tools.installed_apps()
        return list(self.apps)[:150]

    async def respond(self, text: str, speech: LiveSpeech | None = None) -> str:
        self.conversation.expire_if_idle()
        self.runner.begin_request()
        model = intents.route(text, self.mode, self.usage.cap_reached())
        deep = any(p in text.lower() for p in intents.DEEP_THINKING)
        actions: list[Action] = []
        user = {"role": "user", "content": [{"type": "text", "text": text},
                                            {"type": "text", "text": prompts.time_note(self.clock())}]}
        reply = await self.run(self.conversation.messages() + [user], model, deep, actions, speech)
        self.conversation.add(text, reply, actions)
        if self.conversation_log:
            tools.log_line(self.conversation_log, f"You: {text}")
            tools.log_line(self.conversation_log, f"Mycroft [{model}]: {reply}")
        return reply

    async def one_shot(self, prompt: str, model: str = "haiku", speech: LiveSpeech | None = None) -> str:
        self.runner.begin_request()
        msg = {"role": "user", "content": [{"type": "text", "text": prompt},
                                           {"type": "text", "text": prompts.time_note(self.clock())}]}
        return await self.run([msg], "haiku" if self.usage.cap_reached() else model, False, [], speech)

    async def learn(self) -> list[str]:
        transcript = self.conversation.transcript
        if not transcript:
            return []
        from .memory import fact_of
        known = "\n".join(fact_of(l) for l in self.memory.lines()) or "(none)"
        body = {"model": intents.MODELS["haiku"], "max_tokens": 600, "system": prompts.MEMORY_EXTRACT,
                "messages": [{"role": "user", "content": f"Known facts:\n{known}\n\nConversation:\n{transcript}"}]}
        try:
            resp = await self.call(body, "haiku")
        except Exception:
            return []
        return self.memory.append(parse_facts(text_of(resp.content)))

    async def run(self, messages: list[dict], model: str, deep: bool, actions: list[Action],
                  speech: LiveSpeech | None = None) -> str:
        msgs = list(messages)
        self.last_model = model
        system = prompts.system(self.memory.text(), self.app_names())
        for _ in range(MAX_TOOL_ROUNDS):
            resp = await self.call(self.request_body(model, system, msgs, deep), model, speech)
            msgs.append({"role": "assistant", "content": resp.content})
            if resp.stop_reason == "tool_use":
                results = []
                for b in resp.content:
                    if b.get("type") == "tool_use":
                        r = await self.execute(b)
                        results.append(r)
                        actions.append(self.action(b, r))
                msgs.append({"role": "user", "content": results})
                continue
            if resp.stop_reason == "pause_turn":
                continue
            if resp.stop_reason == "refusal":
                return self._spoken("I'm afraid I can't help with that one, sir.", speech)
            if speech:
                speech.flush()
            t = text_of(resp.content)
            return t or self._spoken("Very good, sir.", speech)
        return self._spoken("I seem to have got myself into a loop, sir. Shall we try that again?", speech)

    @staticmethod
    def _spoken(line: str, speech: LiveSpeech | None) -> str:
        if speech:
            speech.speak(lines.in_persona(line))
        return line

    def request_body(self, model: str, system: str, messages: list[dict], deep: bool) -> dict:
        t = tool_definitions(model)
        t[-1] = {**t[-1], "cache_control": {"type": "ephemeral"}}
        return {
            "model": intents.MODELS[model],
            "max_tokens": 2048,
            "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            "messages": messages,
            "tools": t,
            "output_config": {"effort": "high" if deep else "low"},
        }

    @staticmethod
    def action(call: dict, result: dict) -> Action:
        c = result.get("content")
        if isinstance(c, str):
            text = c
        elif isinstance(c, list):
            text = " ".join("[screenshot taken]" if b.get("type") == "image" else b.get("text", "") for b in c)
        else:
            text = ""
        if len(text) > 600:
            text = text[:600] + " [shortened]"
        return Action(call.get("id", ""), call.get("name", ""), call.get("input") or {}, text, bool(result.get("is_error")))

    async def execute(self, block: dict) -> dict:
        inp = block.get("input") or {}
        name = block.get("name")
        content: object
        err = False
        if name == "run_command":
            cmd = (inp.get("command") or "").strip()
            if not cmd:
                content, err = "Missing command.", True
            else:
                r = await self.runner.run(cmd)
                content, err = r.output, r.exit_code != 0
        elif name == "open":
            content, err = await asyncio.to_thread(tools.open_target, inp.get("target", ""), self.apps)
        elif name == "media":
            content, err = await asyncio.to_thread(tools.media, inp.get("action", ""), inp.get("percent"))
        elif name == "look_at_screen":
            b64 = await asyncio.to_thread(self.screenshot)
            if b64:
                content = [{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}},
                           {"type": "text", "text": "Screenshot of the owner's screen."}]
            else:
                content, err = "Could not capture the screen.", True
        elif name == "notes":
            text = inp.get("text") or ""
            action = inp.get("action")
            if action == "save":
                content = tools.note_save(text) if text else "Nothing to save."
            elif action == "search":
                content = tools.note_search(text)
            elif action == "recent":
                content = tools.note_recent(5)
            else:
                content = tools.note_last()
        elif name == "timer":
            action = inp.get("action")
            if action == "set":
                secs = inp.get("seconds")
                if not isinstance(secs, int) or secs <= 0:
                    content, err = "Missing seconds.", True
                else:
                    item = self.timers.start(secs, inp.get("reminder") or "")
                    content = f"Timer {item.id} set for {spoken(secs)}; it ends at {datetime.fromtimestamp(item.ends):%H:%M}."
            elif action == "cancel":
                content = f"Cancelled {self.timers.cancel_all()} timer(s)."
            else:
                content = self.timers.status()
        else:
            content, err = "Unknown tool.", True
        r = {"type": "tool_result", "tool_use_id": block.get("id", ""), "content": content}
        if err:
            r["is_error"] = True
        return r

    async def call(self, body: dict, model: str, speech: LiveSpeech | None = None) -> Response:
        key = self.api_key()
        if not key:
            raise BrainError("no_key")
        for attempt in range(3):
            asm = StreamAssembler(on_text=speech.text if speech else None,
                                  on_tool_start=speech.tool_starting if speech else None)
            try:
                status, data = await self.transport.stream(body, key, asm.handle)
            except StreamError as e:
                if attempt < 2:
                    await asyncio.sleep(1.5 * (attempt + 1))
                    continue
                raise BrainError("api", 529, str(e)) from e
            if status == 200:
                self.usage.record(model, asm.usage)
                return Response(asm.content, asm.stop_reason)
            try:
                j = json.loads(data or b"{}")
                msg = (j.get("error") or {}).get("message") or data.decode(errors="replace")
            except (ValueError, AttributeError):
                msg = (data or b"").decode(errors="replace")
            if status == 402:
                raise BrainError("credits", status, msg)
            if status in (401, 403):
                raise BrainError("bad_key", status, msg)
            if status in (408, 429, 500, 502, 503, 529) and attempt < 2:
                await asyncio.sleep(1.5 * (attempt + 1))
                continue
            raise BrainError("api", status, msg)
        raise BrainError("api", 0, "retries exhausted")
