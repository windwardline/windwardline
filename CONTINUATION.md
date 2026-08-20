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
| `levelflow-cloud/docs/HANDOFF.md` §6b | **A sixth home, and the one most likely to drift.** It carries the full eight-step long form as an executable kickoff prompt, and says of itself "It does not check the long form below" — the copy an agent actually pastes and runs is the one nothing enforces. It was missing from this table until 2026-08-20; the §0 lens meant to catch cycle drift excluded it. |

**The return pointer.** `levelflow-cloud/docs/HANDOFF.md` is the Levelflow
rebuild's state of record and it points here for anything fleet-wide. This brief
governs the fleet; HANDOFF governs the rebuild; where they overlap **this file
wins on fleet state and HANDOFF wins on rebuild state**. HANDOFF's "The fleet
standard, 2026-08-20" section is a summary that will go stale — do not correct
the fleet from it, and do not read it as a completion notice. The two documents
are the whole record: there is no third place, and no chat.

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

**Re-derive this list before acting on it; do not trust the state below.** The
derivation, not a curated list:

```
gh search prs --owner windwardline --state open --head claude/converge-citation \
  --json number,repository,isDraft,url
gh pr view 76 --repo windwardline/windwardline --json number,isDraft,mergeable,mergeStateStatus
```

**State as of 2026-08-20 02:56 UTC, derived that way. Fourteen citation PRs, not
fifteen** — an earlier count in this file put `windwardline#76` inside the
citation set; it is the enforcement PR and merges *last*, so it is listed apart:

| PR | draft? |
| :-- | :-- |
| `grown-men-grow#118`, `timeshift#77`, `pathfinder#79`, `mimic#52`, `craft#34`, `fleet-template#21`, `thats-extra#55`, `proper-form#32`, `portfolio#36` | ready (9) |
| `windwardline-com#51`, `windwardline-labs#35`, `windwardline-media#31`, `windwardline-strategy#32`, `venture#2` | **DRAFT (5)** |
| `windwardline#76` — the enforcement, merges last | **DRAFT** |

**A draft PR cannot be merged, and this file did not say so until now.** Six of
the sixteen are drafts; §1 makes "merged" a condition of done, so the sequence
below was literally unexecutable as first written. `gh pr ready <n> --repo <r>`
first, or the merge call fails and reads like a permissions problem.

**`levelflow-cloud` and `ops` are not in that list and are not missing.**
levelflow-cloud's citation merged in `#366` (`73000d6`); `ops` already carried
the chain before this session, line-wrapped in its `AGENTS.md` lede. Both are
citation-conformant on `main`. Seventeen repos, fifteen PRs, two already done.

**Thirteen citation PR bodies describe only their first commit** while carrying
two or three; the body is the merge record and a squash carries it forward.
`levelflow-cloud#366`'s was corrected before it merged. **The claim that each
body also says "no gate reads this file" is FALSE and was curated, not
derived** — five bodies were pulled (craft#34, fleet-template#21, portfolio#36,
timeshift#77, venture#2) and none contains the phrase. It appeared only in an
earlier version of `#366`'s body, which `#366`'s final body explicitly retracts.
Re-derive with `gh pr view <n> --repo <r> --json body` before acting on any
claim about what a body says. Fixing a body is `gh pr edit <n> --repo <r> --body-file <f>`; it changes no commit and
triggers no CI, so it is cheap and it is the merge record.

**Merge order is load-bearing: citations first, then `windwardline#76`.** The
checker reads `main`. Landing #76 first makes every repo report
`converge-citation:absent` until its own citation merges. This repo has no CI by
design — merge #76 manually after review.

**"Deployed", for this work.** Every artifact here is a `.md` file or a shell
script in repos with no deploy step, so the word has no literal meaning and §1
still requires it. The substitute, stated so nobody has to invent one: after
#76 lands, run `scripts/fleet-conformance.sh` against `main` **from a clean
checkout** — `git worktree add /tmp/fleet-verify origin/main`, or a throwaway
clone — and record the per-repo output. Green from a clean checkout against
`main` is what "deployed" means for this change set. A run from an existing
working tree does not count — see the stale-clone trap in §5, which is about the
very checkouts this work will be done in.

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
  desynchronizes **thirteen** repos on the lane that arms unattended merges —
  not fourteen; `craft` already differs deliberately (documented `LANE_HELD`),
  which the next clause said while the count contradicted it. Fourteen repos
  carry the file; thirteen are in sync with the template.
- **There is a real defect in that template, deliberately left for a decision.**
  Its comment claims "Label majors before any hold can fire". False: the
  merge-gate hold at `:139-141` fires *before* the `deferred-major` labelling at
  `:147-149`. So in a repo whose base branch has no merge gate — and the file's
  own comment names `fleet-template` as deliberately gateless — a major bump is
  held **unlabelled** and never reaches the deferred-majors issue, which is the
  exact failure the ordering was built to prevent. The fix is safe in isolation
  (`UPDATE_TYPE` is set at `:101`, in the `env:` block of the "Decide and arm"
  step — **not** at `:92`, which is `fetch-metadata`'s `uses:` line — so the
  labelling block can
  simply move above the gate check) but costs a fourteen-repo propagation.
- **The local clones are on stale feature branches. Derive from `origin/main`,
  never from a working tree.** This was written from a container whose copies
  lived under `/workspace/*`; it applies identically to whatever directory holds
  them on the machine doing the work, and more sharply there, since that is
  where the merges happen. Every repo sits on
  `claude/converge-citation` (or another feature branch) and several predate the
  citation commit. `grep CONVERGE /workspace/ops/AGENTS.md` returns **zero** and
  `git show origin/main:AGENTS.md` in the same repo returns the full chain — the
  working tree is on `claude/fmp-key-consumer-inventory`, cut before the
  citation landed. A conformance claim derived from a working tree is a claim
  about whatever branch happened to be checked out. `git fetch origin main` then
  `git show origin/main:<path>` is the only safe read. This trap has already
  produced one false "ops is non-conformant" finding and one false refutation of
  it, in opposite directions, on the same file.
- **"17/17 conformant" is a conclusion, not evidence, and it is not fully
  earned.** §3 states it; what is actually recorded is that a hand re-run after
  a container restart reported it. The anchor pattern is not written down, the
  per-repo rows were not preserved, and §14 records that the independent verify
  phase never ran at all. Re-derive it — the script prints a per-repo row by
  design — and record the rows, not the ratio. The correct shape already exists
  in this file: see the `UNVERIFIED` entry for windwardline-com in §8, which
  names the reason and the remedy.
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

**16. Three of the four §4b populations have no recorded derivation.** §4b.4
carries its command (`grep -qE '^[[:space:]]*uses:.*osv-scanner-reusable'`) and
names the two ways it was previously derived wrong. §4b.1–3 say only "each was
verified against the workflow files" — so "fourteen repos" for the action-pin
gate, "~13 contracts" for the review-lane claim, and "~14 repos" in §8.10 are
counts with no reproducible method behind them. That is the same shape §5 says
cost two wrong derivations on the cron population, and it is the shape the
"derive populations rather than curating them" rule exists to prevent. Record
the predicate beside each population before acting on it. Do not act on a bare
count.

**17. This brief was read adversarially on 2026-08-20 and the findings above
are what came back.** Six of them were fixed in place the same night: the draft
status of six PRs (§4a), the missing return pointer to `HANDOFF.md` (§2), the
sixth home of the cycle (§2), the undefined "deployed" (§4a), the stale-clone
trap (§5), and the unearned "17/17" (§5). §0's five audit lenses remain unrun —
the pass that found these was a document audit, not the code-and-behaviour audit
§0 asks for. Item 15 stays open.

## 9. The brief for whoever executes this — paste it whole

The owner is handing this to a different frontier model at highest effort. That
model has **none** of the conversation this brief came out of; this file,
`FLEET.md`, and `scripts/fleet-conformance.sh` are the entire inheritance. The
prompt below is written to be pasted as-is, and is kept here rather than in a
chat so it survives.

```
You are running on the machine where all seventeen repositories are already
checked out. Find the windwardline/windwardline clone, run git fetch origin, and
check out the branch claude/converge-enforcement — that is PR #76, still open.
Do not clone a second copy; work the checkouts that are there. Read
CONTINUATION.md on that branch in full before doing anything else. It is the
brief, and it is not on main yet, which is itself part of the task. FLEET.md in
the same repo is the standard the brief enforces, scripts/fleet-conformance.sh
is that standard's deterministic checker, CADENCE.md is a third universal
document the brief only just discovered contradicts FLEET.md, and ~/AGENTS.md is
the machine-level contract every agent on this machine reads — it binds
everywhere and delegates the working method to FLEET.md. You have no prior
conversation; those files plus the seventeen repos are all the context that
exists, and that is deliberate.

Before you trust anything you read in a working tree, run git fetch origin and
git status in each repo you touch. Every one of those local clones is sitting on
a feature branch, several cut before the work you are about to merge, and some
carry local commits that were never pushed. That is not hypothetical — it has
already produced one false conformance finding and one false refutation of it,
on the same file, in opposite directions.

Your job is section 4, in order: fix the PR bodies, merge the fifteen PRs in the
stated order, correct the contract inaccuracies, close the new-repo path, and
update FLEET.md's record. Section 6 is the half of the requirement that is NOT
met — a new repo is not automatically held to the standard today — and it is
the part that matters most, because every repo created after you finish inherits
whatever you leave.

Hold yourself to CONVERGE, the cycle the standard defines: find, refute, verify
yourself, fix, re-rank, test, update, report. Refute means you attack your own
finding before you act on it, and verify means you re-derive the claim yourself
rather than trusting a report — including every claim in this brief. Section 3
says "17/17 conformant"; treat that as a claim to re-derive, not a fact. Section
5 lists the traps, and the first one is the local checkouts described above:
read state with git show origin/main:<path>, never from a working tree.

Derive populations, never curate them. Wherever this brief gives you a count
without a command that reproduces it — section 8 item 16 names three — write the
predicate first, run it, and act on what it returns. Two wrong populations have
already shipped from grepping one phrasing when several existed, and from
matching a commented-out job as though it were live.

Changes must be universal and must enhance, not weaken. The same standard in
every repo, no variations, no accommodations. Where you find a rule that is
false in some repos and true in others, section 5's cron trap is the model: a
blanket edit that breaks an accurate contract is a regression even when it
closes a defect elsewhere.

Done means all seven of these, and section 1 has the owner's own words for it:
tested, verified, committed, pushed, merged, deployed, and cleaned up. Merged is
not "PR opened" — six of the sixteen PRs are drafts and cannot merge until you
mark them ready. Deployed, for a change set of markdown and shell in repos with
no deploy step, is defined in section 4a: fleet-conformance.sh green against
main from a clean checkout — a git worktree off origin/main, or a throwaway
clone — with the per-repo rows recorded. Running it from your working tree does
not count, for the reason above. Cleaned up is defined in section 1: branches
reset onto the default branch, no orphaned state — and on this machine that
includes the local feature branches you will have finished with.

Section 10i splits ownership item by item and is the authority on what is
yours. In short: levelflow-cloud's rebuild program is not — its state of record
is docs/HANDOFF.md in that repo and its own owner resumes it separately, and
the eleven-item register in that file is theirs, not yours. Two things inside
that repo ARE yours, because they are fleet-wide items that happen to live
there: the four AGENTS.md contract defects, each one instance of a population
spanning many repos, and HANDOFF.md section 6b's long-form CONVERGE prompt,
which is the sixth home of the cycle and the only copy nothing pins — the copy
an agent actually pastes and runs.

One thing is out of scope outright. templates/dependabot-auto-merge.yml is
compared across repos by git blob hash, so any byte you change there
desynchronizes thirteen repos on the lane that arms unattended merges — section
5 explains the real defect sitting in it and why it was left for a decision
rather than fixed.

Report what you could not verify as plainly as what you did. A check that
reports success without having evaluated anything is the single defect class
this entire effort exists to close; do not let your own report become one.
```

**One thing to say out loud when handing this over.** The brief is honest about
its own gaps — §0 lists five audit lenses that have never been run, §6 says the
new-repo guarantee is not met, and §8 routes fifteen open findings. That honesty
is the deliverable, not a caveat on it. An executor who reads §3 and stops has
been told the work is finished; an executor who reads §0 first has been told
what to distrust. Point at §0.

## 10. The adversarial pass — run 2026-08-20, findings re-verified here

§0 said this brief had never been attacked. It has now. Two independent
read-only passes ran against it; what follows is what survived **my own
re-derivation**, with the checks written out so nobody has to trust either the
reviewer or me. One headline finding was refuted and is recorded as refuted,
because a register that only grows is not a register.

### 10a. REFUTED — `ops` is fine, and the refutation is the point

The pass ranked "`ops` has no pushed branch, no PR, and no cycle on `main`" as
its single most actionable defect, and concluded the §4 sequence cannot close.
**It is wrong.** Re-derived:

```
$ git -C /workspace/ops fetch origin main && git rev-parse origin/main
9c478f0faae446765ee0b97c19ae42980ddfcdc9
$ git show origin/main:AGENTS.md | grep -c 'find → refute → verify yourself'
1
```

`ops` carries the full chain on `main`, line-wrapped in its lede. A grep that
anchors on one line misses it; the checker normalises whitespace and passes it.
This is the second time this exact file has produced a false finding in each
direction, which is why the stale-clone and whitespace traps are in §5. **Do not
open a PR against `ops` for this.**

### 10b. CONFIRMED and decisive — the checker cannot see `fleet-template`

`scripts/fleet-conformance.sh:26-27` builds its universe as

```
gh repo list "$OWNER" --json name,isArchived,isTemplate \
  --jq '[.[] | select((.isArchived or .isTemplate) | not) | .name] …'
```

and the GitHub API returns **`"is_template": true`** for
`windwardline/fleet-template` (control: `mimic` returns `false`). So the seed
repo is dropped from `$ALL` before any pass runs — citation, gate enumeration,
dependency-scan, required files, all of it — and no row is printed for a repo
that was silently dropped.

**This is the documented incident recurring through a different mechanism.** The
script's own comment records that fleet-template was once exempted as "no CI, no
ruleset", then grew `ci.yml`, `security.yml` and a review lane, and "ran 61
`pull_request` builds and merged eight PRs through no gate at all, and the
checker stayed silent because it had been told not to look." The exemption
register was fixed; the `isTemplate` filter does the same thing and nothing
re-verifies it. The re-verification loop at `:603-617` iterates `$EXEMPT` only.

It also means **"17/17" cannot be a checker output** — the checker can print at
most sixteen rows. And §6, whose entire subject is fleet-template, states the
filter approvingly while describing the mechanism that blinds the checker to
§6's own subject.

**Fix shape, not a fix:** either drop `isTemplate` from the filter and let the
exceptions register be the only exemption mechanism, or keep it and make the
script print a `skipped: <repo> (isTemplate)` row per drop. The second is
cheaper; the first is what "no accommodations" means. Whichever is chosen, a
repo dropped silently is the defect class, not the filter.

### 10c. CONFIRMED — a live false green in `grown-men-grow`

`grown-men-grow/.github/workflows/security.yml` has exactly **one** cron —
`17 9 * * 1`, weekly — and its `dependency-scan` job at `:84` carries **no**
`if:` guard. So the scan runs weekly on schedule, which is precisely what
`FLEET.md:78` forbids and why: the advisory database changes with no commit, and
a weekly scan let a widened advisory sit four days. The checker tests only for a
job-level `if:` containing `github.event.schedule`, so a repo whose *workflow*
has no daily cron at all passes as "runs on every trigger". Derived predicate for
the real population: a repo is compliant only if its `security.yml` has a daily
cron **and** its scan job has no schedule guard. The checker currently tests the
second half only.

### 10d. CONFIRMED — `fleet-template`'s daily cron runs zero jobs

Its `security.yml` has two jobs, `semgrep:24` and `secret-scan:38`, and **both**
are guarded to `17 9 * * 1`. The daily cron at `:10` therefore fires a run in
which nothing executes and which reports success. Its own comment on that line
reads `# daily: Dependency scan + Headers live` — neither job exists in the file
(the OSV job is commented out at `:58-66`, and there is no `headers-live` job at
all). A green that evaluated nothing, in the repo every future repo is copied
from. Combined with 10b, the seed repo is both unchecked and self-describing as
running scans it does not run.

### 10e. CONFIRMED — two universal documents disagree

`FLEET.md:78`: "**`Dependency scan` carries no schedule guard either**."
`CADENCE.md:34-37`: "`17 13 * * *` runs `Headers live` only, and **the scan jobs
skip themselves on the daily one** — so that run reports success while scanning
nothing." CADENCE describes as current a state FLEET.md now forbids. §1 names
exactly this — two documents asserting incompatible things — as a defect, and §8
claimed to be the complete list while omitting it. `CADENCE.md` is a universal
document and belongs in §2's table; it is not there either.

### 10f. Corrections to §8's populations — all curated, all now derived

- **§8 item 11** (`security.yml:9`'s stale comment) is wrong in **five** repos,
  not two: `fleet-template`, `mimic`, `thats-extra`, `timeshift`,
  `levelflow-cloud`. `pathfinder` carries the same comment and is **correct** —
  it really has `codeql:38` and `license-policy:94`. The other six repos say
  "full scan suite" and `grown-men-grow` has no comment.
- **§8 item 12** (the `fleet-template` ordinal, "A fourth workflow…") is **three**
  repos, not one: `fleet-template/AGENTS.md:19`, `mimic/AGENTS.md:15`,
  `proper-form/AGENTS.md:11` — the last two both read "Of the four workflows
  only `security.yml` carries `workflow_dispatch`". A count, in the change set
  whose own rule is *enumerate the gates rather than counting them*. The finding
  was framed as "the one repo whose whole job is to be copied", and the frame is
  what dropped two repos.
- **The `thats-extra` dependabot-grouping row is not repo-specific.** Its
  `dependabot.yml` is byte-identical to `craft`, `mimic`, `timeshift` and
  `levelflow-cloud`, and `pathfinder`'s differs only by comments and an
  `ignore:` block. The row also says the byte-identical workflow "cannot carry"
  the consequence; it does, at `templates/dependabot-auto-merge.yml:176-177`.
- **`timeshift/README.md:162`** was cleared as "fine and should stay". It reads
  "the same contract (**CLAUDE.md §13**)"; `CLAUDE.md` is one line and has no
  §13 — §13 is `AGENTS.md:197`. Same dead end as `:47`, cleared without checking.

### 10g. The standing caveat on `craft`

§5 protects `craft`'s schedule guard as correct-today. It is — verified at
`craft/.github/workflows/security.yml:57-60`, and its two crons make the
contract sentence true. But `FLEET.md:458` schedules that guard for **deletion**
("drop the `if:` on `Dependency scan`, then remove `craft` from both lists"), and
`fleet-conformance.sh:639`'s `DEPSCAN_HELD="craft"` exists only to stop the
checker reddening it meanwhile. So §5's trap protects a sentence the standard
requires to become false. When the hold lifts, `craft` joins the five — and the
daily-cron correction must be re-derived, not replayed from the list in §5.

### 10i. Ownership — every open item has exactly one owner

The rebuild and the standard are worked by different agents from here. Split
stated once, so nothing sits waiting on whichever one reads it first.

**Yours (the standards work).** Everything in §4, §5, §6 and §8 of this file,
plus two items that live inside `levelflow-cloud` and are nonetheless
fleet-wide:

- **The four `AGENTS.md` contract defects recorded in `levelflow-cloud`'s
  HANDOFF** — the false daily-cron claim, the false "every same-repo PR" review
  claim, the omitted `unrecognised update type` hold, and the unnamed
  `verify-action-pins` gate. Each is one instance of a population spanning many
  repos (§4b), and fixing the levelflow instance alone is the blanket-edit
  mistake §5's cron trap describes, run in miniature.
- **`levelflow-cloud/docs/HANDOFF.md` §6b's long-form CONVERGE prompt.** It is
  the sixth home in §2's table and the only unpinned copy of the cycle — §6b
  says so about itself: *"It does not check the long form below."* It is the
  copy an agent pastes and executes, so it is the copy most likely to drift,
  and pinning it is enforcement work, not rebuild work. `HANDOFF.md` now routes
  it here explicitly rather than leaving it to whoever notices.

**Not yours (the rebuild).** The R-ranked sequence and the eleven-item
"Unresolved, recorded here so it is not lost" register in `HANDOFF.md`. That
register names dead commits, an unreproducible fingerprint and an undefined
"deployed" for the next three rebuild items; all of it lands in that repo and
none of it is a fleet concern. Read `HANDOFF.md` if you want the split's other
half; do not work it.

### 10h. What the pass could not check, stated plainly

`gh` is absent from the audit container, so no finding above was produced by
*running* `fleet-conformance.sh` — all of it is read against the script,
the filesystem and the API. `windwardline.com/AGENTS.md` remains **UNVERIFIED**:
the agent proxy denies CONNECT to that host (policy denial, 403 on `/` as well),
so the §8 entry's marking stands and its remedy is still owed. Commit counts
were pulled for two of the thirteen under-described PR bodies; the other eleven
are unchecked, and the arithmetic (14 citation PRs − `venture#2`, which is a
single commit fully described) is what supports "thirteen".
