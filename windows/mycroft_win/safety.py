"""Classifies a PowerShell command line. Harmless commands run at once; risky ones need a spoken yes.

The Windows counterpart of Safety.swift: same idea (deleting, killing, power, admin, system settings and
writing outside the owner's folder need a yes), with PowerShell cmdlets, their aliases and cmd.exe commands.
"""
from __future__ import annotations

import ntpath
import os
import re
from typing import Callable

ALWAYS_RISKY: dict[str, str] = {}


def _add(why: str, *names: str) -> None:
    for n in names:
        ALWAYS_RISKY[n] = why


_add("deletes files", "clear-item", "cli", "clear-itemproperty", "clp", "remove-item", "rm", "del", "erase", "rd", "rmdir", "ri", "clear-content", "clc",
     "clear-recyclebin", "cipher", "sdelete", "remove-itemproperty", "rp")
_add("ends programs", "stop-process", "kill", "spps", "taskkill", "tskill", "pskill")
_add("powers off, restarts or logs out", "stop-computer", "restart-computer", "shutdown", "logoff", "suspend-computer")
_add("needs administrator rights", "runas", "gsudo", "sudo", "start-elevated")
_add("touches disks", "format-volume", "clear-disk", "initialize-disk", "remove-partition", "new-partition",
     "resize-partition", "set-partition", "diskpart", "format", "mountvol", "bcdedit", "bootrec", "vssadmin", "wbadmin",
     "manage-bde", "dismount-diskimage", "chkdsk")
_add("changes permissions or ownership", "takeown", "icacls", "cacls", "set-acl", "attrib")
_add("changes services", "stop-service", "set-service", "new-service", "remove-service", "restart-service",
     "suspend-service", "sc", "sc.exe", "spsv")
_add("changes scheduled tasks", "schtasks", "register-scheduledtask", "unregister-scheduledtask", "set-scheduledtask",
     "disable-scheduledtask")
_add("changes network or firewall settings", "netsh", "set-netfirewallprofile", "new-netfirewallrule",
     "remove-netfirewallrule", "set-netfirewallrule", "disable-netadapter", "enable-netadapter", "set-netipaddress",
     "new-netipaddress", "remove-netipaddress", "set-dnsclientserveraddress", "route", "netcfg", "set-netconnectionprofile")
_add("changes security settings", "set-mppreference", "add-mppreference", "remove-mppreference",
     "set-executionpolicy", "unblock-file", "set-processmitigation", "secedit", "auditpol")
_add("changes user accounts", "net", "net.exe", "net1", "new-localuser", "set-localuser", "remove-localuser",
     "add-localgroupmember", "remove-localgroupmember", "disable-localuser", "enable-localuser")
_add("installs or removes software", "msiexec", "winget", "choco", "scoop", "install-package", "uninstall-package",
     "install-module", "remove-appxpackage", "add-appxpackage", "uninstall-module", "dism", "add-windowscapability",
     "enable-windowsoptionalfeature", "disable-windowsoptionalfeature")
_add("runs arbitrary code", "invoke-expression", "iex", "invoke-command", "icm", "start-job", "mshta", "wscript",
     "cscript", "regsvr32", "rundll32", "certutil", "bitsadmin")
_add("changes the registry", "reg", "reg.exe", "regedit", "new-itemproperty", "set-itemproperty", "sp", "rename-itemproperty")
_add("changes system settings", "set-date", "set-timezone", "rename-computer", "add-computer", "remove-computer",
     "powercfg", "wsl", "set-winsystemlocale", "set-culture", "set-winuserlanguagelist", "set-mpcomputerstatus",
     "bcdboot", "sfc", "reagentc", "systemreset")
_add("runs a program that can change anything", "python", "python3", "py", "pythonw", "node", "deno", "bun", "perl",
     "ruby", "php", "java", "javaw", "wevtutil", "fsutil", "clear-eventlog", "limit-eventlog", "bash.exe")
_add("runs a nested shell", "powershell", "powershell.exe", "pwsh", "pwsh.exe", "cmd", "cmd.exe", "bash", "wsl.exe")

# Commands that write to the paths they're given.
WRITERS = {
    "new-item", "ni", "mkdir", "md", "set-content", "add-content", "ac", "out-file", "copy-item", "cp", "copy", "cpi",
    "move-item", "mv", "move", "mi", "rename-item", "ren", "rni", "expand-archive", "compress-archive", "tee-object",
    "tee", "export-csv", "export-clixml", "xcopy", "robocopy", "tar", "git", "invoke-webrequest", "iwr", "curl",
    "curl.exe", "wget", "start-bitstransfer", "new-shortcut", "export-certificate", "set-clipboard",
}
MOVERS = {"move-item", "mv", "move", "mi", "rename-item", "ren", "rni", "robocopy", "xcopy"}
COPIERS = {"copy-item", "cp", "copy", "cpi"}

_PIPE_TO_SHELL = re.compile(r"\|\s*(&\s*)?(iex|invoke-expression|powershell(\.exe)?|pwsh(\.exe)?|cmd(\.exe)?|bash|sh|python[0-9.]*|node)\b")
# Cmdlet verbs that change or remove things: any Verb-Noun with these asks first (Remove-*, Stop-*, ...).
RISKY_VERBS = {"remove", "uninstall", "disable", "stop", "clear", "reset", "unregister", "suspend", "restart",
               "dismount", "revoke", "block", "deny", "protect", "unprotect", "initialize", "mount", "install",
               "register", "enable", "format", "repair", "update", "publish", "grant", "lock", "unlock", "kill"}
SAFE_FORMATTERS = {"format-table", "format-list", "format-wide", "format-custom", "format-hex", "update-typedata",
                   "update-formatdata", "update-list"}
SCRIPT_EXT = (".ps1", ".psm1", ".bat", ".cmd", ".vbs", ".vbe", ".js", ".jse", ".wsf", ".wsh", ".msi", ".msp", ".hta",
              ".scr", ".com", ".pif", ".reg", ".cpl", ".jar", ".lnk")
_DOTNET_RISKY = [
    (re.compile(r"\[(system\.)?(io\.)?(file|directory|fileinfo|directoryinfo)\]::\s*(delete|move|replace|write\w*|append\w*|copy|create\w*|encrypt|decrypt|setattributes|setaccesscontrol)"),
     "changes files"),
    (re.compile(r"\[(system\.)?diagnostics\.process\]::\s*start|\[(system\.)?activator\]::|\[(system\.)?reflection\."), "runs arbitrary code"),
    (re.compile(r"\.(delete|moveto|copyto|kill|terminate|setinfo|encrypt|decrypt)\s*\("), "changes or ends something"),
    (re.compile(r"win32shutdown|invoke-cimmethod|invoke-wmimethod|\bicim\b|\biwmi\b"), "powers off or changes the system"),
    (re.compile(r"\[(system\.)?environment\]::setenvironmentvariable"), "changes system settings"),
    (re.compile(r"add-type|new-object\s+(-typename\s+)?(-comobject|system\.net\.webclient)"), "runs arbitrary code"),
]

_REDIRECT = re.compile(r"(?:^|[^0-9&*])(?:[1-6*]?>>?)\s*(\"[^\"]*\"|'[^']*'|[^\s;&|<>]+)")
_ENV_UNDER_HOME = {"userprofile", "home", "appdata", "localappdata", "temp", "tmp", "onedrive"}
_WRAPPERS = {"&", ".", "start-process", "saps", "start", "invoke-item", "ii"}


class SafetyChecker:
    def __init__(self, home: str | None = None, exists: Callable[[str], bool] | None = None,
                 is_dir: Callable[[str], bool] | None = None) -> None:
        self.home = ntpath.normpath(home or os.environ.get("USERPROFILE") or os.path.expanduser("~"))
        self.exists = exists or os.path.exists
        self.is_dir = is_dir or os.path.isdir

    def classify(self, command: str) -> str | None:
        """None if safe, otherwise why it is risky ("deletes files")."""
        lower = command.lower()
        if _PIPE_TO_SHELL.search(lower):
            return "runs downloaded or generated code"
        if re.search(r"-verb\s+['\"]?runas", lower):
            return "needs administrator rights"
        if re.search(r"\s-(e|ec|en|enc|encodedcommand)\s", " " + lower + " ") and ("powershell" in lower or "pwsh" in lower):
            return "runs hidden code"
        if "[scriptblock]::create" in lower or "downloadstring(" in lower or "downloadfile(" in lower:
            return "runs downloaded or generated code"
        if re.search(r"\bhk(lm|cu|cr|u|cc)\b|registry::|hkey_", lower) and re.search(
                r"\b(set|new|remove|rename|clear|copy|move)-item", lower):
            return "changes the registry"
        for rx, why in _DOTNET_RISKY:
            if rx.search(lower):
                return why
        if "powrprof" in lower or "setsuspendstate" in lower:
            return "puts the PC to sleep"
        if re.search(r"\.(shutdown|reboot|logoff)\s*\(", lower) or "exitwindowsex" in lower:
            return "powers off, restarts or logs out"

        # & $cmd, & (Get-Command ...), . $script: the real command can't be read, so ask.
        if re.search(r"(^|[\s(;|{])[&.]\s*[$(]", command.strip()):
            return "runs a command it can't check"
        cwd_outside = False
        for seg in split(command) + subexpressions(command):
            # & $cmd, & (Get-Command ...), . $script: the real command can't be read, so ask.
            if re.search(r"(^|[\s(])[&.]\s*[$(]", seg.strip()):
                return "runs a command it can't check"
            if re.match(r"^\s*\$[\w:]+\s*=\s*['\"]", seg):
                continue   # $p = 'C:\...': a string, not a command
            words = shell_words(seg)
            found = command_and_args(words)
            if not found:
                continue
            cmd, args = found
            name = ntpath.basename(cmd).lower()
            # A script, or a program given by its path: could be anything.
            if name.endswith(SCRIPT_EXT) or (("\\" in cmd or "/" in cmd) and not cmd.lower().startswith(("http:", "https:"))):
                return "runs a program or script"
            if "-" in name and name.split("-", 1)[0] in RISKY_VERBS and name not in SAFE_FORMATTERS:
                return ALWAYS_RISKY.get(name, f"runs {name}, which changes things")
            if name in ("start-process", "saps", "start", "invoke-item", "ii") and args:
                target = start_target(args)
                if target:
                    t = target.strip("\"'")
                    base = ntpath.basename(t).lower()
                    tl = t.lower()
                    if re.match(r"^(https?://|mailto:)", tl) or (re.match(r"^[a-z][\w.+-]+:", tl) and not tl.startswith("file:")
                                                                  and "\\" not in t and "/" not in t):
                        continue   # a URL or app protocol: https://..., spotify:, ms-settings:
                    if base in ALWAYS_RISKY or base.removesuffix(".exe") in ALWAYS_RISKY:
                        return ALWAYS_RISKY.get(base) or ALWAYS_RISKY[base.removesuffix(".exe")]
                    if base.endswith(SCRIPT_EXT + (".exe",)) or "\\" in t or "/" in t or t.startswith("$"):
                        return "runs a program or script"
                continue
            if name in ("wmic", "wmic.exe") and any(a.lower() in ("call", "delete", "set", "create") for a in args):
                return "changes the system"
            if name == "git" and args:
                sub, rest = args[0].lower(), [a.lower() for a in args[1:]]
                if (sub in ("clean", "rm", "restore", "filter-branch", "reflog")
                        or (sub == "reset" and "--hard" in rest)
                        or (sub == "checkout" and ("--" in rest or "-f" in rest or "." in rest))
                        or (sub == "push" and any(a in ("-f", "--force", "--force-with-lease", "--delete") for a in rest))
                        or (sub == "branch" and any(a in ("-d", "-D".lower(), "--delete") for a in rest))
                        or (sub == "stash" and any(a in ("drop", "clear") for a in rest))):
                    return "throws away work in git"
            if name in ("cd", "set-location", "sl", "chdir", "pushd", "push-location") and args:
                target = next((a for a in args if not a.startswith("-")), "")
                if target:
                    cwd_outside = self.outside([target]) is not None or (
                        cwd_outside and not target.strip("\"'").startswith(("~", "$home", "$env:userprofile")))
                continue
            if name.endswith(".exe") and name not in ALWAYS_RISKY:
                name_noext = name[:-4]
                if name_noext in ALWAYS_RISKY:
                    return ALWAYS_RISKY[name_noext]
            if name in ("reg", "reg.exe") and args and args[0].lower() in ("query", "export"):
                pass
            elif name in ("net", "net.exe") and args and args[0].lower() in ("view", "statistics", "time", "config"):
                pass
            elif name in ("powercfg",) and args and args[0].lower() in ("/list", "/l", "/query", "/q", "/batteryreport", "/a"):
                pass
            elif name in ("winget",) and args and args[0].lower() in ("list", "search", "show", "--version", "-v"):
                pass
            elif name in ("sc", "sc.exe") and args and args[0].lower() in ("query", "qc", "queryex"):
                pass
            elif name in ALWAYS_RISKY:
                return ALWAYS_RISKY[name]
            paths = [a for a in args if not a.startswith("-")]
            if name in MOVERS and len(paths) >= 1 and (r := self.outside(paths)):
                return r
            if name in COPIERS and len(paths) >= 2:
                dest = self.expand(paths[-1])
                if self.exists(dest) and not self.is_dir(dest):
                    return "overwrites an existing file"
                if self.exists(dest) and self.is_dir(dest):
                    for src in paths[:-1]:
                        if self.exists(ntpath.join(dest, ntpath.basename(src))):
                            return "overwrites an existing file"
            if cwd_outside and (name in WRITERS or redirect_targets(seg)) and name not in ("git", "curl", "curl.exe", "iwr", "invoke-webrequest", "wget"):
                return "changes files outside your user folder"
            if name in WRITERS:
                targets = paths if name not in ("git", "curl", "curl.exe", "wget", "iwr", "invoke-webrequest") else []
                targets += output_targets(args)
                if r := self.outside(targets):
                    return r
            for target in redirect_targets(seg):
                if r := self.outside([target]):
                    return r
        return None

    def expand(self, p: str) -> str:
        p = p.strip("\"'")
        low = p.lower()
        for var in ("$env:userprofile", "$home", "$env:home"):
            if low.startswith(var):
                return ntpath.normpath(self.home + p[len(var):])
        if p == "~" or p.startswith("~\\") or p.startswith("~/"):
            return ntpath.normpath(self.home + p[1:])
        if re.match(r"^[a-zA-Z]:[\\/]", p) or p.startswith("\\\\"):
            return ntpath.normpath(p)
        return ntpath.normpath(ntpath.join(self.home, p))

    def outside(self, paths: list[str]) -> str | None:
        home = self.home.lower().rstrip("\\")
        for raw in paths:
            p = raw.strip("\"'")
            low = p.lower()
            if low in ("$null", "nul", "null") or not p:
                continue
            m = re.match(r"^\$env:([a-z_]+)", low)
            if m:
                if m.group(1) in _ENV_UNDER_HOME:
                    continue
                return "changes files outside your user folder"
            if p.startswith("$") and not low.startswith("$home"):
                continue   # an unknown variable: can't tell
            looks_like_path = (re.match(r"^[a-zA-Z]:", p) or p.startswith("\\") or p.startswith("/") or
                               p.startswith("~") or low.startswith("$home") or ".." in p)
            if not looks_like_path:
                continue
            if re.match(r"^[a-zA-Z]:[^\\/]", p):
                return "changes files outside your user folder"   # drive-relative path, e.g. C:foo
            if p.startswith("/") and not p.startswith("//"):
                p = "C:" + p   # PowerShell treats \foo as the current drive's root
            std = self.expand(p).lower().rstrip("\\")
            if std != home and not std.startswith(home + "\\"):
                return "changes files outside your user folder"
        return None


def start_target(args: list[str]) -> str | None:
    """The program Start-Process / Invoke-Item would run: -FilePath/-Path value, else the first positional."""
    skip_next = False
    for i, a in enumerate(args):
        low = a.lower()
        if low in ("-filepath", "-path", "-literalpath", "-fi", "-lp") and i + 1 < len(args):
            return args[i + 1]
    for i, a in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        if a.startswith("-"):
            skip_next = a.lower() in ("-argumentlist", "-args", "-verb", "-workingdirectory", "-windowstyle", "-credential",
                                      "-redirectstandardoutput", "-redirectstandarderror", "-redirectstandardinput")
            continue
        return a
    return None


def subexpressions(command: str) -> list[str]:
    """The insides of every $( ... ), including inside double-quoted strings, which split() keeps whole."""
    out, i = [], 0
    while (i := command.find("$(", i)) >= 0:
        depth, j = 1, i + 2
        while j < len(command) and depth:
            depth += {"(": 1, ")": -1}.get(command[j], 0)
            j += 1
        out.extend(split(command[i + 2:j - 1]))
        i += 2
    return out


def output_targets(args: list[str]) -> list[str]:
    out = []
    for i, a in enumerate(args):
        if a.lower() in ("-o", "--output", "-outfile", "-destination", "-destinationpath", "-path", "-literalpath",
                         "-filepath", "-target") and i + 1 < len(args):
            out.append(args[i + 1])
    return out


def redirect_targets(seg: str) -> list[str]:
    out = []
    for m in _REDIRECT.finditer(seg):
        t = m.group(1).strip("\"'")
        if not t.startswith("&"):
            out.append(t)
    return out


def command_and_args(words: list[str]) -> tuple[str, list[str]] | None:
    i = 0
    while i < len(words):
        w = words[i]
        if re.match(r"^\$[A-Za-z_:]+\s*=?$", w) or w == "=":
            i += 1
            continue
        if w in ("&", ".", "(", "{", "!", "-not", "@(", "$("):
            i += 1
            continue
        w = w.lstrip("({@$").strip()
        if not w:
            i += 1
            continue
        return w, words[i + 1:]
    return None


def split(s: str) -> list[str]:
    """Splits on ; | && || newlines and braces, outside quotes."""
    segs, cur, quote = [], "", None
    i = 0
    while i < len(s):
        c = s[i]
        if quote:
            cur += c
            if c == quote and not (quote == '"' and i > 0 and s[i - 1] == "`"):
                quote = None
        elif c in ("'", '"'):
            quote = c
            cur += c
        elif c in ";\n|{}()" or (c == "&" and i + 1 < len(s) and s[i + 1] == "&"):
            if cur.strip():
                segs.append(cur)
            cur = ""
            if i + 1 < len(s) and c in "|&" and s[i + 1] == c:
                i += 1
        else:
            cur += c
        i += 1
    if cur.strip():
        segs.append(cur)
    return segs


def shell_words(s: str) -> list[str]:
    """Word split honouring PowerShell quotes (quotes removed, backtick escapes in double quotes)."""
    out, cur, quote, has = [], "", None, False
    esc = False
    for c in s:
        if esc:
            cur += c
            esc = False
            continue
        if c == "`" and quote != "'":
            esc = True
            continue
        if quote:
            if c == quote:
                quote = None
            else:
                cur += c
            continue
        if c in ("'", '"'):
            quote, has = c, True
            continue
        if c in (" ", "\t", ","):
            if has or cur:
                out.append(cur)
            cur, has = "", False
            continue
        if c in "()":
            if has or cur:
                out.append(cur)
            cur, has = "", False
            continue
        cur += c
    if has or cur:
        out.append(cur)
    return out
