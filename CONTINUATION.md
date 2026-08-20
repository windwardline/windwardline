# CONVERGE — the fleet continuation brief

**Start a fresh session with: Auto mode, Opus 5, ultracode on.** Then read this
file, then `FLEET.md`, then act. This brief exists because the work below spans
seventeen repositories and several universal documents, and re-deriving its
state costs more than recording it did.

Delete this file when the sequence in §4 is closed. It is a work record, not a
standard — `FLEET.md` is the standard.

---

## 0. What this brief has NOT had — read before trusting it

**This file has not been adversarially reviewed.** Every fact in it was verified
directly against the files on 2026-08-20 — populations derived from the
filesystem, claims checked at file:line, the drift detection demonstrated rather
than asserted. But the pass whose whole job is to *kill* those findings never
ran: the container restarted mid-flight and took the workflow with it.

That matters because this brief's own §7 says reviews and subagents are inputs
rather than conclusions, and **the same applies to this brief.** Two errors were
caught on this work only because something re-derived a population that had
already been "verified" — see §5. There is no reason to think this file is the
one document that got everything right first time.

**Do this before acting on §4.** Run the audit that was lost, or its equivalent:

| Lens | Brief |
| :-- | :-- |
| Universal docs | Do `~/AGENTS.md` (in `ops` at `snapshot/AGENTS.md`), `FLEET.md`, `CADENCE.md`, this repo's `AGENTS.md`, `README.md`, and `fleet-template` all describe the SAME cycle and rules? Is precedence stated consistently in each place it appears? Does `FLEET.md`'s Enforcement section describe what the script actually does? |
| The checker | Read `scripts/fleet-conformance.sh` in full. Hunt vacuous passes: which `gh api` calls distinguish *absent* from *refused*? Does every derivation that could return empty abort? Can any plausible `FLEET.md` rewrite make `cycle_scan()` half-parse? |
| Contract accuracy | Re-derive every population in §4b and §5 from the filesystem. Report repos wrongly included **and** wrongly excluded — a repo where a claim is already true must be left alone. |
| New-repo path | Trace §6 end to end. What must a human still do by hand, and what breaks for each step forgotten? |
| Breakage | For every action §4 implies, what is its blast radius? Assume §5 understates at least one. |

Run them read-only and in parallel, then refute the results before acting. If a
lens confirms everything, be suspicious of the lens.

## 1. Definition of done — the owner's words, unabridged

> Every existing repo held to this standard, every new one automatically held to
> this standard, and all universal documents reflecting the same standard.
> Consistent and functional with no silent failings or contradictions. It must
> not break anything existing. Tested, verified, committed, pushed, merged,
> deployed, and cleaned up before it can be called done.

Nothing here is done until all of that is true. A green checker is not done. A
merged PR is not done. "Cleaned up" means branches reset onto the default branch
and no orphaned state left behind.

Two of those words carry weight earned the hard way:

- **No silent failings.** A check that reports success without having evaluated
  anything is worse than no check. This is the single defect class the whole
  effort exists to close, and it has already been found *inside the enforcement
  itself* — see §5.
- **No contradictions.** Two documents asserting incompatible things is a defect
  even when both are individually defensible, because an agent reads one of them.

## 2. What the standard is, and where it lives

The working method is **CONVERGE**: find → refute → verify yourself → fix →
re-rank → test → update → report, plus six delivery rules (enumerate the gates
rather than counting them, stage explicit paths, validate before mutating,
preserve standing claims, derive populations rather than curating them, and
never let a harness failure read as the subject refusing).

| Document | Role |
| :-- | :-- |
| `FLEET.md` (this repo) | **The standard.** Everything else summarises or enforces it. |
| `scripts/fleet-conformance.sh` (this repo) | Its deterministic enforcement. Changes together with `FLEET.md` — that is a law, not a habit. |
| `~/AGENTS.md` (archived in `windwardline/ops` at `snapshot/AGENTS.md`) | The cross-tool contract every client on the machine reads — one file, four symlinked paths. It **delegates** the working method to `FLEET.md`. |
| Each repo's `AGENTS.md` | Where an agent actually reads it. Carries a summary plus repo-specific law. |
| `fleet-template` | What a new repo starts from. |

**Precedence, already stated in `FLEET.md` and not to be re-litigated:** the
global `~/AGENTS.md` binds machine-level law everywhere and is not overridable;
on the working method it delegates here; a repo's own contract may narrow but
never weaken either; where a repo's summary and `FLEET.md` differ, `FLEET.md`
governs.

## 3. What already landed

Verified on 2026-08-20 — all seventeen repos committed, pushed, clean trees.

- **Every repo's `AGENTS.md` carries the citation**, and every repo names every
  workflow in its `.github/workflows/` by filename. Re-verified with anchored
  matching after a container restart: **17/17 conformant.**
- **`venture` had no `AGENTS.md` at all** — its whole contract lived in
  `CLAUDE.md`, so it reached Claude and no other agent. Now `AGENTS.md` with
  `CLAUDE.md` as the one-line pointer; substance byte-identical.
- **Enforcement exists** (PR #76 on `claude/converge-enforcement`):
  `scripts/fleet-conformance.sh` requires the citation and checks the cycle
  against a chain **derived from `FLEET.md` at run time**, never a literal in the
  script. A literal would be a third copy free to drift from both.
- **The review lane stopped ordering an impossible check.** Its prompt told the
  reviewer to `curl` `FLEET.md`; that sandbox has no egress, and eight reviewers
  in one round each spent a turn discovering it. Withdrawn, and pointed at the
  checker instead — which does the job deterministically, where the review lane
  is advisory by design and could only duplicate or contradict it.

**Proof the derivation works**, not an assertion: a ninth step was inserted into
a temp copy of `FLEET.md` and the checker re-run. Every repo went red **with no
repo edited**, and green again when the step was removed. Reordering is caught
too — the haystack is consumed as each step matches, so the right steps in the
wrong order fail.

## 4. The sequence — do these in order

### 4a. Fix the PR bodies, then merge

**Open PRs are not landed work.** Nothing in §3 is "done" under §1's definition
until these merge — a green branch that never lands protects no repo.

**Re-derive this list before acting on it; do not trust the state below.** As of
writing: `levelflow-cloud#366` is MERGED as `73000d6`, `#367` (its corrections)
was open with checks running, and these fifteen were open:

```
grown-men-grow#118   timeshift#77          pathfinder#79      mimic#52
craft#34             fleet-template#21     thats-extra#55     proper-form#32
portfolio#36         windwardline-com#51   windwardline-labs#35
windwardline-media#31  windwardline-strategy#32  venture#2   windwardline#76
```

**Thirteen citation PR bodies describe only their first commit** while carrying
two or three; the body is the merge record and a squash carries it forward.
`levelflow-cloud#366`'s was corrected before it merged. Each body also says "no
gate reads this file", which stops being true the moment #76 lands.

**Merge order is load-bearing: citations first, then `windwardline#76`.** The
checker reads `main`. Landing #76 first makes every repo report
`converge-citation:absent` until its own citation merges. This repo has no CI by
design — merge #76 manually after review.

### 4b. Correct the contract inaccuracies

Each was verified against the workflow files. **Derive every population again
before editing** — the fan-out has rewritten these paragraphs since.

1. **The action-pin gate is unnamed.** `verify-action-pins` runs as a *step*
   inside `security.yml`'s `secret-scan` job in all fourteen repos and fails that
   required check when an action is not SHA-pinned. It is a hard gate. Named in
   almost no contract. An agent adding `uses: foo/bar@v3` learns the rule only by
   watching CI go red.
2. **"every same-repo PR" is false.** `claude-review.yml` gates on
   `github.actor != 'dependabot[bot]'`, so Dependabot PRs — the one class that
   merges unattended — get no review.
3. **The hold enumeration is short.** `dependabot-auto-merge.yml` holds on an
   *unrecognised update type* (`:184-186`), distinct from the empty-metadata
   hold. Contracts that list the holds omit it.
4. **The daily-cron claim.** See the trap in §5 before touching this.

### 4c. Close the new-repo path

This is the half of the owner's requirement that nothing yet guarantees. See §6.

### 4d. Update `FLEET.md`'s record, cleanly

`FLEET.md` and `scripts/fleet-conformance.sh` change together. When the sequence
closes, the closure record must say so accurately and this file goes away.

## 5. Traps — read before editing anything

These look like corrections and are not.

- **Do not "fix" the daily-cron claim fleet-wide.** It is false in exactly five
  repos (`mimic`, `pathfinder`, `thats-extra`, `timeshift`, `levelflow-cloud`)
  and **true** in `craft`, whose `dependency-scan` still carries its weekly
  schedule guard under a documented owner hold, and true in every repo with no
  `dependency-scan` job at all. This population was derived **wrong twice**
  before it was derived right: once by grepping a single phrasing when several
  existed, which missed `timeshift`; once by matching a **commented-out** OSV job
  in `fleet-template` as though it were live. Test liveness with
  `grep -qE '^[[:space:]]*uses:.*osv-scanner-reusable'`.
- **Do not edit `templates/dependabot-auto-merge.yml` casually.** The checker
  compares every repo's copy against it **by git blob hash**, so any byte change
  desynchronizes fourteen repos on the lane that arms unattended merges. `craft`
  already differs deliberately (documented `LANE_HELD`).
- **There is a real defect in that template, deliberately left for a decision.**
  Its comment claims "Label majors before any hold can fire". False: the
  merge-gate hold at `:139-141` fires *before* the `deferred-major` labelling at
  `:147-149`. So in a repo whose base branch has no merge gate — and the file's
  own comment names `fleet-template` as deliberately gateless — a major bump is
  held **unlabelled** and never reaches the deferred-majors issue, which is the
  exact failure the ordering was built to prevent. The fix is safe in isolation
  (`UPDATE_TYPE` is set by `fetch-metadata` at `:92`, so the labelling block can
  simply move above the gate check) but costs a fourteen-repo propagation.
- **`pathfinder` really does have `codeql` and `license-policy` jobs.** Its
  contract naming them is correct. The "no CodeQL job" drift note applies to
  *other* repos' `security.yml:9` comments, not to pathfinder's contract.
- **The checker cannot see gates implemented as steps.** It derives from workflow
  *files*. `verify-action-pins` is exactly that shape and is invisible to it.
  This is recorded in the script itself rather than patched with a heuristic,
  because a checker claiming coverage it lacks is the defect being prevented.

## 6. The new-repo guarantee — NOT MET, and it is half the requirement

**State this plainly rather than let it read as a detail.** The owner's
requirement has two halves — every *existing* repo held, and every *new* repo
automatically held. The first half is done and enforced. **The second is not.**

A repo created today by following `fleet-template`'s README to the letter starts
conformant on the citation and **broken on the auto-merge lane**: it runs on the
degraded `GITHUB_TOKEN` path, whose pushes fire no workflow runs at all, so its
post-deploy headers probe never runs and nobody is told. Until §6's two gaps
close, "every new one automatically held" is aspiration, not fact — and it must
not be reported as done.

Two mechanisms exist, and two gaps sit between them and the guarantee:

- The checker **derives the fleet live** from GitHub — every non-archived,
  non-template repo, minus the exceptions register. A new repo is in scope the
  moment it exists; inclusion is the default and exemption the explicit act.
- `fleet-template` seeds the citation, so a repo created from it starts conformant.
- **The gap:** `fleet-template`'s `README.md` setup steps propagate only
  `CLAUDE_CODE_OAUTH_TOKEN`. They do not propagate `FLEET_AUTOMERGE_APP_ID` /
  `FLEET_AUTOMERGE_PRIVATE_KEY`, which must be **Dependabot** secrets — a
  Dependabot-triggered run resolves Actions secrets to empty rather than
  erroring. Without them the auto-merge lane degrades silently to `GITHUB_TOKEN`,
  whose pushes fire **no workflow runs at all**, so the post-merge headers probe
  never runs. A repo set up by following the README to the letter auto-merges
  dependency bumps into production with its post-deploy assertion silently off.
- **Second gap, same file:** its step 5 says required checks are "every
  PR-running CI and scan job by name". `dependabot-auto-merge` is a PR-running
  job and **must never** become a required check — the checker carries an explicit
  carve-out for exactly that string, which exists only because the naive
  derivation catches it. The README states the naive derivation with no carve-out.

Both propagate to every future repo, which is why they are the priority of §4c.

## 7. Standing discipline for whoever picks this up

- **Derive populations; never curate them.** Every error made on this work was a
  curated predicate where a derived one was available. When you check a property,
  compute the set from the filesystem — including from the lists in *this file*.
- **Verify yourself.** Reviews and subagents are inputs, not conclusions. Several
  findings recorded here were confirmed only after being checked in source, and
  at least one review claim was refuted that way.
- **A harness failure must never read as the subject refusing.** If a check
  cannot run, say so plainly and say why; do not report it as clean.
- **Preserve standing claims.** Nothing here may be quietly retired. If a trap in
  §5 stops being true, say so and record who verified it.

## 8. Open-issue register — every finding, routed

Nothing found on 2026-08-20 may live only in a chat transcript. This is the
complete list. **Re-derive every population before acting** (§7); the state
column is what was true when written, not a licence to skip checking.

### Fleet-wide — detailed above

| # | Issue | Where |
| :-- | :-- | :-- |
| 1 | `verify-action-pins` gate unnamed in ~13 contracts | §4b.1 |
| 2 | "every same-repo PR" false in every contract | §4b.2 |
| 3 | Hold enumeration omits *unrecognised update type* | §4b.3 |
| 4 | Daily-cron claim false in 5 repos, TRUE in others | §4b.4, §5 |
| 5 | `deferred-major` ordering defect in the template | §5 |
| 6 | `fleet-template` README: no auto-merge App secrets | §6 |
| 7 | `fleet-template` README step 5 would require the un-requirable job | §6 |
| 8 | Checker cannot see step-gates | §5, and in the script |
| 9 | 13 PR bodies under-describe their change sets | §4a |

### Fleet-wide — not detailed above

**10. The review lane's Dependabot guard is re-run leaky.** Each repo's
`claude-review.yml` gates on `github.actor != 'dependabot[bot]'`. `github.actor`
becomes the *human* who clicks Re-run, so re-running a Dependabot PR's checks
fires the review that was meant to skip. `dependabot-auto-merge.yml:46-49` solves
the identical problem correctly with `pull_request.user.login`, and its comment
says why. Two workflows, same question, one re-run-safe. **Fails safe** — it adds
a review rather than removing a guard — so this is a consistency fix, not urgent.
Touches `.github/workflows/` in ~14 repos. Fix the guard *before* documenting it,
or the contract describes behaviour about to change.

**11. `security.yml:9`'s comment names jobs that do not exist.** It labels the
weekly cron "Semgrep, CodeQL, Secret scan, License policy". Confirmed wrong in
`levelflow-cloud` and `thats-extra`, which have no CodeQL and no license-policy
job. **`pathfinder` genuinely has both** (`security.yml:38`, `:94`) — its contract
naming them is correct, so do not "fix" it. **Population not derived** — do that
first.

**12. `fleet-template`'s new paragraph opens with an ordinal.** "A fourth
workflow…" is a count, in the change set that imports *enumerate the gates rather
than counting them*, in the one repo whose whole job is to be copied. Repos made
from it add and drop workflows and the ordinal goes stale silently.

### Repo-specific

| Repo | Issue |
| :-- | :-- |
| `grown-men-grow` | `scripts/verify-repository.mjs` `requiredFiles` (~`:351-353`) lists `ci.yml`, `security.yml`, `claude-review.yml` — **not** `dependabot-auto-merge.yml`. Deleting that workflow passes gate 6 while `AGENTS.md` describes it at length. One line. |
| `timeshift` | `docs/DEMO_SCRIPT.md` pins into `prisma/schema.prisma` are each one line high: `:93` and `:240` cite 66–69 (actual **65–68**); `:102` and `:241` cite 75 (actual **74** — 75 is the model's closing brace). `:102` is a rehearsed `[POINT]` cue quoting the line inline. |
| `timeshift` | `README.md:47` links the contract as `[`CLAUDE.md`](CLAUDE.md)`, which resolves to the one-line `@AGENTS.md` pointer — GitHub renders that as plain text, so the highest-traffic path to the contract dead-ends. `README.md:162`'s bare §-ref is fine and should stay. |
| `portfolio` | `AGENTS.md`'s law that "fleet claims here (test counts, product roster) mirror the launch registry — verify against source repos before editing" does not name the CONVERGE summary, which is now a second species of mirrored claim. An agent editing it reads the law, sees its edit uncovered, and skips the check. |
| `thats-extra` | `.github/dependabot.yml` groups all npm production deps, all dev deps, and all actions into three PRs. `fetch-metadata` reports the **highest** semver change in a PR, so one major holds its whole group. Arming is per-group there, not per-package — a repo-specific consequence the byte-identical workflow cannot carry. |
| `windwardline-com` | **UNVERIFIED.** `.vercelignore` excludes only `docs`, so `AGENTS.md` may serve at `windwardline.com/AGENTS.md`. Raised twice in review; a `curl` from this session failed at the network layer, so it is unchecked either way. The repo is public, so this is serving discipline rather than disclosure — the contract asserts "specs never serve" and this file sits outside that. Check with `curl -sI`. |

### Raised and NOT acted on — decide, do not silently drop

**13. Citation placement.** Two reviewers noted the cycle and delivery rules
landed in each `AGENTS.md`'s identity lede rather than under `## Laws`, where an
agent looks for what binds it. Left as-is because the lede is read first and the
file is auto-loaded whole; recorded because it was raised twice and never
answered either way. Owner's call.

### Process gaps from this session

**14. The fan-out's verify phase never ran.** The container restarted mid-flight.
Its enumeration work was re-verified by hand afterwards — 17/17 conformant with
anchored matching — but the independent per-repo quality check it was going to
run did not happen. The prose it wrote was reviewed by the fleet review lane in
most repos, which caught real omissions; treat unreviewed repos as unreviewed.

**15. This brief's own adversarial pass never ran.** See §0. It is the first
thing to fix, not the last.
