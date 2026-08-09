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
   the checker), two views over runs with `event != pull_request`. The action
   list is the **latest run per workflow**: group by `workflow_id`, take the
   newest, report the ones not green — that is what is broken now. The window
   view (runs since the previous Monday with `conclusion == failure`) is
   context only, and any entry a later green run of the same workflow
   supersedes is reported as resolved, not as a finding. Push and cron
   failures (weekly Semgrep, Headers live) surface nowhere else. Report
   workflows examined alongside failures found, so a clean sweep is visibly
   "looked at 44, found 1". Run two swept window-only and produced 10
   findings of which 9 were already fixed hours earlier the same day.
3. **Open-issue and open-PR sweep** — enumerate open issues across every
   fleet repo (`gh issue list`). Automated alert issues
   (`production-alert.yml` and kin) are acted on, not just counted: an
   alert nobody sweeps is a log line — pathfinder#15 sat unread 16 days
   before the first cadence run closed it.
   Then open PRs, same reasoning: enumerate them across every fleet repo
   **plus `windwardline` and `ops`**, and flag anything older than seven
   days. The no-CI repos are the structural accumulators — everywhere else
   `--squash --auto` lands work by itself, but these two need a human, and
   nothing else watches that gap: run three found the guardrail-drift pair
   stalled since 2026-08-08 while the daily log recorded it as shipped.
   Authored is not landed — a `.remember/` daily saying work is done is not
   evidence it merged; verify against the default branch. Distinguish
   deliberately parked drafts (craft#5, the Lighthouse gate held until two
   studies clear 95) from stalled work. Report PRs examined alongside
   stalled found, so a clean sweep is visibly "looked at N, found 0".
4. **Production error sweep** — for each live app, pull the week's Vercel
   runtime errors (Vercel MCP or CLI); report new signatures and counts.
   In-stack observability, deliberately: no third-party error service
   (owner decision 2026-08-04). A zero is only reportable with a probe
   showing the pipeline returns rows — group runtime logs by status code on
   at least one live app — or "no errors" and "no telemetry" read alike.
   Runtime-log retention is one day on Pro; the errors table holds seven.
5. **Guardrail drift** — two scripts, then two checks with no script.
   - Permission surface: `scripts/permission-audit.sh` (this repo) exits
     clean — no interpreter or task-runner wildcards on standing allow,
     credential reads ask-gated, no fence-defeating local wildcards, no
     connection-string material in any settings file, house skills present.
     Absolute rules: it asks whether the surface is safe, not whether it moved.
   - Change detection: `guardrail-drift.sh` in `windwardline/ops` (private)
     exits 0. It asserts the model defaults for the two file-backed clients
     (`~/.claude/settings.json` at `"opus"`/`"high"`, `~/.codex/config.toml`
     frontier at high) and diffs the permission sets, registered hooks, and
     Codex project trust against the last committed snapshot. Exit 1 is an
     invariant violation or a missing baseline; 2 is drift to report. It
     catches the widening the audit cannot — a rule nobody has named as
     forbidden, a removed `deny`, a disarmed hook. **Run it here, at step 5.**
     After step 8 the snapshot has overwritten the baseline with the current
     state, and the check compares the live config against itself.
   - The four AGENTS.md paths resolve to one inode (`ls -laiL`); restore the
     symlinks if not.
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
   week's snapshot (the first run had to snapshot twice to achieve this), and
   step 5's drift check reads the baseline this step replaces.

## Known-benign reds

Failures that recur by design. Confirm the stated condition still holds, then
move on — do not re-investigate from scratch each week.

- **pathfinder Dependabot security updates for `postcss` and `brace-expansion`**
  fail `security_update_not_possible`. Dependabot resolves declared ranges and
  cannot see pnpm `overrides`; `pnpm-workspace.yaml` already forces the whole
  tree to the non-vulnerable releases. The check that it is still benign is
  open Dependabot alerts = 0.

## First cadence of each month, additionally

- Dependabot alert counts per fleet repo (`gh api`), open items reported.
  Code-scanning has no data by design — the security workflows set
  `upload: never` — so don't query it.
- Owner dashboard reminders (checks only the owner can see): Anthropic Console
  spend and limits; Supabase backup posture; domain and certificate expiries;
  the two UI-managed clients hold the frontier model — ChatGPT's default set
  to the frontier (not Auto) and Antigravity's model confirmed in-app,
  especially after client updates. (Claude and Codex are file-checked in
  step 5 weekly; these two cannot be.)
