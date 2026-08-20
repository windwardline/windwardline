#!/bin/bash
# Fleet conformance checker — verifies every fleet repo against FLEET.md.
# Requires an authenticated `gh`. Reads remote state only (no local checkouts),
# so it can run from any machine. Exit 0 = fully conformant; 1 = drift found.
#
# The fleet is derived live: every non-archived, non-template repo under the
# owner, minus the exceptions register (FLEET.md). A new repo is in scope the
# moment it exists — inclusion is the default, exemption is the explicit act.
#
# FLEET.md is the standard; this script is its enforcement. Change them together.

set -u
OWNER="windwardline"
EXEMPT="windwardline venture ops"   # mirrors FLEET.md's exceptions register exactly
# Repos the owner has reserved, which therefore lag a fleet-wide change. Named
# and reported every run rather than skipped: a skip list that cannot say why
# is how fleet-template sat exempt while merging eight PRs through no gate.
# Empty this the moment the hold lifts — see FLEET.md's held-repos note.
LANE_HELD="craft"
FILES="AGENTS.md CLAUDE.md LICENSE SECURITY.md .github/dependabot.yml .github/workflows/ci.yml .github/workflows/security.yml .github/workflows/claude-review.yml"
# Detectable parallel-stack markers (FLEET.md Preferred stack). A recorded
# "Stack exception (owner-approved" line in the repo's AGENTS.md waives them.
STACK_DENY_DEPS="mongodb mongoose firebase firebase-admin @planetscale/database"
ALT_HOST_FILES="netlify.toml fly.toml render.yaml railway.json"

ALL=$(gh repo list "$OWNER" --limit 200 --json name,isArchived,isTemplate \
  --jq '[.[] | select((.isArchived or .isTemplate) | not) | .name] | sort | join(" ")' 2>/dev/null) || ALL=""
REPOS=""
for r in $ALL; do
  skip=0
  for e in $EXEMPT; do [ "$r" = "$e" ] && skip=1; done
  [ "$skip" -eq 0 ] && REPOS="$REPOS $r"
done
if [ -z "${REPOS// /}" ]; then
  echo "ERROR: fleet enumeration returned no repos — refusing a vacuous pass." >&2
  exit 1
fi
echo "Fleet (live from github.com/$OWNER, minus exceptions register):$REPOS"
echo

# Resolve this script's repo once, through any symlink. The pin auditor below
# already did this; the template comparison used a bare dirname "$0", which
# breaks under a symlinked checkout and silently yields an empty $want — read
# as "no template" rather than as a failure to look.
REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/.." && pwd)

# Absent and refused are different answers. `gh api` fails non-zero on both a
# 404 and a rate limit, so a throttled run reported every file missing in all
# 14 repos at once (2026-08-11, secondary rate limit mid-sweep). That is worse
# than not running: this script is the fleet's authority, and a false
# "everything is missing" invites exactly the wrong remediation. Refusals abort
# the run instead of being counted as drift.
#   0 = present   1 = absent   2 = refused
probe() {
  resp=$(gh api "$1" 2>&1) && return 0
  case "$resp" in
    *"Not Found"*) return 1 ;;
    *) refusal="$resp"; return 2 ;;
  esac
}


# The CONVERGE cycle, DERIVED FROM FLEET.md rather than copied into this script.
#
# FLEET.md's working method only reaches an agent through the file the agent
# actually reads: its own repo's AGENTS.md. Every repo therefore carries a
# summary of the cycle — and a summary is a copy, free to drift from the thing
# it summarises. Eight reviewers in one round (2026-08-20) each said the same
# thing: nothing asserted the two agreed.
#
# A literal chain hardcoded here would not fix that. It would be a THIRD copy,
# free to drift from both — the curated-population defect this script's own
# fleet enumeration exists to avoid, reintroduced in the enforcement itself.
#
# Read from main, not from the working tree. This script's header promises it
# reads remote state only, and the promise has to hold for the ONE input that
# defines pass/fail: a stale clone would otherwise measure the fleet against an
# old cycle and report green, which is precisely the silent failure the whole
# check exists to prevent. Set FLEET_MD_LOCAL=<path> to test a proposed change
# before pushing it; the source is printed either way, because a check whose
# authority is ambiguous is not a check.
if [ -n "${FLEET_MD_LOCAL:-}" ]; then
  STANDARD=$(cat "$FLEET_MD_LOCAL" 2>/dev/null)
  echo "CONVERGE chain derived from LOCAL $FLEET_MD_LOCAL (override; main is what governs)"
else
  probe "repos/$OWNER/windwardline/contents/FLEET.md?ref=main"
  case $? in
    1) echo "ERROR: FLEET.md is absent from $OWNER/windwardline@main — refusing to" >&2
       echo "check the fleet against a standard that is not there." >&2; exit 2 ;;
    2) echo "ERROR: GitHub refused the request for FLEET.md — not drift, aborting." >&2
       printf '%s\n' "$refusal" | head -3 >&2; exit 2 ;;
  esac
  STANDARD=$(gh api "repos/$OWNER/windwardline/contents/FLEET.md?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  echo "CONVERGE chain derived from $OWNER/windwardline@main FLEET.md"
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
# Formatting is stripped before the step name is read, because the name is the
# WORD, not its markup: **`REPORT`** is REPORT. And the name must be a run of
# ALL-CAPS words — a title-cased "**Refute.**" yields nothing rather than the
# single letter "R", which would have matched the first R in any document,
# imposed no ordering, and left REFUTE unchecked with the count still correct.
# Nothing derived from a real entry is an ABORT, never a guess.
cycle_scan() {
  awk '
    /^### The cycle/ { inlist=1; next }
    inlist && /^#+ /  { exit }
    inlist && /^[0-9]+\. / {
      line=$0
      sub(/^[0-9]+\. /, "", line)
      gsub(/[*`_]/, "", line)                      # strip bold/code/emphasis
      entries++
      # Walk leading words while each is ENTIRELY capitals (hyphens allowed),
      # ignoring trailing punctuation. Token-walking rather than one regex,
      # because a regex over the whole run cannot tell "VERIFY YOURSELF" (two
      # real name words) from "UPDATE FLEET.md" (one name word and a filename)
      # — the caps-run form matched "UPDATE FLEET" and would have reddened the
      # fleet over a wording change that altered nothing about the method.
      # An internal dot keeps FLEET.md out; a trailing dot keeps FIND. in.
      n=split(line, w, " ")
      name=""
      for (i=1; i<=n; i++) {
        t=w[i]
        sub(/[.,;:!?]+$/, "", t)
        if (t ~ /^[A-Z][A-Z-]+$/) name = (name=="" ? t : name " " t)
        else break
      }
      if (name != "") print "STEP " name
    }
    END { print "ENTRIES " entries+0 }
  '
}
scan=$(printf '%s\n' "$STANDARD" | cycle_scan)
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

fail=0
printf '%-22s %s\n' "REPO" "DRIFT (empty = conformant)"
printf '%-22s %s\n' "----" "----"

for r in $REPOS; do
  drift=""
  note=""

  # Required files on main
  for f in $FILES; do
    probe "repos/$OWNER/$r/contents/$f?ref=main"
    case $? in
      1) drift="$drift missing:$f" ;;
      2) echo; echo "ERROR: GitHub refused a request for $r ($f) — not drift, aborting." >&2
         printf '%s\n' "$refusal" | head -3 >&2
         echo "Re-run after the rate limit resets: gh api /rate_limit --jq .resources.core" >&2
         exit 2 ;;
    esac
  done

  # Read once for the stack-exception waiver near the end of this loop. The
  # CONVERGE citation and gate-enumeration checks moved OUT of this loop — see
  # the all-repos pass below — because this loop skips the exceptions register.
  agents=$(gh api "repos/$OWNER/$r/contents/AGENTS.md?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)

  # Dependabot auto-merge lane — now every repo, no exceptions. levelflow-cloud
  # was excluded while the lane ran on GITHUB_TOKEN, whose merges fire no
  # on: push workflows and would have left its Supabase deploy silently behind
  # main. The App installation token removed that, so the exception went with
  # it (2026-08-11).
  # Byte-identity, not presence. The same reasoning as the cooldown check
  # below: that a file exists says nothing about what is inside it, and this
  # one decides what merges unattended. Compared by git blob SHA against the
  # canonical templates/ copy in this repo, so one sweep re-verifies the fleet.
  #
  # `gh api --jq` writes the error body to stdout on a 404, so two missing
  # files would otherwise compare equal — hence the 40-hex guard before any
  # comparison is trusted.
  want=$(git -C "$REPO_ROOT" hash-object templates/dependabot-auto-merge.yml 2>/dev/null)
  got=$(gh api "repos/$OWNER/$r/contents/.github/workflows/dependabot-auto-merge.yml?ref=main" --jq '.sha' 2>/dev/null)
  case "$got" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) got="" ;;
  esac
  if [ -z "$got" ]; then
    drift="$drift missing:dependabot-auto-merge.yml"
  elif [ -z "$want" ]; then
    drift="$drift no-template:dependabot-auto-merge.yml"
  elif [ "$got" != "$want" ]; then
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
  fi

  # The soak is read, not assumed. Auto-merge without a cooldown is a same-day
  # supply-chain window, so every update lane must carry at least seven days —
  # the file's presence says nothing about the number inside it.
  db=$(gh api "repos/$OWNER/$r/contents/.github/dependabot.yml?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -n "$db" ]; then
    lanes=$(printf '%s\n' "$db" | grep -c "package-ecosystem:")
    soaked=$(printf '%s\n' "$db" | grep -cE "default-days: *([7-9]|[1-9][0-9]+)")
    [ "${soaked:-0}" -ge "${lanes:-1}" ] || drift="$drift cooldown:${soaked:-0}of${lanes:-0}lanes"
  fi

  # A required check that excuses itself from Dependabot PRs reports green
  # without running, because GitHub counts a skipped required check as
  # satisfied. Semgrep CE did exactly that until 2026-08-11 (verified on
  # mimic#35, merged with "Semgrep CE SKIPPED"). Nothing in security.yml may
  # carry that guard again.
  sy=$(gh api "repos/$OWNER/$r/contents/.github/workflows/security.yml?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  case "$sy" in
    *"github.actor != 'dependabot[bot]'"*) drift="$drift security-yml:skips-dependabot";;
  esac

  # The action-pin gate rides the already-required Secret scan job as a step, so
  # it contributes no check name and nothing in the ruleset would notice it being
  # dropped. Reuses $sy above — no extra API call. A repo that loses this step
  # keeps merging wrong pin comments until the next weekly sweep catches them.
  case "$sy" in
    *"verify-action-pins@"*) ;;
    *) drift="$drift security-yml:no-pin-gate";;
  esac

  # Repo settings
  am=$(gh api "repos/$OWNER/$r" --jq '.allow_auto_merge' 2>/dev/null)
  [ "$am" = "true" ] || drift="$drift auto-merge:off"

  # Seven-header vercel.json, explicit (root, or apps/web in a monorepo)
  vj=$(gh api "repos/$OWNER/$r/contents/vercel.json?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  [ -z "$vj" ] && vj=$(gh api "repos/$OWNER/$r/contents/apps/web/vercel.json?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -z "$vj" ]; then
    drift="$drift missing:vercel.json"
  else
    hv=$(printf '%s' "$vj" | jq -r '[.headers[]?.headers[]?.key] | map(ascii_downcase) | unique
      | map(select(. == "content-security-policy" or . == "strict-transport-security"
        or . == "x-content-type-options" or . == "referrer-policy" or . == "x-frame-options"
        or . == "permissions-policy" or . == "cross-origin-opener-policy")) | length' 2>/dev/null)
    [ "${hv:-0}" -eq 7 ] || drift="$drift vercel-headers:${hv:-0}/7"
  fi

  # Ruleset: exists, requires the scan jobs, enforces linear history, no bypass
  rid=$(gh api "repos/$OWNER/$r/rulesets" --jq '.[] | select(.name=="main-requires-green-ci") | .id' 2>/dev/null | head -1)
  haspkg=0
  gh api "repos/$OWNER/$r/contents/package.json?ref=main" --silent >/dev/null 2>&1 && haspkg=1
  ctx=""
  if [ -z "$rid" ]; then
    drift="$drift ruleset:missing"
  else
    rs=$(gh api "repos/$OWNER/$r/rulesets/$rid" 2>/dev/null)
    ctx=$(printf '%s' "$rs" | jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | join("|")' 2>/dev/null)
    for want in "Semgrep CE" "Secret scan"; do
      case "|$ctx|" in *"|$want|"*) ;; *) drift="$drift ruleset-lacks:${want// /_}";; esac
    done
    if [ "$haspkg" -eq 1 ]; then
      case "|$ctx|" in *"|Dependency scan / osv-scan|"*) ;; *) drift="$drift ruleset-lacks:osv-scan";; esac
    fi
    printf '%s' "$rs" | jq -e '[.rules[].type] | contains(["required_linear_history"])' >/dev/null 2>&1 \
      || drift="$drift ruleset-lacks:linear-history"
    nb=$(printf '%s' "$rs" | jq -r '.bypass_actors | length' 2>/dev/null)
    [ "${nb:-1}" -eq 0 ] || drift="$drift ruleset:bypass-actors($nb)"
  fi

  # Required-checks completeness: every successful job from PR-triggered
  # workflow runs on the latest merged PR must be a required context. Sampled
  # from workflow runs filtered to event == pull_request — a dispatch or
  # schedule run against the same SHA must not poison the sample (it did, on
  # the 2026-08-04 cadence run's own verification dispatch). The advisory
  # review ("review / *") is excluded by design, and so is
  # "dependabot-auto-merge": it skips on human PRs but succeeds on Dependabot
  # ones, so the sample sees it precisely when the latest merged PR came from
  # Dependabot. Requiring it would be backwards — it is the thing doing the
  # merging, not a gate on it. Skipped/cancelled jobs are filtered by the
  # success condition.
  sha=$(gh pr list -R "$OWNER/$r" --state merged -L1 --json headRefOid --jq '.[0].headRefOid' 2>/dev/null)
  if [ -n "$sha" ] && [ "$sha" != "null" ] && [ -n "$ctx" ]; then
    run_names=$(gh api "repos/$OWNER/$r/actions/runs?head_sha=$sha&per_page=50" \
      --jq '.workflow_runs[] | select(.event=="pull_request") | .id' 2>/dev/null | while IFS= read -r wrid; do
        gh api "repos/$OWNER/$r/actions/runs/$wrid/jobs?per_page=100" --paginate \
          --jq '.jobs[] | select(.conclusion=="success") | .name' 2>/dev/null
      done | sort -u)
    oldifs=$IFS
    IFS=$'\n'
    for n in $run_names; do
      case "$n" in ""|"review / "*|"dependabot-auto-merge") continue;; esac
      case "|$ctx|" in *"|$n|"*) ;; *) drift="$drift unrequired-job:${n// /_}";; esac
    done
    IFS=$oldifs
  else
    note=" (no merged-PR sample for required-checks audit)"
  fi

  # Review-lane secret. The license is the only credential now — API billing
  # was retired 2026-08-08 and the Console key revoked, so a repo carrying
  # ANTHROPIC_API_KEY is drift rather than an accepted alternative.
  sec=$(gh secret list -R "$OWNER/$r" --json name --jq '[.[] | select(.name=="CLAUDE_CODE_OAUTH_TOKEN")] | length' 2>/dev/null)
  [ "${sec:-0}" -ge 1 ] || drift="$drift secret:CLAUDE_CODE_OAUTH_TOKEN"
  stale=$(gh secret list -R "$OWNER/$r" --json name --jq '[.[] | select(.name=="ANTHROPIC_API_KEY")] | length' 2>/dev/null)
  [ "${stale:-0}" -eq 0 ] || drift="$drift secret:stale-ANTHROPIC_API_KEY"

  # Dependabot settings, not just the config file (found off on 5 repos by
  # the 2026-08-04 cadence run while dependabot.yml sat present everywhere).
  # Three independent switches: the FILE drives scheduled version PRs, the
  # ALERTS toggle surfaces advisories, and AUTOMATED SECURITY FIXES opens
  # the fix PRs.
  gh api "repos/$OWNER/$r/vulnerability-alerts" --silent >/dev/null 2>&1 \
    || drift="$drift dependabot-alerts:off"
  asf=$(gh api "repos/$OWNER/$r/automated-security-fixes" --jq '.enabled' 2>/dev/null)
  [ "$asf" = "true" ] || drift="$drift dependabot-security-fixes:off"

  # App-class extras: lockfile + required scripts + stack-deviation deps
  stackdrift=""
  if [ "$haspkg" -eq 1 ]; then
    haslock=0
    for lf in package-lock.json pnpm-lock.yaml yarn.lock bun.lockb; do
      gh api "repos/$OWNER/$r/contents/$lf?ref=main" --silent >/dev/null 2>&1 && { haslock=1; break; }
    done
    [ "$haslock" -eq 1 ] || drift="$drift missing:lockfile"
    pkg=$(gh api "repos/$OWNER/$r/contents/package.json?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
    scripts=$(printf '%s' "$pkg" | jq -r '.scripts | keys | join("|")' 2>/dev/null)
    case "$scripts" in *typecheck*|*check*) ;; *) drift="$drift script:typecheck";; esac
    case "$scripts" in *lint*) ;; *) drift="$drift script:lint";; esac
    case "$scripts" in *test*) ;; *) drift="$drift script:test";; esac
    deps=$(printf '%s' "$pkg" | jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys | join("|")' 2>/dev/null)
    for bad in $STACK_DENY_DEPS; do
      case "|$deps|" in *"|$bad|"*) stackdrift="$stackdrift dep:$bad";; esac
    done
  fi

  # Alternate-hosting artifacts (all repos)
  for f in $ALT_HOST_FILES; do
    gh api "repos/$OWNER/$r/contents/$f?ref=main" --silent >/dev/null 2>&1 \
      && stackdrift="$stackdrift file:$f"
  done

  # Unrecorded stack deviations fail; a recorded owner approval waives them.
  if [ -n "$stackdrift" ]; then
    # $agents was read once at the top of this loop.
    case "$agents" in
      *"Stack exception (owner-approved"*) ;;
      *) drift="$drift stack-deviation:${stackdrift# }(unrecorded)";;
    esac
  fi

  if [ -n "$drift" ]; then
    fail=1
    printf '%-22s %s\n' "$r" "$drift"
  else
    printf '%-22s %s\n' "$r" "✓$note"
  fi
done

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
  # Fetched again here rather than shared with the main loop: that loop runs
  # over $REPOS (exceptions removed) and this pass runs over $ALL, so there is
  # no shared iteration to hang a cached read on. The extra calls buy coverage
  # of exactly the repos an exemption would otherwise hide.
  #
  # Probed, not just fetched. This pass runs LAST, after roughly forty calls per
  # repo — exactly where the 2026-08-11 secondary rate limit landed — and a
  # throttle there would otherwise report every contract as drift, which is the
  # failure this script already committed in writing never to repeat. Absent and
  # refused are different answers.
  probe "repos/$OWNER/$r/contents/AGENTS.md?ref=main"
  case $? in
    1) rowdrift="$rowdrift agents-md:absent" ; agents="" ;;
    2) echo; echo "ERROR: GitHub refused a request for $r (AGENTS.md) — not drift, aborting." >&2
       printf '%s\n' "$refusal" | head -3 >&2
       echo "Re-run after the rate limit resets: gh api /rate_limit --jq .resources.core" >&2
       exit 2 ;;
    0) agents=$(gh api "repos/$OWNER/$r/contents/AGENTS.md?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) ;;
  esac
  if [ -z "$agents" ]; then
    [ -n "$rowdrift" ] || rowdrift="$rowdrift agents-md:empty"
  else
    # Closure condition 3: the standard reaches the agent at the file it reads.
    case "$agents" in
      *"FLEET.md"*) ;;
      *) rowdrift="$rowdrift converge-citation:absent" ;;
    esac

    # The cycle itself, IN ORDER, against the derivation above. The haystack is
    # consumed as each step matches, so a contract that lists the right steps
    # in the wrong order fails — an out-of-order cycle is a different method,
    # not a cosmetic difference. Case- and whitespace-insensitive: repos state
    # the chain in prose, and this check is about the method surviving the
    # copy, not about punctuation.
    #
    # Known and deliberate: the step NAMED in the drift row is the first one
    # that broke the ordered match, which is not always the step someone
    # edited — a step word occurring earlier in the file for unrelated reasons
    # consumes the haystack ahead of its turn and shifts the label. The ROW is
    # the signal ("this contract's cycle is not the standard's"); the step name
    # is a hint for where to look. Verified 2026-08-20 by adding a ninth step
    # to FLEET.md and re-running: every repo went red with no repo edited, one
    # of them naming a different step than the one inserted.
    hay=$(printf '%s' "$agents" | tr '[:lower:]' '[:upper:]' | tr -s '[:space:]' ' ')
    cyc_missing=""
    while IFS= read -r step; do
      [ -z "$step" ] && continue
      rest=${hay#*"$step"}
      if [ "$rest" = "$hay" ]; then
        cyc_missing="$cyc_missing,${step// /_}"
      else
        hay="$rest"
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
    # Probed for the same reason, and then SHAPE-CHECKED. `gh api --jq` writes
    # the error body to stdout on a non-2xx, so an unguarded read of this
    # endpoint splits `{"message":"Not Found",...}` into tokens, matches none of
    # them against *.yml, finds nothing unenumerated, and reports the repo
    # conformant having examined nothing. That is the same hazard the
    # dependabot-template comparison guards with its 40-hex blob-sha check, and
    # a check that cannot tell "no workflows" from "GitHub refused" is worse
    # than no check.
    wfs=""
    probe "repos/$OWNER/$r/contents/.github/workflows?ref=main"
    case $? in
      1) wfs="" ;;   # genuinely no workflows directory — nothing to enumerate
      2) echo; echo "ERROR: GitHub refused a request for $r (workflows) — not drift, aborting." >&2
         printf '%s\n' "$refusal" | head -3 >&2
         exit 2 ;;
      0) wfs=$(gh api "repos/$OWNER/$r/contents/.github/workflows?ref=main" --jq '.[].name' 2>/dev/null)
         # Every line must look like a bare filename. Anything else means the
         # response was not the array we asked for.
         if printf '%s\n' "$wfs" | grep -qvE '^[A-Za-z0-9._-]*$'; then
           echo; echo "ERROR: workflow listing for $r was not a filename array — aborting." >&2
           printf '%s\n' "$wfs" | head -3 >&2
           exit 2
         fi ;;
    esac
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
      printf '%s' "$agents" \
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
PRIVATE_BY_DESIGN="ops venture"
vis_rows=$(gh repo list "$OWNER" --limit 200 --json name,visibility,isArchived \
  --jq '[.[] | select(.isArchived | not) | .name + " " + .visibility] | sort | join("\n")' 2>/dev/null) || vis_rows=""
if [ -z "${vis_rows// /}" ]; then
  echo "VISIBILITY AUDIT INCOMPLETE — enumeration returned nothing, refusing a vacuous pass." >&2
  fail=1
else
  vis_fail=0
  while read -r name vis; do
    [ -n "$name" ] || continue
    registered=0
    for p in $PRIVATE_BY_DESIGN; do [ "$name" = "$p" ] && registered=1; done
    if [ "$vis" = "PRIVATE" ] && [ "$registered" -eq 0 ]; then
      printf '%-22s %s\n' "$name" "visibility:private-unregistered (billing Actions minutes)"
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
echo
exempt_fail=0
for e in $EXEMPT; do
  prruns=$(gh api "repos/$OWNER/$e/actions/runs?event=pull_request&per_page=1" --jq '.total_count' 2>/dev/null)
  case "$prruns" in ''|*[!0-9]*) prruns=0 ;; esac
  hasci=0
  for f in ci.yml security.yml; do
    sha=$(gh api "repos/$OWNER/$e/contents/.github/workflows/$f?ref=main" --jq '.sha' 2>/dev/null)
    # gh writes the 404 body to stdout, so require a real blob sha before trusting it
    case "$sha" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) hasci=1 ;;
    esac
  done
  if [ "$hasci" -eq 1 ] || [ "$prruns" -gt 0 ]; then
    printf '%-22s %s\n' "$e" "exemption-stale: has CI (ci/security workflow, ${prruns} pull_request runs) — the no-CI premise no longer holds, so the ruleset and auto-merge are now required"
    exempt_fail=1
  fi
done
if [ "$exempt_fail" -eq 0 ]; then
  echo "Exemption premises hold — every exempted repo still has no CI."
else
  fail=1
fi

# The dependency scan must not carry a schedule guard. Its input is the
# advisory database, which moves with no commit — so a weekly cron means a
# repo can sit on a High advisory for six days, which is exactly what happened
# to craft and pathfinder with nanoid GHSA-2v37-7h3g-55p8 (widened 2026-08-13,
# seen 2026-08-17). Semgrep and Secret scan keep their guards: they read repo
# content, which cannot change without a push they already gate.
#
# Only repos that actually scan a lockfile are in scope; the six sites without
# one have no such job and are not drift.
#
# craft is held by the owner (2026-08-17) while unrelated work finishes there,
# so it is named rather than silently skipped — a skip list that cannot say why
# is how fleet-template sat exempt while running 61 builds through no gate.
DEPSCAN_HELD="craft"
echo
scan_fail=0; scan_seen=0; scan_held=0
for r in $ALL; do
  body=$(gh api "repos/$OWNER/$r/contents/.github/workflows/security.yml?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  [ -z "$body" ] && continue
  # only the live job counts; fleet-template ships it commented out as a TODO
  printf '%s' "$body" | grep -qE '^[[:space:]]*uses:.*osv-scanner-reusable' || continue
  scan_seen=$((scan_seen + 1))
  guard=$(printf '%s' "$body" | awk '/name: Dependency scan/{f=1;next} f&&/^[[:space:]]*if:/{print;exit} f&&!/^[[:space:]]*#/{exit}')
  case "$guard" in
    *github.event.schedule*)
      case " $DEPSCAN_HELD " in
        *" $r "*) printf '%-22s %s\n' "$r" "dependency-scan still weekly — held by owner 2026-08-17, not drift"; scan_held=$((scan_held + 1)) ;;
        *) printf '%-22s %s\n' "$r" "dependency-scan carries a schedule guard — the advisory database moves without a commit"; scan_fail=1 ;;
      esac ;;
  esac
done
if [ "$scan_fail" -eq 0 ]; then
  echo "Dependency scans run on every trigger — $scan_seen repo(s) with a lockfile scan, $scan_held held."
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
  probe "repos/$OWNER/$r/contents/osv-scanner.toml?ref=main"
  case $? in
    1) continue ;;
    2) echo; echo "ERROR: GitHub refused a request for $r (osv-scanner.toml) — not drift, aborting." >&2
       printf '%s\n' "$refusal" | head -3 >&2
       exit 2 ;;
  esac
  body=$(gh api "repos/$OWNER/$r/contents/osv-scanner.toml?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -z "$body" ]; then
    printf '%-22s %s\n' "$r" "osv-scanner.toml unreadable — refusing to call it conformant"
    supp_fail=1; continue
  fi
  supp_repos=$((supp_repos + 1))
  # One line per [[IgnoredVulns]] block: id|reason-present|ignoreUntil
  parsed=$(printf '%s\n' "$body" | awk '
    function emit() { printf "%s|%d|%s\n", (id==""?"NOID":id), rs, (iu==""?"NONE":iu) }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[\[IgnoredVulns\]\]/ { if (n>0) emit(); n++; id=""; rs=0; iu=""; next }
    n>0 && /^[[:space:]]*id[[:space:]]*=/          { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/["'"'"'[:space:]]/,"",v); id=v }
    n>0 && /^[[:space:]]*reason[[:space:]]*=/      { rs=1 }
    n>0 && /^[[:space:]]*ignoreUntil[[:space:]]*=/ { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/["'"'"'[:space:]]/,"",v); iu=v }
    END { if (n>0) emit() }')
  [ -z "$parsed" ] && continue
  while IFS='|' read -r id rs iu; do
    [ -z "$id" ] && continue
    supp_entries=$((supp_entries + 1))
    [ "$rs" = "1" ] || { printf '%-22s %s\n' "$r" "suppression $id: no reason — FLEET.md requires one"; supp_fail=1; }
    if [ "$iu" = "NONE" ]; then
      printf '%-22s %s\n' "$r" "suppression $id: no ignoreUntil — an acceptance that cannot expire is unreviewed"
      supp_fail=1
    elif ! printf '%s' "$iu" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      printf '%-22s %s\n' "$r" "suppression $id: ignoreUntil '$iu' is not a YYYY-MM-DD date"
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
# the four the checker exempts. Both original rot cases sat in exempt repos —
# this repo's own review lane, and fleet-template, which is how a bad comment
# would reach every repo created after it.
echo
# $0 resolved through any symlink, and the auditor invoked via bash rather than
# executed — so neither a linked checkout nor a lost executable bit turns into a
# phantom drift report.
here=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)
pins_rc=0
bash "$here/verify-action-pins.sh" || pins_rc=$?
case "$pins_rc" in
  0) ;;
  1) fail=1 ;;
  *) fail=1; echo "ACTION PIN AUDIT INCOMPLETE (rc=$pins_rc) — not a clean pass." >&2 ;;
esac

if [ "$fail" -eq 0 ]; then
  echo; echo "Fleet conformant."
else
  echo; echo "DRIFT FOUND — see rows above. FLEET.md defines the standard." >&2
fi
exit $fail
