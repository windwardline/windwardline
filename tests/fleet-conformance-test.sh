#!/bin/bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-conformance-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export GHOST_MANAGED_EDGE_REPOS_OVERRIDE=_NONE_

mkdir -p "$TMP/subject/scripts" "$TMP/subject/templates" "$TMP/bin"
cp "$ROOT/scripts/fleet-conformance.sh" "$TMP/subject/scripts/fleet-conformance.sh"
cp "$ROOT/scripts/actions_yaml_inspector.rb" "$TMP/subject/scripts/actions_yaml_inspector.rb"
cp "$ROOT/templates/dependabot-auto-merge.yml" "$TMP/subject/templates/dependabot-auto-merge.yml"
cp "$ROOT/templates/scratch-clone.sh" "$TMP/subject/templates/scratch-clone.sh"
cat >"$TMP/subject/scripts/verify-action-pins.sh" <<'PIN_AUDITOR'
#!/bin/bash
[ "${1:-}" = --latest-release ] && { printf 'v1.0.0\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; exit 0; }
[ "${1:-}" = --snapshot-manifest ] || exit 2
[ "${2:-}" = - ] || exit 2
manifest=$(cat)
printf '%s\n' "$manifest" >"$MOCK_LOG.pin-manifest"
printf 'pin-auditor %s\n' "$*" >>"$MOCK_LOG"
manifest_count=$(printf '%s\n' "$manifest" | awk 'NF { n++ } END { print n+0 }')
[ "$manifest_count" -eq "${3:-0}" ] || exit 2
[ "${MOCK_SCENARIO:-}" = pin_auditor_incomplete ] && exit 2
exit 0
PIN_AUDITOR
chmod +x "$TMP/subject/scripts/verify-action-pins.sh"

cat >"$TMP/bin/gh" <<'MOCK_GH'
#!/bin/bash

set -u

printf '%s\n' "$*" >>"$MOCK_LOG"

content_json() {
  encoded=$(printf '%s' "$1" | base64 | tr -d '\n')
  printf '{"sha":"%s","content":"%s"}' "${2:-1111111111111111111111111111111111111111}" "$encoded"
}

agents_body() {
  cycle='CONVERGE: find refute verify yourself fix re-rank test update report.'
  [ "$MOCK_SCENARIO" = cycle_prefix ] \
    && cycle='CONVERGE: find refute verify yourself prefix re-rank test update report.'
  global_contract='The live global contract at ~/AGENTS.md applies.'
  fleet_contract='FLEET.md governs this repo.'
  waiver=''
  case "$MOCK_SCENARIO" in
    global_contract_absent) global_contract='The global contract applies.' ;;
    global_contract_wrong_path) global_contract='The live global contract is ~/AGENTS.md/archive.' ;;
    global_contract_negated) global_contract='The live global contract at ~/AGENTS.md does not apply.' ;;
    global_contract_meta_negated) global_contract='It is false that ~/AGENTS.md applies.' ;;
    global_contract_labeled_negated) global_contract='Incorrect. The live global contract at ~/AGENTS.md applies.' ;;
    global_contract_labeled_negated_clause) global_contract='False; the global ~/AGENTS.md still applies.' ;;
    global_contract_house_form) global_contract='Operating contract for AI work in this repo; the global `~/AGENTS.md` still applies.' ;;
    global_contract_trailing_colon) global_contract='The global `~/AGENTS.md` still applies: read it before anything here.' ;;
    global_contract_fence_false_closer) global_contract='```text
- ```
The live global contract at ~/AGENTS.md applies.
- ```
```' ;;
    global_contract_wrapped) global_contract='The live global contract at ~/AGENTS.md still
applies.' ;;
    global_contract_closed_comment_quote) global_contract='The live global contract at ~/AGENTS.md applies.
<!--
> quoted text inside a closed comment
-->' ;;
    global_contract_invalid_fence_lazy) global_contract='> These policy claims are quoted examples:
```bad`info
The live global contract at ~/AGENTS.md applies.' ;;
    global_contract_blockquoted) global_contract='> The live global contract is ~/AGENTS.md.' ;;
    global_contract_list_blockquoted) global_contract='- > The live global contract is ~/AGENTS.md.' ;;
    global_contract_lazy_blockquoted) global_contract='> These paths are quoted examples:
The live global contract is ~/AGENTS.md.' ;;
    blockquote_heading_interrupt) global_contract='> This is a quoted example.
## Contract sources
The live global contract at ~/AGENTS.md applies.' ;;
    global_contract_list_fenced) global_contract='- ```text
  ~/AGENTS.md
  ```' ;;
    global_contract_fenced) global_contract='```text
~/AGENTS.md
```' ;;
    global_contract_commented) global_contract='<!-- ~/AGENTS.md -->' ;;
    contract_wrong_path) fleet_contract='docs/FLEET.md governs this repo.' ;;
    contract_negated) fleet_contract='FLEET.md does not govern this repo.' ;;
    contract_meta_negated) fleet_contract='Never say FLEET.md governs this repo.' ;;
    contract_labeled_negated) fleet_contract='False. FLEET.md governs this repo.' ;;
    contract_labeled_negated_clause) fleet_contract='Wrong; FLEET.md governs this repo.' ;;
    contract_house_form) fleet_contract='`FLEET.md` governs where it and this summary differ.' ;;
    contract_colon_example) fleet_contract='The following is an inert illustrative example of the house form: FLEET.md governs this repo.' ;;
    contract_house_form_trailing) fleet_contract='`FLEET.md` governs where it and this summary differ — and it lives in this repo, so read it rather than this summary.' ;;
    contract_fence_false_closer) fleet_contract='```text
- ```
FLEET.md governs this repo.
- ```
```' ;;
    contract_list_fence_closed) fleet_contract='- ```text
  FLEET.md
  ```

FLEET.md governs this repo.' ;;
    contract_blockquoted) fleet_contract='> FLEET.md governs this repo.' ;;
    contract_list_blockquoted) fleet_contract='- > FLEET.md governs this repo.' ;;
    contract_lazy_blockquoted) fleet_contract='> This path is a quoted example:
FLEET.md governs this repo.' ;;
    contract_list_fenced) fleet_contract='- ```text
  FLEET.md
  ```' ;;
    waiver_prefixed) waiver='Note: Stack exception (owner-approved 2026-08-20): MongoDB required.' ;;
    waiver_blank) waiver='Stack exception (owner-approved 2026-08-20):   ' ;;
    waiver_future) waiver='Stack exception (owner-approved 2099-08-20): MongoDB required.' ;;
    waiver_fenced) waiver='```
Stack exception (owner-approved 2026-08-20): MongoDB required.
```' ;;
    waiver_tilde_fenced) waiver='~~~
Stack exception (owner-approved 2026-08-20): MongoDB required.
~~~' ;;
    waiver_mismatched_fence) waiver='````
~~~
Stack exception (owner-approved 2026-08-20): MongoDB required.
````' ;;
    waiver_short_fence) waiver='````
```
Stack exception (owner-approved 2026-08-20): MongoDB required.
````' ;;
    waiver_commented) waiver='<!--
Stack exception (owner-approved 2026-08-20): MongoDB required.
-->' ;;
    waiver_indented) waiver='    Stack exception (owner-approved 2026-08-20): MongoDB required.' ;;
    waiver_valid) waiver='Stack exception (owner-approved 2026-08-20): MongoDB required.' ;;
  esac
  if [ "$MOCK_SCENARIO" = contract_fenced ]; then
    printf '%s\n' \
      "$global_contract" \
      '```text' \
      'FLEET.md governs this repo.' \
      "$cycle" \
      'Workflows: ci.yml, security.yml, claude-review.yml, dependabot-auto-merge.yml, all enforced.' \
      '```' \
      'No operative fleet contract is present.'
    return
  fi
  if [ "$MOCK_SCENARIO" = contract_commented ]; then
    printf '%s\n' \
      "$global_contract" \
      '<!--' \
      'FLEET.md governs this repo.' \
      "$cycle" \
      'Workflows: ci.yml, security.yml, claude-review.yml, dependabot-auto-merge.yml, all enforced.' \
      '-->' \
      'No operative fleet contract is present.'
    return
  fi
  if [ "$MOCK_SCENARIO" = contract_indented ]; then
    printf '%s\n' \
      "$global_contract" \
      '    FLEET.md governs this repo.' \
      "    $cycle" \
      '    Workflows: ci.yml, security.yml, claude-review.yml, dependabot-auto-merge.yml, all enforced.' \
      'No operative fleet contract is present.'
    return
  fi
  printf '%s\n' \
    "$global_contract" \
    "$fleet_contract" \
    "$cycle" \
    'Workflows: ci.yml, security.yml, claude-review.yml, dependabot-auto-merge.yml, all enforced.' \
    "$waiver"
}

package_body() {
  case "$MOCK_SCENARIO" in
    script_misleading)
      printf '%s' '{"scripts":{"typecheck-ci":"x","lint:ci":"x","test:unit":"x","check":""},"dependencies":{}}'
      ;;
    waiver_prefixed|waiver_blank|waiver_future|waiver_fenced|waiver_tilde_fenced|waiver_mismatched_fence|waiver_short_fence|waiver_commented|waiver_indented|waiver_valid)
      printf '%s' '{"scripts":{"typecheck":"x","lint":"x","test":"x"},"dependencies":{"mongodb":"x"}}'
      ;;
    *)
      printf '%s' '{"scripts":{"typecheck":"x","lint":"x","test":"x"},"dependencies":{}}'
      ;;
  esac
}

dependabot_body() {
  case "$MOCK_SCENARIO" in
    cooldown_split)
      cat <<'YAML'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
    # default-days: 7
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
YAML
      ;;
    ecosystem_missing)
      cat <<'YAML'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
YAML
      ;;
    nested_lockfile|nested_lockfile_no_scan|nested_lockfile_mismatch)
      cat <<'YAML'
version: 2
updates:
  - package-ecosystem: npm
    directory: /theme
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
YAML
      ;;
    zero_lanes)
      printf '%s\n' 'version: 2' 'updates: []'
      ;;
    dependabot_lane_disabled)
      cat <<'YAML'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    schedule:
      interval: weekly
    open-pull-requests-limit: 0
    cooldown:
      default-days: 7
YAML
      ;;
    cooldown_misplaced)
      cat <<'YAML'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    schedule:
      interval: weekly
    labels:
      default-days: 7
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
YAML
      ;;
    *)
      cat <<'YAML'
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
YAML
      ;;
  esac
}

security_body() {
  daily='    - cron: "17 13 * * *"'
  push_line='  push:'
  dependency_if=''
  unrelated_cron_job=''
  semgrep_command='        run: semgrep scan --config auto --error'
  gitleaks_step='      - uses: gitleaks/gitleaks-action@cccccccccccccccccccccccccccccccccccccccc # v3.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}'
  pin='      - uses: windwardline/windwardline/actions/verify-action-pins@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0'
  header='  headers-live:
    name: Headers live
    if: github.event_name != '\''pull_request'\''
    timeout-minutes: 12
    runs-on: ubuntu-latest
    steps:
      - name: Assert the seven security headers on production
        uses: windwardline/windwardline/actions/verify-live-headers@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
        with:
          url: https://fixture.example.com'
  managed_edge=''
  dependency='  dependency-scan:
    name: Dependency scan
    uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v2.5.0
    with:
      scan-args: --lockfile=package-lock.json
      fail-on-vuln: true
      upload-sarif: false
    permissions:
      actions: read
      contents: read
      security-events: write'
  case "$MOCK_SCENARIO" in
    weekly_only) daily='' ;;
    no_push_trigger) push_line='' ;;
    semgrep_noop) semgrep_command='        run: "true"' ;;
    gitleaks_missing) gitleaks_step='      - run: echo no secret scan' ;;
    osv_fail_open) dependency=${dependency/fail-on-vuln: true/fail-on-vuln: false} ;;
    scan_guarded) dependency_if="    if: github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1'" ;;
    push_only) dependency_if="    if: github.event_name == 'push'" ;;
    no_scan|nested_lockfile_no_scan)
      dependency='  # dependency-scan:
  #   name: Dependency scan
  #   uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v2.5.0'
      ;;
    nested_lockfile)
      dependency=${dependency/--lockfile=package-lock.json/--lockfile=theme\/pnpm-lock.yaml}
      ;;
    pin_commented)
      pin='      # uses: windwardline/windwardline/actions/verify-action-pins@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
      - run: echo no pin gate'
      ;;
    pin_run_text)
      pin='      - name: Fake pin gate
        run: |
          - uses: windwardline/windwardline/actions/verify-action-pins@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0'
      ;;
    pin_wrong_job)
      pin='      - run: echo no pin gate'
      dependency='  fake-pin-job:
    name: Not Secret scan
    runs-on: ubuntu-latest
    steps:
      - uses: windwardline/windwardline/actions/verify-action-pins@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
  dependency-scan:
    name: Dependency scan
    uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v2.5.0
    with:
      scan-args: --lockfile=package-lock.json
      fail-on-vuln: true
      upload-sarif: false
    permissions:
      actions: read
      contents: read
      security-events: write'
      ;;
    pin_if_false)
      pin='      - uses: windwardline/windwardline/actions/verify-action-pins@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
        if: false'
      ;;
    pin_if_expression)
      pin='      - uses: windwardline/windwardline/actions/verify-action-pins@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
        if: github.actor == '\''nobody'\'''
      ;;
    pin_continue_on_error)
      pin='      - uses: windwardline/windwardline/actions/verify-action-pins@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
        continue-on-error: true'
      ;;
    pin_continue_expression)
      pin='      - uses: windwardline/windwardline/actions/verify-action-pins@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
        continue-on-error: ${{ github.actor == '\''nobody'\'' }}'
      ;;
    stale_pin_release)
      pin='      - uses: windwardline/windwardline/actions/verify-action-pins@dddddddddddddddddddddddddddddddddddddddd # v0.9.0'
      ;;
    header_missing)
      header=''
      ;;
    header_inline)
      header='  headers-live:
    name: Headers live
    if: github.event_name != '\''pull_request'\''
    timeout-minutes: 12
    runs-on: ubuntu-latest
    steps:
      - name: Assert the seven security headers on production
        run: curl https://fixture.example.com'
      ;;
    header_stale_ref)
      header=${header/verify-live-headers@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/verify-live-headers@dddddddddddddddddddddddddddddddddddddddd}
      ;;
    header_wrong_url)
      header=${header/https:\/\/fixture.example.com/https:\/\/other.example.com}
      ;;
    ghost_valid|ghost_stale_ref|ghost_inline|ghost_header_conflict|ghost_unregistered)
      managed_edge='  ghost-managed-edge:
    name: Ghost managed edge
    if: github.event_name != '\''pull_request'\''
    timeout-minutes: 12
    runs-on: ubuntu-latest
    steps:
      - name: Verify the managed Ghost production edge
        uses: windwardline/windwardline/actions/verify-ghost-managed-edge@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0'
      [ "$MOCK_SCENARIO" = ghost_header_conflict ] || header=''
      [ "$MOCK_SCENARIO" = ghost_stale_ref ] \
        && managed_edge=${managed_edge/verify-ghost-managed-edge@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/verify-ghost-managed-edge@dddddddddddddddddddddddddddddddddddddddd}
      [ "$MOCK_SCENARIO" = ghost_inline ] \
        && managed_edge='  ghost-managed-edge:
    name: Ghost managed edge
    if: github.event_name != '\''pull_request'\''
    timeout-minutes: 12
    runs-on: ubuntu-latest
    steps:
      - name: Verify the managed Ghost production edge
        run: curl https://grownmengrow.com'
      ;;
    ghost_missing)
      header=''
      ;;
    dependent_on_guarded)
      dependency='  prep:
    name: Daily preparation
    if: github.event_name == '\''push'\''
    runs-on: ubuntu-latest
    steps:
      - run: echo prepare
  dependency-scan:
    name: Dependency scan
    needs: prep
    uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v2.5.0
    with:
      scan-args: --lockfile=package-lock.json
      fail-on-vuln: true
      upload-sarif: false
    permissions:
      actions: read
      contents: read
      security-events: write'
      ;;
    dependent_schedule_only)
      dependency='  prep:
    name: Daily preparation
    if: github.event_name == '''schedule'''
    runs-on: ubuntu-latest
    steps:
      - run: echo prepare
  dependency-scan:
    name: Dependency scan
    needs: prep
    uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v2.5.0
    with:
      scan-args: --lockfile=package-lock.json
      fail-on-vuln: true
      upload-sarif: false
    permissions:
      actions: read
      contents: read
      security-events: write'
      ;;
    header_push_blocked)
      unrelated_cron_job='  header-prep:
    name: Header preparation
    if: github.event_name == '''schedule'''
    runs-on: ubuntu-latest
    steps:
      - run: echo prepare'
      header='  headers-live:
    name: Headers live
    if: github.event_name != '''pull_request'''
    needs: header-prep
    timeout-minutes: 12
    runs-on: ubuntu-latest
    steps:
      - name: Assert the seven security headers on production
        uses: windwardline/windwardline/actions/verify-live-headers@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0
        with:
          url: https://fixture.example.com'
      ;;
    dependent_on_guarded_with_headers)
      header='  headers-live:
    name: Headers live
    if: github.event_name != '\''pull_request'\''
    timeout-minutes: 12
    runs-on: ubuntu-latest
    steps:
      - name: Assert the seven security headers on production
        run: curl https://fixture.example.com'
      dependency='  prep:
    name: Daily preparation
    if: github.event_name == '\''push'\''
    runs-on: ubuntu-latest
    steps:
      - run: echo prepare
  dependency-scan:
    name: Dependency scan
    needs: prep
    uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v2.5.0
    with:
      scan-args: --lockfile=package-lock.json
      fail-on-vuln: true
      upload-sarif: false
    permissions:
      actions: read
      contents: read
      security-events: write'
      ;;
    cron_outside_on)
      daily=''
      unrelated_cron_job='  schedule-looking-matrix:
    name: Schedule-looking matrix
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - cron: "17 13 * * *"
    steps:
      - run: echo schedule matrix'
      ;;
  esac
  schedule_block='  schedule:
    - cron: "17 9 * * 1"'
  if [ -n "$daily" ]; then
    schedule_block="$schedule_block
$daily"
  elif [ "$MOCK_SCENARIO" = cron_outside_on ]; then
    schedule_block=''
  fi
  semgrep_if="    if: github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1'"
  secret_if="    if: github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1'"
  case "$MOCK_SCENARIO" in
    actor_guard_variant) semgrep_if='    if: ${{ github.actor!="dependabot[bot]" }}' ;;
    actor_guard_negated) semgrep_if='    if: ${{ !(github.actor == "dependabot[bot]") }}' ;;
    actor_guard_negated_reverse) semgrep_if='    if: ${{ !("dependabot[bot]" == github.actor) }}' ;;
    actor_guard_commented) semgrep_if="    if: github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1' # github.actor != \"dependabot[bot]\"" ;;
    actor_guard_startswith) semgrep_if="    if: \${{ !startsWith(github.actor, 'dependabot') }}" ;;
    pin_job_push_only) secret_if="    if: github.event_name == 'push'" ;;
  esac
  permissions_actions=read
  [ "$MOCK_SCENARIO" = security_root_permissions ] && permissions_actions=write
  printf '%s\n' \
    'name: Security analysis' \
    'on:' \
    '  pull_request:' \
    "$push_line" \
    "$schedule_block" \
    'permissions:' \
    "  actions: $permissions_actions" \
    '  contents: read' \
    '  pull-requests: read' \
    '  security-events: write' \
    'jobs:' \
    "$unrelated_cron_job" \
    '  semgrep:' \
    '    name: Semgrep CE' \
    "$semgrep_if" \
    '    runs-on: ubuntu-latest' \
    '    timeout-minutes: 15' \
    '    container:' \
    '      image: semgrep/semgrep@sha256:2b33f46ba66cf8cc2ad59ccfa7d22951fd00c632c38f1339e84ec8e6e641a942' \
    '    steps:' \
    '      - uses: actions/checkout@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee # v7.0.1' \
    '        with:' \
    '          persist-credentials: false' \
    '      - name: Scan application and workflow code' \
    "$semgrep_command" \
    '  secret-scan:' \
    '    name: Secret scan' \
    "$secret_if" \
    '    runs-on: ubuntu-latest' \
    '    timeout-minutes: 10' \
    '    steps:' \
    '      - uses: actions/checkout@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee # v7.0.1' \
    '        with:' \
    '          fetch-depth: 0' \
    '          persist-credentials: false' \
    "$gitleaks_step" \
    "$pin" \
    "$header" \
    "$managed_edge" \
    "$dependency" \
    "$dependency_if"
}

vercel_body() {
  if [ "$MOCK_SCENARIO" = split_header_routes ]; then
    cat <<'JSON'
{"headers":[{"source":"/api/(.*)","headers":[{"key":"Content-Security-Policy"},{"key":"Strict-Transport-Security"},{"key":"X-Content-Type-Options"}]},{"source":"/assets/(.*)","headers":[{"key":"Referrer-Policy"},{"key":"X-Frame-Options"},{"key":"Permissions-Policy"},{"key":"Cross-Origin-Opener-Policy"}]}]}
JSON
    return
  fi
  cat <<'JSON'
{"headers":[{"source":"/(.*)","headers":[{"key":"Content-Security-Policy"},{"key":"Strict-Transport-Security"},{"key":"X-Content-Type-Options"},{"key":"Referrer-Policy"},{"key":"X-Frame-Options"},{"key":"Permissions-Policy"},{"key":"Cross-Origin-Opener-Policy"}]}]}
JSON
}

ruleset_body() {
  if [ "$MOCK_SCENARIO" = bad_ruleset ]; then
    cat <<'JSON'
{"name":"main-requires-green-ci","enforcement":"evaluate","target":"tag","conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":["refs/heads/release"]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"CI"},{"context":"Semgrep CE"},{"context":"Secret scan"},{"context":"Dependency scan / osv-scan"},{"context":"dependabot-auto-merge"},{"context":"review / review"},{"context":"Vercel"}]}},{"type":"required_linear_history"}]}
JSON
  elif [ "$MOCK_SCENARIO" = missing_force_push_rule ]; then
    cat <<'JSON'
{"name":"main-requires-green-ci","enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"CI"},{"context":"Semgrep CE"},{"context":"Secret scan"},{"context":"Dependency scan / osv-scan"}]}},{"type":"required_linear_history"}]}
JSON
  elif [ "$MOCK_SCENARIO" = headers_required_context ]; then
    cat <<'JSON'
{"name":"main-requires-green-ci","enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"CI"},{"context":"Semgrep CE"},{"context":"Secret scan"},{"context":"Dependency scan / osv-scan"},{"context":"Headers live"}]}},{"type":"required_linear_history"},{"type":"non_fast_forward"}]}
JSON
  elif [ "$MOCK_SCENARIO" = external_required_context ]; then
    cat <<'JSON'
{"name":"main-requires-green-ci","enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"CI"},{"context":"Semgrep CE"},{"context":"Secret scan"},{"context":"Dependency scan / osv-scan"},{"context":"Acme Deploy"}]}},{"type":"required_linear_history"},{"type":"non_fast_forward"}]}
JSON
  elif [ "$MOCK_SCENARIO" = skipped_required_context ]; then
    cat <<'JSON'
{"name":"main-requires-green-ci","enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"CI"},{"context":"Semgrep CE"},{"context":"Secret scan"},{"context":"Dependency scan / osv-scan"},{"context":"Optional platform"}]}},{"type":"required_linear_history"},{"type":"non_fast_forward"}]}
JSON
  else
    cat <<'JSON'
{"name":"main-requires-green-ci","enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"CI"},{"context":"Semgrep CE"},{"context":"Secret scan"},{"context":"Dependency scan / osv-scan"}]}},{"type":"required_linear_history"},{"type":"non_fast_forward"}]}
JSON
  fi
}

ruleset_response() {
  body=$(ruleset_body)
  body=$(printf '%s' "$body" | jq -c '
    (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]) += {integration_id: 15368}
  ')
  case "$MOCK_SCENARIO" in
    ruleset_source_missing)
      printf '%s' "$body" | jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | select(.context == "CI")) |= del(.integration_id)'
      ;;
    ruleset_source_null)
      printf '%s' "$body" | jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | select(.context == "CI") | .integration_id) = null'
      ;;
    ruleset_source_wrong)
      printf '%s' "$body" | jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | select(.context == "CI") | .integration_id) = 999'
      ;;
    ruleset_source_malformed)
      printf '%s' "$body" | jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | select(.context == "CI") | .integration_id) = "github-actions"'
      ;;
    *) printf '%s' "$body" ;;
  esac
}

jobs_body() {
  if [ "$MOCK_SCENARIO" = "zero_jobs" ]; then
    printf '%s\n' '{"total_count":0,"jobs":[]}'
  elif [ "$MOCK_SCENARIO" = "pending_job" ]; then
    printf '%s\n' '{"total_count":1,"jobs":[{"id":1,"name":"CI","status":"in_progress","conclusion":null}]}'
  elif [ "$MOCK_SCENARIO" = "job_total_overflow" ]; then
    printf '%s\n' '{"total_count":3,"jobs":[{"id":1,"name":"CI","status":"completed","conclusion":"success"},{"id":2,"name":"Semgrep CE","status":"completed","conclusion":"success"},{"id":3,"name":"Secret scan","status":"completed","conclusion":"success"},{"id":4,"name":"Dependency scan / osv-scan","status":"completed","conclusion":"success"}]}'
  elif [ "$MOCK_SCENARIO" = "duplicate_job_name" ]; then
    printf '%s\n' '{"total_count":5,"jobs":[{"id":1,"name":"CI","status":"completed","conclusion":"success"},{"id":2,"name":"CI","status":"completed","conclusion":"success"},{"id":3,"name":"Semgrep CE","status":"completed","conclusion":"success"},{"id":4,"name":"Secret scan","status":"completed","conclusion":"success"},{"id":5,"name":"Dependency scan / osv-scan","status":"completed","conclusion":"success"}]}'
  elif [ "$MOCK_SCENARIO" = "failed_unrequired" ]; then
    cat <<'JSON'
{"total_count":4,"jobs":[{"id":1,"name":"CI","status":"completed","conclusion":"success"},{"id":2,"name":"Semgrep CE","status":"completed","conclusion":"success"},{"id":3,"name":"Secret scan","status":"completed","conclusion":"success"},{"id":4,"name":"Ungated failed","status":"completed","conclusion":"failure"}]}
JSON
  elif [ "$MOCK_SCENARIO" = "cancelled_unrequired" ]; then
    cat <<'JSON'
{"total_count":5,"jobs":[{"id":1,"name":"CI","status":"completed","conclusion":"success"},{"id":2,"name":"Semgrep CE","status":"completed","conclusion":"success"},{"id":3,"name":"Secret scan","status":"completed","conclusion":"success"},{"id":4,"name":"Dependency scan / osv-scan","status":"completed","conclusion":"success"},{"id":5,"name":"Ungated cancelled","status":"completed","conclusion":"cancelled"}]}
JSON
  elif [ "$MOCK_SCENARIO" = "incomplete_job_page" ]; then
    cat <<'JSON'
{"total_count":5,"jobs":[{"id":1,"name":"CI","status":"completed","conclusion":"success"},{"id":2,"name":"Semgrep CE","status":"completed","conclusion":"success"},{"id":3,"name":"Secret scan","status":"completed","conclusion":"success"},{"id":4,"name":"Dependency scan / osv-scan","status":"completed","conclusion":"success"}]}
JSON
  elif [ "$MOCK_SCENARIO" = "skipped_required_context" ]; then
    cat <<'JSON'
{"total_count":5,"jobs":[{"id":1,"name":"CI","status":"completed","conclusion":"success"},{"id":2,"name":"Semgrep CE","status":"completed","conclusion":"success"},{"id":3,"name":"Secret scan","status":"completed","conclusion":"success"},{"id":4,"name":"Dependency scan / osv-scan","status":"completed","conclusion":"success"},{"id":5,"name":"Optional platform","status":"completed","conclusion":"skipped"}]}
JSON
  elif [ "$MOCK_SCENARIO" = "review_prefix_nonreview" ]; then
    cat <<'JSON'
{"total_count":5,"jobs":[{"id":1,"name":"CI","status":"completed","conclusion":"success"},{"id":2,"name":"Semgrep CE","status":"completed","conclusion":"success"},{"id":3,"name":"Secret scan","status":"completed","conclusion":"success"},{"id":4,"name":"Dependency scan / osv-scan","status":"completed","conclusion":"success"},{"id":5,"name":"review / build","status":"completed","conclusion":"failure"}]}
JSON
  else
    cat <<'JSON'
{"total_count":4,"jobs":[{"id":1,"name":"CI","status":"completed","conclusion":"success"},{"id":2,"name":"Semgrep CE","status":"completed","conclusion":"success"},{"id":3,"name":"Secret scan","status":"completed","conclusion":"success"},{"id":4,"name":"Dependency scan / osv-scan","status":"completed","conclusion":"success"}]}
JSON
  fi
}

handoff_body() {
  if [ "$MOCK_SCENARIO" = handoff_commented_prompt ]; then
    cat <<'MD'
# Handoff
### 6b. CONVERGE — executable prompt
<!--
```
(1) **FIND.** Evidence.
(2) **REFUTE.** Evidence.
(3) **VERIFY YOURSELF.** Evidence.
(4) **FIX.** Evidence.
(5) **RE-RANK.** Evidence.
(6) **TEST.** Evidence.
(7) **UPDATE.** Evidence.
(8) **REPORT.** Evidence.
- **Enumerate the gates; never count them.** Evidence.
- **Stage explicit paths. Never `git add -A`.** Evidence.
- **Validate before mutating.** Evidence.
- **Preserve standing claims.** Evidence.
- **Derive populations; do not curate them.** Evidence.
- **A harness failure must never read as the subject refusing.** Evidence.
```
-->
### 6b-i. Next section
MD
    return
  fi
  if [ "$MOCK_SCENARIO" = handoff_fake_closer ]; then
    cat <<'MD'
# Handoff
### 6b. CONVERGE — executable prompt
```
(1) **FIND.** Evidence.
```junk
### 6b-i. Next section
MD
    return
  fi
  if [ "$MOCK_SCENARIO" = handoff_prose_only ]; then
    cat <<'MD'
# Handoff
### 6b. CONVERGE — executable prompt
```
(1) **FIND.** Evidence.
(2) **VERIFY YOURSELF.** Evidence.
(3) **FIX.** Evidence.
(4) **RE-RANK.** Evidence.
(5) **TEST.** Evidence.
(6) **UPDATE.** Evidence.
(7) **REPORT.** Evidence.
- **Enumerate the gates; never count them.** Evidence.
- **Stage explicit paths. Never `git add -A`.** Evidence.
- **Validate before mutating.** Evidence.
- **Preserve standing claims.** Evidence.
- **Derive populations; do not curate them.** Evidence.
- **A harness failure must never read as the subject refusing.** Evidence.
```
REFUTE, VERIFY YOURSELF, FIX, RE-RANK, TEST, UPDATE, and REPORT are discussed in surrounding prose.
### 6b-i. Next section
MD
    return
  fi
  if [ "$MOCK_SCENARIO" = handoff_delivery_prose_only ]; then
    delivery_sixth='A harness failure must never read as the subject refusing. This is surrounding prose, not a prompt bullet.'
  else
    delivery_sixth='- **A harness failure must never read as the subject refusing.** Evidence.'
  fi
  cat <<'MD'
# Handoff
### 6b. CONVERGE — executable prompt
```
(1) **FIND.** Evidence.
(2) **REFUTE.** Evidence.
(3) **VERIFY YOURSELF.** Evidence.
(4) **FIX.** Evidence.
(5) **RE-RANK.** Evidence.
(6) **TEST.** Evidence.
(7) **UPDATE.** Evidence.
(8) **REPORT.** Evidence.

- **Enumerate the gates; never count them.** Evidence.
- **Stage explicit paths. Never `git add -A`.** Evidence.
- **Validate before mutating.** Evidence.
- **Preserve standing claims.** Evidence.
- **Derive populations; do not curate them.** Evidence.
MD
  printf '%s\n' "$delivery_sixth"
  cat <<'MD'
```
### 6b-i. Next section
MD
}

suppression_body() {
  case "$MOCK_SCENARIO" in
    empty_suppression_reason)
      printf '%s\n' '[[IgnoredVulns]]' 'id = "GHSA-test"' 'reason = ""' 'ignoreUntil = "2099-01-01"'
      ;;
    invalid_suppression_date)
      printf '%s\n' '[[IgnoredVulns]]' 'id = "GHSA-test"' 'reason = "No fixed release"' 'ignoreUntil = "2099-02-30"'
      ;;
  esac
}

emit() {
  status=$1
  body=$2
  if [ "$include" -eq 1 ]; then
    reason=OK
    [ "$status" = 404 ] && reason='Not Found'
    [ "$status" = 403 ] && reason='Forbidden'
    printf 'HTTP/2.0 %s %s\nContent-Type: application/json\n\n%s\n' "$status" "$reason" "$body"
  elif [ "$silent" -eq 0 ]; then
    if [ -n "$jq_expr" ]; then
      printf '%s' "$body" | jq -r "$jq_expr"
    else
      printf '%s\n' "$body"
    fi
  fi
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    printf 'gh: %s (HTTP %s)\n' "$body" "$status" >&2
    return 1
  fi
}

cmd=${1:-}
shift || true

case "$cmd" in
  repo)
    sub=${1:-}; shift || true
    [ "$sub" = list ] || exit 97
    args="$*"
    if [ "$MOCK_SCENARIO" = template_repo ] && printf '%s' "$args" | grep -q 'isTemplate'; then
      exit 0
    fi
    if printf '%s' "$args" | grep -q visibility; then
      printf '%s\n' 'fixture PUBLIC'
    else
      printf '%s\n' fixture
    fi
    exit 0
    ;;
  pr)
    [ "${1:-}" = list ] || exit 97
    printf '%s\n' cccccccccccccccccccccccccccccccccccccccc
    exit 0
    ;;
  secret)
    [ "${1:-}" = list ] || exit 97
    shift
    jq_expr=''
    while [ "$#" -gt 0 ]; do
      [ "$1" = --jq ] && { shift; jq_expr=$1; }
      shift
    done
    body='[{"name":"CLAUDE_CODE_OAUTH_TOKEN"}]'
    if [ -n "$jq_expr" ]; then printf '%s' "$body" | jq -r "$jq_expr"; else printf '%s\n' "$body"; fi
    exit 0
    ;;
  api) ;;
  *) exit 97 ;;
esac

endpoint=''
jq_expr=''
include=0
silent=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) shift; jq_expr=$1 ;;
    --include) include=1 ;;
    --silent) silent=1 ;;
    --paginate|--slurp) ;;
    -*) ;;
    *) [ -z "$endpoint" ] && endpoint=$1 ;;
  esac
  shift
done

case "$endpoint" in
  repos/windwardline/fixture2/*) endpoint="repos/windwardline/fixture/${endpoint#repos/windwardline/fixture2/}" ;;
  repos/windwardline/fixture2) endpoint='repos/windwardline/fixture' ;;
esac

local_sha=$(git hash-object "$MOCK_SUBJECT/templates/dependabot-auto-merge.yml")
canonical_sha=$local_sha
[ "$MOCK_SCENARIO" = remote_template ] && canonical_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
local_scratch_sha=$(git hash-object "$MOCK_SUBJECT/templates/scratch-clone.sh")
canonical_scratch_sha=$local_scratch_sha
[ "$MOCK_SCENARIO" = scratch_copy_drift ] && repository_scratch_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
repository_scratch_sha=${repository_scratch_sha:-$canonical_scratch_sha}

case "$endpoint" in
  user/repos*|users/windwardline/repos*)
    if [ "$MOCK_SCENARIO" = repo_repeated_page ]; then
      page_body=$(jq -nc '[range(1;101) | {name:("archived-" + tostring),archived:true,is_template:false,visibility:"public",default_branch:"main",owner:{login:"windwardline"}}]')
      emit 200 "$page_body"
    elif printf '%s' "$endpoint" | grep -q 'page=2'; then
      emit 200 '[]'
    else
      template=false
      [ "$MOCK_SCENARIO" = template_repo ] && template=true
      visibility=public
      [ "$MOCK_SCENARIO" = internal_visibility ] && visibility=internal
      if [ "$MOCK_SCENARIO" = two_repos ]; then
        emit 200 '[{"name":"fixture","archived":false,"is_template":false,"visibility":"public","default_branch":"main","owner":{"login":"windwardline"}},{"name":"fixture2","archived":false,"is_template":false,"visibility":"public","default_branch":"main","owner":{"login":"windwardline"}}]'
      else
        emit 200 "[{\"name\":\"fixture\",\"archived\":false,\"is_template\":$template,\"visibility\":\"$visibility\",\"default_branch\":\"main\",\"owner\":{\"login\":\"windwardline\"}}]"
      fi
    fi
    ;;
  apps/github-actions)
    case "$MOCK_SCENARIO" in
      app_identity_malformed) emit 200 '{"id":"15368","slug":"github-actions","owner":{"login":"github"}}' ;;
      app_identity_refused) emit 403 '{"message":"Forbidden"}' ;;
      *) emit 200 '{"id":15368,"slug":"github-actions","owner":{"login":"github"}}' ;;
    esac
    ;;
  repos/windwardline/windwardline/contents/templates/claude-review.yml*)
    review_sha=d2ef3e401767662eacf7f78cbe7c4f5e71eeeb6d
    [ "$MOCK_SCENARIO" = review_canonical_drift ] && review_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    [ "$MOCK_SCENARIO" = review_canonical_refused ] && { emit 403 '{"message":"Forbidden"}'; exit $?; }
    emit 200 "{\"sha\":\"$review_sha\",\"content\":\"WA==\"}"
    ;;
  repos/windwardline/windwardline/contents/templates/dependabot-auto-merge.yml*)
    emit 200 "{\"sha\":\"$canonical_sha\",\"content\":\"WA==\"}"
    ;;
  repos/windwardline/windwardline/contents/templates/scratch-clone.sh*)
    if [ "$MOCK_SCENARIO" = scratch_canonical_refused ]; then
      emit 403 '{"message":"Forbidden"}'
    else
      emit 200 "{\"sha\":\"$canonical_scratch_sha\",\"content\":\"WA==\"}"
    fi
    ;;
  repos/windwardline/fixture/contents/.github/workflows/dependabot-auto-merge.yml*)
    emit 200 "{\"sha\":\"$canonical_sha\",\"content\":\"WA==\"}"
    ;;
  repos/windwardline/fixture/contents/scripts/scratch-clone.sh*)
    if [ "$MOCK_SCENARIO" = scratch_copy_missing ]; then
      emit 404 '{"message":"Not Found"}'
    elif [ "$MOCK_SCENARIO" = scratch_copy_refused ]; then
      emit 403 '{"message":"Forbidden"}'
    else
      emit 200 "{\"sha\":\"$repository_scratch_sha\",\"content\":\"WA==\"}"
    fi
    ;;
  repos/windwardline/fixture/contents/.github/dependabot.yml*)
    emit 200 "$(content_json "$(dependabot_body)")"
    ;;
  repos/windwardline/fixture/contents/.github/workflows/security.yml*)
    if [ "$MOCK_SCENARIO" = malformed_required ]; then
      emit 200 '{"sha":"1111111111111111111111111111111111111111","content":"%%%"}'
    elif [ "$MOCK_SCENARIO" = truncated_required ]; then
      emit 200 '{"sha":"1111111111111111111111111111111111111111","content":"YWJjZA"}'
    else
      emit 200 "$(content_json "$(security_body)")"
    fi
    ;;
  repos/windwardline/fixture/contents/.github/workflows/claude-review.yml*)
    caller_sha=d2ef3e401767662eacf7f78cbe7c4f5e71eeeb6d
    [ "$MOCK_SCENARIO" = review_caller_drift ] && caller_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    emit 200 "{\"sha\":\"$caller_sha\",\"content\":\"WA==\"}"
    ;;
  repos/windwardline/fixture/contents/AGENTS.md*)
    emit 200 "$(content_json "$(agents_body)")"
    ;;
  repos/windwardline/fixture/contents/CLAUDE.md*)
    claude='@AGENTS.md
'
    case "$MOCK_SCENARIO" in
      bad_claude) claude='@AGENTS.md
extra' ;;
      claude_no_lf) claude='@AGENTS.md' ;;
      claude_two_lf) claude='@AGENTS.md

' ;;
    esac
    emit 200 "$(content_json "$claude")"
    ;;
  repos/windwardline/fixture/contents/vercel.json*|repos/windwardline/fixture/contents/apps/web/vercel.json*)
    emit 200 "$(content_json "$(vercel_body)")"
    ;;
  repos/windwardline/fixture/contents/package.json*)
    emit 200 "$(content_json "$(package_body)")"
    ;;
  repos/windwardline/fixture/contents/package-lock.json*)
    if [ "$MOCK_SCENARIO" = no_lockfile ]; then emit 404 '{"message":"Not Found"}'; else emit 200 "$(content_json '{}')"; fi
    ;;
  repos/windwardline/fixture/contents/pnpm-lock.yaml*|repos/windwardline/fixture/contents/yarn.lock*|repos/windwardline/fixture/contents/bun.lockb*)
    emit 404 '{"message":"Not Found"}'
    ;;
  repos/windwardline/fixture/contents/.github/workflows*)
    if [ "$endpoint" = 'repos/windwardline/fixture/contents/.github/workflows?ref=main' ]; then
      emit 200 '[{"name":"ci.yml"},{"name":"security.yml"},{"name":"claude-review.yml"},{"name":"dependabot-auto-merge.yml"}]'
    else
      emit 200 "$(content_json 'fixture')"
    fi
    ;;
  repos/windwardline/fixture/contents/SECURITY.md*)
    if [ "$MOCK_SCENARIO" = security_origin_missing ]; then
      emit 200 "$(content_json 'This repository has no declared deployment.')"
    elif [ "$MOCK_SCENARIO" = security_origin_non_ascii ]; then
      # craft's real SECURITY.md carries an arrow here. Under a scheduled task
      # (LANG unset) ruby reads this as US-ASCII and String#scan raises.
      emit 200 "$(content_json 'Report via the workflow (Security → Advisories) for https://fixture.example.com')"
    elif [ "${MOCK_SCENARIO#ghost_}" != "$MOCK_SCENARIO" ] \
      && [ "$MOCK_SCENARIO" != ghost_unregistered ]; then
      emit 200 "$(content_json 'This repository and the deployment at https://grownmengrow.com')"
    else
      emit 200 "$(content_json 'This repository and the deployment at https://fixture.example.com')"
    fi
    ;;
  repos/windwardline/fixture/contents/LICENSE*)
    emit 200 "$(content_json 'fixture')"
    ;;
  repos/windwardline/fixture/branches/main)
    emit 200 '{"name":"main","commit":{"sha":"ffffffffffffffffffffffffffffffffffffffff"}}'
    ;;
  repos/windwardline/fixture/git/trees/ffffffffffffffffffffffffffffffffffffffff\?recursive=1)
    if [ "$MOCK_SCENARIO" = no_lockfile ]; then
      lock_entry=''
    elif { [ "$MOCK_SCENARIO" = nested_lockfile ] || [ "$MOCK_SCENARIO" = nested_lockfile_no_scan ] || [ "$MOCK_SCENARIO" = nested_lockfile_mismatch ]; }; then
      lock_entry=',{"path":"theme/pnpm-lock.yaml","type":"blob"}'
    else
      lock_entry=',{"path":"package-lock.json","type":"blob"}'
    fi
    emit 200 "{\"sha\":\"ffffffffffffffffffffffffffffffffffffffff\",\"truncated\":false,\"tree\":[{\"path\":\".github/workflows/ci.yml\",\"type\":\"blob\"},{\"path\":\".github/workflows/security.yml\",\"type\":\"blob\"},{\"path\":\".github/workflows/claude-review.yml\",\"type\":\"blob\"},{\"path\":\".github/workflows/dependabot-auto-merge.yml\",\"type\":\"blob\"}$lock_entry]}"
    ;;
  repos/windwardline/windwardline/git/trees/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\?recursive=1)
    if [ "$MOCK_SCENARIO" = release_action_missing ]; then
      release_paths='[{"path":"actions/verify-action-pins/action.yml","type":"blob"},{"path":"scripts/verify-action-pins.sh","type":"blob"},{"path":"scripts/actions_yaml_inspector.rb","type":"blob"},{"path":"actions/verify-live-headers/action.yml","type":"blob"},{"path":"actions/verify-live-headers/verify-live-headers.sh","type":"blob"},{"path":"actions/verify-ghost-managed-edge/action.yml","type":"blob"}]'
    else
      release_paths='[{"path":"actions/verify-action-pins/action.yml","type":"blob"},{"path":"scripts/verify-action-pins.sh","type":"blob"},{"path":"scripts/actions_yaml_inspector.rb","type":"blob"},{"path":"actions/verify-live-headers/action.yml","type":"blob"},{"path":"actions/verify-live-headers/verify-live-headers.sh","type":"blob"},{"path":"actions/verify-ghost-managed-edge/action.yml","type":"blob"},{"path":"actions/verify-ghost-managed-edge/verify-ghost-managed-edge.sh","type":"blob"}]'
    fi
    emit 200 "{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"truncated\":false,\"tree\":$release_paths}"
    ;;
  repos/windwardline/fixture/contents/netlify.toml*|repos/windwardline/fixture/contents/fly.toml*|repos/windwardline/fixture/contents/render.yaml*|repos/windwardline/fixture/contents/railway.json*|repos/windwardline/fixture/contents/osv-scanner.toml*)
    if { [ "$MOCK_SCENARIO" = empty_suppression_reason ] || [ "$MOCK_SCENARIO" = invalid_suppression_date ]; } \
      && printf '%s' "$endpoint" | grep -q osv-scanner; then
      emit 200 "$(content_json "$(suppression_body)")"
    elif [ "$MOCK_SCENARIO" = false_404_text ] && printf '%s' "$endpoint" | grep -q osv-scanner; then
      emit 403 '{"message":"Not Found while authorization was refused"}'
    else
      emit 404 '{"message":"Not Found"}'
    fi
    ;;
  repos/windwardline/fixture/rulesets\?*)
    if [ "$MOCK_SCENARIO" = ruleset_repeated_page ]; then
      page_body=$(jq -nc '[range(1;101) | {name:(if . == 1 then "main-requires-green-ci" else ("other-" + tostring) end),id:.}]')
      emit 200 "$page_body"
    elif [ "$MOCK_SCENARIO" = ruleset_duplicate_page ]; then
      if printf '%s' "$endpoint" | grep -qE '(^|[?&])page=1($|&)'; then
        page_body=$(jq -nc '[{"name":"main-requires-green-ci","id":1}] + [range(2;101) | {name:("other-" + tostring),id:.}]')
        emit 200 "$page_body"
      else
        emit 200 '[{"name":"main-requires-green-ci","id":101}]'
      fi
    else
      emit 200 '[{"name":"main-requires-green-ci","id":1}]'
    fi
    ;;
  repos/windwardline/fixture/rulesets/1)
    emit 200 "$(ruleset_response)"
    ;;
  repos/windwardline/fixture/pulls*)
    if [ "$MOCK_SCENARIO" = pr_repeated_page ]; then
      page_body=$(jq -nc '[range(1;101) | {number:.,merged_at:"2026-08-19T00:00:00Z",head:{sha:"cccccccccccccccccccccccccccccccccccccccc"},base:{ref:"main"}}]')
      emit 200 "$page_body"
    else
      emit 200 '[{"number":1,"merged_at":"2026-08-19T00:00:00Z","head":{"sha":"cccccccccccccccccccccccccccccccccccccccc"},"base":{"ref":"main"}}]'
    fi
    ;;
  repos/windwardline/fixture/actions/workflows/security.yml)
    case "$MOCK_SCENARIO" in
      workflow_disabled_manually) state=disabled_manually ;;
      workflow_disabled_inactivity) state=disabled_inactivity ;;
      *) state=active ;;
    esac
    emit 200 "{\"path\":\".github/workflows/security.yml\",\"state\":\"$state\"}"
    ;;
  repos/windwardline/fixture/actions/runs\?head_sha=cccccccccccccccccccccccccccccccccccccccc*)
    if [ "$MOCK_SCENARIO" = empty_sample ]; then
      emit 200 '{"total_count":0,"workflow_runs":[]}'
    elif [ "$MOCK_SCENARIO" = run_repeated_page ]; then
      page_body=$(jq -nc '[range(1;101) | {event:"pull_request",status:"completed",id:.,path:".github/workflows/ci.yml"}] | {total_count:200,workflow_runs:.}')
      emit 200 "$page_body"
    elif [ "$MOCK_SCENARIO" = run_total_overflow ]; then
      emit 200 '{"total_count":1,"workflow_runs":[{"event":"pull_request","status":"completed","id":9,"path":".github/workflows/ci.yml"},{"event":"pull_request","status":"completed","id":10,"path":".github/workflows/security.yml"}]}'
    elif [ "$MOCK_SCENARIO" = incomplete_run_page ]; then
      emit 200 '{"total_count":2,"workflow_runs":[{"event":"pull_request","status":"completed","id":9,"path":".github/workflows/ci.yml"}]}'
    else
      emit 200 '{"total_count":1,"workflow_runs":[{"event":"pull_request","status":"completed","id":9,"path":".github/workflows/ci.yml"}]}'
    fi
    ;;
  repos/windwardline/fixture/actions/runs/9/jobs*)
    if [ "$MOCK_SCENARIO" = job_repeated_page ]; then
      page_body=$(jq -nc '[range(1;101) | {id:.,name:("Job " + tostring),status:"completed",conclusion:"success"}] | {total_count:200,jobs:.}')
      emit 200 "$page_body"
    else
      emit 200 "$(jobs_body)"
    fi
    ;;
  repos/windwardline/fixture/actions/secrets*)
    if [ "$MOCK_SCENARIO" = actions_secret_repeated_page ]; then
      page_body=$(jq -nc '[range(1;101) | {name:(if . == 1 then "CLAUDE_CODE_OAUTH_TOKEN" else ("SECRET_" + tostring) end)}] | {total_count:200,secrets:.}')
      emit 200 "$page_body"
    else
      emit 200 '{"total_count":1,"secrets":[{"name":"CLAUDE_CODE_OAUTH_TOKEN"}]}'
    fi
    ;;
  repos/windwardline/fixture/dependabot/secrets*)
    if [ "$MOCK_SCENARIO" = dependabot_secret_repeated_page ]; then
      page_body=$(jq -nc '[range(1;101) | {name:(if . == 1 then "FLEET_AUTOMERGE_APP_ID" elif . == 2 then "FLEET_AUTOMERGE_PRIVATE_KEY" else ("SECRET_" + tostring) end)}] | {total_count:200,secrets:.}')
      emit 200 "$page_body"
    elif [ "$MOCK_SCENARIO" = missing_dependabot_secret ]; then
      emit 200 '{"total_count":1,"secrets":[{"name":"FLEET_AUTOMERGE_APP_ID"}]}'
    else
      emit 200 '{"total_count":2,"secrets":[{"name":"FLEET_AUTOMERGE_APP_ID"},{"name":"FLEET_AUTOMERGE_PRIVATE_KEY"}]}'
    fi
    ;;
  repos/windwardline/fixture/vulnerability-alerts)
    emit 204 ''
    ;;
  repos/windwardline/fixture/automated-security-fixes)
    emit 200 '{"enabled":true}'
    ;;
  repos/windwardline/fixture)
    case "$MOCK_SCENARIO" in
      refused_required) emit 403 '{"message":"Not Found text in a refusal"}' ;;
      rate_limited) emit 429 '{"message":"secondary rate limit"}' ;;
      server_error) emit 500 '{"message":"Server Error"}' ;;
      transport_error) exit 1 ;;
      empty_required) emit 200 '' ;;
      malformed_json) emit 200 '{' ;;
      *) emit 200 '{"allow_auto_merge":true}' ;;
    esac
    ;;
  repos/windwardline/windwardline/contents/FLEET.md*)
    emit 200 "$(content_json "$(cat "$FLEET_MD_LOCAL")")"
    ;;
  repos/windwardline/levelflow-cloud/contents/docs/HANDOFF.md*)
    emit 200 "$(content_json "$(handoff_body)")"
    ;;
  repos/windwardline/levelflow-cloud)
    emit 200 '{"name":"levelflow-cloud","archived":false,"default_branch":"main"}'
    ;;
  repos/windwardline/levelflow-cloud/branches/main)
    emit 200 '{"name":"main","commit":{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}'
    ;;
  repos/windwardline/craft|repos/windwardline/ops|repos/windwardline/venture|repos/windwardline/windwardline)
    repo_name=${endpoint##*/}
    [ "$MOCK_SCENARIO" = registered_repo_missing ] && [ "$repo_name" = craft ] \
      && { emit 404 '{"message":"Not Found"}'; exit $?; }
    default_branch=main
    if [ "$repo_name" = ops ]; then
      [ "$MOCK_SCENARIO" = exempt_non_main_default ] && default_branch=trunk
      [ "$MOCK_SCENARIO" = exempt_slash_default ] && default_branch=release/trunk
      [ "$MOCK_SCENARIO" = exempt_missing_default ] && { emit 200 '{"name":"ops","archived":false}'; exit $?; }
    fi
    emit 200 "{\"name\":\"$repo_name\",\"archived\":false,\"default_branch\":\"$default_branch\"}"
    ;;
  repos/windwardline/craft/branches/*|repos/windwardline/ops/branches/*|repos/windwardline/venture/branches/*|repos/windwardline/windwardline/branches/*)
    repo_and_branch=${endpoint#repos/windwardline/}
    repo_name=${repo_and_branch%%/*}
    encoded_branch=${endpoint##*/}
    branch_name=$encoded_branch
    [ "$encoded_branch" = release%2Ftrunk ] && branch_name=release/trunk
    [ "$MOCK_SCENARIO" = exempt_branch_malformed ] && [ "$repo_name" = ops ] \
      && { emit 200 "{\"name\":\"$branch_name\",\"commit\":{\"sha\":\"short\"}}"; exit $?; }
    emit 200 "{\"name\":\"$branch_name\",\"commit\":{\"sha\":\"dddddddddddddddddddddddddddddddddddddddd\"}}"
    ;;
  repos/windwardline/ops/git/trees/dddddddddddddddddddddddddddddddddddddddd\?recursive=1)
    case "$MOCK_SCENARIO" in
      alert_premise_disabled|alert_premise_enabled|alert_premise_refused)
        tree='[{"path":"package.json","type":"blob"}]' ;;
      exempt_live_pr_workflow|exempt_block_sequence|exempt_indentless_sequence|exempt_spaced_on|exempt_explicit_on|exempt_tagged_on|exempt_escaped_on|exempt_tab_on|exempt_nested_token|exempt_non_main_default|exempt_slash_default)
        tree='[{"path":".github/workflows/docs.yml","type":"blob"}]' ;;
      exempt_filename_only) tree='[{"path":".github/workflows/ci.yml","type":"blob"}]' ;;
      *) tree='[]' ;;
    esac
    emit 200 "{\"sha\":\"dddddddddddddddddddddddddddddddddddddddd\",\"truncated\":false,\"tree\":$tree}"
    ;;
  repos/windwardline/venture/git/trees/dddddddddddddddddddddddddddddddddddddddd\?recursive=1|repos/windwardline/windwardline/git/trees/dddddddddddddddddddddddddddddddddddddddd\?recursive=1)
    emit 200 '{"sha":"dddddddddddddddddddddddddddddddddddddddd","truncated":false,"tree":[]}'
    ;;
  repos/windwardline/ops/contents/.github/workflows\?ref=dddddddddddddddddddddddddddddddddddddddd)
    case "$MOCK_SCENARIO" in
      exempt_live_pr_workflow|exempt_block_sequence|exempt_indentless_sequence|exempt_spaced_on|exempt_explicit_on|exempt_tagged_on|exempt_escaped_on|exempt_tab_on|exempt_nested_token|exempt_non_main_default|exempt_slash_default) emit 200 '[{"name":"docs.yml"}]' ;;
      exempt_filename_only) emit 200 '[{"name":"ci.yml"}]' ;;
      *) emit 404 '{"message":"Not Found"}' ;;
    esac
    ;;
  repos/windwardline/ops/contents/.github/workflows/docs.yml*)
    if [ "$MOCK_SCENARIO" = exempt_nested_token ]; then
      emit 200 "$(content_json 'name: Docs
on:
  workflow_dispatch:
    inputs:
      note:
        description: pull_request
jobs: {}')"
    elif [ "$MOCK_SCENARIO" = exempt_indentless_sequence ]; then
      emit 200 "$(content_json 'name: Docs
on:
- pull_request
jobs: {}')"
    elif [ "$MOCK_SCENARIO" = exempt_spaced_on ]; then
      emit 200 "$(content_json 'name: Docs
on :
  pull_request:
jobs: {}')"
    elif [ "$MOCK_SCENARIO" = exempt_explicit_on ]; then
      emit 200 "$(content_json 'name: Docs
? on
:
  pull_request:
jobs: {}')"
    elif [ "$MOCK_SCENARIO" = exempt_tagged_on ]; then
      emit 200 "$(content_json 'name: Docs
!!str on:
  pull_request:
jobs: {}')"
    elif [ "$MOCK_SCENARIO" = exempt_escaped_on ]; then
      emit 200 "$(content_json 'name: Docs
"o\u006e":
  pull_request:
jobs: {}')"
    elif [ "$MOCK_SCENARIO" = exempt_tab_on ]; then
      emit 200 "$(content_json "name: Docs
on\t:
  pull_request:
jobs: {}")"
    elif [ "$MOCK_SCENARIO" = exempt_block_sequence ]; then
      emit 200 "$(content_json 'name: Docs
on:
  - pull_request
jobs: {}')"
    else
      emit 200 "$(content_json 'name: Docs
on:
  pull_request:
jobs: {}')"
    fi
    ;;
  repos/windwardline/ops/contents/.github/workflows/ci.yml*)
    if [ "$MOCK_SCENARIO" = exempt_filename_only ]; then
      emit 200 "$(content_json 'name: Archive
on:
  push:
jobs: {}')"
    else
      emit 404 '{"message":"Not Found"}'
    fi
    ;;
  repos/windwardline/windwardline/contents/.github/workflows\?ref=dddddddddddddddddddddddddddddddddddddddd|repos/windwardline/venture/contents/.github/workflows\?ref=dddddddddddddddddddddddddddddddddddddddd)
    emit 404 '{"message":"Not Found"}'
    ;;
  repos/windwardline/ops/vulnerability-alerts)
    case "$MOCK_SCENARIO" in
      alert_premise_enabled) emit 204 '' ;;
      alert_premise_refused) emit 403 '{"message":"Forbidden"}' ;;
      *) emit 404 '{"message":"Not Found"}' ;;
    esac
    ;;
  repos/windwardline/*/actions/runs\?event=pull_request*)
    if [ "$MOCK_SCENARIO" = exempt_historical_runs ]; then emit 200 '{"total_count":7,"workflow_runs":[]}'; else emit 200 '{"total_count":0,"workflow_runs":[]}'; fi
    ;;
  repos/windwardline/*/contents/.github/workflows/ci.yml*|repos/windwardline/*/contents/.github/workflows/security.yml*)
    emit 404 '{"message":"Not Found"}'
    ;;
  *)
    printf 'unhandled gh endpoint: %s\n' "$endpoint" >&2
    exit 96
    ;;
esac
MOCK_GH
chmod +x "$TMP/bin/gh"

standard() {
  case "$1" in
    duplicate_heading)
      cat <<'MD'
# Standard
### The cycle
1. **FIND.** Evidence.
2. **REFUTE.** Evidence.
3. **VERIFY YOURSELF.** Evidence.
4. **FIX durably.** Evidence.
5. **RE-RANK the sequence.** Evidence.
6. **TEST.** Evidence.
7. **UPDATE.** Evidence.
8. **REPORT.** Evidence.
### Delivery discipline
### The cycle
1. **FIND.** Duplicate.
MD
      ;;
    inexact_heading)
      cat <<'MD'
# Standard
### The cycle rewritten
1. **FIND.** Evidence.
2. **REFUTE.** Evidence.
3. **VERIFY YOURSELF.** Evidence.
4. **FIX durably.** Evidence.
5. **RE-RANK the sequence.** Evidence.
6. **TEST.** Evidence.
7. **UPDATE.** Evidence.
8. **REPORT.** Evidence.
### Delivery discipline
MD
      ;;
    wrapped_label)
      cat <<'MD'
# Standard
### The cycle
1. **FIND
   MORE.** Evidence.
2. **REFUTE.** Evidence.
3. **VERIFY YOURSELF.** Evidence.
4. **FIX durably.** Evidence.
5. **RE-RANK the sequence.** Evidence.
6. **TEST.** Evidence.
7. **UPDATE.** Evidence.
8. **REPORT.** Evidence.
### Delivery discipline
MD
      ;;
    ambiguous_label)
      cat <<'MD'
# Standard
### The cycle
1. **FIND / REFUTE.** Evidence.
2. **REFUTE.** Evidence.
3. **VERIFY YOURSELF.** Evidence.
4. **FIX durably.** Evidence.
5. **RE-RANK the sequence.** Evidence.
6. **TEST.** Evidence.
7. **UPDATE.** Evidence.
8. **REPORT.** Evidence.
### Delivery discipline
MD
      ;;
    *)
      cat <<'MD'
# Standard
### The cycle
1. **FIND.** Evidence.
2. **REFUTE.** Evidence.
3. **VERIFY YOURSELF.** Evidence.
4. **FIX durably.** Evidence.
5. **RE-RANK the sequence.** Evidence.
6. **TEST.** Evidence.
7. **UPDATE.** Evidence.
8. **REPORT.** Evidence.
### Delivery discipline
MD
      ;;
  esac
  cat <<'MD'
- **Enumerate the gates; never count them.** Evidence.
- **Stage explicit paths. Never `git add -A`.** Evidence.
- **Validate before mutating.** Evidence.
- **Preserve standing claims.** Evidence.
- **Derive populations; do not curate them.** Evidence.
- **A harness failure must never read as the subject refusing.** Evidence.
### Operational completion and artifact rules
- **Then:** Continue.
- **No model identifiers.** Evidence.
MD
  cat <<'MD'
## Managed-edge header exception
| Repo | Approved | Managed origin | Required proof | Expiry |
|---|---|---|---|---|
MD
  case "$1" in
    ghost_valid|ghost_stale_ref|ghost_inline|ghost_header_conflict|ghost_missing|ghost_register_mismatch)
      cat <<'MD'
| `fixture` | 2026-08-24 | `https://grownmengrow.com` on Ghost(Pro) | Exact `Ghost managed edge` one-step job on push + daily, calling `windwardline/windwardline/actions/verify-ghost-managed-edge@<current release SHA>` | Fails once all seven headers appear; remove this row and restore `Headers live` |
MD
      ;;
    ghost_register_field_mismatch)
      cat <<'MD'
| `fixture` | 2026-08-25 | `https://grownmengrow.com` on Ghost(Pro) | Exact `Ghost managed edge` one-step job on push + daily, calling `windwardline/windwardline/actions/verify-ghost-managed-edge@<current release SHA>` | Fails once all seven headers appear; remove this row and restore `Headers live` |
MD
      ;;
  esac
  cat <<'MD'
## Repository visibility
| Repo | Why |
|---|---|
| `ops` | Private |
| `venture` | Private |
## Held repos
| Repo | Behind |
|---|---|
| `craft` | dependency-scan schedule guard; auto-merge lane reorder |
## Exceptions register
| Repo | Exception |
|---|---|
| `windwardline` | No CI |
| `venture` | Outside fleet |
MD
  if [ "$1" != register_mismatch ]; then
    cat <<'MD'
| `ops` | No CI |
MD
  fi
}

passes=0
failures=0
CASE_FILTER=${CASE_FILTER:-}

run_with_timeout() {
  ruby -rtimeout -e '
    seconds = Integer(ENV.fetch("FLEET_TEST_TIMEOUT", "20"))
    pid = Process.spawn(*ARGV, pgroup: true)
    status = nil
    begin
      Timeout.timeout(seconds) { _waited, status = Process.wait2(pid) }
    rescue Timeout::Error
      warn "test subject exceeded #{seconds}s; terminating process group"
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
      end
      exit 124
    end
    exit(status.exitstatus || 128 + status.termsig)
  ' "$@"
}

run_case() {
  name=$1
  if [ -n "$CASE_FILTER" ]; then
    case "$name" in *"$CASE_FILTER"*) ;; *) return ;; esac
  fi
  scenario=$2
  expected_rc=$3
  pattern=$4
  managed_edge_override=_NONE_
  case "$scenario" in
    ghost_valid|ghost_stale_ref|ghost_inline|ghost_header_conflict|ghost_missing|ghost_register_field_mismatch)
      managed_edge_override=fixture
      ;;
  esac
  standard "$scenario" >"$TMP/standard-$name.md"
  : >"$TMP/log-$name"
  PATH="$TMP/bin:$PATH" \
    MOCK_SCENARIO="$scenario" \
    MOCK_LOG="$TMP/log-$name" \
    MOCK_SUBJECT="$TMP/subject" \
    FLEET_MD_LOCAL="$TMP/standard-$name.md" \
    GHOST_MANAGED_EDGE_REPOS_OVERRIDE="$managed_edge_override" \
    run_with_timeout bash "$TMP/subject/scripts/fleet-conformance.sh" >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq "$expected_rc" ] && grep -qE "$pattern" "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (expected rc=%s /%s/, got rc=%s)\n' "$name" "$expected_rc" "$pattern" "$rc"
    sed -n '1,100p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_locale_independence_case() {
  name=non-ascii-security-md-survives-unset-locale
  if [ -n "$CASE_FILTER" ]; then
    case "$name" in *"$CASE_FILTER"*) ;; *) return ;; esac
  fi
  standard valid >"$TMP/standard-$name.md"
  : >"$TMP/log-$name"
  # The locale is cleared deliberately. Run this under a UTF-8 shell without
  # clearing it and the case passes whether or not the fix is present, which
  # is a test that cannot fail.
  # A subshell, not env(1): run_with_timeout is a shell function and env cannot
  # invoke one. The first draft of this test used env, got exit 127, and passed
  # anyway because 127 is not 2 — a test that examined nothing.
  (
    unset LANG LC_ALL LC_CTYPE
    PATH="$TMP/bin:$PATH" \
    MOCK_SCENARIO=security_origin_non_ascii \
    MOCK_LOG="$TMP/log-$name" \
    MOCK_SUBJECT="$TMP/subject" \
    FLEET_MD_LOCAL="$TMP/standard-$name.md" \
    GHOST_MANAGED_EDGE_REPOS_OVERRIDE=_NONE_ \
    run_with_timeout bash "$TMP/subject/scripts/fleet-conformance.sh"
  ) >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -ne 2 ] && [ "$rc" -ne 127 ] \
    && grep -q 'REPO' "$TMP/out-$name" \
    && ! grep -qE 'invalid byte sequence|could not be derived unambiguously' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (non-ASCII SECURITY.md must not abort the audit; rc=%s)\n' "$name" "$rc"
    sed -n '1,60p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_no_graphql_case() {
  name=no-graphql
  standard valid >"$TMP/standard-$name.md"
  : >"$TMP/log-$name"
  PATH="$TMP/bin:$PATH" \
    MOCK_SCENARIO=valid \
    MOCK_LOG="$TMP/log-$name" \
    MOCK_SUBJECT="$TMP/subject" \
    FLEET_MD_LOCAL="$TMP/standard-$name.md" \
    bash "$TMP/subject/scripts/fleet-conformance.sh" >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -qE '^(repo|pr) ' "$TMP/log-$name" \
    && ! grep -qE 'gh (repo|pr) list' "$ROOT/scripts/fleet-conformance.sh" "$ROOT/scripts/verify-action-pins.sh"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (GraphQL-backed gh command observed or rc=%s)\n' "$name" "$rc"
    grep -E '^(repo|pr) ' "$TMP/log-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_snapshot_case() {
  name=single-immutable-snapshot
  standard valid >"$TMP/standard-$name.md"
  : >"$TMP/log-$name"
  PATH="$TMP/bin:$PATH" \
    MOCK_SCENARIO=valid \
    MOCK_LOG="$TMP/log-$name" \
    MOCK_SUBJECT="$TMP/subject" \
    FLEET_MD_LOCAL="$TMP/standard-$name.md" \
    run_with_timeout bash "$TMP/subject/scripts/fleet-conformance.sh" >"$TMP/out-$name" 2>&1
  rc=$?
  branch_reads=$(grep -c 'repos/windwardline/fixture/branches/main' "$TMP/log-$name" || true)
  enumeration_reads=$(grep -c 'user/repos?affiliation=owner' "$TMP/log-$name" || true)
  pin_manifest_calls=$(grep -c '^pin-auditor --snapshot-manifest - 1$' "$TMP/log-$name" || true)
  expected_manifest=$'fixture\tffffffffffffffffffffffffffffffffffffffff'
  actual_manifest=$(cat "$TMP/log-$name.pin-manifest" 2>/dev/null || true)
  bad_content_refs=$(awk '/contents\// && $0 !~ /\?ref=[0-9a-f]{40}([[:space:]]|$)/ { print }' "$TMP/log-$name")
  if [ "$rc" -eq 0 ] && [ "$branch_reads" -eq 1 ] && [ "$enumeration_reads" -eq 1 ] \
    && [ "$pin_manifest_calls" -eq 1 ] && [ "$actual_manifest" = "$expected_manifest" ] \
    && [ -z "$bad_content_refs" ] \
    && ! grep -q 'ref=main' "$TMP/log-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (rc=%s, fixture branch reads=%s, enumerations=%s, pin manifests=%s; every audit must share one exact snapshot)\n' \
      "$name" "$rc" "$branch_reads" "$enumeration_reads" "$pin_manifest_calls"
    [ "$actual_manifest" = "$expected_manifest" ] \
      || printf '  pin manifest: %q (expected %q)\n' "$actual_manifest" "$expected_manifest"
    [ -z "$bad_content_refs" ] || printf '%s\n' "$bad_content_refs" | sed 's/^/  /'
    sed -n '1,100p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_template_universal_case() {
  name=template-universal-passes
  standard valid >"$TMP/standard-$name.md"
  : >"$TMP/log-$name"
  PATH="$TMP/bin:$PATH" \
    MOCK_SCENARIO=template_repo \
    MOCK_LOG="$TMP/log-$name" \
    MOCK_SUBJECT="$TMP/subject" \
    FLEET_MD_LOCAL="$TMP/standard-$name.md" \
    bash "$TMP/subject/scripts/fleet-conformance.sh" >"$TMP/out-$name" 2>&1
  rc=$?
  rows=$(grep -cE '^fixture[[:space:]]+✓' "$TMP/out-$name")
  if [ "$rc" -eq 0 ] && [ "$rows" -eq 2 ] \
    && grep -q 'Dependency scan cadence conformant — 1 live scan repo' "$TMP/out-$name" \
    && grep -q 'Visibility conformant' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (expected main + universal rows and scan/visibility coverage; rc=%s rows=%s)\n' "$name" "$rc" "$rows"
    sed -n '1,120p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_pin_auditor_scope_case() {
  name=pin-auditor-local-path-scope
  root="$TMP/pin-scope"
  mkdir -p "$root/.github/workflows/nested" "$root/templates/nested"
  printf '%s\n' 'name: Top level' 'on: workflow_dispatch' 'jobs: {}' >"$root/.github/workflows/top.yml"
  printf '%s\n' 'name: Nested docs example' 'uses: actions/checkout@v4' >"$root/.github/workflows/nested/example.yml"
  printf '%s\n' 'name: Nested template example' 'uses: actions/checkout@v4' >"$root/templates/nested/example.yml"
  TMPDIR="$TMP" bash "$ROOT/scripts/verify-action-pins.sh" --local "$root" >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ] && grep -q 'Scanned 1 workflow file' "$TMP/out-$name" \
    && grep -q 'classified zero third-party refs' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (nested examples must be ignored without allowing a vacuous pass; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=pin-auditor-local-actions-remain-recursive
  mkdir -p "$root/.github/actions/nested"
  printf '%s\n' 'name: Nested action' 'runs:' '  using: composite' '  steps:' '    - uses: actions/checkout@v4' >"$root/.github/actions/nested/action.yml"
  TMPDIR="$TMP" bash "$ROOT/scripts/verify-action-pins.sh" --local "$root" >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'pin-unpinned:actions/checkout@v4' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (nested composite actions must remain audited; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=pin-auditor-local-repo-actions-remain-recursive
  mkdir -p "$root/actions/nested"
  printf '%s\n' 'name: Repo action' 'runs:' '  using: composite' '  steps:' '    - uses: actions/setup-node@v4' >"$root/actions/nested/action.yml"
  TMPDIR="$TMP" bash "$ROOT/scripts/verify-action-pins.sh" --local "$root" >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'pin-unpinned:actions/setup-node@v4' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (actions/**/action.yml must be audited; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_pin_auditor_failure_cases() {
  local name rc fixture_bin fixture_root cache_root

  name=pin-auditor-local-enumeration-failure-is-incomplete
  fixture_root="$TMP/pin-find-root"
  fixture_bin="$TMP/pin-find-bin"
  mkdir -p "$fixture_root/.github/workflows" "$fixture_bin"
  printf '%s\n' 'name: Empty fixture' 'on: workflow_dispatch' 'jobs: {}' \
    >"$fixture_root/.github/workflows/fixture.yml"
  cat >"$fixture_bin/find" <<'PIN_FIND'
#!/bin/bash
printf '%s\n' "$FIND_FIXTURE_FILE"
exit 1
PIN_FIND
  chmod +x "$fixture_bin/find"
  PATH="$fixture_bin:$PATH" FIND_FIXTURE_FILE="$fixture_root/.github/workflows/fixture.yml" \
    TMPDIR="$TMP" bash "$ROOT/scripts/verify-action-pins.sh" --local "$fixture_root" \
    >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ] && grep -qE 'enumerat|find|incomplete|could not' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (failed local file enumeration must be incomplete; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=pin-auditor-multiple-flow-uses-cannot-pass
  fixture_root="$TMP/pin-flow-root"
  fixture_bin="$TMP/pin-flow-bin"
  mkdir -p "$fixture_root/.github/workflows" "$fixture_bin"
  printf '%s\n' \
    'name: Flow pins' \
    'on: push' \
    'jobs:' \
    '  audit:' \
    '    runs-on: ubuntu-latest' \
    '    steps: [{uses: actions/setup-node@v4}, {uses: windwardline/internal@main}]' \
    >"$fixture_root/.github/workflows/flow.yml"
  TMPDIR="$TMP" bash "$ROOT/scripts/verify-action-pins.sh" --local "$fixture_root" \
    >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ] && grep -qE 'pin-(unpinned|multiple|ambiguous)' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (multiple uses keys on one line cannot hide a ref; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=pin-auditor-quoted-uses-key-cannot-pass
  fixture_root="$TMP/pin-quoted-key-root"
  mkdir -p "$fixture_root/.github/workflows"
  printf '%s\n' \
    'name: Quoted key' \
    'on: push' \
    'jobs:' \
    '  audit:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - "uses": actions/checkout@v4' \
    >"$fixture_root/.github/workflows/quoted.yml"
  TMPDIR="$TMP" bash "$ROOT/scripts/verify-action-pins.sh" --local "$fixture_root" \
    >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'pin-unpinned:actions/checkout@v4' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (quoted uses key cannot hide a ref; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=pin-auditor-comment-punctuation-is-exact
  fixture_root="$TMP/pin-punctuation-root"
  fixture_bin="$TMP/pin-punctuation-bin"
  mkdir -p "$fixture_root/.github/workflows" "$fixture_bin"
  printf '%s\n' \
    'name: Punctuated pin comment' \
    'on: workflow_dispatch' \
    'jobs:' \
    '  pin:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0}, explanation' \
    >"$fixture_root/.github/workflows/pin.yml"
  cat >"$fixture_bin/git" <<'PIN_PUNCTUATION_GIT'
#!/bin/bash
[ "${1:-}" = ls-remote ] || exit 97
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.0.0\n'
PIN_PUNCTUATION_GIT
  chmod +x "$fixture_bin/git"
  PATH="$fixture_bin:$PATH" TMPDIR="$TMP" \
    bash "$ROOT/scripts/verify-action-pins.sh" --local "$fixture_root" >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'pin-comment-wrong:actions/checkout#v1.0.0},' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (comment punctuation must not be normalized away; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=pin-auditor-malformed-tree-is-incomplete
  fixture_bin="$TMP/pin-tree-bin"
  mkdir -p "$fixture_bin"
  cat >"$fixture_bin/gh" <<'PIN_TREE_GH'
#!/bin/bash
case "$*" in
  'api repos/windwardline/fixture') printf '%s\n' '{"default_branch":"main"}' ;;
  'api repos/windwardline/fixture/git/trees/main?recursive=1') printf '%s\n' '{}' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 97 ;;
esac
PIN_TREE_GH
  chmod +x "$fixture_bin/gh"
  PATH="$fixture_bin:$PATH" TMPDIR="$TMP" \
    bash "$ROOT/scripts/verify-action-pins.sh" --repo fixture >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ] && grep -qE 'tree.*(shape|malformed|could not)|audit.*could not' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (malformed successful tree response must be incomplete; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=pin-auditor-malformed-content-is-incomplete
  fixture_bin="$TMP/pin-content-bin"
  mkdir -p "$fixture_bin"
  cat >"$fixture_bin/gh" <<'PIN_CONTENT_GH'
#!/bin/bash
case "$*" in
  'api repos/windwardline/fixture') printf '%s\n' '{"default_branch":"main"}' ;;
  'api repos/windwardline/fixture/git/trees/main?recursive=1')
    printf '%s\n' '{"truncated":false,"tree":[{"path":".github/workflows/ci.yml","type":"blob"}]}' ;;
  'api repos/windwardline/fixture/contents/.github/workflows/ci.yml?ref=main')
    printf '%s\n' '{"content":"bmFtZTogeAo="}' '{' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 97 ;;
esac
PIN_CONTENT_GH
  chmod +x "$fixture_bin/gh"
  PATH="$fixture_bin:$PATH" TMPDIR="$TMP" \
    bash "$ROOT/scripts/verify-action-pins.sh" --repo fixture >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ] && grep -qE 'content|decode|malformed|audit.*could not' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (partially parseable content response must be incomplete; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=pin-auditor-refresh-failure-is-incomplete
  fixture_root="$TMP/pin-refresh-root"
  fixture_bin="$TMP/pin-refresh-bin"
  cache_root="$TMP/pin-refresh-cache"
  mkdir -p "$fixture_root/.github/workflows" "$fixture_bin" "$cache_root"
  printf '%s\n' \
    'name: Pin refresh' \
    'on: workflow_dispatch' \
    'jobs:' \
    '  pin:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v9.9.9' \
    >"$fixture_root/.github/workflows/pin.yml"
cat >"$fixture_bin/git" <<'PIN_REFRESH_GIT'
#!/bin/bash
[ "${1:-}" = ls-remote ] || exit 97
state=${0%/*}/git-state
if [ ! -e "$state" ]; then
  printf 'seen\n' >"$state"
  printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v1.0.0\n'
  exit 0
fi
exit 1
PIN_REFRESH_GIT
  chmod +x "$fixture_bin/git"
  PATH="$fixture_bin:$PATH" TMPDIR="$cache_root" \
    bash "$ROOT/scripts/verify-action-pins.sh" --local "$fixture_root" >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ] && grep -qE 'tag lookup failed|AUDIT INCOMPLETE' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (failed forced tag refresh must be incomplete; rc=%s)\n' "$name" "$rc"
    sed -n '1,100p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_pin_auditor_git_tree_case() {
  name=pin-auditor-git-tree-is-immutable
  fixture_root="$TMP/pin-git-tree-root"
  fixture_bin="$TMP/pin-git-tree-bin"
  real_git=$(command -v git)
  mkdir -p "$fixture_root/.github/workflows" "$fixture_bin"
  "$real_git" -C "$fixture_root" init -q
  printf '%s\n' \
    'name: Immutable pin source' \
    'on: workflow_dispatch' \
    'jobs:' \
    '  pin:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v1.0.0' \
    >"$fixture_root/.github/workflows/pin.yml"
  "$real_git" -C "$fixture_root" add .github/workflows/pin.yml
  "$real_git" -C "$fixture_root" -c user.name=Test -c user.email=test@example.com commit -qm good
  good_sha=$("$real_git" -C "$fixture_root" rev-parse HEAD)
  printf '%s\n' \
    'name: Mutated pin source' \
    'on: workflow_dispatch' \
    'jobs:' \
    '  pin:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: actions/checkout@v4' \
    >"$fixture_root/.github/workflows/pin.yml"
  "$real_git" -C "$fixture_root" add .github/workflows/pin.yml
  "$real_git" -C "$fixture_root" -c user.name=Test -c user.email=test@example.com commit -qm bad
  bad_sha=$("$real_git" -C "$fixture_root" rev-parse HEAD)
  "$real_git" -C "$fixture_root" replace "$good_sha" "$bad_sha"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'if [ "${1:-}" = ls-remote ]; then'
    printf '%s\n' '  printf "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\trefs/tags/v1.0.0\\n"'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf 'exec %q "$@"\n' "$real_git"
  } >"$fixture_bin/git"
  chmod +x "$fixture_bin/git"
  PATH="$fixture_bin:$PATH" TMPDIR="$TMP" \
    bash "$ROOT/scripts/verify-action-pins.sh" --git-tree "$fixture_root" "$good_sha" \
    >"$TMP/out-$name" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'All action pin comments name the tag' "$TMP/out-$name"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (audit must read the exact commit, ignoring worktree and replacement refs; rc=%s)\n' "$name" "$rc"
    sed -n '1,100p' "$TMP/out-$name" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_case valid-fixture valid 0 'Fleet conformant'
run_case template-repo-included template_repo 0 'fixture[[:space:]]+✓'
run_case internal-visibility-cannot-pass internal_visibility 1 'visibility:.*internal|visibility.*INTERNAL'
run_case required-refusal-aborts refused_required 2 'HTTP 403|refused'
run_case rate-limit-aborts rate_limited 2 'HTTP 429|refused'
run_case server-error-aborts server_error 2 'HTTP 500|refused'
run_case transport-error-aborts transport_error 2 'no parseable HTTP status|could not be read'
run_case false-404-text-aborts false_404_text 2 'HTTP 403|refused'
run_case empty-required-body-aborts empty_required 2 'empty required body'
run_case malformed-required-json-aborts malformed_json 2 'malformed JSON'
run_case malformed-required-body-aborts malformed_required 2 'malformed|decode|empty'
run_case truncated-base64-body-aborts truncated_required 2 'malformed|decode|base64'
run_case duplicate-cycle-heading-aborts duplicate_heading 2 'exactly one.*The cycle|heading'
run_case inexact-cycle-heading-aborts inexact_heading 2 'exactly one.*The cycle|heading'
run_case wrapped-cycle-label-aborts wrapped_label 2 'label|wrapped|parse'
run_case ambiguous-cycle-label-aborts ambiguous_label 2 'label|ambiguous|parse'
run_case cycle-steps-use-token-boundaries cycle_prefix 1 'converge-order:FIX|cycle:FIX'
run_case handoff-cycle-is-structural handoff_prose_only 1 'HANDOFF.md-6b:.*cycle'
run_case handoff-delivery-rules-are-bullets handoff_delivery_prose_only 1 'HANDOFF.md-6b:.*delivery'
run_case handoff-fence-needs-real-closer handoff_fake_closer 1 'HANDOFF.md-6b:.*prompt-fence-structure'
run_case handoff-commented-prompt-is-not-executable handoff_commented_prompt 1 'HANDOFF.md-6b:.*prompt-fence-structure'
run_case remote-template-is-canonical remote_template 0 'Fleet conformant'
run_case canonical-template-survives-two-repo-loop two_repos 0 'fixture2[[:space:]]+✓'
run_case scratch-copy-must-exist scratch_copy_missing 1 'missing:scratch-clone.sh'
run_case scratch-copy-must-match-template scratch_copy_drift 1 'scratch-clone:differs-from-template'
run_case scratch-copy-refusal-is-incomplete scratch_copy_refused 2 'scratch-clone.sh.*HTTP 403|refused'
run_case scratch-template-refusal-is-incomplete scratch_canonical_refused 2 'scratch-clone template.*HTTP 403|refused'
run_case failed-job-must-be-required failed_unrequired 1 'unrequired-job:Ungated_failed'
run_case cancelled-job-must-be-required cancelled_unrequired 1 'unrequired-job:Ungated_cancelled'
run_case empty-required-check-sample-aborts empty_sample 2 'required-check.*empty|sample.*empty|no PR-triggered'
run_case zero-jobs-aborts zero_jobs 2 'returned zero jobs'
run_case incomplete-run-pagination-aborts incomplete_run_page 2 'workflow run.*(incomplete|ended early)|expected.*workflow run'
run_case incomplete-job-pagination-aborts incomplete_job_page 2 'jobs.*(incomplete|ended early)|expected.*jobs'
run_case repeated-repository-page-aborts repo_repeated_page 2 'repository enumeration.*repeated pagination identity|pagination made no progress'
run_case repeated-pull-request-page-aborts pr_repeated_page 2 'closed pull requests.*repeated pagination identity|pagination made no progress'
run_case repeated-workflow-run-page-aborts run_repeated_page 2 'workflow runs.*repeated pagination identity|pagination made no progress'
run_case repeated-job-page-aborts job_repeated_page 2 'jobs page.*repeated pagination identity|pagination made no progress'
run_case repeated-ruleset-page-aborts ruleset_repeated_page 2 'ruleset listing.*repeated pagination identity|pagination made no progress'
run_case repeated-actions-secret-page-aborts actions_secret_repeated_page 2 'Actions secret listing.*repeated pagination identity|pagination made no progress'
run_case repeated-dependabot-secret-page-aborts dependabot_secret_repeated_page 2 'Dependabot secret listing.*repeated pagination identity|pagination made no progress'
run_case pending-job-aborts pending_job 2 'unfinished job|evidence is not final'
run_case workflow-run-total-overflow-aborts run_total_overflow 2 'workflow run pagination exceeded total_count'
run_case job-total-overflow-aborts job_total_overflow 2 'jobs pagination exceeded total_count'
run_case duplicate-actions-job-name-is-drift duplicate_job_name 1 'duplicate-actions-job:CI'
run_case weekly-only-dependency-scan-fails weekly_only 1 'daily-cron|daily cron'
run_case security-workflow-must-trigger-on-push no_push_trigger 1 'security-yml:no-push-trigger|not-push-live'
run_case semgrep-name-cannot-mask-noop semgrep_noop 1 'security-yml:semgrep-not-canonical'
run_case secret-name-cannot-mask-missing-gitleaks gitleaks_missing 1 'security-yml:secret-scan-not-canonical|security-yml:no-pin-gate'
run_case osv-cannot-disable-vulnerability-failure osv_fail_open 1 'dependency-scan:dependency-scan:not-canonical'
run_case daily-cron-must-run-live-job scan_guarded 1 'daily-cron.*no-live-job|daily cron.*no live job|dependency-scan.*schedule guard'
run_case push-only-job-is-not-daily-live push_only 1 'daily-cron.*no-live-job|job-level condition'
run_case daily-job-needs-live-schedule-path dependent_on_guarded 1 'daily-cron.*no-live-job|dependency.*schedule'
run_case osv-needs-chain-must-admit-pr-and-push dependent_schedule_only 1 'dependency-scan.*not-pull-request-live|dependency-scan.*not-push-live'
run_case disabled-security-workflow-cannot-pass workflow_disabled_manually 1 'security-workflow:disabled_manually'
run_case inactivity-disabled-security-workflow-cannot-pass workflow_disabled_inactivity 1 'security-workflow:disabled_inactivity'
run_case unrelated-daily-job-cannot-mask-osv-needs dependent_on_guarded_with_headers 1 'dependency-scan.*daily|dependency.*schedule|not-daily-live'
run_case cron-outside-on-is-not-a-daily-trigger cron_outside_on 1 'dependency-scan:no-daily-cron|daily cron'
run_case expected-scan-cannot-delete-itself no_scan 1 'dependency-scan:missing-live-job|missing.*dependency.scan'
run_case nested-lockfile-remains-in-scan-population nested_lockfile_no_scan 1 'dependency-scan:missing-live-job|missing.*dependency.scan'
run_case nested-lockfile-with-scan-is-conformant nested_lockfile 0 'Fleet conformant'
run_case nested-lockfile-inputs-must-match-tree nested_lockfile_mismatch 1 'lockfile-population-mismatch'
run_case zero-expected-scan-population-aborts no_lockfile 2 'expected.*scan population.*zero|lockfile population.*zero'
run_case dependabot-ecosystems-are-tree-derived ecosystem_missing 1 'dependabot:ecosystem-path-population'
run_case cooldown-is-per-lane cooldown_split 1 'cooldown:.*lane|cooldown.*github-actions'
run_case cooldown-value-must-be-nested cooldown_misplaced 1 'cooldown:.*lane|cooldown.*npm.*missing'
run_case zero-update-lanes-aborts zero_lanes 2 'at least one live lane|no live update lanes|could not be parsed structurally'
run_case disabled-dependabot-lane-is-drift dependabot_lane_disabled 1 'dependabot:lane1-npm-disabled'
run_case exact-claude-pointer bad_claude 1 'claude-pointer|CLAUDE.md:not-exact'
run_case claude-pointer-requires-one-lf claude_no_lf 1 'claude-pointer|CLAUDE.md:not-exact'
run_case claude-pointer-rejects-two-lfs claude_two_lf 1 'claude-pointer|CLAUDE.md:not-exact'
run_case package-scripts-are-exact-nonblank-keys script_misleading 1 'script:typecheck.*script:lint.*script:test'
run_case stack-waiver-must-be-anchored waiver_prefixed 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-reason-is-nonblank waiver_blank 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-cannot-be-future-dated waiver_future 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-example-is-not-live waiver_fenced 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-tilde-fence-is-not-live waiver_tilde_fenced 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-mismatched-fence-is-not-live waiver_mismatched_fence 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-short-closer-is-not-live waiver_short_fence 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-comment-is-not-live waiver_commented 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-indented-code-is-not-live waiver_indented 1 'stack-deviation:.*unrecorded'
run_case stack-waiver-valid-shape waiver_valid 0 'Fleet conformant'
run_case fenced-contract-is-not-live contract_fenced 1 'converge-citation:absent|converge-cycle|gates-unenumerated'
run_case commented-contract-is-not-live contract_commented 1 'converge-citation:absent|converge-cycle|gates-unenumerated'
run_case indented-contract-is-not-live contract_indented 1 'converge-citation:absent|converge-cycle|gates-unenumerated'
run_case global-contract-is-required global_contract_absent 1 'global-contract-citation:absent'
run_case global-contract-path-is-exact global_contract_wrong_path 1 'global-contract-citation:absent'
run_case global-contract-must-be-affirmative global_contract_negated 1 'global-contract-applicability:absent'
run_case meta-negated-global-contract-is-not-affirmative global_contract_meta_negated 1 'global-contract-applicability:absent'
run_case labeled-negation-cannot-lend-force-to-a-global-affirmation global_contract_labeled_negated 1 'global-contract-applicability:absent'
run_case labeled-negation-clause-cannot-lend-force-to-a-global-affirmation global_contract_labeled_negated_clause 1 'global-contract-applicability:absent'
run_case house-form-global-contract-is-affirmative global_contract_house_form 0 'Fleet conformant'
run_case a-trailing-colon-does-not-end-the-global-claim global_contract_trailing_colon 0 'Fleet conformant'
run_case list-prefixed-line-cannot-close-a-root-fence global_contract_fence_false_closer 1 'global-contract-citation:absent'
run_case wrapped-global-contract-is-affirmative global_contract_wrapped 0 'Fleet conformant'
run_case closed-comment-blockquote-is-inert global_contract_closed_comment_quote 0 'Fleet conformant'
run_case invalid-fence-cannot-end-lazy-blockquote global_contract_invalid_fence_lazy 1 'global-contract-citation:absent'
run_case blockquoted-global-contract-is-not-live global_contract_blockquoted 1 'global-contract-citation:absent'
run_case list-blockquoted-global-contract-is-not-live global_contract_list_blockquoted 1 'global-contract-citation:absent'
run_case lazy-blockquoted-global-contract-is-not-live global_contract_lazy_blockquoted 1 'global-contract-citation:absent'
run_case heading-ends-lazy-blockquote blockquote_heading_interrupt 0 'Fleet conformant'
run_case list-fenced-global-contract-is-not-live global_contract_list_fenced 1 'global-contract-citation:absent'
run_case fenced-global-contract-is-not-live global_contract_fenced 1 'global-contract-citation:absent'
run_case commented-global-contract-is-not-live global_contract_commented 1 'global-contract-citation:absent'
run_case fleet-contract-path-is-exact contract_wrong_path 1 'converge-citation:absent'
run_case fleet-contract-must-be-affirmative contract_negated 1 'converge-applicability:absent'
run_case meta-negated-fleet-contract-is-not-affirmative contract_meta_negated 1 'converge-applicability:absent'
run_case labeled-negation-cannot-lend-force-to-a-fleet-affirmation contract_labeled_negated 1 'converge-applicability:absent'
run_case labeled-negation-clause-cannot-lend-force-to-a-fleet-affirmation contract_labeled_negated_clause 1 'converge-applicability:absent'
run_case house-form-fleet-contract-is-affirmative contract_house_form 0 'Fleet conformant'
run_case a-colon-introduced-example-is-not-an-affirmation contract_colon_example 1 'converge-applicability:absent'
run_case house-form-fleet-contract-with-trailing-qualifier-is-affirmative contract_house_form_trailing 0 'Fleet conformant'
run_case list-prefixed-line-cannot-close-a-root-fence-around-the-fleet-clause contract_fence_false_closer 1 'converge-citation:absent'
run_case list-nested-fence-still-closes-at-its-indented-closer contract_list_fence_closed 0 'Fleet conformant'
run_case blockquoted-fleet-contract-is-not-live contract_blockquoted 1 'converge-citation:absent'
run_case list-blockquoted-fleet-contract-is-not-live contract_list_blockquoted 1 'converge-citation:absent'
run_case lazy-blockquoted-fleet-contract-is-not-live contract_lazy_blockquoted 1 'converge-citation:absent'
run_case list-fenced-fleet-contract-is-not-live contract_list_fenced 1 'converge-citation:absent'
run_case pin-gate-must-be-live-use pin_commented 1 'security-yml:no-pin-gate'
run_case pin-gate-cannot-be-run-text pin_run_text 1 'security-yml:no-pin-gate'
run_case pin-gate-must-be-in-secret-scan pin_wrong_job 1 'security-yml:no-pin-gate'
run_case pin-gate-cannot-be-disabled pin_if_false 1 'security-yml:no-pin-gate'
run_case pin-gate-cannot-have-conditional-expression pin_if_expression 1 'security-yml:no-pin-gate'
run_case pin-gate-cannot-continue-on-error pin_continue_on_error 1 'security-yml:no-pin-gate'
run_case pin-gate-cannot-have-expression-continue pin_continue_expression 1 'security-yml:no-pin-gate'
run_case pin-gate-must-use-current-release stale_pin_release 1 'security-yml:pin-gate-not-current-v1.0.0'
run_case current-release-must-contain-shared-actions release_action_missing 2 'current fleet-action release.*required action path'
run_case security-root-permissions-are-exact security_root_permissions 1 'security-yml:root-permissions-not-canonical'
run_case production-header-job-is-required header_missing 1 'headers-live-job-count-0|canonical-header-probes:0/1'
run_case inline-header-probe-is-not-evidence header_inline 1 'headers-live-not-canonical|canonical-header-probes:0/1'
run_case header-probe-must-use-current-release header_stale_ref 1 'headers-live-not-current-v1.0.0'
run_case header-probe-url-matches-security-scope header_wrong_url 1 'headers-live-url-mismatch'
run_case header-needs-chain-must-admit-push header_push_blocked 1 'headers-live-not-push-live'
run_case production-origin-population-is-derived-and-nonvacuous security_origin_missing 2 'derived production-origin population is zero'
run_case registered-ghost-edge-is-conformant ghost_valid 0 '0 canonical header job\(s\) \+ 1 managed-edge job\(s\) = 1 derived origin'
run_case registered-ghost-edge-job-is-required ghost_missing 1 'ghost-managed-edge-job-count-0|managed-edge-probes:0/1'
run_case ghost-edge-probe-must-use-current-release ghost_stale_ref 1 'ghost-managed-edge-not-current-v1.0.0'
run_case inline-ghost-edge-probe-is-not-evidence ghost_inline 1 'ghost-managed-edge-not-canonical|managed-edge-probes:0/1'
run_case managed-edge-cannot-coexist-with-header-probe ghost_header_conflict 1 'headers-live-conflicts-with-managed-edge'
run_case unregistered-repo-cannot-claim-ghost-edge ghost_unregistered 1 'unregistered-ghost-managed-edge'
run_case managed-edge-table-must-match-code ghost_register_mismatch 2 'managed-edge header exception register does not match checker'
run_case managed-edge-full-row-must-match-code ghost_register_field_mismatch 2 'managed-edge header exception full row does not match checker policy'
run_case actor-guard-syntax-cannot-escape actor_guard_variant 1 'security-yml:skips-dependabot'
run_case actor-guard-negated-equality-cannot-escape actor_guard_negated 1 'security-yml:skips-dependabot'
run_case actor-guard-reversed-negated-equality-cannot-escape actor_guard_negated_reverse 1 'security-yml:skips-dependabot'
run_case actor-guard-in-comment-is-not-live actor_guard_commented 0 'Fleet conformant'
run_case actor-guard-startswith-cannot-escape actor_guard_startswith 1 'security-yml:skips-dependabot'
run_case pin-gate-job-must-admit-pull-requests pin_job_push_only 1 'security-yml:no-pin-gate'
run_case dependabot-app-secrets-required missing_dependabot_secret 1 'dependabot-secret:FLEET_AUTOMERGE_PRIVATE_KEY'
run_case empty-suppression-reason-fails empty_suppression_reason 1 'suppression GHSA-test:.*reason'
run_case invalid-calendar-date-fails invalid_suppression_date 1 'suppression GHSA-test:.*valid.*date|not a valid.*date'
run_case ruleset-shape-and-forbidden-contexts bad_ruleset 1 'ruleset:not-active.*ruleset:not-branch-target.*ruleset:not-default-branch-only.*ruleset:strict-on.*ruleset-forbids:dependabot-auto-merge.*ruleset-forbids:review_/_review.*ruleset-lacks:block-force-pushes.*required-context-not-actions-job:Vercel'
run_case ruleset-source-must-be-present ruleset_source_missing 1 'ruleset-source:CI:any'
run_case ruleset-source-cannot-be-null ruleset_source_null 1 'ruleset-source:CI:any'
run_case ruleset-source-must-be-github-actions ruleset_source_wrong 1 'ruleset-source:CI:999'
run_case ruleset-source-shape-is-validated ruleset_source_malformed 2 'ruleset.*shape|unexpected response shape'
run_case ruleset-listing-is-paginated ruleset_duplicate_page 2 'multiple main-requires-green-ci rulesets'
run_case github-actions-app-shape-is-validated app_identity_malformed 2 'GitHub Actions App identity.*shape'
run_case github-actions-app-refusal-aborts app_identity_refused 2 'GitHub Actions App identity.*HTTP 403|refused'
run_case review-caller-template-is-frozen review_canonical_drift 2 'review caller.*behavior lock|canonical review caller differs'
run_case review-caller-template-refusal-aborts review_canonical_refused 2 'review caller template.*HTTP 403|refused'
run_case review-caller-copies-are-identical review_caller_drift 1 'review-caller:differs-from-template'
run_case force-push-rule-is-separate missing_force_push_rule 1 'ruleset-lacks:block-force-pushes'
run_case required-context-must-be-actions-job external_required_context 1 'required-context-not-actions-job:Acme_Deploy'
run_case headers-live-is-never-a-pr-required-context headers_required_context 1 'ruleset-forbids:Headers_live'
run_case skipped-job-name-proves-membership skipped_required_context 0 'Fleet conformant'
run_case headers-must-share-catchall-route split_header_routes 1 'vercel-catchall-routes|vercel-headers-catchall'
run_case live-pr-workflow-invalidates-exemption exempt_live_pr_workflow 1 'exemption-stale:.*docs.yml'
run_case block-sequence-pr-invalidates-exemption exempt_block_sequence 1 'exemption-stale:.*docs.yml'
run_case indentless-block-sequence-pr-invalidates-exemption exempt_indentless_sequence 1 'exemption-stale:.*docs.yml'
run_case spaced-on-key-pr-invalidates-exemption exempt_spaced_on 1 'exemption-stale:.*docs.yml'
run_case explicit-on-key-invalidates-exemption exempt_explicit_on 1 'exemption-stale:.*docs.yml'
run_case tagged-on-key-invalidates-exemption exempt_tagged_on 1 'exemption-stale:.*docs.yml'
run_case escaped-on-key-invalidates-exemption exempt_escaped_on 1 'exemption-stale:.*docs.yml'
run_case tabbed-on-key-is-not-a-trigger exempt_tab_on 0 'Fleet conformant'
run_case non-main-default-is-audited exempt_non_main_default 1 'exemption-stale:.*docs.yml'
run_case slash-default-is-audited exempt_slash_default 1 'exemption-stale:.*docs.yml'
run_case missing-exempt-default-aborts exempt_missing_default 2 'ops repository identity.*shape|default_branch'
run_case malformed-exempt-branch-aborts exempt_branch_malformed 2 'ops default branch snapshot.*shape'
run_case exempt-manifest-needs-alerts alert_premise_disabled 1 'alert-premise-stale: carries package.json'
run_case exempt-manifest-with-alerts-passes alert_premise_enabled 0 'all 1 exempt repo\(s\) with a manifest have alerts on'
run_case exempt-alert-refusal-is-incomplete alert_premise_refused 2 'vulnerability-alert premise.*HTTP 403|refused'
run_case ci-filename-alone-does-not-invalidate exempt_filename_only 0 'Fleet conformant'
run_case historical-runs-do-not-invalidate exempt_historical_runs 0 'Fleet conformant'
run_case nested-pr-token-does-not-invalidate-exemption exempt_nested_token 0 'Fleet conformant'
run_case review-prefix-in-nonreview-workflow-is-a-gate-candidate review_prefix_nonreview 1 'unrequired-job:review_/_build'
run_case policy-registers-match-code register_mismatch 2 'Exceptions register does not match checker EXEMPT'
run_case registered-repo-must-exist registered_repo_missing 2 'craft repository identity.*absent|craft.*HTTP 404'
run_case pin-auditor-incomplete-preserves-exit-two pin_auditor_incomplete 2 'ACTION PIN AUDIT INCOMPLETE'
run_locale_independence_case
if [ -z "$CASE_FILTER" ]; then
  run_template_universal_case
  run_no_graphql_case
  run_snapshot_case
  run_pin_auditor_scope_case
  run_pin_auditor_failure_cases
  run_pin_auditor_git_tree_case
fi

printf '%s passed; %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
