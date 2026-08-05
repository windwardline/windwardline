# Weekly fleet-health cadence

Fires every Monday 09:00 ET as a Claude Code scheduled task. This file is the
checklist the task executes; the task is only the trigger. Changing the cadence
is a PR here. Results are reported in-chat as tables — drift first,
owner-decision items last.

## Every week

1. **Conformance** — run `scripts/fleet-conformance.sh` (this repo). Mechanical
   drift is fixed same-day by the standing flow; anything requiring judgment
   goes to the owner with a proposed fix.
2. **Actions failure sweep** — for every fleet repo (live enumeration, same as
   the checker): workflow runs since the previous Monday with
   `conclusion == failure` and `event != pull_request`. Push and cron failures
   (weekly Semgrep, Headers live) surface nowhere else; report each one.
3. **Guardrail drift** —
   - The four AGENTS.md paths resolve to one inode (`ls -laiL`); restore the
     symlinks if not.
   - Hooks registered: global repo-location guard, workspace done-gate and
     edited-marker (jq assertions against both settings.json files).
   - Model defaults: `~/.claude/settings.json` still `"model": "opus"` with
     `"effortLevel": "high"`; `~/.codex/config.toml` still frontier at high.
   - `gh auth status` healthy.
4. **Stray-repo sweep** — `.git` directories under `$HOME` outside
   `~/Projects` and client-internal zones; propose a safe move for any found.
5. **Meta-snapshot** — run `snapshot.sh` in `windwardline/ops` (private):
   versions the canonical standards file, global and workspace agent config,
   hooks, and agent memory. Lands by PR; aborts on key-shaped content.
6. **Trajectory review** — read the week's `~/Projects/.remember/` dailies
   plus `recent.md`, and memory `MEMORY.md`: repeated failures, permission
   friction, guardrail near-misses, workflow inefficiencies. Durable lessons
   are written to memory; improvement candidates go to the owner as a short
   list.

## First cadence of each month, additionally

- Dependabot and code-scanning alert counts per fleet repo (`gh api`), open
  items reported.
- Owner dashboard reminders (checks only the owner can see): Anthropic Console
  spend and limits; Supabase backup posture; domain and certificate expiries.
