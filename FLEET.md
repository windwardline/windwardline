# The Fleet Standard

No single repository is the standard-bearer. Each repo led in some dimension and
lagged in others; a repo-as-standard drifts, gets retired, or excuses its own
gaps. The standard is therefore this document plus the machinery that enforces
it. Repos conform to the standard; the standard does not live in any of them.

## Provenance — where each piece came from

The standard is a composite. Credit where each dimension originated, and what
enforces it now:

| Dimension | Origin | Enforced by |
|---|---|---|
| Security scan mechanics (Semgrep, gitleaks, OSV) | pathfinder `security.yml` | `security.yml` in every repo; scan jobs are required checks |
| Live posture verification (prod headers) | levelflow `deploy.yml` polling | `Headers live` job (push + daily cron) in every prod-facing repo |
| Test-enforced design contracts | craft (palette/contrast tests) | Each repo's own suite; pattern replicated in header contract tests |
| TDD law and run-capture evidence | timeshift | Repo operating contracts |
| Spec governance (§-law amendments) | levelflow | Repo operating contracts |
| Dependency quarantine and trust policy | pathfinder `pnpm-workspace.yaml` | Repo-local policy files; Dependabot fleet-wide |
| Deliberate minimalism (no-live-fetch CI, strict CSP) | portfolio, proper-form | Repo operating contracts |
| Merge gating (green CI, linear history, auto-merge) | fleet-wide 2026-07-27 | `main-requires-green-ci` rulesets |
| Advisory frontier-model review | this repo's `claude-review.yml` | Caller workflow in every repo |

## The standard — every fleet repo

- `AGENTS.md` operating contract (purpose, stack, commands, gates, laws) and
  `CLAUDE.md` containing exactly `@AGENTS.md`.
- `LICENSE` and `SECURITY.md` (house forms; security scope names the repo's own
  domain).
- `.github/dependabot.yml` (house form), with the repository's Dependabot
  security-alerts AND automated-security-fixes settings enabled. Three
  independent switches, all required: the file drives scheduled version PRs,
  alerts surface advisories, automated fixes open the fix PRs. Both toggles
  were silently off on five repos until the first cadence run caught it —
  the account is personal, so GitHub's auto-enable-for-new-repos default is
  dashboard-only; the checker is the guarantee, not the default.
- `vercel.json` carrying the house seven-header set explicitly
  (Content-Security-Policy, Strict-Transport-Security, X-Content-Type-Options,
  Referrer-Policy, X-Frame-Options, Permissions-Policy,
  Cross-Origin-Opener-Policy) — at the repo root, or the app directory in a
  monorepo. Explicit always; never rely on platform-injected headers.
- `.github/workflows/ci.yml` — the repo's real gates.
- `.github/workflows/security.yml` — Semgrep CE + Secret scan on PRs, pushes,
  weekly cron; plus `Dependency scan / osv-scan` when the repo has a lockfile;
  plus `Headers live` when it serves a production domain. **No job in it may
  carry a `github.actor != 'dependabot[bot]'` guard.** Semgrep CE held one
  until 2026-08-11: it is a required check, GitHub counts a skipped required
  check as satisfied, so it reported green without running on precisely the
  PRs that merge unattended — verified on mimic#35, whose rollup reads
  `Semgrep CE SKIPPED` beside three green siblings, merged. The guard bought
  nothing; the job runs in a pinned container with `persist-credentials:
  false` and reads no secret. The checker asserts the guard stays gone.
- `.github/workflows/claude-review.yml` — the thin caller of this repo's
  reusable (`@main`, deliberate: one merge updates every repo), passing
  `CLAUDE_CODE_OAUTH_TOKEN`.
- `.github/workflows/dependabot-auto-merge.yml` — byte-identical fleet-wide,
  and verified so: the canonical copy is `templates/dependabot-auto-merge.yml`
  in this repo, and the checker compares git blob SHAs rather than asking
  whether a file is present. It decides what merges unattended, so presence
  is not evidence — the same reasoning as reading the cooldown value below.
  green `semver-patch` and `semver-minor` Dependabot updates merge without a
  human, majors never (they stay deferred and tracked per repo). The soak that
  makes it safe is `cooldown: default-days: 7` on every update lane of
  `dependabot.yml` above: a release sits on the registry a week before a PR
  exists. `--auto` merges only on green required checks and bypasses no gate;
  security updates are exempt from cooldown by design and gate identically.
  `on: pull_request`, never `pull_request_target` — the permissions key has
  been honored on Dependabot-triggered runs since 2021-10-11, so the latter
  buys nothing while handing a write token to a mutated manifest. Without this
  lane the weekly batch simply accumulates: run six found nine mergeable PRs
  that nothing would ever land, none old enough to trip a staleness flag.
  **The credential upgrades itself.** With `FLEET_AUTOMERGE_APP_ID` and
  `FLEET_AUTOMERGE_PRIVATE_KEY` present as *Dependabot* secrets (Actions
  secrets are invisible to Dependabot-triggered runs), the lane mints a GitHub
  App installation token; without them it falls back to `GITHUB_TOKEN`. The
  difference is not cosmetic: a push attributed to `GITHUB_TOKEN` creates no
  workflow run at all, so on the fallback path an auto-merged commit does not
  fire the post-merge `Headers live` probe. Each run's summary states which
  credential it used, because a silent fallback is indistinguishable from
  success. The App landed 2026-08-11 and every fleet repo now runs on it,
  proven rather than assumed: pathfinder#61 merged through the lane and its
  merge commit fired `CI` and `Security analysis` on `main` three seconds
  later — runs that a `GITHUB_TOKEN` merge would not have produced at all.
- Repository settings: auto-merge enabled; `main-requires-green-ci` ruleset
  requiring every PR-running CI and scan job by name; linear history; no bypass
  actors.
- `CLAUDE_CODE_OAUTH_TOKEN` actions secret — the review lane's only
  credential. Reviews bill the owner's Max subscription; API-key billing is
  fully retired (Console key revoked 2026-08-08; the vestigial `apikey` gate
  branch and every caller's `ANTHROPIC_API_KEY` pass-through were removed
  2026-08-09). Reviews skip cleanly without the token; fork PRs never
  receive it by design.
- Action pins that say what they are. Every third-party `uses:` in a workflow is
  pinned to a full commit SHA and carries a trailing comment naming an immutable
  tag that SHA actually carries — `# v7.0.1`, never a floating major (`# v7`).
  The comment is the only human-readable version signal when a Dependabot bump
  rewrites forty hex characters, so a wrong one reads as a downgrade and hides a
  real one. It fails two ways, both live on 2026-08-11: twelve repos carried
  `# v6` beside a SHA tagged v7.0.1, and two more named major aliases that were
  accurate when written and had since moved off the pinned commit. Naming the
  patch tag closes the second path — an immutable tag cannot drift. Same-owner
  `@main` refs are deliberate (above) and outside this rule.

App-class repos (a `package.json` at root) additionally: `typecheck` (or
`check`), `lint`, and single-shot test scripts; a committed lockfile
(`package-lock.json`, `pnpm-lock.yaml`, or equivalent); a contract test
enforcing the header set. An app that collects any user data serves a
`/privacy` page in the house form — what is kept, every processor named,
retention, deletion contact — linked from the surface where collection
happens (enforced by repo contracts and the review lane; precedents:
pathfinder `/privacy`, levelflow's legal panel, timeshift `/privacy`).

## Preferred stack

The default stack for every project. Deviations follow the protocol below —
never silent adoption.

| Layer | Default | Recorded alternates |
|---|---|---|
| Database / backend | Supabase (org "Windward Line") | Neon via the Vercel Marketplace where it fits (precedent: pathfinder) |
| Hosting | Vercel | — |
| DNS / edge | Cloudflare (Windward Line account) | — |
| Source | GitHub `windwardline` | — |
| AI inference | Groq (the `openai` SDK pointed at Groq is the house client) | Better-fit provider with owner approval |
| Email | Resend on `windwardline.com` | — |
| Automation | Zapier | — |

**Deviation protocol:** an agent recommending a genuinely better option must put
the question to the owner *before* adopting anything — never adopt silently. An
approved deviation is recorded in that repo's `AGENTS.md` as a line beginning
`Stack exception (owner-approved YYYY-MM-DD):` with the reasoning. The
conformance checker fails any detectable deviation without a recorded approval,
and the review lane holds every PR diff against this table.

## Exceptions register

| Repo | Exception | Why |
|---|---|---|
| `windwardline` (this repo) | No CI on its own content; PRs merge manually. Hosts the fleet reusable, this standard, and the conformance checker — its workflows gate the fleet, never itself. | Meta/standards home |
| `venture` | Outside the fleet standard entirely | Private venture outside the Windward Line family |
| `fleet-template` | No CI, no ruleset, placeholders by design | The seeding template; the checker, not the template, is the authority |
| `ops` | No CI, no ruleset; snapshots land by PR, merged manually | Private meta-layer archive (canonical standards file, agent config, hooks, memory) — holds no application code |

This register is mechanized: the conformance checker's exemption list mirrors it
exactly, and everything else under the account is checked by default. Adding an
exception means amending this table and the checker in the same change set.

## Enforcement pathways

1. **`scripts/fleet-conformance.sh`** (this repo) — deterministic checker. It
   derives the fleet live from the GitHub account (every non-archived,
   non-template repo minus the exceptions register), so a new repo is in scope
   the moment it exists — inclusion is the default, exemption is the explicit
   act — and it refuses a vacuous pass if enumeration returns nothing. Per repo
   it verifies each item above, including ruleset depth (linear history rule
   present, zero bypass actors), the Dependabot cooldown value rather than the
   file's mere presence, and required-checks completeness: every successful job
   from the latest merged PR's pull_request-triggered workflow runs must be a
   required context, with the advisory review and the auto-merge job excluded —
   dispatch and schedule runs against the same commit are not part of the
   sample. It then runs `scripts/verify-action-pins.sh`, which resolves every
   third-party action pin against the tags its SHA really carries, dereferencing
   annotated tags. That sweep is deliberately wider than the fleet above — it
   covers the exempted repos too, because this repo's own review lane held one
   of the two original rot cases and `fleet-template` is how a bad comment would
   reach every repo created after it. Prints a per-repo table and exits
   non-zero on any drift. Run it from any machine with `gh` authenticated.
   Scheduled execution rides pathway 6.
2. **Rulesets** hold the merge gates; converting or creating a repo never drops
   a check it already required.
3. **The review lane** holds diffs against each repo's operating contract on
   every PR.
4. **The done-gate** (workspace Stop hook) holds local sessions to
   typecheck + lint + tests before they may finish.
5. **New repos** start from `windwardline/fleet-template` and must pass the
   conformance checker before first release. The checker, not the template,
   is the authority — a template can go stale; the checker is run against
   the standard as written here.
6. **The weekly fleet-health cadence** — `CADENCE.md` (this repo), executed by
   a Claude Code scheduled task every Monday 09:00 ET: conformance run,
   Actions failure sweep, guardrail-drift audit, stray-repo sweep, meta-layer
   snapshot to the private `ops` repo, and trajectory review. The checklist is
   versioned; the task is only the trigger.

Changing this document is changing the fleet standard: land it by PR here, then
make the conformance checker agree with it in the same change set.

## Closure rule (owner-ruled 2026-08-04)

Any fleet-wide improvement — a gap fix from the agentic-workflow backlog, a
newly identified standard, a practice one repo pioneers — is **closed only when
all four hold**: codified in this document; enforced by the conformance checker
or another named pathway above; applied to every existing fleet repo; and seeded
into `fleet-template` for future repos. This applies retroactively to gaps 1–3
(contracts, done-gate, security + review lanes — all four conditions verified
2026-08-04) and prospectively to every remaining and future gap.
