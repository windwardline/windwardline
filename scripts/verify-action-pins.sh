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
#   verify-action-pins.sh --snapshot-manifest FILE [COUNT]
#                                      audit exact repo<TAB>commit rows without
#                                      re-enumerating repositories or branches
#
# Exit: 0 clean, 1 drift found, 2 the audit could not be completed.
#
# THE GOVERNING RULE: an audit that could not run must never render as "clean".
# Every failure path below exits 2 rather than returning a pass.
#
# Sweep mode reads remote state only (gh api + git ls-remote). The PR composite
# passes an exact commit to --git-tree; --local remains a developer diagnostic.

set -u

# Locale-independent for the same reason as scripts/fleet-conformance.sh: this
# script drives ruby over workflow YAML, and a scheduled task runs with LANG
# unset, making ruby's default external encoding US-ASCII.
LC_ALL=C.UTF-8
export LC_ALL
OWNER="windwardline"
REVIEW_WORKFLOW_REF="windwardline/windwardline/.github/workflows/claude-review.yml@main"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
YAML_INSPECTOR="$SCRIPT_DIR/actions_yaml_inspector.rb"
# The PR controls workflow/job/step env. Policy inputs therefore cannot inherit
# OWNER, TMPDIR, a cache path, or a TTL from that environment. One private cache
# lives only for this process: it still deduplicates tag lookups across the fleet,
# but no checked-out file or earlier run can seed the evidence it trusts.
CACHE=$(mktemp -d /tmp/fleet-action-tags.XXXXXX) \
  || { echo "ERROR: cannot create private action-tag cache" >&2; exit 2; }
chmod 700 "$CACHE" 2>/dev/null \
  || { echo "ERROR: cannot protect private action-tag cache" >&2; exit 2; }
REFRESHED=""
# Counts third-party refs actually classified. "All clean" over zero refs is the
# vacuous pass this fleet has shipped before; the sweep refuses to report one.
REFS_SEEN_FILE=""
REPO_ROWS_FILE=""

die() { echo "ERROR: $*" >&2; exit 2; }

# shellcheck disable=SC2329 # Invoked indirectly by the traps below.
cleanup() {
  [ -z "$REFS_SEEN_FILE" ] || rm -f -- "$REFS_SEEN_FILE"
  [ -z "$REPO_ROWS_FILE" ] || rm -f -- "$REPO_ROWS_FILE"
  [ -z "$CACHE" ] || rm -rf -- "$CACHE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v ruby >/dev/null 2>&1 || die "ruby is required for fail-closed YAML inspection"
[ -r "$YAML_INSPECTOR" ] || die "YAML inspector is missing: $YAML_INSPECTOR"
GIT_BIN=$(command -v git) || die "git is required for action tag and tree inspection"
[ -d "$CACHE" ] && [ ! -L "$CACHE" ] && [ -O "$CACHE" ] \
  || die "private action-tag cache failed ownership validation"

decode_base64() {
  if printf '' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

# decode_api_content JSON LABEL -> decoded bytes in DECODED_CONTENT.
#
# GitHub wraps file bytes in a base64 JSON field. Every layer is checked: one
# JSON document, the documented response shape, strict base64 spelling, a
# successful decoder exit, a non-empty body, and a canonical round trip. jq's
# default streaming mode and permissive base64 decoders can otherwise accept a
# good prefix followed by a malformed/truncated response and let a partial audit
# report clean.
decode_api_content() {
  local payload="$1" label="$2" encoded compact decoded sentinel canonical
  if ! encoded=$(printf '%s' "$payload" | jq -ser '
      if length == 1
         and (.[0] | type == "object")
         and (.[0].content | type == "string" and length > 0)
         and ((.[0] | has("encoding") | not) or .[0].encoding == "base64")
      then .[0].content
      else error("unexpected content response shape")
      end
    ' 2>/dev/null); then
    echo "$label: content response was malformed or had an unexpected shape" >&2
    return 1
  fi
  compact=$(printf '%s' "$encoded" | tr -d '[:space:]')
  [ -n "$compact" ] || { echo "$label: empty base64 content" >&2; return 1; }
  [ $(( ${#compact} % 4 )) -eq 0 ] \
    || { echo "$label: malformed base64 length or padding" >&2; return 1; }
  printf '%s' "$compact" | grep -qE '^[A-Za-z0-9+/]*={0,2}$' \
    || { echo "$label: malformed base64 characters or padding" >&2; return 1; }

  sentinel=$'\034'
  if decoded=$(
    printf '%s' "$compact" | decode_base64 2>/dev/null || exit 1
    printf '%s' "$sentinel"
  ); then
    DECODED_CONTENT=${decoded%"$sentinel"}
  else
    echo "$label: base64 content did not decode" >&2
    return 1
  fi
  [ -n "$DECODED_CONTENT" ] || { echo "$label: decoded content was empty" >&2; return 1; }
  canonical=$(printf '%s' "$DECODED_CONTENT" | base64 | tr -d '[:space:]')
  [ "$canonical" = "$compact" ] \
    || { echo "$label: base64 content failed canonical round-trip validation" >&2; return 1; }
}

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
  [ -d "$CACHE" ] && [ ! -L "$CACHE" ] && [ -O "$CACHE" ] \
    || { echo "$CACHE is not a private owned directory; refusing to trust it" >&2; return 1; }
  if [ -n "$refresh" ]; then
    rm -f "$f" 2>/dev/null || { echo "cannot invalidate tag cache $f" >&2; return 1; }
  fi
  if [ ! -s "$f" ]; then
    raw=$(
      cd "$CACHE" || exit 1
      /usr/bin/env -i \
        PATH="$(dirname "$GIT_BIN"):/usr/bin:/bin" \
        HOME="$CACHE" \
        LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_COUNT=0 \
        GIT_TERMINAL_PROMPT=0 \
        GIT_NO_REPLACE_OBJECTS=1 \
        "$GIT_BIN" ls-remote --tags "https://github.com/$action" 2>/dev/null
    ); rc=$?
    # Status first: a truncated transfer can exit non-zero with partial output,
    # and caching that half-map poisons every later lookup in this run.
    [ $rc -eq 0 ] || { echo "git ls-remote failed for $action (exit $rc)" >&2; return 1; }
    # A successful call that returned nothing is an ANSWER, not a failure: this
    # repo publishes no tags. Emitting an empty map lets the caller report
    # pin-untagged — a finding — instead of aborting the whole audit. Conflating
    # the two made a legitimately untagged action look like a broken lookup.
    [ -n "$raw" ] || return 0
    local parsed
    if ! parsed=$(printf '%s\n' "$raw" | awk '
      { sha=$1; ref=$2; sub("refs/tags/","",ref)
        if (ref ~ /\^\{\}$/) { sub(/\^\{\}$/,"",ref); deref[ref]=sha } else { plain[ref]=sha } }
      END { for (t in plain) print t"\t"((t in deref) ? deref[t] : plain[t]) }
    '); then
      echo "tag response could not be normalized for $action" >&2
      return 1
    fi
    [ -n "$parsed" ] || return 0
    # Answer from what was fetched; the cache is best-effort. Failing the lookup
    # because a WRITE failed would discard a perfectly good map and fabricate
    # pin-untagged drift on a conformant repo with a healthy network.
    tmp="$f.$$"                     # PID-suffixed: concurrent runs cannot interleave
    if printf '%s\n' "$parsed" > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null; then
      :
    else
      rm -f "$tmp"
    fi
    printf '%s\n' "$parsed"
    return 0
  fi
  cat "$f"
}

# audit_repo NAME -> drift tokens on stdout, space-prefixed.
# Returns 0 when the audit completed (clean or drifted), 2 when it could not run.
# audit_content LABEL — reads one file's text on stdin, prints drift tokens,
# returns 0 or 2. The remote sweep and the in-CI gate both call this, so the
# rule enforced on a pull request cannot drift from the rule the fleet checker
# applies afterwards. One implementation, two input sources.
audit_content() {
  local label="$1" drift="" rc=0 ref_v comment line_number scope job_id action sha claimed tags at precise found parsed rows duplicate_lines canonical_review_file
  if ! parsed=$(ruby "$YAML_INSPECTOR" uses); then
    echo "$label: YAML uses-key inspection failed" >&2
    return 2
  fi
  printf '%s' "$parsed" | jq -e 'type == "array" and all(.[];
      (.value | type == "string" and test("^[^[:space:]]+$"))
      and (.comment | type == "string")
      and (.comment_token | type == "string")
      and (.line | type == "number" and . > 0 and floor == .)
      and (.scope == "job" or .scope == "step")
      and (.job_id | type == "string" and length > 0))' >/dev/null 2>&1 \
    || { echo "$label: YAML inspector returned an unexpected uses response" >&2; return 2; }
  duplicate_lines=$(printf '%s' "$parsed" | jq -r 'group_by(.line)[] | select(length > 1) | .[0].line') \
    || { echo "$label: duplicate uses-key rows could not be derived" >&2; return 2; }
  while IFS= read -r line_number; do
    [ -n "$line_number" ] || continue
    drift="$drift pin-multiple-uses-one-line:$label:$line_number"
  done <<EOF
$duplicate_lines
EOF
  # Keep the possibly empty comment token last. Bash treats tab as IFS
  # whitespace and collapses adjacent delimiters, so putting an empty comment
  # in the middle silently shifts every field left and makes an uncommented pin
  # look commented.
  rows=$(printf '%s' "$parsed" | jq -r '.[] | [.value, (.line | tostring), .scope, .job_id, .comment_token] | @tsv') \
    || { echo "$label: uses-key rows could not be materialized" >&2; return 2; }
  while IFS=$'\t' read -r ref_v line_number scope job_id comment; do
    [ -n "$ref_v" ] || continue
    case "$ref_v" in
      ""|./*) continue ;;
      docker://*)
        # A Docker tag is every bit as mutable as actions/checkout@main. Only
        # an OCI sha256 digest is content-addressed; a tag-shaped docker:// ref
        # must not disappear through a protocol-wide exemption.
        [ -n "$REFS_SEEN_FILE" ] && printf 'x\n' >> "$REFS_SEEN_FILE"
        if printf '%s' "$ref_v" | grep -qE '^docker://[^@[:space:]]+@sha256:[0-9a-f]{64}$'; then
          continue
        fi
        drift="$drift pin-docker-mutable:$ref_v"
        continue
        ;;
    esac
    # One reusable workflow in the canonical `review` job deliberately rides
    # @main so a central review update lands fleet-wide. The inspector supplies
    # the structural scope and job identity: the same spelling in a step or a
    # different job is not exempt. No owner-wide mutable escape remains.
    case "$label" in
      .github/workflows/claude-review.yml|*:.github/workflows/claude-review.yml)
        canonical_review_file=1
        ;;
      *) canonical_review_file=0 ;;
    esac
    if [ "$canonical_review_file" -eq 1 ] && [ "$scope" = job ] && [ "$job_id" = review ] \
      && [ "$ref_v" = "$REVIEW_WORKFLOW_REF" ]; then
      continue
    fi
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
      echo "$label: tag lookup failed for $action" >&2; rc=2; continue
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
          else
            echo "$label: tag lookup failed for $action" >&2
            rc=2
            continue
          fi
          ;;
      esac
    fi
    [ -n "$at" ] || { drift="$drift pin-untagged:$action@$(printf '%s' "$sha" | cut -c1-7)"; continue; }
    [ "$found" -eq 1 ] || { drift="$drift pin-comment-wrong:$action#$claimed"; continue; }

    # Correct today, rot-prone tomorrow: latest/stable/beta and `vN`/`vN.M`
    # aliases can all move upstream. A claim is accepted only when it names an
    # exact three-component release tag. This shape covers every legitimate tag
    # currently deployed in the fleet.
    #
    # The candidate must be strict semver. Upstream tag namespaces are full of
    # things that are not versions — codeql-action carries 174 of them
    # (codeql-bundle-20230203, testpoctag), checkout has v6-beta, gitleaks
    # v0.0.0-test. A looser pattern happily advises "use # latest".
    precise=$(printf '%s\n' "$at" | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    if ! printf '%s' "$claimed" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
      if [ -n "$precise" ]; then
        drift="$drift pin-comment-imprecise:$action#$claimed(->$precise)"
      else
        drift="$drift pin-comment-imprecise:$action#$claimed"
      fi
    fi
  done <<EOF
$rows
EOF
  printf '%s' "$drift"
  return $rc
}

audit_repo() {
  local r="$1" ref="${2:-}" supplied_sha="${3:-}" drift="" repo_json branch_json encoded_branch default_sha tree entries truncated rc=0 message
  local encoded_entry entry_json p blob_sha mode body d

  if [ -n "$supplied_sha" ]; then
    printf '%s' "$supplied_sha" | grep -qE '^[0-9a-f]{40}$' \
      || { echo "$r: snapshot manifest carried a malformed commit SHA" >&2; return 2; }
    default_sha=$supplied_sha
  else
    # The default branch is read, not assumed. Hardcoding `main` makes any repo
    # on another default audit as flawlessly clean — it has no workflows at
    # `main`. The standalone sweep passes the branch from its enumeration; only
    # --repo mode pays for the extra identity call. Fleet conformance instead
    # passes its already-captured commit through --snapshot-manifest.
    if [ -z "$ref" ]; then
      if ! repo_json=$(gh_json "repos/$OWNER/$r"); then
        echo "cannot read repo $r" >&2; return 2
      fi
      printf '%s' "$repo_json" | jq -se '
        length == 1 and (.[0] | type == "object")
        and (.[0].default_branch | type == "string" and length > 0)
      ' >/dev/null 2>&1 \
        || { echo "$r: repository response had an unexpected shape" >&2; return 2; }
      ref=$(printf '%s' "$repo_json" | jq -sr '.[0].default_branch')
    fi
    [ -n "$ref" ] || { echo "$r: no default branch" >&2; return 2; }

    if ! encoded_branch=$(printf '%s' "$ref" | jq -sRr @uri 2>/dev/null); then
      echo "$r: default branch could not be URL-encoded" >&2
      return 2
    fi
    if ! branch_json=$(gh_json "repos/$OWNER/$r/branches/$encoded_branch"); then
      # Preserve the one legitimate no-tree case without treating an arbitrary
      # branch lookup failure as clean.
      if ! tree=$(gh_json "repos/$OWNER/$r/git/trees/$encoded_branch?recursive=1"); then
        if ! message=$(printf '%s' "$tree" | jq -ser '
            if length == 1 and (.[0] | type == "object") and (.[0].message | type == "string")
            then .[0].message
            else error("unexpected error response shape")
            end
          ' 2>/dev/null); then
          echo "$r: default-branch error response was malformed" >&2
          return 2
        fi
        case "$message" in
          "Git Repository is empty."|"Git Repository is empty") return 0 ;;
        esac
      fi
      echo "$r: cannot resolve default branch $ref to a commit" >&2
      return 2
    fi
    printf '%s' "$branch_json" | jq -se --arg branch "$ref" '
      length == 1 and (.[0] | type == "object") and .[0].name == $branch
      and (.[0].commit.sha | type == "string" and test("^[0-9a-f]{40}$"))
    ' >/dev/null 2>&1 \
      || { echo "$r: default-branch response had an unexpected shape" >&2; return 2; }
    default_sha=$(printf '%s' "$branch_json" | jq -sr '.[0].commit.sha')
  fi

  if ! tree=$(gh_json "repos/$OWNER/$r/git/trees/$default_sha?recursive=1"); then
    if ! message=$(printf '%s' "$tree" | jq -ser '
        if length == 1 and (.[0] | type == "object")
        then .[0].message // ""
        else error("unexpected error response shape")
        end
      ' 2>/dev/null); then
      echo "$r: tree error response was malformed" >&2
      return 2
    fi
    case "$message" in
      "Git Repository is empty."|"Git Repository is empty") return 0 ;;
      *) echo "$r: cannot read tree at $default_sha" >&2; return 2 ;;
    esac
  fi
  printf '%s' "$tree" | jq -se '
    length == 1 and (.[0] |
      type == "object"
      and (.sha | type == "string" and test("^[0-9a-f]{40}$"))
      and (.truncated | type == "boolean")
      and (.tree | type == "array")
      and all(.tree[];
        (.path | type == "string") and (.type | type == "string")
        and (.mode | type == "string") and (.sha | type == "string" and test("^[0-9a-f]{40}$"))))
  ' >/dev/null 2>&1 \
    || { echo "$r: tree response had an unexpected shape" >&2; return 2; }
  [ "$(printf '%s' "$tree" | jq -sr '.[0].sha')" = "$default_sha" ] \
    || { echo "$r: tree response did not match the captured default-branch SHA" >&2; return 2; }
  truncated=$(printf '%s' "$tree" | jq -sr '.[0].truncated')
  [ "$truncated" = "true" ] && { echo "$r: tree truncated, audit would be partial" >&2; return 2; }
  # `templates/` is audited alongside real workflows. This repo seeds every fleet
  # repo's auto-merge lane from templates/dependabot-auto-merge.yml, and a wrong
  # comment written there reaches the whole fleet before any repo-level scan sees
  # it — which is exactly how `# v6` spread to twelve repos from fleet-template's
  # ci.yml. Audit the seed, not only the crop.
  if ! entries=$(printf '%s' "$tree" | jq -sr '
      .[0].tree[]?
      | select(.type == "blob")
      | select(.path | test("^\\.github/workflows/[^/]+\\.ya?ml$|^templates/[^/]+\\.ya?ml$|(^|/)action\\.ya?ml$"))
      | {path: .path, sha: .sha, mode: .mode}
      | @base64
    ' 2>/dev/null); then
    echo "$r: workflow/action tree entries could not be extracted" >&2
    return 2
  fi
  [ -n "$entries" ] || return 0

  while IFS= read -r encoded_entry; do
    [ -n "$encoded_entry" ] || continue
    if ! entry_json=$(printf '%s' "$encoded_entry" | decode_base64 2>/dev/null); then
      echo "$r: workflow/action tree row did not decode" >&2; rc=2; continue
    fi
    printf '%s' "$entry_json" | jq -e '
      type == "object" and (.path | type == "string" and length > 0)
      and (.sha | type == "string" and test("^[0-9a-f]{40}$"))
      and (.mode | type == "string" and length > 0)
    ' >/dev/null 2>&1 \
      || { echo "$r: workflow/action tree row was malformed" >&2; rc=2; continue; }
    p=$(printf '%s' "$entry_json" | jq -r '.path')
    blob_sha=$(printf '%s' "$entry_json" | jq -r '.sha')
    mode=$(printf '%s' "$entry_json" | jq -r '.mode')
    if [ "$mode" = "120000" ]; then
      echo "$r: symlinked workflow/action manifest is unsupported: $p" >&2
      rc=2
      continue
    fi
    if ! body=$(gh_json "repos/$OWNER/$r/git/blobs/$blob_sha"); then
      echo "$r: cannot read blob for $p" >&2; rc=2; continue
    fi
    if ! decode_api_content "$body" "$r:$p"; then
      rc=2
      continue
    fi
    body=$DECODED_CONTENT
    d=$(printf '%s\n' "$body" | audit_content "$r:$p") || rc=2
    drift="$drift$d"
  done <<EOF
$entries
EOF
  printf '%s' "$drift"
  return $rc
}

audit_snapshot_manifest() {
  local manifest="$1" expected_count="${2:-}" line repo sha seen="" count=0
  local d fail=0 refs_seen

  case "$expected_count" in
    "") ;;
    *[!0-9]*) die "snapshot manifest expected count must be a positive integer" ;;
    *) [ "$expected_count" -gt 0 ] || die "snapshot manifest expected count must be positive" ;;
  esac
  if [ "$manifest" != - ]; then
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] \
      || die "snapshot manifest must be a readable regular file or '-' for stdin"
    exec 9<"$manifest" || die "snapshot manifest could not be opened"
  else
    exec 9<&0 || die "snapshot manifest stdin could not be opened"
  fi

  REPO_ROWS_FILE=$(mktemp /tmp/fleet-pin-snapshot.XXXXXX) \
    || die "cannot create snapshot-manifest validation file"
  chmod 600 "$REPO_ROWS_FILE" 2>/dev/null \
    || die "cannot protect snapshot-manifest validation file"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || die "snapshot manifest contains an empty row"
    case "$line" in
      *$'\t'*) ;;
      *) die "snapshot manifest row must be repo<TAB>40-hex-sha" ;;
    esac
    repo=${line%%$'\t'*}
    sha=${line#*$'\t'}
    case "$sha" in
      *$'\t'*) die "snapshot manifest row contains more than two fields" ;;
    esac
    printf '%s' "$repo" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
      || die "snapshot manifest contains a malformed repository name"
    printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$' \
      || die "snapshot manifest contains a malformed commit SHA for $repo"
    case $'\n'"$seen"$'\n' in
      *$'\n'"$repo"$'\n'*) die "snapshot manifest repeats repository '$repo'" ;;
    esac
    seen="${seen}${seen:+$'\n'}${repo}"
    printf '%s\t%s\n' "$repo" "$sha" >>"$REPO_ROWS_FILE" \
      || die "snapshot manifest row could not be recorded"
    count=$((count + 1))
  done <&9
  exec 9<&-

  [ "$count" -gt 0 ] || die "snapshot manifest is empty — refusing a vacuous pass"
  if [ -n "$expected_count" ] && [ "$count" -ne "$expected_count" ]; then
    die "snapshot manifest covered $count of $expected_count expected repositories"
  fi

  REFS_SEEN_FILE=$(mktemp /tmp/fleet-pin-refs.XXXXXX) \
    || die "cannot create snapshot ref counter"
  printf '%-22s %s\n' "REPO" "PIN DRIFT (empty = conformant)"
  printf '%-22s %s\n' "----" "----"
  while IFS=$'\t' read -r repo sha; do
    if ! d=$(audit_repo "$repo" "" "$sha"); then
      fail=2
      printf '%-22s %s\n' "$repo" "AUDIT FAILED (see stderr)"
      continue
    fi
    if [ -n "$d" ]; then
      [ "$fail" -eq 0 ] && fail=1
      printf '%-22s %s\n' "$repo" "${d# }"
    else
      printf '%-22s %s\n' "$repo" "✓"
    fi
  done <"$REPO_ROWS_FILE"

  refs_seen=$(wc -l < "$REFS_SEEN_FILE" 2>/dev/null | tr -d ' ')
  if [ "${refs_seen:-0}" -eq 0 ]; then
    echo "AUDITED ZERO third-party refs across $count repos — refusing a vacuous pass." >&2
    exit 2
  fi
  echo
  echo "$refs_seen third-party refs classified from $count immutable repository snapshot(s)."
  case "$fail" in
    0) echo "All action pin comments name the tag their SHA carries." ;;
    1) echo "PIN DRIFT FOUND — FLEET.md defines the standard." >&2 ;;
    *) echo "AUDIT INCOMPLETE — treat as drift until it runs clean." >&2 ;;
  esac
  exit "$fail"
}

audit_git_tree() {
  local root="$1" commit="$2" resolved rows_file row metadata path mode type object wanted
  local body d drift="" rc=0 nfiles=0 refs
  [ -d "$root" ] || die "--git-tree needs a repository directory (got '$root')"
  printf '%s' "$commit" | grep -qE '^[0-9a-fA-F]{40}$' \
    || die "--git-tree needs an exact 40-hex commit SHA"

  if ! resolved=$(GIT_NO_REPLACE_OBJECTS=1 "$GIT_BIN" -C "$root" rev-parse --verify "$commit^{commit}" 2>/dev/null); then
    die "cannot resolve immutable commit $commit under $root"
  fi
  resolved=$(printf '%s' "$resolved" | tr 'A-F' 'a-f')
  [ "$resolved" = "$(printf '%s' "$commit" | tr 'A-F' 'a-f')" ] \
    || die "resolved commit $resolved did not equal requested GITHUB_SHA $commit"

  rows_file=$(mktemp /tmp/fleet-pin-tree.XXXXXX) || die "cannot create git-tree enumeration file"
  if ! GIT_NO_REPLACE_OBJECTS=1 "$GIT_BIN" -C "$root" ls-tree -r -z --full-tree "$resolved" >"$rows_file"; then
    rm -f -- "$rows_file"
    die "cannot enumerate workflow/action manifests at $resolved"
  fi
  REFS_SEEN_FILE=$(mktemp /tmp/fleet-pin-refs.XXXXXX) \
    || { rm -f -- "$rows_file"; die "cannot create counter file"; }

  while IFS= read -r -d '' row; do
    case "$row" in
      *$'\t'*) ;;
      *) echo "malformed git-tree row" >&2; rc=2; continue ;;
    esac
    metadata=${row%%$'\t'*}
    path=${row#*$'\t'}
    printf '%s' "$path" | grep -qE '^[^[:cntrl:]]+$' \
      || { echo "workflow/action path contains control characters" >&2; rc=2; continue; }
    IFS=' ' read -r mode type object <<EOF
$metadata
EOF
    [ "$type" = blob ] || continue

    wanted=0
    case "$path" in
      .github/workflows/*.yml|.github/workflows/*.yaml)
        case "${path#.github/workflows/}" in */*) ;; *) wanted=1 ;; esac
        ;;
      templates/*.yml|templates/*.yaml)
        case "${path#templates/}" in */*) ;; *) wanted=1 ;; esac
        ;;
      action.yml|action.yaml|*/action.yml|*/action.yaml) wanted=1 ;;
    esac
    [ "$wanted" -eq 1 ] || continue
    nfiles=$((nfiles + 1))

    if [ "$mode" = 120000 ]; then
      echo "symlinked workflow/action manifest is unsupported: $path" >&2
      rc=2
      continue
    fi
    printf '%s' "$object" | grep -qE '^[0-9a-f]{40}$' \
      || { echo "malformed blob id for $path" >&2; rc=2; continue; }
    if ! body=$(GIT_NO_REPLACE_OBJECTS=1 "$GIT_BIN" -C "$root" show "$resolved:$path" 2>/dev/null); then
      echo "cannot read $path from immutable commit $resolved" >&2
      rc=2
      continue
    fi
    d=$(printf '%s\n' "$body" | audit_content "$path") || rc=2
    drift="$drift$d"
  done <"$rows_file"
  rm -f -- "$rows_file"

  [ "$nfiles" -gt 0 ] || die "no workflow files at $resolved — refusing a vacuous pass"
  refs=$(wc -l < "$REFS_SEEN_FILE" 2>/dev/null | tr -d ' ')
  echo "Scanned $nfiles immutable workflow file(s) at $resolved; classified ${refs:-0} third-party ref(s)."
  [ "$rc" -eq 0 ] || { echo "AUDIT INCOMPLETE — treat as drift until it runs clean." >&2; exit 2; }
  if [ "${refs:-0}" -eq 0 ]; then
    echo "AUDIT INCOMPLETE — immutable gate classified zero third-party refs." >&2
    exit 2
  fi
  if [ -n "$drift" ]; then
    echo "Action pin comments disagree with the tags their SHAs carry:" >&2
    for token in $drift; do echo "  $token" >&2; done
    echo "Fix: name the immutable tag the SHA actually carries (e.g. # v7.0.1, never # v7)." >&2
    exit 1
  fi
  echo "All action pin comments name the tag their SHA carries."
  exit 0
}

if [ "${1:-}" = "--snapshot-manifest" ]; then
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] \
    || die "--snapshot-manifest needs FILE [EXPECTED_COUNT]"
  audit_snapshot_manifest "$2" "${3:-}"
fi

if [ "${1:-}" = "--git-tree" ]; then
  [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "--git-tree needs a repository directory and commit SHA"
  audit_git_tree "$2" "$3"
fi

if [ "${1:-}" = "--latest-release" ]; then
  action="${2:-$OWNER/windwardline}"
  if ! release_tags=$(tagmap "$action"); then
    die "cannot resolve immutable releases for $action"
  fi
  latest_release=$(printf '%s\n' "$release_tags" | awk -F'\t' '$1 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ { print }' | sort -t $'\t' -k1,1V | tail -1)
  [ -n "$latest_release" ] || die "$action publishes no strict vMAJOR.MINOR.PATCH release tag"
  release_tag=${latest_release%%$'\t'*}
  release_sha=${latest_release#*$'\t'}
  printf '%s' "$release_sha" | grep -qE '^[0-9a-fA-F]{40}$' \
    || die "$action latest release resolved to a malformed commit SHA"
  printf '%s\t%s\n' "$release_tag" "$(printf '%s' "$release_sha" | tr 'A-F' 'a-f')"
  exit 0
fi

# Local mode is a developer diagnostic over the working tree. The PR-time gate
# uses --git-tree so uncommitted files and checkout mutations cannot redefine
# the commit under review. Both modes resolve tags through git ls-remote rather
# than the REST limit that stopped the 2026-08-11 fleet sweep.
if [ "${1:-}" = "--local" ]; then
  root="${2:-.}"
  [ -d "$root" ] || die "--local needs a directory (got '$root')"
  if files=$(
    enum_rc=0
    for dir in "$root/.github/workflows" "$root/templates"; do
      if [ -d "$dir" ]; then
        find "$dir" -maxdepth 1 \( -type f -o -type l \) \( -name '*.yml' -o -name '*.yaml' \) -print \
          || enum_rc=1
      fi
    done
    find "$root" \
      -type d \( -name .git -o -name node_modules \) -prune -o \
      \( -type f -o -type l \) \( -name action.yml -o -name action.yaml \) -print \
      || enum_rc=1
    exit "$enum_rc"
  ); then
    :
  else
    die "local workflow/action file enumeration failed under $root"
  fi
  if ! files=$(printf '%s\n' "$files" | LC_ALL=C sort -u); then
    die "local workflow/action file population could not be normalized"
  fi
  # A gate that found no files to read has not passed; it has not run.
  [ -n "$files" ] || die "no workflow files under $root — refusing a vacuous pass"
  REFS_SEEN_FILE=$(mktemp /tmp/fleet-pin-refs.XXXXXX) || die "cannot create counter file"
  drift=""
  lrc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -L "$f" ]; then
      echo "symlinked workflow/action manifest is unsupported: ${f#"$root"/}" >&2
      lrc=2
      continue
    fi
    d=$(audit_content "${f#"$root"/}" < "$f") || lrc=2
    drift="$drift$d"
  done <<< "$files"
  nfiles=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
  refs=$(wc -l < "$REFS_SEEN_FILE" 2>/dev/null | tr -d ' ')
  echo "Scanned $nfiles workflow file(s); classified ${refs:-0} third-party ref(s)."
  [ "$lrc" -eq 0 ] || { echo "AUDIT INCOMPLETE — treat as drift until it runs clean." >&2; exit 2; }
  if [ "${refs:-0}" -eq 0 ]; then
    echo "AUDIT INCOMPLETE — local gate classified zero third-party refs." >&2
    exit 2
  fi
  if [ -n "$drift" ]; then
    echo "Action pin comments disagree with the tags their SHAs carry:" >&2
    for t in $drift; do echo "  $t" >&2; done
    echo "Fix: name the immutable tag the SHA actually carries (e.g. # v7.0.1, never # v7)." >&2
    exit 1
  fi
  echo "All action pin comments name the tag their SHA carries."
  exit 0
fi

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
# name:default-branch pairs. REST keeps the enforcement path on one API surface;
# page until a short response so a future 101st repo cannot disappear at a
# fixed limit. Templates are repositories too and remain in scope.
REPO_ROWS_FILE=$(mktemp /tmp/fleet-pin-repos.XXXXXX) \
  || die "cannot create repository enumeration file"
REFS_SEEN_FILE=$(mktemp /tmp/fleet-pin-refs.XXXXXX) \
  || { rm -f "$REPO_ROWS_FILE"; die "cannot create counter file"; }
page=1
expected_repo_total=0
SEEN_REPOS=""
while :; do
  if ! repo_page=$(gh_json "user/repos?affiliation=owner&per_page=100&page=$page"); then
    die "repo enumeration page $page could not be read"
  fi
  printf '%s' "$repo_page" | jq -se --arg owner "$OWNER" \
    'length == 1 and (.[0] | type == "array" and all(.[]; (.name | type == "string" and length > 0) and (.archived | type == "boolean") and (.default_branch | type == "string" and length > 0) and .owner.login == $owner))' >/dev/null 2>&1 \
    || die "repo enumeration page $page had an unexpected shape"
  page_count=$(printf '%s' "$repo_page" | jq -sr '.[0] | length')
  [ "$page_count" -le 100 ] || die "repo enumeration page $page exceeded the requested page size"
  repo_ids=$(printf '%s' "$repo_page" | jq -sr '.[0][].name') \
    || die "repo enumeration page $page identities could not be extracted"
  observed=0
  while IFS= read -r repo_id; do
    [ -n "$repo_id" ] || continue
    observed=$((observed + 1))
    case $'\n'"$SEEN_REPOS"$'\n' in
      *$'\n'"$repo_id"$'\n'*) die "repo enumeration repeated identity '$repo_id'; pagination made no progress" ;;
    esac
    SEEN_REPOS="${SEEN_REPOS}${SEEN_REPOS:+$'\n'}${repo_id}"
  done <<EOF
$repo_ids
EOF
  [ "$observed" -eq "$page_count" ] \
    || die "repo enumeration page $page emitted $observed of $page_count identities"
  [ "$page" -ne 1 ] || [ "$page_count" -gt 0 ] \
    || die "repo enumeration returned nothing — refusing a vacuous pass"
  live_count=$(printf '%s' "$repo_page" | jq -sr '[.[0][] | select(.archived | not)] | length') \
    || die "repo enumeration page $page live count could not be derived"
  if ! entries=$(printf '%s' "$repo_page" | jq -sr '.[0][] | select(.archived | not) | "\(.name):\(.default_branch)"'); then
    die "repo enumeration page $page rows could not be extracted"
  fi
  emitted_count=$(printf '%s\n' "$entries" | awk 'NF { n++ } END { print n+0 }') \
    || die "repo enumeration page $page rows could not be counted"
  [ "$emitted_count" -eq "$live_count" ] \
    || die "repo enumeration page $page emitted $emitted_count of $live_count live repositories"
  expected_repo_total=$((expected_repo_total + live_count))
  [ -z "$entries" ] || printf '%s\n' "$entries" >> "$REPO_ROWS_FILE" \
    || die "repository enumeration page $page could not be recorded"
  [ "$page_count" -lt 100 ] && break
  page=$((page + 1))
done
if ! ALL=$(LC_ALL=C sort -u "$REPO_ROWS_FILE"); then
  die "repository population could not be normalized"
fi
[ -n "$ALL" ] || die "repo enumeration returned nothing — refusing a vacuous pass"
repo_total=$(printf '%s\n' "$ALL" | awk 'NF { n++ } END { print n+0 }') \
  || die "repository population could not be counted"
[ "$repo_total" -eq "$expected_repo_total" ] \
  || die "repository population normalized to $repo_total of $expected_repo_total rows"

fail=0
printf '%-22s %s\n' "REPO" "PIN DRIFT (empty = conformant)"
printf '%-22s %s\n' "----" "----"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
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
done <<EOF
$ALL
EOF
echo
# Non-vacuity, mirroring the conformance checker's own enumeration guard. A sweep
# that classified nothing must not be able to say "all clean" — every silent-skip
# defect this script has had ended exactly there.
refs_seen=$(wc -l < "$REFS_SEEN_FILE" 2>/dev/null | tr -d ' ')
if [ "${refs_seen:-0}" -eq 0 ]; then
  repo_count=$(printf '%s\n' "$ALL" | awk 'NF { n++ } END { print n+0 }')
  echo "AUDITED ZERO third-party refs across $repo_count repos — refusing a vacuous pass." >&2
  exit 2
fi
echo "$refs_seen third-party refs classified."
case "$fail" in
  0) echo "All action pin comments name the tag their SHA carries." ;;
  1) echo "PIN DRIFT FOUND — FLEET.md defines the standard." >&2 ;;
  *) echo "AUDIT INCOMPLETE — treat as drift until it runs clean." >&2 ;;
esac
exit $fail
