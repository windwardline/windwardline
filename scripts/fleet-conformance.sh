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
  # review ("review / *") is excluded by design; skipped/cancelled jobs are
  # filtered by the success condition.
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
      case "$n" in ""|"review / "*) continue;; esac
      case "|$ctx|" in *"|$n|"*) ;; *) drift="$drift unrequired-job:${n// /_}";; esac
    done
    IFS=$oldifs
  else
    note=" (no merged-PR sample for required-checks audit)"
  fi

  # Review-lane secret
  sec=$(gh secret list -R "$OWNER/$r" --json name --jq '[.[] | select(.name=="ANTHROPIC_API_KEY")] | length' 2>/dev/null)
  [ "${sec:-0}" -ge 1 ] || drift="$drift secret:ANTHROPIC_API_KEY"

  # Dependabot security alerts: the setting, not just the config file
  # (found off on 5 repos by the 2026-08-04 cadence run while dependabot.yml
  # sat present everywhere — the file drives version PRs, the toggle drives
  # security updates).
  gh api "repos/$OWNER/$r/vulnerability-alerts" --silent >/dev/null 2>&1 \
    || drift="$drift dependabot-alerts:off"

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

if [ "$fail" -eq 0 ]; then
  echo; echo "Fleet conformant."
else
  echo; echo "DRIFT FOUND — see rows above. FLEET.md defines the standard." >&2
fi
exit $fail
