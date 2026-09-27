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
| **Event sounds** – plays a sound when apps launch or quit, the Mac sleeps or wakes, volumes mount, USB and Bluetooth devices come and go, Wi-Fi and Ethernet connect, power source or battery state changes, spaces change, windows open, menus open and close, rows expand, and Music plays or pauses. | EventSounds | – |
| **Key clicks** – a click for every key while typing in a text field, with different sounds for lowercase, uppercase, digits, punctuation, space, return, tab, delete, arrows and function keys. | KeyClicks | – |
| **Audio devices** – cycle output and input devices, mute the microphone, list devices. | Audioswitch | ⌃⇧[ ⌃⇧] ⌃⌘⇧[ ⌃⌘⇧] ⌃⇧M ⌃⇧L ⌃⌘⇧L |
| **System information** – CPU and GPU, memory, disks, macOS version, uptime, battery, current audio devices, clipboard. Press the CPU or memory shortcut twice for the top five processes. Connected devices and their battery levels (AirPods report left, right and case). | recmon | ⌃⇧1 … ⌃⇧9 |
| **Application info** – name, version, bundle ID and path of the frontmost app. | AppInfo | ⌃⇧V |
| **Position info** – "42 percent, item 5 of 12" in tables, outlines and lists; character and line position in text. | PositionInfo | ⌃⇧P |
| **Menu extras** – press once to hear the Nth status item in the menu bar, twice to open it. Off by default. | MenuExt | ⌥⇧1 … ⌥⇧0 |

Every shortcut can be changed or removed in **Settings → Shortcuts** (⌃⇧0
opens it). There are also unbound shortcuts for toggling event sounds and key
clicks.

## Improvements over the spoons

- Memory usage is implemented (it was a stub in recmon), and a double press
  of the CPU or memory shortcut names the top five processes.
- Network, power, battery-level, Bluetooth, screen lock, window, menu, row and
  Music events are all wired up; the classic sound set already had files for
  most of them.
- Key clicks classify keys by Unicode properties rather than ASCII, so accented
  and non-Latin letters click correctly. New categories for digits,
  punctuation, tab, navigation and function keys fall back to the classic
  sounds when a pack does not provide them.
- Audio device switching wraps around (optional) and can speak the volume.
- Position info also handles lists, focused rows, and reports the line number
  in text.
- Clipboard reports describe files and images, and summarise long text.
- All sounds are decoded once and played through a single AVAudioEngine for
  minimal latency; the engine recovers when the output device changes.
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
stay silent, depending on the "Use Classic sounds…" toggle. Key clicks and
event sounds can use different packs.

User packs live in `~/Library/Application Support/MaccessHub/Soundpacks/`.
The **Soundpacks** tab can create an empty pack, duplicate an existing one,
import a folder, or export the sounds currently in use (custom files included)
as a new pack. Event IDs are listed in each pack's "Events without a sound"
section and in `SoundEvent.swift`.

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

Settings are stored as JSON in
`~/Library/Application Support/MaccessHub/settings.json`.

To print every spoken report as text (useful for checking output or filing a
bug):

```sh
MaccessHub.app/Contents/MacOS/MaccessHub --report
```

## Permissions

- **Accessibility** – key clicks (to know when a text field is focused),
  position info, menu extras, and window/menu sounds. Requested on first launch.
- **Input Monitoring** – some macOS versions require this as well for the
  key-click event tap.
- **Automation → VoiceOver** – asked the first time MaccessHub speaks through
  VoiceOver.
- **Bluetooth** – asked when Bluetooth sounds are active.

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
