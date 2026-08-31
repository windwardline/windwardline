#!/bin/bash
# Fleet conformance checker — verifies every fleet repo against FLEET.md.
# Requires an authenticated `gh`. Reads remote state only (no local checkouts),
# so it can run from any machine. Exit 0 = fully conformant; 1 = drift found;
# 2 = the audit could not be completed and no drift classification is valid.
#
# The fleet is derived live: every non-archived repo under the owner, templates
# included, minus the exceptions register (FLEET.md). A new repo is in scope the
# moment it exists — inclusion is the default, exemption is the explicit act.
#
# FLEET.md is the standard; this script is its enforcement. Change them together.

set -u

# Ruby derives its default external encoding from the ambient locale. Under a
# scheduled task LANG is unset, so that encoding is US-ASCII and every String#scan
# over a Markdown or YAML file carrying a non-ASCII byte raises
# "invalid byte sequence in US-ASCII". On 2026-08-31 this aborted the whole run at
# craft's SECURITY.md, whose line 8 contains an en-dash arrow, and the failure was
# reported as `craft SECURITY.md deployment URL could not be derived unambiguously`
# — drift attributed to a repo for a fault entirely inside this script. A checker
# whose verdict depends on the caller's environment is not a checker, and one whose
# harness failure reads as the subject refusing is worse than one that stops.
# scripts/bootstrap-repo.sh already pins this for the same reason.
LC_ALL=C.UTF-8
export LC_ALL

OWNER="windwardline"
here=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)
YAML_INSPECTOR="$here/actions_yaml_inspector.rb"
PIN_AUDITOR="$here/verify-action-pins.sh"
command -v ruby >/dev/null 2>&1 || { echo "ERROR: ruby is required for fail-closed YAML inspection." >&2; exit 2; }
[ -r "$YAML_INSPECTOR" ] || { echo "ERROR: YAML inspector is missing: $YAML_INSPECTOR" >&2; exit 2; }
[ -r "$PIN_AUDITOR" ] || { echo "ERROR: action-pin auditor is missing: $PIN_AUDITOR" >&2; exit 2; }
EXEMPT="windwardline venture ops"   # mirrors FLEET.md's exceptions register exactly
PRIVATE_BY_DESIGN="ops venture"     # mirrors FLEET.md's private-by-design register
# Repos the owner has reserved, which therefore lag a fleet-wide change. Named
# and reported every run rather than skipped: a skip list that cannot say why
# is how fleet-template sat exempt while merging eight PRs through no gate.
# Empty this the moment the hold lifts — see FLEET.md's held-repos note.
LANE_HELD="craft"
DEPSCAN_HELD="craft"
# Capability-specific live-header exception. This is not a fleet exemption:
# grown-men-grow remains in every other audit population. The full governing
# table row and this executable copy are asserted byte-for-byte below.
GHOST_MANAGED_EDGE_ROW='| `grown-men-grow` | 2026-08-24 | `https://grownmengrow.com` on Ghost(Pro) | Exact 12-minute `Ghost managed edge` one-step job on push + daily, its step named exactly `Verify the managed Ghost production edge`, calling `windwardline/windwardline/actions/verify-ghost-managed-edge@<current release SHA>` | Fails once all seven headers appear; remove this row and restore `Headers live` |'
if [ -n "${GHOST_MANAGED_EDGE_REPOS_OVERRIDE+x}" ]; then
  [ -n "${FLEET_MD_LOCAL:-}" ] \
    || { echo "ERROR: GHOST_MANAGED_EDGE_REPOS_OVERRIDE is test-only and requires FLEET_MD_LOCAL." >&2; exit 2; }
  if [ "$GHOST_MANAGED_EDGE_REPOS_OVERRIDE" = _NONE_ ]; then
    GHOST_MANAGED_EDGE_ROW=""
  else
    case "$GHOST_MANAGED_EDGE_REPOS_OVERRIDE" in
      ''|*[!A-Za-z0-9._\ -]*) echo "ERROR: GHOST_MANAGED_EDGE_REPOS_OVERRIDE contains an invalid repository name." >&2; exit 2 ;;
    esac
    GHOST_MANAGED_EDGE_ROW="| \`$GHOST_MANAGED_EDGE_REPOS_OVERRIDE\` | 2026-08-24 | \`https://grownmengrow.com\` on Ghost(Pro) | Exact 12-minute \`Ghost managed edge\` one-step job on push + daily, its step named exactly \`Verify the managed Ghost production edge\`, calling \`windwardline/windwardline/actions/verify-ghost-managed-edge@<current release SHA>\` | Fails once all seven headers appear; remove this row and restore \`Headers live\` |"
  fi
fi
GHOST_MANAGED_EDGE_REPOS=$(printf '%s\n' "$GHOST_MANAGED_EDGE_ROW" | awk -F '|' 'NF > 2 { cell=$2; gsub(/[`[:space:]]/, "", cell); print cell }')
GHOST_MANAGED_EDGE_ORIGIN=$(printf '%s\n' "$GHOST_MANAGED_EDGE_ROW" | awk -F '|' 'NF > 4 { cell=$4; gsub(/`/, "", cell); sub(/ on Ghost\(Pro\).*/, "", cell); gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell); print cell }')
FILES="AGENTS.md CLAUDE.md LICENSE SECURITY.md .github/dependabot.yml .github/workflows/ci.yml .github/workflows/security.yml .github/workflows/claude-review.yml"
# Detectable parallel-stack markers (FLEET.md Preferred stack). A recorded
# "Stack exception (owner-approved" line in the repo's AGENTS.md waives them.
STACK_DENY_DEPS="mongodb mongoose firebase firebase-admin @planetscale/database"
ALT_HOST_FILES="netlify.toml fly.toml render.yaml railway.json"
# Exact bytes of templates/claude-review.yml. This is a behavior lock, not a
# floating pointer: changing the caller requires changing its canonical file,
# this expected blob, and every fleet copy in one reviewed rollout.
EXPECTED_REVIEW_CALLER_SHA="d2ef3e401767662eacf7f78cbe7c4f5e71eeeb6d"
# Every REST read goes through this status-preserving boundary. `gh api` returns
# non-zero for both a real 404 and a refusal, and its error text is not a status:
# a 403 body may itself contain "Not Found". Only the HTTP status may classify
# an optional resource as absent. A non-404 error, malformed JSON, or an empty
# required body aborts with 2; none of those is fleet drift.
#
#   api_get:       0 = response, 1 = exact 404, 2 = refusal/malformed transport
#   required_json: sets JSON or exits 2
#   optional_json: sets JSON, returns 1 on exact 404, exits 2 otherwise
die_incomplete() {
  echo "ERROR: $*" >&2
  exit 2
}

api_get() {
  local endpoint="$1" label="$2" raw rc
  API_STATUS=""
  API_BODY=""
  if raw=$(gh api --include "$endpoint" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  API_STATUS=$(printf '%s\n' "$raw" | sed -n '1s/^HTTP\/[^ ]* \([0-9][0-9][0-9]\).*/\1/p')
  [ -n "$API_STATUS" ] || {
    echo "ERROR: $label returned no parseable HTTP status (gh rc=$rc)." >&2
    return 2
  }
  API_BODY=$(printf '%s\n' "$raw" | awk 'body { print } /^[[:space:]]*$/ { body=1 }')
  case "$API_STATUS" in
    404) return 1 ;;
    2??)
      [ "$rc" -eq 0 ] || {
        echo "ERROR: $label returned HTTP $API_STATUS but gh exited $rc." >&2
        return 2
      }
      return 0
      ;;
    *)
      echo "ERROR: $label was refused (HTTP $API_STATUS, gh rc=$rc)." >&2
      return 2
      ;;
  esac
}

required_json() {
  local endpoint="$1" label="$2" rc
  api_get "$endpoint" "$label"; rc=$?
  case "$rc" in
    0) ;;
    1) die_incomplete "$label is absent (HTTP 404); required data was not read." ;;
    *) die_incomplete "$label could not be read." ;;
  esac
  [ -n "$API_BODY" ] || die_incomplete "$label returned an empty required body (HTTP $API_STATUS)."
  printf '%s' "$API_BODY" | jq -se 'length == 1' >/dev/null 2>&1 \
    || die_incomplete "$label returned malformed JSON (HTTP $API_STATUS)."
  JSON=$API_BODY
}

optional_json() {
  local endpoint="$1" label="$2" rc
  api_get "$endpoint" "$label"; rc=$?
  case "$rc" in
    1) JSON=""; return 1 ;;
    2) die_incomplete "$label could not be read." ;;
  esac
  [ -n "$API_BODY" ] || die_incomplete "$label returned an empty body for a present resource."
  printf '%s' "$API_BODY" | jq -se 'length == 1' >/dev/null 2>&1 \
    || die_incomplete "$label returned malformed JSON (HTTP $API_STATUS)."
  JSON=$API_BODY
  return 0
}

decode_base64() {
  if printf '' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

decode_content() {
  local label="$1" encoded compact decoded sentinel canonical
  encoded=$(printf '%s' "$JSON" | jq -er '.content | select(type == "string" and length > 0)' 2>/dev/null) \
    || die_incomplete "$label has no non-empty base64 content field."
  compact=$(printf '%s' "$encoded" | tr -d '[:space:]')
  [ -n "$compact" ] \
    || die_incomplete "$label content had an empty base64 payload."
  [ $(( ${#compact} % 4 )) -eq 0 ] \
    || die_incomplete "$label content had malformed base64 length or padding."
  printf '%s' "$compact" | grep -qE '^[A-Za-z0-9+/]*={0,2}$' \
    || die_incomplete "$label content had malformed base64 characters or padding."
  sentinel=$'\034'
  if decoded=$(
    printf '%s' "$compact" | decode_base64 2>/dev/null || exit 1
    printf '%s' "$sentinel"
  ); then
    CONTENT=${decoded%"$sentinel"}
  else
    die_incomplete "$label content did not decode as base64."
  fi
  [ -n "$CONTENT" ] || die_incomplete "$label decoded to an empty required body."
  canonical=$(printf '%s' "$CONTENT" | base64 | tr -d '[:space:]')
  [ "$canonical" = "$compact" ] \
    || die_incomplete "$label content failed canonical base64 round-trip validation."
}

required_content() {
  required_json "$1" "$2"
  decode_content "$2"
}

optional_content() {
  optional_json "$1" "$2" || return 1
  decode_content "$2"
  return 0
}

json_shape() {
  local label="$1" expression="$2"
  printf '%s' "$JSON" | jq -e "$expression" >/dev/null 2>&1 \
    || die_incomplete "$label had an unexpected response shape."
}

is_sha() {
  printf '%s' "$1" | grep -qE '^[0-9a-f]{40}$'
}

# Pagination is allowed to continue only when every object contributes a new,
# stable identity. A full page repeated forever is not an empty response and
# therefore evades short-page termination unless progress is proved directly.
# Bash 3.2 has no associative arrays, so each pager resets this newline-delimited
# set before its first request.
record_page_ids() {
  local label="$1" ids="$2" expected="$3" id observed=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    observed=$((observed + 1))
    case $'\n'"$PAGER_SEEN"$'\n' in
      *$'\n'"$id"$'\n'*)
        die_incomplete "$label repeated pagination identity '$id'; pagination made no progress."
        ;;
    esac
    PAGER_SEEN="${PAGER_SEEN}${PAGER_SEEN:+$'\n'}$id"
  done <<EOF
$ids
EOF
  [ "$observed" -eq "$expected" ] \
    || die_incomplete "$label emitted $observed of $expected pagination identities."
}

list_named_resources() {
  local endpoint="$1" label="$2" collection="$3" page=1 count total expected_total=-1 names
  local listed=0 rows=""
  PAGER_SEEN=""
  while :; do
    required_json "$endpoint?per_page=100&page=$page" "$label page $page"
    printf '%s' "$JSON" | jq -e --arg collection "$collection" '
      type == "object"
      and (.total_count | type == "number" and . >= 0 and floor == .)
      and (.[$collection] | type == "array")
      and all(.[$collection][]; .name | type == "string" and length > 0)
    ' >/dev/null 2>&1 \
      || die_incomplete "$label page $page had an unexpected response shape."
    count=$(printf '%s' "$JSON" | jq -r --arg collection "$collection" '.[$collection] | length')
    total=$(printf '%s' "$JSON" | jq -r '.total_count')
    [ "$count" -le 100 ] || die_incomplete "$label page $page exceeded the requested page size."
    if [ "$expected_total" -eq -1 ]; then
      expected_total=$total
    elif [ "$total" -ne "$expected_total" ]; then
      die_incomplete "$label total changed across pages ($expected_total to $total)."
    fi
    names=$(printf '%s' "$JSON" | jq -r --arg collection "$collection" '.[$collection][].name') \
      || die_incomplete "$label page $page names could not be extracted."
    record_page_ids "$label page $page" "$names" "$count"
    [ -z "$names" ] || rows="${rows}${rows:+$'\n'}${names}"
    listed=$((listed + count))
    [ "$listed" -le "$expected_total" ] \
      || die_incomplete "$label pagination exceeded total_count: read $listed of $expected_total rows."
    [ "$listed" -eq "$expected_total" ] && break
    [ "$count" -eq 100 ] \
      || die_incomplete "$label pagination ended early: read $listed of $expected_total rows."
    page=$((page + 1))
  done
  LISTED_NAMES=$rows
}

valid_calendar_date() {
  local candidate="$1" parsed
  if parsed=$(LC_ALL=C date -u -d "$candidate" +%F 2>/dev/null); then
    [ "$parsed" = "$candidate" ]
    return
  fi
  if parsed=$(LC_ALL=C date -j -u -f '%Y-%m-%d' "$candidate" '+%Y-%m-%d' 2>/dev/null); then
    [ "$parsed" = "$candidate" ]
    return
  fi
  return 1
}

exact_claude_pointer_blob() {
  local encoded
  encoded=$(printf '%s' "$JSON" | jq -er '.content | select(type == "string")' 2>/dev/null) || return 1
  encoded=$(printf '%s' "$encoded" | tr -d '[:space:]')
  # Exact bytes: "@AGENTS.md\n" (11 bytes, one and only one trailing LF).
  [ "$encoded" = 'QEFHRU5UUy5tZAo=' ]
}

# The accepted-clause rule, shared by both applicability claims.
#
# An affirmation counts only where it BEGINS an operative sentence or
# semicolon-delimited clause AND the clause immediately before it in the same
# block is either absent — the affirmation opens the block — or a complete
# statement of at least four words.
#
# The clause-start anchor alone reads only forward, and that was enough to be
# fooled: `Incorrect. The live global contract at ~/AGENTS.md applies.` begins
# an operative sentence, so it satisfied the anchor while the sentence before it
# withdrew the claim. A rebuttal was lending its own quoted text the force of an
# affirmation. `False; FLEET.md governs this repo.` did the same across a
# semicolon.
#
# This is an accepted-clause rule and deliberately not a list of negation words:
# no vocabulary is enumerated, and a fragment is refused whatever it says, so
# there is no spelling of a verdict label to discover next. A contract's
# operative prose does not put bare fragments in front of its central claims.
#
# Four words, and the bar sits below the fleet's own floor on purpose: the
# shortest clause standing in front of either affirmation across all seventeen
# live contracts is eight words ("Operating contract for AI work in this repo"),
# and two repos open the block with the affirmation itself. A check that reddens
# a correct contract over a wording change gets weakened rather than obeyed.
# `scripts/bootstrap_config_validator.rb` holds a future repo to the identical
# rule; the two are normalized line by line in the same order so they cannot
# drift into agreeing only on the examples they happen to share.
#
# What it does NOT do, stated so the check is not read as more than it examined:
# it does not adjudicate arbitrary contrary prose. A full sentence of
# contradiction followed by the affirmation is accepted, and a paragraph that
# stands alone is read on its own terms whatever precedes it — blank lines,
# headings, and list items all open a new block — because a separate paragraph
# asserting the contract applies is an affirmation however the previous
# paragraph argued. Beyond those forms the contract's correctness rests on
# review, not on this check.
affirms_clause() {
  awk -v affirm="$1" '
    { lines[++n] = $0 }
    END {
      s = ""
      for (i = 1; i <= n; i++) {
        line = lines[i]
        gsub(/[`*_]/, " ", line)
        if (line ~ /^[[:space:]]*$/) { s = s " ."; continue }
        if (line ~ /^ {0,3}[#]{1,6}([[:space:]]|$)/) { s = s " ."; continue }
        # A list item is its own block, so an affirmation opening one opens a
        # block. Strip the marker and mark the boundary: left in place, an
        # ordered marker ends a clause on its own dot, and the claim would be
        # judged against the bare numeral standing in front of it.
        stripped = line; marked = 0
        while (match(stripped, /^ {0,3}([-+]|[0-9]+[.)])[[:space:]]+/)) {
          stripped = substr(stripped, RLENGTH + 1); marked = 1
        }
        if (marked) line = ". " stripped
        s = s " " line
      }
      # A terminator only ends a clause when whitespace follows it, so the dot
      # inside ~/AGENTS.md does not split the very clause being matched. A colon
      # is deliberately NOT a terminator: it introduces what follows rather than
      # closing what precedes, so "an inert example: FLEET.md governs this repo"
      # is one clause that does not begin with the claim. A trailing colon on the
      # claim itself is absorbed by the patterns below instead.
      s = tolower(s) " "
      m = split(s, seg, /[.!?;][[:space:]]/)
      for (k = 1; k <= m; k++) {
        t = seg[k]
        gsub(/^[[:space:]]+/, "", t); gsub(/[[:space:]]+$/, "", t)
        if (t !~ affirm) continue
        p = (k == 1) ? "" : seg[k - 1]
        gsub(/^[[:space:]]+/, "", p); gsub(/[[:space:]]+$/, "", p)
        if (p == "") exit 0
        if (split(p, w, /[[:space:]]+/) >= 4) exit 0
      }
      exit 1
    }
  '
}

affirms_global_contract() {
  affirms_clause '^([-+][[:space:]]+)?(the[[:space:]]+(live[[:space:]]+)?global([[:space:]]+contract)?([[:space:]]+at)?[[:space:]]+)?~/agents[.]md[[:space:]]+(still[[:space:]]+)?applies(:.*)?$'
}

affirms_fleet_contract() {
  affirms_clause '^([-+][[:space:]]+)?fleet[.]md[[:space:]]+governs([[:space:][:punct:]].*)?$'
}

live_markdown() {
  # Emit only operative Markdown. Fenced examples, block quotations, and HTML
  # comments are not policy, so they cannot satisfy a contract or waive a rule.
  # CommonMark indented code is excluded too; accepting only fenced code would
  # let the same inert example become policy by changing its delimiter.
  # A fence closes only with the same marker and at least the opener's length;
  # a shorter or mismatched marker remains literal content inside the fence.
  awk '
    function strip_comments(line, out, start, stop) {
      out=""
      while (1) {
        if (in_comment) {
          stop=index(line, "-->")
          if (!stop) return out
          line=substr(line, stop+3); in_comment=0
          continue
        }
        start=index(line, "<!--")
        if (!start) return out line
        out=out substr(line, 1, start-1)
        line=substr(line, start+4); in_comment=1
      }
    }
    # Container prefixes an OPENER may sit behind, and how wide they were.
    # container_width counts only prefixes that ended in a list marker: bare
    # indentation belongs to the fence itself, not to a container, and the
    # closer allowance is measured from the container content column.
    function container_content(line, candidate, i, pad) {
      candidate=line
      container_width=0
      while (1) {
        pad=0
        for (i=0; i<3 && substr(candidate,1,1)==" "; i++) { candidate=substr(candidate,2); pad++ }
        if (match(candidate, /^[-+*][[:space:]]+/) \
            || match(candidate, /^[0-9]+[.)][[:space:]]+/)) {
          container_width += pad + RLENGTH
          candidate=substr(candidate, RLENGTH+1)
        } else {
          return candidate
        }
      }
    }
    # A CLOSER is not container-aware, and that asymmetry is the whole point.
    # Inside a fenced block every line is literal content, so a list marker
    # cannot introduce anything: a list-prefixed run of backticks is text, not a
    # closing fence. Reusing the opener parser here stripped that marker and
    # closed the block early, releasing the fenced lines after it as operative
    # policy — a fenced citation could then satisfy the applicability it was
    # only illustrating. A closer may be indented and nothing else, by at most
    # three columns past the container content column the fence opened at.
    # Anything further is content, which leaves more text inert rather than
    # less.
    function fence_closer(line, candidate, i, run) {
      candidate=line
      for (i=0; i<fence_indent+3 && substr(candidate,1,1)==" "; i++) candidate=substr(candidate,2)
      if (substr(candidate,1,1)==" ") return 0
      if (substr(candidate,1,1)!=fence_char) return 0
      run=0
      while (substr(candidate,run+1,1)==fence_char) run++
      if (run<fence_len) return 0
      return substr(candidate,run+1) ~ /^[[:space:]]*$/
    }
    function parse_fence(line, candidate, i, ch) {
      candidate=container_content(line)
      ch=substr(candidate,1,1)
      if (ch != "`" && ch != "~") return 0
      parsed_run=0
      while (substr(candidate,parsed_run+1,1)==ch) parsed_run++
      if (parsed_run < 3) return 0
      parsed_char=ch; parsed_rest=substr(candidate,parsed_run+1)
      return 1
    }
    function paragraph_interrupt(line, candidate) {
      candidate=line
      sub(/^ {0,3}/, "", candidate)
      if (candidate ~ /^#{1,6}([[:space:]]|$)/) return 1
      if (candidate ~ /^([-+*]|1[.)])[[:space:]]+/) return 1
      if (candidate ~ /^([*][[:space:]]*){3,}$/ \
          || candidate ~ /^(-[[:space:]]*){3,}$/ \
          || candidate ~ /^(_[[:space:]]*){3,}$/) return 1
      return valid_fence_opener(line)
    }
    function valid_fence_opener(line) {
      if (!parse_fence(line)) return 0
      return parsed_char != "`" || parsed_rest !~ /`/
    }
    {
      line=$0
      if (in_fence) {
        if (fence_closer(line)) { in_fence=0; fence_char=""; fence_len=0; fence_indent=0 }
        print ""; next
      }
      if (in_comment) line=strip_comments(line)
      quote_candidate=container_content(line)
      quoted=substr(quote_candidate,1,1)==">"
      if (in_block_quote) {
        if (line ~ /^[[:space:]]*$/) { in_block_quote=0; print ""; next }
        if (!quoted && !paragraph_interrupt(line)) { print ""; next }
        if (!quoted) in_block_quote=0
      }
      if (quoted) { in_block_quote=1; print ""; next }
      if (in_indented) {
        if (line ~ /^[[:space:]]*$/ || line ~ /^(    |\t)/) { print ""; next }
        in_indented=0
      }
      if (line ~ /^(    |\t)/) { in_indented=1; print ""; next }
      visible=strip_comments(line)
      if (valid_fence_opener(visible)) {
        in_fence=1; fence_char=parsed_char; fence_len=parsed_run
        fence_indent=container_width
        print ""; next
      }
      print visible
    }
    END {
      if (in_fence || in_comment) exit 3
    }
  '
}

derive_production_url() {
  local label="$1" live urls count
  if ! live=$(live_markdown); then
    die_incomplete "$label contains an unclosed fenced block or HTML comment."
  fi
  if ! urls=$(printf '%s\n' "$live" | ruby -e '
      source = STDIN.read
      tokens = source.scan(%r{https://[^\s`<>\(\)"\]]+}).map { |url| url.sub(/[.,;:]+\z/, "") }
      concrete = []
      tokens.each do |url|
        next if url.include?("{") || url.include?("}")
        unless url.match?(%r{\Ahttps://(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}/?\z})
          warn "non-placeholder HTTPS URL is not a literal origin: #{url}"
          exit 2
        end
        concrete << url.sub(%r{/\z}, "")
      end
      puts concrete.uniq
    '); then
    die_incomplete "$label deployment URL could not be derived unambiguously."
  fi
  count=$(printf '%s\n' "$urls" | awk 'NF { n++ } END { print n+0 }') \
    || die_incomplete "$label deployment URL count could not be derived."
  [ "$count" -le 1 ] \
    || die_incomplete "$label names $count concrete HTTPS origins; exactly one production origin is supported."
  DEPLOYMENT_URL=$(printf '%s\n' "$urls" | awk 'NF { print; exit }')
}

has_valid_stack_exception() {
  local line approval_date reason current_date visible
  current_date=$(date -u +%F)
  visible=$(live_markdown) || return 2
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qE '^Stack exception \(owner-approved [0-9]{4}-[0-9]{2}-[0-9]{2}\):[[:space:]]+[^[:space:]]' || continue
    approval_date=${line#Stack exception (owner-approved }
    approval_date=${approval_date%%)*}
    reason=${line#*):}
    printf '%s' "$reason" | grep -q '[^[:space:]]' || continue
    valid_calendar_date "$approval_date" || continue
    [ "$approval_date" \> "$current_date" ] && continue
    return 0
  done <<EOF
$visible
EOF
  return 1
}

# REST replaces the GraphQL-backed repository-list command and keeps the
# checker on one API surface. Page until a
# short response; stopping at a fixed limit would silently drop future repos.
repo_rows=""
page=1
repo_expected=0
PAGER_SEEN=""
while :; do
  required_json "user/repos?affiliation=owner&per_page=100&page=$page" "repository enumeration page $page"
  json_shape "repository enumeration page $page" \
    'type == "array" and all(.[]; (.name | type == "string" and length > 0) and (.archived | type == "boolean") and (.visibility | type == "string" and length > 0) and (.default_branch | type == "string" and length > 0) and (.owner.login | type == "string"))'
  page_count=$(printf '%s' "$JSON" | jq -r 'length')
  [ "$page_count" -le 100 ] \
    || die_incomplete "repository enumeration page $page exceeded the requested page size."
  page_ids=$(printf '%s' "$JSON" | jq -r '.[].name') \
    || die_incomplete "repository enumeration page $page identities could not be extracted."
  record_page_ids "repository enumeration page $page" "$page_ids" "$page_count"
  if [ "$page" -eq 1 ] && [ "$page_count" -eq 0 ]; then
    die_incomplete "repository enumeration returned zero repositories; refusing a vacuous pass."
  fi
  wrong_owner=$(printf '%s' "$JSON" | jq -r --arg owner "$OWNER" '[.[] | select(.owner.login != $owner)] | length')
  [ "$wrong_owner" -eq 0 ] || die_incomplete "repository enumeration included a repository outside $OWNER."
  live_count=$(printf '%s' "$JSON" | jq -r '[.[] | select(.archived | not)] | length') \
    || die_incomplete "repository enumeration page $page live count could not be derived."
  rows=$(printf '%s' "$JSON" | jq -r '.[] | select(.archived | not) | [.name, ((.visibility // "") | ascii_upcase), .default_branch] | @tsv') \
    || die_incomplete "repository enumeration page $page rows could not be extracted."
  emitted_count=$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n+0 }') \
    || die_incomplete "repository enumeration page $page rows could not be counted."
  [ "$emitted_count" -eq "$live_count" ] \
    || die_incomplete "repository enumeration page $page emitted $emitted_count of $live_count live repositories."
  repo_expected=$((repo_expected + live_count))
  [ -z "$rows" ] || repo_rows="$repo_rows
$rows"
  [ "$page_count" -lt 100 ] && break
  page=$((page + 1))
done

if ! ALL=$(ruby -e '
    rows = $stdin.each_line.map(&:strip).reject(&:empty?).map { |line| line.split("\t", -1) }
    abort "malformed repository row" unless rows.all? { |row| row.length == 3 && row.all? { |v| !v.empty? } }
    print rows.map(&:first).uniq.sort.join(" ")
  ' <<EOF
$repo_rows
EOF
); then
  die_incomplete "repository population could not be normalized."
fi
if ! VIS_ROWS=$(ruby -e '
    rows = $stdin.each_line.map(&:strip).reject(&:empty?).map { |line| line.split("\t", -1) }
    abort "malformed visibility row" unless rows.all? { |row| row.length == 3 && row.all? { |v| !v.empty? } }
    puts rows.map { |row| row.take(2) }.uniq.sort.map { |row| row.join(" ") }
  ' <<EOF
$repo_rows
EOF
); then
  die_incomplete "visibility population could not be normalized."
fi
if ! DEFAULT_BRANCH_ROWS=$(ruby -e '
    rows = $stdin.each_line.map(&:strip).reject(&:empty?).map { |line| line.split("\t", -1) }
    abort "malformed default-branch row" unless rows.all? { |row| row.length == 3 && row.all? { |v| !v.empty? } }
    puts rows.map { |row| [row[0], row[2]] }.uniq.sort.map { |row| row.join("\t") }
  ' <<EOF
$repo_rows
EOF
); then
  die_incomplete "default-branch population could not be normalized."
fi
[ -n "${ALL// /}" ] || die_incomplete "non-archived repository population is empty."
repo_actual=$(printf '%s\n' "$ALL" | awk '{ for (i=1; i<=NF; i++) n++ } END { print n+0 }') \
  || die_incomplete "normalized repository population could not be counted."
[ "$repo_actual" -eq "$repo_expected" ] \
  || die_incomplete "repository population normalized to $repo_actual of $repo_expected rows."

# Capture each repository's default branch exactly once and pin every Git data
# read in this audit to that immutable commit. Live control-plane state such as
# rulesets and Actions runs remains live by design; files and trees do not.
REPO_SHA_ROWS=""
SNAPSHOT_CACHE_ROWS=""
capture_repo_snapshot() {
  local repo="$1" cached default_branch encoded_branch
  cached=$(printf '%s\n' "$SNAPSHOT_CACHE_ROWS" | awk -F '\t' -v repo="$repo" '$1 == repo { print $2 }')
  if [ -n "$cached" ]; then
    SNAPSHOT_SHA=$cached
    return 0
  fi

  default_branch=$(printf '%s\n' "$DEFAULT_BRANCH_ROWS" | awk -F '\t' -v repo="$repo" '$1 == repo { print $2 }')
  if [ -z "$default_branch" ]; then
    required_json "repos/$OWNER/$repo" "$repo repository identity for snapshot"
    printf '%s' "$JSON" | jq -e --arg repo "$repo" '
      type == "object" and .name == $repo and .archived == false
      and (.default_branch | type == "string" and length > 0)
    ' >/dev/null 2>&1 \
      || die_incomplete "$repo repository identity for snapshot had an unexpected response shape."
    default_branch=$(printf '%s' "$JSON" | jq -r '.default_branch')
  fi
  encoded_branch=$(printf '%s' "$default_branch" | jq -sRr @uri) \
    || die_incomplete "$repo default branch could not be URL-encoded for snapshotting."
  required_json "repos/$OWNER/$repo/branches/$encoded_branch" "$repo default branch snapshot"
  printf '%s' "$JSON" | jq -e --arg branch "$default_branch" '
    type == "object" and .name == $branch
    and (.commit.sha | type == "string" and test("^[0-9a-f]{40}$"))
  ' >/dev/null 2>&1 \
    || die_incomplete "$repo default branch snapshot had an unexpected response shape."
  SNAPSHOT_SHA=$(printf '%s' "$JSON" | jq -r '.commit.sha')
  SNAPSHOT_CACHE_ROWS="${SNAPSHOT_CACHE_ROWS}${SNAPSHOT_CACHE_ROWS:+$'\n'}${repo}"$'\t'"${SNAPSHOT_SHA}"
}

for r in $ALL; do
  capture_repo_snapshot "$r"
  REPO_SHA_ROWS="${REPO_SHA_ROWS}${REPO_SHA_ROWS:+$'\n'}${r}"$'\t'"${SNAPSHOT_SHA}"
done
snapshot_count=$(printf '%s\n' "$REPO_SHA_ROWS" | awk 'NF { n++ } END { print n+0 }') \
  || die_incomplete "repository snapshot population could not be counted."
[ "$snapshot_count" -eq "$repo_actual" ] \
  || die_incomplete "repository snapshot population covered $snapshot_count of $repo_actual repositories."

REPOS=""
for r in $ALL; do
  skip=0
  for e in $EXEMPT; do [ "$r" = "$e" ] && skip=1; done
  [ "$skip" -eq 0 ] && REPOS="$REPOS $r"
done
if [ -z "${REPOS// /}" ]; then
  die_incomplete "fleet enumeration returned no repos after applying the exceptions register."
fi
echo "Fleet (live from github.com/$OWNER, minus exceptions register):$REPOS"
echo


# The CONVERGE cycle, DERIVED FROM FLEET.md rather than copied into this script.
#
# FLEET.md's working method only reaches an agent through the file the agent
# actually reads: its own repo's AGENTS.md. Every repo therefore carries a
# summary of the cycle, and nothing previously asserted the copy still agreed
# with its source. A literal chain hardcoded here would only create a third
# copy—the curated-population defect this script avoids, reintroduced inside
# its enforcement.
#
# Read from main, not from the working tree. This script's header promises it
# reads remote state only, and the promise has to hold for the ONE input that
# defines pass/fail: a stale clone would otherwise measure the fleet against an
# old cycle and report green, which is precisely the silent failure the whole
# check exists to prevent. Set FLEET_MD_LOCAL=<path> to test a proposed change
# before pushing it; the source is printed either way, because a check whose
# authority is ambiguous is not a check.
capture_repo_snapshot windwardline
WINDWARDLINE_SHA=$SNAPSHOT_SHA
if [ -n "${FLEET_MD_LOCAL:-}" ]; then
  if STANDARD=$(cat "$FLEET_MD_LOCAL" 2>/dev/null); then
    :
  else
    die_incomplete "local FLEET.md test override could not be read: $FLEET_MD_LOCAL"
  fi
  [ -n "$STANDARD" ] || die_incomplete "local FLEET.md test override is empty: $FLEET_MD_LOCAL"
  echo "CONVERGE chain derived from LOCAL TEST OVERRIDE $FLEET_MD_LOCAL (main is what governs)"
else
  required_content "repos/$OWNER/windwardline/contents/FLEET.md?ref=$WINDWARDLINE_SHA" \
    "$OWNER/windwardline FLEET.md at $WINDWARDLINE_SHA"
  STANDARD=$CONTENT
  echo "CONVERGE chain derived from $OWNER/windwardline FLEET.md at $WINDWARDLINE_SHA"
fi

if ! LIVE_STANDARD=$(printf '%s\n' "$STANDARD" | live_markdown); then
  die_incomplete "FLEET.md contains an unclosed fenced block or HTML comment; policy derivation is ambiguous."
fi

# Two numbers come out of the scan, and they must agree: the numbered entries
# the cycle list contains, and the step names successfully derived from them.
# Comparing them is what removes the last hardcoded fact — an earlier version
# required "at least 6 steps", which was itself a claim about FLEET.md copied
# into this script, and it would have sat green while two steps silently
# vanished.
#
# The scan stops at the NEXT HEADING OF ANY DEPTH. Stopping only at "## " ran
# 143 lines past the cycle, through three "### " subsections, so any numbered
# bold line added in those became a phantom cycle step.
#
# Exactly one exact heading is required. Prefix matching accepted
# "### The cycle rewritten", and a second heading silently replaced the first
# parser state. Each entry's leading bold span must also close on that line:
# accepting a wrapped or ambiguous label lets a partial all-caps prefix stand in
# for a step the parser never actually read.
cycle_headings=$(printf '%s\n' "$LIVE_STANDARD" | grep -cE '^### The cycle[[:space:]]*$')
[ "$cycle_headings" -eq 1 ] \
  || die_incomplete "expected exactly one exact '### The cycle' heading; found $cycle_headings."

cycle_scan() {
  awk '
    /^### The cycle[[:space:]]*$/ { inlist=1; next }
    inlist && /^#+ /  { exit }
    inlist && /^[0-9]+\. / {
      line=$0
      entries++
      ordinal=line
      sub(/\..*$/, "", ordinal)
      if (ordinal+0 != entries) {
        print "ERROR entry " entries " is numbered " ordinal
        next
      }
      sub(/^[0-9]+\. /, "", line)
      if (substr(line, 1, 2) != "**") {
        print "ERROR entry " entries " has no leading bold label"
        next
      }
      bold=substr(line, 3)
      close_at=index(bold, "**")
      if (close_at == 0) {
        print "ERROR entry " entries " has a wrapped or unclosed bold label"
        next
      }
      label=substr(bold, 1, close_at-1)
      if (label == "" || label ~ /[*_]/) {
        print "ERROR entry " entries " has an empty or ambiguous bold label"
        next
      }
      # Walk whole tokens inside the bold span. Backticks are formatting, but
      # separators such as / and & are ambiguity, not a reason to accept the
      # prefix before them. A lowercase token starts descriptive prose.
      n=split(label, w, /[[:space:]]+/)
      name=""
      bad=0
      for (i=1; i<=n; i++) {
        t=w[i]
        gsub(/`/, "", t)
        sub(/[.,;:!?]+$/, "", t)
        if (t ~ /^[A-Z][A-Z-]+$/) name = (name=="" ? t : name " " t)
        else if (t ~ /^[a-z]/) break
        else { bad=1; break }
      }
      if (name == "" || bad) {
        print "ERROR entry " entries " has an ambiguous or non-capital label: " label
        next
      }
      print "STEP " name
    }
    END { print "ENTRIES " entries+0 }
  '
}
scan=$(printf '%s\n' "$LIVE_STANDARD" | cycle_scan)
CYCLE_ERRORS=$(printf '%s\n' "$scan" | sed -n 's/^ERROR //p')
[ -z "$CYCLE_ERRORS" ] || {
  printf '%s\n' "$CYCLE_ERRORS" | sed 's/^/ERROR: cycle parse: /' >&2
  die_incomplete "cycle labels or numbering were not parsed unambiguously."
}
CYCLE=$(printf '%s\n' "$scan" | sed -n 's/^STEP //p')
CYCLE_ENTRIES=$(printf '%s\n' "$scan" | sed -n 's/^ENTRIES //p')
CYCLE_STEPS=$(printf '%s\n' "$CYCLE" | grep -c '[A-Z]')
if [ "${CYCLE_ENTRIES:-0}" -lt 2 ]; then
  echo "ERROR: found ${CYCLE_ENTRIES:-0} numbered entries under '### The cycle' in" >&2
  echo "FLEET.md — the scan failed to read the list. Refusing a vacuous pass." >&2
  exit 2
fi
if [ "$CYCLE_STEPS" -ne "$CYCLE_ENTRIES" ]; then
  echo "ERROR: '### The cycle' has $CYCLE_ENTRIES numbered entries but only" >&2
  echo "$CYCLE_STEPS yielded a step name. A step must lead with an ALL-CAPS name" >&2
  echo "(markup ignored): '**FIND.**', '**RE-RANK the sequence**', '**\`REPORT\`**'." >&2
  echo "Derived so far: $(printf '%s' "$CYCLE" | tr '\n' ' ')" >&2
  echo "Refusing to check the fleet against a chain this script only half read." >&2
  exit 2
fi
echo "CONVERGE chain ($CYCLE_STEPS steps): $(printf '%s' "$CYCLE" | tr '\n' ' ')"
echo

# The long-form kickoff prompt also carries the delivery rules. Derive their
# bold labels from the exact governing section; its next heading is the only
# boundary, so a new rule cannot disappear merely because of its wording.
delivery_headings=$(printf '%s\n' "$LIVE_STANDARD" | grep -cE '^### Delivery discipline[[:space:]]*$')
[ "$delivery_headings" -eq 1 ] \
  || die_incomplete "expected exactly one exact '### Delivery discipline' heading; found $delivery_headings."
DELIVERY_RULES=$(printf '%s\n' "$LIVE_STANDARD" | awk '
  /^### Delivery discipline[[:space:]]*$/ { inrules=1; next }
  inrules && /^#+ / { exit }
  inrules && /^- \*\*/ {
    line=substr($0, 5)
    close_at=index(line, "**")
    if (!close_at) { print "ERROR unclosed delivery-rule label"; next }
    label=substr(line, 1, close_at-1)
    plain=label; gsub(/[*`_]/, "", plain)
    print "RULE " plain
  }
')
DELIVERY_ERRORS=$(printf '%s\n' "$DELIVERY_RULES" | sed -n 's/^ERROR //p')
[ -z "$DELIVERY_ERRORS" ] || die_incomplete "delivery-rule labels were not parsed unambiguously: $DELIVERY_ERRORS"
DELIVERY_RULES=$(printf '%s\n' "$DELIVERY_RULES" | sed -n 's/^RULE //p')
DELIVERY_COUNT=$(printf '%s\n' "$DELIVERY_RULES" | awk 'NF { n++ } END { print n+0 }')
[ "$DELIVERY_COUNT" -gt 0 ] || die_incomplete "delivery-rule derivation returned zero rules."
echo "CONVERGE delivery rules derived from FLEET.md: $DELIVERY_COUNT"
echo

# Registers are duplicated in shell variables only because the exemption list
# is needed before FLEET.md's later checks run. Assert those executable copies
# against the governing tables on every invocation so a documentation edit
# cannot silently leave policy behind.
register_rows() {
  local heading="$1" contains="${2:-}" rows
  rows=$(printf '%s\n' "$LIVE_STANDARD" | awk -v heading="$heading" -v contains="$contains" '
    $0 == heading { sections++; insection=1; next }
    insection && /^## / { exit }
    insection && /^\|/ {
      if (contains != "" && index(tolower($0),tolower(contains)) == 0) next
      split($0, columns, "|")
      cell=columns[2]
      gsub(/`/,"",cell)
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",cell)
      split(cell, words, /[[:space:]]+/)
      name=words[1]
      if (name == "Repo" || name ~ /^-+$/ || name !~ /^[A-Za-z0-9._-]+$/) next
      print name
    }
    END { if (sections != 1) exit 3 }
  ') || return
  printf '%s\n' "$rows" | awk 'NF' | LC_ALL=C sort -u
}

register_full_rows() {
  local heading="$1"
  printf '%s\n' "$LIVE_STANDARD" | awk -v heading="$heading" '
    $0 == heading { sections++; insection=1; next }
    insection && /^## / { exit }
    insection && /^\|/ {
      split($0, columns, "|")
      cell=columns[2]
      gsub(/`/, "", cell)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
      if (cell == "Repo" || cell ~ /^-+$/) next
      print $0
    }
    END { if (sections != 1) exit 3 }
  '
}

normalize_words() {
  tr ' ' '\n' | awk 'NF' | LC_ALL=C sort -u
}

doc_exempt=$(register_rows '## Exceptions register') \
  || die_incomplete "FLEET.md Exceptions register was missing or duplicated."
doc_private=$(register_rows '## Repository visibility') \
  || die_incomplete "FLEET.md private-by-design register was missing or duplicated."
doc_held=$(register_rows '## Held repos') \
  || die_incomplete "FLEET.md Held repos register was missing or duplicated."
doc_lane_held=$(register_rows '## Held repos' 'auto-merge lane') \
  || die_incomplete "FLEET.md Held repos register was missing or duplicated."
doc_scan_held=$(register_rows '## Held repos' 'dependency-scan') \
  || die_incomplete "FLEET.md Held repos register was missing or duplicated."
doc_ghost_managed=$(register_rows '## Managed-edge header exception') \
  || die_incomplete "FLEET.md managed-edge header exception register was missing or duplicated."
doc_ghost_managed_rows=$(register_full_rows '## Managed-edge header exception') \
  || die_incomplete "FLEET.md managed-edge header exception register was missing or duplicated."
code_exempt=$(printf '%s\n' "$EXEMPT" | normalize_words)
code_private=$(printf '%s\n' "$PRIVATE_BY_DESIGN" | normalize_words)
code_held=$(printf '%s\n%s\n' "$LANE_HELD" "$DEPSCAN_HELD" | normalize_words)
code_lane_held=$(printf '%s\n' "$LANE_HELD" | normalize_words)
code_scan_held=$(printf '%s\n' "$DEPSCAN_HELD" | normalize_words)
code_ghost_managed=$(printf '%s\n' "$GHOST_MANAGED_EDGE_REPOS" | normalize_words)
[ "$doc_exempt" = "$code_exempt" ] \
  || die_incomplete "FLEET.md Exceptions register does not match checker EXEMPT."
[ "$doc_private" = "$code_private" ] \
  || die_incomplete "FLEET.md private-by-design register does not match checker PRIVATE_BY_DESIGN."
[ "$doc_held" = "$code_held" ] \
  || die_incomplete "FLEET.md Held repos register does not match checker held populations."
[ "$doc_lane_held" = "$code_lane_held" ] \
  || die_incomplete "FLEET.md auto-merge held rows do not match checker LANE_HELD."
[ "$doc_scan_held" = "$code_scan_held" ] \
  || die_incomplete "FLEET.md dependency-scan held rows do not match checker DEPSCAN_HELD."
[ "$doc_ghost_managed" = "$code_ghost_managed" ] \
  || die_incomplete "FLEET.md managed-edge header exception register does not match checker GHOST_MANAGED_EDGE_REPOS."
[ "$doc_ghost_managed_rows" = "$GHOST_MANAGED_EDGE_ROW" ] \
  || die_incomplete "FLEET.md managed-edge header exception full row does not match checker policy."
registered_repos=$(printf '%s\n%s\n%s\n%s\n%s\n' "$EXEMPT" "$PRIVATE_BY_DESIGN" "$LANE_HELD" "$DEPSCAN_HELD" "$GHOST_MANAGED_EDGE_REPOS" \
  | normalize_words)
for registered_repo in $registered_repos; do
  capture_repo_snapshot "$registered_repo"
done
echo "FLEET.md registers match checker populations."
echo

# The thin review caller is security-sensitive control flow, not merely a path.
# Bind every copy to the exact reviewed blob. The expected SHA prevents a
# weakened canonical (for example workflow_dispatch with an empty jobs map)
# from redefining correctness merely by landing first.
if [ -n "${REVIEW_CALLER_SHA_OVERRIDE:-}" ]; then
  CANONICAL_REVIEW_CALLER_SHA=$REVIEW_CALLER_SHA_OVERRIDE
  is_sha "$CANONICAL_REVIEW_CALLER_SHA" \
    || die_incomplete "REVIEW_CALLER_SHA_OVERRIDE is not a 40-hex blob SHA."
  echo "Review caller canonical SHA from TEST OVERRIDE: $CANONICAL_REVIEW_CALLER_SHA"
else
  required_json "repos/$OWNER/windwardline/contents/templates/claude-review.yml?ref=$WINDWARDLINE_SHA" \
    "$OWNER/windwardline review caller template at $WINDWARDLINE_SHA"
  CANONICAL_REVIEW_CALLER_SHA=$(printf '%s' "$JSON" | jq -er '.sha | select(type == "string")' 2>/dev/null) \
    || die_incomplete "canonical review caller template response had no SHA."
  is_sha "$CANONICAL_REVIEW_CALLER_SHA" \
    || die_incomplete "canonical review caller template SHA was malformed."
  echo "Review caller canonical SHA from $OWNER/windwardline at $WINDWARDLINE_SHA: $CANONICAL_REVIEW_CALLER_SHA"
fi
[ "$CANONICAL_REVIEW_CALLER_SHA" = "$EXPECTED_REVIEW_CALLER_SHA" ] \
  || die_incomplete "canonical review caller differs from the checker's reviewed behavior lock."
echo

# Every Secret scan caller must execute the newest immutable fleet-action
# release, not merely any 40-hex ref. Otherwise a hardened weekly auditor can
# coexist indefinitely with an older PR-time gate and the two checks enforce
# different rules while both report green.
if ! pin_release=$(bash "$PIN_AUDITOR" --latest-release "$OWNER/windwardline"); then
  die_incomplete "current fleet-action release could not be resolved."
fi
pin_release_lines=$(printf '%s\n' "$pin_release" | awk 'NF { n++ } END { print n+0 }')
[ "$pin_release_lines" -eq 1 ] \
  || die_incomplete "current fleet-action release response was not exactly one row."
IFS=$'\t' read -r PIN_ACTION_RELEASE_TAG PIN_ACTION_RELEASE_SHA pin_release_extra <<EOF
$pin_release
EOF
[ -z "${pin_release_extra:-}" ] \
  || die_incomplete "current fleet-action release response had extra fields."
printf '%s' "$PIN_ACTION_RELEASE_TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  || die_incomplete "current fleet-action release tag was malformed."
is_sha "$PIN_ACTION_RELEASE_SHA" \
  || die_incomplete "current fleet-action release SHA was malformed."
echo "Current fleet-action release: $PIN_ACTION_RELEASE_TAG ($PIN_ACTION_RELEASE_SHA)"
required_json "repos/$OWNER/windwardline/git/trees/$PIN_ACTION_RELEASE_SHA?recursive=1" \
  "current fleet-action release tree"
json_shape "current fleet-action release tree" '
  type == "object" and .sha == "'"$PIN_ACTION_RELEASE_SHA"'"
  and .truncated == false and (.tree | type == "array")
  and all(.tree[]; (.path | type == "string") and (.type | type == "string"))
'
printf '%s' "$JSON" | jq -e '
  ([.tree[] | select(.type == "blob") | .path]) as $paths |
  all([
    "actions/verify-action-pins/action.yml",
    "scripts/verify-action-pins.sh",
    "scripts/actions_yaml_inspector.rb",
    "actions/verify-live-headers/action.yml",
    "actions/verify-live-headers/verify-live-headers.sh",
    "actions/verify-ghost-managed-edge/action.yml",
    "actions/verify-ghost-managed-edge/verify-ghost-managed-edge.sh"
  ][]; . as $required | ($paths | index($required)) != null)
' >/dev/null 2>&1 \
  || die_incomplete "current fleet-action release does not contain every required action path."
echo

# Bind required-check names to the GitHub Actions App that produced the sampled
# jobs. A matching context name with no integration_id can be reported by any
# source with repository write access, so name membership alone is not a source
# guarantee. Derive the first-party App id live instead of baking in 15368.
required_json "apps/github-actions" "GitHub Actions App identity"
json_shape "GitHub Actions App identity" \
  'type == "object" and .slug == "github-actions" and .owner.login == "github" and (.id | type == "number" and . > 0 and floor == .)'
GITHUB_ACTIONS_APP_ID=$(printf '%s' "$JSON" | jq -r '.id')
echo "Required-check source: github-actions App $GITHUB_ACTIONS_APP_ID"
echo

# The lane is compared to the canonical blob on the governing main branch, not
# to this checkout. A stale or modified local tree must not redefine what the
# fleet is measured against. Tests may inject a literal SHA, but the override is
# validated and printed so it cannot masquerade as the live authority.
if [ -n "${AUTOMERGE_TEMPLATE_SHA_OVERRIDE:-}" ]; then
  CANONICAL_AUTOMERGE_SHA=$AUTOMERGE_TEMPLATE_SHA_OVERRIDE
  is_sha "$CANONICAL_AUTOMERGE_SHA" || die_incomplete "AUTOMERGE_TEMPLATE_SHA_OVERRIDE is not a 40-hex blob SHA."
  echo "Auto-merge template canonical SHA from TEST OVERRIDE: $CANONICAL_AUTOMERGE_SHA"
else
  required_json "repos/$OWNER/windwardline/contents/templates/dependabot-auto-merge.yml?ref=$WINDWARDLINE_SHA" \
    "$OWNER/windwardline auto-merge template at $WINDWARDLINE_SHA"
  CANONICAL_AUTOMERGE_SHA=$(printf '%s' "$JSON" | jq -er '.sha | select(type == "string")' 2>/dev/null) \
    || die_incomplete "canonical auto-merge template response had no SHA."
  is_sha "$CANONICAL_AUTOMERGE_SHA" || die_incomplete "canonical auto-merge template SHA was malformed."
  echo "Auto-merge template canonical SHA from $OWNER/windwardline at $WINDWARDLINE_SHA: $CANONICAL_AUTOMERGE_SHA"
fi
echo

# The scratch-copy helper is a second byte-identity control. Resolve its
# canonical blob from the same captured governing commit as every other fleet
# template; a dirty or stale local checkout cannot redefine the safe copy path.
if [ -n "${SCRATCH_TEMPLATE_SHA_OVERRIDE:-}" ]; then
  CANONICAL_SCRATCH_SHA=$SCRATCH_TEMPLATE_SHA_OVERRIDE
  is_sha "$CANONICAL_SCRATCH_SHA" || die_incomplete "SCRATCH_TEMPLATE_SHA_OVERRIDE is not a 40-hex blob SHA."
  echo "Scratch-clone template canonical SHA from TEST OVERRIDE: $CANONICAL_SCRATCH_SHA"
else
  required_json "repos/$OWNER/windwardline/contents/templates/scratch-clone.sh?ref=$WINDWARDLINE_SHA" \
    "$OWNER/windwardline scratch-clone template at $WINDWARDLINE_SHA"
  CANONICAL_SCRATCH_SHA=$(printf '%s' "$JSON" | jq -er '.sha | select(type == "string")' 2>/dev/null) \
    || die_incomplete "canonical scratch-clone template response had no SHA."
  is_sha "$CANONICAL_SCRATCH_SHA" || die_incomplete "canonical scratch-clone template SHA was malformed."
  echo "Scratch-clone template canonical SHA from $OWNER/windwardline at $WINDWARDLINE_SHA: $CANONICAL_SCRATCH_SHA"
fi
echo

# Find the newest merged pull request using REST only. Closed-PR pages are read
# to exhaustion because `sort=updated` is not `sort=merged`: a comment on an old
# closed PR can move it ahead of the newest merge. A fixed first page would make
# the required-check sample depend on unrelated discussion activity.
latest_merged_sha() {
  local repo="$1" base_branch="$2" encoded_base page=1 count rows merged_at candidate wrong_base page_ids
  encoded_base=$(printf '%s' "$base_branch" | jq -sRr @uri) \
    || die_incomplete "$repo default branch could not be URL-encoded for pull-request sampling."
  LATEST_MERGED_SHA=""
  latest_merged_at=""
  PAGER_SEEN=""
  while :; do
    required_json "repos/$OWNER/$repo/pulls?state=closed&sort=updated&direction=desc&base=$encoded_base&per_page=100&page=$page" \
      "$repo closed pull requests page $page"
    json_shape "$repo closed pull requests page $page" \
      'type == "array" and all(.[]; (.number | type == "number" and . > 0 and floor == .) and ((.merged_at == null) or (.merged_at | type == "string")) and (.head.sha | type == "string" and length > 0) and (.base.ref | type == "string" and length > 0))'
    wrong_base=$(printf '%s' "$JSON" | jq -r --arg base "$base_branch" '[.[] | select(.base.ref != $base)] | length') \
      || die_incomplete "$repo closed pull request base branches could not be validated."
    [ "$wrong_base" -eq 0 ] \
      || die_incomplete "$repo base-filtered pull request response included another base branch."
    count=$(printf '%s' "$JSON" | jq -r 'length')
    [ "$count" -le 100 ] \
      || die_incomplete "$repo closed pull requests page $page exceeded the requested page size."
    page_ids=$(printf '%s' "$JSON" | jq -r '.[].number') \
      || die_incomplete "$repo closed pull request identities could not be extracted."
    record_page_ids "$repo closed pull requests page $page" "$page_ids" "$count"
    [ "$page" -ne 1 ] || [ "$count" -gt 0 ] \
      || die_incomplete "$repo has no closed pull requests; required-check sampling is empty."
    rows=$(printf '%s' "$JSON" | jq -r '.[] | select(.merged_at != null) | [.merged_at, .head.sha] | @tsv') \
      || die_incomplete "$repo merged pull request rows could not be extracted."
    while IFS=$'\t' read -r merged_at candidate; do
      [ -n "$merged_at" ] || continue
      is_sha "$candidate" || die_incomplete "$repo merged pull request had a malformed head SHA."
      if [ -z "$latest_merged_at" ] || [ "$merged_at" \> "$latest_merged_at" ]; then
        latest_merged_at=$merged_at
        LATEST_MERGED_SHA=$candidate
      fi
    done <<EOF
$rows
EOF
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  [ -n "$LATEST_MERGED_SHA" ] \
    || die_incomplete "$repo has no merged pull request; required-check sampling is empty."
}

# Every completed, non-skipped PR job is evidence about a potential gate. A
# failed job is especially important: filtering to successes lets a real red
# job remain non-required forever. The sample must contain at least one
# non-advisory job, and every REST page/job payload must be non-empty and shaped.
audit_required_checks() {
  local repo="$1" contexts="$2" base_branch="$3" sha page count total emitted_count run_total expected_run_total rows run_rows run_id run_path workflow_path job_page job_count job_rows name conclusion run_job_total expected_job_total sampled_job_names="" run_job_names duplicate_job_names required_context audited=0 page_ids pending_jobs
  latest_merged_sha "$repo" "$base_branch"
  sha=$LATEST_MERGED_SHA
  page=1
  run_total=0
  expected_run_total=-1
  run_rows=""
  PAGER_SEEN=""
  while :; do
    required_json "repos/$OWNER/$repo/actions/runs?head_sha=$sha&event=pull_request&status=completed&per_page=100&page=$page" \
      "$repo PR workflow runs page $page for $sha"
    json_shape "$repo PR workflow runs page $page" \
      'type == "object" and (.total_count | type == "number" and . >= 0 and floor == .) and (.workflow_runs | type == "array") and all(.workflow_runs[]; (.id | type == "number" and . > 0 and floor == .) and .event == "pull_request" and .status == "completed" and (.path | type == "string" and length > 0))'
    count=$(printf '%s' "$JSON" | jq -r '.workflow_runs | length')
    total=$(printf '%s' "$JSON" | jq -r '.total_count')
    [ "$count" -le 100 ] \
      || die_incomplete "$repo PR workflow runs page $page exceeded the requested page size."
    page_ids=$(printf '%s' "$JSON" | jq -r '.workflow_runs[].id') \
      || die_incomplete "$repo PR workflow run identities could not be extracted."
    record_page_ids "$repo PR workflow runs page $page" "$page_ids" "$count"
    if [ "$expected_run_total" -eq -1 ]; then
      expected_run_total=$total
    elif [ "$total" -ne "$expected_run_total" ]; then
      die_incomplete "$repo PR workflow run total changed across pages ($expected_run_total to $total)."
    fi
    run_total=$((run_total + count))
    [ "$run_total" -le "$expected_run_total" ] \
      || die_incomplete "$repo PR workflow run pagination exceeded total_count: read $run_total of $expected_run_total runs."
    [ "$page" -ne 1 ] || [ "$total" -gt 0 ] \
      || die_incomplete "$repo required-check sample has no PR-triggered workflow runs."
    rows=$(printf '%s' "$JSON" | jq -r '.workflow_runs[] | [.id, .path] | @tsv') \
      || die_incomplete "$repo PR workflow run rows could not be extracted."
    emitted_count=$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n+0 }') \
      || die_incomplete "$repo PR workflow run rows could not be counted."
    [ "$emitted_count" -eq "$count" ] \
      || die_incomplete "$repo PR workflow run page $page emitted $emitted_count of $count rows."
    [ -z "$rows" ] || run_rows="$run_rows
$rows"
    [ "$run_total" -eq "$expected_run_total" ] && break
    [ "$count" -eq 100 ] \
      || die_incomplete "$repo PR workflow run pagination ended early: read $run_total of $expected_run_total runs."
    page=$((page + 1))
  done
  [ "$run_total" -eq "$expected_run_total" ] \
    || die_incomplete "$repo PR workflow run pagination was incomplete: read $run_total of $expected_run_total runs."
  [ -n "${run_rows// /}" ] || die_incomplete "$repo required-check sample yielded zero workflow run IDs."

  while IFS=$'\t' read -r run_id run_path; do
    [ -n "$run_id" ] || continue
    workflow_path=${run_path%%@*}
    case "$workflow_path" in
      .github/workflows/claude-review.yml|.github/workflows/dependabot-auto-merge.yml) continue ;;
    esac
    job_page=1
    run_job_total=0
    expected_job_total=-1
    run_job_names=""
    PAGER_SEEN=""
    while :; do
      required_json "repos/$OWNER/$repo/actions/runs/$run_id/jobs?per_page=100&page=$job_page" \
        "$repo workflow run $run_id jobs page $job_page"
      json_shape "$repo workflow run $run_id jobs page $job_page" \
        'type == "object" and (.total_count | type == "number" and . >= 0 and floor == .) and (.jobs | type == "array") and all(.jobs[]; (.id | type == "number" and . > 0 and floor == .) and (.name | type == "string" and length > 0) and (.status | type == "string" and length > 0) and ((.conclusion == null) or (.conclusion | type == "string" and length > 0)))'
      job_count=$(printf '%s' "$JSON" | jq -r '.jobs | length')
      total=$(printf '%s' "$JSON" | jq -r '.total_count')
      [ "$job_count" -le 100 ] \
        || die_incomplete "$repo workflow run $run_id jobs page $job_page exceeded the requested page size."
      page_ids=$(printf '%s' "$JSON" | jq -r '.jobs[].id') \
        || die_incomplete "$repo workflow run $run_id job identities could not be extracted."
      record_page_ids "$repo workflow run $run_id jobs page $job_page" "$page_ids" "$job_count"
      if [ "$expected_job_total" -eq -1 ]; then
        expected_job_total=$total
      elif [ "$total" -ne "$expected_job_total" ]; then
        die_incomplete "$repo workflow run $run_id job total changed across pages ($expected_job_total to $total)."
      fi
      run_job_total=$((run_job_total + job_count))
      [ "$run_job_total" -le "$expected_job_total" ] \
        || die_incomplete "$repo workflow run $run_id jobs pagination exceeded total_count: read $run_job_total of $expected_job_total jobs."
      pending_jobs=$(printf '%s' "$JSON" | jq -r '[.jobs[] | select(.status != "completed" or .conclusion == null)] | length') \
        || die_incomplete "$repo workflow run $run_id pending-job count could not be derived."
      [ "$pending_jobs" -eq 0 ] \
        || die_incomplete "$repo workflow run $run_id contains $pending_jobs unfinished job(s); required-check evidence is not final."
      job_rows=$(printf '%s' "$JSON" | jq -r '.jobs[] | [.name, .conclusion] | @tsv') \
        || die_incomplete "$repo workflow run $run_id job rows could not be extracted."
      emitted_count=$(printf '%s\n' "$job_rows" | awk 'NF { n++ } END { print n+0 }') \
        || die_incomplete "$repo workflow run $run_id job rows could not be counted."
      [ "$emitted_count" -eq "$job_count" ] \
        || die_incomplete "$repo workflow run $run_id jobs page $job_page emitted $emitted_count of $job_count rows."
      while IFS=$'\t' read -r name conclusion; do
        [ -n "$name" ] || continue
        run_job_names="$run_job_names
$name"
        sampled_job_names="$sampled_job_names
$name"
        case "$name:$conclusion" in
          *:skipped) continue ;;
        esac
        audited=$((audited + 1))
        printf '%s\n' "$contexts" | grep -Fqx -- "$name" \
          || drift="$drift unrequired-job:${name// /_}"
      done <<EOF
$job_rows
EOF
      [ "$run_job_total" -eq "$expected_job_total" ] && break
      [ "$job_count" -eq 100 ] \
        || die_incomplete "$repo workflow run $run_id jobs pagination ended early: read $run_job_total of $expected_job_total jobs."
      job_page=$((job_page + 1))
    done
    [ "$run_job_total" -gt 0 ] || die_incomplete "$repo workflow run $run_id returned zero jobs."
    [ "$run_job_total" -eq "$expected_job_total" ] \
      || die_incomplete "$repo workflow run $run_id jobs pagination was incomplete: read $run_job_total of $expected_job_total jobs."
    duplicate_job_names=$(printf '%s\n' "$run_job_names" | awk 'NF' | LC_ALL=C sort | uniq -d) \
      || die_incomplete "$repo workflow run $run_id job names could not be checked for duplicates."
    while IFS= read -r duplicate_name; do
      [ -n "$duplicate_name" ] || continue
      drift="$drift duplicate-actions-job:${duplicate_name// /_}"
    done <<EOF
$duplicate_job_names
EOF
  done <<EOF
$run_rows
EOF
  [ "$audited" -gt 0 ] || die_incomplete "$repo required-check sample contained zero auditable jobs."
  if ! sampled_job_names=$(printf '%s\n' "$sampled_job_names" | awk 'NF' | LC_ALL=C sort -u); then
    die_incomplete "$repo sampled job-name population could not be normalized."
  fi
  [ -n "$sampled_job_names" ] || die_incomplete "$repo required-check sample yielded zero job names."
  while IFS= read -r required_context; do
    [ -n "$required_context" ] || continue
    printf '%s\n' "$sampled_job_names" | grep -Fqx -- "$required_context" \
      || drift="$drift required-context-not-actions-job:${required_context// /_}"
  done <<EOF
$contexts
EOF
}

fail=0
production_seen=0
header_probe_seen=0
managed_edge_probe_seen=0
printf '%-22s %s\n' "REPO" "DRIFT (empty = conformant)"
printf '%-22s %s\n' "----" "----"

for r in $REPOS; do
  drift=""
  note=""
  review_caller_sha=""
  security_doc=""
  default_branch=$(printf '%s\n' "$DEFAULT_BRANCH_ROWS" | awk -F '\t' -v repo="$r" '$1 == repo { print $2 }')
  [ -n "$default_branch" ] \
    || die_incomplete "$r default branch was absent from the derived repository population."
  capture_repo_snapshot "$r"
  repo_sha=$SNAPSHOT_SHA
  required_json "repos/$OWNER/$r/git/trees/$repo_sha?recursive=1" "$r default-branch tree"
  json_shape "$r default-branch tree" '
    type == "object" and .sha == "'"$repo_sha"'"
    and (.truncated | type == "boolean") and (.tree | type == "array")
    and all(.tree[]; (.path | type == "string") and (.type | type == "string"))
  '
  [ "$(printf '%s' "$JSON" | jq -r '.truncated')" = false ] \
    || die_incomplete "$r default-branch tree was truncated; repository predicates would be partial."
  repo_tree=$JSON

  # Required files at the audit-wide default-branch snapshot.
  for f in $FILES; do
    if [ "$f" = SECURITY.md ]; then
      if optional_content "repos/$OWNER/$r/contents/$f?ref=$repo_sha" "$r $f at $repo_sha"; then
        security_doc=$CONTENT
        file_present=1
      else
        file_present=0
      fi
    elif optional_json "repos/$OWNER/$r/contents/$f?ref=$repo_sha" "$r $f at $repo_sha"; then
      file_present=1
    else
      file_present=0
    fi
    if [ "$file_present" -eq 1 ]; then
      file_sha=$(printf '%s' "$JSON" | jq -er '.sha | select(type == "string")' 2>/dev/null) \
        || die_incomplete "$r $f response had no SHA."
      is_sha "$file_sha" || die_incomplete "$r $f response had a malformed SHA."
      [ "$f" != ".github/workflows/claude-review.yml" ] || review_caller_sha=$file_sha
    else
      drift="$drift missing:$f"
    fi
  done
  DEPLOYMENT_URL=""
  if [ -n "$security_doc" ]; then
    derive_production_url "$r SECURITY.md" <<EOF
$security_doc
EOF
  fi
  if [ -n "$DEPLOYMENT_URL" ]; then
    production_seen=$((production_seen + 1))
  fi
  if [ -n "$review_caller_sha" ] && [ "$review_caller_sha" != "$CANONICAL_REVIEW_CALLER_SHA" ]; then
    drift="$drift review-caller:differs-from-template"
  fi

  # Read once for the stack-exception waiver near the end of this loop. The
  # CONVERGE citation and gate-enumeration checks moved OUT of this loop — see
  # the all-repos pass below — because this loop skips the exceptions register.
  if optional_content "repos/$OWNER/$r/contents/AGENTS.md?ref=$repo_sha" "$r AGENTS.md at $repo_sha"; then
    agents=$CONTENT
  else
    agents=""
  fi

  # The cross-client pointer is a file format, not merely a required path. Any
  # extra prose creates a second contract and breaks structural parity.
  if optional_content "repos/$OWNER/$r/contents/CLAUDE.md?ref=$repo_sha" "$r CLAUDE.md at $repo_sha"; then
    exact_claude_pointer_blob || drift="$drift CLAUDE.md:not-exact-pointer"
  fi

  # Dependabot auto-merge lane — now every repo, no exceptions. levelflow-cloud
  # was excluded while the lane ran on GITHUB_TOKEN, whose merges fire no
  # on: push workflows and would have left its Supabase deploy silently behind
  # main. The App installation token removed that, so the exception went with
  # it (2026-08-11).
  # Byte-identity, not presence. The same reasoning as the cooldown check
  # below: that a file exists says nothing about what is inside it, and this
  # one decides what merges unattended. Compared by git blob SHA against the
  # canonical templates/ copy at this repo's captured branch SHA, so a stale working
  # tree cannot redefine the lane one sweep re-verifies across the fleet.
  #
  # `gh api --jq` writes the error body to stdout on a 404, so two missing
  # files would otherwise compare equal — hence the 40-hex guard before any
  # comparison is trusted.
  if optional_json "repos/$OWNER/$r/contents/.github/workflows/dependabot-auto-merge.yml?ref=$repo_sha" \
    "$r dependabot-auto-merge.yml"; then
    got=$(printf '%s' "$JSON" | jq -er '.sha | select(type == "string")' 2>/dev/null) \
      || die_incomplete "$r dependabot-auto-merge.yml response had no SHA."
    is_sha "$got" || die_incomplete "$r dependabot-auto-merge.yml SHA was malformed."
  else
    got=""
  fi
  if [ -z "$got" ]; then
    drift="$drift missing:dependabot-auto-merge.yml"
  elif [ "$got" != "$CANONICAL_AUTOMERGE_SHA" ]; then
    # craft is held by the owner (2026-08-17) while unrelated work finishes
    # there, so it lags the template reorder that let the lane mint its token
    # before reading Dependabot metadata. Named, not skipped — and reported on
    # every run, because this file decides what merges unattended and a quiet
    # exception here is the most expensive kind. Closing it is one command:
    #   gh workflow ... see LANE_HELD note in FLEET.md
    case " $LANE_HELD " in
      *" $r "*) note="$note lane-behind-template:held-by-owner-2026-08-17" ;;
      *) drift="$drift auto-merge-lane:differs-from-template" ;;
    esac
  else
    case " $LANE_HELD " in
      *" $r "*) drift="$drift auto-merge-lane:hold-premise-stale" ;;
    esac
  fi

  # Scratch-clone helper — byte-identity, same reasoning as the auto-merge lane.
  # It decides whether ignored caches and local secrets can enter a fan-out.
  # Compare the repository blob at the captured default-branch commit to the
  # governing template blob captured above; no local working-tree byte is
  # trusted.
  if optional_json "repos/$OWNER/$r/contents/scripts/scratch-clone.sh?ref=$repo_sha" \
    "$r scratch-clone.sh at $repo_sha"; then
    scratch_sha=$(printf '%s' "$JSON" | jq -er '.sha | select(type == "string")' 2>/dev/null) \
      || die_incomplete "$r scratch-clone.sh response had no SHA."
    is_sha "$scratch_sha" || die_incomplete "$r scratch-clone.sh SHA was malformed."
  else
    scratch_sha=""
  fi
  if [ -z "$scratch_sha" ]; then
    drift="$drift missing:scratch-clone.sh"
  elif [ "$scratch_sha" != "$CANONICAL_SCRATCH_SHA" ]; then
    drift="$drift scratch-clone:differs-from-template"
  fi

  # Lockfiles are a tree-derived population, not a manifest checkbox. The same
  # exact paths drive Dependabot ecosystem coverage, OSV inputs, and ruleset
  # membership below.
  lockfiles_json=$(printf '%s' "$repo_tree" | jq -c '
    [.tree[] | select(.type == "blob") | .path
     | select(test("(^|/)(package-lock\\.json|pnpm-lock\\.yaml|yarn\\.lock|bun\\.lockb)$"))]
    | unique | sort
  ') || die_incomplete "$r lockfile population could not be derived from its default-branch tree."
  lockfile_count=$(printf '%s' "$lockfiles_json" | jq -r 'length') \
    || die_incomplete "$r lockfile population count could not be derived."
  haslock=0
  [ "$lockfile_count" -eq 0 ] || haslock=1

  # The soak is read, not assumed. Auto-merge without a cooldown is a same-day
  # supply-chain window, so every update lane must carry at least seven days —
  # the file's presence says nothing about the number inside it.
  if optional_content "repos/$OWNER/$r/contents/.github/dependabot.yml?ref=$repo_sha" "$r dependabot.yml at $repo_sha"; then
    db=$CONTENT
    if ! db_analysis=$(printf '%s\n' "$db" | ruby "$YAML_INSPECTOR" dependabot 2>/dev/null); then
      die_incomplete "$r dependabot.yml could not be parsed structurally."
    fi
    printf '%s' "$db_analysis" | jq -e '
      type == "object" and (.lanes | type == "array")
      and all(.lanes[];
        (.index | type == "number" and . > 0 and floor == .)
        and (.ecosystem | type == "string" and length > 0)
        and (.enabled | type == "boolean")
        and (.interval | type == "string" and length > 0)
        and (.paths | type == "array") and all(.paths[]; type == "string" and startswith("/"))
        and (.default_days_present | type == "boolean")
        and (.default_days | type == "string"))
    ' >/dev/null 2>&1 \
      || die_incomplete "$r dependabot.yml inspector returned an unexpected response shape."
    lanes=$(printf '%s' "$db_analysis" | jq -r '.lanes | length') \
      || die_incomplete "$r dependabot.yml lane count could not be derived."
    [ "$lanes" -gt 0 ] || die_incomplete "$r dependabot.yml yielded no live update lanes."
    expected_dependabot_rows=$(printf '%s' "$repo_tree" | jq -r '
      def package_dir:
        split("/") | .[0:-1] | if length == 0 then "/" else "/" + join("/") end;
      ([ ["github-actions", "/"] ] +
       [.tree[] | select(.type == "blob") | .path as $path
        | select($path | test("(^|/)(package-lock\\.json|pnpm-lock\\.yaml|yarn\\.lock|bun\\.lockb)$"))
        | [if ($path | endswith("bun.lockb")) then "bun" else "npm" end,
           ($path | package_dir)]])
      | unique | sort | .[] | @tsv
    ') || die_incomplete "$r expected Dependabot ecosystem population could not be derived."
    actual_dependabot_rows=$(printf '%s' "$db_analysis" | jq -r '
      [.lanes[] | .ecosystem as $ecosystem | .paths[] | [$ecosystem, .]]
      | unique | sort | .[] | @tsv
    ') || die_incomplete "$r actual Dependabot ecosystem population could not be derived."
    [ "$actual_dependabot_rows" = "$expected_dependabot_rows" ] \
      || drift="$drift dependabot:ecosystem-path-population"
    lane_rows=$(printf '%s' "$db_analysis" | jq -r '.lanes[] | @base64') \
      || die_incomplete "$r dependabot.yml lane rows could not be extracted."
    while IFS= read -r encoded_lane; do
      [ -n "$encoded_lane" ] || continue
      lane_json=$(printf '%s' "$encoded_lane" | decode_base64 2>/dev/null) \
        || die_incomplete "$r dependabot.yml lane row could not be decoded."
      lane=$(printf '%s' "$lane_json" | jq -r '.index')
      ecosystem=$(printf '%s' "$lane_json" | jq -r '.ecosystem')
      enabled=$(printf '%s' "$lane_json" | jq -r '.enabled')
      present=$(printf '%s' "$lane_json" | jq -r '.default_days_present')
      days=$(printf '%s' "$lane_json" | jq -r '.default_days')
      if [ "$enabled" != true ]; then
        drift="$drift dependabot:lane${lane}-${ecosystem}-disabled"
      fi
      if [ "$present" != true ]; then
        drift="$drift cooldown:lane${lane}-${ecosystem}-missing"
        continue
      fi
      case "$days" in ''|*[!0-9]*) die_incomplete "$r dependabot lane $lane ($ecosystem) has a malformed default-days value." ;; esac
      [ "$days" -ge 7 ] || drift="$drift cooldown:lane${lane}-${ecosystem}-${days}days"
    done <<EOF
$lane_rows
EOF
  fi

  # A required check that excuses itself from Dependabot PRs reports green
  # without running, because GitHub counts a skipped required check as
  # satisfied. Semgrep CE did exactly that until 2026-08-11 (verified on
  # mimic#35, merged with "Semgrep CE SKIPPED"). Nothing in security.yml may
  # carry that guard again.
  if optional_content "repos/$OWNER/$r/contents/.github/workflows/security.yml?ref=$repo_sha" "$r security.yml at $repo_sha"; then
    sy=$CONTENT
  else
    sy=""
  fi
  if [ -n "$sy" ]; then
    if ! sy_analysis=$(printf '%s' "$sy" | ruby "$YAML_INSPECTOR" security 2>/dev/null); then
      die_incomplete "$r security.yml could not be parsed for control-flow enforcement."
    fi
    required_json "repos/$OWNER/$r/actions/workflows/security.yml" "$r security.yml workflow metadata"
    json_shape "$r security.yml workflow metadata" '
      type == "object" and .path == ".github/workflows/security.yml"
      and (.state | type == "string" and length > 0)
    '
    security_workflow_state=$(printf '%s' "$JSON" | jq -r '.state')
    [ "$security_workflow_state" = active ] \
      || drift="$drift security-workflow:$security_workflow_state"
  else
    sy_analysis='{"root_permissions":{},"root_permissions_valid":false,"pull_request_trigger":false,"push_trigger":false,"daily_crons":[],"weekly_crons":[],"live_jobs":[],"osv":[],"headers":[],"managed_edges":[],"semgrep":[],"secret_scans":[],"actor_guard":false,"secret_scan_jobs":0,"pin_gates":0,"pin_gate_refs":[]}'
  fi
  printf '%s' "$sy_analysis" | jq -e '
    type == "object"
    and (.root_permissions | type == "object") and (.root_permissions_valid | type == "boolean")
    and (.pull_request_trigger | type == "boolean") and (.push_trigger | type == "boolean")
    and (.actor_guard | type == "boolean")
    and (.secret_scan_jobs | type == "number") and (.pin_gates | type == "number")
    and (.pin_gate_refs | type == "array")
    and all(.pin_gate_refs[]; type == "string" and test("^windwardline/windwardline/actions/verify-action-pins@[0-9a-f]{40}$"))
    and (.pin_gates == (.pin_gate_refs | length))
    and (.daily_crons | type == "array") and all(.daily_crons[]; type == "string")
    and (.weekly_crons | type == "array") and all(.weekly_crons[]; type == "string")
    and (.live_jobs | type == "array")
    and (.osv | type == "array") and all(.osv[];
      (.id | type == "string" and length > 0)
      and (.valid | type == "boolean") and (.live | type == "boolean")
      and (.pull_request_live | type == "boolean") and (.push_live | type == "boolean")
      and (.schedule_live | type == "boolean")
      and (.has_if | type == "boolean") and (.condition | type == "string")
      and (.lockfiles | type == "array") and all(.lockfiles[]; type == "string"))
    and (.semgrep | type == "array") and all(.semgrep[];
      (.id | type == "string" and length > 0)
      and (.valid | type == "boolean") and (.pull_request_live | type == "boolean")
      and (.push_live | type == "boolean") and (.weekly_live | type == "boolean"))
    and (.secret_scans | type == "array") and all(.secret_scans[];
      (.id | type == "string" and length > 0)
      and (.valid | type == "boolean") and (.pull_request_live | type == "boolean")
      and (.push_live | type == "boolean") and (.weekly_live | type == "boolean"))
    and (.headers | type == "array")
    and all(.headers[];
      (.id | type == "string" and length > 0)
      and (.valid | type == "boolean") and (.live | type == "boolean")
      and (.push_live | type == "boolean") and (.schedule_live | type == "boolean")
      and (.ref | type == "string")
      and (.url | type == "string"))
    and (.managed_edges | type == "array")
    and all(.managed_edges[];
      (.id | type == "string" and length > 0)
      and (.valid | type == "boolean") and (.live | type == "boolean")
      and (.push_live | type == "boolean") and (.schedule_live | type == "boolean")
      and (.ref | type == "string"))
  ' >/dev/null 2>&1 || die_incomplete "$r security.yml inspector returned an unexpected response shape."
  [ "$(printf '%s' "$sy_analysis" | jq -r '.root_permissions_valid')" = true ] \
    || drift="$drift security-yml:root-permissions-not-canonical"
  if [ "$(printf '%s' "$sy_analysis" | jq -r '.actor_guard')" = true ]; then
    drift="$drift security-yml:skips-dependabot"
  fi
  [ "$(printf '%s' "$sy_analysis" | jq -r '.pull_request_trigger')" = true ] \
    || drift="$drift security-yml:no-pull-request-trigger"
  [ "$(printf '%s' "$sy_analysis" | jq -r '.push_trigger')" = true ] \
    || drift="$drift security-yml:no-push-trigger"
  weekly_security_crons=$(printf '%s' "$sy_analysis" | jq -r '.weekly_crons | length')
  [ "$weekly_security_crons" -eq 1 ] \
    || drift="$drift security-yml:weekly-security-cron-count-$weekly_security_crons"

  semgrep_jobs=$(printf '%s' "$sy_analysis" | jq -r '.semgrep | length')
  if [ "$semgrep_jobs" -ne 1 ]; then
    drift="$drift security-yml:semgrep-job-count-$semgrep_jobs"
  else
    [ "$(printf '%s' "$sy_analysis" | jq -r '.semgrep[0].valid')" = true ] \
      || drift="$drift security-yml:semgrep-not-canonical"
    [ "$(printf '%s' "$sy_analysis" | jq -r '.semgrep[0].pull_request_live')" = true ] \
      || drift="$drift security-yml:semgrep-not-pull-request-live"
    [ "$(printf '%s' "$sy_analysis" | jq -r '.semgrep[0].push_live')" = true ] \
      || drift="$drift security-yml:semgrep-not-push-live"
    [ "$(printf '%s' "$sy_analysis" | jq -r '.semgrep[0].weekly_live')" = true ] \
      || drift="$drift security-yml:semgrep-not-weekly-live"
  fi

  canonical_secret_jobs=$(printf '%s' "$sy_analysis" | jq -r '.secret_scans | length')
  if [ "$canonical_secret_jobs" -eq 1 ]; then
    [ "$(printf '%s' "$sy_analysis" | jq -r '.secret_scans[0].valid')" = true ] \
      || drift="$drift security-yml:secret-scan-not-canonical"
    [ "$(printf '%s' "$sy_analysis" | jq -r '.secret_scans[0].pull_request_live')" = true ] \
      || drift="$drift security-yml:secret-scan-not-pull-request-live"
    [ "$(printf '%s' "$sy_analysis" | jq -r '.secret_scans[0].push_live')" = true ] \
      || drift="$drift security-yml:secret-scan-not-push-live"
    [ "$(printf '%s' "$sy_analysis" | jq -r '.secret_scans[0].weekly_live')" = true ] \
      || drift="$drift security-yml:secret-scan-not-weekly-live"
  fi

  # The action-pin gate rides the already-required Secret scan job as a step, so
  # it contributes no check name and nothing in the ruleset would notice it being
  # dropped. Reuses $sy above — no extra API call. A repo that loses this step
  # keeps merging wrong pin comments until the next weekly sweep catches them.
  secret_scan_jobs=$(printf '%s' "$sy_analysis" | jq -r '.secret_scan_jobs')
  effective_pin_gates=$(printf '%s' "$sy_analysis" | jq -r '.pin_gates')
  expected_pin_ref="$OWNER/windwardline/actions/verify-action-pins@$PIN_ACTION_RELEASE_SHA"
  [ "$secret_scan_jobs" -eq 1 ] || drift="$drift security-yml:secret-scan-job-count-$secret_scan_jobs"
  if [ "$secret_scan_jobs" -ne 1 ] || [ "$effective_pin_gates" -ne 1 ]; then
    drift="$drift security-yml:no-pin-gate"
  else
    actual_pin_ref=$(printf '%s' "$sy_analysis" | jq -r '.pin_gate_refs[0]')
    [ "$actual_pin_ref" = "$expected_pin_ref" ] \
      || drift="$drift security-yml:pin-gate-not-current-$PIN_ACTION_RELEASE_TAG"
  fi

  # Production membership is derived from each live SECURITY.md. The derived
  # population is non-vacuous and each member gets exactly one
  # current-release probe: the canonical seven-header action, except for the one
  # owner-approved Ghost managed-edge row. That row is capability-specific and
  # receives the fixed, self-expiring topology probe instead.
  header_count=$(printf '%s' "$sy_analysis" | jq -r '.headers | length')
  managed_edge_count=$(printf '%s' "$sy_analysis" | jq -r '.managed_edges | length')
  managed_edge_registered=0
  case " $GHOST_MANAGED_EDGE_REPOS " in *" $r "*) managed_edge_registered=1 ;; esac
  if [ "$managed_edge_registered" -eq 1 ]; then
    [ "$header_count" -eq 0 ] \
      || drift="$drift security-yml:headers-live-conflicts-with-managed-edge"
    if [ -z "$DEPLOYMENT_URL" ]; then
      drift="$drift managed-edge:no-production-origin"
    elif [ "$DEPLOYMENT_URL" != "$GHOST_MANAGED_EDGE_ORIGIN" ]; then
      drift="$drift managed-edge:origin-mismatch"
    fi
    if [ "$managed_edge_count" -ne 1 ]; then
      drift="$drift security-yml:ghost-managed-edge-job-count-$managed_edge_count"
    else
      managed_valid=$(printf '%s' "$sy_analysis" | jq -r '.managed_edges[0].valid')
      managed_push_live=$(printf '%s' "$sy_analysis" | jq -r '.managed_edges[0].push_live')
      managed_schedule_live=$(printf '%s' "$sy_analysis" | jq -r '.managed_edges[0].schedule_live')
      managed_ref=$(printf '%s' "$sy_analysis" | jq -r '.managed_edges[0].ref')
      expected_managed_ref="$OWNER/windwardline/actions/verify-ghost-managed-edge@$PIN_ACTION_RELEASE_SHA"
      [ "$managed_valid" = true ] \
        || drift="$drift security-yml:ghost-managed-edge-not-canonical"
      [ "$managed_push_live" = true ] \
        || drift="$drift security-yml:ghost-managed-edge-not-push-live"
      [ "$managed_schedule_live" = true ] \
        || drift="$drift security-yml:ghost-managed-edge-not-daily-live"
      [ "$managed_ref" = "$expected_managed_ref" ] \
        || drift="$drift security-yml:ghost-managed-edge-not-current-$PIN_ACTION_RELEASE_TAG"
      daily_managed_crons=$(printf '%s' "$sy_analysis" | jq -r '.daily_crons | length')
      [ "$daily_managed_crons" -gt 0 ] \
        || drift="$drift security-yml:ghost-managed-edge-no-daily-cron"
      if [ -n "$DEPLOYMENT_URL" ] && [ "$DEPLOYMENT_URL" = "$GHOST_MANAGED_EDGE_ORIGIN" ] \
        && [ "$header_count" -eq 0 ] && [ "$managed_valid" = true ] \
        && [ "$managed_push_live" = true ] && [ "$managed_schedule_live" = true ] \
        && [ "$managed_ref" = "$expected_managed_ref" ] && [ "$daily_managed_crons" -gt 0 ]; then
        managed_edge_probe_seen=$((managed_edge_probe_seen + 1))
      fi
    fi
  elif [ -n "$DEPLOYMENT_URL" ]; then
    [ "$managed_edge_count" -eq 0 ] \
      || drift="$drift security-yml:unregistered-ghost-managed-edge"
    expected_header_ref="$OWNER/windwardline/actions/verify-live-headers@$PIN_ACTION_RELEASE_SHA"
    if [ "$header_count" -ne 1 ]; then
      drift="$drift security-yml:headers-live-job-count-$header_count"
    else
      header_valid=$(printf '%s' "$sy_analysis" | jq -r '.headers[0].valid')
      header_push_live=$(printf '%s' "$sy_analysis" | jq -r '.headers[0].push_live')
      header_schedule_live=$(printf '%s' "$sy_analysis" | jq -r '.headers[0].schedule_live')
      header_ref=$(printf '%s' "$sy_analysis" | jq -r '.headers[0].ref')
      header_url=$(printf '%s' "$sy_analysis" | jq -r '.headers[0].url')
      [ "$header_valid" = true ] \
        || drift="$drift security-yml:headers-live-not-canonical"
      [ "$header_push_live" = true ] \
        || drift="$drift security-yml:headers-live-not-push-live"
      [ "$header_schedule_live" = true ] \
        || drift="$drift security-yml:headers-live-not-daily-live"
      [ "$header_ref" = "$expected_header_ref" ] \
        || drift="$drift security-yml:headers-live-not-current-$PIN_ACTION_RELEASE_TAG"
      [ "$header_url" = "$DEPLOYMENT_URL" ] \
        || drift="$drift security-yml:headers-live-url-mismatch"
      daily_header_crons=$(printf '%s' "$sy_analysis" | jq -r '.daily_crons | length')
      [ "$daily_header_crons" -gt 0 ] \
        || drift="$drift security-yml:headers-live-no-daily-cron"
      if [ "$header_valid" = true ] && [ "$header_push_live" = true ] \
        && [ "$header_schedule_live" = true ] && [ "$header_ref" = "$expected_header_ref" ] \
        && [ "$header_url" = "$DEPLOYMENT_URL" ] && [ "$daily_header_crons" -gt 0 ]; then
        header_probe_seen=$((header_probe_seen + 1))
      fi
    fi
  else
    [ "$header_count" -eq 0 ] \
      || drift="$drift security-yml:headers-live-without-production-origin"
    [ "$managed_edge_count" -eq 0 ] \
      || drift="$drift security-yml:ghost-managed-edge-without-registration-and-origin"
  fi

  # Repo settings
  required_json "repos/$OWNER/$r" "$r repository settings"
  json_shape "$r repository settings" '.allow_auto_merge | type == "boolean"'
  am=$(printf '%s' "$JSON" | jq -r '.allow_auto_merge')
  [ "$am" = "true" ] || drift="$drift auto-merge:off"

  # Seven-header vercel.json, explicit (root, or apps/web in a monorepo)
  vj=""
  if optional_content "repos/$OWNER/$r/contents/vercel.json?ref=$repo_sha" "$r vercel.json at $repo_sha"; then
    vj=$CONTENT
  elif optional_content "repos/$OWNER/$r/contents/apps/web/vercel.json?ref=$repo_sha" "$r apps/web/vercel.json at $repo_sha"; then
    vj=$CONTENT
  fi
  if [ -z "$vj" ]; then
    drift="$drift missing:vercel.json"
  else
    printf '%s' "$vj" | jq -e . >/dev/null 2>&1 \
      || die_incomplete "$r vercel.json decoded to malformed JSON."
    catchall_routes=$(printf '%s' "$vj" | jq -er '[.headers[]? | select(.source == "/(.*)")] | length' 2>/dev/null) \
      || die_incomplete "$r vercel.json catch-all header routes could not be inspected."
    if [ "$catchall_routes" -ne 1 ]; then
      drift="$drift vercel-catchall-routes:$catchall_routes/1"
    else
      hv=$(printf '%s' "$vj" | jq -er '[.headers[] | select(.source == "/(.*)") | .headers[]?.key | select(type == "string")] | map(ascii_downcase) | unique
        | map(select(. == "content-security-policy" or . == "strict-transport-security"
          or . == "x-content-type-options" or . == "referrer-policy" or . == "x-frame-options"
          or . == "permissions-policy" or . == "cross-origin-opener-policy")) | length' 2>/dev/null) \
        || die_incomplete "$r vercel.json catch-all headers could not be inspected."
      [ "$hv" -eq 7 ] || drift="$drift vercel-headers-catchall:$hv/7"
    fi
  fi

  # Package and lockfile predicates are independent. A lockfile commits a
  # dependency graph even when package.json is absent, so it alone is enough to
  # require the OSV context in the branch ruleset.
  haspkg=0
  optional_json "repos/$OWNER/$r/contents/package.json?ref=$repo_sha" "$r package.json at $repo_sha" && haspkg=1
  # Ruleset: exists, requires the scan jobs, enforces linear history, blocks
  # force pushes through the separate non_fast_forward rule, and has no bypass.
  rid_rows=""
  rid_count=0
  ruleset_page=1
  PAGER_SEEN=""
  while :; do
    required_json "repos/$OWNER/$r/rulesets?per_page=100&page=$ruleset_page" "$r ruleset listing page $ruleset_page"
    json_shape "$r ruleset listing page $ruleset_page" \
      'type == "array" and all(.[]; (.name | type == "string") and (.id | type == "number" and . > 0 and floor == .))'
    ruleset_page_count=$(printf '%s' "$JSON" | jq -r 'length') \
      || die_incomplete "$r ruleset listing page $ruleset_page count could not be derived."
    [ "$ruleset_page_count" -le 100 ] \
      || die_incomplete "$r ruleset listing page $ruleset_page exceeded the requested page size."
    ruleset_page_ids=$(printf '%s' "$JSON" | jq -r '.[].id') \
      || die_incomplete "$r ruleset listing page $ruleset_page identities could not be extracted."
    record_page_ids "$r ruleset listing page $ruleset_page" "$ruleset_page_ids" "$ruleset_page_count"
    page_rids=$(printf '%s' "$JSON" | jq -r '.[] | select(.name=="main-requires-green-ci") | .id') \
      || die_incomplete "$r ruleset listing page $ruleset_page rows could not be extracted."
    page_rid_count=$(printf '%s\n' "$page_rids" | awk 'NF { n++ } END { print n+0 }') \
      || die_incomplete "$r ruleset listing page $ruleset_page target rows could not be counted."
    rid_count=$((rid_count + page_rid_count))
    [ -z "$page_rids" ] || rid_rows="$rid_rows
$page_rids"
    [ "$ruleset_page_count" -lt 100 ] && break
    ruleset_page=$((ruleset_page + 1))
  done
  [ "$rid_count" -le 1 ] || die_incomplete "$r has multiple main-requires-green-ci rulesets."
  rid=$(printf '%s\n' "$rid_rows" | awk 'NF { print; exit }')
  ctx=""
  if [ -z "$rid" ]; then
    drift="$drift ruleset:missing"
  else
    required_json "repos/$OWNER/$r/rulesets/$rid" "$r main-requires-green-ci ruleset"
    json_shape "$r main-requires-green-ci ruleset" \
      'type == "object" and (.name | type == "string") and (.enforcement | type == "string") and (.target | type == "string") and (.conditions.ref_name.include | type == "array") and (.conditions.ref_name.exclude | type == "array") and (.rules | type == "array") and (.bypass_actors | type == "array") and all(.rules[]; if .type == "required_status_checks" then (.parameters.strict_required_status_checks_policy | type == "boolean") and (.parameters.required_status_checks | type == "array") and all(.parameters.required_status_checks[]; (.context | type == "string" and length > 0) and ((has("integration_id") | not) or .integration_id == null or (.integration_id | type == "number" and . > 0 and floor == .))) else true end)'
    rs=$JSON
    [ "$(printf '%s' "$rs" | jq -r '.enforcement')" = active ] || drift="$drift ruleset:not-active"
    [ "$(printf '%s' "$rs" | jq -r '.target')" = branch ] || drift="$drift ruleset:not-branch-target"
    printf '%s' "$rs" | jq -e '.conditions.ref_name.include == ["~DEFAULT_BRANCH"] and .conditions.ref_name.exclude == []' >/dev/null 2>&1 \
      || drift="$drift ruleset:not-default-branch-only"
    status_rule_count=$(printf '%s' "$rs" | jq -r '[.rules[] | select(.type=="required_status_checks")] | length')
    [ "$status_rule_count" -le 1 ] || die_incomplete "$r ruleset has multiple required_status_checks rules."
    if [ "$status_rule_count" -eq 0 ]; then
      drift="$drift ruleset-lacks:required-status-checks"
    else
      strict=$(printf '%s' "$rs" | jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy')
      case "$strict" in
        false) ;;
        true) drift="$drift ruleset:strict-on" ;;
        *) die_incomplete "$r ruleset strict_required_status_checks_policy was missing or malformed." ;;
      esac
    fi
    ctx=$(printf '%s' "$rs" | jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]? | .context | select(type == "string" and length > 0)] | unique[]' 2>/dev/null) \
      || die_incomplete "$r required-check contexts were malformed."
    source_rows=$(printf '%s' "$rs" | jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]? | [.context, (if has("integration_id") and .integration_id != null then (.integration_id | tostring) else "any" end)] | @tsv' 2>/dev/null) \
      || die_incomplete "$r required-check sources were malformed."
    while IFS=$'\t' read -r source_context source_id; do
      [ -n "$source_context" ] || continue
      if [ "$source_id" != "$GITHUB_ACTIONS_APP_ID" ]; then
        drift="$drift ruleset-source:${source_context// /_}:$source_id"
      fi
    done <<EOF
$source_rows
EOF
    forbidden_ctx=$(printf '%s' "$rs" | jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context | select(. == "dependabot-auto-merge" or . == "Headers live" or startswith("review / "))')
    if [ -n "$forbidden_ctx" ]; then
      oldifs=$IFS
      IFS=$'\n'
      for forbidden in $forbidden_ctx; do
        drift="$drift ruleset-forbids:${forbidden// /_}"
      done
      IFS=$oldifs
    fi
    for required_context in "Semgrep CE" "Secret scan"; do
      printf '%s\n' "$ctx" | grep -Fqx -- "$required_context" \
        || drift="$drift ruleset-lacks:${required_context// /_}"
    done
    if [ "$haslock" -eq 1 ]; then
      printf '%s\n' "$ctx" | grep -Fqx -- "Dependency scan / osv-scan" \
        || drift="$drift ruleset-lacks:osv-scan"
    fi
    printf '%s' "$rs" | jq -e '[.rules[].type] | contains(["required_linear_history"])' >/dev/null 2>&1 \
      || drift="$drift ruleset-lacks:linear-history"
    printf '%s' "$rs" | jq -e '[.rules[].type] | contains(["non_fast_forward"])' >/dev/null 2>&1 \
      || drift="$drift ruleset-lacks:block-force-pushes"
    nb=$(printf '%s' "$rs" | jq -r '.bypass_actors | length')
    [ "$nb" -eq 0 ] || drift="$drift ruleset:bypass-actors($nb)"
  fi

  # Required-checks completeness: every completed job from PR-triggered
  # workflow runs on the latest merged PR must be a required context. Sampled
  # from workflow runs filtered to event == pull_request — a dispatch or
  # schedule run against the same SHA must not poison the sample (it did, on
  # the 2026-08-04 cadence run's own verification dispatch). The advisory
  # review ("review / *") is excluded by design, and so is
  # "dependabot-auto-merge": it skips on human PRs but succeeds on Dependabot
  # ones, so the sample sees it precisely when the latest merged PR came from
  # Dependabot. Requiring it would be backwards — it is the thing doing the
  # merging, not a gate on it. Skipped jobs are not gate candidates, but their
  # names remain evidence for inverse required-context membership. Failed and
  # cancelled jobs are sampled: either left outside the ruleset is still an
  # ungated failure. Empty PR/run/job populations abort instead of becoming a
  # note, and page totals must reconcile.
  audit_required_checks "$r" "$ctx" "$default_branch"

  # Review-lane secret. The license is the only credential now — API billing
  # was retired 2026-08-08 and the Console key revoked, so a repo carrying
  # ANTHROPIC_API_KEY is drift rather than an accepted alternative.
  list_named_resources "repos/$OWNER/$r/actions/secrets" "$r Actions secret listing" secrets
  sec=$(printf '%s\n' "$LISTED_NAMES" | awk '$0 == "CLAUDE_CODE_OAUTH_TOKEN" { n++ } END { print n+0 }')
  [ "$sec" -ge 1 ] || drift="$drift secret:CLAUDE_CODE_OAUTH_TOKEN"
  stale=$(printf '%s\n' "$LISTED_NAMES" | awk '$0 == "ANTHROPIC_API_KEY" { n++ } END { print n+0 }')
  [ "$stale" -eq 0 ] || drift="$drift secret:stale-ANTHROPIC_API_KEY"

  # The unattended merge lane runs on Dependabot-triggered pull requests, where
  # Actions secrets are deliberately unavailable. Its App credentials therefore
  # live in Dependabot's separate secret namespace; checking only the workflow
  # file or Actions-secret list silently accepts the GITHUB_TOKEN fallback.
  list_named_resources "repos/$OWNER/$r/dependabot/secrets" "$r Dependabot secret listing" secrets
  for dependabot_secret in FLEET_AUTOMERGE_APP_ID FLEET_AUTOMERGE_PRIVATE_KEY; do
    secret_count=$(printf '%s\n' "$LISTED_NAMES" | awk -v name="$dependabot_secret" '$0 == name { n++ } END { print n+0 }')
    [ "$secret_count" -eq 1 ] || drift="$drift dependabot-secret:$dependabot_secret"
  done

  # Dependabot settings, not just the config file (found off on 5 repos by
  # the 2026-08-04 cadence run while dependabot.yml sat present everywhere).
  # Three independent switches: the FILE drives scheduled version PRs, the
  # ALERTS toggle surfaces advisories, and AUTOMATED SECURITY FIXES opens
  # the fix PRs.
  api_get "repos/$OWNER/$r/vulnerability-alerts" "$r vulnerability-alert setting"; alerts_rc=$?
  case "$alerts_rc:$API_STATUS" in
    0:204) ;;
    1:404) drift="$drift dependabot-alerts:off" ;;
    0:*) die_incomplete "$r vulnerability-alert setting returned unexpected HTTP $API_STATUS." ;;
    *) die_incomplete "$r vulnerability-alert setting could not be read." ;;
  esac
  if optional_json "repos/$OWNER/$r/automated-security-fixes" "$r automated-security-fixes setting"; then
    json_shape "$r automated-security-fixes setting" '.enabled | type == "boolean"'
    asf=$(printf '%s' "$JSON" | jq -r '.enabled')
    [ "$asf" = "true" ] || drift="$drift dependabot-security-fixes:off"
  else
    drift="$drift dependabot-security-fixes:off"
  fi

  # App-class extras: lockfile + required scripts + stack-deviation deps
  stackdrift=""
  if [ "$haspkg" -eq 1 ]; then
    [ "$haslock" -eq 1 ] || drift="$drift missing:lockfile"
    required_content "repos/$OWNER/$r/contents/package.json?ref=$repo_sha" "$r package.json at $repo_sha"
    pkg=$CONTENT
    printf '%s' "$pkg" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || die_incomplete "$r package.json decoded to malformed or non-object JSON."
    printf '%s' "$pkg" | jq -e '
      (.scripts | type == "object") and
      (((.scripts.typecheck // null) | type == "string" and test("[^[:space:]]")) or
       ((.scripts.check // null) | type == "string" and test("[^[:space:]]")))' >/dev/null 2>&1 \
      || drift="$drift script:typecheck"
    printf '%s' "$pkg" | jq -e '
      (.scripts | type == "object") and
      ((.scripts.lint // null) | type == "string" and test("[^[:space:]]"))' >/dev/null 2>&1 \
      || drift="$drift script:lint"
    printf '%s' "$pkg" | jq -e '
      (.scripts | type == "object") and
      ((.scripts.test // null) | type == "string" and test("[^[:space:]]"))' >/dev/null 2>&1 \
      || drift="$drift script:test"
    if ! deps=$(printf '%s' "$pkg" | jq -er '
        if (((has("dependencies") | not) or .dependencies == null or (.dependencies | type == "object"))
            and ((has("devDependencies") | not) or .devDependencies == null or (.devDependencies | type == "object")))
        then ((.dependencies // {}) + (.devDependencies // {})) | keys | join("|")
        else error("dependency maps must be objects or null")
        end
      ' 2>/dev/null); then
      die_incomplete "$r package.json dependency maps were malformed."
    fi
    for bad in $STACK_DENY_DEPS; do
      case "|$deps|" in *"|$bad|"*) stackdrift="$stackdrift dep:$bad";; esac
    done
  fi

  # Alternate-hosting artifacts (all repos)
  for f in $ALT_HOST_FILES; do
    optional_json "repos/$OWNER/$r/contents/$f?ref=$repo_sha" "$r $f at $repo_sha" \
      && stackdrift="$stackdrift file:$f"
  done

  # Unrecorded stack deviations fail; a recorded owner approval waives them.
  if [ -n "$stackdrift" ]; then
    # $agents was read once at the top of this loop.
    printf '%s\n' "$agents" | has_valid_stack_exception
    waiver_rc=$?
    case "$waiver_rc" in
      0) ;;
      1) drift="$drift stack-deviation:${stackdrift# }(unrecorded)" ;;
      *) die_incomplete "$r AGENTS.md Markdown structure was incomplete while checking the stack exception." ;;
    esac
  fi

  if [ -n "$drift" ]; then
    fail=1
    printf '%-22s %s\n' "$r" "$drift"
  else
    printf '%-22s %s\n' "$r" "✓$note"
  fi
done

managed_edge_expected=$(printf '%s\n' "$GHOST_MANAGED_EDGE_REPOS" | awk 'NF { n++ } END { print n+0 }')
header_probe_expected=$((production_seen - managed_edge_expected))
if [ "$header_probe_expected" -lt 0 ]; then
  die_incomplete "managed-edge register exceeds the derived production population."
fi
[ "$production_seen" -gt 0 ] \
  || die_incomplete "derived production-origin population is zero; refusing a vacuous header audit."
if [ "$header_probe_seen" -ne "$header_probe_expected" ] \
  || [ "$managed_edge_probe_seen" -ne "$managed_edge_expected" ] \
  || [ $((header_probe_seen + managed_edge_probe_seen)) -ne "$production_seen" ]; then
  printf '%-22s %s\n' "production-register" \
    "canonical-header-probes:$header_probe_seen/$header_probe_expected managed-edge-probes:$managed_edge_probe_seen/$managed_edge_expected total:$((header_probe_seen + managed_edge_probe_seen))/$production_seen"
  fail=1
else
  echo "Production probes conformant — $header_probe_seen canonical header job(s) + $managed_edge_probe_seen managed-edge job(s) = $production_seen derived origin(s)."
fi

# The CONVERGE citation and the gate enumeration, across EVERY non-archived
# repo — the exceptions register does NOT apply here.
#
# Owner ruling 2026-08-20: "the same standard everywhere. No variations, no
# accommodations, no weaknesses." The register exists because some repos have no
# CI, and a repo with no CI cannot carry a ruleset or an auto-merge lane. But the
# WORKING METHOD is not a CI feature. It binds an agent editing a snapshot in
# `ops` exactly as it binds one editing an engine in `levelflow-cloud`, and the
# standards home is the last place the standard should fail to reach. The global
# `~/AGENTS.md` says so directly: the cycle "binds every agent on every project,
# including repos outside the fleet."
#
# Deliberately outside the main loop, in the same shape as the visibility and
# suppression audits below: those cover the exempted repos too, and for the same
# reason — an exemption from one rule is not an exemption from every rule. The
# gate enumeration is derived from each repo's own .github/workflows/, so a repo
# with no workflows passes it trivially rather than needing to be excused.
echo
cite_fail=0
cite_seen=0
for r in $ALL; do
  rowdrift=""
  capture_repo_snapshot "$r"
  universal_sha=$SNAPSHOT_SHA
  #
  # Probed, not just fetched. This pass runs LAST, after roughly forty calls per
  # repo — exactly where the 2026-08-11 secondary rate limit landed — and a
  # throttle there would otherwise report every contract as drift, which is the
  # failure this script already committed in writing never to repeat. Absent and
  # refused are different answers.
  if optional_content "repos/$OWNER/$r/contents/AGENTS.md?ref=$universal_sha" "$r AGENTS.md universal pass"; then
    agents=$CONTENT
  else
    rowdrift="$rowdrift agents-md:absent"
    agents=""
  fi
  if optional_content "repos/$OWNER/$r/contents/CLAUDE.md?ref=$universal_sha" "$r CLAUDE.md universal pass"; then
    exact_claude_pointer_blob || rowdrift="$rowdrift claude-pointer:not-exact"
  else
    rowdrift="$rowdrift claude-pointer:absent"
  fi
  if [ -z "$agents" ]; then
    [ -n "$rowdrift" ] || rowdrift="$rowdrift agents-md:empty"
  else
    if ! live_agents=$(printf '%s\n' "$agents" | live_markdown); then
      die_incomplete "$r AGENTS.md contains an unclosed fenced block or HTML comment."
    fi
    # Closure condition 3: both layers of the standard reach the agent through
    # the file it reads. Examples and comments were removed above, and token
    # boundaries keep a similarly named path from impersonating either source.
    if printf '%s\n' "$live_agents" \
      | grep -qE '(^|[^A-Za-z0-9_./~-])~/AGENTS[.]md($|[^A-Za-z0-9_./~-]|[.]($|[[:space:]`),;:!?]))'; then
      printf '%s\n' "$live_agents" | affirms_global_contract \
        || rowdrift="$rowdrift global-contract-applicability:absent"
    else
      rowdrift="$rowdrift global-contract-citation:absent"
    fi
    if printf '%s\n' "$live_agents" \
      | grep -qE '(^|[^A-Za-z0-9_./~-])FLEET[.]md($|[^A-Za-z0-9_./~-]|[.]($|[[:space:]`),;:!?]))'; then
      printf '%s\n' "$live_agents" | affirms_fleet_contract \
        || rowdrift="$rowdrift converge-applicability:absent"
    else
      rowdrift="$rowdrift converge-citation:absent"
    fi

    # The cycle itself, IN ORDER, against the derivation above. The haystack is
    # consumed as each step matches, so a contract that lists the right steps
    # in the wrong order fails — an out-of-order cycle is a different method,
    # not a cosmetic difference. Case- and whitespace-insensitive: repos state
    # the chain in prose, and this check is about the method surviving the
    # copy, not about punctuation. Normalize to whole tokens before consuming:
    # a substring such as PREFIX must not satisfy the FIX step.
    hay=$(printf '%s' "$live_agents" | tr '[:lower:]' '[:upper:]' \
      | sed 's/[^A-Z0-9-][^A-Z0-9-]*/ /g' | tr '\n' ' ' | tr -s ' ')
    hay=" $hay "
    cyc_missing=""
    while IFS= read -r step; do
      [ -z "$step" ] && continue
      step_normalized=$(printf '%s' "$step" | tr '[:lower:]' '[:upper:]' \
        | sed 's/[^A-Z0-9-][^A-Z0-9-]*/ /g; s/^ *//; s/ *$//' | tr -s ' ')
      rest=${hay#*" $step_normalized "}
      if [ "$rest" = "$hay" ]; then
        cyc_missing="$cyc_missing,${step// /_}"
      else
        hay=" $rest"
      fi
    done <<CYCLE_EOF
$CYCLE
CYCLE_EOF
    [ -n "$cyc_missing" ] && rowdrift="$rowdrift converge-cycle:${cyc_missing#,}"

    # "Enumerate the gates; never count them" (FLEET.md, Delivery discipline),
    # made mechanical. The population is DERIVED from .github/workflows/ rather
    # than from the contract's own list, because a contract cannot be the
    # witness to its own completeness — that is exactly how the omission below
    # survived.
    #
    # The first sweep carrying this check found dependabot-auto-merge.yml named
    # in NO contract in the fleet: the lane that arms unattended merges, with a
    # documented silent degradation to GITHUB_TOKEN (whose pushes fire no
    # workflows), invisible to every agent that reads only its repo's contract.
    # It was found because pathfinder printed a count — "Gates — seven
    # workflows" against eight on disk — and the other repos hid the same
    # omission by not counting. A count is not a checklist.
    #
    # WHAT THIS DOES NOT COVER, stated so the check is not read as more than it
    # is: this population is workflow FILES, so the contract need not name
    # arbitrary step-level gates. The known action-pin step is separately
    # enforced structurally by pin_gate_count above. Any future step-level gate
    # needs an equally explicit declaration and enforcement pathway; guessing
    # from step names would create silent omissions of its own.
    #
    # Probed for the same reason, and then SHAPE-CHECKED. `gh api --jq` writes
    # the error body to stdout on a non-2xx, so an unguarded read of this
    # endpoint splits `{"message":"Not Found",...}` into tokens, matches none of
    # them against *.yml, finds nothing unenumerated, and reports the repo
    # conformant having examined nothing. That is the same hazard the
    # dependabot-template comparison guards with its 40-hex blob-sha check, and
    # a check that cannot tell "no workflows" from "GitHub refused" is worse
    # than no check.
    required_json "repos/$OWNER/$r/git/trees/$universal_sha?recursive=1" "$r default-branch tree for gate enumeration"
    json_shape "$r default-branch tree for gate enumeration" '
      type == "object" and .sha == "'"$universal_sha"'"
      and (.truncated | type == "boolean") and (.tree | type == "array")
      and all(.tree[]; (.path | type == "string") and (.type | type == "string"))
    '
    [ "$(printf '%s' "$JSON" | jq -r '.truncated')" = false ] \
      || die_incomplete "$r default-branch tree was truncated; gate enumeration would be partial."
    wfs=$(printf '%s' "$JSON" | jq -r '
      [.tree[] | select(.type == "blob") | .path
       | select(test("^\\.github/workflows/[^/]+\\.ya?ml$"))
       | sub("^\\.github/workflows/"; "")]
      | if all(.[]; test("^[^/\\r\\n]+\\.ya?ml$")) then .[]
        else error("workflow filename contains a path separator or newline") end
    ') || die_incomplete "$r workflow-name population could not be extracted from the default-branch tree."
    unnamed=""
    oldifs=$IFS
    IFS=$'\n'
    for w in $wfs; do
      IFS=$oldifs
      case "$w" in *.yml|*.yaml) ;; *) IFS=$'\n'; continue ;; esac
      # Anchored, not a substring: a contract naming `deploy-ci.yml` must not
      # satisfy the requirement to name `ci.yml`. A `/` may precede, so
      # `.github/workflows/ci.yml` still counts as naming it.
      esc=$(printf '%s' "$w" | sed 's/[].[^$*\\]/\\&/g')
      printf '%s' "$live_agents" \
        | grep -qE "(^|[^A-Za-z0-9._-])${esc}($|[^A-Za-z0-9._-])" \
        || unnamed="$unnamed,$w"
      IFS=$'\n'
    done
    IFS=$oldifs
    [ -n "$unnamed" ] && rowdrift="$rowdrift gates-unenumerated:${unnamed#,}"
  fi
  cite_seen=$((cite_seen + 1))
  # A row for EVERY repo, pass or fail. The rule this block enforces is
  # "enumerate the gates; never count them" — reporting only failures and
  # closing with "conformant across N repos" would be the same defect one level
  # up: if $ALL silently loses a repo (flipped to template, list truncated,
  # partial enumeration) the number moves and nothing says which repo went
  # unexamined. The count is not the evidence; the names are.
  if [ -n "$rowdrift" ]; then
    printf '%-22s %s\n' "$r" "$rowdrift"
    cite_fail=1
  else
    printf '%-22s %s\n' "$r" "✓"
  fi
done
if [ "$cite_fail" -eq 0 ]; then
  echo "CONVERGE citation and gate enumeration conformant — every repo named above, exceptions register included."
else
  fail=1
fi

# The Levelflow handoff's §6b block is an executable kickoff prompt, not merely
# a narrative mention. It is the sixth home of CONVERGE and therefore checked
# against the same derived chain and delivery labels. The section boundary is
# explicit so matching prose elsewhere in the 1,900-line record cannot satisfy
# an omission in the prompt an agent actually pastes.
echo
capture_repo_snapshot levelflow-cloud
LEVELFLOW_SHA=$SNAPSHOT_SHA
required_content "repos/$OWNER/levelflow-cloud/contents/docs/HANDOFF.md?ref=$LEVELFLOW_SHA" \
  "levelflow-cloud docs/HANDOFF.md at $LEVELFLOW_SHA"
handoff=$CONTENT
handoff_drift=""
handoff_parseable=1
if ! handoff_live=$(printf '%s\n' "$handoff" | live_markdown); then
  handoff_drift="$handoff_drift prompt-fence-structure"
  handoff_parseable=0
  handoff_section=""
else
  handoff_headings=$(printf '%s\n' "$handoff_live" | grep -cE '^### 6b\. CONVERGE([[:space:]]|$)')
  if [ "$handoff_headings" -ne 1 ]; then
    handoff_drift="$handoff_drift prompt-heading-structure"
    handoff_parseable=0
    handoff_section=""
  else
    handoff_start=$(printf '%s\n' "$handoff_live" | awk '/^### 6b\. CONVERGE([[:space:]]|$)/ { print NR }')
    handoff_end=$(printf '%s\n' "$handoff_live" | awk -v start="$handoff_start" 'NR > start && /^### / { print NR; exit }')
    handoff_section=$(printf '%s\n' "$handoff" | awk -v start="$handoff_start" -v stop="$handoff_end" '
      NR > start && (stop == "" || NR < stop) { print }
    ')
    if [ -z "$handoff_section" ]; then
      handoff_drift="$handoff_drift prompt-empty"
      handoff_parseable=0
    fi
  fi
fi

extract_single_fenced_block() {
  # CommonMark fence semantics relevant here: up to three leading spaces, at
  # least three identical backticks/tildes, and a closer with the same marker,
  # at least the opener length, and no trailing info string. Exactly one complete
  # block is accepted; a line such as ```junk inside it is content, not a close.
  awk '
    function strip_comments(line, out, start, stop) {
      out=""
      while (1) {
        if (in_comment) {
          stop=index(line, "-->")
          if (!stop) return out
          line=substr(line, stop+3); in_comment=0
          continue
        }
        start=index(line, "<!--")
        if (!start) return out line
        out=out substr(line, 1, start-1)
        line=substr(line, start+4); in_comment=1
      }
    }
    function parse_fence(line, candidate, i, ch) {
      candidate=line
      for (i=0; i<3 && substr(candidate,1,1)==" "; i++) candidate=substr(candidate,2)
      ch=substr(candidate,1,1)
      if (ch != "`" && ch != "~") return 0
      parsed_run=0
      while (substr(candidate,parsed_run+1,1)==ch) parsed_run++
      if (parsed_run < 3) return 0
      parsed_char=ch; parsed_rest=substr(candidate,parsed_run+1)
      return 1
    }
    {
      line=$0
      if (in_fence) {
        if (parse_fence(line) && parsed_char == fence_char && parsed_run >= fence_len \
            && parsed_rest ~ /^[[:space:]]*$/) {
          in_fence=0; complete++; next
        }
        if (blocks == 1) print line
        next
      }
      visible=strip_comments(line)
      if (parse_fence(visible) && (parsed_char != "`" || parsed_rest !~ /`/)) {
        blocks++; in_fence=1; fence_char=parsed_char; fence_len=parsed_run
      }
    }
    END { if (blocks != 1 || complete != 1 || in_fence || in_comment) exit 3 }
  '
}

handoff_prompt=""
if [ "$handoff_parseable" -eq 1 ] && ! handoff_prompt=$(extract_single_fenced_block <<EOF
$handoff_section
EOF
); then
  handoff_drift="$handoff_drift prompt-fence-structure"
  handoff_prompt=""
fi

# The executable list is structural: one `(N) **LABEL.**` entry per step. A
# narrative mention elsewhere in §6b or later in the prompt cannot replace a
# missing entry while keeping the check green.
handoff_cycle_scan=$(printf '%s\n' "$handoff_prompt" | awk '
  /^\([0-9]+\)[[:space:]]+/ {
    line=$0; entries++
    ordinal=line; sub(/^\(/, "", ordinal); sub(/\).*/, "", ordinal)
    if (ordinal+0 != entries) { print "ERROR numbering"; next }
    sub(/^\([0-9]+\)[[:space:]]+/, "", line)
    if (substr(line,1,2) != "**") { print "ERROR unbolded"; next }
    bold=substr(line,3); close_at=index(bold,"**")
    if (!close_at) { print "ERROR unclosed"; next }
    label=substr(bold,1,close_at-1)
    if (label == "" || label ~ /[*_]/) { print "ERROR ambiguous"; next }
    n=split(label,w,/[[:space:]]+/); name=""; bad=0
    for (i=1;i<=n;i++) {
      t=w[i]; gsub(/`/,"",t); sub(/[.,;:!?]+$/,"",t)
      if (t ~ /^[A-Z][A-Z-]+$/) name=(name=="" ? t : name " " t)
      else if (t ~ /^[a-z]/) break
      else { bad=1; break }
    }
    if (name=="" || bad) { print "ERROR label"; next }
    print "STEP " name
  }
  END { print "ENTRIES " entries+0 }
')
handoff_cycle_errors=$(printf '%s\n' "$handoff_cycle_scan" | grep -c '^ERROR ')
handoff_cycle_entries=$(printf '%s\n' "$handoff_cycle_scan" | sed -n 's/^ENTRIES //p')
handoff_cycle=$(printf '%s\n' "$handoff_cycle_scan" | sed -n 's/^STEP //p')
if [ "$handoff_cycle_errors" -gt 0 ] || [ "$handoff_cycle_entries" -ne "$CYCLE_STEPS" ] \
  || [ "$handoff_cycle" != "$CYCLE" ]; then
  handoff_drift="$handoff_drift cycle:structural"
fi

# Delivery discipline is likewise bound to every bold bullet derived from its
# exact governing section. Free prose containing the same words is not a rule.
handoff_rule_scan=$(printf '%s\n' "$handoff_prompt" | awk '
  /^- \*\*/ {
    line=substr($0,5); close_at=index(line,"**")
    if (!close_at) { print "ERROR"; next }
    label=substr(line,1,close_at-1); gsub(/[*`_]/,"",label)
    print "RULE " label
  }
')
handoff_rule_errors=$(printf '%s\n' "$handoff_rule_scan" | grep -c '^ERROR')
handoff_rules=$(printf '%s\n' "$handoff_rule_scan" | sed -n 's/^RULE //p')
handoff_rule_count=$(printf '%s\n' "$handoff_rules" | awk 'NF { n++ } END { print n+0 }')
if [ "$handoff_rule_errors" -gt 0 ] || [ "$handoff_rule_count" -ne "$DELIVERY_COUNT" ] \
  || [ "$handoff_rules" != "$DELIVERY_RULES" ]; then
  handoff_drift="$handoff_drift delivery:structural"
fi
if [ -n "$handoff_drift" ]; then
  printf '%-22s %s\n' "levelflow-cloud" "HANDOFF.md-6b:$handoff_drift"
  fail=1
else
  printf '%-22s %s\n' "levelflow-cloud" "HANDOFF.md §6b ✓ ($CYCLE_STEPS steps; $DELIVERY_COUNT delivery rules)"
fi

# Repository visibility, in one pass across the whole account. Actions minutes
# are free on public repos and billed on private ones, so visibility is a cost
# control before it is anything else — on 2026-08-16 eight private repos burned
# 90% of the 3,000-minute monthly allowance by day 16, and publishing five of
# them removed the entire overage without touching a workflow. Deliberately
# outside the loop above: it covers the exempted repos too, because two of the
# exemptions are private and this register is what makes that deliberate
# rather than drift.
#
# Checked both directions. A repo that goes private starts costing money; a
# registered-private repo that goes public is an irreversible disclosure. Either
# is drift, and the second is the more expensive mistake.
echo
vis_rows=$VIS_ROWS
if [ -z "${vis_rows// /}" ]; then
  die_incomplete "visibility population is empty."
else
  vis_fail=0
  while read -r name vis; do
    [ -n "$name" ] || continue
    case "$vis" in PUBLIC|PRIVATE|INTERNAL) ;; *) die_incomplete "$name had unknown visibility '$vis'." ;; esac
    registered=0
    for p in $PRIVATE_BY_DESIGN; do [ "$name" = "$p" ] && registered=1; done
    if [ "$registered" -eq 0 ] && [ "$vis" != "PUBLIC" ]; then
      printf '%-22s %s\n' "$name" "visibility:$(printf '%s' "$vis" | tr '[:upper:]' '[:lower:]')-unregistered (every unregistered repo must be public)"
      vis_fail=1
    elif [ "$vis" != "PRIVATE" ] && [ "$registered" -eq 1 ]; then
      printf '%-22s %s\n' "$name" "visibility:registered-private-but-$vis (disclosure regression)"
      vis_fail=1
    fi
  done <<EOF
$vis_rows
EOF
  if [ "$vis_fail" -eq 0 ]; then
    echo "Visibility conformant — every repo public except the private-by-design register."
  else
    fail=1
  fi
fi

# Exemption premises, re-verified every run. An exemption is a claim about a
# repo ("no CI"), and a blanket skip list can never notice when that claim stops
# being true — the skip is exactly what stops anyone looking. fleet-template was
# exempted as "no CI, no ruleset", then grew ci.yml, security.yml and a review
# lane; it ran 61 pull_request builds and merged eight PRs through no gate at
# all, and the checker stayed silent because it had been told not to look.
#
# The standing rule is that every repo WITH CI carries the ruleset and
# auto-merge, no exceptions — so an exempt repo that has CI is not an exception,
# it is an unapplied rule. This pass re-derives the premise from remote state
# instead of trusting the register.
workflow_has_pr_trigger() {
  ruby "$YAML_INSPECTOR" pr-trigger
}

echo
exempt_fail=0
alertprem_fail=0
alertprem_seen=0
for e in $EXEMPT; do
  live_pr_workflows=""
  capture_repo_snapshot "$e"
  default_sha=$SNAPSHOT_SHA

  required_json "repos/$OWNER/$e/git/trees/$default_sha?recursive=1" "$e default-branch tree for exemption premise"
  json_shape "$e default-branch tree for exemption premise" '
    type == "object" and .sha == "'"$default_sha"'"
    and (.truncated | type == "boolean") and (.tree | type == "array")
    and all(.tree[]; (.path | type == "string") and (.type | type == "string"))
  '
  [ "$(printf '%s' "$JSON" | jq -r '.truncated')" = false ] \
    || die_incomplete "$e default-branch tree was truncated; exemption audit would be partial."
  manifest=$(printf '%s' "$JSON" | jq -r '
    [.tree[] | select(.type == "blob") | .path
     | select(test("(^|/)(package\\.json|requirements\\.txt|Gemfile|go\\.mod|Cargo\\.toml|pom\\.xml)$"))]
    | first // empty
  ') || die_incomplete "$e dependency-manifest premise could not be derived from its default-branch tree."
  if [ -n "$manifest" ]; then
    alertprem_seen=$((alertprem_seen + 1))
    api_get "repos/$OWNER/$e/vulnerability-alerts" "$e Dependabot vulnerability-alert premise"
    alert_rc=$?
    case "$alert_rc:$API_STATUS" in
      0:204) ;;
      1:404)
        printf '%-22s %s\n' "$e" "alert-premise-stale: carries $manifest but Dependabot alerts are off"
        alertprem_fail=1
        ;;
      0:*) die_incomplete "$e vulnerability-alert premise returned unexpected HTTP $API_STATUS." ;;
      *) die_incomplete "$e vulnerability-alert premise could not be read." ;;
    esac
  fi
  workflow_rows=$(printf '%s' "$JSON" | jq -r '
    .tree[] | select(.type == "blob") | .path
    | select(test("^\\.github/workflows/[^/]+\\.ya?ml$"))
    | sub("^\\.github/workflows/"; "")
    | @base64
  ') || die_incomplete "$e workflow names could not be extracted from the default-branch tree."
  if [ -n "$workflow_rows" ]; then
    while IFS= read -r encoded_workflow_row; do
      [ -n "$encoded_workflow_row" ] || continue
      workflow_name=$(printf '%s' "$encoded_workflow_row" | decode_base64 2>/dev/null) \
        || die_incomplete "$e workflow-name row could not be decoded."
      printf '%s' "$workflow_name" | grep -qE '^[^/]+\.ya?ml$' \
        || die_incomplete "$e workflow-name row had an unexpected shape."
      encoded_workflow=$(printf '%s' "$workflow_name" | jq -sRr @uri)
      required_content "repos/$OWNER/$e/contents/.github/workflows/$encoded_workflow?ref=$default_sha" \
        "$e $workflow_name current workflow for exemption premise"
      printf '%s\n' "$CONTENT" | workflow_has_pr_trigger
      trigger_rc=$?
      case "$trigger_rc" in
        0) live_pr_workflows="$live_pr_workflows,$workflow_name" ;;
        1) ;;
        *) die_incomplete "$e $workflow_name workflow trigger syntax was ambiguous; could not prove the no-CI exemption." ;;
      esac
    done <<EOF
$workflow_rows
EOF
  fi
  if [ -n "$live_pr_workflows" ]; then
    printf '%-22s %s\n' "$e" "exemption-stale: live pull_request workflow(s) on the default branch: ${live_pr_workflows#,} — ruleset and auto-merge are now required"
    exempt_fail=1
  fi
done
if [ "$exempt_fail" -eq 0 ]; then
  echo "Exemption premises hold — no exempt repo has a current default-branch workflow with a live pull_request trigger."
else
  fail=1
fi

if [ "$alertprem_fail" -eq 0 ]; then
  if [ "$alertprem_seen" -eq 0 ]; then
    echo "Alert premises hold — no exempt repo carries a dependency manifest."
  else
    echo "Alert premises hold — all $alertprem_seen exempt repo(s) with a manifest have alerts on."
  fi
else
  fail=1
fi

# Dependency scans need both halves of the daily guarantee: a live reusable OSV
# job and a daily cron that reaches live work. Testing only for absence of a job
# guard let a weekly-only workflow pass; testing only for a cron let
# fleet-template schedule a green run in which every job skipped. The expected
# scan population is itself non-vacuous.

# The YAML inspector decodes the workflow grammar before applying the proof. A
# live daily subject is the exact reusable OSV job, canonical Headers probe, or
# registered Ghost managed-edge probe; an unrelated checkout/echo cannot mask a
# guarded subject. Runner jobs need executable schedule-live steps, and every
# `needs` edge must lead to the same proof. Quoted/escaped keys, flow sequences,
# and block scalars therefore have their YAML meaning instead of a regex
# approximation.
# craft is held by the owner (2026-08-17) while unrelated work finishes there,
# so its schedule guard is named rather than silently skipped.
echo
scan_fail=0; scan_expected=0; scan_seen=0; scan_held=0
for r in $ALL; do
  scan_hold_registered=0
  scan_hold_observed=0
  case " $DEPSCAN_HELD " in *" $r "*) scan_hold_registered=1 ;; esac
  capture_repo_snapshot "$r"
  scan_sha=$SNAPSHOT_SHA
  required_json "repos/$OWNER/$r/git/trees/$scan_sha?recursive=1" "$r default-branch tree for scan population"
  json_shape "$r default-branch tree for scan population" '
    type == "object" and .sha == "'"$scan_sha"'"
    and (.truncated | type == "boolean") and (.tree | type == "array")
    and all(.tree[]; (.path | type == "string") and (.type | type == "string"))
  '
  [ "$(printf '%s' "$JSON" | jq -r '.truncated')" = false ] \
    || die_incomplete "$r default-branch tree was truncated; scan population would be partial."
  derived_lockfiles=$(printf '%s' "$JSON" | jq -c '
    [.tree[] | select(.type == "blob") | .path
     | select(test("(^|/)(package-lock\\.json|pnpm-lock\\.yaml|yarn\\.lock|bun\\.lockb)$"))]
    | unique | sort
  ') || die_incomplete "$r lockfile population could not be derived from its default-branch tree."
  lockfile_count=$(printf '%s' "$derived_lockfiles" | jq -r 'length') \
    || die_incomplete "$r lockfile population count could not be derived."
  expects_scan=0
  [ "$lockfile_count" -eq 0 ] || expects_scan=1
  if [ "$expects_scan" -eq 1 ]; then
    scan_expected=$((scan_expected + 1))
  fi

  if optional_content "repos/$OWNER/$r/contents/.github/workflows/security.yml?ref=$scan_sha" "$r security.yml scan audit"; then
    body=$CONTENT
  else
    body=""
  fi
  if [ -n "$body" ]; then
    if ! job_analysis=$(printf '%s' "$body" | ruby "$YAML_INSPECTOR" security 2>/dev/null); then
      die_incomplete "$r security.yml could not be parsed for dependency-scan enforcement."
    fi
    required_json "repos/$OWNER/$r/actions/workflows/security.yml" "$r security.yml workflow metadata for daily audit"
    json_shape "$r security.yml workflow metadata for daily audit" '
      type == "object" and .path == ".github/workflows/security.yml"
      and (.state | type == "string" and length > 0)
    '
    security_workflow_state=$(printf '%s' "$JSON" | jq -r '.state')
    if [ "$security_workflow_state" != active ]; then
      printf '%-22s %s\n' "$r" "security-workflow:$security_workflow_state — declared schedules and PR gates cannot run"
      scan_fail=1
    fi
  else
    job_analysis='{"root_permissions":{},"root_permissions_valid":false,"pull_request_trigger":false,"push_trigger":false,"daily_crons":[],"weekly_crons":[],"live_jobs":[],"osv":[],"headers":[],"managed_edges":[],"semgrep":[],"secret_scans":[],"actor_guard":false,"secret_scan_jobs":0,"pin_gates":0,"pin_gate_refs":[]}'
  fi
  printf '%s' "$job_analysis" | jq -e '
    type == "object" and (.daily_crons | type == "array")
    and (.live_jobs | type == "array") and (.osv | type == "array")
    and all(.osv[];
      (.id | type == "string" and length > 0)
      and (.valid | type == "boolean")
      and (.pull_request_live | type == "boolean")
      and (.push_live | type == "boolean")
      and (.schedule_live | type == "boolean")
      and (.has_if | type == "boolean")
      and (.condition | type == "string")
      and (.lockfiles | type == "array") and all(.lockfiles[]; type == "string"))
  ' >/dev/null 2>&1 || die_incomplete "$r security.yml dependency inspector returned an unexpected response shape."
  daily_count=$(printf '%s' "$job_analysis" | jq -r '.daily_crons | length')
  if [ "$daily_count" -gt 0 ]; then
    live_jobs=$(printf '%s' "$job_analysis" | jq -r '.live_jobs | length')
    if [ "$live_jobs" -eq 0 ]; then
      printf '%-22s %s\n' "$r" "daily-cron:no-live-job — scheduled success would examine nothing"
      scan_fail=1
    fi
  fi
  osv_count=$(printf '%s' "$job_analysis" | jq -r '.osv | length')
  if [ "$osv_count" -eq 0 ]; then
    if [ "$expects_scan" -eq 1 ]; then
      printf '%-22s %s\n' "$r" "dependency-scan:missing-live-job (lockfile makes this repo part of the expected population)"
      scan_fail=1
    fi
    if [ "$scan_hold_registered" -eq 1 ]; then
      printf '%-22s %s\n' "$r" "dependency-scan:hold-premise-stale — registered schedule guard is absent"
      scan_fail=1
    fi
    continue
  fi
  if [ "$expects_scan" -eq 0 ]; then
    printf '%-22s %s\n' "$r" "dependency-scan:unexpected-live-job (no derived lockfile exists)"
    scan_fail=1
  elif [ "$osv_count" -ne 1 ]; then
    printf '%-22s %s\n' "$r" "dependency-scan:job-count-$osv_count (expected exactly one for the derived lockfile population)"
    scan_fail=1
  fi
  scan_seen=$((scan_seen + 1))
  if [ "$daily_count" -eq 0 ]; then
    printf '%-22s %s\n' "$r" "dependency-scan:no-daily-cron"
    scan_fail=1
  fi
  osv_rows=$(printf '%s' "$job_analysis" | jq -r '.osv[] | @base64')
  while IFS= read -r encoded_osv; do
    [ -n "$encoded_osv" ] || continue
    osv_row=$(printf '%s' "$encoded_osv" | decode_base64 2>/dev/null) \
      || die_incomplete "$r dependency-scan analysis row did not decode."
    job_id=$(printf '%s' "$osv_row" | jq -r '.id')
    osv_valid=$(printf '%s' "$osv_row" | jq -r 'if .valid then 1 else 0 end')
    pull_request_proof=$(printf '%s' "$osv_row" | jq -r 'if .pull_request_live then 1 else 0 end')
    push_proof=$(printf '%s' "$osv_row" | jq -r 'if .push_live then 1 else 0 end')
    schedule_proof=$(printf '%s' "$osv_row" | jq -r 'if .schedule_live then 1 else 0 end')
    has_if=$(printf '%s' "$osv_row" | jq -r 'if .has_if then 1 else 0 end')
    condition=$(printf '%s' "$osv_row" | jq -r '.condition')
    osv_lockfiles=$(printf '%s' "$osv_row" | jq -c '.lockfiles | unique | sort') \
      || die_incomplete "$r dependency-scan lockfile inputs could not be normalized."
    if [ "$osv_lockfiles" != "$derived_lockfiles" ]; then
      printf '%-22s %s\n' "$r" "dependency-scan:$job_id:lockfile-population-mismatch"
      scan_fail=1
    fi
    if [ "$osv_valid" -ne 1 ]; then
      printf '%-22s %s\n' "$r" "dependency-scan:$job_id:not-canonical — runtime controls can bypass the reusable scanner"
      scan_fail=1
    fi
    if [ "$pull_request_proof" -ne 1 ]; then
      printf '%-22s %s\n' "$r" "dependency-scan:$job_id:not-pull-request-live — its needs chain or trigger skips PRs"
      scan_fail=1
    fi
    if [ "$push_proof" -ne 1 ]; then
      printf '%-22s %s\n' "$r" "dependency-scan:$job_id:not-push-live — its needs chain or trigger skips pushes"
      scan_fail=1
    fi
    if [ "$has_if" -eq 1 ]; then
      case "$condition" in
        *github.event.schedule*)
          case " $DEPSCAN_HELD " in
            *" $r "*)
              printf '%-22s %s\n' "$r" "dependency-scan:$job_id schedule guard held by owner 2026-08-17"
              scan_held=$((scan_held + 1))
              scan_hold_observed=1
              continue
              ;;
            *)
              printf '%-22s %s\n' "$r" "dependency-scan:$job_id carries a schedule guard — the daily advisory check can skip"
              scan_fail=1
              continue
              ;;
          esac
          ;;
        *)
          printf '%-22s %s\n' "$r" "dependency-scan:$job_id carries a job-level condition — daily execution is not guaranteed"
          scan_fail=1
          continue
          ;;
      esac
    fi
    if [ "$schedule_proof" -ne 1 ]; then
      printf '%-22s %s\n' "$r" "dependency-scan:$job_id:not-daily-live — its needs chain cannot execute on schedule"
      scan_fail=1
    fi
  done <<EOF
$osv_rows
EOF
  if [ "$scan_hold_registered" -eq 1 ] && [ "$scan_hold_observed" -eq 0 ]; then
    printf '%-22s %s\n' "$r" "dependency-scan:hold-premise-stale — registered schedule guard is absent"
    scan_fail=1
  fi
done
[ "$scan_expected" -gt 0 ] \
  || die_incomplete "expected dependency-scan lockfile population is zero; refusing a vacuous pass."
if [ "$scan_fail" -eq 0 ]; then
  echo "Dependency scan cadence conformant — $scan_seen live scan repo(s) across $scan_expected expected lockfile repo(s), every live scan with a daily cron; $scan_held held guard(s)."
else
  fail=1
fi

# Vulnerability suppressions, in one pass across the whole account. An
# osv-scanner.toml entry holds the dependency-scan gate green over a finding
# nobody can fix, which makes it the one file in the fleet that can turn a red
# gate green by assertion alone. FLEET.md therefore requires two fields on every
# entry — a `reason`, and an `ignoreUntil` that makes the acceptance expire.
#
# The expiry is the part that needs a checker. A `reason` is visible in review
# the day it is written; a date silently lapses months later, in a file nobody
# has opened since, and the only thing that would notice is a scan that happens
# to run afterwards. That is the same shape as every other defect this script
# exists for: a control that reports success without having evaluated anything.
#
# Swept across every non-archived repo rather than inside the loop above,
# because an exempt repo can carry a suppression too — and the exempt repos are
# precisely the ones with no CI to fail when a date lapses.
echo
today=$(date -u +%F)
supp_fail=0
supp_entries=0
supp_repos=0
for r in $ALL; do
  capture_repo_snapshot "$r"
  suppression_sha=$SNAPSHOT_SHA
  if optional_content "repos/$OWNER/$r/contents/osv-scanner.toml?ref=$suppression_sha" \
    "$r osv-scanner.toml at $suppression_sha"; then
    body=$CONTENT
  else
    continue
  fi
  supp_repos=$((supp_repos + 1))
  # One line per [[IgnoredVulns]] block: id|nonempty-reason|ignoreUntil
  if ! parsed=$(printf '%s\n' "$body" | awk '
    function emit() { printf "%s|%d|%s\n", (id==""?"NOID":id), rs, (iu==""?"NONE":iu) }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[\[IgnoredVulns\]\]/ { if (n>0) emit(); n++; id=""; rs=0; iu=""; next }
    n>0 && /^[[:space:]]*id[[:space:]]*=/          { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/["'"'"'[:space:]]/,"",v); id=v }
    n>0 && /^[[:space:]]*reason[[:space:]]*=/      { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); gsub(/["'"'"'[:space:]]/,"",v); rs=(v!="") }
    n>0 && /^[[:space:]]*ignoreUntil[[:space:]]*=/ { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/["'"'"'[:space:]]/,"",v); iu=v }
    END { if (n>0) emit() }'); then
    die_incomplete "$r osv-scanner.toml suppression blocks could not be parsed."
  fi
  marker_count=$(printf '%s\n' "$body" | awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[\[IgnoredVulns\]\]/ { n++ }
    END { print n+0 }
  ') || die_incomplete "$r osv-scanner.toml suppression markers could not be counted."
  parsed_count=$(printf '%s\n' "$parsed" | awk -F '|' 'NF { n++ } END { print n+0 }') \
    || die_incomplete "$r osv-scanner.toml parsed suppression rows could not be counted."
  [ "$parsed_count" -eq "$marker_count" ] \
    || die_incomplete "$r osv-scanner.toml parsed $parsed_count of $marker_count suppression blocks."
  [ "$marker_count" -eq 0 ] && continue
  while IFS='|' read -r id rs iu; do
    [ -z "$id" ] && continue
    supp_entries=$((supp_entries + 1))
    [ "$rs" = "1" ] || { printf '%-22s %s\n' "$r" "suppression $id: no reason — FLEET.md requires one"; supp_fail=1; }
    if [ "$iu" = "NONE" ]; then
      printf '%-22s %s\n' "$r" "suppression $id: no ignoreUntil — an acceptance that cannot expire is unreviewed"
      supp_fail=1
    elif ! printf '%s' "$iu" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      || ! valid_calendar_date "$iu"; then
      printf '%-22s %s\n' "$r" "suppression $id: ignoreUntil '$iu' is not a valid YYYY-MM-DD calendar date"
      supp_fail=1
    elif [ "$iu" \< "$today" ]; then
      printf '%-22s %s\n' "$r" "suppression $id: ignoreUntil $iu has passed — re-decide it or remove the entry"
      supp_fail=1
    fi
  done <<EOF
$parsed
EOF
done
if [ "$supp_fail" -eq 0 ]; then
  echo "Suppressions conformant — $supp_entries entr$([ "$supp_entries" = 1 ] && echo y || echo ies) across $supp_repos repo(s), all with a reason and an unexpired date."
else
  fail=1
fi

# Action pin comments, in one pass across the whole account. Deliberately not
# inside the loop above: this audit covers every non-archived repo, including
# the three the checker exempts. Both original rot cases sat in exempt repos —
# this repo's own review lane, and fleet-template, which is how a bad comment
# would reach every repo created after it.
echo
# $0 was resolved through any symlink at startup, and the auditor is invoked
# via bash rather than executed — so neither a linked checkout nor a lost
# executable bit turns into a phantom drift report. The exact snapshot manifest
# captured at the start of this audit is passed through; the pin auditor neither
# re-enumerates repositories nor resolves moving default branches a second time.
pins_rc=0
printf '%s\n' "$REPO_SHA_ROWS" \
  | bash "$PIN_AUDITOR" --snapshot-manifest - "$repo_actual" || pins_rc=$?
case "$pins_rc" in
  0) ;;
  1) fail=1 ;;
  *) die_incomplete "ACTION PIN AUDIT INCOMPLETE (rc=$pins_rc) — no fleet drift classification is valid." ;;
esac

if [ "$fail" -eq 0 ]; then
  echo; echo "Fleet conformant."
else
  echo; echo "DRIFT FOUND — see rows above. FLEET.md defines the standard." >&2
fi
exit $fail
