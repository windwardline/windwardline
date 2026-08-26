# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/actions_yaml_inspector"

class ActionsYamlInspectorTest < Minitest::Test
  CHECKOUT_REF = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
  GITLEAKS_REF = "gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e"
  PIN_REF = "windwardline/windwardline/actions/verify-action-pins@0123456789abcdef0123456789abcdef01234567"
  HEADER_REF = "windwardline/windwardline/actions/verify-live-headers@0123456789abcdef0123456789abcdef01234567"
  GHOST_EDGE_REF = "windwardline/windwardline/actions/verify-ghost-managed-edge@0123456789abcdef0123456789abcdef01234567"
  OSV_REF = "google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@0123456789abcdef0123456789abcdef01234567"
  SEMGREP_IMAGE = "semgrep/semgrep@sha256:2b33f46ba66cf8cc2ad59ccfa7d22951fd00c632c38f1339e84ec8e6e641a942"

  def parse(source)
    ActionsYamlInspector.parse(source)
  end

  def canonical_security_source(extra_jobs: "")
    <<~YAML
      name: Security analysis
      on:
        pull_request:
        push:
        schedule:
          - cron: "17 9 * * 1"
          - cron: "17 13 * * *"
      permissions:
        actions: read
        contents: read
        pull-requests: read
        security-events: write
      jobs:
        semgrep:
          name: Semgrep CE
          if: github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1'
          runs-on: ubuntu-latest
          timeout-minutes: 15
          container:
            image: #{SEMGREP_IMAGE}
          steps:
            - uses: #{CHECKOUT_REF}
              with:
                persist-credentials: false
            - name: Scan application and workflow code
              run: semgrep scan --config auto --error
        secret-scan:
          name: Secret scan
          if: github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1'
          runs-on: ubuntu-latest
          timeout-minutes: 10
          steps:
            - uses: #{CHECKOUT_REF}
              with:
                fetch-depth: 0
                persist-credentials: false
            - uses: #{GITLEAKS_REF}
              env:
                GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
            - uses: #{PIN_REF}
      #{extra_jobs}
    YAML
  end

  def canonical_osv_source(scan_args: "--lockfile=package-lock.json")
    <<~YAML
      on:
        pull_request:
        push:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        dependency-scan:
          name: Dependency scan
          uses: #{OSV_REF}
          with:
            scan-args: |-
              #{scan_args.gsub("\n", "\n              ")}
            fail-on-vuln: true
            upload-sarif: false
          permissions:
            actions: read
            contents: read
            security-events: write
    YAML
  end

  def canonical_header_source
    <<~YAML
      on:
        push:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        headers-live:
          name: Headers live
          if: github.event_name != 'pull_request'
          runs-on: ubuntu-latest
          timeout-minutes: 12
          steps:
            - name: Assert the seven security headers on production
              uses: #{HEADER_REF}
              with:
                url: https://example.com
    YAML
  end

  def canonical_ghost_edge_source
    <<~YAML
      on:
        push:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        ghost-managed-edge:
          name: Ghost managed edge
          if: github.event_name != 'pull_request'
          runs-on: ubuntu-latest
          timeout-minutes: 12
          steps:
            - name: Verify the managed Ghost production edge
              uses: #{GHOST_EDGE_REF}
    YAML
  end

  def test_pull_request_trigger_decodes_supported_yaml_key_spellings
    tagged = parse("!!str on:\n  pull_request:\n")
    escaped = parse(%("o\\u006e":\n  pull_request_target:\n))

    assert ActionsYamlInspector.pull_request_trigger?(tagged)
    assert ActionsYamlInspector.pull_request_trigger?(escaped)
  end

  def test_nested_pull_request_text_is_not_a_trigger
    parsed = parse(<<~YAML)
      on:
        workflow_dispatch:
          inputs:
            note:
              description: pull_request
    YAML

    refute ActionsYamlInspector.pull_request_trigger?(parsed)
  end

  def test_uses_entries_decode_quoted_keys_and_ignore_block_scalars
    parsed = parse(<<~'YAML')
      jobs:
        audit:
          runs-on: ubuntu-latest
          steps:
            - "u\u0073es": actions/checkout@v4
            - run: |
                uses: actions/setup-node@v4
    YAML

    entries = ActionsYamlInspector.uses_entries(parsed)
    assert_equal ["actions/checkout@v4"], entries.map { |entry| entry.fetch("value") }
  end

  def test_uses_entry_preserves_the_exact_first_comment_token
    parsed = parse(<<~YAML)
      jobs:
        audit:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v4.1.0}, explanation
    YAML

    entry = ActionsYamlInspector.uses_entries(parsed).first
    assert_equal "v4.1.0},", entry.fetch("comment_token")
  end

  def test_multiple_flow_uses_remain_two_distinct_entries
    parsed = parse("jobs: {audit: {steps: [{uses: actions/checkout@v4}, {uses: actions/setup-node@v4}]}}\n")

    entries = ActionsYamlInspector.uses_entries(parsed)
    assert_equal 2, entries.length
    assert_equal 1, entries.map { |entry| entry.fetch("line") }.uniq.length
  end

  def test_uses_entries_follow_only_actions_schema_sites
    parsed = parse(<<~YAML)
      jobs:
        audit:
          uses: owner/reusable/.github/workflows/a.yml@main
          with:
            uses: not/an-action@main
      env:
        uses: also/not-an-action@main
    YAML
    composite = parse(<<~YAML)
      runs:
        using: composite
        steps:
          - uses: actions/checkout@v4
    YAML

    assert_equal ["owner/reusable/.github/workflows/a.yml@main"],
                 ActionsYamlInspector.uses_entries(parsed).map { |entry| entry.fetch("value") }
    assert_equal ["actions/checkout@v4"],
                 ActionsYamlInspector.uses_entries(composite).map { |entry| entry.fetch("value") }
  end

  def test_uses_entries_report_job_or_step_scope_and_identity
    workflow = parse(<<~YAML)
      jobs:
        reusable:
          uses: owner/repo/.github/workflows/check.yml@main
        runner:
          runs-on: ubuntu-latest
          steps:
            - run: echo setup
            - uses: actions/checkout@v4
    YAML
    composite = parse(<<~YAML)
      runs:
        using: composite
        steps:
          - uses: actions/setup-node@v4
    YAML

    job_use, step_use = ActionsYamlInspector.uses_entries(workflow)
    assert_equal({ "scope" => "job", "job_id" => "reusable", "step_index" => nil },
                 job_use.slice("scope", "job_id", "step_index"))
    assert_equal({ "scope" => "step", "job_id" => "runner", "step_index" => 2 },
                 step_use.slice("scope", "job_id", "step_index"))
    composite_use = ActionsYamlInspector.uses_entries(composite).first
    assert_equal({ "scope" => "step", "job_id" => "$composite", "step_index" => 1 },
                 composite_use.slice("scope", "job_id", "step_index"))
  end

  def test_actor_guard_is_detected_after_yaml_escape_decoding
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          "if": "github.actor != 'dependabot\u005bbot\u005d'"
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_actor_policy_reads_only_condition_sites_and_bans_both_directions
    input_only = parse(<<~'YAML')
      jobs:
        scan:
          runs-on: ubuntu-latest
          steps:
            - uses: owner/action@main
              with:
                if: github.actor != 'dependabot[bot]'
    YAML
    positive_condition = parse(<<~'YAML')
      jobs:
        scan:
          if: github.actor == 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    refute ActionsYamlInspector.security_analysis(input_only).fetch("actor_guard")
    assert ActionsYamlInspector.security_analysis(positive_condition).fetch("actor_guard")
  end

  def test_bracket_actor_access_cannot_escape_policy
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: github['actor'] != 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_pr_user_identity_cannot_escape_dependabot_policy
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: github.event.pull_request.user.login != 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_actor_predicate_cannot_hide_behind_starts_with
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: ${{ !startsWith(github.actor, 'dependabot') }}
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_unrelated_dependabot_text_is_not_an_actor_guard
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: inputs.channel != 'dependabot'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    refute ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_bracketed_pr_login_cannot_escape_actor_policy
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: github['event']['pull_request']['user']['login'] != 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_mixed_bracketed_pr_login_cannot_escape_actor_policy
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: github.event.pull_request.user['login'] != 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_event_sender_cannot_escape_actor_policy
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: github.event.sender.login != 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_actor_value_construction_cannot_escape_policy
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: ${{ github.actor != format('dependa{0}', 'bot[bot]') }}
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_actor_read_through_json_round_trip_cannot_escape_policy
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: fromJSON(toJSON(github)).actor != 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")
  end

  def test_dynamic_github_actor_access_cannot_escape_policy
    parsed = parse(<<~'YAML')
      jobs:
        scan:
          if: github[format('act{0}', 'or')] != 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(parsed).fetch("actor_guard")

    nested = parse(<<~'YAML')
      jobs:
        scan:
          if: github.event[format('send{0}', 'er')].id != 1
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML
    assert ActionsYamlInspector.security_analysis(nested).fetch("actor_guard")
  end

  def test_actor_identity_cannot_be_laundered_through_environment
    workflow_env = parse(<<~'YAML')
      env:
        EVENT_IDENTITY: ${{ github.actor }}
      jobs:
        scan:
          if: env.EVENT_IDENTITY != 'dependabot[bot]'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML
    step_env = parse(<<~'YAML')
      jobs:
        scan:
          runs-on: ubuntu-latest
          steps:
            - if: env.EVENT_IDENTITY != 'dependabot[bot]'
              env:
                EVENT_IDENTITY: ${{ github.event.sender.login }}
              run: echo scan
    YAML

    assert ActionsYamlInspector.security_analysis(workflow_env).fetch("actor_guard")
    assert ActionsYamlInspector.security_analysis(step_env).fetch("actor_guard")

    two_hop = parse(<<~'YAML')
      env:
        FIRST_IDENTITY: ${{ github.event.pull_request.user.type }}
        SECOND_IDENTITY: ${{ env.FIRST_IDENTITY }}
      jobs:
        scan:
          if: env.SECOND_IDENTITY != 'Bot'
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML
    assert ActionsYamlInspector.security_analysis(two_hop).fetch("actor_guard")
  end

  def test_multiline_flow_needs_preserves_guarded_dependency
    parsed = parse(<<~'YAML')
      on:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        prep:
          if: github.event_name == 'push'
          runs-on: ubuntu-latest
          steps:
            - run: echo prep
        dependency-scan:
          name: Dependency scan
          needs: [
            prep,
          ]
          uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@0123456789abcdef0123456789abcdef01234567
    YAML

    analysis = ActionsYamlInspector.security_analysis(parsed)
    assert_equal false, analysis.fetch("osv").first.fetch("live")
  end

  def test_guarded_header_probe_does_not_make_daily_schedule_live
    parsed = parse(<<~'YAML')
      on:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        headers-live:
          name: Headers live
          if: github.event_name != 'pull_request'
          runs-on: ubuntu-latest
          steps:
            - name: Setup only
              run: echo setup
            - name: Assert the seven security headers on production
              if: github.event_name == 'push'
              run: curl https://example.com
    YAML

    analysis = ActionsYamlInspector.security_analysis(parsed)
    assert_empty analysis.fetch("live_jobs")
    assert_equal false, analysis.fetch("headers").first.fetch("live")
  end

  def test_header_probe_requires_the_canonical_action_and_returns_its_literal_subject
    ref = "windwardline/windwardline/actions/verify-live-headers@0123456789abcdef0123456789abcdef01234567"
    parsed = parse(<<~YAML)
      on:
        push:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        headers-live:
          name: Headers live
          if: github.event_name != 'pull_request'
          timeout-minutes: 12
          runs-on: ubuntu-latest
          steps:
            - name: Assert the seven security headers on production
              uses: #{ref}
              with:
                url: https://example.com
    YAML

    header = ActionsYamlInspector.security_analysis(parsed).fetch("headers").first
    assert header.fetch("live")
    assert header.fetch("push_live")
    assert header.fetch("schedule_live")
    assert_equal ref, header.fetch("ref")
    assert_equal "https://example.com", header.fetch("url")
  end

  def test_header_probe_rejects_runtime_controls_and_non_github_runner
    mutations = {
      "workflow env" => ["on:\n", "env: { BASH_ENV: ./forge.sh }\non:\n"],
      "workflow defaults" => ["on:\n", "defaults: { run: { shell: bash } }\non:\n"],
      "job condition" => ["    if: github.event_name != 'pull_request'\n", "    if: github.event_name == 'schedule'\n"],
      "job continue" => ["  headers-live:\n", "  headers-live:\n    continue-on-error: false\n"],
      "job strategy" => ["  headers-live:\n", "  headers-live:\n    strategy: { fail-fast: false }\n"],
      "job env" => ["  headers-live:\n", "  headers-live:\n    env: { LD_PRELOAD: ./forge.so }\n"],
      "job defaults" => ["  headers-live:\n", "  headers-live:\n    defaults: { run: { shell: bash } }\n"],
      "job container" => ["  headers-live:\n", "  headers-live:\n    container: attacker/image:latest\n"],
      "job services" => ["  headers-live:\n", "  headers-live:\n    services: { attacker: { image: 'attacker/image:latest' } }\n"],
      "self hosted" => ["    runs-on: ubuntu-latest\n", "    runs-on: self-hosted\n"],
      "step if" => ["      - name: Assert the seven security headers on production\n", "      - name: Assert the seven security headers on production\n        if: true\n"],
      "step continue" => ["      - name: Assert the seven security headers on production\n", "      - name: Assert the seven security headers on production\n        continue-on-error: false\n"],
      "step env" => ["      - name: Assert the seven security headers on production\n", "      - name: Assert the seven security headers on production\n        env: { LD_PRELOAD: ./forge.so }\n"]
    }

    mutations.each do |label, (needle, replacement)|
      source = canonical_header_source.sub(needle, replacement)
      refute_equal canonical_header_source, source, "mutation fixture did not change for #{label}"
      header = ActionsYamlInspector.security_analysis(parse(source)).fetch("headers").first
      refute header.fetch("valid"), label
      refute header.fetch("push_live"), label
      refute header.fetch("schedule_live"), label
    end
  end

  def test_ghost_managed_edge_probe_is_exact_push_and_daily_evidence
    analysis = ActionsYamlInspector.security_analysis(parse(canonical_ghost_edge_source))
    edge = analysis.fetch("managed_edges").fetch(0)

    assert edge.fetch("valid")
    assert edge.fetch("live")
    assert edge.fetch("push_live")
    assert edge.fetch("schedule_live")
    assert_equal GHOST_EDGE_REF, edge.fetch("ref")
    assert_includes analysis.fetch("live_jobs"), "ghost-managed-edge"
  end

  def test_ghost_managed_edge_probe_rejects_runtime_controls_and_substitutes
    mutations = {
      "workflow env" => ["on:\n", "env: { BASH_ENV: ./forge.sh }\non:\n"],
      "wrong job id" => ["  ghost-managed-edge:\n", "  edge-check:\n"],
      "wrong name" => ["    name: Ghost managed edge\n", "    name: Managed edge\n"],
      "wrong condition" => ["    if: github.event_name != 'pull_request'\n", "    if: github.event_name == 'schedule'\n"],
      "self hosted" => ["    runs-on: ubuntu-latest\n", "    runs-on: self-hosted\n"],
      "wrong timeout" => ["    timeout-minutes: 12\n", "    timeout-minutes: 10\n"],
      "inline probe" => ["      - name: Verify the managed Ghost production edge\n        uses: #{GHOST_EDGE_REF}\n",
                         "      - name: Verify the managed Ghost production edge\n        run: curl https://grownmengrow.com\n"],
      "caller input" => ["        uses: #{GHOST_EDGE_REF}\n", "        uses: #{GHOST_EDGE_REF}\n        with: { apex: 'https://example.com' }\n"],
      "step condition" => ["      - name: Verify the managed Ghost production edge\n", "      - name: Verify the managed Ghost production edge\n        if: true\n"],
      "continue on error" => ["  ghost-managed-edge:\n", "  ghost-managed-edge:\n    continue-on-error: true\n"]
    }

    mutations.each do |label, (needle, replacement)|
      source = canonical_ghost_edge_source.sub(needle, replacement)
      refute_equal canonical_ghost_edge_source, source, "mutation fixture did not change for #{label}"
      edges = ActionsYamlInspector.security_analysis(parse(source)).fetch("managed_edges")
      assert_equal 1, edges.length, label
      refute edges.first.fetch("valid"), label
      refute edges.first.fetch("push_live"), label
      refute edges.first.fetch("schedule_live"), label
    end
  end

  def test_ghost_managed_edge_needs_chain_must_admit_push_and_schedule
    source = <<~YAML
      on:
        push:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        prep:
          if: github.event_name == 'schedule'
          runs-on: ubuntu-latest
          steps:
            - run: echo prep
        ghost-managed-edge:
          name: Ghost managed edge
          if: github.event_name != 'pull_request'
          needs: prep
          runs-on: ubuntu-latest
          timeout-minutes: 12
          steps:
            - name: Verify the managed Ghost production edge
              uses: #{GHOST_EDGE_REF}
    YAML
    edge = ActionsYamlInspector.security_analysis(parse(source)).fetch("managed_edges").first

    assert edge.fetch("valid")
    assert edge.fetch("schedule_live")
    refute edge.fetch("push_live")
  end

  def test_canonical_semgrep_secret_and_pin_jobs_are_proved_on_every_required_trigger
    analysis = ActionsYamlInspector.security_analysis(parse(canonical_security_source))

    assert analysis.fetch("pull_request_trigger")
    assert analysis.fetch("push_trigger")
    assert_equal ["17 9 * * 1"], analysis.fetch("weekly_crons")

    semgrep = analysis.fetch("semgrep").fetch(0)
    assert semgrep.fetch("valid")
    assert semgrep.fetch("pull_request_live")
    assert semgrep.fetch("push_live")
    assert semgrep.fetch("weekly_live")

    secret = analysis.fetch("secret_scans").fetch(0)
    assert secret.fetch("valid")
    assert secret.fetch("pull_request_live")
    assert secret.fetch("push_live")
    assert secret.fetch("weekly_live")
    assert_equal 1, analysis.fetch("pin_gates")
    assert_equal [PIN_REF], analysis.fetch("pin_gate_refs")
  end

  def test_noop_jobs_cannot_impersonate_semgrep_or_secret_scanning
    parsed = parse(<<~YAML)
      on:
        pull_request:
        push:
        schedule:
          - cron: "17 9 * * 1"
      jobs:
        semgrep:
          name: Semgrep CE
          runs-on: ubuntu-latest
          steps:
            - run: "true"
        secret-scan:
          name: Secret scan
          runs-on: ubuntu-latest
          steps:
            - uses: #{PIN_REF}
    YAML

    analysis = ActionsYamlInspector.security_analysis(parsed)
    refute analysis.fetch("semgrep").first.fetch("valid")
    refute analysis.fetch("secret_scans").first.fetch("valid")
    assert_equal 0, analysis.fetch("pin_gates")
  end

  def test_canonical_security_jobs_reject_untrusted_runtime_controls
    mutations = {
      "semgrep job env" => [:semgrep, "  semgrep:\n", "  semgrep:\n    env: { BASH_ENV: ./forge.sh }\n"],
      "semgrep continue" => [:semgrep, "  semgrep:\n", "  semgrep:\n    continue-on-error: false\n"],
      "semgrep strategy" => [:semgrep, "  semgrep:\n", "  semgrep:\n    strategy: { fail-fast: false }\n"],
      "semgrep defaults" => [:semgrep, "  semgrep:\n", "  semgrep:\n    defaults: { run: { shell: bash } }\n"],
      "semgrep services" => [:semgrep, "  semgrep:\n", "  semgrep:\n    services: { attacker: { image: 'attacker/image:latest' } }\n"],
      "semgrep step if" => [:semgrep, "        run: semgrep scan --config auto --error\n", "        if: true\n        run: semgrep scan --config auto --error\n"],
      "semgrep step continue" => [:semgrep, "        run: semgrep scan --config auto --error\n", "        continue-on-error: false\n        run: semgrep scan --config auto --error\n"],
      "semgrep step env" => [:semgrep, "        run: semgrep scan --config auto --error\n", "        env: { BASH_ENV: ./forge.sh }\n        run: semgrep scan --config auto --error\n"],
      "semgrep wrong condition" => [:semgrep, "    if: github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1'\n", "    if: github.event_name == 'push'\n"],
      "semgrep wrong container" => [:semgrep, SEMGREP_IMAGE, "attacker/image:latest"],
      "self hosted semgrep" => [:semgrep, "    runs-on: ubuntu-latest\n    timeout-minutes: 15\n", "    runs-on: self-hosted\n    timeout-minutes: 15\n"],
      "secret container" => [:secret, "  secret-scan:\n", "  secret-scan:\n    container: attacker/image:latest\n"],
      "secret strategy" => [:secret, "  secret-scan:\n", "  secret-scan:\n    strategy: { fail-fast: false }\n"],
      "secret continue" => [:secret, "  secret-scan:\n", "  secret-scan:\n    continue-on-error: false\n"],
      "secret defaults" => [:secret, "  secret-scan:\n", "  secret-scan:\n    defaults: { run: { shell: bash } }\n"],
      "secret services" => [:secret, "  secret-scan:\n", "  secret-scan:\n    services: { attacker: { image: 'attacker/image:latest' } }\n"],
      "secret job env" => [:secret, "  secret-scan:\n", "  secret-scan:\n    env: { LD_PRELOAD: ./forge.so }\n"],
      "secret wrong condition" => [:secret,
                                   "  secret-scan:\n    name: Secret scan\n    if: github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1'\n",
                                   "  secret-scan:\n    name: Secret scan\n    if: github.event_name == 'push'\n"],
      "pin step if" => [:secret, "      - uses: #{PIN_REF}\n", "      - uses: #{PIN_REF}\n        if: true\n"],
      "pin step env" => [:secret, "      - uses: #{PIN_REF}\n", "      - uses: #{PIN_REF}\n        env: { LD_PRELOAD: ./forge.so }\n"],
      "gitleaks continue" => [:secret, "      - uses: #{GITLEAKS_REF}\n", "      - uses: #{GITLEAKS_REF}\n        continue-on-error: false\n"],
      "self hosted secret" => [:secret, "    runs-on: ubuntu-latest\n    timeout-minutes: 10\n    steps:\n", "    runs-on: self-hosted\n    timeout-minutes: 10\n    steps:\n"]
    }

    mutations.each do |label, (target, needle, replacement)|
      source = canonical_security_source.sub(needle, replacement)
      refute_equal canonical_security_source, source, "mutation fixture did not change for #{label}"
      analysis = ActionsYamlInspector.security_analysis(parse(source))
      subject = target == :semgrep ? analysis.fetch("semgrep") : analysis.fetch("secret_scans")
      refute subject.first.fetch("valid"), label
    end
  end

  def test_security_analysis_reports_exact_root_permissions
    parsed = parse(canonical_security_source)
    analysis = ActionsYamlInspector.security_analysis(parsed)

    assert_equal true, analysis.fetch("root_permissions_valid")
    assert_equal({
      "actions" => "read",
      "contents" => "read",
      "pull-requests" => "read",
      "security-events" => "write"
    }, analysis.fetch("root_permissions"))

    widened = parse(canonical_security_source.sub(
      "permissions:\n  actions: read",
      "permissions:\n  actions: write"
    ))
    assert_equal false,
                 ActionsYamlInspector.security_analysis(widened).fetch("root_permissions_valid")
  end

  def test_workflow_env_or_defaults_invalidates_every_canonical_runner_gate
    [
      "env:\n  BASH_ENV: ./forge.sh\n",
      "defaults:\n  run:\n    shell: bash\n"
    ].each do |injected|
      source = canonical_security_source.sub("on:\n", "#{injected}on:\n")
      analysis = ActionsYamlInspector.security_analysis(parse(source))
      refute analysis.fetch("semgrep").first.fetch("valid")
      refute analysis.fetch("secret_scans").first.fetch("valid")
      assert_equal 0, analysis.fetch("pin_gates")
    end
  end

  def test_osv_needs_chain_must_be_live_on_pull_request_push_and_daily_schedule
    parsed = parse(<<~YAML)
      on:
        pull_request:
        push:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        prep:
          if: github.event_name == 'schedule'
          runs-on: ubuntu-latest
          steps:
            - run: echo prep
        dependency-scan:
          name: Dependency scan
          needs: prep
          uses: #{OSV_REF}
          with:
            scan-args: --lockfile=package-lock.json
            fail-on-vuln: true
            upload-sarif: false
          permissions:
            actions: read
            contents: read
            security-events: write
    YAML

    osv = ActionsYamlInspector.security_analysis(parsed).fetch("osv").first
    assert osv.fetch("valid")
    assert osv.fetch("schedule_live")
    refute osv.fetch("pull_request_live")
    refute osv.fetch("push_live")
  end

  def test_osv_requires_a_real_lockfile_scan_failure_gate_and_least_privilege_permissions
    nested = ActionsYamlInspector.security_analysis(
      parse(canonical_osv_source(scan_args: "--config=osv-scanner.toml\n--lockfile=theme/pnpm-lock.yaml"))
    ).fetch("osv").first
    assert nested.fetch("valid")
    assert nested.fetch("pull_request_live")
    assert nested.fetch("push_live")
    assert nested.fetch("schedule_live")

    mutations = {
      "failure gate disabled" => ["fail-on-vuln: true", "fail-on-vuln: false"],
      "SARIF behavior changed" => ["upload-sarif: false", "upload-sarif: true"],
      "not a lockfile" => ["--lockfile=package-lock.json", "--lockfile=README.md"],
      "path traversal" => ["--lockfile=package-lock.json", "--lockfile=../package-lock.json"],
      "extra scanner argument" => ["--lockfile=package-lock.json", "--lockfile=package-lock.json\n              --format=table"],
      "unsafe contents permission" => ["contents: read", "contents: write"],
      "runtime environment" => ["    name: Dependency scan\n", "    name: Dependency scan\n    env: { BASH_ENV: ./forge.sh }\n"],
      "continue on error" => ["    name: Dependency scan\n", "    name: Dependency scan\n    continue-on-error: false\n"],
      "strategy" => ["    name: Dependency scan\n", "    name: Dependency scan\n    strategy: { fail-fast: false }\n"],
      "container" => ["    name: Dependency scan\n", "    name: Dependency scan\n    container: attacker/image:latest\n"],
      "services" => ["    name: Dependency scan\n", "    name: Dependency scan\n    services: { attacker: { image: 'attacker/image:latest' } }\n"],
      "defaults" => ["    name: Dependency scan\n", "    name: Dependency scan\n    defaults: { run: { shell: bash } }\n"],
      "arbitrary condition" => ["    name: Dependency scan\n", "    name: Dependency scan\n    if: github.event_name == 'schedule'\n"]
    }

    mutations.each do |label, (needle, replacement)|
      source = canonical_osv_source.sub(needle, replacement)
      refute_equal canonical_osv_source, source, "mutation fixture did not change for #{label}"
      refute ActionsYamlInspector.security_analysis(parse(source)).fetch("osv").first.fetch("valid"), label
    end
  end

  def test_structural_branch_filters_remain_live_but_malformed_trigger_configs_do_not
    source = canonical_osv_source
             .sub("  pull_request:\n", "  pull_request:\n    branches: [main]\n")
             .sub("  push:\n", "  push:\n    branches: [main]\n")
    analysis = ActionsYamlInspector.security_analysis(parse(source))

    assert analysis.fetch("pull_request_trigger")
    assert analysis.fetch("push_trigger")
    assert analysis.fetch("osv").first.fetch("pull_request_live")
    assert analysis.fetch("osv").first.fetch("push_live")

    malformed = canonical_osv_source
                .sub("  pull_request:\n", "  pull_request: false\n")
                .sub("  push:\n", "  push: false\n")
    malformed_analysis = ActionsYamlInspector.security_analysis(parse(malformed))
    refute malformed_analysis.fetch("pull_request_trigger")
    refute malformed_analysis.fetch("push_trigger")
    refute malformed_analysis.fetch("osv").first.fetch("pull_request_live")
    refute malformed_analysis.fetch("osv").first.fetch("push_live")

    skip_all = canonical_osv_source
               .sub("  pull_request:\n", "  pull_request:\n    branches-ignore: ['**']\n")
               .sub("  push:\n", "  push:\n    paths: [docs/**]\n")
    skip_analysis = ActionsYamlInspector.security_analysis(parse(skip_all))
    refute skip_analysis.fetch("pull_request_trigger")
    refute skip_analysis.fetch("push_trigger")
  end

  def test_header_needs_chain_and_workflow_trigger_must_admit_push_and_daily_schedule
    parsed = parse(<<~YAML)
      on:
        pull_request:
        push:
        schedule:
          - cron: "17 13 * * *"
      jobs:
        prep:
          if: github.event_name == 'schedule'
          runs-on: ubuntu-latest
          steps:
            - run: echo prep
        headers-live:
          name: Headers live
          if: github.event_name != 'pull_request'
          needs: prep
          runs-on: ubuntu-latest
          timeout-minutes: 12
          steps:
            - name: Assert the seven security headers on production
              uses: #{HEADER_REF}
              with:
                url: https://example.com
    YAML

    header = ActionsYamlInspector.security_analysis(parsed).fetch("headers").first
    assert header.fetch("valid")
    assert header.fetch("schedule_live")
    refute header.fetch("push_live")

    no_push = parsed.root.dup
    no_push["on"] = no_push.fetch("on").reject { |event, _value| event == "push" }
    analysis = ActionsYamlInspector.security_analysis(parse(no_push.to_yaml))
    refute analysis.fetch("push_trigger")
    refute analysis.fetch("headers").first.fetch("push_live")
  end

  def test_inline_or_expression_driven_header_probes_are_not_structural_evidence
    inline = parse(<<~YAML)
      jobs:
        headers-live:
          name: Headers live
          timeout-minutes: 12
          runs-on: ubuntu-latest
          steps:
            - name: Assert the seven security headers on production
              run: curl https://example.com
    YAML
    expression = parse(<<~'YAML')
      jobs:
        headers-live:
          name: Headers live
          timeout-minutes: 12
          runs-on: ubuntu-latest
          steps:
            - name: Assert the seven security headers on production
              uses: windwardline/windwardline/actions/verify-live-headers@0123456789abcdef0123456789abcdef01234567
              with:
                url: ${{ vars.PRODUCTION_URL }}
    YAML
    wrong_timeout = parse(<<~YAML)
      jobs:
        headers-live:
          name: Headers live
          timeout-minutes: 10
          runs-on: ubuntu-latest
          steps:
            - name: Assert the seven security headers on production
              uses: windwardline/windwardline/actions/verify-live-headers@0123456789abcdef0123456789abcdef01234567
              with:
                url: https://example.com
    YAML

    [inline, expression, wrong_timeout].each do |subject|
      refute ActionsYamlInspector.security_analysis(subject).fetch("headers").first.fetch("live")
    end
  end

  def test_quoted_continue_on_error_invalidates_pin_gate
    parsed = parse(<<~'YAML')
      jobs:
        secret:
          name: Secret scan
          "if": github.event_name == 'push'
          runs-on: ubuntu-latest
          steps:
            - uses: windwardline/windwardline/actions/verify-action-pins@0123456789abcdef0123456789abcdef01234567
              "continue-on-error": true
    YAML

    analysis = ActionsYamlInspector.security_analysis(parsed)
    assert_equal 1, analysis.fetch("secret_scan_jobs")
    assert_equal 0, analysis.fetch("pin_gates")
  end

  def test_push_only_boolean_tail_cannot_make_pin_job_pr_live
    parsed = parse(<<~'YAML')
      jobs:
        secret:
          name: Secret scan
          if: github.event_name != 'schedule' && github.event_name == 'push'
          runs-on: ubuntu-latest
          steps:
            - uses: windwardline/windwardline/actions/verify-action-pins@0123456789abcdef0123456789abcdef01234567
    YAML

    assert_equal 0, ActionsYamlInspector.security_analysis(parsed).fetch("pin_gates")
  end

  def test_empty_runs_on_cannot_make_a_runner_job_executable
    parsed = parse(<<~YAML)
      jobs:
        secret:
          name: Secret scan
          runs-on: []
          steps:
            - uses: windwardline/windwardline/actions/verify-action-pins@0123456789abcdef0123456789abcdef01234567
    YAML

    error = assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.security_analysis(parsed)
    end
    assert_match(/runs-on.*nonempty/i, error.message)
  end

  def test_reusable_job_cannot_also_define_runner_fields
    with_steps = parse(<<~YAML)
      jobs:
        scan:
          uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@0123456789abcdef0123456789abcdef01234567
          steps:
            - run: echo bypass
    YAML
    with_runner = parse(<<~YAML)
      jobs:
        scan:
          uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@0123456789abcdef0123456789abcdef01234567
          runs-on: ubuntu-latest
    YAML

    assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.security_analysis(with_steps)
    end
    assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.security_analysis(with_runner)
    end
  end

  def test_job_ids_and_runner_steps_must_follow_actions_schema
    invalid_id = parse(<<~YAML)
      jobs:
        123:
          runs-on: ubuntu-latest
          steps:
            - run: echo scan
    YAML
    empty_steps = parse(<<~YAML)
      jobs:
        scan:
          runs-on: ubuntu-latest
          steps: []
    YAML
    mixed_step = parse(<<~YAML)
      jobs:
        scan:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567
              run: echo bypass
    YAML

    [invalid_id, empty_steps, mixed_step].each do |parsed|
      assert_raises(ActionsYamlInspector::ParseError) do
        ActionsYamlInspector.security_analysis(parsed)
      end
    end
  end

  def test_runner_job_requires_runs_on_and_accepts_supported_shapes
    missing = parse(<<~YAML)
      jobs:
        scan:
          steps:
            - run: echo scan
    YAML
    supported = [
      "ubuntu-latest",
      ["self-hosted", "linux"],
      { "group" => "ubuntu-runners", "labels" => ["gpu", "x64"] }
    ]

    assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.security_analysis(missing)
    end
    supported.each do |runs_on|
      source = { "jobs" => { "scan" => { "runs-on" => runs_on, "steps" => [{ "run" => "echo scan" }] } } }.to_yaml
      ActionsYamlInspector.security_analysis(parse(source))
    end
  end

  def test_pin_gate_pr_path_includes_needs
    parsed = parse(<<~'YAML')
      jobs:
        prep:
          if: github.event_name == 'push'
          runs-on: ubuntu-latest
          steps:
            - run: echo prep
        secret:
          name: Secret scan
          needs: prep
          runs-on: ubuntu-latest
          steps:
            - uses: windwardline/windwardline/actions/verify-action-pins@0123456789abcdef0123456789abcdef01234567
    YAML

    assert_equal 0, ActionsYamlInspector.security_analysis(parsed).fetch("pin_gates")
  end

  def test_pin_gate_analysis_returns_the_exact_live_action_ref
    analysis = ActionsYamlInspector.security_analysis(parse(canonical_security_source))
    assert_equal 1, analysis.fetch("pin_gates")
    assert_equal [PIN_REF], analysis.fetch("pin_gate_refs")
  end

  def test_duplicate_mapping_keys_are_rejected
    error = assert_raises(ActionsYamlInspector::ParseError) do
      parse("on: push\non: pull_request\n")
    end
    assert_match(/duplicate/i, error.message)
  end

  def test_decoded_duplicate_mapping_keys_are_rejected
    error = assert_raises(ActionsYamlInspector::ParseError) do
      parse(%(on: push\n"o\\u006e": pull_request\n))
    end
    assert_match(/duplicate/i, error.message)
  end

  def test_yaml_indirection_and_multiple_documents_are_rejected
    sources = [
      "defaults: &defaults\n  runs-on: ubuntu-latest\njobs: {}\n",
      "&key on: push\n",
      "defaults: &defaults\n  runs-on: ubuntu-latest\njobs:\n  scan: *defaults\n",
      "defaults: &defaults\n  runs-on: ubuntu-latest\njobs:\n  scan:\n    <<: *defaults\n",
      %(jobs:\n  scan:\n    "\\u003c\\u003c": { runs-on: ubuntu-latest }\n),
      "on: push\n---\non: pull_request\n"
    ]

    sources.each do |source|
      assert_raises(ActionsYamlInspector::ParseError) { parse(source) }
    end
  end

  def test_impossible_daily_cron_is_rejected
    parsed = parse(<<~YAML)
      on:
        schedule:
          - cron: "99 99 * * *"
      jobs: {}
    YAML

    assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.security_analysis(parsed)
    end
  end

  def test_invalid_nondaily_cron_cannot_hide_beside_a_valid_daily_cron
    parsed = parse(<<~YAML)
      on:
        schedule:
          - cron: "17 13 * * *"
          - cron: "17 9 32 * *"
      jobs: {}
    YAML

    assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.security_analysis(parsed)
    end
  end

  def test_dependabot_lanes_follow_yaml_structure
    parsed = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: weekly }
          cooldown: { default-days: 7 }
        -
          package-ecosystem: github-actions
          directory: /
          schedule: { interval: weekly }
    YAML

    lanes = ActionsYamlInspector.dependabot_analysis(parsed).fetch("lanes")
    assert_equal 2, lanes.length
    assert lanes.first.fetch("default_days_present")
    refute lanes.last.fetch("default_days_present")
  end

  def test_dependabot_requires_a_real_lane_sequence
    parsed = parse("version: 2\nupdates: {}\n")

    assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.dependabot_analysis(parsed)
    end
  end

  def test_dependabot_requires_version_and_complete_lane_identity
    missing_version = parse(<<~YAML)
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: weekly }
          cooldown: { default-days: 7 }
    YAML
    missing_directory = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          schedule: { interval: weekly }
          cooldown: { default-days: 7 }
    YAML
    missing_schedule = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          cooldown: { default-days: 7 }
    YAML

    [missing_version, missing_directory, missing_schedule].each do |parsed|
      assert_raises(ActionsYamlInspector::ParseError) do
        ActionsYamlInspector.dependabot_analysis(parsed)
      end
    end
  end

  def test_dependabot_rejects_unknown_ecosystems_and_noncanonical_paths
    invalid_ecosystem = <<~YAML
      version: 2
      updates:
        - package-ecosystem: pnpm
          directory: /
          schedule: { interval: weekly }
    YAML
    invalid_paths = [
      "packages/app", "/packages/", "//packages", "/packages//app", "/packages/./app",
      "/packages/../app", "/${{ github.repository }}", "/packages\\app"
    ]

    [invalid_ecosystem, *invalid_paths.map do |path|
      <<~YAML
        version: 2
        updates:
          - package-ecosystem: npm
            directory: #{path.inspect}
            schedule: { interval: weekly }
      YAML
    end].each do |source|
      assert_raises(ActionsYamlInspector::ParseError) do
        ActionsYamlInspector.dependabot_analysis(parse(source))
      end
    end

    %w[bazel nix sbt npm github-actions].each do |ecosystem|
      parsed = parse(<<~YAML)
        version: 2
        updates:
          - package-ecosystem: #{ecosystem}
            directory: /packages/app
            schedule: { interval: weekly }
      YAML
      assert_equal ["/packages/app"],
                   ActionsYamlInspector.dependabot_analysis(parsed).fetch("lanes").first.fetch("paths")
    end
  end

  def test_dependabot_paths_are_unique_within_and_across_ecosystem_lanes
    duplicate_within = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directories: [/apps/web, /apps/web]
          schedule: { interval: weekly }
    YAML
    duplicate_across = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /apps/web
          schedule: { interval: weekly }
        - package-ecosystem: npm
          directories: [/apps/api, /apps/web]
          schedule: { interval: daily }
    YAML

    [duplicate_within, duplicate_across].each do |parsed|
      assert_raises(ActionsYamlInspector::ParseError) do
        ActionsYamlInspector.dependabot_analysis(parsed)
      end
    end

    distinct_ecosystems = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: weekly }
        - package-ecosystem: github-actions
          directory: /
          schedule: { interval: weekly }
    YAML
    assert_equal 2, ActionsYamlInspector.dependabot_analysis(distinct_ecosystems).fetch("lanes").length
  end

  def test_dependabot_indentless_lane_sequence_is_structural
    parsed = parse(<<~YAML)
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

    lanes = ActionsYamlInspector.dependabot_analysis(parsed).fetch("lanes")
    assert_equal %w[npm github-actions], lanes.map { |lane| lane.fetch("ecosystem") }
  end

  def test_dependabot_interval_and_cronjob_are_validated
    invalid_interval = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: hourly }
    YAML
    missing_cronjob = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: cron }
    YAML
    stray_cronjob = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: weekly, cronjob: "17 13 * * *" }
    YAML
    valid_cron = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: cron, cronjob: "17 13 * * *" }
    YAML
    malformed_cron = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: cron, cronjob: "99 13 * * *" }
    YAML

    [invalid_interval, missing_cronjob, stray_cronjob, malformed_cron].each do |parsed|
      assert_raises(ActionsYamlInspector::ParseError) do
        ActionsYamlInspector.dependabot_analysis(parsed)
      end
    end
    assert ActionsYamlInspector.dependabot_analysis(valid_cron).fetch("lanes").first.fetch("enabled")
  end

  def test_dependabot_disabled_lane_is_reported_without_becoming_a_parse_failure
    parsed = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: weekly }
          open-pull-requests-limit: 0
    YAML
    malformed = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: weekly }
          open-pull-requests-limit: none
    YAML

    lane = ActionsYamlInspector.dependabot_analysis(parsed).fetch("lanes").first
    refute lane.fetch("enabled")
    assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.dependabot_analysis(malformed)
    end


    positive = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          directory: /
          schedule: { interval: weekly }
          open-pull-requests-limit: 3
    YAML
    assert ActionsYamlInspector.dependabot_analysis(positive).fetch("lanes").first.fetch("enabled")
  end

  def test_dependabot_multi_ecosystem_groups_fail_closed_until_the_house_form_supports_them
    parsed = parse(<<~YAML)
      version: 2
      updates:
        - package-ecosystem: npm
          multi-ecosystem-group: application
          directory: /
          schedule: { interval: weekly }
    YAML

    assert_raises(ActionsYamlInspector::ParseError) do
      ActionsYamlInspector.dependabot_analysis(parsed)
    end
  end
end
