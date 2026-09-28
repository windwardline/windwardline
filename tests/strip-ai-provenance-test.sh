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

cp signed.jpg mislabeled.png
bash "$STRIP" mislabeled.png >out 2>&1
rc=$?
if [ "$rc" -eq 0 ] && c2patool mislabeled.png 2>&1 | grep -qi 'no claim found' \
  && [ "$(exiftool -s3 -FileTypeExtension mislabeled.png)" = jpg ]; then
  ok "JPEG data named .png is stripped in place and stays JPEG"
else
  not_ok "JPEG data named .png is stripped in place and stays JPEG (rc=$rc)"; sed 's/^/  /' out
fi

cp signed.jpg keep.jpg
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
