# MaccessHub

A menu bar app for macOS that bundles a set of small accessibility helpers,
originally written as Hammerspoon spoons, into one native application with
settings, configurable shortcuts and soundpacks.

Everything it says goes through VoiceOver when VoiceOver is running, so
messages use your own voice and rate and can be interrupted normally. Without
VoiceOver it falls back to the system voice.

## What it does

| Feature | Spoon it replaces | Default shortcuts |
|---------|-------------------|-------------------|
| **Event sounds** – plays a sound when apps launch or quit, the Mac sleeps or wakes, disks mount, USB and Bluetooth devices come and go, Wi-Fi and Ethernet connect, power source or battery state changes, spaces change, windows open, menus open and close, rows expand, Music plays or pauses, and items change in folders you pick (see [Watched folders](#watched-folders)). | EventSounds | – |
| **Focus sounds** – like the Unspoken add-on for NVDA: a distinct sound when focus lands on a button, checkbox, radio button, pop-up, text field, link, list row, outline row, menu item, tab, slider, image or progress indicator. Uses the Unspoken-ng default theme (GPL-2, see the pack's CREDITS.txt). Follows keyboard focus, menu highlighting, row selection, and (optionally) the VoiceOver cursor itself, by polling VoiceOver for its cursor bounds and hit-testing the item beneath. Optionally rendered with HRTF at the control's screen position, with a choice of room reverb. | – | – |
| **Progress bars** – NVDA-style: rising beeps (110 Hz at 0 % doubling every 25 %) and/or speech every N percent as bars fill, optionally for background windows and apps. Beeps can come from the bar's place on screen, a fixed pan, or move left to right (or right to left) as the bar fills. An optional Pleasant beep sound, inspired by the [Pleasant Progress Bar](https://github.com/c469591/Pleasant-Progress-Bar) add-on for NVDA, offers a choice of wave shape (sine, square, triangle, sawtooth, pulse, white noise), a smooth or bell fade, beep length (40 to 100 ms) and the pitch at 0 and 100 percent. Play Sample, Test Beeps and Hear in Context let you try the settings. | – | Optional, unassigned: switch between Classic and Pleasant beeps |
| **Key clicks** – a click for every key while typing in a text field, with different sounds for lowercase, uppercase, digits, punctuation, space, return, tab, delete, arrows and function keys. | KeyClicks | – |
| **Per-app sounds** – give an app its own key clicks, focus sounds and progress bar reports, for example no key clicks in REAPER. Key clicks and focus sounds can be left as they are, turned off, or played quieter (a percentage of normal). Progress bars can be turned off for that app. Settings → Apps; changes apply while the app is in front. Event sounds stay global. | – | – |
| **Audio devices** – cycle output and input devices, mute the microphone (confirmed by speech, a sound, or both), list devices. | Audioswitch | ⌃⇧[ ⌃⇧] ⌃⌘⇧[ ⌃⌘⇧] ⌃⇧M ⌃⇧L ⌃⌘⇧L |
| **System information** – CPU and GPU, memory, disks, macOS version, uptime, battery, current audio devices, clipboard. Press the CPU, memory or disk shortcut twice for the top processes (count and GPU inclusion are settings); press the battery shortcut twice for health, cycles, capacity, voltage and power draw. Connected devices and their battery levels (AirPods report left, right and case; Logitech Bluetooth devices are asked directly over HID++). Network: connection type, Wi-Fi name (with Location access), signal and link rate, IP address and live send/receive speed; press twice for the processes moving the most data. | recmon | ⌃⇧1 … ⌃⇧0 |
| **Application info** – name, version, bundle ID and path of the frontmost app. | AppInfo | ⌃⇧V |
| **Process info** – the frontmost app's process: name, PID, CPU, GPU, memory and running time on one press; bundle ID, version, architecture (and Rosetta), path, parent, threads, CPU time, launch time and window count on two. | – | ⌃⇧- |
| **Position info** – "42 percent, item 5 of 12" in tables, outlines and lists; character and line position in text. | PositionInfo | ⌃⇧P |
| **Menu extras** – press once to hear the Nth status item in the menu bar, twice to open it. Off by default. | MenuExt | ⌥⇧1 … ⌥⇧0 |
| **Speech history** – like the Speech History add-on for NVDA: keeps the last 500 things VoiceOver said (adjustable), steps back and forth through them, copies the current one, and records a run of announcements to the clipboard. See [Speech history](#speech-history). | Speech History | ⇧F11 ⇧F12 F12 |
| **Disk sounds** – from [Plattersong](https://github.com/OnjLouis/Plattersong): a short click whenever a physical disk reads, a lower one when it writes. Each disk has its own on/off switch, volume, pan, bass, middle and treble, with Preview Read and Preview Write. Off until you turn it on. See [Disk sounds](#disk-sounds). | Plattersong | ⌃⇧K |

Every shortcut can be changed or removed in **Settings → Shortcuts** (⌃⇧=
opens it). There are also unbound shortcuts for turning event sounds, key
clicks and focus sounds on or off.

## Sound processing

**Settings → Sound Processing** gives each group of sounds its own volume,
tone and reverb. The groups are event sounds, focus sounds, key clicks,
progress beeps and disk sounds, so you can put reverb on focus sounds and keep key clicks dry,
or make progress beeps brighter without touching anything else.

For each group:

- **Volume**, 0 to 100 percent. It works together with the volume on the
  group's own tab.
- **Bass, Middle and Treble**, each from minus 12 to plus 12 decibels (around
  200 Hz, 1,500 Hz and 5,000 Hz). **Clearer** turns bass down and middle and
  treble up, which can help if high sounds are hard to hear; **Warmer** does the
  opposite; **Flat** puts them back. A limiter stops boosted sounds from
  distorting.
- **Reverb**: small, medium or large room, medium or large hall, plate or
  cathedral, with an amount from dry to fully wet. Focus sounds and progress
  beeps with HRTF on also keep the Room setting on the Focus tab; this reverb
  is added on top.
- **Play Sample** plays one typical sound from the group and **Hear in
  Context** plays a few seconds of everyday use (apps opening, tabbing through
  a dialog, typing, a progress bar filling). Press again to stop. Moving a
  control while a preview plays changes what you hear. Nothing plays on its own.
- **Reset This Group** goes back to full volume, flat tone and no reverb.

Everything starts at full volume, flat and dry, so nothing sounds different
until you change it, and the processing is switched off entirely while a
group is at its defaults.

## Speech history

MaccessHub reads VoiceOver's last spoken phrase ten times a second and keeps a
history of it.

- **⇧F11 / ⇧F12** – previous and next announcement. At either end the
  announcement is repeated with "Oldest" or "Newest" in front. Any new speech
  moves the review position back to the newest announcement.
- **F12** – copy the current announcement.
- **Start recording speech** / **Stop recording and copy speech** – everything
  VoiceOver says in between is copied to the clipboard, one announcement per
  line. Unbound by default; assign them in Settings → Shortcuts.
- **Show speech history window** – the history as a list, newest first, with
  Copy Selected (also ⌘C), Copy All (oldest first, one per line), Clear and
  Close (Escape). Unbound by default; also in the menu bar menu. Nothing is
  captured while the window is in front, so reading it does not add to it.
- **Clear speech history** – unbound by default.

Settings → Tools → Speech History turns it off, sets the maximum number of
announcements, and controls whitespace trimming. Turning it off also releases
its shortcuts, so F12 goes back to other apps.

Anything MaccessHub itself says through VoiceOver while you review, copy or
record is left out of the history.

**Limitation:** VoiceOver only exposes the text of its last phrase, with no
identifier or timestamp, so the same announcement spoken twice in a row (for
example "Button", "Button") is stored once.

## Disk sounds

Ported from Onj's [Plattersong](https://github.com/OnjLouis/Plattersong), so
you can hear a Mac's disks working the way you would hear a hard drive's
platters. **Settings → Disk Sounds** has the on/off switch and a mix for each
physical disk; ⌃⇧K (as in Plattersong, changeable under Shortcuts) or the menu
bar menu turns the sounds on and off.

- Every physical disk is found automatically, internal and external; disk
  images and virtual disks are skipped. Each keeps its own mix, recognised by
  model, size and serial number, whichever port it is plugged into.
- New disks are on by default at 30 percent volume, so the shortcut works
  straight away. Turn off any disk you don't want to hear.
- While disk sounds are on, each disk's read and write counters are checked
  every 25 ms. When off, MaccessHub only looks for connected disks every few
  seconds.
- A busy disk can't build up a backlog: at most two batches of clicks wait to
  play, so the clicking stops when the activity does.
- Disk sounds are also a group on **Settings → Sound Processing**, for reverb
  or an overall volume and tone on top of each disk's own mix.
- The sounds are sample-for-sample Plattersong's; `make check` verifies them
  against Plattersong's reference.

If you used Plattersong, quit it (or clear its shortcut) so ⌃⇧K isn't claimed
twice.

## Watched folders

**Settings → Event Sounds → Watched Folders** plays a sound when items are
added to, removed from, renamed in or changed in folders you pick, such as
Downloads or a shared folder. Nothing is watched until you add a folder.

- **Add Folder…** picks one or more folders; **Stop Watching** removes one.
- **Include items in subfolders** reports changes anywhere inside the folder,
  not only its own items.
- **Also say what changed** speaks after the sound: "New file in Downloads:
  invoice.pdf", "Renamed in Notes: draft.txt to final.txt", "Removed from
  Downloads: invoice.pdf", "Changed in Notes: todo.txt". Two or three items
  are named, more are counted ("12 items added to Downloads"). A folder copied
  in is one item, not one per file inside it.
- Changes are gathered for a second after things go quiet, so copying twenty
  files is one sound. A file still being written, such as a download, is
  reported once it's finished. Browsers' partial download files (`.crdownload`,
  `.part`, `.download`), hidden files and Office's `~$` lock files are skipped.
- "Item changed" is off to begin with, because some apps save often.
- A folder on a disk that isn't connected starts being watched when the disk is.
  For Desktop, Documents, Downloads, and folders on external or network disks,
  macOS asks once whether MaccessHub may read them. If you say no, MaccessHub
  tells you it can't read the folder.

## Improvements over the spoons

- Memory usage is implemented (it was a stub in recmon), and a double press
  of the CPU or memory shortcut names the top five processes.
- Network, power, battery-level, Bluetooth, screen lock, display, window,
  menu, row and Music events are all wired up; the classic sound set already
  had files for most of them, and `scripts/derive-sounds.py` derives the rest
  from it so every event in Classic has a sound.
- Key clicks classify keys by Unicode properties rather than ASCII, so accented
  and non-Latin letters click correctly. New categories for digits,
  punctuation, tab, navigation and function keys fall back to the classic
  sounds when a pack does not provide them.
- Audio device switching wraps around (optional) and can speak the volume.
- Position info also handles lists, focused rows, and reports the line number
  in text.
- Clipboard reports describe files and images, and summarize long text.
- All sounds are decoded once and played through a single AVAudioEngine for
  minimal latency: player nodes stay running and new sounds are scheduled with
  `.interrupts` (microseconds, versus 5–12 ms for stop/play), and the output
  device runs a 256-frame IO buffer. The engine recovers when the output
  device changes.
- Every event has its own on/off switch, a preview button, and a per-event
  custom file.

## Soundpacks

A soundpack is a folder of audio files named after event IDs, plus an optional
`pack.json`:

```
My Pack/
  pack.json                      {"name": "My Pack", "author": "…", "description": "…", "version": "1.0"}
  application.launched.wav
  key.lower.wav
  key.upper.mp3
  …
```

Any format AVFoundation can decode is accepted (wav, aiff, caf, mp3, m4a,
flac). A pack can be partial: missing events either use the Classic sound or
stay silent, depending on the "Use the Classic sound when this pack has none"
toggle. Key clicks and
event sounds can use different packs.

### Variants

An event can have several sounds. MaccessHub picks one at random each time it
plays, and never the same file twice in a row (with two, they alternate). Name
the extra files with a number after the event ID:

```
key.lower.wav
key.lower.2.wav
key.lower.3.wav
```

The number only counts as a variant when what comes before it is a known event
ID. Duplicating a pack and exporting the current scheme keep every variant. A
custom file chosen for one event is always a single sound.

User packs live in `~/Library/Application Support/MaccessHub/Soundpacks/`.
The **Soundpacks** tab can create an empty pack, duplicate an existing one,
import a folder, or save the sounds currently in use (custom files included)
as a new pack. Event IDs are listed in each pack's "Events without a sound"
section and in `SoundEvent.swift`. **Preview Typing** plays a key-clicks pack
as if you typed a short phrase, and **Preview Focus Sounds** plays each
control's sound in turn; press either again to stop.

### Importing NVDA Navigation Sounds packs

**Import NVDA Sounds…** on the Soundpacks tab reads packs made for the NVDA
add-on [Navigation Sounds](https://github.com/ahmedthebest31/navsounds), as a
folder, a folder of packs, or a downloaded `.zip` (zips are capped at 64 MB and
2000 files). No sounds from that project ship with MaccessHub, since many of
them are recordings of phone keyboards; you import the packs you want.

The kind of pack is worked out from the file names.

- **Typing packs** become key-click packs. A file whose name contains "space"
  plays for Space; "delete" or "backspace" for Delete; "bill", "bell", "enter"
  or "return" for Return; "letter" for letters; "number" or "digit" for digits.
  Everything else becomes a variant of both letters and other keys. If a pack
  has no file for Space, Delete or Return, those keys use its general key
  presses too, the way Navigation Sounds plays them.
- **Navigation packs** (files named after NVDA roles, like `button.wav` or
  `treeviewitem.wav`) become focus-sound packs, one sound per kind of control.
  Roles MaccessHub has no slot for are left out.

A name that is already taken gets a number. Files that are not playable audio
are skipped, and the result is spoken and shown at the top of the tab with
buttons to preview the new pack or start using it.

`scripts/verify-nvda-import.sh /path/to/navsounds` runs the importer against a
checkout of Navigation Sounds into a temporary folder and prints what each
pack turns into.

## Building

Requires Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
make            # generate MaccessHub.xcodeproj and build Debug
make run        # build and launch
make install    # Release build copied to /Applications and launched
```

`scripts/package.sh` builds a Developer ID-signed, notarized DMG in `dist/`
(unsigned if no identity is present), and `scripts/release.sh vX.Y.Z` tags
and publishes it as a GitHub release. Pre-built DMGs are on the
[Releases](https://github.com/masonasons/MaccessHub/releases) page.

Updates are delivered with [Sparkle](https://sparkle-project.org): the app
checks `appcast.xml` in this repository, which `release.sh` regenerates and
signs with the EdDSA key on the release machine. "Check for Updates…" is in
the menu bar menu and in Settings → General.

Settings are stored as JSON in
`~/Library/Application Support/MaccessHub/settings.json`.

To print every spoken report as text (useful for checking output or filing a
bug):

```sh
MaccessHub.app/Contents/MacOS/MaccessHub --report
```

## Permissions

- **Accessibility** – key clicks (to know when a text field is focused),
  focus sounds, position info, menu extras, and window/menu sounds. Requested on first launch.
- **Input Monitoring** – some macOS versions require this as well for the
  key-click event tap, and it is needed to read Logitech device batteries.
- **Automation → VoiceOver** – asked the first time MaccessHub speaks through
  VoiceOver or reads its speech for the history. The same permission covers
  both; if speech history stays empty, check System Settings → Privacy &
  Security → Automation → MaccessHub → VoiceOver.
- **Bluetooth** – asked when Bluetooth sounds are active.
- **Files and Folders** – asked the first time a watched folder is in Desktop,
  Documents, Downloads, or on an external or network disk.

The app is not sandboxed, because global shortcuts, the key-click event tap and
accessibility queries against other apps all need direct access.

## Migrating from the spoons

MaccessHub registers the same shortcuts as the spoons, so unload them from
`~/.hammerspoon/init.lua` (or stop Hammerspoon) to avoid two announcements per
key press.

## Credits

Original spoons by Quin Marilyn (Audioswitch, recmon, AppInfo, PositionInfo,
MenuExt), Arthur Pirika (EventSounds) and pitermach (KeyClicks). The Classic
soundpack is their sound set. MIT licensed.

Speech history is based on Mikołaj Hołysz's
[SpeechHistory spoon](https://github.com/mikolysz/speech-history) (MIT), which
introduced polling VoiceOver's last phrase to keep a history.

Disk sounds are ported from Onj's
[Plattersong](https://github.com/OnjLouis/Plattersong) (MIT), including its
disk discovery and its click synthesis, which Plattersong adapted from Sensor
Readout 6.6.1 (MIT, © 2026 Sensor Readout contributors). The licence ships in
the app as `Plattersong-LICENSE.txt`.
