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
EXEMPT="windwardline venture fleet-template ops"   # mirrors FLEET.md's exceptions register exactly
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

fail=0
printf '%-22s %s\n' "REPO" "DRIFT (empty = conformant)"
printf '%-22s %s\n' "----" "----"

for r in $REPOS; do
  drift=""
  note=""

  # Required files on main
  for f in $FILES; do
    gh api "repos/$OWNER/$r/contents/$f?ref=main" --silent >/dev/null 2>&1 \
      || drift="$drift missing:$f"
  done

  # Dependabot auto-merge lane. levelflow-cloud is the one exception in
  # FLEET.md's register: it holds the fleet's only Actions-based deploy on
  # push, and a merge whose auto-merge was enabled by GITHUB_TOKEN does not
  # trigger on: push workflows — silently, with nothing in the Actions tab.
  if [ "$r" != "levelflow-cloud" ]; then
    gh api "repos/$OWNER/$r/contents/.github/workflows/dependabot-auto-merge.yml?ref=main" --silent >/dev/null 2>&1 \
      || drift="$drift missing:dependabot-auto-merge.yml"
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
    agents=$(gh api "repos/$OWNER/$r/contents/AGENTS.md?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
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
