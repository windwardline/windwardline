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
   list is the **latest run per workflow job**: group by
   `(workflow_id, job identity)`, take the newest, report the ones not green —
   that is what is broken now. The window
   view (runs since the previous Monday with `conclusion == failure`) is
   context only, and any entry a later green run of the same workflow job
   supersedes is reported as resolved, not as a finding.
   **Group by job, never by `workflow_id` alone.** A later green run
   supersedes a red one only if it re-did the same work, and fan-out
   workflows break that assumption: Dependabot's `dynamic` workflow emits
   one run *per ecosystem* under a single `workflow_id`, and matrix and
   per-directory workflows fan out the same way. For Dependabot the job
   identity is the leading token of `display_title` (`npm_and_yarn in /.`
   vs `github_actions in /.`). Run five swept 49 workflows, reported
   0 not-green, and both views hid the run's only real finding —
   pathfinder's `npm_and_yarn` failure at 13:12 was masked by its
   `github_actions` success at 13:36. It surfaced only because the window
   list was read by eye. This failure mode turns a real red into a
   confident clean report, so it costs more than a missed check. Push and cron
   failures (weekly Semgrep, Headers live) surface nowhere else. Report
   workflows examined alongside failures found, so a clean sweep is visibly
   "looked at 44, found 1". Run two swept window-only and produced 10
   findings of which 9 were already fixed hours earlier the same day.
   For event-driven workflows and error-table entries, supersession by a
   later green run is unavailable — a `dynamic` workflow fires only when
   its trigger matches again, and an error-table row is not a run at all.
   For those, establish resolution from state — the config, the alert
   count, the merged commit — before reporting the item as broken. Run
   four's two cases: mimic `Dependabot Updates` (Aug 8, `pdfjs-dist`) had
   no later run to supersede it, but `dependabot.yml` on main carried no
   ignore blocks and open alerts were 0 — resolved in state; pathfinder
   health `CONNECT_TIMEOUT` was an error-table entry whose last occurrence
   predated the merged `HEALTH_RETRY_DELAY_MS` retry, with the next 8
   scheduled `Production health` runs green — resolved in state.
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
   **Dependabot PRs changed shape on 2026-08-11.** Green patch and minor
   updates now land themselves, so an open Dependabot PR is no longer a
   backlog item — it is a **hold**, and the hold is the finding. Read the
   auto-merge run's step summary for the reason: a maintainer change on the
   released package, a pre-1.0 version, a major (labelled `deferred-major`),
   an unrecognised update type, or the `no-automerge` label. A maintainer
   change in particular is the signature the lane exists to stop at, so it is
   read the week it appears, not counted. levelflow-cloud is excluded from
   the lane by FLEET.md's register; its Dependabot PRs still merge by hand
   and remain ordinary backlog. Run six's nine-PR pile-up is what closed this
   gap — none of them was stale enough to trip the seven-day flag.
4. **Runtime error sweep, environment-aware** — for each live app, pull the
   week's Vercel runtime errors (Vercel MCP or CLI); report new signatures
   and counts. The errors table mixes production and preview in one view
   and `get_runtime_errors` takes no environment parameter, so attribute
   every signature to an environment before counting it — from the row's
   branch/deployment metadata, or via `get_runtime_logs`, which does take
   `environment` (`production` | `preview`). Report the two environments
   separately: production errors are the primary finding; preview errors
   are still findings — lower severity, own table row, never dropped and
   never mixed in. Both are swept because a production-only reading is
   exactly how the breakage run four found on timeshift stayed invisible —
   every preview deployment 500ed on `/` (missing Preview-scope env vars)
   while builds reported Ready and production read clean. A green build is not a
   rendering page, and "N projects clean" claimed off a mixed or
   production-only view is not a clean sweep.
   In-stack observability, deliberately: no third-party error service
   (owner decision 2026-08-04). A zero is only reportable with a probe
   showing the pipeline returns rows — group runtime logs by status code on
   at least one live app, in the environment being cleared — or "no errors"
   and "no telemetry" read alike.
   Runtime-log retention is one day on Pro; the errors table holds seven.
5. **Guardrail drift** — two scripts, then two checks with no script.
   - Permission surface: `scripts/permission-audit.sh` (this repo) exits
     clean — no interpreter or task-runner wildcards on standing allow,
     credential reads ask-gated, no fence-defeating local wildcards, no
     connection-string material in any settings file, house skills present,
     and — since 2026-08-11 — `~/.claude/settings.local.json` in scope. That
     file overrides the global settings for every session in every directory
     and was scanned by nothing until then; it was dated 15 July and held ten
     forbidden grants, a keychain read among them, defeating the very ask
     fence this audit asserts two checks earlier. Depth is 5 so a
     settings.local.json inside a git worktree is not invisible either,
     both machine guard hooks registered (repo-location PreToolUse,
     settings-hygiene SessionStart — the latter strips forbidden local
     grants same-day; this audit is its weekly backstop).
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

## Expected absences

Runs that are *supposed* not to exist. Their absence is not drift, and a sweep
that reports it as a finding is misreading the fleet.

- ~~No `on: push` run after an auto-merged Dependabot commit.~~ **Retired
  2026-08-11.** True only while the lane ran on `GITHUB_TOKEN`. It now mints a
  GitHub App installation token, whose merges fire push workflows normally —
  verified on pathfinder#61, whose merge produced `CI` and `Security analysis`
  runs on `main` three seconds later. A missing push run after an auto-merge is
  now a **real finding**: check the lane run's summary, which names the
  credential it used, and treat `credential: GITHUB_TOKEN` as the drift.
- **`dependabot-auto-merge` reporting `skipping` on human PRs.** That is the
  job guard working. It succeeds only on Dependabot PRs, which is also why
  the conformance checker excludes it from the required-checks audit.

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
