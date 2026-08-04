# windwardline — fleet standards home, operating contract

Operating contract for AI work in this repo; the global `~/AGENTS.md` still applies. This repo is two things: the org's GitHub profile page (`README.md`) and the fleet's standards home — `FLEET.md` (the composite fleet standard), `scripts/fleet-conformance.sh` (its deterministic enforcement), and `.github/workflows/claude-review.yml` (the fleet-reusable review workflow, `workflow_call`-only, so nothing here ever runs CI on this repo's own content).

## Laws

- No CI on this repo's own content, by design (documented exception): merge PRs manually after local review; auto-merge stays off. The workflows hosted here gate the fleet, never this repo.
- `FLEET.md` and `scripts/fleet-conformance.sh` change together, in the same change set — the document defines the standard, the script enforces it, and drift between them is a defect.
- The reusable review workflow is inherited by every fleet repo at `@main` — a merge here lands fleet-wide on the next PR. Treat edits to it with production care.
- Every line of `README.md` is a manual claim about other repos. Verify test counts, the product count, and casing against the source repos before editing — nothing here catches drift.
- Product names are spec-cased ("Levelflow Cloud"). The fleet table follows the launch registry: a launch or retirement lands here in the same change set as labs and the portfolio.
- Contact here is mlp@windwardline.com while the apex site uses hello@ — confirm which is canonical before unifying either.
