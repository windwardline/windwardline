# frozen_string_literal: true

require "json"
require "pathname"
require "shellwords"
require "uri"

require_relative "actions_yaml_inspector"

module BootstrapConfigValidator
  class ValidationError < StandardError; end

  OWNER = "windwardline"
  REQUIRED_FILES = [
    "AGENTS.md",
    "README.md",
    ".github/workflows/ci.yml",
    ".github/workflows/security.yml",
    ".github/dependabot.yml"
  ].freeze
  PROTECTED_FILES = [
    "CLAUDE.md",
    "LICENSE",
    "SECURITY.md",
    "templates/LICENSE",
    ".github/workflows/claude-review.yml",
    ".github/workflows/dependabot-auto-merge.yml"
  ].freeze
  REQUIRED_HEADERS = [
    "Content-Security-Policy",
    "Strict-Transport-Security",
    "X-Content-Type-Options",
    "Referrer-Policy",
    "X-Frame-Options",
    "Permissions-Policy",
    "Cross-Origin-Opener-Policy"
  ].freeze
  TOP_LEVEL_KEYS = [
    "repository",
    "display_name",
    "description",
    "visibility",
    "production_url",
    "automerge_app_id",
    "ci_gates",
    "required_checks",
    "lockfiles",
    "header_contract_tests",
    "files"
  ].freeze
  WORKFLOW_ROOT_KEYS = %w[name on permissions concurrency jobs].freeze
  CI_JOB_KEYS = %w[env name needs permissions runs-on steps timeout-minutes].freeze
  CI_PERMISSIONS = {"contents" => "read"}.freeze
  SECURITY_PERMISSIONS = {
    "actions" => "read",
    "contents" => "read",
    "pull-requests" => "read",
    "security-events" => "write"
  }.freeze
  LOCKFILE_ECOSYSTEMS = {
    "package-lock.json" => "npm",
    "pnpm-lock.yaml" => "npm",
    "yarn.lock" => "npm",
    "bun.lockb" => "bun"
  }.freeze
  BOOTSTRAP_WORKFLOWS = %w[
    ci.yml
    security.yml
    claude-review.yml
    dependabot-auto-merge.yml
  ].freeze

  module_function

  def validate(manifest_path, fleet_path, release_tag, release_sha, expected_app_id,
               snapshot_root, allow_unregistered_private: false)
    manifest = parse_manifest(manifest_path)
    exact_keys!(manifest, TOP_LEVEL_KEYS, "manifest")

    repository = scalar!(manifest["repository"], "repository", 1..100)
    unless repository.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      raise ValidationError, "repository must be a lowercase kebab-case GitHub name"
    end

    display_name = scalar!(manifest["display_name"], "display_name", 1..120)
    description = scalar!(manifest["description"], "description", 1..350)
    visibility = scalar!(manifest["visibility"], "visibility", 1..10).downcase
    unless %w[public private].include?(visibility)
      raise ValidationError, "visibility must be public or private"
    end
    private_registration_present = validate_private_registration!(repository, visibility, fleet_path)
    if visibility == "private" && !private_registration_present && !allow_unregistered_private
      raise ValidationError,
            "private repository #{repository} is absent from FLEET.md's private-by-design register"
    end

    app_id = manifest["automerge_app_id"]
    unless app_id.is_a?(Integer) && app_id == expected_app_id
      raise ValidationError,
            "automerge_app_id must equal the reviewed windward-line-automerge App ID #{expected_app_id}"
    end

    production_url, production_host = production_origin(manifest["production_url"])
    ci_gates = unique_string_array!(manifest["ci_gates"], "ci_gates", allow_empty: false)
    required_checks = unique_string_array!(manifest["required_checks"], "required_checks", allow_empty: false)
    if required_checks.include?("dependabot-auto-merge")
      raise ValidationError, "dependabot-auto-merge must never be required by the branch ruleset"
    end
    if required_checks.include?("Headers live")
      raise ValidationError, "Headers live runs only after merge and on schedule and must never be required by the branch ruleset"
    end
    if required_checks.any? { |name| name.match?(/\A(?:review|claude review)(?:\s*\/|\z)/i) }
      raise ValidationError, "the advisory review must never be required by the branch ruleset"
    end

    lockfiles = unique_target_array!(manifest["lockfiles"], "lockfiles")
    header_tests = unique_target_array!(manifest["header_contract_tests"], "header_contract_tests")
    bundle_root = File.dirname(File.realpath(manifest_path))
    files = normalize_files!(manifest["files"], bundle_root, snapshot_root)
    casefolded_targets = files.keys.group_by(&:downcase)
    collision = casefolded_targets.values.find { |targets| targets.length > 1 }
    if collision
      raise ValidationError, "files contains case-insensitive target collision: #{collision.join(', ')}"
    end

    REQUIRED_FILES.each do |path|
      raise ValidationError, "files is missing required target #{path}" unless files.key?(path)
    end
    PROTECTED_FILES.each do |path|
      if files.keys.any? { |target| target.casecmp(path).zero? }
        raise ValidationError, "files cannot replace bootstrap-controlled target #{path}"
      end
    end
    supplied_workflows = files.keys.select { |path| path.downcase.start_with?(".github/workflows/") }
    extra_workflows = supplied_workflows - [
      ".github/workflows/ci.yml",
      ".github/workflows/security.yml"
    ]
    unless extra_workflows.empty?
      raise ValidationError,
            "files cannot add bootstrap-time workflow #{extra_workflows.sort.first}"
    end
    (lockfiles + header_tests).each do |path|
      raise ValidationError, "declared input #{path} is missing from files" unless files.key?(path)
    end
    derived_lockfiles = files.keys.select { |path| LOCKFILE_ECOSYSTEMS.key?(File.basename(path)) }
    unless lockfiles.sort == derived_lockfiles.sort
      raise ValidationError,
            "lockfiles must equal the lockfile population derived from files: #{derived_lockfiles.sort.join(', ')}"
    end

    files.each do |target, source|
      reject_placeholders!(source, target)
    end

    app_class = files.key?("package.json")
    if app_class
      validate_package_json!(files.fetch("package.json"))
      raise ValidationError, "app-class repositories must declare at least one lockfile" if lockfiles.empty?
      raise ValidationError, "app-class repositories must declare a header contract test" if header_tests.empty?
      raise ValidationError, "app-class repositories must supply vercel.json" unless files.key?("vercel.json")
    end
    if production_url
      raise ValidationError, "production repositories must declare a header contract test" if header_tests.empty?
      raise ValidationError, "production repositories must supply vercel.json" unless files.key?("vercel.json")
    end
    validate_vercel_headers!(files.fetch("vercel.json")) if files.key?("vercel.json")

    ci_contexts = validate_ci!(files.fetch(".github/workflows/ci.yml"), ci_gates, header_tests)
    validate_agents!(files.fetch("AGENTS.md"), ci_gates)
    security_contexts = validate_security!(
      files.fetch(".github/workflows/security.yml"),
      production_url,
      lockfiles,
      release_tag,
      release_sha
    )
    expected_checks = ci_contexts + security_contexts
    unless required_checks == expected_checks
      raise ValidationError,
            "required_checks must equal the ordered live gate list: #{expected_checks.join(', ')}"
    end

    validate_dependabot!(files.fetch(".github/dependabot.yml"), derived_lockfiles)

    {
      "repository" => repository,
      "full_repository" => "#{OWNER}/#{repository}",
      "display_name" => display_name,
      "description" => description,
      "visibility" => visibility,
      "private_registration_present" => private_registration_present,
      "production_url" => production_url,
      "production_host" => production_host,
      "license_subject" => production_host || display_name,
      "automerge_app_id" => app_id,
      "ci_gates" => ci_gates,
      "required_checks" => required_checks,
      "lockfiles" => lockfiles,
      "header_contract_tests" => header_tests,
      "files" => files,
      "release_tag" => release_tag,
      "release_sha" => release_sha
    }
  rescue JSON::ParserError => e
    raise ValidationError, "manifest is not valid JSON: #{e.message}"
  rescue Errno::ENOENT, Errno::EACCES => e
    raise ValidationError, e.message
  end

  def parse_manifest(path)
    expanded = File.expand_path(path)
    stat = File.lstat(expanded)
    raise ValidationError, "manifest must be a regular file, not a symlink" if stat.symlink?
    raise ValidationError, "manifest must be a regular file" unless stat.file?
    resolved = File.realpath(expanded)
    unless resolved == expanded
      raise ValidationError, "manifest path must not traverse a symlink"
    end

    value = File.open(expanded, File::RDONLY | File::NOFOLLOW) do |io|
      opened = io.stat
      current = File.stat(resolved)
      unless opened.file? && opened.dev == current.dev && opened.ino == current.ino
        raise ValidationError, "manifest changed while it was opened"
      end
      JSON.parse(io.read)
    end
    raise ValidationError, "manifest root must be a JSON object" unless value.is_a?(Hash)

    value["visibility"] ||= "public"
    value
  end

  def exact_keys!(object, expected, label)
    unknown = object.keys - expected
    missing = expected - object.keys
    raise ValidationError, "#{label} has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    raise ValidationError, "#{label} is missing keys: #{missing.join(', ')}" unless missing.empty?
  end

  def scalar!(value, label, length)
    unless value.is_a?(String) && length.cover?(value.length) && value.match?(/\S/) &&
           !value.match?(/[\r\n\t\0]/)
      raise ValidationError, "#{label} must be a single-line nonblank string (#{length.begin}-#{length.end} characters)"
    end
    value
  end

  def production_origin(value)
    return [nil, nil] if value.nil?
    raise ValidationError, "production_url must be null or an HTTPS origin" unless value.is_a?(String)

    uri = URI.parse(value)
    valid_host = uri.host&.match?(/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/i)
    unless uri.scheme == "https" && valid_host && uri.userinfo.nil? && uri.port == 443 &&
           (uri.path.nil? || uri.path.empty? || uri.path == "/") && uri.query.nil? && uri.fragment.nil?
      raise ValidationError, "production_url must be one HTTPS origin with no credentials, port, path, query, or fragment"
    end
    origin = "https://#{uri.host.downcase}"
    [origin, uri.host.downcase]
  rescue URI::InvalidURIError
    raise ValidationError, "production_url must be a valid HTTPS origin"
  end

  def validate_private_registration!(repository, visibility, fleet_path)
    return true unless visibility == "private"

    rows = []
    inside = false
    File.foreach(fleet_path) do |line|
      inside = true if line.strip == "## Repository visibility"
      next unless inside
      break if line.start_with?("Checked both directions.")

      match = line.match(/\A\| `([^`]+)` \|/)
      rows << match[1] if match
    end
    rows.include?(repository)
  end

  def unique_string_array!(value, label, allow_empty: true)
    unless value.is_a?(Array) && (allow_empty || !value.empty?) &&
           value.all? { |entry| entry.is_a?(String) && entry.match?(/\S/) && !entry.match?(/[\r\n\t\0]/) }
      qualifier = allow_empty ? "an array of" : "a nonempty array of"
      raise ValidationError, "#{label} must be #{qualifier} single-line nonblank strings"
    end
    raise ValidationError, "#{label} contains duplicates" unless value.uniq.length == value.length

    value
  end

  def unique_target_array!(value, label)
    targets = unique_string_array!(value, label)
    targets.each { |target| validate_target!(target, label) }
    targets
  end

  def normalize_files!(value, bundle_root, snapshot_root)
    raise ValidationError, "files must be a nonempty JSON object" unless value.is_a?(Hash) && !value.empty?
    snapshot_root = File.expand_path(snapshot_root)
    snapshot_stat = File.lstat(snapshot_root)
    unless snapshot_stat.directory? && !snapshot_stat.symlink? && File.realpath(snapshot_root) == snapshot_root
      raise ValidationError, "snapshot root must be one physical directory"
    end
    raise ValidationError, "snapshot root must begin empty" unless Dir.empty?(snapshot_root)

    value.each_with_index.each_with_object({}) do |((target, source), index), normalized|
      validate_target!(target, "files target")
      unless source.is_a?(String) && source.match?(/\S/) && !source.match?(/[\r\n\t\0\\]/)
        raise ValidationError, "source for #{target} must be a single-line nonblank path"
      end
      source_path = Pathname.new(source)
      source_path = Pathname.new(bundle_root).join(source_path) unless source_path.absolute?
      expanded = File.expand_path(source_path.cleanpath.to_s)
      unless path_beneath?(expanded, bundle_root)
        raise ValidationError, "source for #{target} must stay beneath the manifest bundle root"
      end
      resolved = File.realpath(expanded)
      unless resolved == expanded && path_beneath?(resolved, bundle_root)
        raise ValidationError, "source for #{target} must not traverse a symlink"
      end
      snapshot = File.join(snapshot_root, format("%04d", index))
      File.open(expanded, File::RDONLY | File::NOFOLLOW) do |source_io|
        opened = source_io.stat
        current = File.stat(resolved)
        raise ValidationError, "source for #{target} must be a regular file" unless opened.file?
        unless opened.dev == current.dev && opened.ino == current.ino
          raise ValidationError, "source for #{target} changed while it was opened"
        end
        raise ValidationError, "source for #{target} is empty" if opened.size.zero?
        raise ValidationError, "source for #{target} exceeds 50 MiB" if opened.size > 50 * 1024 * 1024
        body = source_io.read
        raise ValidationError, "source for #{target} changed while it was read" unless body.bytesize == opened.size
        File.open(snapshot, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |snapshot_io|
          snapshot_io.write(body)
          snapshot_io.flush
          snapshot_io.fsync
        end
        body.clear
      end
      normalized[target] = snapshot
    end
  rescue Errno::ELOOP
    raise ValidationError, "manifest bundle contains a symlinked file"
  end

  def path_beneath?(path, root)
    path.start_with?("#{root}#{File::SEPARATOR}")
  end

  def validate_target!(target, label)
    unless target.is_a?(String) && !target.empty? && !target.start_with?("/") &&
           target.ascii_only? && target.match?(/\A[ -~]+\z/) &&
           !target.match?(/[\r\n\t\0\\]/) &&
           target.split("/").none? { |part| part.empty? || part == "." || part == ".." } &&
           target.split("/").first.downcase != ".git"
      raise ValidationError, "#{label} contains unsafe repository path #{target.inspect}"
    end
    if %w[.gitleaks.toml .gitleaksignore].include?(target.downcase)
      raise ValidationError, "#{label} cannot replace the bootstrap-owned secret-scan configuration"
    end
    if target.match?(/(?:\A|\/)(?:\.env(?:\.|\z)|.*\.(?:pem|key|p12|pfx)\z)/i)
      raise ValidationError, "#{label} cannot publish credential-bearing path #{target}"
    end
  end

  def reject_placeholders!(source, target)
    body = File.binread(source)
    template_todo = /TODO\((?:one sentence:|framework \+|exact dev\/|the 3-6)/
    workflow_todo = /TODO(?:: this repo's real gates|\((?:app-class|prod-facing) repos\))/
    return unless body.match?(/\{\{(?:NAME|DOMAIN)\}\}|#{template_todo}|#{workflow_todo}/)

    raise ValidationError, "source for #{target} still contains a template placeholder"
  end

  def validate_package_json!(path)
    package = JSON.parse(File.binread(path))
    scripts = package["scripts"]
    raise ValidationError, "package.json scripts must be an object" unless scripts.is_a?(Hash)

    type_key = scripts["typecheck"].is_a?(String) && scripts["typecheck"].match?(/\S/) ? "typecheck" : "check"
    %W[#{type_key} lint test].each do |key|
      unless scripts[key].is_a?(String) && scripts[key].match?(/\S/)
        raise ValidationError, "package.json must define a nonblank #{key} script"
      end
    end
  rescue JSON::ParserError => e
    raise ValidationError, "package.json is malformed: #{e.message}"
  end

  def validate_vercel_headers!(path)
    config = JSON.parse(File.binread(path))
    routes = config["headers"]
    unless routes.is_a?(Array)
      raise ValidationError, "vercel.json headers must be an array"
    end
    catch_all = routes.select { |route| route.is_a?(Hash) && route["source"] == "/(.*)" }
    raise ValidationError, "vercel.json must contain exactly one /(.*) header route" unless catch_all.length == 1

    headers = catch_all.first["headers"]
    unless headers.is_a?(Array)
      raise ValidationError, "vercel.json catch-all headers must be an array"
    end
    names = headers.each_with_object([]) do |header, found|
      next unless header.is_a?(Hash) && header["key"].is_a?(String) &&
                  header["value"].is_a?(String) && header["value"].match?(/\S/)
      found << header["key"]
    end
    unless names.sort == REQUIRED_HEADERS.sort
      raise ValidationError, "vercel.json catch-all must define each house security header exactly once"
    end
  rescue JSON::ParserError => e
    raise ValidationError, "vercel.json is malformed: #{e.message}"
  end

  def validate_ci!(path, ci_gates, header_tests)
    parsed = ActionsYamlInspector.parse(File.binread(path))
    validate_workflow_root!(parsed.root, "ci.yml")
    reject_credential_context!(parsed.root, "ci.yml")
    events = parsed.root["on"]
    unless events.is_a?(Hash) && events.keys.sort == %w[pull_request push] &&
           exact_main_branch_trigger?(events["pull_request"]) && exact_main_branch_trigger?(events["push"])
      raise ValidationError, "ci.yml must run exactly on push and pull_request for main"
    end
    unless parsed.root["permissions"] == CI_PERMISSIONS
      raise ValidationError, "ci.yml top-level permissions must be exactly contents: read"
    end

    jobs = parsed.root["jobs"]
    raise ValidationError, "ci.yml jobs must be a nonempty mapping" unless jobs.is_a?(Hash) && !jobs.empty?

    contexts = []
    ordered_steps = []
    context_job_ids = []
    jobs.each do |job_id, job|
      raise ValidationError, "ci.yml job #{job_id} must be a mapping" unless job.is_a?(Hash)
      if job.key?("if") || job.key?("continue-on-error") || job.key?("strategy") || job.key?("matrix") ||
         job.key?("uses")
        raise ValidationError, "ci.yml job #{job_id} cannot be conditional, ignored, matrixed, or reusable"
      end
      unknown_job_keys = job.keys - CI_JOB_KEYS
      unless unknown_job_keys.empty?
        raise ValidationError,
              "ci.yml job #{job_id} has unsupported control keys: #{unknown_job_keys.join(', ')}"
      end
      unless job["runs-on"] == "ubuntu-latest"
        raise ValidationError, "ci.yml job #{job_id} must run on the reviewed ubuntu-latest runner"
      end
      timeout = job["timeout-minutes"]
      unless timeout.is_a?(String) && timeout.match?(/\A[1-9][0-9]?\z/) && timeout.to_i <= 60
        raise ValidationError, "ci.yml job #{job_id} must set timeout-minutes between 1 and 60"
      end
      if job.key?("permissions") && job["permissions"] != CI_PERMISSIONS
        raise ValidationError, "ci.yml job #{job_id} permissions must be absent or exactly contents: read"
      end
      context = job.fetch("name", job_id)
      unless context.is_a?(String) && context.match?(/\S/)
        raise ValidationError, "ci.yml job #{job_id} has an invalid display name"
      end
      contexts << context
      context_job_ids << job_id
      steps = job["steps"]
      unless steps.is_a?(Array) && !steps.empty?
        raise ValidationError, "ci.yml job #{job_id} must contain executable steps"
      end

      steps.each do |step|
        raise ValidationError, "ci.yml job #{job_id} contains a non-mapping step" unless step.is_a?(Hash)
        if step["run"].is_a?(String) && step["run"].match?(/\S/) &&
           !(step["name"].is_a?(String) && step["name"].match?(/\S/))
          raise ValidationError, "ci.yml job #{job_id} contains an unnamed run step outside ci_gates"
        end
        ordered_steps << [job_id, step] if step["name"].is_a?(String)
      end
    end
    raise ValidationError, "ci.yml has duplicate check names" unless contexts.uniq.length == contexts.length

    run_steps = ordered_steps.select { |_job_id, step| step["run"].is_a?(String) && step["run"].match?(/\S/) }
    derived_gates = run_steps.map { |_job_id, step| step.fetch("name") }
    unless ci_gates == derived_gates
      raise ValidationError,
            "ci_gates must equal the ordered unconditional run-step population: #{derived_gates.join(', ')}"
    end

    gate_steps = {}
    gate_job_ids = []
    run_steps.each do |gate_job_id, gate_step|
      gate = gate_step.fetch("name")
      if gate_step.key?("if") || gate_step.key?("continue-on-error") || gate_step.key?("shell")
        raise ValidationError, "ci_gates entry #{gate.inspect} cannot be skipped, ignored, or override its shell"
      end
      unless gate_step["run"].is_a?(String) && gate_step["run"].match?(/\S/)
        raise ValidationError, "ci_gates entry #{gate.inspect} must execute a nonblank run command"
      end
      gate_steps[gate] = gate_step
      gate_job_ids << gate_job_id
    end
    missing_job_gate = context_job_ids.find { |job_id| !gate_job_ids.include?(job_id) }
    if missing_job_gate
      raise ValidationError, "ci.yml job #{missing_job_gate} has no audited unconditional gate"
    end
    unless header_tests.empty? || ci_gates.include?("Header contract")
      raise ValidationError, "ci_gates must include Header contract when header_contract_tests are declared"
    end
    unless header_tests.empty?
      command = gate_steps.fetch("Header contract").fetch("run")
      validate_header_contract_command!(command, header_tests)
    end
    contexts
  rescue ActionsYamlInspector::ParseError => e
    raise ValidationError, "ci.yml is invalid: #{e.message}"
  end

  def validate_header_contract_command!(command, header_tests)
    invocations = command.lines.each_with_object([]) do |line, found|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      found << Shellwords.shellsplit(stripped)
    rescue ArgumentError
      raise ValidationError, "Header contract gate contains malformed shell syntax"
    end
    expected = header_tests.map do |path|
      [
        ["node", path],
        ["ruby", path],
        ["python3", path],
        ["bash", "--noprofile", "--norc", path],
        ["zsh", "-f", path],
        ["./#{path}"]
      ]
    end
    canonical = invocations.length == header_tests.length &&
                invocations.each_with_index.all? do |invocation, index|
                  expected.fetch(index).include?(invocation)
                end
    unless canonical
      raise ValidationError,
            "Header contract gate may contain only the ordered canonical command for each declared test"
    end
  end

  def validate_security!(path, production_url, lockfiles, release_tag, release_sha)
    parsed = ActionsYamlInspector.parse(File.binread(path))
    validate_workflow_root!(parsed.root, "security.yml")
    reject_credential_context!(parsed.root, "security.yml", allow_github_token: true)
    events = parsed.root["on"]
    unless events.is_a?(Hash) && events.keys.sort == %w[pull_request push schedule workflow_dispatch] &&
           exact_main_branch_trigger?(events["pull_request"]) && exact_main_branch_trigger?(events["push"]) &&
           events["schedule"].is_a?(Array) && events["workflow_dispatch"] == ""
      raise ValidationError,
            "security.yml must run exactly on main pull requests, main pushes, schedules, and workflow_dispatch"
    end
    unless parsed.root["permissions"] == SECURITY_PERMISSIONS
      raise ValidationError, "security.yml top-level permissions differ from the fleet least-privilege policy"
    end
    analysis = ActionsYamlInspector.security_analysis(parsed)

    expected_job_ids = %w[semgrep secret-scan]
    expected_job_ids << "dependency-scan" unless lockfiles.empty?
    expected_job_ids << "headers-live" if production_url
    unless analysis.fetch("job_ids") == expected_job_ids
      raise ValidationError, "security.yml jobs must equal the ordered canonical job set: #{expected_job_ids.join(', ')}"
    end

    semgrep = analysis.fetch("semgrep", [])
    secret_scans = analysis.fetch("secret_scans", [])
    unless semgrep.length == 1 && semgrep.first.values_at("valid", "pull_request_live", "push_live", "weekly_live").all?
      raise ValidationError, "security.yml must contain one canonical live Semgrep CE job"
    end
    unless secret_scans.length == 1 &&
           secret_scans.first.values_at("valid", "pull_request_live", "push_live", "weekly_live").all?
      raise ValidationError, "security.yml must contain one canonical live Secret scan job"
    end
    raise ValidationError, "security.yml must not skip an actor" if analysis.fetch("actor_guard")
    unless analysis.fetch("weekly_crons") == [ActionsYamlInspector::WEEKLY_SECURITY_CRON]
      raise ValidationError, "security.yml must contain the exact weekly security cron once"
    end
    expected_pin = "#{OWNER}/windwardline/actions/verify-action-pins@#{release_sha}"
    unless analysis.fetch("pin_gates") == 1 && analysis.fetch("pin_gate_refs") == [expected_pin]
      raise ValidationError, "security.yml pin gate must use current release #{release_tag} (#{release_sha})"
    end

    osv = analysis.fetch("osv")
    headers = analysis.fetch("headers")
    needs_daily = !lockfiles.empty? || !production_url.nil?
    daily = analysis.fetch("daily_crons")
    if needs_daily
      unless daily == ["17 13 * * *"]
        raise ValidationError, "security.yml must contain the exact daily live-input cron once"
      end
    elsif !daily.empty?
      raise ValidationError, "security.yml has a daily cron but no lockfile or production probe"
    end

    if lockfiles.empty?
      raise ValidationError, "security.yml has an OSV job but no declared lockfile" unless osv.empty?
    else
      unless osv.length == 1 && osv.first.values_at("valid", "pull_request_live", "push_live", "schedule_live").all?
        raise ValidationError, "security.yml must contain one canonical PR, push, and daily Dependency scan"
      end
      unless osv.first["lockfiles"] == lockfiles
        raise ValidationError,
              "security.yml OSV inputs must equal the ordered declared lockfile population"
      end
    end

    if production_url
      expected_header = "#{OWNER}/windwardline/actions/verify-live-headers@#{release_sha}"
      unless headers.length == 1 && headers.first.values_at("valid", "push_live", "schedule_live").all? &&
             headers.first["url"] == production_url && headers.first["ref"] == expected_header
        raise ValidationError, "security.yml must contain the current canonical header probe for #{production_url}"
      end
    elsif !headers.empty?
      raise ValidationError, "security.yml has a production header job but production_url is null"
    end

    contexts = ["Semgrep CE", "Secret scan"]
    contexts << "Dependency scan / osv-scan" unless lockfiles.empty?
    contexts
  rescue ActionsYamlInspector::ParseError, KeyError => e
    raise ValidationError, "security.yml is invalid: #{e.message}"
  end

  def validate_dependabot!(path, lockfiles)
    parsed = ActionsYamlInspector.parse(File.binread(path))
    lanes = ActionsYamlInspector.dependabot_analysis(parsed).fetch("lanes")
    malformed_days = lanes.find do |lane|
      lane["default_days_present"] && !lane["default_days"].match?(/\A[0-9]+\z/)
    end
    if malformed_days
      raise ValidationError, "cooldown.default-days must be an integer with no trailing characters"
    end
    unless lanes.all? do |lane|
      days = lane["default_days"]
      lane["enabled"] && lane["default_days_present"] &&
        days.match?(/\A[0-9]+\z/) && days.to_i >= 7
    end
      raise ValidationError, "every Dependabot lane must be enabled with cooldown.default-days of at least seven"
    end

    expected_pairs = [["github-actions", "/"]]
    lockfiles.each do |lockfile|
      ecosystem = LOCKFILE_ECOSYSTEMS.fetch(File.basename(lockfile))
      directory = File.dirname(lockfile)
      expected_pairs << [ecosystem, directory == "." ? "/" : "/#{directory}"]
    end
    expected_pairs.uniq!
    actual_pairs = lanes.flat_map do |lane|
      lane.fetch("paths").map { |directory| [lane.fetch("ecosystem"), directory] }
    end
    unless actual_pairs.sort == expected_pairs.sort
      rendered = expected_pairs.sort.map { |ecosystem, directory| "#{ecosystem}:#{directory}" }.join(", ")
      raise ValidationError,
            "Dependabot lane population must equal the derived repository ecosystem population: #{rendered}"
    end
  rescue ActionsYamlInspector::ParseError, KeyError => e
    raise ValidationError, "dependabot.yml is invalid: #{e.message}"
  end

  def validate_agents!(path, ci_gates)
    body = File.binread(path)
    BOOTSTRAP_WORKFLOWS.each do |workflow|
      unless body.match?(/(?<![A-Za-z0-9_.-])#{Regexp.escape(workflow)}(?![A-Za-z0-9_.-])/)
        raise ValidationError, "AGENTS.md must name bootstrap workflow #{workflow}"
      end
    end

    gate_lines = []
    in_gates = false
    body.each_line do |line|
      if line.match?(/\A##[[:space:]]+/)
        in_gates = line.match?(/\A##[[:space:]]+Gates(?:[[:space:]-]|\z)/i)
        next
      end
      next unless in_gates

      match = line.match(/\A-[[:space:]]+(.+?)[[:space:]]*\z/)
      gate_lines << match[1].gsub(/\A`|`\z/, "") if match
    end
    unless gate_lines == ci_gates
      raise ValidationError, "AGENTS.md ordered CI gates must equal ci_gates: #{ci_gates.join(', ')}"
    end
  end

  def validate_workflow_root!(root, label)
    unknown = root.keys - WORKFLOW_ROOT_KEYS
    raise ValidationError, "#{label} has unsupported top-level keys: #{unknown.join(', ')}" unless unknown.empty?
    raise ValidationError, "#{label} must define on, permissions, and jobs" unless %w[on permissions jobs].all? { |key| root.key?(key) }
  end

  def exact_main_branch_trigger?(value)
    value == {"branches" => ["main"]}
  end

  def reject_credential_context!(value, label, allow_github_token: false)
    expressions = credential_context_expressions(value)
    if allow_github_token
      expressions.reject! { |expression| expression.strip.casecmp("secrets.GITHUB_TOKEN").zero? }
    end
    return if expressions.empty?

    raise ValidationError, "#{label} cannot reference a credential-bearing Actions context"
  end

  def credential_context_expressions(value)
    case value
    when Hash
      value.flat_map { |key, child| credential_context_expressions(key) + credential_context_expressions(child) }
    when Array
      value.flat_map { |child| credential_context_expressions(child) }
    when String
      value.scan(/\$\{\{(.*?)\}\}/m).flatten.select do |expression|
        expression.match?(/(?<![A-Za-z0-9_])secrets(?![A-Za-z0-9_])/i) ||
          expression.match?(/(?<![A-Za-z0-9_])github\s*(?:\.\s*token|\[\s*["']token["']\s*\])/i) ||
          (expression.match?(/(?<![A-Za-z0-9_])github(?![A-Za-z0-9_])/i) &&
           expression.match?(/(?<![A-Za-z0-9_])token(?![A-Za-z0-9_])/i))
      end
    else
      []
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    manifest, fleet, tag, sha, expected_app_id_text, snapshot_root, mode = ARGV
    unless manifest && fleet && tag&.match?(/\Av\d+\.\d+\.\d+\z/) &&
           sha&.match?(/\A[0-9a-f]{40}\z/) && expected_app_id_text&.match?(/\A[1-9][0-9]*\z/) &&
           snapshot_root && %w[dry-run apply].include?(mode)
      warn "usage: #{File.basename(__FILE__)} MANIFEST FLEET.md RELEASE_TAG RELEASE_SHA EXPECTED_APP_ID SNAPSHOT_ROOT MODE"
      exit 64
    end
    expected_app_id = Integer(expected_app_id_text, 10)
    puts JSON.pretty_generate(
      BootstrapConfigValidator.validate(
        manifest, fleet, tag, sha, expected_app_id, snapshot_root,
        allow_unregistered_private: mode == "dry-run"
      )
    )
  rescue BootstrapConfigValidator::ValidationError => e
    warn "bootstrap preflight: #{e.message}"
    exit 2
  end
end
