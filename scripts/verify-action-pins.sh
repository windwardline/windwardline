#!/bin/bash
# Action pin auditor — enforces FLEET.md's pin-comment standard.
#
# Every third-party `uses:` in a repo's workflows must be pinned to a full 40-hex
# commit SHA and carry a trailing comment naming an immutable tag that the SHA
# actually carries.
#
# Why the comment: it is the only human-readable version signal when a Dependabot
# bump rewrites forty hex characters. Why it must be precise: a comment naming a
# floating major alias (`# v4`) is true the day it is written and rots the moment
# upstream re-points that alias — silently, with nothing in any diff to see. Both
# failure modes were live on 2026-08-11: twelve repos carried `# v6` beside a SHA
# that is v7.0.1, and two more named aliases that had already moved.
#
# Usage:
#   verify-action-pins.sh              sweep every non-archived repo; table; exit 1 on drift
#   verify-action-pins.sh --repo NAME  emit drift tokens for one repo, exit 1 on drift
#
# Exit: 0 clean, 1 drift found, 2 the audit could not be completed.
#
# Reads remote state only (gh api + git ls-remote); no checkouts, so it runs from
# any machine with an authenticated gh.

set -u
OWNER="${OWNER:-windwardline}"
REF="${REF:-main}"
CACHE="${TMPDIR:-/tmp}/fleet-action-tags"
CACHE_TTL_MIN="${CACHE_TTL_MIN:-60}"

die() { echo "ERROR: $*" >&2; exit 2; }

# tagmap OWNER/REPO -> "tag<TAB>commit-sha" lines. Returns non-zero on failure.
#
# It must RETURN, never exit: every caller invokes it inside $( ), where an exit
# would kill only the subshell. The parent would sail on with an empty tag map
# and report every pin in the fleet as untagged — a network blip rendered as
# fleet-wide drift, with a zero exit code. Callers check the status.
#
# Annotated tags are dereferenced: `git ls-remote` prints both refs/tags/X (the
# tag OBJECT's sha) and refs/tags/X^{} (the commit). A pin names the commit, so
# the ^{} row wins where it exists; comparing the other row marks every annotated
# tag as a mismatch.
tagmap() {
  local action="$1" f raw tmp
  f="$CACHE/$(printf '%s' "$action" | tr '/' '_').tags"
  mkdir -p "$CACHE" 2>/dev/null || { echo "cannot create $CACHE" >&2; return 1; }
  if [ ! -s "$f" ] || [ -n "$(find "$f" -mmin "+$CACHE_TTL_MIN" 2>/dev/null)" ]; then
    raw=$(git ls-remote --tags "https://github.com/$action" 2>/dev/null)
    # Empty means network, auth, or a renamed repo. Caching that would poison
    # every later run inside the TTL, so refuse rather than record it.
    [ -n "$raw" ] || { echo "could not resolve tags for $action" >&2; return 1; }
    tmp="$f.$$"
    printf '%s\n' "$raw" | awk '
      { sha=$1; ref=$2; sub("refs/tags/","",ref)
        if (ref ~ /\^\{\}$/) { sub(/\^\{\}$/,"",ref); deref[ref]=sha } else { plain[ref]=sha } }
      END { for (t in plain) print t"\t"((t in deref) ? deref[t] : plain[t]) }
    ' > "$tmp" || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "empty tag map for $action" >&2; return 1; }
    mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  fi
  cat "$f"
}

# audit_repo NAME -> prints drift tokens on stdout, space-prefixed.
# Returns 0 when the audit completed (clean or drifted), 2 when it could not run.
# "Could not read the repo" must never look like "the repo is clean".
audit_repo() {
  local r="$1" drift="" tree paths truncated rc=0
  tree=$(gh api "repos/$OWNER/$r/git/trees/$REF?recursive=1" 2>/dev/null)
  if [ -z "$tree" ]; then
    # Distinguish an empty/branchless repo (fine) from an unreadable one (not).
    gh api "repos/$OWNER/$r" --silent >/dev/null 2>&1 || { echo "unreadable repo $r" >&2; return 2; }
    return 0
  fi
  truncated=$(printf '%s' "$tree" | jq -r '.truncated // false' 2>/dev/null)
  [ "$truncated" = "true" ] && { echo "$r: tree truncated, audit would be partial" >&2; return 2; }
  paths=$(printf '%s' "$tree" | jq -r '.tree[] | select(.type=="blob") | .path' 2>/dev/null \
    | grep -E '^\.github/workflows/[^/]+\.ya?ml$|(^|/)action\.ya?ml$')
  [ -n "$paths" ] || return 0

  local p body line ref comment action sha claimed tags at precise
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    body=$(gh api "repos/$OWNER/$r/contents/$p?ref=$REF" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
    [ -n "$body" ] || { echo "could not read $r:$p" >&2; rc=2; continue; }
    # `uses:` must be a YAML key, not any old substring. Anchoring to start-of-line
    # (with an optional list dash) is what stops `statuses: 2.0.2` in a pnpm
    # lockfile from being read as an action reference — it did, in the first sweep.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ref=$(printf '%s' "$line" \
        | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//' \
        | tr -d "\"'")
      # First `#` on the line, not the last. A greedy `.*#` reads
      # `... # v4 # pinned 2026-08` as the comment "pinned" and then reports a
      # correct pin as wrong.
      comment=$(printf '%s' "$line" | sed -E 's/^[^#]*#[[:space:]]*//' | awk '{print $1}')
      case "$ref" in
        ""|./*|docker://*) continue ;;
        "$OWNER"/*) continue ;;     # same-owner reusables ride @main by design
      esac
      case "$ref" in
        *@*) ;;
        *) drift="$drift pin-unversioned:$ref"; continue ;;
      esac
      action=$(printf '%s' "${ref%@*}" | cut -d/ -f1,2)
      sha=$(printf '%s' "${ref##*@}" | tr 'A-F' 'a-f')
      if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
        drift="$drift pin-unpinned:$action@${ref##*@}"; continue
      fi
      [ -n "$comment" ] || { drift="$drift pin-uncommented:$action"; continue; }
      claimed="$comment"
      if ! tags=$(tagmap "$action"); then
        echo "$r: tag lookup failed for $action" >&2; rc=2; continue
      fi
      at=$(printf '%s\n' "$tags" | awk -F'\t' -v s="$sha" '$2==s {print $1}')
      [ -n "$at" ] || { drift="$drift pin-untagged:$action@$(printf '%s' "$sha" | cut -c1-7)"; continue; }
      if ! printf '%s\n' "$at" | grep -qxF -- "$claimed"; then
        drift="$drift pin-comment-wrong:$action#$claimed"; continue
      fi
      # Correct today, rot-prone tomorrow: the SHA offers an immutable tag and the
      # comment picked the moving alias anyway. Only flagged when a better tag
      # exists, so the rule stays satisfiable for actions that ship majors only.
      #
      # The candidate must be strict semver. Upstream tag namespaces are full of
      # things that are not versions — codeql-action alone carries 174 of them
      # (codeql-bundle-20230203, testpoctag), and checkout has v6-beta, gitleaks
      # v0.0.0-test, claude-code-action beta. A looser pattern happily advises
      # "use # latest".
      precise=$(printf '%s\n' "$at" | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -1)
      if printf '%s' "$claimed" | grep -qE '^v?[0-9]+$' && [ -n "$precise" ]; then
        drift="$drift pin-comment-floating:$action#$claimed(->$precise)"
      fi
    done <<< "$(printf '%s\n' "$body" | grep -E '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]')"
  done <<< "$paths"
  printf '%s' "$drift"
  return $rc
}

if [ "${1:-}" = "--repo" ]; then
  [ -n "${2:-}" ] || die "--repo needs a repository name"
  out=$(audit_repo "$2") || die "audit of $2 could not be completed"
  [ -n "$out" ] || exit 0
  printf '%s\n' "${out# }"
  exit 1
fi

# Standalone sweep. Deliberately WIDER than fleet-conformance.sh's fleet: pin
# hygiene applies to the standards repo and the seeding template too, and both
# carry workflows. `windwardline`'s own review lane held one of the two original
# rot cases, and `fleet-template` is how a bad comment reaches every repo created
# from here on.
ALL=$(gh repo list "$OWNER" --limit 200 --json name,isArchived \
  --jq '[.[] | select(.isArchived | not) | .name] | sort | join(" ")' 2>/dev/null) || ALL=""
[ -n "${ALL// /}" ] || die "repo enumeration returned nothing — refusing a vacuous pass"

fail=0
printf '%-22s %s\n' "REPO" "PIN DRIFT (empty = conformant)"
printf '%-22s %s\n' "----" "----"
for r in $ALL; do
  if ! d=$(audit_repo "$r"); then
    fail=2; printf '%-22s %s\n' "$r" "AUDIT FAILED (see stderr)"; continue
  fi
  if [ -n "$d" ]; then
    [ "$fail" -eq 0 ] && fail=1
    printf '%-22s %s\n' "$r" "${d# }"
  else
    printf '%-22s %s\n' "$r" "✓"
  fi
done
echo
case "$fail" in
  0) echo "All action pin comments name the tag their SHA carries." ;;
  1) echo "PIN DRIFT FOUND — FLEET.md defines the standard." >&2 ;;
  *) echo "AUDIT INCOMPLETE — treat as drift until it runs clean." >&2 ;;
esac
exit $fail
