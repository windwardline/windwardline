#!/bin/bash
# Strip embedded AI indicators from media before it is published — FLEET.md
# "Published media carries no embedded AI indicator".
#
# Removes every metadata block exiftool can write (C2PA/JUMBF manifests, XMP
# including IPTC digitalSourceType, EXIF and IPTC fields naming a generative
# tool, JFIF density, container tags), then writes back the fields that decide
# how the picture looks: the ICC profile, EXIF orientation and colour space, and
# PNG sRGB, gamma and pixel density (PNG chromaticity survives on its own).
# It proves that by fingerprinting those fields before and after and failing on
# any difference, then re-scans each file with scripts/media_provenance.rb.
# Video colour and rotation live in the stream, which exiftool does not touch. Disclosure is
# the owner's, through each platform's own labeling tool; nothing here removes a
# label a platform requires. Invisible pixel watermarks are left alone by rule.
#
# Usage: strip-ai-provenance.sh FILE...    (rewrites each file in place)
# Exit:  0 every file stripped and re-scanned clean; 1 a marker survived or a
#        rendering field changed;
#        2 could not run. Every input is validated before the first write, so a
#        refusal leaves every file as it was.

set -u
LC_ALL=C.UTF-8
export LC_ALL

here=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)
SCANNER="$here/media_provenance.rb"
die() { echo "ERROR: $*" >&2; exit 2; }

command -v exiftool >/dev/null 2>&1 || die "exiftool is required (brew install exiftool)."
command -v ruby >/dev/null 2>&1 || die "ruby is required for the post-strip scan."
[ -r "$SCANNER" ] || die "scanner is missing: $SCANNER"
[ "$#" -gt 0 ] || die "no file given; a strip that touched nothing is not a pass."

extensions=$(ruby "$SCANNER" extensions) || die "could not read the supported media population."
pattern="\\.($(printf '%s' "$extensions" | tr ' ' '|'))\$"
for f in "$@"; do
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] && [ -w "$f" ] \
    || die "$f is not a writable regular file (symlinks are refused); nothing was changed."
  printf '%s\n' "$f" | grep -qiE "$pattern" \
    || die "$f is not a supported media type ($extensions); nothing was changed."
done

work=$(mktemp -d "${TMPDIR:-/tmp}/strip-ai-provenance.XXXXXX") || die "cannot create a private work directory."
trap 'rm -rf "$work"' EXIT HUP INT TERM

# The fields that decide how the picture renders. A strip that changed any of
# them changed the picture, whatever the pixels hash to.
KEEP="-icc_profile -orientation -EXIF:ColorSpace -InteropIndex -PNG:SRGBRendering -PNG:Gamma -PNG:PixelsPerUnitX -PNG:PixelsPerUnitY -PNG:PixelUnits"
fingerprint() {
  exiftool -j -G1 -a -ICC_Profile:all -EXIF:Orientation -EXIF:ColorSpace -InteropIndex \
    -PNG:SRGBRendering -PNG:Gamma -PNG:WhitePointX -PNG:WhitePointY -PNG:RedX -PNG:RedY \
    -PNG:GreenX -PNG:GreenY -PNG:BlueX -PNG:BlueY -PixelsPerUnitX -PixelsPerUnitY -PixelUnits \
    -Composite:Rotation -- "$1" 2>/dev/null | grep -v '"SourceFile"'
}

stripped=0
changed=""
for f in "$@"; do
  # exiftool refuses to rewrite a file whose name lies about its type (a JPEG
  # saved as .png). Such a file is stripped as a copy named for what it really
  # is, then written back under its original name, so nothing else changes.
  actual=$(exiftool -s3 -FileTypeExtension -- "$f" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ -n "$actual" ] || die "exiftool could not identify $f ($stripped of $# already stripped); no scan result is valid."
  named=$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')
  case "$named:$actual" in
    jpeg:jpg|jpg:jpeg|tiff:tif|tif:tiff) actual=$named ;;
  esac
  target=$f
  if [ "$named" != "$actual" ]; then
    target="$work/$stripped.$actual"
    cp -p -- "$f" "$target" || die "could not copy $f for stripping ($stripped of $# already stripped)."
    echo "$f is $actual data named .$named; stripped as .$actual and written back under its own name."
  fi
  # -overwrite_original writes a temporary file and renames it over the
  # target, so a failure leaves this file whole; earlier files stay stripped.
  before=$(fingerprint "$target") || die "could not read the colour fields of $f; nothing about it is proven."
  # shellcheck disable=SC2086 # KEEP is a fixed list of exiftool tag arguments.
  exiftool -q -q -overwrite_original -all= -tagsfromfile @ $KEEP -- "$target" >/dev/null \
    || die "exiftool could not rewrite $f ($stripped of $# already stripped); no scan result is valid."
  after=$(fingerprint "$target") || die "could not re-read the colour fields of $f after stripping."
  [ "$before" = "$after" ] || changed="$changed $f"
  if [ "$target" != "$f" ]; then
    cat -- "$target" >"$f" || die "could not write the stripped copy back to $f; it may be truncated."
  fi
  stripped=$((stripped + 1))
done
echo "Stripped $stripped file(s); colour profile, colour space, gamma, chromaticity, density, orientation and rotation compared before and after."
if [ -n "$changed" ]; then
  echo "FAIL rendering fields changed in:$changed" >&2
  ruby "$SCANNER" check "$@" >/dev/null
  exit 1
fi
ruby "$SCANNER" check "$@"
