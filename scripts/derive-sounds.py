#!/usr/bin/env python3
"""Derive the Classic soundpack's extra sounds from the original spoon set.

The original EventSounds/KeyClicks files cover most events. The rest are made
here by pitch-shifting, reversing or trimming existing files, plus two small
synthesized tones for microphone mute feedback, so every event in the catalog
has a Classic sound. Stdlib only; run from the repo root.
"""
import array, math, wave, os, sys

PACK = os.path.join(os.path.dirname(__file__), "..", "Resources", "Soundpacks", "Classic")

def read(name):
    with wave.open(os.path.join(PACK, name + ".wav"), "rb") as w:
        assert w.getsampwidth() == 2, name
        frames = array.array("h", w.readframes(w.getnframes()))
        return w.getnchannels(), w.getframerate(), frames

def write(name, channels, rate, frames):
    with wave.open(os.path.join(PACK, name + ".wav"), "wb") as w:
        w.setnchannels(channels); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(frames.tobytes())

def deinterleave(frames, channels):
    return [frames[c::channels] for c in range(channels)]

def interleave(chans):
    out = array.array("h")
    for i in range(len(chans[0])):
        for c in chans: out.append(c[i])
    return out

def resample(samples, ratio):
    """Playback-speed change (ratio > 1 = higher pitch, shorter)."""
    n = int(len(samples) / ratio)
    out = array.array("h")
    for i in range(n):
        pos = i * ratio
        j = int(pos); frac = pos - j
        a = samples[j]; b = samples[j + 1] if j + 1 < len(samples) else a
        out.append(int(a + (b - a) * frac))
    return out

def gain(samples, g):
    return array.array("h", (max(-32768, min(32767, int(s * g))) for s in samples))

def fade(samples, rate, ms=4):
    n = min(len(samples), int(rate * ms / 1000))
    for i in range(n):
        samples[i] = int(samples[i] * i / n)
        samples[-1 - i] = int(samples[-1 - i] * i / n)
    return samples

def derive(src, dst, pitch=1.0, g=1.0, reverse=False, max_ms=None):
    channels, rate, frames = read(src)
    chans = deinterleave(frames, channels)
    out = []
    for ch in chans:
        s = resample(ch, pitch) if pitch != 1.0 else array.array("h", ch)
        if reverse: s.reverse()
        if max_ms: s = s[: int(rate * max_ms / 1000)]
        out.append(fade(gain(s, g), rate))
    write(dst, channels, rate, interleave(out))
    print(f"{dst:24} <- {src} pitch={pitch} gain={g}{' reversed' if reverse else ''}")

def tone(dst, freqs, rate=44100, ms_each=110, g=0.35):
    """Short sequence of sine blips with a soft envelope."""
    out = array.array("h")
    for f in freqs:
        n = int(rate * ms_each / 1000)
        for i in range(n):
            env = math.sin(math.pi * i / n) ** 0.5
            out.append(int(32767 * g * env * math.sin(2 * math.pi * f * i / rate)))
    write(dst, 1, rate, out)
    print(f"{dst:24} <- tones {freqs}")

derive("system.willSleep", "system.screenLocked", pitch=0.8)
derive("system.didWake", "system.screenUnlocked", pitch=1.25)
derive("window.created", "window.focused", pitch=1.3, g=0.8)
derive("ui.menuClosed", "ui.menuOpened", reverse=True)
derive("key.other", "key.digit", pitch=1.2)
derive("key.other", "key.punctuation", pitch=0.85)
derive("key.space", "key.tab", pitch=0.8)
derive("key.other", "key.navigation", pitch=1.6, g=0.6, max_ms=70)
derive("key.enter", "key.function", pitch=0.7)
tone("audio.inputMuted", [660, 440])
tone("audio.inputUnmuted", [440, 660])
