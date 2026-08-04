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
| Live posture verification (prod headers) | levelflow `deploy.yml` polling | `Headers live` job (push + weekly) in every prod-facing repo |
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
- `.github/dependabot.yml` (house form).
- `.github/workflows/ci.yml` — the repo's real gates.
- `.github/workflows/security.yml` — Semgrep CE + Secret scan on PRs, pushes,
  weekly cron; plus `Dependency scan / osv-scan` when the repo has a lockfile;
  plus `Headers live` when it serves a production domain.
- `.github/workflows/claude-review.yml` — the thin caller of this repo's
  reusable (`@main`, deliberate: one merge updates every repo), passing exactly
  the `ANTHROPIC_API_KEY` secret.
- Repository settings: auto-merge enabled; `main-requires-green-ci` ruleset
  requiring every PR-running CI and scan job by name; linear history; no bypass
  actors.
- `ANTHROPIC_API_KEY` actions secret (reviews skip cleanly without it — fork
  PRs never receive it by design).

App-class repos (a `package.json` at root) additionally: `typecheck` (or
`check`), `lint`, and single-shot test scripts; a committed lockfile
(`package-lock.json`, `pnpm-lock.yaml`, or equivalent); security headers via
`vercel.json` with a contract test enforcing the set.

## Exceptions register

| Repo | Exception | Why |
|---|---|---|
| `windwardline` (this repo) | No CI on its own content; PRs merge manually. Hosts the fleet reusable, this standard, and the conformance checker — its workflows gate the fleet, never itself. | Meta/standards home |
| `venture` | Outside the fleet standard entirely | Private venture outside the Windward Line family |

## Enforcement pathways

1. **`scripts/fleet-conformance.sh`** (this repo) — deterministic checker: walks
   every fleet repo via the GitHub API and verifies each item above; prints a
   per-repo table and exits non-zero on any drift. Run it from any machine with
   `gh` authenticated. Scheduled execution rides the weekly fleet-health cadence.
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

Changing this document is changing the fleet standard: land it by PR here, then
make the conformance checker agree with it in the same change set.
