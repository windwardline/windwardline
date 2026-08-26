# New repository bootstrap

Run the canonical bootstrap from this repository. It creates a repository from
`windwardline/fleet-template`, replaces the seed with project-specific files,
and carries the first change through the same gates the repository will retain.
Before any repository-owned helper executes, the source checkout must prove its
canonical GitHub origin, clean `main`, and byte-current remote head; feature
branches and stale or dirty policy copies are refused. The bootstrap then
copies every helper it will execute into one private run snapshot.

Start with a self-contained manifest bundle outside every repository. The JSON
manifest contains no secrets. Its parent directory is the bundle root. The
manifest itself and every source named by `files` must be nonempty regular files
that resolve beneath that root. No path component may be a symlink. Absolute
paths outside the bundle, `..` traversal outside it, and a regular file reached
through a symlinked directory are refused. Preflight copies each opened source
into a separate private manifest snapshot, and all later validation and
publication use those exact bytes.

The manifest's exact fields are:

- `repository`: lowercase GitHub repository name.
- `display_name` and `description`: final project copy.
- `visibility`: `public` or `private`. Omitting it selects `public`.
- `production_url`: one HTTPS origin, or `null` before launch.
- `automerge_app_id`: `4562963`, the reviewed ID for
  `windward-line-automerge`.
- `ci_gates`: every named executable `run:` step in `ci.yml`, in workflow
  order. `AGENTS.md` names all four workflows and repeats this exact ordered
  population under its `## Gates` section.
- `required_checks`: the exact ordered CI and security contexts that run to
  completion on pull requests. `Headers live`, the advisory review,
  Dependabot auto-merge, and deploy-platform checks are excluded.
- `lockfiles`: the exact repository-relative population derived from every
  supplied `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, and `bun.lockb`,
  including nested paths. One OSV job takes that same ordered population as
  parsed `--lockfile=` arguments. Dependabot contains exactly the matching
  ecosystem/directory lanes plus the root GitHub Actions lane; every enabled
  lane has a strict integer cooldown of at least seven days.
- `header_contract_tests`: repository-relative inputs executed by the supplied
  CI workflow. The `Header contract` gate contains only one canonical direct
  invocation for each declared test, in order, so an early exit or conditional
  mention cannot pass as reachable execution.
- `files`: safe repository-relative targets mapped to bundle-relative source
  paths. Supply real `AGENTS.md`, `README.md`, `ci.yml`, `security.yml`, and
  `dependabot.yml` files.

The finished repository has exactly four workflows: project-supplied `ci.yml`
and `security.yml`, plus the bootstrap-owned canonical `claude-review.yml` and
`dependabot-auto-merge.yml`. A fifth workflow is refused. Structural validation
requires the exact fleet jobs, exact root permissions, and least-privilege job
permissions, rejects caller-supplied credential-context reads, and keeps the
live header probe, advisory review, and auto-merge jobs out of
`required_checks`. App-class
repositories also supply their package scripts, lockfile, header contract test,
and seven-header Vercel contract.

Run the read-only preflight first:

```sh
/Users/peacock/Projects/windwardline/scripts/bootstrap-repo.sh \
  --dry-run --manifest /absolute/path/to/bootstrap.json
```

It validates the closed manifest bundle, all four workflows, ordered gates, the
current immutable fleet action release and the exact shared action paths at
that commit, the signed-in GitHub owner, the live template,
repository-name availability, the GitHub Actions App identity, and required
Keychain item presence. It creates nothing. For an unregistered private name,
it completes the non-mutating checks and prints the exact reservation required
before apply mode.

Apply mode repeats those checks, then parses the App private key and proves the
exact App identity plus its active, unsuspended, all-repository Windward Line
installation before creating a remote or local target. A present Keychain item
or parseable PEM cannot substitute for live authentication. Key material stays
in the Keychain-to-verifier pipe and is never printed, passed as an argument,
assigned to a shell variable, or written to disk.

Run the same command without `--dry-run` only after the preflight passes. The
bootstrap then:

1. Creates the repository with the requested visibility from the fleet template
   and reads the exact repository back from GitHub before trusting the result.
   If creation reports an ambiguous failure, the readback distinguishes a
   created remote from an exact absence; it is never safe to retry the name
   blindly. The checkout is cloned under `/Users/peacock/Projects`.
2. Rejects every symlink or special file inherited from the template before it
   writes. It installs the proprietary license and concrete project contract on
   a feature branch, validates the exact four-workflow set again, and stages
   literal explicit paths. The fixed trusted gitleaks executable scans that
   staged content before the first commit or push; a missing scanner, scanner
   error, or non-positive examined-byte count is a failure.
3. Pushes the branch with no repository secrets installed. The deterministic
   CI and security gates run. The production-only `Headers live` job and two
   secret-gated advisory jobs skip, while the advisory credential gate
   succeeds. The bootstrap verifies the complete expected population once by
   exact rendered name and GitHub Actions App identity; `Headers live` is
   evidence of the PR workflow shape, not a required context.
4. Enables auto-merge and installs the exact `main-requires-green-ci` ruleset
   from the PR-required population only, with GitHub Actions App binding,
   linear history, and force-push protection. It arms squash auto-merge and
   waits for the pull request. The post-merge push then runs `Headers live`;
   the daily schedule retains it thereafter.
5. Before any secret upload, proves that the merged pull-request head is the
   validated commit, that the default branch is the merge commit, and that its
   tree equals the reviewed tree. It then streams `CLAUDE_CODE_OAUTH_TOKEN` to
   Actions secrets and the fleet App ID and private key to Dependabot secrets.
   The private-key verifier repeats live App and installation authentication on
   the same read whose decoded PEM reaches GitHub.
6. Enables and verifies vulnerability alerts and automated security fixes, and
   verifies auto-merge. Public repositories also enable and verify GitHub private
   vulnerability reporting; private repositories receive truthful reporting
   instructions because GitHub exposes that form only on public repositories.
   It verifies the remote repository, ruleset, secret names, and deleted
   bootstrap branch; probes any production origin; synchronizes clean local
   `main`; and runs full fleet
   conformance.

Private creation uses one bounded two-step sequence. After a successful
preflight, merge a reviewed reservation that adds the exact repository to
`FLEET.md`'s private-by-design register and its executable mirror. Immediately
run apply mode, create the private repository, and close with full conformance.
The temporary nonexistent-repository interval is not a conformant resting
state. If creation cannot proceed, remove the reservation at once; never leave
a standing row for a repository that does not exist.

GitHub repository creation has no transactional rollback. If any later step
fails, the command prints the retained GitHub URL and local path and states that
it attempted no rollback. Repair or remove those exact targets deliberately;
do not rerun under the same name until they are reconciled.
