#!/bin/bash
# Fleet conformance checker — verifies every fleet repo against FLEET.md.
# Requires an authenticated `gh`. Reads remote state only (no local checkouts),
# so it can run from any machine. Exit 0 = fully conformant; 1 = drift found.
#
# FLEET.md is the standard; this script is its enforcement. Change them together.

set -u
OWNER="windwardline"
REPOS="craft levelflow-cloud mimic pathfinder portfolio proper-form thats-extra timeshift windwardline-com windwardline-capital windwardline-labs windwardline-media windwardline-strategy"
FILES="AGENTS.md CLAUDE.md LICENSE SECURITY.md .github/dependabot.yml .github/workflows/ci.yml .github/workflows/security.yml .github/workflows/claude-review.yml"

fail=0
printf '%-22s %s\n' "REPO" "DRIFT (empty = conformant)"
printf '%-22s %s\n' "----" "----"

for r in $REPOS; do
  drift=""

  # Required files on main
  for f in $FILES; do
    gh api "repos/$OWNER/$r/contents/$f?ref=main" --silent >/dev/null 2>&1 \
      || drift="$drift missing:$f"
  done

  # Repo settings
  am=$(gh api "repos/$OWNER/$r" --jq '.allow_auto_merge' 2>/dev/null)
  [ "$am" = "true" ] || drift="$drift auto-merge:off"

  # Ruleset exists and requires the scan jobs
  rid=$(gh api "repos/$OWNER/$r/rulesets" --jq '.[] | select(.name=="main-requires-green-ci") | .id' 2>/dev/null | head -1)
  if [ -z "$rid" ]; then
    drift="$drift ruleset:missing"
  else
    ctx=$(gh api "repos/$OWNER/$r/rulesets/$rid" \
      --jq '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | join("|")' 2>/dev/null)
    for want in "Semgrep CE" "Secret scan"; do
      case "$ctx" in *"$want"*) ;; *) drift="$drift ruleset-lacks:${want// /_}";; esac
    done
    # App-class repos (root package.json) must also require the OSV scan
    if gh api "repos/$OWNER/$r/contents/package.json?ref=main" --silent >/dev/null 2>&1; then
      case "$ctx" in *"Dependency scan / osv-scan"*) ;; *) drift="$drift ruleset-lacks:osv-scan";; esac
    fi
  fi

  # Review-lane secret
  sec=$(gh secret list -R "$OWNER/$r" --json name --jq '[.[] | select(.name=="ANTHROPIC_API_KEY")] | length' 2>/dev/null)
  [ "${sec:-0}" -ge 1 ] || drift="$drift secret:ANTHROPIC_API_KEY"

  # App-class extras: lockfile + required scripts
  if gh api "repos/$OWNER/$r/contents/package.json?ref=main" --silent >/dev/null 2>&1; then
    haslock=0
    for lf in package-lock.json pnpm-lock.yaml yarn.lock bun.lockb; do
      gh api "repos/$OWNER/$r/contents/$lf?ref=main" --silent >/dev/null 2>&1 && { haslock=1; break; }
    done
    [ "$haslock" -eq 1 ] || drift="$drift missing:lockfile"
    scripts=$(gh api "repos/$OWNER/$r/contents/package.json?ref=main" --jq '.content' 2>/dev/null | base64 -d | jq -r '.scripts | keys | join("|")' 2>/dev/null)
    case "$scripts" in *typecheck*|*check*) ;; *) drift="$drift script:typecheck";; esac
    case "$scripts" in *lint*) ;; *) drift="$drift script:lint";; esac
    case "$scripts" in *test*) ;; *) drift="$drift script:test";; esac
  fi

  if [ -n "$drift" ]; then
    fail=1
    printf '%-22s %s\n' "$r" "$drift"
  else
    printf '%-22s %s\n' "$r" "✓"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo; echo "Fleet conformant."
else
  echo; echo "DRIFT FOUND — see rows above. FLEET.md defines the standard." >&2
fi
exit $fail
