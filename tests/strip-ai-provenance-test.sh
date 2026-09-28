#!/bin/bash
# Integration test for scripts/strip-ai-provenance.sh against real tools: media
# signed with a real C2PA manifest by c2patool, and tagged with IPTC
# digitalSourceType by exiftool, must come out with no manifest c2patool can
# find, a clean scan, and pixels that still decode. Refusals must leave every
# input untouched.
#
# The tools are required, not optional: a run that could not sign a fixture has
# proved nothing about stripping one, so a missing tool exits 2 before any case.

set -u
LC_ALL=C.UTF-8
export LC_ALL

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STRIP="$ROOT/scripts/strip-ai-provenance.sh"
SCAN="$ROOT/scripts/media_provenance.rb"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/strip-ai-provenance-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

for tool in exiftool c2patool ffmpeg ffprobe ruby; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required for this test (brew install $tool)." >&2; exit 2; }
done

passes=0
failures=0
ok() { printf 'ok - %s\n' "$1"; passes=$((passes + 1)); }
not_ok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

cd "$TMP" || exit 2
printf '%s\n' '{"claim_generator":"strip-test/1.0","assertions":[{"label":"c2pa.actions","data":{"actions":[{"action":"c2pa.created","digitalSourceType":"http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"}]}}]}' >manifest.json
ffmpeg -loglevel error -y -f lavfi -i testsrc=size=160x120:rate=1 -frames:v 1 base.jpg || exit 2
ffmpeg -loglevel error -y -f lavfi -i testsrc=size=160x120:rate=1 -frames:v 1 base.png || exit 2
ffmpeg -loglevel error -y -f lavfi -i testsrc=size=160x120:rate=10 -t 1 -pix_fmt yuv420p base.mp4 || exit 2

signed=""
for ext in jpg png mp4; do
  c2patool "base.$ext" -m manifest.json -o "signed.$ext" -f >/dev/null 2>&1 || { echo "ERROR: c2patool could not sign base.$ext" >&2; exit 2; }
  c2patool "signed.$ext" 2>/dev/null | grep -q trainedAlgorithmicMedia || { echo "ERROR: signed.$ext carries no readable manifest; the fixture proves nothing." >&2; exit 2; }
  cp "signed.$ext" "pristine.$ext" || exit 2
  signed="$signed signed.$ext"
done
exiftool -q -o tagged.jpg '-XMP-iptcExt:DigitalSourceType=http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia' \
  '-XMP-xmp:CreatorTool=Generator' base.jpg || exit 2
ruby "$SCAN" check $signed tagged.jpg >/dev/null
[ $? -eq 1 ] || { echo "ERROR: the scanner did not flag the fixtures before stripping; the test would prove nothing." >&2; exit 2; }

# shellcheck disable=SC2086 # $signed is a space-separated list of plain names.
if bash "$STRIP" $signed tagged.jpg >out 2>&1; then
  ok "strip exits 0 on signed and tagged media"
else
  not_ok "strip exits 0 on signed and tagged media"; sed 's/^/  /' out
fi
grep -q '4 media file(s) examined; 0 carry' out && ok "strip reports what it re-scanned" || not_ok "strip reports what it re-scanned"
for f in $signed tagged.jpg; do
  if c2patool "$f" 2>&1 | grep -qi 'no claim found'; then ok "no manifest left in $f"; else not_ok "no manifest left in $f"; fi
  if ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$f" | grep -q video; then ok "$f still decodes"; else not_ok "$f still decodes"; fi
done
if exiftool -s3 -XMP-iptcExt:DigitalSourceType tagged.jpg | grep -q .; then not_ok "IPTC source type removed"; else ok "IPTC source type removed"; fi

# Colour survives. The PNG carries sRGB, gamma and chromaticity chunks, plus
# the one pixel-density chunk it already had, beside its manifest; the JPEG carries an ICC profile, a rotated EXIF
# orientation and an EXIF colour space. All of it must come through unchanged.
python3 - <<'PY' || exit 2
import struct, zlib
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
src = open("pristine.png", "rb").read()
extra = (chunk(b"sRGB", b"\x00") + chunk(b"gAMA", struct.pack(">I", 45455))
         + chunk(b"cHRM", struct.pack(">8I", 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000)))
types, i = [], 8
while i + 8 <= len(src):
    n, = struct.unpack(">I", src[i:i + 4]); types.append(src[i + 4:i + 8]); i += 12 + n
assert types.count(b"pHYs") == 1, "the signed PNG must carry exactly one pHYs chunk of its own"
open("colour.png", "wb").write(src[:33] + extra + src[33:])
PY
icc=$(ls /System/Library/ColorSync/Profiles/*.icc 2>/dev/null | head -1)
[ -n "$icc" ] || { echo "ERROR: no ICC profile on this machine to build the JPEG fixture." >&2; exit 2; }
exiftool -q -o colour.jpg "-icc_profile<=$icc" -EXIF:Orientation#=6 -EXIF:ColorSpace#=1 pristine.jpg || exit 2
png_chunks() { python3 -c "import struct,sys
d=open(sys.argv[1],'rb').read();i=8;o=[]
while i+8<=len(d):
    n,=struct.unpack('>I',d[i:i+4]);t=d[i+4:i+8].decode();o.append(t);i+=12+n
    if t=='IEND':break
print(' '.join(sorted(set(o)-{'IDAT'})))" "$1"; }
jpeg_fields() { exiftool -s3 -ICC_Profile:ProfileDescription -EXIF:Orientation -EXIF:ColorSpace "$1" | tr '\n' '|'; }
want_jpeg=$(jpeg_fields colour.jpg)
bash "$STRIP" colour.png colour.jpg >out 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(png_chunks colour.png)" = "IEND IHDR cHRM gAMA pHYs sRGB" ]; then
  ok "PNG sRGB, gamma, chromaticity and density survive; the manifest does not"
else
  not_ok "PNG sRGB, gamma, chromaticity and density survive (rc=$rc, chunks: $(png_chunks colour.png))"; sed 's/^/  /' out
fi
if [ "$rc" -eq 0 ] && [ -n "$want_jpeg" ] && [ "$(jpeg_fields colour.jpg)" = "$want_jpeg" ]; then
  ok "JPEG ICC profile, orientation and colour space survive"
else
  not_ok "JPEG ICC profile, orientation and colour space survive (want $want_jpeg, got $(jpeg_fields colour.jpg))"
fi
grep -q 'compared before and after' out && ok "strip says which rendering fields it compared" || not_ok "strip says which rendering fields it compared"

cp pristine.jpg mislabeled.png
bash "$STRIP" mislabeled.png >out 2>&1
rc=$?
if [ "$rc" -eq 0 ] && c2patool mislabeled.png 2>&1 | grep -qi 'no claim found' \
  && [ "$(exiftool -s3 -FileTypeExtension mislabeled.png)" = jpg ]; then
  ok "JPEG data named .png is stripped in place and stays JPEG"
else
  not_ok "JPEG data named .png is stripped in place and stays JPEG (rc=$rc)"; sed 's/^/  /' out
fi

cp pristine.jpg keep.jpg
before=$(shasum -a 256 keep.jpg)
printf 'x' >notes.txt
bash "$STRIP" keep.jpg notes.txt >out 2>&1
rc=$?
after=$(shasum -a 256 keep.jpg)
[ "$rc" -eq 2 ] && [ "$before" = "$after" ] && ok "an unsupported input refuses before any write" || not_ok "an unsupported input refuses before any write (rc=$rc)"

ln -s keep.jpg link.jpg
bash "$STRIP" link.jpg >out 2>&1
rc=$?
[ "$rc" -eq 2 ] && [ "$before" = "$(shasum -a 256 keep.jpg)" ] && ok "a symlink is refused" || not_ok "a symlink is refused (rc=$rc)"

bash "$STRIP" >out 2>&1
[ $? -eq 2 ] && grep -q 'touched nothing' out && ok "no input is not a pass" || not_ok "no input is not a pass"

printf '%s passed; %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
