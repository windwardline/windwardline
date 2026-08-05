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
3. **Open-issue sweep** — enumerate open issues across every fleet repo
   (`gh issue list`). Automated alert issues (`production-alert.yml` and
   kin) are acted on, not just counted: an alert nobody sweeps is a log
   line — pathfinder#15 sat unread 16 days before the first cadence run
   closed it.
4. **Production error sweep** — for each live app, pull the week's Vercel
   runtime errors (Vercel MCP or CLI); report new signatures and counts.
   In-stack observability, deliberately: no third-party error service
   (owner decision 2026-08-04).
5. **Guardrail drift** —
   - The four AGENTS.md paths resolve to one inode (`ls -laiL`); restore the
     symlinks if not.
   - Hooks registered: global repo-location guard, workspace done-gate and
     edited-marker (jq assertions against both settings.json files).
   - Model defaults: `~/.claude/settings.json` still `"model": "opus"` with
     `"effortLevel": "high"`; `~/.codex/config.toml` still frontier at high.
   - `gh auth status` healthy.
6. **Stray-repo sweep** — `.git` directories under `$HOME` outside
   `~/Projects` and client-internal zones; propose a safe move for any found.
7. **Trajectory review** — read the week's `~/Projects/.remember/` dailies
   plus `recent.md`, and memory `MEMORY.md`: repeated failures, permission
   friction, guardrail near-misses, workflow inefficiencies. Durable lessons
   are written to memory; improvement candidates go to the owner as a short
   list.
8. **Meta-snapshot** — run `snapshot.sh` in `windwardline/ops` (private):
   versions the canonical standards file, global and workspace agent config,
   hooks, and agent memory. Lands by PR; aborts on key-shaped content.
   Deliberately last: the review's own memory writes belong in the same
   week's snapshot (the first run had to snapshot twice to achieve this).

## First cadence of each month, additionally

- Dependabot alert counts per fleet repo (`gh api`), open items reported.
  Code-scanning has no data by design — the security workflows set
  `upload: never` — so don't query it.
- Owner dashboard reminders (checks only the owner can see): Anthropic Console
  spend and limits; Supabase backup posture; domain and certificate expiries.
