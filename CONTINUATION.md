# CONVERGE — the fleet continuation brief

**Start a fresh session with: Auto mode, Opus 5, ultracode on.** Then read this
file, then `FLEET.md`, then act. This brief exists because the work below spans
seventeen repositories and several universal documents, and re-deriving its
state costs more than recording it did.

Delete this file when the sequence in §4 is closed. It is a work record, not a
standard — `FLEET.md` is the standard.

---

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

Eighteen PRs are open. **Thirteen citation PR bodies describe only their first
commit** while carrying two or three; the body is the merge record and a squash
carries it forward. `levelflow-cloud#366`'s body is already corrected.
Each body also says "no gate reads this file", which stops being true the moment
#76 lands.

```
levelflow-cloud#366  grown-men-grow#118  timeshift#77   pathfinder#79
mimic#52             craft#34            fleet-template#21  thats-extra#55
proper-form#32       portfolio#36        windwardline-com#51
windwardline-labs#35 windwardline-media#31  windwardline-strategy#32
venture#2            windwardline#76
```

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

## 6. The new-repo guarantee — the part that is not finished

The owner requires that **every new repo is automatically held**. Two mechanisms
exist and one gap is known:

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
