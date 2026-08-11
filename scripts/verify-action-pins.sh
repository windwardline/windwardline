#!/bin/bash
# Action pin auditor — enforces FLEET.md's pin-comment standard.
#
# Every third-party `uses:` in a repo's workflows must be pinned to a full 40-hex
# commit SHA and carry a trailing comment naming an immutable tag that the SHA
# actually carries.
#
# Why the comment: it is the only human-readable version signal when a Dependabot
# bump rewrites forty hex characters. Why it must be precise: a comment naming a
# moving alias (`# v4`) is true the day it is written and rots the moment upstream
# re-points it — silently, with nothing in any diff to see. Both failure modes
# were live on 2026-08-11: twelve repos carried `# v6` beside a SHA that is
# v7.0.1, and two more named aliases that had already moved.
#
# Usage:
#   verify-action-pins.sh              sweep every non-archived repo; table; exit 1 on drift
#   verify-action-pins.sh --repo NAME  emit drift tokens for one repo, exit 1 on drift
#
# Exit: 0 clean, 1 drift found, 2 the audit could not be completed.
#
# THE GOVERNING RULE: an audit that could not run must never render as "clean".
# Every failure path below exits 2 rather than returning a pass.
#
# Reads remote state only (gh api + git ls-remote); no checkouts, so it runs from
# any machine with an authenticated gh.

set -u
OWNER="${OWNER:-windwardline}"
# Per-user and private. With TMPDIR unset this lands in a world-writable /tmp
# under a name derivable from any workflow file, and the map is the sole source
# of truth for every tag comparison — a pre-created file could force a clean pass
# over genuinely rotten comments.
CACHE="${TMPDIR:-/tmp}/fleet-action-tags-$(id -u)"
CACHE_TTL_MIN="${CACHE_TTL_MIN:-60}"
REFRESHED=""
# Counts third-party refs actually classified. "All clean" over zero refs is the
# vacuous pass this fleet has shipped before; the sweep refuses to report one.
REFS_SEEN_FILE=""

die() { echo "ERROR: $*" >&2; exit 2; }

# gh_json ENDPOINT -> body on stdout, non-zero on failure.
# `gh api` prints its error body to STDOUT and signals failure only through the
# exit status: a 404 yields 110 bytes of JSON and exit 1. Testing the output for
# emptiness therefore passes a renamed, deleted, or rate-limited repo off as
# readable, and the audit reports it conformant. Status is the only honest signal.
#
# Retries the throttles, not the refusals. A sweep issues roughly six calls per
# repo, which is enough to trip GitHub's SECONDARY rate limit — the burst
# detector, which fires while the primary quota still reads 4313/5000, so
# checking `rate_limit` does not predict it. Observed live on 2026-08-11. A 404
# or 403-on-scope is a real answer and returns immediately.
gh_json() {
  local ep="$1" body rc attempt=0
  while :; do
    body=$(gh api "$ep" 2>/dev/null); rc=$?
    [ $rc -eq 0 ] && { printf '%s' "$body"; return 0; }
    case "$body" in
      *"rate limit"*|*"secondary"*|*"abuse"*|*"Server Error"*|*"try again"*)
        attempt=$((attempt + 1))
        [ $attempt -ge 4 ] && break
        sleep $((attempt * 10))
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$body"
  return $rc
}

# tagmap OWNER/REPO [refresh] -> "tag<TAB>commit-sha" lines. Non-zero on failure.
#
# It must RETURN, never exit: every caller invokes it inside $( ), where an exit
# kills only the subshell. The parent would sail on with an empty tag map and
# report every pin in the fleet as untagged — a network blip rendered as
# fleet-wide drift. Callers check the status.
#
# Annotated tags are dereferenced: `git ls-remote` prints both refs/tags/X (the
# tag OBJECT's sha) and refs/tags/X^{} (the commit). A pin names the commit, so
# the ^{} row wins where it exists; comparing the other row marks every annotated
# tag as a mismatch.
tagmap() {
  local action="$1" refresh="${2:-}" f raw rc tmp
  f="$CACHE/$(printf '%s' "$action" | tr '/' '_').tags"
  mkdir -p "$CACHE" 2>/dev/null || { echo "cannot create $CACHE" >&2; return 1; }
  chmod 700 "$CACHE" 2>/dev/null
  [ -O "$CACHE" ] || { echo "$CACHE not owned by this user; refusing to trust it" >&2; return 1; }
  [ -n "$refresh" ] && rm -f "$f"
  if [ ! -s "$f" ] || [ -n "$(find "$f" -mmin "+$CACHE_TTL_MIN" 2>/dev/null)" ]; then
    raw=$(git ls-remote --tags "https://github.com/$action" 2>/dev/null); rc=$?
    # Status first: a truncated transfer can exit non-zero with partial output,
    # and caching that half-map poisons every run inside the TTL.
    [ $rc -eq 0 ] || { echo "git ls-remote failed for $action (exit $rc)" >&2; return 1; }
    [ -n "$raw" ] || { echo "no tags returned for $action" >&2; return 1; }
    local parsed
    parsed=$(printf '%s\n' "$raw" | awk '
      { sha=$1; ref=$2; sub("refs/tags/","",ref)
        if (ref ~ /\^\{\}$/) { sub(/\^\{\}$/,"",ref); deref[ref]=sha } else { plain[ref]=sha } }
      END { for (t in plain) print t"\t"((t in deref) ? deref[t] : plain[t]) }
    ')
    [ -n "$parsed" ] || { echo "empty tag map for $action" >&2; return 1; }
    # Answer from what was fetched; the cache is best-effort. Failing the lookup
    # because a WRITE failed would discard a perfectly good map and fabricate
    # pin-untagged drift on a conformant repo with a healthy network.
    tmp="$f.$$"                     # PID-suffixed: concurrent runs cannot interleave
    printf '%s\n' "$parsed" > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    printf '%s\n' "$parsed"
    return 0
  fi
  cat "$f"
}

# Emit the `uses:` lines of a workflow, skipping block-scalar bodies.
#
# A `run: |` block is shell, not YAML: a line reading `uses: foo@bar` inside one
# is a string, and treating it as an action reference invents drift. Tracking
# scalar indentation lets the matcher then accept `uses:` anywhere on a real
# line, which picks up flow style (`{uses: x@sha}`) as well as block style.
uses_lines() {
  awk '
    { line=$0; match(line, /^[ ]*/); ind=RLENGTH }
    inscalar {
      if (line ~ /^[ \t]*$/) next
      if (ind > sind) next
      inscalar=0
    }
    line ~ /^[ ]*-?[ ]*[A-Za-z0-9_.-]+:[ ]*[|>][0-9+-]*[ ]*$/ { inscalar=1; sind=ind; next }
    # A commented-out step is not a step. fleet-template parks a disabled
    # osv-scanner call as `#   uses: google/osv-scanner-action/...`; matching
    # `uses:` mid-line without this reads the leading # as the version comment
    # and reports pin-comment-wrong:...#uses: on a conformant repo.
    line ~ /^[ ]*#/ { next }
    line ~ /(^|[ {,])uses:[ ]/ { print line }
  '
}

# audit_repo NAME -> drift tokens on stdout, space-prefixed.
# Returns 0 when the audit completed (clean or drifted), 2 when it could not run.
audit_repo() {
  local r="$1" ref="${2:-}" drift="" repo_json tree paths truncated rc=0

  # The default branch is read, not assumed. Hardcoding `main` makes any repo on
  # another default audit as flawlessly clean — it has no workflows at `main`.
  # The sweep passes it in from the enumeration, which already returns it; only
  # --repo mode pays for the extra call.
  if [ -z "$ref" ]; then
    if ! repo_json=$(gh_json "repos/$OWNER/$r"); then
      echo "cannot read repo $r" >&2; return 2
    fi
    ref=$(printf '%s' "$repo_json" | jq -r '.default_branch // empty' 2>/dev/null)
  fi
  [ -n "$ref" ] || { echo "$r: no default branch" >&2; return 2; }

  if ! tree=$(gh_json "repos/$OWNER/$r/git/trees/$ref?recursive=1"); then
    # A repo with no commits legitimately has no tree; anything else is a failure.
    case "$(printf '%s' "$tree" | jq -r '.message // empty' 2>/dev/null)" in
      *[Ee]mpty*) return 0 ;;
      *) echo "$r: cannot read tree at $ref" >&2; return 2 ;;
    esac
  fi
  truncated=$(printf '%s' "$tree" | jq -r '.truncated // false' 2>/dev/null)
  [ "$truncated" = "true" ] && { echo "$r: tree truncated, audit would be partial" >&2; return 2; }
  paths=$(printf '%s' "$tree" | jq -r '.tree[]? | select(.type=="blob") | .path' 2>/dev/null \
    | grep -E '^\.github/workflows/[^/]+\.ya?ml$|(^|/)action\.ya?ml$')
  [ -n "$paths" ] || return 0

  local p body line ref_v comment action sha claimed tags at precise found
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! body=$(gh_json "repos/$OWNER/$r/contents/$p?ref=$ref"); then
      echo "$r: cannot read $p" >&2; rc=2; continue
    fi
    body=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null)
    [ -n "$body" ] || { echo "$r: empty body for $p" >&2; rc=2; continue; }
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ref_v=$(printf '%s' "$line" \
        | sed -E 's/^.*[ {,]?uses:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[},].*$//; s/[[:space:]]*$//' \
        | tr -d "\"'")
      # First `#` on the line, not the last. A greedy `.*#` reads
      # `... # v4 # pinned 2026-08` as the comment "pinned", then reports a
      # correct pin as wrong.
      #
      # Guard the no-comment case explicitly. Without it the substitution finds
      # nothing, passes the whole line through, and awk's $1 hands back the YAML
      # list dash — so an UNCOMMENTED pin arrives carrying the comment "-",
      # sails past the pin-uncommented check, and is reported as merely wrong.
      case "$line" in
        *"#"*) comment=$(printf '%s' "$line" | sed -E 's/^[^#]*#[[:space:]]*//' | awk '{print $1}' | tr -d '},') ;;
        *)     comment="" ;;
      esac
      case "$ref_v" in
        ""|./*|docker://*) continue ;;
      esac
      case "$(printf '%s' "$ref_v" | cut -d/ -f1 | tr 'A-Z' 'a-z')" in
        "$(printf '%s' "$OWNER" | tr 'A-Z' 'a-z')") continue ;;   # same-owner reusables ride @main by design
      esac
      # A third-party ref we are about to classify. Counted so the sweep can
      # prove it actually looked at something before printing "all clean".
      [ -n "$REFS_SEEN_FILE" ] && printf 'x\n' >> "$REFS_SEEN_FILE"
      case "$ref_v" in
        *@*) ;;
        *) drift="$drift pin-unversioned:$ref_v"; continue ;;
      esac
      action=$(printf '%s' "${ref_v%@*}" | cut -d/ -f1,2)
      sha=$(printf '%s' "${ref_v##*@}" | tr 'A-F' 'a-f')
      if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
        drift="$drift pin-unpinned:$action@${ref_v##*@}"; continue
      fi
      [ -n "$comment" ] || { drift="$drift pin-uncommented:$action"; continue; }
      claimed="$comment"

      if ! tags=$(tagmap "$action"); then
        echo "$r: tag lookup failed for $action" >&2; rc=2; continue
      fi
      at=$(printf '%s\n' "$tags" | awk -F'\t' -v s="$sha" '$2==s {print $1}')
      found=0
      [ -n "$at" ] && printf '%s\n' "$at" | grep -qxF -- "$claimed" && found=1
      # A cached map older than the pin is the one false positive left: Dependabot
      # bumps to a tag published minutes ago, the cache predates it, and a correct
      # pin reads as wrong. Miss once, refetch once, then believe the answer.
      if [ "$found" -eq 0 ]; then
        case " $REFRESHED " in
          *" $action "*) ;;
          *)
            REFRESHED="$REFRESHED $action"
            if tags=$(tagmap "$action" refresh); then
              at=$(printf '%s\n' "$tags" | awk -F'\t' -v s="$sha" '$2==s {print $1}')
              [ -n "$at" ] && printf '%s\n' "$at" | grep -qxF -- "$claimed" && found=1
            fi
            ;;
        esac
      fi
      [ -n "$at" ] || { drift="$drift pin-untagged:$action@$(printf '%s' "$sha" | cut -c1-7)"; continue; }
      [ "$found" -eq 1 ] || { drift="$drift pin-comment-wrong:$action#$claimed"; continue; }

      # Correct today, rot-prone tomorrow: the SHA offers an immutable tag and the
      # comment picked a moving one anyway. `vN` and `vN.M` both move upstream
      # (gitleaks ships a v1.0); only a full patch tag is treated as immutable.
      # Flagged only when a better tag exists, so the rule stays satisfiable for
      # actions that publish majors alone.
      #
      # The candidate must be strict semver. Upstream tag namespaces are full of
      # things that are not versions — codeql-action carries 174 of them
      # (codeql-bundle-20230203, testpoctag), checkout has v6-beta, gitleaks
      # v0.0.0-test. A looser pattern happily advises "use # latest".
      precise=$(printf '%s\n' "$at" | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
      if printf '%s' "$claimed" | grep -qE '^v?[0-9]+(\.[0-9]+)?$' && [ -n "$precise" ]; then
        drift="$drift pin-comment-floating:$action#$claimed(->$precise)"
      fi
    done <<< "$(printf '%s\n' "$body" | uses_lines)"
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
# name:default-branch pairs — the listing already carries the branch, so the
# sweep need not ask again per repo.
ALL=$(gh repo list "$OWNER" --limit 200 --json name,isArchived,defaultBranchRef \
  --jq '[.[] | select(.isArchived | not) | "\(.name):\(.defaultBranchRef.name // "")"] | sort | join(" ")' 2>/dev/null) || ALL=""
[ -n "${ALL// /}" ] || die "repo enumeration returned nothing — refusing a vacuous pass"

REFS_SEEN_FILE=$(mktemp "${TMPDIR:-/tmp}/fleet-pin-refs.XXXXXX") || die "cannot create counter file"
trap 'rm -f "$REFS_SEEN_FILE"' EXIT INT TERM

fail=0
printf '%-22s %s\n' "REPO" "PIN DRIFT (empty = conformant)"
printf '%-22s %s\n' "----" "----"
for entry in $ALL; do
  r=${entry%%:*}
  br=${entry#*:}
  if ! d=$(audit_repo "$r" "$br"); then
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
# Non-vacuity, mirroring the conformance checker's own enumeration guard. A sweep
# that classified nothing must not be able to say "all clean" — every silent-skip
# defect this script has had ended exactly there.
refs_seen=$(wc -l < "$REFS_SEEN_FILE" 2>/dev/null | tr -d ' ')
if [ "${refs_seen:-0}" -eq 0 ]; then
  echo "AUDITED ZERO third-party refs across $(printf '%s' "$ALL" | wc -w | tr -d ' ') repos — refusing a vacuous pass." >&2
  exit 2
fi
echo "$refs_seen third-party refs classified."
case "$fail" in
  0) echo "All action pin comments name the tag their SHA carries." ;;
  1) echo "PIN DRIFT FOUND — FLEET.md defines the standard." >&2 ;;
  *) echo "AUDIT INCOMPLETE — treat as drift until it runs clean." >&2 ;;
esac
exit $fail
