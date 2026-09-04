# The Fleet Standard

No single repository is the standard-bearer. Each repo led in some dimension and
lagged in others; a repo-as-standard drifts, gets retired, or excuses its own
gaps. The standard is therefore this document plus the machinery that enforces
it. Repos conform to the standard; the standard does not live in any of them.

**Precedence, so three documents cannot each claim the last word.** Every repo's
`AGENTS.md` opens by noting that the machine's global `~/AGENTS.md` still
applies, and now also cites this document — three texts an agent may hold at
once. They rank, and they do not compete:

- The global `~/AGENTS.md` is the cross-tool contract every client on the
  machine reads (Claude, Claude Code, Codex, Gemini — one file, four symlinked
  paths). Its machine-level laws — credential handling, where repos may live,
  what may never be published — bind everywhere and are not overridable by a
  repo or by this document.
- For the WORKING METHOD the global contract **delegates here**: it states that
  this document's CONVERGE section "binds every agent on every project,
  including repos outside the fleet." So on CONVERGE there is no conflict to
  resolve — the global contract carries the pointer, this file carries the
  method, and a new project is covered by the pointer before it has a repo to
  conform.
- A repo's own `AGENTS.md` adds specifics — its stack, gates, and laws — and
  may narrow but never weaken either. Where its summary of this document and
  this document differ, this document governs.

## Provenance — where each piece came from

The standard is a composite. Credit where each dimension originated, and what
enforces it now:

| Dimension | Origin | Enforced by |
|---|---|---|
| Security scan mechanics (Semgrep, gitleaks, OSV) | pathfinder `security.yml` | `security.yml` in every repo; scan jobs are required checks |
| Live posture verification (prod headers) | levelflow `deploy.yml` polling | Exact `Headers live` or registered managed-edge job on post-merge push + daily cron in every prod-facing repo; never a PR-required check |
| Test-enforced design contracts | craft (palette/contrast tests) | Each repo's own suite; pattern replicated in header contract tests |
| TDD law and run-capture evidence | fleet-wide | Repo operating contracts |
| Spec governance (§-law amendments) | levelflow | Repo operating contracts |
| Dependency quarantine and trust policy | pathfinder `pnpm-workspace.yaml` | Repo-local policy files; Dependabot fleet-wide |
| Deliberate minimalism (no-live-fetch CI, strict CSP) | portfolio, proper-form | Repo operating contracts |
| Merge gating (green CI, linear history, auto-merge) | fleet-wide 2026-07-27 | `main-requires-green-ci` rulesets |
| Advisory frontier-model review | this repo's `claude-review.yml` | Caller workflow reports semantic findings; deterministic gates and contracts enforce |

## The standard — every fleet repo

- `AGENTS.md` operating contract (purpose, stack, commands, gates, laws) and
  `CLAUDE.md` containing exactly the 11 bytes `@AGENTS.md\n`: one line, one
  trailing LF, no second contract before or after it.
- `LICENSE` and `SECURITY.md` (house forms; security scope names the repo's own
  domain).
- `.github/dependabot.yml` (house form), with the repository's Dependabot
  security-alerts AND automated-security-fixes settings enabled. Three
  independent switches, all required: the file drives scheduled version PRs,
  alerts surface advisories, automated fixes open the fix PRs. Both toggles
  were silently off on five repos until the first cadence run caught it —
  the account is personal, so GitHub's auto-enable-for-new-repos default is
  dashboard-only; the checker is the guarantee, not the default. Every live
  update lane carries exactly one `cooldown.default-days` value of at least
  seven. The checker parses each lane separately and aborts if the live lane
  population is empty; global line counts cannot let one lane's duplicate
  value stand in for another lane's missing one. `version: 2`, lane identity,
  schedule interval, and cron shape are structural. A valid
  `open-pull-requests-limit: 0` is drift because it disables that lane; syntax
  that parses is not proof that updates can run.
- `vercel.json` carrying the house seven-header set explicitly on exactly one
  catch-all `/(.*)` route
  (Content-Security-Policy, Strict-Transport-Security, X-Content-Type-Options,
  Referrer-Policy, X-Frame-Options, Permissions-Policy,
  Cross-Origin-Opener-Policy) — at the repo root, or the app directory in a
  monorepo. Auxiliary cache or asset routes may coexist; headers split among
  narrower routes do not satisfy the catch-all. Explicit always; never rely on
  platform-injected headers. An inert `vercel.json` retained as a policy
  artifact is not operational evidence that Vercel serves the application. It
  cannot erase live evidence of alternate hosting or replace a required,
  owner-approved stack exception.
- `.github/workflows/ci.yml` — the repo's real gates.
- `.github/workflows/security.yml` — Semgrep CE + Secret scan on pull requests,
  pushes, and the exact weekly cron; those jobs skip the daily trigger.
  `Dependency scan / osv-scan` runs on pull requests, pushes, and a **daily**
  cron when the repo has a lockfile. It has no schedule guard, so the weekly
  workflow invocation reaches it too. `Headers live` runs on pushes and the
  daily cron when the repo serves a production domain; it never joins the
  pull-request ruleset. Each cron comment
  names the jobs that cron actually runs:
  the daily one read "Headers live probe only" for a day after the dependency
  scan joined it. The checker now proves both halves: every live reusable OSV
  job has a daily cron, and every declared daily cron reaches at least one job
  with a provably live schedule path, including its `needs` chain. A daily
  schedule on which every job skips is drift. The expected scan population and
  each OSV job's exact lockfile paths are derived independently from every
  recognized lockfile at any path in the default-branch tree; zero
  expected repositories abort, and deleting an OSV job from one of them is
  drift rather than a way to leave the measured population. Dependabot's
  enabled ecosystem/directory lanes are derived from that same set, plus the
  one root GitHub Actions lane; cooldown days are strict integers of at least
  seven. A production repo
  is derived from the one concrete, non-placeholder HTTPS origin in its live
  `SECURITY.md`. Each derived origin either uses the canonical header probe or
  appears as the exact full row in the managed-edge register below. Deleting an
  origin and its probe therefore cannot
  shrink both the subject and its measurement to green: canonical header
  probes plus managed-edge probes must equal the independently derived
  production population. `Headers live` is one 12-minute job with one step,
  named exactly `Assert the seven security headers on production` and calling
  `windwardline/windwardline/actions/verify-live-headers@<current release SHA>`,
  with a literal `url:` equal to that origin and no inline replacement. **The
  step name is part of the shape, and this document did not say so until
  2026-08-31.** The checker began requiring it, `templates/` and the new-repo
  bootstrap were seeded with it, and the twelve repositories that already
  existed never received it — so every production repo in the fleet reported
  `headers-live-not-canonical` while its probe ran and passed. It survived
  because the checker's own harness fixtures carry the name: the mocked suite
  was green against a subject the fleet had never adopted, which is this
  standard's own defect — a gate reporting on something other than what it
  examined — reappearing inside the machinery built to catch it. A fixture is
  not a population. The shared
  action waits for push deployment propagation, retries bounded GET probes,
  accepts only a final 200–399 response, and requires nonblank values for all
  seven headers. A redirect's headers cannot stand in for its final response.
  **No job in it may
  carry a condition that reads `github.actor`, `github.triggering_actor`, the PR
  user's login, or the event sender's login.** Trying to recognize only one
  spelling of `dependabot[bot]` is not a boundary: expression functions can
  construct the same value without that literal appearing in the file.
  Semgrep CE held one
  until 2026-08-11: it is a required check, GitHub counts a skipped required
  check as satisfied, so it reported green without running on precisely the
  PRs that merge unattended — verified on mimic#35, whose rollup reads
  `Semgrep CE SKIPPED` beside three green siblings, merged. The guard bought
  nothing; the job runs in a pinned container with `persist-credentials:
  false` and reads no secret. The checker asserts the guard stays gone.
  **`Dependency scan` carries no schedule guard either, and for a different
  reason.** Semgrep and Secret scan read repository content, which cannot
  change without a push, and both already run on every push and pull request —
  a weekly cron is enough for them. This job reads the advisory database, which
  changes with no commit at all, so it is the one job whose input moves while
  the repository sits still. It ran weekly until 2026-08-17: nanoid
  GHSA-2v37-7h3g-55p8 widened on the 13th, nothing looked again until the
  17th, and the daily run in between reported `success` having skipped every
  scan job. The checker rejects any job-level condition on a live dependency
  scan unless it is the dated `craft` hold; absence of one literal schedule
  expression is not proof that a push-only condition admits cron.
- **A gate states what it examined, and a gate that examined nothing fails.**
  The standing property behind several of the rules above. Six separate
  controls in this fleet have reported success without evaluating anything:
  Semgrep skipping itself on Dependabot PRs, the conformance checker reading a
  rate limit as "file missing", the auto-merge lane falling back to
  `GITHUB_TOKEN` in silence, an App ID that was present but not an integer, the
  daily scan skipping its scans, and a suppression whose expiry nothing read.
  Presence is not validity, and a green signal is not a signal that ran. So:
  report a count of what was inspected next to the count of what failed, treat
  a zero or absent count as failure rather than as a pass, and — when reading a
  workflow — ask which jobs *executed*, never what the run concluded.
- `osv-scanner.toml` — optional, and the only sanctioned way to hold the
  dependency-scan gate green over a finding that cannot be fixed. Every
  `[[IgnoredVulns]]` entry carries a `reason` for accepting the risk and an
  `ignoreUntil` date, because **an accepted risk that cannot expire is an
  unreviewed one**: at the expiry the gate fails again and the decision is
  made a second time, on that day's facts. The checker asserts both fields on
  every entry, requires the reason to be nonblank, and rejects a malformed,
  impossible, or already-past `ignoreUntil` calendar date — a lapsed date sitting
  in a file nobody reads is the exact failure this exists to prevent, and it
  is invisible until the scan happens to run. An entry suppresses a finding;
  it does not fix one, so it is written only where there is nothing to
  upgrade to. Precedent: grown-men-grow and craft, both for `extract-zip`,
  which has published no release since 2023. Never a blanket ignore, never an
  entry without a date.
- `.github/workflows/claude-review.yml` — the thin caller of exactly
  `windwardline/windwardline/.github/workflows/claude-review.yml@main`, the
  fleet's sole mutable `uses:` reference. The central ref is deliberate: one
  merge updates every caller. It passes `CLAUDE_CODE_OAUTH_TOKEN` and runs on
  eligible same-repo PR events only when
  `github.event.pull_request.user.login` — the PR author, stable across manual
  reruns — is not `dependabot[bot]` and `github.base_ref` equals
  `github.event.repository.default_branch`. Fork or missing-secret events skip.
  The reusable
  checks out this repo's `FLEET.md` at `main` into the review workspace before
  the action runs, so the no-egress sandbox can enforce the Preferred stack
  without an impossible network instruction.
- `.github/workflows/dependabot-auto-merge.yml` — byte-identical fleet-wide,
  and verified so: the canonical copy is `templates/dependabot-auto-merge.yml`
  on `windwardline/windwardline@main`, and the checker compares remote git blob
  SHAs rather than asking whether a file is present or trusting its local tree.
  A proposed-change test may inject a 40-hex SHA only through the printed test
  override. It decides what merges unattended, so presence
  is not evidence — the same reasoning as reading the cooldown value below.
  Green `semver-patch` and `semver-minor` Dependabot updates merge without a
  human; majors never merge. The lane is intended to label majors deferred and
  track them per repo, subject to the unresolved ordering decision recorded
  below. The soak that
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
  success. The App landed 2026-08-11. Pathfinder#61 proves that repo used it:
  it merged through the lane and its
  merge commit fired `CI` and `Security analysis` on `main` three seconds
  later — runs that a `GITHUB_TOKEN` merge would not have produced at all. The
  checker reads Dependabot's separate secret namespace and requires both exact
  names in every repo; an Actions-secret listing cannot prove the opaque values.
  The daily canary proves this repo's separate Actions-secret copies can mint an
  installation token, not that each repo's Dependabot-secret values are valid.
- Repository settings: auto-merge enabled; `main-requires-green-ci` ruleset
  active against `~DEFAULT_BRANCH` only, requiring every completed,
  non-skipped PR-running CI and scan job by name; strict up-to-date checking
  off; linear history; blocked force pushes through GitHub's separate
  `non_fast_forward` rule; no bypass actors. Cancelled jobs are completed and
  therefore sampled. Skipped jobs are not gate candidates, but their names are
  retained as evidence that a required context is a GitHub Actions job. Every
  required context must appear in that sampled Actions population and carry the
  live GitHub Actions App's `integration_id`. A matching context name from any
  other source cannot satisfy the rule. That binding structurally excludes
  external deploy-platform checks without a provider denylist. It proves the
  reporting App, not which workflow produced the status. GitHub still matches
  by job name; workflow path, trigger, and matrix identity are not part of the
  ruleset key. Duplicate job names within a sampled run are therefore drift,
  but App binding must never be described as workflow identity. The advisory
  review and auto-merge job are never required checks. Neither is `Headers
  live`: it remains mandatory on post-merge pushes and the daily schedule, but
  a deployment-propagation probe cannot gate the pull request whose merge
  produces that deployment.

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
  patch tag closes the second path — an immutable tag cannot drift. The exact
  review caller above is the sole mutable exception. Every other same-owner
  `uses:` is either a local `./` reference or is pinned to a full SHA; a
  same-owner SHA carries a version comment and is checked like any other pin.
  Docker-action syntax has no Git commit or release-tag namespace: a
  `docker://` reference is accepted only with a full lowercase OCI
  `sha256:<64 hex>` digest. Mutable Docker tags are forbidden, and no Git tag
  comment applies to a digest.
  Gated twice. At PR time by `actions/verify-action-pins` (this repo), carried as
  a **step** in each repo's already-required `Secret scan` job — a step adds no
  check name, so the gate landed in fourteen repos without touching a single
  ruleset. Fleet-wide after merge by the conformance checker, which also asserts
  an unconditional pinned `uses:` step remains inside the exact `Secret scan`
  job. A comment, another job, run-block text, or any step-level `if:` or
  `continue-on-error:` key cannot satisfy it. Nothing in a ruleset would notice
  the step being dropped.
  Both run the same script. The PR action reads the exact `github.sha` Git tree,
  with replacement refs disabled; an uncommitted workspace mutation cannot
  redefine what it audits. Tag discovery runs with repository and global Git
  rewrites disabled, and the exact first comment token must equal a real
  immutable tag. The checker also resolves this repo's newest semantic release
  and rejects callers pinned to any older one. The rule that blocks a merge is
  therefore the rule the fleet later measures against.

  `templates/claude-review.yml` is that same caller, byte for byte — the source
  every caller is seeded from and compared against — so the pin sweep exempts it
  under identical structural conditions: same job scope, same `review` job id,
  same exact ref. Nothing is widened by a character, and the file cannot drift
  under the exemption because the checker independently refuses to run unless
  that blob equals its reviewed behavior lock. Until 2026-08-31 this repository
  was the fleet's only pin-drift row, for carrying the file it hands to the other
  fourteen; a rule whose sole violator is the rule's own source is a population
  error, not a finding.

  The gate is pinned by SHA, not `@main`, and that is not incidental. A
  step-level `@main` reference trips this fleet's own
  `github-actions-mutable-action-tag` Semgrep rule — verified on
  windwardline-media#24, where `Secret scan` passed and `Semgrep CE` blocked the
  step carrying it. The review lane escapes that rule only because its `@main` is
  a job-level reusable workflow rather than a step. So the gate that enforces
  pinning is itself pinned, against a tag this repo now publishes; the weekly
  `github-actions` Dependabot lane plus the auto-merge lane carry patch and minor
  bumps fleet-wide without a human, which is what makes pinning cost nothing here.
  Releasing a new gate version means tagging this repo.

  Composite actions scrub hostile caller environments before invoking their
  subject. Loader variables whose behavior is activated by presence are never
  materialized as empty step variables: `LD_SHOW_AUXV` is omitted from the
  declared environment and unset before the first command. Release `v1.1.0`
  assigned it an empty value; glibc still emitted the auxiliary vector for every
  child process, corrupting command substitutions while the underlying audit
  itself passed. The action-manifest tests enforce the absence-plus-first-unset
  shape for every shared action.

App-class repos (a `package.json` at root) additionally: exact `typecheck` (or
exact `check`), `lint`, and `test` script keys with nonblank string values; a
committed lockfile
(`package-lock.json`, `pnpm-lock.yaml`, or equivalent); a contract test
enforcing the header set. An app that collects any user data serves a
`/privacy` page in the house form — what is kept, every processor named,
retention, deletion contact — linked from the surface where collection
happens (enforced by repo contracts and deterministic gates; the semantic
review may report omissions but is not enforcement; precedents: pathfinder
`/privacy`, levelflow's legal panel).

### Preview databases expire on the pull request's clock (owner-ruled 2026-09-03)

Any repo whose project uses Neon carries `.github/workflows/neon-branch-cleanup.yml`,
byte-identical to `templates/neon-branch-cleanup.yml`, plus the `NEON_PROJECT_ID`
repository variable and the `NEON_API_KEY` repository secret. The workflow is seeded
into `fleet-template`, so a project that later adopts Neon is already carrying it
rather than acquiring it after its own first surprise invoice.

The rule exists because the provider's lifecycle is coupled to the wrong clock. Neon's
Vercel integration creates a `preview/<git-branch>` database per preview deployment and
deletes it only when the **Vercel deployment** is removed — six months by default.
Merging a pull request and deleting the git branch does nothing to the database. Every
cleanup discipline the fleet already had operated on the branch, so nothing noticed.
pathfinder reached 93 branches and $79.60 of an $81.78 invoice against $2.18 of real
compute and storage, with 89 merged pull requests and one remote branch. The cost grew
about $1.50 per merged pull request per month and never came back down.

The checker enforces both directions of the pairing, because each half alone is worse
than neither: `NEON_PROJECT_ID` without `NEON_API_KEY` reaps nothing while looking
healthy, and `NEON_API_KEY` without `NEON_PROJECT_ID` is a live credential with no
consumer. It also compares the workflow blob wherever the file exists, configured or
not, since a seeded copy quietly edited into a no-op is the failure this is for.

A spending limit is a tripwire, not this control. Neon's org limit only emails at 80%
and 100% — it does not suspend — so it records that the reaper failed rather than
preventing the cost. Do not accept one in place of the workflow.

Migrating providers is not a substitute either. Supabase deletes preview branches on
pull request close by default, but its branches bill at roughly $10/branch-month and
its docs place branches **outside** the Spend Cap. The same 93 stuck branches would
have cost about $930 with the hard cap not applying.

The general rule this instances: **any provider resource created per pull request,
per deployment, or on a schedule must have a deletion mechanism owned by this fleet,
not by the provider's default retention.** Backup buckets get lifecycle expiry, preview
databases get a reaper, and anything else that accumulates gets named here with its
expiry before it ships.

### Deploy count is the build bill, not build duration (2026-09-03)

Vercel bills Build CPU Minutes per deployment, and the charge is dominated by fixed
per-deploy overhead — container provision, install, artifact upload — rather than by the
build step. Measured across the fleet on 2026-09-03: no project has a slow build
(pathfinder 21-31s, levelflow 8-15s), yet Aug 3 - Sep 2 billed 8,444 CPU-minutes over
roughly a thousand deploys, about 8 CPU-minutes each. Optimising a fast build saves almost
nothing. Not deploying a commit that changes nothing deployable saves the whole deploy.

The lever is a Vercel `ignoreCommand` that exits 0 to skip and 1 to build. Its predicate
must be one-sided: skip only when EVERY changed path is provably non-deployable, and build
on a deployable path, an unreadable diff, a missing parent commit, a non-git checkout, and
an empty file list. An empty diff is equally consistent with a diff that failed to compute,
so it must never read as "nothing changed". A wrong skip ships stale code and is invisible;
a wrong build costs a fraction of a cent.

**This is deliberately not seeded into fleet-template.** The non-deployable path set is
project-specific — a documentation site has `docs/` as its deployable content — and a
template guessing wrong would ship silent stale deploys to every repo created from it. A
repo adopting the lever writes its own path set and its own mutation test. Reference
implementation: pathfinder `scripts/vercel-ignore-build.sh` with
`scripts/vercel-ignore-build-test.sh`, which runs its cases against real git repositories
and proves the catch-all is load-bearing by deleting it.

Unlike an accumulating resource, this cost is proportional to activity and cannot compound
while nobody is looking. It is an optimisation, not a defect, and is ranked accordingly.

## Managed-edge header exception

The owner approved one capability-specific exception on 2026-08-24. Ghost(Pro)
[requires Cloudflare DNS records to remain DNS-only](https://ghost.org/help/cloudflare-domain-setup/),
so Windward Line cannot add the house response headers at Cloudflare without
replacing Ghost's supported edge topology. This waives only the live seven-header
result for the named origin. It does not waive CI, security scans, the local
header policy artifact, DNS integrity, action pins, rulesets, or any other fleet
control.

| Repo | Approved | Managed origin | Required proof | Expiry |
|---|---|---|---|---|
| `grown-men-grow` | 2026-08-24 | `https://grownmengrow.com` on Ghost(Pro) | Exact 12-minute `Ghost managed edge` one-step job on push + daily, its step named exactly `Verify the managed Ghost production edge`, calling `windwardline/windwardline/actions/verify-ghost-managed-edge@<current release SHA>` | Fails once all seven headers appear; remove this row and restore `Headers live` |

The shared probe has no caller-controlled subject and no secrets. It resolves
the apex and `grown-men-grow.ghost.io` through the same public resolver and
requires identical nonempty IPv4 sets. It requires `www.grownmengrow.com` to
resolve only to `178.128.137.126` and redirect exactly to the apex. From the
final apex response, not an intermediate redirect, it rejects `cf-ray`,
`cf-cache-status`, and a Cloudflare `server`; requires the observed Ghost
`ghost-fastly: true;production` marker and Fastly/Varnish path marker; and
requires at least one of the fleet's seven headers to remain absent. Once all
seven arrive, the exception premise is stale and the job deliberately fails.
The checker derives this table and requires exact full-row equality with its
executable register. Every other test of that equality compares the checker to a
FIXTURE `FLEET.md` the suite writes itself, which can only prove the checker
agrees with the fixture: on 2026-08-31 this row was edited here, the harness
stayed green at 203/203, and a live run aborted on the first read. One case in
`tests/fleet-conformance-test.sh` therefore reads the shipped document and the
shipped script directly, so that divergence fails in the suite rather than
waiting for someone to run the fleet. It also derives the nonempty production-origin population
from live security policies and proves that canonical header probes plus the
managed-edge rows equal that population exactly.

**Scratch copies of a repository are made by `scripts/scratch-clone.sh`, never
by hand.** Every repo carries it, byte-identical to `templates/scratch-clone.sh`
in this repo. Copying a working tree with `cp -R`, a bare `rsync`, or a local
`git clone` is not permitted: those copy what is *there*, and what is there
includes the data and the secrets. On 2026-08-25 a levelflow-cloud fan-out held
**23 whole copies under `/private/tmp` — 148.8 GiB**, each carrying a 7.7 GB
`.calibration-cache` that **no test reads** (the suite builds its own fixtures
with `mkdtempSync`), and **20 copies of a live `.env.local`** beside them. A
scratch copy made correctly is **12 MB**, and the same command that shrinks it
by 683x is what stops the secret travelling.

The script asks **git** what to copy — `git ls-files --cached --others
--exclude-standard` — rather than filtering with a list of its own. A private
list rots unnoticed until a copy is already gigabytes; git's ignore rules cannot,
because they are load-bearing for every commit. `--exclude-standard` is required
rather than incidental: it honours `.gitignore`, `.git/info/exclude`, **and**
`core.excludesFile`. An `rsync --filter=':- .gitignore'` sees only the first, and
leaked `.claude/settings.local.json` from the user's global excludes in testing.
The script refuses to run where git reports nothing ignored, and asserts after
copying that nothing ignored arrived — a copy that examined nothing must not
report success.


## How the work is done — the CONVERGE cycle

The standard above says what a repo must *contain*. This says how work on it is
*conducted*. It is owner-directed and applies to every agent, on every fleet
repo, existing and future.

`CONVERGE` is a standing one-word command. It means: work the repo's sequence
from wherever it stands, and when the current item is genuinely done — gates
green, deployed, verified in production, branches cleaned — run another full
cycle.

**Reporting is part of the command, not a courtesy.** Every `converge` gets a
detailed report, never a status line: where the overall build stands with the
full ranked sequence visible, what the adversarial review found and what was
refuted, what was verified personally, what changed, what is blocked, and what
the agent got wrong.

### The cycle

1. **FIND.** Several adversarial agents, one lens each, each asked what is WRONG
   or MISSING rather than what to improve. Every finding carries file:line or
   command output, the exact population it affects, and the procedural mechanism
   that let it through.
2. **REFUTE.** A second, independent pass whose brief is to KILL each finding —
   inflated severity, already remedied, wrong population, arithmetic that does
   not hold. A finding survives only if the refuter personally verified it.
   Expect to kill a fifth; expect some to come back worse than filed. Finding
   and refuting are different jobs, and one pass doing both protects its own
   conclusions.
3. **VERIFY YOURSELF.** Re-derive every load-bearing claim personally rather
   than relaying an agent's word — especially any claim about to be acted on,
   and any claim that flatters the work. Two traps, both paid for: a DELTA is
   not a LEVEL (an improvement over a bad baseline is not a good result), and
   identical numbers from two supposedly different runs are proof the knob did
   nothing, not agreement.
4. **FIX durably**, not with patches.
5. **RE-RANK the whole sequence** rather than appending to it. Re-ranking and
   updating are separate obligations; neither substitutes for the other.
   Anything homeless gets an owner. Placing an item often surfaces an ordering
   constraint nobody had written down — look for it.
6. **TEST whether the sequence reaches best-possible positioning**, and keep
   hunting if not, or name the input boundary that stops you.
7. **UPDATE the state-of-record document** — every ruling, reversal, and
   practice learned the hard way.
8. **REPORT** as described above.

Do not stop at turn boundaries. Never claim green when it is not. If a round
yields only nulls and validations, say the diminished-returns point is reached
rather than manufacturing another.

### Delivery discipline

- **Enumerate the gates; never count them.** Name each one, in the report and in
  any document a resumer copies. A count is not a checklist — it hides the gate
  nobody ran. This is not hypothetical: a session reported "six gates green" for
  fifty-odd rounds while the contract listed seven, and the omitted one was
  never run. **A repo's `AGENTS.md` names every workflow it runs, by filename**,
  and `scripts/fleet-conformance.sh` derives that set from `.github/workflows/`
  rather than trusting the contract's own list — a contract cannot be the
  witness to its own completeness. The first sweep carrying that check found
  `dependabot-auto-merge.yml` named in **no contract in the fleet**: the lane
  that arms unattended merges, and that degrades silently to `GITHUB_TOKEN`
  (whose pushes fire no workflows) when its App credentials are absent. It
  surfaced only because one repo printed a count — "seven workflows" against
  eight on disk — while every other repo hid the identical omission by not
  counting.
- **Stage explicit paths. Never `git add -A`.** Audit the staged diff against
  what you actually authored. Never run a write-capable background agent against
  the working tree a commit is staged from.
- **Validate before mutating.** Anything that writes must check its inputs
  before the first write, and a run that refuses must leave nothing behind.
- **Preserve standing claims.** No rewrite may silently retire an invalidation
  notice, caveat, or warning attached to an artifact. Those are retired by a
  human who revalidated, with the reason recorded — never as a side effect of
  re-running something.
- **Derive populations; do not curate them.** When installing a law of the form
  "every X must Y", derive the set of X by inspection, with any exemption
  verifying its own premise. A hand-picked list is how something sits outside
  its own law for fifty rounds. Make the predicate stable under the fix, so
  converting a member does not remove it from the population.
- **A harness failure must never read as the subject refusing.** An executed
  test asserts that the runner STARTED before it asserts anything about what the
  subject said. Spawn the repo's own binary by absolute path, never a resolver
  that depends on the working directory. Prove refusal tests against a cold
  cache — a green that depends on one machine's caches is not a green.

### Operational completion and artifact rules

- **Then:** commit (Conventional Commits, explaining *why*), push to the
  designated branch only, open a PR, drive CI to green, merge, reset the branch
  onto the default branch, verify the merge-triggered deploy **end to end** —
  naming the E2E and production-verification steps specifically, since a green
  run that skipped them is not a verified deploy — and leave zero open PRs and a
  clean tree.
- **No model identifiers** in commit messages, PR titles or bodies, code
  comments, or any other pushed artifact. Chat replies only.

### Advisory review is advisory

The review lane is semantic reporting, not enforcement. Deterministic gates,
the conformance checker, and repo operating contracts decide whether work may
land. "Wait for a clean round" is not a merge criterion unless the owner makes
it one. Rounds that never converge to zero are evidence about the loop, not a
reason to keep looping.

**The review lane bills the owner's Claude subscription, not separate credits.**
Every push to an open PR spends the same budget the working session draws on.
Under a constrained usage limit an unmerged PR is a second meter running, and an
agent must say so in its report rather than letting the cost stay invisible.

### Stopping

A safe stopping point means tested, verified, committed, pushed, merged,
deployed, cleaned up, and a dated resume block in the state-of-record document
naming the current head, what is next, what is untouched, and what constraint
the next session must not rediscover. Anchor durable checks to content hashes,
never to commit SHAs a squash merge will orphan. Do not start work you cannot
finish — stopping mid-implementation is a worse parking state than not starting.

**Enforcement.** This standard is deterministically enforced.
`scripts/fleet-conformance.sh` requires every repo's `AGENTS.md` to affirm that
the live global `~/AGENTS.md` applies and that `FLEET.md` governs, to carry the
cycle's steps **in order**, and to keep `CLAUDE.md` equal to the exact 11-byte
pointer `@AGENTS.md\n`. A path mention is not the contract. Fenced, commented,
quoted, and indented examples are stripped before either clause is read, and a
list-prefixed run of backticks is content inside a fence rather than its closer
— parsing a closer with the opener's container-aware reader stripped that marker,
closed the block early, and released the fenced citation after it as operative
policy, so an example could satisfy the applicability it was only illustrating.

What survives that strip is judged by an **accepted-clause rule**: the
affirmation must begin an operative sentence or semicolon-delimited clause, and
the clause immediately before it in the same block must be either absent — the
affirmation opens the block — or a statement of at least four words. A
forward-reading anchor alone was not enough. `Incorrect. The live global
contract at ~/AGENTS.md applies.` begins an operative sentence and satisfied it,
while the sentence in front withdrew the claim; `False; FLEET.md governs this
repo.` did the same across a semicolon. A one- or two-word verdict is a label,
not a statement, so a rebuttal cannot lend its own quoted text the force of an
affirmation. No negation vocabulary is enumerated anywhere in the check — a word
list is only ever as complete as the last spelling someone thought of — and the
bar sits well below the fleet's own floor: the shortest clause standing in front
of either affirmation across all seventeen contracts is eight words, and two
repos open the block with the affirmation itself. A check that reddens a correct
contract over a wording change gets weakened rather than obeyed.

Stated so the check is not read as more than it examined: it does not adjudicate
arbitrary contrary prose. A full sentence of contradiction followed by the
affirmation is accepted, and a paragraph standing alone is read on its own terms
whatever precedes it — blank lines, headings, and list items all open a new
block. Beyond the forms named above the contract rests on review, not on this
check. The rule has two implementations — the checker's shell and
`scripts/bootstrap_config_validator.rb`, which holds a future repo to it before
the repo exists — and they are built the same way, line-normalized in the same
order, not merely tested against the same examples. They diverged once when one
collapsed blank lines with a whole-body substitution and left the affirmation's
clause carrying a trailing dot.

The cycle is checked against a chain
**derived from this document at run time**, never a literal copied into the
script. The same derivation reads every bold delivery-rule label and checks
the executable long form in `levelflow-cloud/docs/HANDOFF.md` §6b against both
the ordered chain and those labels. It reads exactly one fenced prompt: each
step must be its own consecutive `(N) **LABEL.**` entry and each delivery rule
its own bold bullet. A narrative mention elsewhere in §6b cannot replace a
missing executable entry. That prompt is a governed home of the method now, not
an admitted manual copy. A hardcoded chain or rule list would be another place
free to drift from the standard it claims to enforce.

The checker captures each repository's default-branch SHA once, then pins every
file and tree read in that audit to that one immutable snapshot. The same
repo-to-SHA manifest drives the action-pin sweep; the sibling auditor does not
enumerate repositories or resolve their branches a second time. This file and
the canonical templates use the captured `windwardline/windwardline` SHA, never
the clone that launched the script or a later mutable branch read. A stale
clone or mid-audit push cannot redefine the method, unattended-merge lane, or
pin population while the same run reports green. Proposed-change tests are
explicit and printed:
`FLEET_MD_LOCAL` for this document,
`AUTOMERGE_TEMPLATE_SHA_OVERRIDE` for a validated 40-hex template blob, and
`REVIEW_CALLER_SHA_OVERRIDE` for the reviewed caller blob. The caller override
must still equal the checker's behavior-lock SHA; it cannot redefine that lock.
Revising the cycle or its delivery rules on `main` therefore re-points every
check automatically.

Verified 2026-08-20 rather than assumed: a ninth step was inserted into the
cycle above and the checker re-run, every repo went red with no repo edited,
and green again when the step was removed. Reordering is caught too — a
contract listing the right steps in the wrong order fails, because an
out-of-order cycle is a different method, not a cosmetic difference.

The derivation fails closed, and adversarial tests are why it does. Earlier
versions had silent ways to hollow themselves out, each of which would have
reported a green fleet while checking less than it claimed: a title-cased
`**Refute.**` yielded the bare letter `R`, which matches the first R in any
document and imposes no ordering; a code-spanned ``**`REPORT`**`` was dropped
from the chain entirely; `**TEST Whether The Sequence**` over-matched into
`TEST W`, which no contract can contain, reddening the fleet over a wording
change that altered nothing; and the scan stopped only at `##`, so it ran on
through the `###` subsections below and would have promoted any numbered bold
line there into a phantom step. Prefix-matching also accepted `### The cycle
rewritten`, duplicate headings replaced parser state, and a bold label wrapped
onto the next line could reduce to its first word. It now requires one exact
heading, consecutive numbering, and one unambiguous leading bold label closed
on the entry line; then it compares entries found with steps derived and stops
at the next heading of any depth. Any mismatch aborts with exit 2. The derived
chain and delivery-rule count print on every run, because invisible authority
is not authority.

That closes a gap this section previously recorded rather than hid. The first
version of it named pathway 3, the review lane, as its enforcement. That was
circular: two subsections above, this same document declares the review lane
advisory and explicitly not a required gate. A standard cannot be held by a
mechanism it defines as non-binding. And an agent governed by this standard
reads its repo's `AGENTS.md`; it does not read this file unless something points
it here. A working method that lives only in the fleet standard may never reach
the agent it governs.

The closure path, and where each step stands:

1. Every repo's `AGENTS.md` affirmatively cites both the live global
   `~/AGENTS.md` and `FLEET.md`, and carries the cycle, so the standard reaches
   the agent at the file it actually reads. (Closure condition 3.) Rolled out and
   measured against every repo before the check became binding — the rule lands
   on a fleet that already satisfies it, which is the ordering constraint step 2
   was written to respect.

   That ordering claim is exact, and it holds for the citation and the cycle
   only. The gate-enumeration rule below did **not** land on a fleet that
   satisfied it: on its first run every repo with workflows failed it, because
   `dependabot-auto-merge.yml` was named in no contract in the fleet. The
   contracts were corrected in the same effort rather than the rule being
   softened into a warning — the register of held exceptions exists for facts
   the owner has accepted, not for a rule nobody has got round to satisfying.

   **The exceptions register does not apply to this check** (owner ruling
   2026-08-20: "the same standard everywhere. No variations, no accommodations,
   no weaknesses"). The register exists because some repos have no CI, and a
   repo with no CI cannot carry a ruleset or an auto-merge lane. The working
   method is not a CI feature: it binds an agent editing a snapshot in `ops`
   exactly as it binds one editing an engine in `levelflow-cloud`, and the
   standards home is the last place the standard should fail to reach. So the
   citation, cycle, exact-pointer, and gate-enumeration pass runs over every
   non-archived repo, in the same shape as the visibility and suppression
   audits. It earned that on its first run: it caught this repo — the exempt
   standards home — failing to enumerate its own
   `fleet-credential-canary.yml`.
2. `scripts/fleet-conformance.sh` requires that citation, the exact
   `CLAUDE.md` pointer, the derived cycle, and the derived delivery rules in the
   Levelflow handoff's executable §6b prompt — deterministic enforcement,
   landed with this paragraph under the change-together law.
3. `fleet-template` seeds the citation so every future repo starts conformant.
   (Closure condition 4.)

## Preferred stack

The default stack for every project. Deviations follow the protocol below —
never silent adoption.

| Layer | Default | Recorded alternates |
|---|---|---|
| Database / backend | Supabase (org "Windward Line") | Neon via the Vercel Marketplace where it fits (precedent: pathfinder) |
| Hosting | Vercel | — |
| DNS / edge | Cloudflare (Windward Line account), **Workers Paid** since 2026-09-01 | — |
| Object storage | **Cloudflare R2** (`windwardline-backups`), R2 Paid since 2026-09-01 | — |
| Source | GitHub `windwardline` | — |
| AI inference | Groq (the `openai` SDK pointed at Groq is the house client) | Better-fit provider with owner approval |
| Email | Resend on `windwardline.com` | — |
| Automation | Zapier | — |

**Cloudflare subscriptions, and the ones deliberately declined (2026-09-01).**
Active: **Workers Paid** ($5/mo + usage), **R2 Paid** (10 GB storage, 1M Class A
and 10M Class B operations free per month, then $0.015/GB), and **Images Stream
Basic**. Workers Paid raises Workers off the free tier's limits and is the
prerequisite for Durable Objects, Queues and Cron beyond the free allowance —
so a fleet project may now reach for those without a new purchase. R2 exists
because the Levelflow minute bank needed an off-box copy; it is general-purpose
and any repo may use the same bucket under its own `<repo>/<dataset>/` prefix.

Declined, with the reason recorded so they are not re-proposed:

| Offered | Price | Why not |
|---|---|---|
| Workers for Platforms | $25/mo | Lets *your users* deploy their own Workers. No fleet project is multi-tenant in that sense. |
| Smart Shield Advanced | $50/mo | Argo Smart Routing, Tiered Cache and Cache Reserve accelerate traffic Cloudflare *proxies to an origin*. Applications launch on Vercel and Cloudflare is DNS — there is almost no such traffic to accelerate. |
| Zaraz | free, then $5 | Injects third-party tags. The fleet ships `script-src 'self'` with no `unsafe-inline` on purpose; this works against that posture rather than within it. |
| Log Explorer | free, then $1 | Queries HTTP request logs in-dashboard. Useful only for traffic Cloudflare serves, which for a Vercel-hosted fleet is the DNS layer alone. |
| Zero Trust Free | free | Nothing internal is exposed that needs it today. Free and reversible, so it is the first to revisit if an internal-only surface ever ships. |

*Unexplained and worth an owner look*: **Images Stream Basic** is active and was
not part of the 2026-09-01 purchase. If nothing uses it, it is a recurring
charge for an unused product.

Client access is a separate machine baseline, not an application-stack choice.
Each of the six supported client surfaces exposes exactly Zapier, Stripe, FMP,
Vercel, GitHub, Supabase, Neon through Vercel, Cloudflare, Aviationstack, Groq,
and Resend. Nothing outside that set remains connected. The private
`ops/service-baseline-check.py` pathway named in `CADENCE.md` derives the
machine-readable inventories and requires current, complete attestations for
UI-only surfaces. Missing, duplicate, extra, stale, or incomplete evidence is
not parity and exits nonzero.

**Deviation protocol:** an agent recommending a genuinely better option must put
the question to the owner *before* adopting anything — never adopt silently. An
approved deviation is recorded in that repo's `AGENTS.md` as a line beginning
`Stack exception (owner-approved YYYY-MM-DD):` with nonblank reasoning. It must
be an anchored live line outside backtick or tilde fenced examples and HTML
comments, carry a valid date no later than today, and cannot be future-dated
into authority it does not yet have. The
conformance checker fails any detectable deviation without that exact approval,
and deterministic checks enforce detectable deviations. The review lane
reports semantic findings on eligible same-repo PR events whose
`github.event.pull_request.user.login` — the PR author, stable across manual
reruns — is not `dependabot[bot]` and whose base is the repository's dynamic
default branch. Fork or missing-secret events skip;
deterministic gates and repo contracts still bind them.

## Repository visibility

**Every fleet repo is public unless it is on the private-by-design register below.**
Visibility is a cost control before it is a disclosure choice: GitHub Actions is
free on public repos and billed on private ones. On 2026-08-16 eight private
repos consumed 90% of the 3,000-minute monthly allowance by day 16; publishing
five of them removed the entire projected overage without changing a single
workflow. A repo created private is a recurring bill.

**New repos are created public (owner-ruled 2026-08-16):** use the canonical
`scripts/bootstrap-repo.sh` from a clean, GitHub-current `main`, beginning with
its read-only `--dry-run`. Direct `gh repo create` is not the supported fleet
path. The old `--private` default regrew this bill with every new project. A
repo that must start private uses a bounded two-step sequence after bootstrap
preflight: merge the reviewed register reservation, then immediately run apply
mode and finish with full conformance. The interval in which the row names no
existing repository is deliberate but never a stopping point. If creation
cannot proceed, remove the reservation at once. There is no standing
nonexistent private-by-design reservation.

| Repo | Why it stays private |
|---|---|
| `ops` | Third-party personal data (another organization's federal Tax ID, named individuals' contact details), credential-incident history, and the machine's full Keychain inventory. No workflows, so it costs nothing. |
| `venture` | Unlaunched venture: full product roster, supplier positions, and go-to-market not yet public. No workflows, so it costs nothing. |

Checked both directions. A repo that drops to private starts billing minutes; a
registered-private repo that turns public is an irreversible disclosure. The
second is the more expensive mistake, so both fail the checker.

Adding or removing a row here means amending this table and the checker's
`PRIVATE_BY_DESIGN` list in the same change set. The checker parses this table
and aborts if those populations differ. `grown-men-grow` left the register on
2026-08-18: it was the one private repo still running CI, and its
652 runs in 18 days took the account to 100% of the allowance. The owner chose
disclosure over the bill; the repo's decision log records it.

## Held repos

A repo the owner has reserved, which therefore lags a fleet-wide change. Named
in the checker (`LANE_HELD`, `DEPSCAN_HELD`) and reported on every run rather
than skipped — a skip list that cannot say why is how fleet-template sat exempt
while merging eight PRs through no gate. A hold is a dated promise, not an
exception: it carries the date it was granted and is emptied the moment the
work it was protecting lands. The checker parses this table, including each
  row's `dependency-scan` and `auto-merge lane` categories, and aborts if the
  executable held populations differ. Every registered repository must still
  exist and be live. A held behavior that has already caught up is itself drift;
  the register cannot preserve a stale exception after its premise disappears.

| Repo | Held since | Behind | Closing it |
|---|---|---|---|
| craft | 2026-08-17 | dependency-scan schedule guard; auto-merge lane reorder | copy `templates/dependabot-auto-merge.yml` in, drop the `if:` on `Dependency scan`, then remove `craft` from both lists |

Two canonical-template behaviors remain unresolved owner-decision follow-ups,
not holds or exceptions. Lines 42–43 of
`templates/dependabot-auto-merge.yml` falsely claim a manual rerun changes
`github.actor`. Separately, the merge-gate hold runs before deferred-major
labeling, so a gateless base branch can leave a major unlabelled and untracked.
Any chosen correction must then roll through every copy. Neither is closed
merely because its record exists here.

## Exceptions register

| Repo | Exception | Why |
|---|---|---|
| `windwardline` (this repo) | No CI on its own content; PRs merge manually. Hosts the fleet reusable, this standard, and the conformance checker; those workflows serve or audit the fleet rather than gate this repo. | Meta/standards home |
| `venture` | No CI, ruleset, or auto-merge lane; universal account checks still apply | Private venture outside the Windward Line family |
| `ops` | No CI, no ruleset; snapshots land by PR, merged manually | Private meta-layer archive (canonical standards file, agent config, hooks, memory) — holds no application code |

This register is mechanized: the conformance checker's exemption list mirrors it
exactly, asserts that equality on every run, and checks everything else under
the account by default. Adding an exception means amending this table and the
checker in the same change set.

**Exemption premises are re-verified every run.** Every row above rests on a
claim — "no CI" — and a blanket skip list cannot notice when that claim stops
being true, because the skip is what stops anyone looking. `fleet-template` was
exempted as "no CI, no ruleset, placeholders by design", then grew `ci.yml`,
`security.yml` and a review lane. It ran 61 pull_request builds and merged eight
PRs through no gate at all while the checker stayed silent, and its review lane
had been failing on a stale token since 2026-08-11 with nothing to catch it. It
was unexempted on 2026-08-16 and now carries the full standard.

The standing auto-merge rule admits no exceptions for repos with CI, so an
exempt repo that has CI is not an exception — it is an unapplied rule. The
checker enumerates every current default-branch workflow and reads its trigger;
any live `pull_request` or `pull_request_target` trigger invalidates the premise.
A filename such as `ci.yml` and a historical run do not: neither proves that CI
runs on the repository now.

**Exemption never covered vulnerability alerts.** These rows are exempt from the
ruleset and auto-merge — gates that need CI to mean anything. Dependabot alerts
gate nothing and cost nothing, so nothing about being exempt argues for having
them off. All three currently report alerts disabled, and on 2026-08-24 that was
correct: none carries a dependency manifest, so the alerts would scan nothing.

That is a fact about what these repos contain today, not a property of being
exempt, and it is precisely the kind of claim that goes stale without announcing
itself — the day one grows a `package.json`, its advisories go unreported and the
disabled setting still reads as deliberate. The checker therefore re-derives this
premise too: any exempt repo carrying a dependency manifest with alerts off is
drift, reported per repo and named for what it is.

## Enforcement and reporting pathways

1. **`scripts/fleet-conformance.sh`** (this repo) — deterministic checker. It
   derives the account through paginated REST: every non-archived repo,
   templates included. The exceptions register is removed from the main CI and
   application-shape loop; citation, cycle, pointer, gate-enumeration,
   visibility, suppression, dependency-scan, and action-pin audits still sweep
   the full account. `fleet-template` can no longer disappear because GitHub
   marks it `isTemplate`. A new repo is in scope the moment it exists.
   Every read preserves HTTP status: exact 404 means absence only for an
   optional resource; 403, 429, 500, transport failure, malformed JSON/base64,
   and empty required data abort with exit 2 rather than becoming drift or a
   pass. Repository, pull-request, workflow-run, job, ruleset, Actions-secret,
   and Dependabot-secret pages prove progress by immutable item identity. Run
   and job totals drive termination; repeated or overlapping pages, premature
   short pages, total overflow, and unfinished jobs abort instead of hanging or
   disappearing from the sample.

   It verifies the following deterministic subset per repo: the exact 11-byte
   `CLAUDE.md`; exact nonblank package-script keys; an unconditional action-pin step
   inside `Secret scan`; both Dependabot App secret names; every update lane's
   structurally nested cooldown; the catch-all header route; the exact current
   live-header action and SECURITY.md origin for the independently derived,
   nonempty production population; exact managed-edge register rows; canonical
   security-workflow root permissions; and daily-scan cron, exact tree-derived
   lockfile inputs, exact Dependabot ecosystem/directory lanes, and job
   liveness. It validates ruleset
   depth: active, default-branch-only, strict off, linear history plus the
   separate force-push block, zero bypass actors, and every context bound to the
   live GitHub Actions App identity. Required-check completeness
   reconciles every REST page and samples all completed non-skipped jobs,
   including failures and cancellations, on the newest merged PR. Pending jobs
   abort because their conclusions are not final. Skipped names
   remain in the inverse membership set: every required context must be a
   sampled Actions job, so an external deploy check cannot hide behind a new
   provider name. Jobs are excluded only when their run path is the actual
   advisory review or auto-merge workflow; a similarly named job elsewhere is
   still a gate candidate. Dispatch and schedule runs are not part of the sample. Zero PR, run,
   job, expected-scan, update-lane, or repository populations abort.

   It checks the Levelflow handoff's fenced §6b prompt structurally against the
   cycle and delivery rules derived from this file; validates nonblank,
   nonfuture stack waivers outside code fences and HTML comments; asserts the exception, private, and
   held tables against the checker's executable populations; compares every
   auto-merge lane and scratch-clone helper to their canonical blobs at this
   repo's captured default-branch commit; and re-derives whether any exempt repo
   now carries a dependency manifest that requires vulnerability alerts.

   It then passes the same immutable repo-to-SHA snapshot to
   `scripts/verify-action-pins.sh`, which resolves every third-party action pin
   against the tags its SHA really carries, dereferencing annotated tags. That
   sweep covers the exempted repos too, because this repo's own review lane held
   one of the two original rot cases, and because `fleet-template` is how a bad
   comment would reach every repo created after it. It prints a per-repo table
   and exits 1 on drift. If the sibling pin auditor or any required read cannot
   complete, exit 2 is preserved rather than rewritten as drift. Run it from
   any machine with `gh` authenticated. Scheduled execution rides pathway 6.
2. **Rulesets** hold the merge gates; converting or creating a repo never drops
   a check it already required.
3. **The review lane** reports semantic findings on eligible same-repo PR events
   whose `github.event.pull_request.user.login` — the PR author, stable across
   manual reruns — is not `dependabot[bot]` and whose base equals the
   repository's dynamic default branch. It reads each
   repo's operating contract and this file's Preferred stack. The reusable
   checks out `FLEET.md` before the review action; it never orders a network
   fetch from the no-egress sandbox. Fork or missing-secret events skip. The
   predicate is the PR author, not the person who initiated a rerun. This
   pathway is advisory; deterministic gates and contracts enforce.
4. **The done-gate** (workspace Stop hook) blocks a local session from finishing
   while any repo it edited fails a gate that repo's own `AGENTS.md` declares —
   read from the `fleet-gates` block below, every `gate:` line, in order.
   `release:` and `cadence:` are not run here; they are declared so the boundary
   is stated rather than inferred from silence. A repo with no `AGENTS.md` is
   skipped and said so; a repo with a contract but no block fails, because a
   gate that examined nothing must not report success. Each command is bounded
   by Ruby's `Timeout` around a process group rather than `timeout(1)`, which
   macOS does not ship.

   **That is true as of 2026-09-01, and this line claimed it while it was
   false.** It ran `typecheck` or `check`, `lint`, and `test` or `test:run`
   inferred from `package.json` — so a session editing `levelflow-cloud` was not
   held to `check:migrations`, `check:bundle`, `build` or `npm audit`, one
   editing `pathfinder` skipped its documentation validator, and `grown-men-grow`
   and `ops` were not gated at all, having no root `package.json` to infer from.
   The sentence was written on 2026-08-19 in the same change that corrected the
   older "typecheck + lint + tests" wording, and it recorded an intention as
   though it were a mechanism: every archived revision of the hook in the `ops`
   snapshot, back to the first on 2026-08-04, mentioned `AGENTS.md` exactly
   once, in a comment. It took until 2026-09-01 for anything to read it.
   A pathway that reports enforcement it does not perform is this standard's own
   defect in documentation form — a gate that examined nothing, reporting
   success — and it is the more dangerous form, because a reader takes coverage
   on trust and stops looking.
   **The obligation is unchanged, and correcting the description did not soften
   it:** a session runs the full gate set its repo's contract declares and
   reports each one by name.

   **Closed 2026-09-01.** Every contract now carries exactly one fenced
   ```` ```fleet-gates ```` block, and `scripts/fleet-conformance.sh` requires
   it. Three keys, each stating its own boundary so nothing is silently omitted:
   `gate:` runs at session end and must be local and quick, `release:` runs
   before a pull request and may be slow, `cadence:` is scheduled or needs the
   live machine and is run by neither. The tiering is not a loophole — it is
   where the slow-gate decision belongs. A long suite behind `release:` is the
   contract's own call, stated explicitly, rather than a hook silently running a
   subset and reporting completeness.

   The block is read from the raw document rather than through `live_markdown`,
   which strips fences. That is deliberate and not a contradiction: fences are
   stripped so an *example* can never satisfy a contract *clause*; this block is
   data, read structurally, the same split already made for the Levelflow
   handoff's fenced §6b prompt. It contributes no operative line, so it can
   neither satisfy nor disturb an applicability clause.

   The checker enforces shape, not truth: exactly one block, closed, at least one
   `gate:`, only the three keys, no repeated entry. It cannot prove a command is
   real without running it, and says so rather than implying more.

   **CI closes that half, and closes it standing.** Every repo with `ci.yml`
   carries one byte-identical `Run declared gates` step — canonical copy at
   `templates/steps/ci-declared-gates-step.yml`, compared by the checker — which reads
   the block and runs each `gate:` line. The declaration is therefore the
   executable thing rather than prose beside it: a command that is wrong,
   renamed, or rotted fails the next pull request. The step fails when the block
   is absent or declares no gate, so a repo cannot pass by having nothing to run,
   and it prints how many gates it executed rather than only that it finished.
   The individual gate steps were removed rather than kept beside it; two lists
   that must agree, with nothing making them, is the drift this closes.

   It is a step and not a shared action on purpose. Three action refs — the pin
   gate, the header probe, the managed-edge probe — are held to the current
   release SHA, so cutting a release to host this would red fourteen repos until
   every pin was chased. A step needs no release. The cost is a copy in each
   repo, which is why the checker compares it byte for byte, exactly as it does
   the auto-merge lane.

   The gates were still executed by hand in all seventeen repositories before
   being written down. CI proves them from now on; nothing proved them at the
   moment they were declared, and that gap was closed once, deliberately, rather
   than assumed away.

   Two things this ordering protects. The blocks landed in all seventeen repos
   before the checker required them, so the rule met a fleet that already
   satisfied it. And the runner is bounded with Ruby's `Timeout` around a
   process group, not `timeout(1)`: **macOS ships no `timeout`**, and the first
   verification harness that used it reported every gate in every repo as
   failing — a harness failure reading as the subject refusing, which is the one
   thing this standard forbids above the rest.
5. **The new-repo bootstrap** is the creation pathway, not a checklist. From a
   clean, GitHub-current `windwardline/windwardline@main`, run
   `scripts/bootstrap-repo.sh --dry-run --manifest <absolute JSON path>`, then
   rerun without `--dry-run` only after preflight passes. It validates the real
   project files, closed manifest bundle, ordered gates, exact four-workflow set
   and least-privilege schemas, current immutable fleet-action release, GitHub
   identities, and Keychain item presence before creating anything. Before any
   repository-owned helper executes, it proves the canonical origin, clean
   `main`, and byte-current remote head, then freezes every bootstrap-owned
   helper and manifest source into private snapshots. Apply mode
   proves the exact App identity and its active all-repository Windward Line
   installation before remote creation and reads creation state back on any ambiguous result;
   it never retries a name blindly. It creates from
   `windwardline/fleet-template` under `/Users/peacock/Projects`, proves the
   release commit contains every shared action path the generated workflows
   call, and runs the bootstrap-owned staged gitleaks scan through its fixed trusted executable
   path before the first commit or push, refusing a non-positive examined-byte
   count, and lands the project through a gated squash PR. Repository secrets
   are installed only after the merged head, default-branch commit, and complete
   tree are rebound to the validated commit. The App key is reauthenticated from
   the same stream uploaded to Dependabot. The
   final pass enables and verifies vulnerability alerts, automated fixes,
   auto-merge, the GitHub-Actions-bound
   ruleset, production probes, clean local `main`, and full fleet conformance. A
   public repository also gets verified private vulnerability reporting; a
   private repository gets truthful alternate reporting instructions because
   GitHub exposes that form only on public repositories.
   post-create failure retains and names both targets; it never claims rollback.
   Private-by-design creation uses the bounded two-step reservation above and
   cannot leave a nonexistent row behind. The manifest and exact procedure live
   in `docs/new-repo-bootstrap.md`. The checker, not the template, remains the
   authority, and a new repository enters its derived population the moment
   GitHub creates it.
6. **The weekly fleet-health cadence** — `CADENCE.md` (this repo), executed by
   a Claude Code scheduled task every Monday 09:00 ET, in this order:
   conformance; Actions failures; open issues and PRs; production and preview
   runtime errors; permission, config, agent-exit, MCP, exact service-baseline,
   symlink, and GitHub-auth guardrails; stray repos; trajectory; then the meta-layer snapshot to private
   `ops`. The checklist is versioned; the task is only the trigger.

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
