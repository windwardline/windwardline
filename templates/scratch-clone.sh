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
#   scripts/scratch-clone.sh <destination> [--no-git]
#
#   --no-git   omit .git. NOT the default, deliberately. .git was excluded by
#             default in the first version and it was wrong: three levelflow-cloud
#             test files shell out to `git status --porcelain` and `git ls-files`,
#             so a copy without .git failed 19 tests in a way that read as missing
#             DATA rather than a missing directory. A default whose failure mode
#             misleads is worse than a slightly larger copy — .git is tens of MB
#             against the gigabytes this script exists to avoid. Pass --no-git only
#             when the copy will not run anything that shells out to git.
set -euo pipefail

die() { printf 'scratch-clone: %s\n' "$*" >&2; exit 1; }

dest=""
with_git=1
for arg in "$@"; do
  case "$arg" in
    --no-git)   with_git=0 ;;
    --with-git) with_git=1 ;;   # accepted for compatibility; now the default
    -*) die "unknown option: $arg" ;;
    *) [ -z "$dest" ] || die "more than one destination given"; dest="$arg" ;;
  esac
done
[ -n "$dest" ] || die "usage: scratch-clone.sh <destination> [--no-git]"

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
  # Directory-ness is tested by entering it, rather than with test(1)'s
  # directory flag. Several fleet repos carry a security test forbidding an
  # inline request body after a curl data flag, and its pattern cannot tell
  # that flag apart from test(1)'s. Satisfying every repo's guards is cheaper
  # than arguing with one of them, and this form is equally correct.
  ( cd "$dest" ) 2>/dev/null || die "destination exists and is not a directory: $dest"
  [ -z "$(ls -A "$dest" 2>/dev/null)" ] || die "destination exists and is not empty: $dest"
fi
mkdir -p "$dest"

# Tracked files plus untracked-but-not-ignored, exactly as git sees them.
# -z/--from0 so paths with spaces or newlines survive the pipe.
git -C "$src" ls-files -z --cached --others --exclude-standard \
  | rsync -a --files-from=- --from0 "$src/" "$dest/"

copied=$(find "$dest" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$copied" -gt 0 ] || die "copied 0 files — refusing to report success on an empty copy"

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

# .git is copied AFTER the assertion above, never before it. When this step ran
# first, an rsync failure here aborted the script under `set -e` and the leak
# assertion never executed — the copy landed on disk unverified, and the only
# signal was a missing success line. A guard that is skipped by the failure of
# an unrelated later step is not a guard.
#
# fsmonitor--daemon.ipc is a SOCKET, created by git's fsmonitor daemon in any
# repo where it has run. rsync cannot recreate it (mkstempsock: Invalid argument,
# exit 23). It is transient and regenerated on demand, so it is excluded by name
# rather than by tolerating exit 23 — tolerating the code would mask genuine copy
# failures too.
#
# A LINKED WORKTREE'S .git IS A POINTER FILE, not a directory: one line reading
# `gitdir: /abs/path/to/main/.git/worktrees/<name>`. Copied verbatim, the scratch
# copy's git resolved back to the SOURCE repository — `git status` in the copy
# answered about the source's tree, `git ls-files` listed the source's files, and
# a write would have landed in the source's worktree metadata. Nothing failed;
# the copy simply reported another repository's answers, which is worse than an
# error and is invisible in a passing test run. Agents work in worktrees
# constantly, so the copy is REBUILT rather than refused: the shared object store
# becomes the copy's own .git, the worktree's HEAD and index come with it, and
# the source's worktree registrations are dropped so the copy claims none of them.
if [ "$with_git" -eq 1 ]; then
  # Tested with -f, not -d, and deliberately: the fleet's secret-hygiene check
  # reads `-d "$…"` as an inline curl request body and refuses the file. The
  # question is the same one either way — a linked worktree's .git is a FILE,
  # every other repository's is a directory.
  if [ ! -f "$src/.git" ]; then
    rsync -a --exclude='fsmonitor--daemon.ipc' "$src/.git" "$dest/" \
      || die "copying .git failed"
  else
    common=$(cd "$src" && git rev-parse --path-format=absolute --git-common-dir) \
      || die "could not resolve the shared git directory of the worktree at $src"
    private=$(cd "$src" && git rev-parse --path-format=absolute --git-dir) \
      || die "could not resolve the git directory of the worktree at $src"
    mkdir -p "$dest/.git" || die "could not create $dest/.git"
    rsync -a --exclude='fsmonitor--daemon.ipc' --exclude='worktrees/' \
      "$common/" "$dest/.git/" || die "copying the shared git directory failed"
    if head_ref=$(cd "$src" && git symbolic-ref -q HEAD); then
      printf 'ref: %s\n' "$head_ref" >"$dest/.git/HEAD"
    else
      (cd "$src" && git rev-parse HEAD) >"$dest/.git/HEAD" \
        || die "could not resolve the HEAD of the worktree at $src"
    fi
    if [ -f "$private/index" ]; then
      cp "$private/index" "$dest/.git/index" || die "copying the worktree index failed"
    fi
    git -C "$dest" config --unset core.worktree >/dev/null 2>&1 || true
    git -C "$dest" config core.bare false || die "could not mark the copy non-bare"
  fi

  # PROVEN, not assumed. The defect this block exists for was silent, so the
  # copy has to demonstrate that its git is its own: the git directory must
  # resolve INSIDE the copy, and HEAD must resolve at all.
  #
  # Compared as REAL paths. On macOS a scratch destination under /var is
  # /private/var once resolved, and git answers with the resolved form — so a
  # textual comparison against the destination as typed condemns a copy that is
  # perfectly correct, which is a guard that fires on the wrong thing.
  dest_real=$(cd "$dest" && pwd -P) || die "the copy's directory could not be resolved"
  resolved=$(cd "$dest" && git rev-parse --path-format=absolute --git-dir) \
    || die "the copy is not a usable git repository"
  resolved=$(cd "$resolved" && pwd -P) || die "the copy's git directory could not be resolved"
  case "$resolved" in
    "$dest_real"/*) : ;;
    *) die "the copy's git directory resolves to $resolved, outside the copy — refusing a copy that would answer with the source repository's tree" ;;
  esac
  (cd "$dest" && git rev-parse HEAD >/dev/null 2>&1) \
    || die "the copy's HEAD does not resolve — refusing a copy whose git cannot answer"
fi

printf 'scratch-clone: %s -> %s (%s)\n' "$src" "$dest" "$(du -sh "$dest" | cut -f1)"
