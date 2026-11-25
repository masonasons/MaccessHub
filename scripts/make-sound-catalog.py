#!/usr/bin/env python3
"""Build Resources/SoundCatalog/catalog.json: classic sound schemes MaccessHub
can download on request ("Get More Soundpacks…").

The catalog holds no audio. For each pack it lists one https URL per event,
pointing at a copy that is already public (the Internet Archive, or the Android
Open Source Project's GitHub mirror), with the file's size and SHA-256. The app
downloads those files only when the user asks, checks every hash, and writes a
normal user soundpack.

Where the mapping comes from
----------------------------
Which file plays for which event is decided by WinSounds
(https://github.com/Matthew2244/winsounds, MIT). Its import step reads a folder
of sounds and works out each file's Windows event from the file name
(mappings/events.json, rules.json, overrides.json), and saves the result as
<Schemes>/<id>/scheme.json. This script takes those scheme.json files, picks
one file per MaccessHub event with the SLOTS table below (the same table as
WinSounds' tools/to_maccesshub.py, plus a few catalog-only additions marked
as such), fills the events still empty from the same scheme (FILL, NAMES and
SIBLINGS, also shared with to_maccesshub.py), and then finds that exact file
online:

- Internet Archive items listed in the sources manifest: loose files are
  matched by the SHA-1 the archive publishes; files inside a .zip are matched
  by size, then downloaded and compared byte for byte. The archive serves a
  single file out of a zip, so the app never unzips anything.
- AOSP: matched by git blob id against the tagged source tree.

A file is only used when the copy online is byte-identical to the one WinSounds
mapped. Anything that cannot be found that way is left out; a pack with fewer
than --min-slots events is dropped. .7z sources are skipped. Finally every URL
is downloaded once more and checked against the recorded SHA-256.

Run on a Mac (it uses afinfo for lengths of non-WAV files):

    scripts/make-sound-catalog.py \\
        --schemes ~/Library/Application\\ Support/WinSounds/Schemes \\
        --sources ~/Music/Sound\\ Schemes/manifest.json

Only Python's standard library is needed.
"""

import argparse
import concurrent.futures as cf
import datetime
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import wave
from pathlib import Path

SHORT = 1.5   # menus, rows, windows, music: frequent, must be brief
MEDIUM = 4.0  # app open and quit, dialogs
LONG = 8.0    # rare system events

# MaccessHub event id -> (WinSounds events, best first; longest allowed seconds).
# Same as winsounds/tools/to_maccesshub.py except the lines marked "catalog":
# there WinSounds itself plays login and logout, here MaccessHub is on its own.
SLOTS = {
    "application.launched": (["app_open", "restore"], MEDIUM),
    "application.terminated": (["app_close", "minimize"], MEDIUM),
    "system.login": (["login", "startup"], LONG),            # catalog
    "system.logout": (["logout", "shutdown"], LONG),         # catalog
    "system.willSleep": (["sleep", "logout"], LONG),
    "system.didWake": (["wake", "login"], LONG),
    "system.screenLocked": (["lock"], LONG),
    "system.screenUnlocked": (["unlock"], LONG),
    "system.spaceChanged": (["navigation"], SHORT),
    "display.connected": (["device_connect"], LONG),
    "display.disconnected": (["device_disconnect"], LONG),
    "power.acPower": (["power_connected", "device_connect"], LONG),
    "power.batteryPower": (["power_disconnected", "device_disconnect"], LONG),
    "power.upsPower": (["power_disconnected", "device_disconnect"], LONG),
    "power.battery20Minutes": (["battery_low"], LONG),
    "power.battery10Minutes": (["battery_low"], LONG),
    "power.battery5Minutes": (["battery_critical", "battery_low"], LONG),
    "storage.mounted": (["device_connect"], LONG),
    "storage.unmounted": (["device_disconnect"], LONG),
    "usb.connected": (["device_connect"], LONG),
    "usb.disconnected": (["device_disconnect"], LONG),
    "bluetooth.connected": (["device_connect"], LONG),
    "bluetooth.disconnected": (["device_disconnect"], LONG),
    "network.wifiConnected": (["network_up", "notification"], LONG),
    "network.wifiDisconnected": (["network_down", "device_fail"], LONG),
    "network.ethernetConnected": (["network_up", "notification"], LONG),
    "network.ethernetDisconnected": (["network_down", "device_fail"], LONG),
    "window.created": (["maximize", "restore"], SHORT),
    "window.minimized": (["minimize"], SHORT),
    "window.restored": (["restore", "maximize"], SHORT),
    "window.dialogOpened": (["exclamation", "asterisk", "default_beep"], MEDIUM),  # catalog
    "ui.menuOpened": (["menu_popup"], SHORT),
    "ui.menuItemSelected": (["menu_command"], SHORT),
    "ui.rowExpanded": (["navigation"], SHORT),
    "media.playing": (["restore", "maximize"], SHORT),
    "media.paused": (["minimize"], SHORT),
    "audio.inputUnmuted": (["speech_on"], SHORT),
    "audio.inputMuted": (["speech_off"], SHORT),
}

TICK = 0.5   # plays on every arrow press

# Gap filling, the same tables as winsounds/tools/to_maccesshub.py. After the
# direct matches, every MaccessHub event still empty is offered, in order: more
# of the scheme's own WinSounds events (FILL), a file of the scheme whose name
# says what it is (NAMES: lowercase, letters and digits only; exact, then
# prefix for hints of 5+ characters), then the sound a related slot got on its
# own merit (SIBLINGS, one step only, so a sound never spreads from slot to
# slot). Nothing comes from another scheme, every step keeps the slot's length
# limit, and as everywhere here, only files with a byte-identical public copy
# are used. A slot in DISTINCT first avoids the file its partners got, so one
# moment (a Wi-Fi join, an eject) does not play one sound twice.
FILL = {
    "application.launching": (["app_open", "maximize", "restore", "navigation", "menu_command"], MEDIUM),
    "application.launched": (["app_open", "restore", "maximize"], MEDIUM),
    "application.terminated": (["app_close", "minimize"], MEDIUM),
    "application.activated": (["restore", "maximize", "navigation", "menu_command"], SHORT),
    "system.login": (["startup", "login"], LONG),
    "system.logout": (["shutdown", "logout"], LONG),
    "system.willSleep": (["sleep", "logout", "shutdown"], LONG),
    "system.didWake": (["wake", "login", "startup"], LONG),
    "system.screenLocked": (["lock", "logout"], LONG),
    "system.screenUnlocked": (["unlock", "login"], LONG),
    "system.spaceChanged": (["navigation", "menu_command"], SHORT),
    "display.connected": (["device_connect", "power_connected", "notification", "asterisk"], LONG),
    "display.disconnected": (["device_disconnect", "power_disconnected", "exclamation"], LONG),
    "power.acPower": (["power_connected", "device_connect", "notification", "asterisk"], LONG),
    "power.batteryPower": (["power_disconnected", "device_disconnect", "exclamation"], LONG),
    "power.upsPower": (["power_disconnected", "device_disconnect", "exclamation"], LONG),
    "power.charging": (["power_connected", "device_connect"], LONG),
    "power.charged": (["transfer_complete", "notification", "asterisk", "default_beep"], LONG),
    "power.battery20Minutes": (["battery_low", "exclamation"], LONG),
    "power.battery10Minutes": (["battery_low", "exclamation"], LONG),
    "power.battery5Minutes": (["battery_critical", "battery_low", "critical_stop", "exclamation"], LONG),
    "storage.mounted": (["device_connect", "notification", "asterisk"], LONG),
    "storage.willUnmount": (["device_disconnect", "minimize", "menu_command"], LONG),
    "storage.unmounted": (["device_disconnect", "exclamation"], LONG),
    "storage.renamed": (["menu_command", "navigation", "asterisk", "default_beep"], MEDIUM),
    "usb.connected": (["device_connect", "notification", "asterisk"], LONG),
    "usb.disconnected": (["device_disconnect", "exclamation"], LONG),
    "bluetooth.connected": (["device_connect", "notification", "asterisk"], LONG),
    "bluetooth.disconnected": (["device_disconnect", "exclamation"], LONG),
    "network.wifiConnected": (["network_up", "notification", "asterisk"], LONG),
    "network.wifiDisconnected": (["network_down", "device_fail", "exclamation"], LONG),
    "network.ethernetConnected": (["network_up", "notification", "asterisk"], LONG),
    "network.ethernetDisconnected": (["network_down", "device_fail", "exclamation"], LONG),
    "network.ipv4Acquired": (["network_up", "notification", "asterisk", "default_beep"], LONG),
    "network.ipv4Released": (["network_down", "device_fail", "exclamation"], LONG),
    "window.created": (["maximize", "restore", "app_open"], SHORT),
    "window.focused": (["navigation", "restore"], SHORT),
    "window.minimized": (["minimize", "app_close"], SHORT),
    "window.restored": (["restore", "maximize"], SHORT),
    "window.dialogOpened": (["question", "security_prompt", "information_bar", "asterisk",
                             "menu_popup", "exclamation", "default_beep"], MEDIUM),
    "ui.menuOpened": (["menu_popup", "start_menu"], SHORT),
    "ui.menuClosed": (["menu_command", "navigation", "minimize"], SHORT),
    "ui.menuItemSelected": (["menu_command", "navigation"], SHORT),
    "ui.rowExpanded": (["navigation", "menu_popup"], SHORT),
    "ui.rowCollapsed": (["navigation", "menu_command"], SHORT),
    "ui.selectedRowChanged": (["navigation"], TICK),
    "media.playing": (["restore", "maximize", "app_open"], SHORT),
    "media.paused": (["minimize", "app_close"], SHORT),
    "media.stopped": (["app_close", "minimize"], SHORT),
    "media.trackChanged": (["navigation", "menu_command", "restore"], SHORT),
    "audio.inputUnmuted": (["speech_on", "volume_change", "restore", "maximize"], SHORT),
    "audio.inputMuted": (["speech_off", "volume_change", "minimize"], SHORT),
}

NAMES = {
    "power.charged": ["batteryfull", "fullycharged", "chargecomplete", "chargingcomplete", "batterycharged"],
    "power.charging": ["chargingstarted", "charging", "wirelesschargingstarted"],
    "ui.menuOpened": ["menuopen", "mnuo", "draweropening", "deckuisidemenuflyin"],
    "ui.menuClosed": ["menuclose", "mnuc", "drawerclosing", "itemchooserclose", "deckuihidemodal",
                      "deckuisidemenuflyout", "dialogclose"],
    "ui.menuItemSelected": ["mnus", "menuselect"],
    "ui.rowExpanded": ["interactin", "deckuiintogamedetail", "dscr"],
    "ui.rowCollapsed": ["interactout", "deckuioutofgamedetail", "dscr"],
    "ui.selectedRowChanged": ["deckuinavigation", "cursor", "mnui"],
    "window.dialogOpened": ["dialogopen", "deckuishowmodal", "showmodal"],
    "window.created": ["windowopen", "wopn"],
    "application.terminated": ["windowclose", "wcls"],
    "window.focused": ["wact", "windowactivate"],
    "window.minimized": ["wcol", "windowshaded"],
    "window.restored": ["wexp", "windowunshaded"],
    "system.screenLocked": ["screenoff", "screenlock", "lockscreen"],
    "system.login": ["desktoploginshort", "desktoplogin"],
    "storage.mounted": ["dski", "mediainsert"],
    "storage.unmounted": ["dske", "mediaeject"],
    "audio.inputUnmuted": ["deckuiswitchtoggleon", "on"],
    "audio.inputMuted": ["deckuiswitchtoggleoff", "off"],
}

SIBLINGS = {
    "application.launching": ["application.launched", "window.created"],
    "application.launched": ["application.launching", "window.created", "window.restored"],
    "application.terminated": ["window.minimized", "media.stopped"],
    "application.activated": ["window.focused", "window.restored", "system.spaceChanged"],
    "system.login": ["system.didWake", "system.screenUnlocked"],
    "system.logout": ["system.willSleep", "system.screenLocked"],
    "system.willSleep": ["system.logout", "system.screenLocked"],
    "system.didWake": ["system.login", "system.screenUnlocked"],
    "system.screenLocked": ["system.willSleep", "system.logout"],
    "system.screenUnlocked": ["system.didWake", "system.login"],
    "system.spaceChanged": ["window.focused", "application.activated", "ui.selectedRowChanged"],
    "display.connected": ["usb.connected", "storage.mounted", "bluetooth.connected"],
    "display.disconnected": ["usb.disconnected", "storage.unmounted", "bluetooth.disconnected"],
    "power.acPower": ["power.charging", "usb.connected"],
    "power.batteryPower": ["power.upsPower", "usb.disconnected"],
    "power.upsPower": ["power.batteryPower"],
    "power.charging": ["power.acPower"],
    "power.charged": ["power.charging", "power.acPower"],
    "power.battery20Minutes": ["power.battery10Minutes", "power.battery5Minutes"],
    "power.battery10Minutes": ["power.battery20Minutes", "power.battery5Minutes"],
    "power.battery5Minutes": ["power.battery10Minutes", "power.battery20Minutes"],
    "storage.mounted": ["usb.connected", "display.connected"],
    "storage.willUnmount": ["storage.unmounted", "usb.disconnected"],
    "storage.unmounted": ["usb.disconnected", "display.disconnected"],
    "storage.renamed": ["ui.menuItemSelected"],
    "usb.connected": ["storage.mounted", "bluetooth.connected", "display.connected"],
    "usb.disconnected": ["storage.unmounted", "bluetooth.disconnected", "display.disconnected"],
    "bluetooth.connected": ["usb.connected", "storage.mounted", "display.connected"],
    "bluetooth.disconnected": ["usb.disconnected", "storage.unmounted", "display.disconnected"],
    "network.wifiConnected": ["network.ethernetConnected", "network.ipv4Acquired"],
    "network.wifiDisconnected": ["network.ethernetDisconnected", "network.ipv4Released"],
    "network.ethernetConnected": ["network.wifiConnected", "network.ipv4Acquired"],
    "network.ethernetDisconnected": ["network.wifiDisconnected", "network.ipv4Released"],
    "network.ipv4Acquired": ["network.wifiConnected", "network.ethernetConnected"],
    "network.ipv4Released": ["network.wifiDisconnected", "network.ethernetDisconnected"],
    "window.created": ["window.restored", "application.launched"],
    "window.focused": ["application.activated", "window.restored", "system.spaceChanged"],
    "window.minimized": ["application.terminated", "media.paused"],
    "window.restored": ["window.created", "media.playing"],
    "window.dialogOpened": ["ui.menuOpened", "window.created"],
    "ui.menuOpened": ["ui.rowExpanded"],
    "ui.menuClosed": ["ui.rowCollapsed", "window.minimized"],
    "ui.menuItemSelected": ["ui.selectedRowChanged", "system.spaceChanged"],
    "ui.rowExpanded": ["ui.menuOpened", "window.restored"],
    "ui.rowCollapsed": ["ui.menuClosed", "window.minimized"],
    "ui.selectedRowChanged": ["system.spaceChanged", "ui.menuItemSelected"],
    "media.playing": ["window.restored", "audio.inputUnmuted"],
    "media.paused": ["window.minimized", "audio.inputMuted"],
    "media.stopped": ["media.paused", "application.terminated"],
    "media.trackChanged": ["ui.selectedRowChanged", "system.spaceChanged", "ui.menuItemSelected"],
    "audio.inputUnmuted": ["media.playing", "window.restored"],
    "audio.inputMuted": ["media.paused", "window.minimized"],
}

DISTINCT = {
    "application.launching": ["application.launched"],
    "storage.willUnmount": ["storage.unmounted"],
    "network.ipv4Acquired": ["network.wifiConnected", "network.ethernetConnected"],
    "network.ipv4Released": ["network.wifiDisconnected", "network.ethernetDisconnected"],
    "ui.menuClosed": ["ui.menuItemSelected", "ui.menuOpened"],
    "ui.rowCollapsed": ["ui.rowExpanded"],
    "media.stopped": ["media.paused"],
    "audio.inputMuted": ["audio.inputUnmuted"],
}


# Schemes whose files are not Windows events, mapped by file name instead.
# Mac OS 8.5-9's Platinum sound set uses the Appearance Manager's four-letter
# theme sound codes (Appearance.h): mnuo menu open, mnuc menu close, mnus menu
# item chosen, wcol/wexp window collapse/expand, wact window activate, dscr
# disclosure triangle, dski/dske disk inserted/ejected.
BY_FILENAME = {
    "mac-os-8-5-9-platinum": {
        "ui.menuOpened": "mnuo", "ui.menuClosed": "mnuc", "ui.menuItemSelected": "mnus",
        "window.minimized": "wcol", "window.restored": "wexp", "window.focused": "wact",
        "ui.rowExpanded": "dscr", "ui.rowCollapsed": "dscr",
        "storage.mounted": "dski", "storage.unmounted": "dske",
    },
}

# Formats MaccessHub reads directly; anything else in the catalog (QuickTime
# .mov, Ogg) is converted to .caf by the app after download.
DIRECT = {"wav", "aiff", "aif", "caf", "mp3", "m4a", "aac", "flac"}
ACCEPTED = DIRECT | {"mov", "ogg"}
MAX_FILE_BYTES = 8 * 1024 * 1024

# Readable pack names and groups, by WinSounds scheme id prefix.
GROUPS = [
    ("plus-", "Microsoft Plus!"),
    ("windows-ce", "Windows CE and Mobile"),
    ("windows-mobile", "Windows CE and Mobile"),
    ("windows-", "Windows"),
    ("replacement-", "Windows"),
    ("slow-old-windows", "Windows"),
    ("mac-", "Classic Mac OS"),
    ("android-", "Android"),
    ("ios-", "iPhone"),
]

# Better names than the source folders give, by WinSounds scheme id.
NAMES = {
    "windows-7": "Windows Vista",  # this folder holds the Vista set; the archive's Windows 7 zip is windows-7-sound-schemes
    "windows-98-sound-schemes": "Windows 98",
    "plus-98-dangerous": "Plus! 98 Dangerous Creatures",
    "plus-98-inside-you-computer": "Plus! 98 Inside Your Computer",
    "plus-98-leonardo-davinci": "Plus! 98 Leonardo da Vinci",
    "plus-ms-beta-98": "Plus! 98 Beta",
    "plus-windows98-2": "Plus! Windows 98 (second set)",
    "plus-xp-nature-xp": "Plus! XP Nature",
    "plus-xp-space-xp": "Plus! XP Space",
    "plus-95-extras": "Plus! 95 Extras",
    "plus-win-nt": "Plus! Windows NT",
    "windows-me": "Windows Me",
    "plus-windows-me": "Plus! Windows Me",
    "ios-4-6-ui": "iPhone iOS 4 to 6",
    "ios-4-6-voiceover": "iPhone iOS 4 to 6 VoiceOver",
}

# Mixed or home-made collections, and near copies of a pack already listed.
EXCLUDE = {"windows-extras", "slow-old-windows", "replacement-windows-xp-defaults",
           "replacement-computer-sounds", "replacement-madagascar", "replacement-shrek",
           "windows-xp-home", "windows-xp-professional",
           # near copies (most files identical) of a pack that stays
           "plus-98-jungle", "plus-98-windows-98", "windows-98-sound-schemes-2",
           "plus-xp-ancient-pathways", "plus-windows-me", "plus-windows-98-default"}

AGENT = "MaccessHub sound catalog builder (https://github.com/masonasons/MaccessHub)"


def say(*a):
    print(*a, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ network

class Net:
    def __init__(self, cache):
        self.cache = Path(cache)
        self.cache.mkdir(parents=True, exist_ok=True)

    def get(self, url, cache=True, tries=4):
        key = self.cache / hashlib.sha1(url.encode()).hexdigest()
        if cache and key.exists():
            return key.read_bytes()
        last = None
        for attempt in range(tries):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": AGENT})
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = r.read()
                if cache:
                    tmp = key.with_name(f"{key.name}.{os.getpid()}.{threading.get_ident()}.part")
                    tmp.write_bytes(data)
                    tmp.rename(key)
                return data
            except Exception as e:  # noqa: BLE001 - network errors of every kind retry
                last = e
                time.sleep(1.5 * (attempt + 1))
        raise RuntimeError(f"{url}: {last}")

    def json(self, url):
        text = self.get(url).decode("utf-8")
        if text.startswith(")]}'"):
            text = text[4:]
        return json.loads(text)


def quote_path(path):
    return "/".join(urllib.parse.quote(p) for p in path.split("/"))


# ------------------------------------------------------------------ remote index

class Remote:
    """Everything findable online: SHA-1 and git-blob indexes, zip members by size."""

    def __init__(self, net):
        self.net = net
        self.by_sha1 = {}       # sha1 -> (url, page)
        self.by_blob = {}       # git blob id -> (url, page)
        self.zip_by_size = {}   # size -> [(url, page)]
        self.member_sha1 = {}   # zip member url -> sha1 (filled lazily)

    def add_archive_item(self, ident):
        page = f"https://archive.org/details/{ident}"
        try:
            meta = self.net.json(f"https://archive.org/metadata/{urllib.parse.quote(ident)}")
        except Exception as e:  # noqa: BLE001
            say(f"  skipped {ident}: {e}")
            return
        files = meta.get("files", [])
        zips = []
        for f in files:
            name = f.get("name", "")
            ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
            url = f"https://archive.org/download/{ident}/{quote_path(name)}"
            if ext in ACCEPTED and f.get("sha1"):
                self.by_sha1.setdefault(f["sha1"], (url, page))
            elif ext == "zip" and int(f.get("size", 0)) <= 64 * 1024 * 1024:
                zips.append(name)
            # .7z, .rar and other archives are skipped on purpose.
        for z in zips:
            listing_url = f"https://archive.org/download/{ident}/{quote_path(z)}/"
            try:
                text = self.net.get(listing_url).decode("utf-8", "replace")
            except Exception as e:  # noqa: BLE001
                say(f"  could not list {ident}/{z}: {e}")
                continue
            for href, size in re.findall(
                    r'<a href="(//archive\.org/download/[^"]+)">[^<]*</a>(?:<td>[^<]*){2}<td id="size">(\d+)', text):
                href = html.unescape(href)
                ext = href.rsplit(".", 1)[-1].lower()
                if ext in ACCEPTED:
                    self.zip_by_size.setdefault(int(size), []).append(("https:" + href, page))
        say(f"  {ident}: {len(files)} files, {len(zips)} zips")

    def add_aosp_tag(self, tag, path="data/sounds"):
        base = "https://android.googlesource.com/platform/frameworks/base/+/refs/tags"
        page = f"{base}/{tag}/{path}"
        try:
            tree = self.net.json(f"{base}/{tag}/{path}/?format=JSON&recursive=1")
        except Exception as e:  # noqa: BLE001
            say(f"  skipped AOSP {tag}: {e}")
            return
        n = 0
        for e in tree.get("entries", []):
            name = e.get("name", "")
            if e.get("type") == "blob" and name.rsplit(".", 1)[-1].lower() in ACCEPTED:
                url = ("https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/"
                       f"{tag}/{path}/{quote_path(name)}")
                self.by_blob.setdefault(e["id"], (url, page))
                n += 1
        say(f"  AOSP {tag}: {n} sound files")

    def find(self, path):
        """(url, page) of a byte-identical public copy of the local file, or None."""
        data = path.read_bytes()
        sha1 = hashlib.sha1(data).hexdigest()
        if sha1 in self.by_sha1:
            return self.by_sha1[sha1]
        blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        if blob in self.by_blob:
            return self.by_blob[blob]
        for url, page in self.zip_by_size.get(len(data), []):
            if url not in self.member_sha1:
                try:
                    self.member_sha1[url] = hashlib.sha1(self.net.get(url)).hexdigest()
                except Exception as e:  # noqa: BLE001
                    say(f"  could not fetch {url}: {e}")
                    self.member_sha1[url] = None
            if self.member_sha1[url] == sha1:
                return url, page
        return None


# ------------------------------------------------------------------ local files

_durations = {}


def duration(path):
    key = str(path)
    if key not in _durations:
        d = None
        try:
            with wave.open(key) as w:
                if w.getframerate():
                    d = w.getnframes() / w.getframerate()
        except Exception:  # noqa: BLE001 - not a plain WAV, ask afinfo
            try:
                out = subprocess.run(["afinfo", key], capture_output=True, text=True, timeout=20).stdout
                m = re.search(r"estimated duration:\s*([\d.]+)", out)
                d = float(m.group(1)) if m else None
            except Exception:  # noqa: BLE001
                d = None
        _durations[key] = d
    return _durations[key]


def originals(scheme, scheme_dir, fname):
    """Local copies that may match what is online: the scheme's own file, the
    file it was imported from, the untouched original of a converted file, and
    same-named files in other formats (.ogg beside an .m4a, .mov beside a .wav)."""
    out = [scheme_dir / fname]
    rel = (scheme.get("files") or {}).get(fname)
    root = scheme.get("import_root")
    if rel and root:
        src = Path(root) / rel
        out += [src, src.parent / "_original" / src.name]
        stem = src.stem
        if src.parent.is_dir():
            out += [p for p in sorted(src.parent.iterdir())
                    if p.stem == stem and p.suffix.lower().lstrip(".") in ACCEPTED and p != src]
    seen, result = set(), []
    for p in out:
        if p.is_file() and p not in seen:
            seen.add(p)
            result.append(p)
    return result


# ------------------------------------------------------------------ packs

def group_and_name(scheme):
    sid = scheme["id"]
    group = next((g for prefix, g in GROUPS if sid.startswith(prefix)), "Other")
    name = NAMES.get(sid) or re.sub(r"\s*\(Sound Schemes\)\s*$", "", scheme.get("name") or sid).strip()
    return group, name


def licence_note(scheme, page):
    lic = scheme.get("license") or ""
    if "Apache" in lic:
        return ("Apache License 2.0. From the Android Open Source Project, "
                "downloaded from its public source tree.")
    return ("Copyright belongs to its maker. Downloaded at your request from a public "
            "archive that MaccessHub does not run. For personal use.")


def plan(scheme, scheme_dir, remote, no_fill=False):
    """({event id: (local path, url, page, seconds, how)}, the direct matches' event ids).

    --min-slots, the near-copy check and the same-name tie break all look at
    the direct matches only, so filling gaps never changes which schemes are
    listed."""
    events = scheme.get("events", {})
    chosen = {}
    cache = {}

    def usable(fname, limit):
        if fname not in cache:
            hit = None
            secs = duration(scheme_dir / fname) if (scheme_dir / fname).is_file() else None
            if secs is not None:
                for p in originals(scheme, scheme_dir, fname):
                    if p.suffix.lower().lstrip(".") not in ACCEPTED or p.stat().st_size > MAX_FILE_BYTES:
                        continue
                    found = remote.find(p)
                    if found:
                        hit = (p, found[0], found[1], secs)
                        break
            cache[fname] = hit
        hit = cache[fname]
        return hit if hit and hit[3] <= limit else None

    fixed = BY_FILENAME.get(scheme["id"])
    if fixed:
        names = {Path(n).stem.lower(): n for n in os.listdir(scheme_dir)}
        for slot, stem in fixed.items():
            if stem in names:
                hit = usable(names[stem], MEDIUM)
                if hit:
                    chosen[slot] = hit + (stem,)
    else:
        for slot, (candidates, limit) in SLOTS.items():
            for ev in candidates:
                for fname in events.get(ev, []):
                    hit = usable(fname, limit)
                    if hit:
                        chosen[slot] = hit + (ev,)
                        break
                if slot in chosen:
                    break
    direct = set(chosen)
    if not no_fill:
        fill_gaps(scheme, scheme_dir, chosen, usable)
    return chosen, direct


def normalized(name):
    return "".join(c for c in Path(name).stem.lower() if c.isalnum())


def fill_gaps(scheme, scheme_dir, chosen, usable):
    """Adds FILL, NAMES and then SIBLINGS picks to `chosen` for empty slots."""
    events = scheme.get("events", {})
    by_name = {}
    for n in sorted(os.listdir(scheme_dir)):
        if n.rsplit(".", 1)[-1].lower() in ACCEPTED:
            by_name.setdefault(normalized(n), n)

    def avoid(slot):
        return {chosen[o][0].name for o in DISTINCT.get(slot, []) if o in chosen}

    def from_scheme(slot, limit, avoiding):
        for ev in FILL[slot][0]:
            for fname in events.get(ev, []):
                if fname in avoiding:
                    continue
                hit = usable(fname, limit)
                if hit and hit[0].name not in avoiding:
                    return hit + (ev,)
        for exact in (True, False):
            for hint in NAMES.get(slot, []):
                for key, fname in by_name.items():
                    match = key == hint if exact else (len(hint) >= 5 and key.startswith(hint))
                    if match and fname not in avoiding:
                        hit = usable(fname, limit)
                        if hit:
                            return hit + (f"name:{fname}",)
        return None

    for slot, (_, limit) in FILL.items():
        if slot not in chosen:
            pick = from_scheme(slot, limit, avoid(slot)) or from_scheme(slot, limit, set())
            if pick:
                chosen[slot] = pick
    lenders = {k: v for k, v in chosen.items() if not str(v[4]).startswith("same as ")}
    for slot, (_, limit) in FILL.items():
        if slot in chosen:
            continue
        for other in SIBLINGS.get(slot, []):
            if other in lenders and lenders[other][3] <= limit:
                chosen[slot] = lenders[other][:4] + (f"same as {other}",)
                break


def sources_from_manifest(path):
    items, tags = set(), set()
    for entry in json.loads(Path(path).read_text()):
        src = entry.get("source", "")
        m = re.search(r"archive\.org/details/([^\s/?#]+)", src)
        if m and not m.group(1).lower().endswith(".7z"):
            items.add(m.group(1))
        m = re.search(r"refs/tags/(android-[\w.]+)", src)
        if m:
            tags.add(m.group(1))
    return sorted(items), sorted(tags)


def verify(net, f):
    """Downloads the URL fresh and checks size and SHA-256. Returns an error or None."""
    try:
        data = net.get(f["url"], cache=False)
    except Exception as e:  # noqa: BLE001
        return str(e)
    if len(data) != f["bytes"]:
        return f"size {len(data)}, expected {f['bytes']}"
    if hashlib.sha256(data).hexdigest() != f["sha256"]:
        return "SHA-256 differs"
    return None


def main():
    ap = argparse.ArgumentParser(description="Build MaccessHub's downloadable soundpack catalog.")
    ap.add_argument("--schemes", type=Path,
                    default=Path.home() / "Library/Application Support/WinSounds/Schemes",
                    help="WinSounds imported schemes folder (one scheme.json per scheme)")
    ap.add_argument("--sources", type=Path, default=Path.home() / "Music/Sound Schemes/manifest.json",
                    help="manifest naming the public source of each scheme")
    ap.add_argument("--extra-item", action="append", default=[],
                    help="another Internet Archive identifier to search (repeatable)")
    ap.add_argument("--out", type=Path,
                    default=Path(__file__).resolve().parent.parent / "Resources/SoundCatalog/catalog.json")
    ap.add_argument("--cache", type=Path, default=Path.home() / ".cache/maccesshub-sound-catalog")
    ap.add_argument("--min-slots", type=int, default=3)
    ap.add_argument("--no-verify", action="store_true", help="skip the final download of every URL")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--no-fill", action="store_true",
                    help="direct matches only: leave events with no direct match empty")
    args = ap.parse_args()

    net = Net(args.cache)
    remote = Remote(net)
    items, tags = sources_from_manifest(args.sources)
    items = sorted(set(items) | set(args.extra_item))
    say(f"Indexing {len(items)} Internet Archive items and {len(tags)} AOSP tags")
    for ident in items:
        remote.add_archive_item(ident)
    for tag in tags:
        remote.add_aosp_tag(tag)

    schemes = []
    for d in sorted(args.schemes.expanduser().iterdir()):
        try:
            s = json.loads((d / "scheme.json").read_text())
        except Exception:  # noqa: BLE001
            continue
        if not s.get("hidden") and s.get("id") not in EXCLUDE:
            schemes.append((d, s))

    def work(item):
        d, s = item
        return d, s, plan(s, d, remote, args.no_fill)

    with cf.ThreadPoolExecutor(args.jobs) as pool:
        planned = list(pool.map(work, schemes))

    packs, seen, dropped = [], {}, []
    for d, s, (chosen, direct) in planned:
        group, name = group_and_name(s)
        if len(direct) < args.min_slots:
            dropped.append(f"{name} ({len(direct)})")
            continue
        files = []
        for slot, (local, url, page, secs, ev) in sorted(chosen.items()):
            data = local.read_bytes()
            files.append({"event": slot, "url": url, "bytes": len(data),
                          "sha256": hashlib.sha256(data).hexdigest()})
        signature = tuple(sorted((f["event"], f["sha256"]) for f in files if f["event"] in direct))
        if signature in seen:
            say(f"  {name}: same sounds as {seen[signature]}, left out")
            continue
        seen[signature] = name
        pages = sorted({chosen[k][2] for k in chosen})
        packs.append({
            "id": s["id"], "name": name, "group": group,
            "license": licence_note(s, pages[0]),
            "sources": pages,
            "bytes": sum(f["bytes"] for f in files),
            "files": files,
            "_direct": len(direct),
        })

    # Two schemes with the same display name: keep the one with more sounds.
    by_name = {}
    for p in packs:
        k = p["name"].lower()
        if k not in by_name or p["_direct"] > by_name[k]["_direct"]:
            by_name[k] = p
    packs = [p for p in packs if by_name[p["name"].lower()] is p]
    for p in packs:
        del p["_direct"]

    if not args.no_verify:
        everything = [f for p in packs for f in p["files"]]
        say(f"Verifying {len(everything)} downloads")
        with cf.ThreadPoolExecutor(args.jobs) as pool:
            errors = list(pool.map(lambda f: verify(net, f), everything))
        bad = {f["url"]: e for f, e in zip(everything, errors) if e}
        for url, e in bad.items():
            say(f"  FAILED {url}: {e}")
        for p in packs:
            p["files"] = [f for f in p["files"] if f["url"] not in bad]
            p["bytes"] = sum(f["bytes"] for f in p["files"])
        packs = [p for p in packs if len(p["files"]) >= args.min_slots]

    order = [g for _, g in GROUPS] + ["Other"]
    packs.sort(key=lambda p: (order.index(p["group"]), p["name"].lower()))
    catalog = {
        "format": 1,
        "about": ("Soundpacks MaccessHub can download on request. No audio is stored here: each "
                  "file is fetched from the URL given and must match its SHA-256. Generated by "
                  "scripts/make-sound-catalog.py; do not edit by hand."),
        "generated": datetime.date.today().isoformat(),
        "verified": not args.no_verify,
        "packs": packs,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(catalog, indent=1, ensure_ascii=False) + "\n")
    total = sum(p["bytes"] for p in packs)
    say(f"Wrote {len(packs)} packs, {sum(len(p['files']) for p in packs)} files, "
        f"{total / 1e6:.1f} MB in all, to {args.out}")
    if dropped:
        say(f"Too few sounds found online ({len(dropped)}): {', '.join(dropped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
