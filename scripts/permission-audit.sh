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
# ~/.claude/settings.local.json is scanned first and deliberately. It overrides
# the global settings for every session in every directory, which makes it the
# most powerful allowlist on the machine — and it was scanned by nothing until
# 2026-08-11, because both this loop and the SessionStart guard only walked
# ~/Projects. It was dated 15 July and held ten forbidden grants including a
# keychain read, which defeats the ask fence asserted twenty lines above.
# maxdepth is 5 so a settings.local.json inside a git worktree is not invisible.
#
# The interpreter clause reads `node[^)]* -e`, not `node -e`, because flags sit
# between the two. `Bash(FMP_API_KEY=... node --input-type=module -e ' *)` held
# standing allow in levelflow-cloud and passed both this audit and the
# SessionStart guard — a wildcard-tailed arbitrary-eval grant, which is exactly
# what the clause exists to forbid. Measured before widening: across all 249
# allow/ask/deny entries on the machine it newly flags that one entry and
# nothing else.
# Two clauses added 2026-08-17, both for grants this audit passed clean while
# they sat on standing allow in ~/Projects/.claude/settings.local.json.
#
# keychain-write: every verb in the credential clause above is a READ —
# dump, find, export, unlock. The rule was written to protect secrecy and never
# asked about destruction, so `Bash(security delete-generic-password *)` was
# conformant: a wildcard letting any unattended session delete arbitrary
# Keychain entries. Widening it on 2026-08-09 to "all credential-adjacent
# security(1) subcommands" widened it along the read axis only, which is how
# the gap survived a deliberate review of this exact clause. For any tool a
# rule names, enumerate read, write and destroy before calling it complete.
#
# worldwritable-exec: `Bash(chmod +x /tmp/eptest.zsh)` beside
# `Bash(/tmp/eptest.zsh)` is standing execution of a fixed path in a
# world-writable directory — anything that can win the race to write that path
# gets an unprompted run. Scoped to /tmp deliberately: the session scratchpad
# under /private/tmp/claude-501/<uuid>/ is not shared and not predictable.
LOCAL_BAD='gh (api|pr|repo|auth|workflow) \*|security (dump-keychain|find-(generic|internet)-password|export|unlock-keychain)|security (delete|add|set)-(generic|internet)-password|Bash\((chmod \+x )?/tmp/|python[0-9]? -c|python[0-9]? -\)|node[^)]* -e|npm run \*|Bash\(npx[^)]*\*|apply_migration|execute_sql|execute_zapier_write|Read\(//Users/peacock/\*\*|postgres(ql)?://[^"]*:[^@"]{6,}@|wrangler login|brew install \*|git reset \*|git rm \*'
while IFS= read -r f; do
  hits=$(grep -nE "$LOCAL_BAD" "$f" 2>/dev/null | cut -d: -f1 | paste -sd, -)
  [ -z "$hits" ] || say "$f: forbidden entries at line(s) $hits"
done < <( { echo /Users/peacock/.claude/settings.local.json
            find /Users/peacock/Projects -maxdepth 5 -name settings.local.json -not -path '*/node_modules/*' 2>/dev/null; } )

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
