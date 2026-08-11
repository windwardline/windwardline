#!/bin/bash
# Permission-surface audit — asserts the machine's agent allowlists obey the
# standing rules in ~/AGENTS.md: no interpreter, package-runner, or
# task-runner wildcards on standing allow; credential reads ask-gated, never
# allowed; no local wildcards that defeat the global ask fences; no
# connection-string material in any settings file; house skills present.
# Matches are reported as file:line only — never the matched content, which
# by definition may be a secret. Exit 0 clean; 1 on drift.
# Runs weekly via CADENCE.md step 5 (guardrail drift).
set -u
fail=0
say() { fail=1; printf '%s\n' "$*"; }

G=/Users/peacock/.claude/settings.json
W=/Users/peacock/Projects/.claude/settings.json

FORBIDDEN='^Bash\((npm|npx|pnpm|pnpx|yarn|bun|bunx|node|deno|tsx|python[0-9]?|pip[0-9]?|uv|uvx|poetry|cargo|go|php|composer|make|just|turbo|vitest|jest|pytest|docker (build|compose|exec)|git config|sh|bash|zsh|eval|source):\*\)$'
n=$(jq -r '.permissions.allow[]' "$G" 2>/dev/null | grep -cE "$FORBIDDEN")
[ "${n:-0}" -eq 0 ] || {
  say "global allow: $n interpreter/runner/task-runner wildcards (forbidden by standing rule):"
  jq -r '.permissions.allow[]' "$G" | grep -E "$FORBIDDEN" | sed 's/^/  /'
}
# Any credential-adjacent security(1) subcommand on standing allow is drift —
# dump-keychain is strictly broader than the single-item read below, and it
# sat on a local allowlist unnoticed until run three (2026-08-09).
CRED_CLI='security (dump-keychain|find-(generic|internet)-password|export|unlock-keychain)'
jq -r '.permissions.allow[]' "$G" 2>/dev/null | grep -qE "$CRED_CLI" \
  && say "global allow: credential reads must sit in ask, not allow"
jq -e '.permissions.ask | index("Bash(security find-generic-password:*)")' "$G" >/dev/null 2>&1 \
  || say "global ask: missing Bash(security find-generic-password:*)"
jq -e '.hooks.PreToolUse[0].hooks[0].command | test("repo-location-guard")' "$G" >/dev/null 2>&1 \
  || say "global hooks: repo-location guard not registered"
# The settings-hygiene SessionStart hook strips forbidden local grants the
# moment a session starts (owner-approved 2026-08-09 after Bash(gh pr *)
# reached standing allow six times in three days via write-action approval
# prompts). Its pattern mirrors LOCAL_BAD below — the two change together.
# This audit stays the weekly backstop; a disarmed guard is drift.
jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | any(test("settings-hygiene-guard"))' "$G" >/dev/null 2>&1 \
  || say "global hooks: settings-hygiene guard not registered"
jq -e '.hooks.Stop' "$W" >/dev/null 2>&1 \
  || say "workspace hooks: done-gate Stop hook not registered"

# Local settings files: fence-defeating wildcards, mutation standing-allows,
# and secret material. file:line only — content is never printed.
#
# The interpreter clause reads `node[^)]* -e`, not `node -e`, because flags sit
# between the two. `Bash(FMP_API_KEY=... node --input-type=module -e ' *)` held
# standing allow in levelflow-cloud and passed both this audit and the
# SessionStart guard — a wildcard-tailed arbitrary-eval grant, which is exactly
# what the clause exists to forbid. Measured before widening: across all 249
# allow/ask/deny entries on the machine it newly flags that one entry and
# nothing else.
LOCAL_BAD='gh (api|pr|repo|auth) \*|security (dump-keychain|find-(generic|internet)-password|export|unlock-keychain)|python[0-9]? -c|python[0-9]? -\)|node[^)]* -e|npm run \*|Bash\(npx[^)]*\*|apply_migration|execute_sql|execute_zapier_write|Read\(//Users/peacock/\*\*|postgres(ql)?://[^"]*:[^@"]{6,}@|wrangler login|brew install \*|git reset \*|git rm \*'
while IFS= read -r f; do
  hits=$(grep -nE "$LOCAL_BAD" "$f" 2>/dev/null | cut -d: -f1 | paste -sd, -)
  [ -z "$hits" ] || say "$f: forbidden entries at line(s) $hits"
done < <(find /Users/peacock/Projects -maxdepth 3 -name settings.local.json -not -path '*/node_modules/*' 2>/dev/null)

# House skills present
for s in magic-link launch-registry mobile-density; do
  [ -f "/Users/peacock/.claude/skills/$s/SKILL.md" ] || say "missing house skill: $s"
done

if [ "$fail" -eq 0 ]; then
  echo "Permission surface clean."
else
  echo; echo "PERMISSION DRIFT — rows above. Standing rules live in ~/AGENTS.md." >&2
fi
exit "$fail"
