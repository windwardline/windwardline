#!/usr/bin/env bash
# scratch-clone.sh — copy this repository into a scratch directory WITHOUT the
# heavyweight and secret paths.
#
# WHY THIS EXISTS. On 2026-08-25 a levelflow-cloud fan-out had produced 23 whole
# copies of the repo under /private/tmp, each carrying a 7.7 GB `.calibration-cache`
# it never read: 148.8 GiB of duplicate data, and 20 copies of a live `.env.local`
# alongside it. No test reads that cache — the suite builds its own fixtures with
# mkdtempSync — so every byte was an artifact of copying a directory rather than
# choosing what to copy.
#
# GIT DECIDES WHAT IS COPIED, DELIBERATELY. An exclusion list maintained for this
# script alone would rot: nobody notices a stale entry until a copy is already
# 7.7 GB. Git's ignore rules cannot rot, because they are load-bearing for every
# commit — the paths that must never reach a scratch copy are the same paths that
# must never reach a commit.
#
# The enumeration is `git ls-files --exclude-standard`, NOT an rsync filter. An
# earlier draft used `rsync --filter=':- .gitignore'` and leaked
# .claude/settings.local.json, which is ignored via the user's GLOBAL excludes
# file — something rsync cannot see. `--exclude-standard` honours all three
# sources git honours: .gitignore, .git/info/exclude, and core.excludesFile.
# Anything less is an approximation of git's semantics that silently diverges.
#
# Usage:
#   scripts/scratch-clone.sh <destination> [--with-git]
#
#   --with-git   include .git (default: excluded; a scratch copy rarely needs
#                history, and .git is frequently the largest tracked object)
set -euo pipefail

die() { printf 'scratch-clone: %s\n' "$*" >&2; exit 1; }

dest=""
with_git=0
for arg in "$@"; do
  case "$arg" in
    --with-git) with_git=1 ;;
    -*) die "unknown option: $arg" ;;
    *) [ -z "$dest" ] || die "more than one destination given"; dest="$arg" ;;
  esac
done
[ -n "$dest" ] || die "usage: scratch-clone.sh <destination> [--with-git]"

command -v rsync >/dev/null 2>&1 || die "rsync not found"

src="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repository — refusing, because the .gitignore filter would be vacuous"

# NON-VACUITY GUARD. A repository that ignores nothing would make every check
# below pass having excluded nothing, producing a full-size copy that LOOKS
# correct. A check that cannot fail is worse than no check.
if ! git -C "$src" status --ignored=matching --porcelain 2>/dev/null | grep -q '^!! '; then
  die "git reports no ignored paths at $src — refusing, because the exclusion would be vacuous"
fi

if [ -e "$dest" ]; then
  [ -d "$dest" ] || die "destination exists and is not a directory: $dest"
  [ -z "$(ls -A "$dest" 2>/dev/null)" ] || die "destination exists and is not empty: $dest"
fi
mkdir -p "$dest"

# Tracked files plus untracked-but-not-ignored, exactly as git sees them.
# -z/--from0 so paths with spaces or newlines survive the pipe.
git -C "$src" ls-files -z --cached --others --exclude-standard \
  | rsync -a --files-from=- --from0 "$src/" "$dest/"

copied=$(find "$dest" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$copied" -gt 0 ] || die "copied 0 files — refusing to report success on an empty copy"

if [ "$with_git" -eq 1 ]; then
  rsync -a "$src/.git" "$dest/"
fi

# POST-CONDITION. The filter is asserted, not assumed. This does not guess at
# filenames — an earlier draft matched `.env.*` and tripped on `.env.example`,
# a TRACKED file that belongs in the copy. It asks git what it actually ignores
# and requires that none of it arrived.
ignored=0
leaked=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  ignored=$(( ignored + 1 ))
  [ -e "$dest/$rel" ] && leaked="$leaked $rel"
done < <(git -C "$src" status --ignored=matching --porcelain 2>/dev/null \
           | sed -n 's/^!! //p')

# A source tree that ignores nothing makes the loop above vacuous: it would
# report success having compared zero paths. Today's incident is precisely a
# check that passed without examining anything, so this refuses that outcome.
[ "$ignored" -gt 0 ] \
  || die "git reported no ignored paths at $src — refusing a check that examined nothing"

[ -z "$leaked" ] || die "exclusion failed — ignored paths present in copy:$leaked"

printf 'scratch-clone: %s -> %s (%s)\n' "$src" "$dest" "$(du -sh "$dest" | cut -f1)"
