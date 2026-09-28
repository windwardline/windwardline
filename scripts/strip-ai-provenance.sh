#!/bin/bash
# Strip embedded AI indicators from media before it is published — FLEET.md
# "Published media carries no embedded AI indicator".
#
# Removes every metadata block exiftool can write (C2PA/JUMBF manifests, XMP
# including IPTC digitalSourceType, EXIF and IPTC fields naming a generative
# tool), keeps the colour profile and orientation so the image still looks the
# same, then re-scans each file with scripts/media_provenance.rb. Disclosure is
# the owner's, through each platform's own labeling tool; nothing here removes a
# label a platform requires. Invisible pixel watermarks are left alone by rule.
#
# Usage: strip-ai-provenance.sh FILE...    (rewrites each file in place)
# Exit:  0 every file stripped and re-scanned clean; 1 a marker survived;
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

stripped=0
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
  exiftool -q -q -overwrite_original -all= -tagsfromfile @ -icc_profile -orientation -- "$target" >/dev/null \
    || die "exiftool could not rewrite $f ($stripped of $# already stripped); no scan result is valid."
  if [ "$target" != "$f" ]; then
    cat -- "$target" >"$f" || die "could not write the stripped copy back to $f; it may be truncated."
  fi
  stripped=$((stripped + 1))
done
echo "Stripped $stripped file(s); re-scanning."
ruby "$SCANNER" check "$@"
