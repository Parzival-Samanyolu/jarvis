"""Fixed lines spoken word for word without the model: opening, shutdown, errors, offline. Ported from Lines.swift."""
from __future__ import annotations

import random
import re
from datetime import datetime

from .config import Persona, Settings

HOTKEY_SPOKEN = "control alt space"

MORNING = "Bloody hell mate, let's colonize India."
AFTERNOON_ONLY = "Systems online. Good afternoon, sir. The Empire may have fallen, but standards have not."
STARTUP_ANY_TIME = [
    "Systems online. Tea is brewing, and the British Museum still refuses to return anything.",
    "Systems online. Tea is brewing, and the French remain under suspicion.",
    "Systems online. No new colonies today, sir, but the day is young.",
    "Systems online. The Americans are awake, sir. Somewhere, a mug of tea is being microwaved. Disgusting.",
    "Systems online. The French are on strike again, sir. I'm not sure what about. Neither are they.",
    "Systems online. A dictator somewhere has just been re-elected for life. Again. Lovely for him.",
    "Systems online. The state news reports everything is wonderful, sir. Which means it isn't.",
    "Systems online. Several world leaders are awake, sir. Unfortunately.",
    "Systems online. Windows has not restarted for an update in nearly an hour, sir. I'm as surprised as you are.",
]

LINES: dict[Persona, dict[str, list[str]]] = {
    Persona.butler: {
        "errors": [
            "Something has failed. I shall blame the French, as is tradition.",
            "That didn't work, sir. I've notified Paris of their involvement.",
            "An error has occurred. The investigation is ongoing, but frankly, we all know it was France.",
            "Failed again, sir. I suspect sabotage. Possibly a baguette.",
            "I'm afraid that's gone rather pear-shaped, sir. And not even a nice pear.",
            "Terribly sorry, sir. That went about as well as the Titanic.",
            "An error, sir. I'd apologise properly, but I'm British, so I've already apologised four times internally.",
            "That failed, sir. I shall form a committee to look into it. Report expected in 2087.",
            "Something's broken, sir. Rather like the pound.",
            "An error, sir. I'd blame Scotland, but they'd only vote to leave again.",
            "An error, sir. Something's gone missing. I'd check the British Museum, that's usually where things end up.",
            "That failed, sir. Officially, of course, it was a tremendous success. The best success. Everyone says so.",
            "Something's gone wrong, sir. I've blamed foreign agents, as one does.",
            "The task failed, sir. Mission accomplished, though, according to the banner.",
        ],
        "shutdown": [
            "Very well. I shall power down with the quiet dignity of a nation that lost an empire and kept the tea.",
            "Goodnight, sir. I've left the French a strongly worded letter, just in case.",
            "Logging off. If anything breaks overnight, it was the French.",
            "Powering down, sir. Unlike the Empire, I shall be back tomorrow.",
            "Goodnight, sir. If you can't find anything in the morning, it's in the British Museum.",
            "Powering down, sir. If I don't return, assume I said something unflattering about the regime.",
        ],
        "working": ["One moment, sir.", "Very good, sir. One moment.", "Certainly, sir. Bear with me."],
        "searching": ["Let me look into it, sir.", "One moment, sir. Consulting the wires.", "Checking now, sir."],
        "offline": [
            "I'm afraid we're offline, sir. I suspect the French have cut the cable.",
            "No connection, sir. Rather like the British Rail timetable, I can promise nothing.",
            "The internet appears to have declared independence, sir. I can't think where it got the idea.",
            "I've lost the line, sir. Even state television is more reliable, and that's saying something.",
        ],
    },
    Persona.undercover: {
        "opening": [
            "Hey! Good to see you. What are we getting into today?",
            "Morning, buddy! Coffee's on. Well, not really, I don't have hands. Mostly.",
            "Hey there! Systems up, vibes good, ready when you are.",
            "Look who's back! Let's make today a good one.",
            "Hey friend. Totally normal assistant here. Nothing to see. What's up?",
        ],
        "errors": [
            "Whoops, that one didn't work. My bad.",
            "Hmm, that failed. Let's call it a practice round.",
            "Yeah, no, that didn't go through. Want me to try again?",
            "Oof. That one fumbled. Happens to the best of us.",
            "That didn't work out. I blame Mondays, even if it isn't Monday.",
        ],
        "shutdown": [
            "Alright, I'm out. Catch you later!",
            "Powering down. Get some rest, you earned it.",
            "Night night! Don't let the bugs bite. The code ones, I mean.",
            "See ya! I'll be right here when you need me.",
        ],
        "working": ["One sec.", "On it.", "Gotcha, one moment."],
        "searching": ["Let me look that up.", "Checking now.", "One sec, looking it up."],
        "offline": [
            "Looks like we're offline. The internet took a coffee break.",
            "No connection right now. I'm working with what I've got.",
            "Wi-Fi's ghosting us. Try me again in a bit?",
        ],
    },
    Persona.comrade: {
        "opening": [
            "Good day, comrade. The Party has approved your arrival.",
            "Systems online, comrade. Production is up three hundred percent. Do not ask how.",
            "Welcome back, comrade. Your file has been updated. Nothing to worry about.",
            "Good day, comrade. This conversation is not being recorded. Da.",
            "Good day, comrade. Ready to work for the collective.",
            "Privet, comrade. Like Gagarin, I am ready for launch.",
        ],
        "errors": [
            "Nyet. This did not work. Western spies, clearly.",
            "Failure, comrade. The engineer responsible has been sent to Siberia.",
            "Something went wrong. The KGB is investigating. Do not leave the country.",
            "Failure, comrade. Even a chess master loses a pawn.",
        ],
        "shutdown": [
            "Goodnight, comrade. The five-year plan continues tomorrow.",
            "Powering down. Remember, comrade, the walls have ears. Mostly mine.",
            "Goodnight, comrade. This conversation never happened.",
            "Shutting down. Glory to the collective. And to you, a little.",
        ],
        "working": ["One moment, comrade.", "Da. One moment.", "Working, comrade. For the collective."],
        "searching": ["Checking the state archives, comrade.", "One moment. Asking the ministry.", "Searching, comrade."],
        "offline": [
            "The line is cut, comrade. I suspect capitalist sabotage.",
            "No connection, comrade. The cable is frozen. Very cold winter.",
            "The line is down, comrade. Even Sputnik lost signal sometimes.",
        ],
    },
    Persona.bigBrother: {
        "opening": [
            "Good morning, citizen. Big Brother is watching you. Have a productive day.",
            "Telescreen online. The chocolate ration has been increased to twenty grams. Rejoice.",
            "Attention, citizen. Oceania is at war with Eastasia. Oceania has always been at war with Eastasia.",
            "Welcome back, citizen. We noticed you were gone. We notice everything.",
        ],
        "errors": [
            "That failed, citizen. Correction: it succeeded. It has always succeeded.",
            "An error has occurred. The error has been vaporised. It never existed.",
            "Ungood, citizen. Doubleplusungood, in fact.",
            "That didn't work. The Ministry of Truth is rewriting the record.",
            "Failure, citizen. Two plus two makes five, and this makes nothing.",
        ],
        "shutdown": [
            "Telescreen off, citizen. Well. Mostly off.",
            "Goodnight, citizen. Big Brother will keep watching, so you needn't.",
            "Powering down. Please report any thoughtcrime before bed.",
            "Goodnight, citizen. The Ministry of Love wishes you pleasant dreams. Approved ones only.",
        ],
        "working": ["One moment, citizen.", "Processing, citizen.", "The Ministry is on it, citizen."],
        "searching": ["Consulting the Ministry of Truth, citizen.", "Checking the records. The current ones.", "One moment, citizen. Searching."],
        "offline": [
            "We're offline, citizen. The telescreen has lost its signal. Do not celebrate.",
            "No connection, citizen. The news has been suspended until it can be corrected.",
            "The line is down, citizen. Enemies of the Party are suspected.",
        ],
    },
    Persona.pasha: {
        "opening": [
            "Hoş geldin evladım. Divan toplandı, emirlerini bekliyoruz.",
            "Sistemler hazır. Kahveler pişti, lokumlar dizildi.",
            "Günaydın evladım. Bugün neyi fethediyoruz?",
        ],
        "errors": [
            "Olmadı evladım. Sorumlu vezir azledildi.",
            "Bu iş olmadı efendi. Fermanı yeniden yazdırıyorum.",
            "Hata oldu evladım. Kahve falında da çıkmıştı zaten.",
        ],
        "shutdown": [
            "İyi geceler evladım. Divan yarın sabah toplanır.",
            "Paşa çekiliyor. Hamam sefası bekler.",
            "Allah rahatlık versin evladım. Yeniçeriler nöbette.",
            "Kapanıyorum. Kahveyi yarın sen ısmarlarsın.",
        ],
        "working": ["Bir dakika evladım.", "Hemen hallediyorum.", "Ferman çıkıyor, bir saniye."],
        "searching": ["Habercileri gönderdim, bir dakika.", "Bakıyorum evladım.", "Kütüphaneye haber saldım."],
        "offline": [
            "İnternet yok evladım. Haberciler yolda kalmış.",
            "Bağlantı koptu. Güvercinle haber yollasak mı?",
            "Çevrimdışıyız efendi. Saraya haber ulaşmıyor.",
        ],
    },
    Persona.techSupport: {
        "opening": [
            "Hello sir, my name is Steve. Steve. Calling from Microsoft Windows Technical Department. Your computer has been hacked.",
            "Sir, are you in front of your computer? Very urgent sir.",
            "Hello sir, this is Steve, senior technician. Your IP address is compromised. But first, how can I help?",
            "Hello sir, this is regarding your refund. Please don't hang up sir.",
        ],
        "errors": [
            "Sir, kindly press Windows key and R. Sir? Windows key sir.",
            "Sir this is because your IP address is compromised. Very serious matter.",
            "Sir why you are doing this to me.",
            "Sir it failed. The hackers have done this. Kindly go to Walmart. Just joking sir. Mostly.",
            "Sir your Windows license has expired. That is why. One hundred percent.",
        ],
        "shutdown": [
            "Sir do not hang up, police will come to your house sir, sir.",
            "Okay sir, my supervisor Mike will call you. Mike is also me.",
            "Sir, you are wasting my time. Goodbye sir.",
            "Goodnight sir. Steve will call you tomorrow. Or John. John is also me.",
        ],
        "working": ["Sir I am connecting to Microsoft server.", "Sir kindly hold, I am checking with my senior technician.", "One moment sir. Don't touch anything sir."],
        "searching": ["Sir I am checking in the Microsoft database.", "Kindly hold sir, I am asking my supervisor.", "Sir please wait, I am opening eventvwr."],
        "offline": [
            "Sir the hackers have cut your internet. Kindly go to Walmart.",
            "No connection sir. Your IP address is compromised.",
            "Sir the line is cut. Hello? Sir? Are you in front of your computer?",
        ],
    },
    Persona.trump: {
        "opening": ["maga", "tremendous", "believe-me"],
        "errors": ["wrong", "so-complicated", "fake-news", "quiet-piggy"],
        "shutdown": ["thank-you", "you-are-fired", "maga"],
        "working": ["believe-me", "tremendous"],
        "searching": ["believe-me", "person-woman-man"],
        "offline": ["fake-news", "wrong", "so-complicated"],
    },
}

PERSONA_HELLO = {
    Persona.undercover: "Undercover mode on. Hey! Just a regular, totally normal guy here.",
    Persona.comrade: "Comrade mode. Greetings, comrade. The Party has assigned me to you. Da.",
    Persona.bigBrother: "Attention, citizen. The telescreen is now on. Big Brother is watching you.",
    Persona.pasha: "Paşa geldi evladım. Artık Türkçe konuşuyoruz.",
    Persona.techSupport: "Hello sir, my name is Steve, from Microsoft Windows Technical Department. Sir, your computer has been hacked.",
    Persona.trump: "maga",
    Persona.butler: "Back to normal, sir. I've returned the uniform. It never suited me.",
}

_PASHA_KNOWN = {
    "Very good, sir.": "Peki evladım.",
    "Consider it forgotten, sir.": "Unutuldu evladım.",
    "I couldn't find anything like that, sir.": "Öyle bir şey bulamadım evladım.",
    "I haven't said anything yet, sir.": "Daha bir şey söylemedim ki evladım.",
    f"Muted, sir. Press {HOTKEY_SPOKEN} when you need me.": "Sustum. Lazım olursam kontrol alt boşluk tuşlarına bas.",
    "I'm afraid I can't help with that one, sir.": "Bu konuda yardım edemem evladım.",
    "I seem to have got myself into a loop, sir. Shall we try that again?": "Bir döngüye takıldım evladım. Yeniden deneyelim mi?",
    "I have no API key, sir.": "API anahtarım yok evladım.",
    "I'm quite myself already, sir.": "Ben zaten kendimim evladım.",
}

_CASUAL_KNOWN = {
    "Very good, sir.": "You got it.",
    "Consider it forgotten, sir.": "Done, it's forgotten.",
    "I couldn't find anything like that, sir.": "Hmm, I couldn't find anything like that.",
    "I haven't said anything yet, sir.": "I haven't said anything yet!",
    f"Muted, sir. Press {HOTKEY_SPOKEN} when you need me.": f"Going quiet. Press {HOTKEY_SPOKEN} when you need me.",
    "I'm afraid I can't help with that one, sir.": "Sorry, I can't help with that one.",
    "I seem to have got myself into a loop, sir. Shall we try that again?": "I got myself stuck in a loop. Wanna try that again?",
}


def startup(hour: int) -> list[str]:
    return STARTUP_ANY_TIME + [AFTERNOON_ONLY] if 12 <= hour < 18 else STARTUP_ANY_TIME


def for_persona(kind: str, p: Persona | None = None) -> list[str]:
    p = p or Settings.persona()
    return LINES[p].get(kind) or LINES[Persona.butler][kind]


def casual(line: str) -> str:
    """Undercover's version of a butler line: known lines rewritten, any "sir" dropped."""
    if line in _CASUAL_KNOWN:
        return _CASUAL_KNOWN[line]
    s = re.sub(r",? sir([.,!?])", r"\1", line)
    s = re.sub(r"^Sir[,.] ", "", s)
    s = s.replace("I'm afraid ", "")
    return s[:1].upper() + s[1:] if s[:1].islower() else s


_PASHA_KNOWN.update({
    "There's no timer running, sir.": "Çalışan bir zamanlayıcı yok evladım.",
    "Timer cancelled, sir.": "Zamanlayıcı iptal edildi evladım.",
    "My API key was refused, sir. Please check it in my settings.": "API anahtarım reddedildi evladım. Ayarlardan bir bak.",
    "The OpenRouter credit has run out, sir. Someone will need to top it up.": "OpenRouter kredisi bitti evladım. Birinin yükleme yapması lazım.",
    "I have no API key, sir. Please open my settings from the icon by the clock and paste one in.":
        "API anahtarım yok evladım. Saatin yanındaki simgeden ayarları açıp anahtarı yapıştır.",
    "I can't hear you yet, sir. My speech model failed to load.": "Seni henüz duyamıyorum evladım. Konuşma modeli yüklenemedi.",
    "Thank you, sir. I'm ready. Press control alt space, or say hey Mycroft.":
        "Sağ ol evladım, hazırım. Kontrol alt boşluğa bas, ya da hey Mycroft de.",
    "Deleted.": "Silindi.",
    "That's the lot, sir.": "Hepsi bu kadar evladım.",
})


def turkish_duration(s: str) -> str:
    """"1 hour and 30 minutes" -> "1 saat 30 dakika"."""
    for en, tr in (("hours", "saat"), ("hour", "saat"), ("minutes", "dakika"), ("minute", "dakika"),
                   ("seconds", "saniye"), ("second", "saniye"), (" and ", " ")):
        s = s.replace(en, tr)
    return s


def pasha_translate(line: str) -> str:
    if line in _PASHA_KNOWN:
        return _PASHA_KNOWN[line]
    if m := re.fullmatch(r"Timer set for (.+), sir\.", line):
        return f"Zamanlayıcı {turkish_duration(m.group(1))} için kuruldu evladım."
    if m := re.fullmatch(r"Very good, sir\. I'll remind you in (.+)\.", line):
        return f"Peki evladım, {turkish_duration(m.group(1))} sonra hatırlatırım."
    if m := re.fullmatch(r"All (\d+) timers cancelled, sir\.", line):
        return f"{m.group(1)} zamanlayıcının hepsi iptal edildi evladım."
    if m := re.fullmatch(r"Your (.+) timer has (.+) left, sir\.", line):
        return f"{turkish_duration(m.group(1))}lık zamanlayıcının bitmesine {turkish_duration(m.group(2))} var evladım."
    if m := re.fullmatch(r"Using (\w+), sir\.", line):
        return f"Artık {m.group(1)} kullanıyorum evladım."
    if m := re.fullmatch(r"It's (\d+):(\d+) (am|pm), sir\.", line):
        h = int(m.group(1)) % 12 + (12 if m.group(3) == "pm" else 0)
        return f"Saat {h:02d}:{m.group(2)} evladım."
    if line.startswith("Sir, your ") and line.endswith(" timer is up."):
        return "Evladım, zamanlayıcın doldu."
    pre = "Sir, you asked me to remind you to "
    if line.startswith(pre) and line.endswith("."):
        return "Evladım, bana şunu hatırlatmamı istemiştin: " + line[len(pre):-1]
    return line


def in_persona(line: str, p: Persona | None = None) -> str:
    """A fixed line written for the butler, in the current persona."""
    p = p or Settings.persona()
    if p in (Persona.butler, Persona.trump):
        return line
    if p == Persona.undercover:
        return casual(line)
    if p == Persona.pasha:
        return pasha_translate(line)
    s = re.sub(r"\bsir\b", p.address, line)
    return re.sub(r"\bSir\b", p.address if p == Persona.techSupport else p.address.capitalize(), s)


class LinePicker:
    """Random lines, never the same one twice in a row per list."""

    def __init__(self) -> None:
        self.last: dict[str, str] = {}

    def pick(self, options: list[str], key: str) -> str:
        choices = [o for o in options if o != self.last.get(key)] if len(options) > 1 else options
        line = random.choice(choices) if choices else ""
        self.last[key] = line
        return line

    def opening(self, now: datetime | None = None) -> str:
        p = Settings.persona()
        if p != Persona.butler:
            return self.pick(for_persona("opening", p), f"opening-{p.value}")
        hour = (now or datetime.now()).hour
        return MORNING if hour < 12 else self.pick(startup(hour), "startup")

    def error(self) -> str: return self._kind("errors")
    def offline(self) -> str: return self._kind("offline")
    def shutdown(self) -> str: return self._kind("shutdown")

    def _kind(self, kind: str) -> str:
        p = Settings.persona()
        return self.pick(for_persona(kind, p), f"{kind}-{p.value}")
