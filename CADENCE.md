# Weekly fleet-health cadence

Fires every Monday 09:00 ET as a Claude Code scheduled task. This file is the
checklist the task executes; the task is only the trigger. Changing the cadence
is a PR here. Results are reported in-chat as tables — drift first,
owner-decision items last. Its eight steps are the complete pathway named by
`FLEET.md`; neither document maintains a shorter substitute list.

## Every week

1. **Conformance** — run `scripts/fleet-conformance.sh` (this repo). Mechanical
   drift is fixed same-day by the standing flow; anything requiring judgment
   goes to the owner with a proposed fix.
2. **Actions failure sweep** — for every non-archived repository under the
   account, templates and checker exceptions included, two views over runs with
   `event != pull_request`.
   **Fetch the corpus with `--paginate`, and prove it covers the window.**
   `per_page=100` sets a page size, not a result set: without `--paginate`
   `gh api .../actions/runs` returns one page and stops. Run nine fetched
   626 runs that way instead of 2,183 — pathfinder alone went from 95 to 915 —
   and the window view showed 4 failures where there were 12. Nothing errored
   and no list was empty; the busiest repos, which are the likeliest to be
   broken, simply lost the most history. `--paginate` alone is still not
   enough: the Actions API caps at 1,000 runs however you page it, and both
   levelflow-cloud and pathfinder hit that ceiling, leaving levelflow's window
   starting 08-18 when it needed 08-17. Re-fetch any repo that lands on a round
   cap in day-sliced `created=` ranges (URL-encode the comparison —
   `created=%3E%3D2026-08-17`), union, and dedupe by run `id`. Report the corpus
   size and per-repo counts, and assert the oldest `created_at` returned
   actually predates the window start — that is the only direct evidence the
   window is covered. Every rule below reasons over whatever this fetch
   returned, so all of them stay internally consistent on a truncated
   population and produce a confident clean report. The action
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
   confident clean report, so it costs more than a missed check.
   **A workflow with more than one cron fans out the same way, and job
   identity is then the set of jobs that did not skip.** A conformant
   `security.yml` carries two schedules. The exact weekly path at
   `17 9 * * 1` admits Semgrep and Secret scan. The daily path at
   `17 13 * * *` admits `Dependency scan` plus `Headers live` where present.
   Semgrep and Secret scan skip only the daily trigger. Dependency scan has no
   schedule guard, so it also runs in the weekly invocation; its required paths
   are pull request, push, and daily because its advisory input changes without
   a commit. `Headers live` runs after merge on push and on the daily schedule;
   it is never a pull-request ruleset requirement.
   The checker proves a daily cron reaches live work. `craft` remains the dated
   hold: its dependency job is still weekly-guarded, so its daily Headers-only
   success cannot supersede its weekly dependency result. Run seven found that
   weekly scan failing at 09:56Z with a Headers-only success at 13:51Z the same
   day. Two runs that executed different job sets are not comparable, and the
   later cannot supersede the earlier. Read the jobs, not the run conclusion: a
   green run is evidence only for the jobs it executed. Push and cron failures
   (weekly Semgrep and Secret scan; push and daily Headers live) surface nowhere
   else. Report
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
   non-archived repository under the account, templates and checker exceptions
   included. Automated alert issues
   (`production-alert.yml` and kin) are acted on, not just counted: an
   alert nobody sweeps is a log line — pathfinder#15 sat unread 16 days
   before the first cadence run closed it.
   Then open PRs across that same derived population and flag anything older
   than seven days. Re-derive which repos have no CI on each run; they are the
   structural accumulators because `--squash --auto` cannot land their work.
   Nothing else watches that gap: run three found the guardrail-drift pair
   stalled since 2026-08-08 while the daily log recorded it as shipped.
   Authored is not landed — a `.remember/` daily saying work is done is not
   evidence it merged; verify against the default branch. Distinguish
   deliberately parked drafts (craft#5, the Lighthouse gate held until two
   studies clear 95) from stalled work. Report PRs examined alongside
   stalled found, so a clean sweep is visibly "looked at N, found 0".
   **Dependabot PRs changed shape on 2026-08-11.** In every CI-bearing,
   non-exempt repo, green patch and minor updates now land themselves, so an
   open Dependabot PR is no longer a backlog item — it is a **hold**, and the
   hold is the finding. Read the
   auto-merge run's step summary for the reason: a maintainer change on the
   released package, a pre-1.0 version, a major (labelled `deferred-major`),
   an unrecognised update type, or the `no-automerge` label. A maintainer
   change in particular is the signature the lane exists to stop at, so it is
   read the week it appears, not counted. Every CI-bearing repo outside the
   exceptions register is in the lane. Levelflow-cloud joined when the GitHub
   App landed the same evening. Run six's nine-PR pile-up is what closed this
   gap — none of them was stale enough to trip the seven-day flag.
   **A repaired credential does not retroactively unblock the PRs held behind
   it.** The lane fires on pull_request events; a secret corrected afterwards
   changes nothing until something re-runs. Run eight found three levelflow-cloud
   PRs still red on lane runs that predated the owner's fix by two hours — a
   `gh run rerun` merged the first on the spot. When a lane failure traces to a
   credential, check the secret's `updated_at` against the run, and re-run
   rather than report the hold.
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
   exactly how the breakage run four found stayed invisible —
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
5. **Guardrail drift** — five scripts, then two checks with no script.
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
   - Agent exit status: `agent-exit-status.sh` in `windwardline/ops` (private)
     exits 0. launchd records a job's exit code and tells nobody, so a failing
     background job stays invisible until someone asks. On 2026-08-17 six
     non-Apple agents carried a non-zero last exit and none had produced a
     signal — `homebrew-autoupdate` among them, whose `&&` chain broke at a
     cask needing sudo, so `brew cleanup` never ran and its cache reached
     3.3 GB. It separates FAILING (ran, exited non-zero) from ORPHAN (a plist
     whose program does not exist, which cannot run and therefore never looks
     broken), and checks scheduled-job freshness and the updater lock. Exit 1 a
     job is failing, 2 orphans or staleness only. It runs daily from
     `windwardline-toolchain-update` and writes the status line the SessionStart
     hook surfaces; this is the weekly backstop.
   - MCP health: `mcp-health.sh` in `windwardline/ops` (private) exits 0. It
     asserts that MCP **works**, where drift detection only asserts it is
     unchanged — a config that is broken and stable passes a sameness check
     every week, which is exactly how every prior MCP repair decayed unseen
     (diagnosed 2026-08-16: an Antigravity bundle patch erased by an app
     update, five servers unpinned to `http-only` and hanging 60s+, a shadow
     registry no client reads, and a daily updater wedged on a stale lock while
     reporting exit 0). It checks transport pinning, that every stdio command
     resolves under the **GUI PATH** rather than the shell's, that no registry
     carries a literal auth header, and that no vendor app bundle has been
     patched. It never launches a server: doing so would write to the OAuth
     stores it exists to protect. Exit 1 invariant, 2 drift. It also runs daily
     from `windwardline-toolchain-update`, so detection does not depend on this
     cadence being executed.
   - Exact service baseline: `service-baseline-check.py` in `windwardline/ops`
     (private) exits 0. It verifies that all six supported client surfaces
     expose exactly Zapier, Stripe, FMP, Vercel, GitHub, Supabase, Neon through
     Vercel, Cloudflare, Aviationstack, Groq, and Resend: no missing route,
     duplicate route, or extra business integration. Static registries,
     read-only CLI status, and Keychain attribute checks are collected live;
     UI-only client inventories require complete attestations no older than 14
     days. Exit 1 is an invariant violation; 2 is missing or stale evidence.
     The checker never launches an MCP server, starts OAuth, or reads a secret.
   - The four AGENTS.md paths resolve to one inode (`ls -laiL`); restore the
     symlinks if not.
   - `gh auth status` healthy.
6. **Stray-repo sweep** — `.git` directories under `$HOME` outside
   `~/Projects` and client-internal zones; propose a safe move for any found.
7. **Trajectory review** — read the week's dailies plus `recent.md`, and memory
   `MEMORY.md`: repeated failures, permission friction, guardrail near-misses,
   workflow inefficiencies. Durable lessons are written to memory; improvement
   candidates go to the owner as a short list.
   **The record is per project, not one directory.** `remember` writes into
   `<PROJECT_DIR>/.remember`, so a session in `~/Projects/levelflow-cloud`
   rolls up there and never touches `~/Projects/.remember`. Reading only the
   workspace root is how run nine reviewed a week in which levelflow-cloud
   logged 643 non-PR workflow runs and pathfinder 915, off a root whose newest
   daily was five days old — the evidence existed, in directories the review
   did not open. Enumerate `~/Projects/.remember` **and**
   `~/Projects/*/.remember`, and read whichever have moved this week. A quiet
   root is not a quiet week.
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
  the UI-managed clients hold the frontier model — ChatGPT's default set to
  the frontier (not Auto) and Gemini Code Assist's model confirmed in-app,
  especially after client updates. (Claude and Codex are file-checked in
  step 5 weekly; these cannot be.)
