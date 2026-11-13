#!/bin/sh
# Runs the NVDA Navigation Sounds importer against a navsounds checkout, into a
# temporary folder, and prints what each pack turns into. Never touches the
# real soundpacks folder in Application Support.
#
#   scripts/verify-nvda-import.sh /path/to/navsounds
set -eu
clone=${1:?usage: $0 /path/to/navsounds-clone}
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/maccesshub-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out/packs" "$work/bad"

# Hand-made archives for the edge cases (built here, not taken from the clone).
/usr/bin/python3 -I - "$work/bad" <<'PY'
import sys, zipfile, os, struct
d = sys.argv[1]
def wav():
    data = b"\0\0" * 800
    return b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 16000, 2, 16) + b"data" + struct.pack("<I", len(data)) + data
with zipfile.ZipFile(f"{d}/traversal.zip", "w") as z: z.writestr("../evil.wav", wav())
with zipfile.ZipFile(f"{d}/absolute.zip", "w") as z: z.writestr("/tmp/evil.wav", wav())
open(f"{d}/broken.zip", "wb").write(b"this is not a zip file")
with zipfile.ZipFile(f"{d}/nosounds.zip", "w") as z: z.writestr("readme.txt", "hi")
with zipfile.ZipFile(f"{d}/multi.zip", "w") as z:
    z.writestr("release/Pack A/typing1.wav", wav()); z.writestr("release/Pack A/space.wav", wav())
    z.writestr("release/Pack A/garbage.wav", b"not audio at all")
    z.writestr("release/Pack B/button.wav", wav()); z.writestr("release/Pack B/link.wav", wav())
    z.writestr("__MACOSX/release/Pack A/._typing1.wav", b"junk")
with zipfile.ZipFile(f"{d}/unicode.zip", "w") as z: z.writestr("لوحة مفاتيح/type.wav", wav())
os.makedirs(f"{d}/AlreadyMaccessHub"); open(f"{d}/AlreadyMaccessHub/key.lower.wav", "wb").write(wav())
os.makedirs(f"{d}/Classic"); open(f"{d}/Classic/type.wav", "wb").write(wav())
PY

swiftc -O -parse-as-library -o "$work/verify" \
  "$here/Sources/MaccessHub/Sound/SoundEvent.swift" \
  "$here/Sources/MaccessHub/Sound/Soundpack.swift" \
  "$here/Sources/MaccessHub/Sound/NavSoundsImporter.swift" \
  "$here/scripts/VerifyNVDAImport.swift"
"$work/verify" "$clone" "$work/out/packs" "$work/bad"
