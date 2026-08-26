# frozen_string_literal: true

require "json"
require "psych"

# Parses the GitHub Actions YAML surfaces used by the fleet's deterministic
# gates. Psych provides the YAML grammar; this layer deliberately converts the
# syntax tree itself so mapping keys remain strings (`on` must not become the
# YAML 1.1 boolean true), quoted Unicode escapes are decoded, duplicate keys are
# rejected, and aliases cannot hide control flow.
module ActionsYamlInspector
  class ParseError < StandardError; end

  Parsed = Struct.new(:root, :ast, :source_lines, keyword_init: true)
  WEEKLY_SECURITY_CRON = "17 9 * * 1"
  SEMGREP_IMAGE = "semgrep/semgrep@sha256:2b33f46ba66cf8cc2ad59ccfa7d22951fd00c632c38f1339e84ec8e6e641a942"
  FULL_SHA = "[0-9a-f]{40}"
  DEPENDABOT_ECOSYSTEMS = %w[
    bazel bun bundler cargo composer conda deno devcontainers docker docker-compose dotnet-sdk elm
    github-actions gitsubmodule gomod gradle helm julia maven mix nix npm nuget opentofu pip pre-commit
    pub rust-toolchain sbt swift terraform uv vcpkg
  ].freeze
  SECURITY_ROOT_PERMISSIONS = {
    "actions" => "read",
    "contents" => "read",
    "pull-requests" => "read",
    "security-events" => "write"
  }.freeze

  module_function

  def parse(source)
    stream = Psych.parse_stream(source)
    documents = Array(stream.children)
    raise ParseError, "expected exactly one YAML document" unless documents.length == 1

    document = documents.first
    root_node = Array(document.children).first
    raise ParseError, "workflow document was empty" unless root_node

    root = convert(root_node, "$ROOT")
    raise ParseError, "workflow root must be a mapping" unless root.is_a?(Hash)

    Parsed.new(root: root, ast: root_node, source_lines: source.lines)
  rescue Psych::SyntaxError => e
    raise ParseError, "malformed YAML: #{e.problem}"
  end

  def convert(node, path)
    if node.respond_to?(:anchor) && node.anchor
      raise ParseError, "YAML anchors are unsupported at #{path}"
    end

    case node
    when Psych::Nodes::Mapping
      children = Array(node.children)
      raise ParseError, "malformed mapping at #{path}" unless children.length.even?

      children.each_slice(2).each_with_object({}) do |(key_node, value_node), out|
        unless key_node.is_a?(Psych::Nodes::Scalar)
          raise ParseError, "mapping key at #{path} was not a scalar"
        end
        if key_node.respond_to?(:anchor) && key_node.anchor
          raise ParseError, "YAML anchors are unsupported on mapping keys at #{path}"
        end

        key = key_node.value.to_s
        raise ParseError, "YAML merge keys are unsupported at #{path}" if key == "<<"
        raise ParseError, "duplicate mapping key #{key.inspect} at #{path}" if out.key?(key)

        out[key] = convert(value_node, "#{path}.#{key}")
      end
    when Psych::Nodes::Sequence
      Array(node.children).each_with_index.map { |child, index| convert(child, "#{path}[#{index}]") }
    when Psych::Nodes::Scalar
      node.value.to_s
    when Psych::Nodes::Alias
      raise ParseError, "YAML aliases are unsupported at #{path}"
    else
      raise ParseError, "unsupported YAML node #{node.class} at #{path}"
    end
  end

  def pull_request_trigger?(parsed)
    events = parsed.root["on"]
    names = case events
            when String then [events]
            when Array then events
            when Hash then events.keys
            when nil then []
            else raise ParseError, "top-level on value had an unsupported shape"
            end
    unless names.all? { |name| name.is_a?(String) }
      raise ParseError, "top-level on sequence contained a non-scalar event"
    end

    names.any? { |name| %w[pull_request pull_request_target].include?(name) }
  end

  def uses_entries(parsed)
    entries = []
    jobs_node = mapping_value(parsed.ast, "jobs")
    if jobs_node
      raise ParseError, "jobs must be a mapping" unless jobs_node.is_a?(Psych::Nodes::Mapping)
      mapping_pairs(jobs_node).each do |job_key, job_node|
        raise ParseError, "job #{job_key.value} must be a mapping" unless job_node.is_a?(Psych::Nodes::Mapping)
        job_id = job_key.value.to_s
        add_uses_entry(entries, mapping_value(job_node, "uses"), parsed,
                       scope: "job", job_id: job_id, step_index: nil) if mapping_value(job_node, "uses")
        add_step_uses(entries, mapping_value(job_node, "steps"), parsed, "job #{job_id}", job_id)
      end
    end

    runs_node = mapping_value(parsed.ast, "runs")
    if runs_node
      raise ParseError, "runs must be a mapping" unless runs_node.is_a?(Psych::Nodes::Mapping)
      add_step_uses(entries, mapping_value(runs_node, "steps"), parsed, "composite action", "$composite")
    end

    entries
  end

  def mapping_pairs(node)
    raise ParseError, "expected a mapping node" unless node.is_a?(Psych::Nodes::Mapping)
    Array(node.children).each_slice(2).to_a
  end

  def mapping_value(node, key)
    return nil unless node.is_a?(Psych::Nodes::Mapping)
    pair = mapping_pairs(node).find { |key_node, _value_node| key_node.value.to_s == key }
    pair && pair.last
  end

  def add_step_uses(entries, steps_node, parsed, label, job_id)
    return unless steps_node
    raise ParseError, "steps in #{label} must be a sequence" unless steps_node.is_a?(Psych::Nodes::Sequence)

    Array(steps_node.children).each_with_index do |step_node, index|
      raise ParseError, "step #{index + 1} in #{label} must be a mapping" unless step_node.is_a?(Psych::Nodes::Mapping)
      uses_node = mapping_value(step_node, "uses")
      add_uses_entry(entries, uses_node, parsed,
                     scope: "step", job_id: job_id, step_index: index + 1) if uses_node
    end
  end

  def add_uses_entry(entries, value_node, parsed, scope:, job_id:, step_index:)
    unless value_node.is_a?(Psych::Nodes::Scalar)
      raise ParseError, "uses value on line #{value_node.start_line + 1} was not a scalar"
    end

    value = value_node.value.to_s
    unless value.match?(/\A\S+\z/)
      raise ParseError, "uses value on line #{value_node.start_line + 1} was empty or contained whitespace"
    end

    comment = trailing_comment(parsed.source_lines[value_node.start_line].to_s)
    entries << {
      "value" => value,
      "comment" => comment,
      "comment_token" => comment.split(/[[:space:]]+/, 2).first.to_s,
      "line" => value_node.start_line + 1,
      "scope" => scope,
      "job_id" => job_id,
      "step_index" => step_index
    }
  end

  def trailing_comment(line)
    quote = nil
    escaped = false
    index = 0
    while index < line.length
      char = line[index]
      if quote
        if quote == '"' && char == "\\" && !escaped
          escaped = true
          index += 1
          next
        end
        if char == quote && !escaped
          if quote == "'" && line[index + 1] == "'"
            index += 2
            next
          end
          quote = nil
        end
        escaped = false
      elsif char == '"' || char == "'"
        quote = char
      elsif char == "#" && (index.zero? || line[index - 1] =~ /\s/)
        return line[(index + 1)..].to_s.strip
      end
      index += 1
    end
    ""
  end

  def security_analysis(parsed)
    root = parsed.root
    jobs = root.fetch("jobs", {})
    raise ParseError, "jobs must be a mapping" unless jobs.is_a?(Hash)

    normalized_jobs = {}
    actor_guard = false
    workflow_env_taints = identity_tainted_env_keys(root["env"], [], "workflow env")
    workflow_runner_safe = !root.key?("env") && !root.key?("defaults")
    jobs.each do |job_id, raw_job|
      unless job_id.is_a?(String) && job_id.match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/)
        raise ParseError, "job id #{job_id.inspect} is invalid"
      end
      raise ParseError, "job #{job_id} must be a mapping" unless raw_job.is_a?(Hash)

      normalized = normalize_job(job_id, raw_job)
      actor_guard ||= actor_guard_in_job?(raw_job, workflow_env_taints, job_id)
      normalized_jobs[job_id] = normalized
    end

    crons = schedule_crons(root["on"])
    daily = crons.select { |cron| cron_fields(cron)[2, 3] == ["*", "*", "*"] }
    weekly = crons.select { |cron| cron == WEEKLY_SECURITY_CRON }
    pull_request_trigger = event_trigger?(root["on"], "pull_request")
    push_trigger = event_trigger?(root["on"], "push")

    build_proof = lambda do |event, cron = nil|
      proof = {}
      visiting = {}
      prove = nil
      prove = lambda do |job_id|
        return proof[job_id] if proof.key?(job_id)
        return false if visiting[job_id]

        job = normalized_jobs[job_id]
        return proof[job_id] = false unless job

        visiting[job_id] = true
        dependencies_live = job.fetch("needs").all? { |dependency| prove.call(dependency) }
        visiting.delete(job_id)
        proof[job_id] = job_event_executable?(job, event, cron) && dependencies_live
      end
      prove
    end

    prove_pull_request = build_proof.call("pull_request")
    prove_push = build_proof.call("push")
    daily_proofs = daily.map { |cron| build_proof.call("schedule", cron) }
    weekly_proofs = weekly.map { |cron| build_proof.call("schedule", cron) }

    event_live = lambda do |job_id, event|
      case event
      when "pull_request" then pull_request_trigger && prove_pull_request.call(job_id)
      when "push" then push_trigger && prove_push.call(job_id)
      when "daily" then daily_proofs.any? { |prove| prove.call(job_id) }
      when "weekly" then weekly_proofs.any? { |prove| prove.call(job_id) }
      else false
      end
    end

    osv = []
    headers = []
    managed_edges = []
    semgrep = []
    secret_scans = []
    live_jobs = []
    normalized_jobs.each do |job_id, job|
      if job.fetch("osv")
        schedule_live = event_live.call(job_id, "daily") && job.fetch("osv_valid")
        osv << {
          "id" => job_id,
          "valid" => job.fetch("osv_valid"),
          "live" => schedule_live,
          "pull_request_live" => event_live.call(job_id, "pull_request") && job.fetch("osv_valid"),
          "push_live" => event_live.call(job_id, "push") && job.fetch("osv_valid"),
          "schedule_live" => schedule_live,
          "has_if" => job.fetch("has_if"),
          "condition" => job.fetch("condition"),
          "lockfiles" => job.fetch("osv_lockfiles")
        }
        live_jobs << job_id if schedule_live
      end
      if job.fetch("header")
        header_valid = workflow_runner_safe && job.fetch("header_valid")
        schedule_live = event_live.call(job_id, "daily") && header_valid
        headers << {
          "id" => job_id,
          "valid" => header_valid,
          "live" => schedule_live,
          "push_live" => event_live.call(job_id, "push") && header_valid,
          "schedule_live" => schedule_live,
          "ref" => job.fetch("header_ref"),
          "url" => job.fetch("header_url")
        }
        live_jobs << job_id if schedule_live
      end
      if job.fetch("managed_edge")
        valid = workflow_runner_safe && job.fetch("managed_edge_valid")
        schedule_live = event_live.call(job_id, "daily") && valid
        managed_edges << {
          "id" => job_id,
          "valid" => valid,
          "live" => schedule_live,
          "push_live" => event_live.call(job_id, "push") && valid,
          "schedule_live" => schedule_live,
          "ref" => job.fetch("managed_edge_ref")
        }
        live_jobs << job_id if schedule_live
      end
      if job.fetch("semgrep_candidate")
        valid = workflow_runner_safe && job.fetch("semgrep_valid")
        semgrep << {
          "id" => job_id,
          "valid" => valid,
          "pull_request_live" => valid && event_live.call(job_id, "pull_request"),
          "push_live" => valid && event_live.call(job_id, "push"),
          "weekly_live" => valid && event_live.call(job_id, "weekly")
        }
      end
      if job.fetch("secret_candidate")
        valid = workflow_runner_safe && job.fetch("secret_valid")
        secret_scans << {
          "id" => job_id,
          "valid" => valid,
          "pull_request_live" => valid && event_live.call(job_id, "pull_request"),
          "push_live" => valid && event_live.call(job_id, "push"),
          "weekly_live" => valid && event_live.call(job_id, "weekly")
        }
      end
    end

    pin_gate_refs = normalized_jobs.each_with_object([]) do |(job_id, job), refs|
      next unless workflow_runner_safe && job.fetch("secret_valid")
      next unless event_live.call(job_id, "pull_request") && event_live.call(job_id, "push") &&
                  event_live.call(job_id, "weekly")

      refs << job.fetch("steps").fetch(2).fetch("uses")
    end

    {
      "job_ids" => normalized_jobs.keys,
      "root_permissions" => root.fetch("permissions", nil),
      "root_permissions_valid" => root["permissions"] == SECURITY_ROOT_PERMISSIONS,
      "pull_request_trigger" => pull_request_trigger,
      "push_trigger" => push_trigger,
      "daily_crons" => daily,
      "weekly_crons" => weekly,
      "live_jobs" => live_jobs.uniq,
      "osv" => osv,
      "headers" => headers,
      "managed_edges" => managed_edges,
      "semgrep" => semgrep,
      "secret_scans" => secret_scans,
      "actor_guard" => actor_guard,
      "secret_scan_jobs" => secret_scans.length,
      "pin_gates" => pin_gate_refs.length,
      "pin_gate_refs" => pin_gate_refs
    }
  end

  def dependabot_analysis(parsed)
    unless parsed.root["version"] == "2"
      raise ParseError, "Dependabot version must be the scalar 2"
    end

    updates = parsed.root["updates"]
    raise ParseError, "updates must be a sequence" unless updates.is_a?(Array)
    raise ParseError, "updates must contain at least one live lane" if updates.empty?

    covered_paths = {}
    lanes = updates.each_with_index.map do |lane, index|
      raise ParseError, "update lane #{index + 1} must be a mapping" unless lane.is_a?(Hash)

      ecosystem = lane["package-ecosystem"]
      unless ecosystem.is_a?(String) && DEPENDABOT_ECOSYSTEMS.include?(ecosystem)
        raise ParseError, "package-ecosystem in update lane #{index + 1} is unsupported"
      end

      directory_present = lane.key?("directory")
      directories_present = lane.key?("directories")
      if directory_present == directories_present
        raise ParseError, "update lane #{index + 1} must define exactly one of directory or directories"
      end
      if directory_present
        directory = lane["directory"]
        validate_dependabot_path(directory, "directory in update lane #{index + 1}")
        paths = [directory]
      else
        directories = lane["directories"]
        unless directories.is_a?(Array) && !directories.empty?
          raise ParseError, "directories in update lane #{index + 1} must be a nonempty sequence"
        end
        directories.each { |path| validate_dependabot_path(path, "directories in update lane #{index + 1}") }
        if directories.uniq.length != directories.length
          raise ParseError, "directories in update lane #{index + 1} contains a duplicate path"
        end
        paths = directories
      end
      paths.each do |path|
        key = [ecosystem, path]
        if covered_paths.key?(key)
          raise ParseError,
                "update lane #{index + 1} duplicates #{ecosystem} path #{path.inspect} from lane #{covered_paths.fetch(key)}"
        end
        covered_paths[key] = index + 1
      end

      schedule = lane["schedule"]
      unless schedule.is_a?(Hash) && schedule["interval"].is_a?(String) && schedule["interval"].match?(/\S/)
        raise ParseError, "schedule.interval in update lane #{index + 1} must be a nonblank scalar"
      end
      interval = schedule.fetch("interval")
      allowed_intervals = %w[daily weekly monthly quarterly semiannually yearly cron]
      unless allowed_intervals.include?(interval)
        raise ParseError, "schedule.interval in update lane #{index + 1} is unsupported"
      end
      cronjob_present = schedule.key?("cronjob")
      if interval == "cron"
        cronjob = schedule["cronjob"]
        unless cronjob.is_a?(String) && cronjob.match?(/\S/)
          raise ParseError, "schedule.cronjob in cron update lane #{index + 1} must be a nonblank scalar"
        end
        validate_cron_expression(cronjob)
      elsif cronjob_present
        raise ParseError, "schedule.cronjob is only valid for a cron update lane"
      end

      if lane.key?("multi-ecosystem-group")
        raise ParseError, "multi-ecosystem-group update lanes are not supported by the fleet house form"
      end

      limit = lane.fetch("open-pull-requests-limit", "5")
      unless limit.is_a?(String) && limit.match?(/\A[0-9]+\z/)
        raise ParseError, "open-pull-requests-limit in update lane #{index + 1} must be a nonnegative integer"
      end

      cooldown = lane["cooldown"]
      unless cooldown.nil? || cooldown.is_a?(Hash)
        raise ParseError, "cooldown in update lane #{index + 1} must be a mapping"
      end
      present = cooldown.is_a?(Hash) && cooldown.key?("default-days")
      days = present ? cooldown["default-days"] : ""
      if present && !days.is_a?(String)
        raise ParseError, "cooldown.default-days in update lane #{index + 1} must be a scalar"
      end

      {
        "index" => index + 1,
        "ecosystem" => ecosystem,
        "paths" => paths,
        "enabled" => limit.to_i.positive?,
        "interval" => interval,
        "default_days_present" => present,
        "default_days" => days.to_s
      }
    end

    { "lanes" => lanes }
  end

  def validate_dependabot_path(path, label)
    unless path.is_a?(String) && (path == "/" || path.match?(%r{\A/(?:[A-Za-z0-9@._*+-]+/)*[A-Za-z0-9@._*+-]+\z}))
      raise ParseError, "#{label} must be a normalized root-anchored repository path"
    end

    segments = path.split("/").reject(&:empty?)
    if segments.any? { |segment| %w[. ..].include?(segment) }
      raise ParseError, "#{label} cannot contain dot or parent traversal segments"
    end
  end

  def normalize_job(job_id, raw)
    condition = optional_scalar(raw, "if", "job #{job_id}")
    uses_present = raw.key?("uses")
    runner_present = raw.key?("runs-on")
    steps_present = raw.key?("steps")
    uses = optional_scalar(raw, "uses", "job #{job_id}").to_s
    if uses_present
      raise ParseError, "uses in job #{job_id} must be nonblank" unless uses.match?(/\S/)
      conflicts = []
      conflicts << "runs-on" if runner_present
      conflicts << "steps" if steps_present
      unless conflicts.empty?
        raise ParseError, "reusable job #{job_id} cannot also define #{conflicts.join(' or ')}"
      end
    else
      raise ParseError, "runner job #{job_id} must define runs-on" unless runner_present
      validate_runs_on(raw.fetch("runs-on"), job_id)
    end

    steps = normalize_steps(raw.fetch("steps", []), job_id)
    if !uses_present && steps.empty?
      raise ParseError, "runner job #{job_id} must define at least one step"
    end
    name = optional_scalar(raw, "name", "job #{job_id}").to_s
    needs = normalize_needs(raw["needs"], job_id)
    continue_present = raw.key?("continue-on-error")
    strategy_present = raw.key?("strategy") || raw.key?("matrix")
    reusable = uses.match?(/\S/)

    osv = uses.match?(%r{\Agoogle/osv-scanner-action/\.github/workflows/osv-scanner-reusable\.yml@\S+\z})
    osv_valid = osv && canonical_osv_job?(job_id, name, raw, uses)
    osv_lockfiles = if raw["with"].is_a?(Hash)
                      canonical_osv_lockfiles(raw["with"]["scan-args"]) || []
                    else
                      []
                    end

    semgrep_candidate = job_id == "semgrep" || name == "Semgrep CE"
    semgrep_valid = canonical_semgrep_job?(job_id, name, raw, steps)

    secret_candidate = job_id == "secret-scan" || name == "Secret scan"
    secret_valid = canonical_secret_job?(job_id, name, raw, steps)

    header = job_id == "headers-live" || name == "Headers live"
    probe = steps.first
    header_ref = probe ? probe.fetch("uses") : ""
    header_url = probe ? probe.fetch("with").fetch("url", "") : ""
    header_valid = header && job_id == "headers-live" && name == "Headers live" &&
                   runner_present && raw["runs-on"] == "ubuntu-latest" && !reusable &&
                   exact_keys?(raw, %w[name if needs runs-on steps timeout-minutes]) &&
                   weekly_excluded_header_condition?(condition) &&
                   raw["timeout-minutes"] == "12" &&
                   steps.length == 1 && probe.fetch("name") == "Assert the seven security headers on production" &&
                   probe.fetch("run").empty? &&
                   header_ref.match?(%r{\Awindwardline/windwardline/actions/verify-live-headers@#{FULL_SHA}\z}) &&
                   exact_keys?(probe.fetch("raw"), %w[name uses with]) &&
                   probe.fetch("with").keys == ["url"] &&
                   header_url.match?(%r{\Ahttps://(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}/?\z}) &&
                   !probe.fetch("if_present") && !probe.fetch("continue_present")

    managed_edge = job_id == "ghost-managed-edge" || name == "Ghost managed edge"
    managed_edge_ref = probe ? probe.fetch("uses") : ""
    managed_edge_valid = managed_edge && job_id == "ghost-managed-edge" && name == "Ghost managed edge" &&
                         runner_present && raw["runs-on"] == "ubuntu-latest" && !reusable &&
                         exact_keys?(raw, %w[name if needs runs-on steps timeout-minutes]) &&
                         weekly_excluded_header_condition?(condition) &&
                         raw["timeout-minutes"] == "12" &&
                         steps.length == 1 && probe.fetch("name") == "Verify the managed Ghost production edge" &&
                         probe.fetch("run").empty? &&
                         managed_edge_ref.match?(%r{\Awindwardline/windwardline/actions/verify-ghost-managed-edge@#{FULL_SHA}\z}) &&
                         exact_keys?(probe.fetch("raw"), %w[name uses]) &&
                         probe.fetch("with").empty? &&
                         !probe.fetch("if_present") && !probe.fetch("continue_present")

    {
      "raw" => raw,
      "name" => name,
      "condition" => condition.to_s,
      "has_if" => raw.key?("if"),
      "continue_present" => continue_present,
      "strategy_present" => strategy_present,
      "needs" => needs,
      "steps" => steps,
      "runner_present" => runner_present,
      "reusable" => reusable,
      "osv" => osv,
      "osv_valid" => osv_valid,
      "osv_lockfiles" => osv_lockfiles,
      "semgrep_candidate" => semgrep_candidate,
      "semgrep_valid" => semgrep_valid,
      "secret_candidate" => secret_candidate,
      "secret_valid" => secret_valid,
      "header" => header,
      "header_valid" => header_valid,
      "header_ref" => header_ref,
      "header_url" => header_url.sub(%r{/\z}, ""),
      "managed_edge" => managed_edge,
      "managed_edge_valid" => managed_edge_valid,
      "managed_edge_ref" => managed_edge_ref
    }
  end

  def canonical_semgrep_job?(job_id, name, raw, steps)
    return false unless job_id == "semgrep" && name == "Semgrep CE"
    return false unless exact_keys?(raw, %w[container if name needs runs-on steps timeout-minutes])
    return false unless raw["runs-on"] == "ubuntu-latest" && raw["timeout-minutes"] == "15"
    return false unless weekly_security_condition?(raw["if"])
    return false unless raw["container"] == { "image" => SEMGREP_IMAGE }
    return false unless steps.length == 2

    checkout, scan = steps
    canonical_checkout_step?(checkout, secret: false) &&
      exact_keys?(scan.fetch("raw"), %w[name run]) &&
      scan.fetch("run").strip == "semgrep scan --config auto --error"
  end

  def canonical_osv_job?(job_id, name, raw, uses)
    return false unless job_id == "dependency-scan" && name == "Dependency scan"
    return false unless exact_keys?(raw, %w[if name needs permissions uses with])
    return false unless required_keys?(raw, %w[name permissions uses with])
    return false unless uses.match?(%r{\Agoogle/osv-scanner-action/\.github/workflows/osv-scanner-reusable\.yml@#{FULL_SHA}\z})
    return false if raw.key?("if") && !weekly_security_condition?(raw["if"])
    return false unless raw["permissions"] == {
      "actions" => "read", "contents" => "read", "security-events" => "write"
    }

    with = raw["with"]
    return false unless with.is_a?(Hash) && with.keys.sort == %w[fail-on-vuln scan-args upload-sarif]
    return false unless with["fail-on-vuln"] == "true" && with["upload-sarif"] == "false"

    canonical_osv_scan_args?(with["scan-args"])
  end

  def canonical_osv_scan_args?(value)
    !canonical_osv_lockfiles(value).nil?
  end

  def canonical_osv_lockfiles(value)
    return nil unless value.is_a?(String)

    arguments = value.lines.map(&:strip).reject(&:empty?)
    return nil unless arguments.length.between?(1, 51)

    lockfiles = arguments.grep(/\A--lockfile=/)
    configs = arguments.grep(/\A--config=/)
    return nil if lockfiles.empty? || configs.length > 1
    return nil unless arguments.length == lockfiles.length + configs.length

    paths = lockfiles.map { |argument| argument.delete_prefix("--lockfile=") }
    return nil unless paths.uniq.length == paths.length
    return nil unless paths.all? do |lockfile|
      safe_repo_path?(lockfile) &&
        %w[package-lock.json pnpm-lock.yaml yarn.lock bun.lockb].include?(File.basename(lockfile))
    end

    valid_config = configs.empty? || begin
      config = configs.first.delete_prefix("--config=")
      safe_repo_path?(config) && File.basename(config) == "osv-scanner.toml"
    end
    valid_config ? paths : nil
  end

  def safe_repo_path?(path)
    parts = path.to_s.split("/", -1)
    !parts.empty? && parts.none?(&:empty?) && parts.none? { |part| %w[. ..].include?(part) } &&
      parts.all? { |part| part.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) }
  end

  def canonical_secret_job?(job_id, name, raw, steps)
    return false unless job_id == "secret-scan" && name == "Secret scan"
    return false unless exact_keys?(raw, %w[if name needs runs-on steps timeout-minutes])
    return false unless raw["runs-on"] == "ubuntu-latest" && raw["timeout-minutes"] == "10"
    return false unless weekly_security_condition?(raw["if"])
    return false unless steps.length == 3

    checkout, gitleaks, pin_gate = steps
    canonical_checkout_step?(checkout, secret: true) &&
      exact_keys?(gitleaks.fetch("raw"), %w[name uses env]) &&
      gitleaks.fetch("uses").match?(%r{\Agitleaks/gitleaks-action@#{FULL_SHA}\z}) &&
      gitleaks.fetch("raw")["env"] == { "GITHUB_TOKEN" => "${{ secrets.GITHUB_TOKEN }}" } &&
      exact_keys?(pin_gate.fetch("raw"), %w[name uses]) &&
      pin_gate.fetch("uses").match?(%r{\Awindwardline/windwardline/actions/verify-action-pins@#{FULL_SHA}\z})
  end

  def canonical_checkout_step?(step, secret:)
    expected_with = if secret
                      { "fetch-depth" => "0", "persist-credentials" => "false" }
                    else
                      { "persist-credentials" => "false" }
                    end
    exact_keys?(step.fetch("raw"), %w[name uses with]) &&
      step.fetch("uses").match?(%r{\Aactions/checkout@#{FULL_SHA}\z}) &&
      step.fetch("with") == expected_with
  end

  def exact_keys?(mapping, allowed)
    mapping.is_a?(Hash) && (mapping.keys - allowed).empty?
  end

  def required_keys?(mapping, required)
    mapping.is_a?(Hash) && (required - mapping.keys).empty?
  end

  def weekly_security_condition?(condition)
    body = "github.event_name != 'schedule' || github.event.schedule == '#{WEEKLY_SECURITY_CRON}'"
    [body, "${{ #{body} }}", "${{ (#{body}) }}"].include?(condition.to_s.strip)
  end

  def weekly_excluded_header_condition?(condition)
    condition.to_s.strip == "github.event_name != 'pull_request'"
  end

  def validate_runs_on(value, job_id)
    valid_scalar = lambda { |entry| entry.is_a?(String) && entry.match?(/\S/) }
    case value
    when String
      raise ParseError, "runs-on in job #{job_id} must be nonblank" unless valid_scalar.call(value)
    when Array
      unless !value.empty? && value.all? { |entry| valid_scalar.call(entry) }
        raise ParseError, "runs-on in job #{job_id} must be a nonempty sequence of nonblank scalars"
      end
    when Hash
      unknown = value.keys - %w[group labels]
      raise ParseError, "runs-on in job #{job_id} has unsupported keys: #{unknown.join(', ')}" unless unknown.empty?
      raise ParseError, "runs-on in job #{job_id} must be nonempty" if value.empty?

      if value.key?("group") && !valid_scalar.call(value["group"])
        raise ParseError, "runs-on.group in job #{job_id} must be a nonblank scalar"
      end
      if value.key?("labels")
        labels = value["labels"]
        valid_labels = valid_scalar.call(labels) ||
                       (labels.is_a?(Array) && !labels.empty? && labels.all? { |entry| valid_scalar.call(entry) })
        raise ParseError, "runs-on.labels in job #{job_id} must be a nonblank scalar or sequence" unless valid_labels
      end
    else
      raise ParseError, "runs-on in job #{job_id} had an unsupported shape"
    end
  end

  def normalize_steps(raw_steps, job_id)
    raise ParseError, "steps for job #{job_id} must be a sequence" unless raw_steps.is_a?(Array)

    raw_steps.each_with_index.map do |raw, index|
      raise ParseError, "step #{index + 1} in job #{job_id} must be a mapping" unless raw.is_a?(Hash)

      uses = optional_scalar(raw, "uses", "step #{index + 1} in job #{job_id}").to_s
      run = optional_scalar(raw, "run", "step #{index + 1} in job #{job_id}").to_s
      with = raw.fetch("with", {})
      unless with.is_a?(Hash) && with.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
        raise ParseError, "with in step #{index + 1} of job #{job_id} must be a scalar mapping"
      end
      executable_keys = [uses, run].count { |value| value.match?(/\S/) }
      unless executable_keys == 1 && !(raw.key?("uses") && raw.key?("run"))
        raise ParseError, "step #{index + 1} in job #{job_id} must define exactly one nonblank uses or run"
      end

      {
        "raw" => raw,
        "name" => optional_scalar(raw, "name", "step #{index + 1} in job #{job_id}").to_s,
        "uses" => uses,
        "run" => run,
        "with" => with,
        "if" => optional_scalar(raw, "if", "step #{index + 1} in job #{job_id}").to_s,
        "if_present" => raw.key?("if"),
        "continue_present" => raw.key?("continue-on-error")
      }
    end
  end

  def optional_scalar(hash, key, label)
    return nil unless hash.key?(key)

    value = hash[key]
    raise ParseError, "#{key} in #{label} must be a scalar" unless value.is_a?(String)

    value
  end

  def normalize_needs(value, job_id)
    values = case value
             when nil then []
             when String then [value]
             when Array then value
             else raise ParseError, "needs in job #{job_id} must be a scalar or sequence"
             end
    unless values.all? { |entry| entry.is_a?(String) && entry.match?(/\A[A-Za-z0-9_-]+\z/) }
      raise ParseError, "needs in job #{job_id} contained an invalid job id"
    end

    values
  end

  def actor_discriminator?(condition)
    actor_identity_reference?(condition)
  end

  def actor_identity_reference?(value)
    plain = value.to_s.downcase
    canonical = plain.gsub(/\[\s*["']([a-z_][a-z0-9_-]*)["']\s*\]/, '.\1').gsub(/\s+/, '')
    identity = canonical.match?(%r{github\.(?:actor|triggering_actor)(?:\b|[^a-z0-9_])}) ||
               canonical.match?(%r{github[^a-z0-9_]+(?:actor|triggering_actor)(?:\b|[^a-z0-9_])}) ||
               canonical.include?("github.event.pull_request.user.login") ||
               canonical.include?("github.event.sender.login") ||
               canonical.match?(%r{github\.event(?:\.[a-z0-9_-]+)*\.(?:sender|user|actor|pusher)(?:\.login)?(?:\b|[^a-z0-9_])}) ||
               canonical.match?(%r{github(?:\.[a-z_][a-z0-9_-]*)*\[(?!["'])}) ||
               canonical.include?("tojson(github)")
    identity
  end

  def actor_guard_in_job?(raw_job, inherited_taints, job_id)
    job_taints = identity_tainted_env_keys(raw_job["env"], inherited_taints, "env in job #{job_id}")
    condition = raw_job["if"]
    return true if condition && actor_condition?(condition, job_taints)

    steps = raw_job.fetch("steps", [])
    return false unless steps.is_a?(Array)

    steps.each_with_index.any? do |step, index|
      next false unless step.is_a?(Hash)

      step_taints = identity_tainted_env_keys(
        step["env"], job_taints, "env in step #{index + 1} of job #{job_id}"
      )
      step.key?("if") && actor_condition?(step["if"], step_taints)
    end
  end

  def actor_condition?(condition, tainted_env_keys)
    return true if actor_identity_reference?(condition)
    return false if tainted_env_keys.empty?

    canonical = condition.to_s.downcase
                         .gsub(/\[\s*["']([a-z_][a-z0-9_-]*)["']\s*\]/, '.\1')
                         .gsub(/\s+/, '')
    return true if canonical.match?(%r{env\[(?!["'])})

    tainted_env_keys.any? do |key|
      canonical.match?(%r{(?:\A|[^a-z0-9_])env\.#{Regexp.escape(key)}(?:\b|[^a-z0-9_])})
    end
  end

  def identity_tainted_env_keys(raw_env, inherited, label)
    return inherited.dup if raw_env.nil?
    raise ParseError, "#{label} must be a mapping" unless raw_env.is_a?(Hash)

    tainted = inherited.map(&:downcase).uniq
    loop do
      before = tainted.length
      raw_env.each do |key, value|
        raise ParseError, "#{label} keys and values must be scalars" unless key.is_a?(String) && value.is_a?(String)

        normalized_key = key.downcase
        next if tainted.include?(normalized_key)

        tainted << normalized_key if actor_identity_reference?(value) || actor_condition?(value, tainted)
      end
      break if tainted.length == before
    end
    tainted
  end

  def job_event_executable?(job, event, cron)
    return false if job.fetch("continue_present") || job.fetch("strategy_present")
    if job.fetch("has_if")
      return false unless condition_admits_event?(job.fetch("condition"), event, cron)
    end
    return true if job.fetch("reusable")
    return false unless job.fetch("runner_present")

    job.fetch("steps").any? do |step|
      executable = step.fetch("run").match?(/\S/) ||
                   (step.fetch("uses").match?(/\S/) && !step.fetch("uses").start_with?("./"))
      executable && !step.fetch("continue_present") &&
        (!step.fetch("if_present") || condition_admits_event?(step.fetch("if"), event, cron))
    end
  end

  def condition_admits_event?(condition, event, cron = nil)
    plain = condition_expression(condition)
    return false unless plain

    disjunctions = plain.split("||", -1)
    return false if disjunctions.any?(&:empty?)

    disjunctions.any? do |disjunction|
      conjunctions = disjunction.split("&&", -1)
      !conjunctions.any?(&:empty?) &&
        conjunctions.all? { |atom| condition_atom_value(atom, event, cron) }
    end
  end

  def condition_expression(condition)
    plain = condition.to_s.strip.downcase
    if plain.start_with?("${{") && plain.end_with?("}}")
      plain = plain[3...-2].to_s.strip
    end
    while outer_parentheses_wrap?(plain)
      plain = plain[1...-1].to_s.strip
    end
    return nil if plain.include?("(") || plain.include?(")")

    plain.gsub(/[\s'"]/, "")
  end

  def outer_parentheses_wrap?(plain)
    return false unless plain.start_with?("(") && plain.end_with?(")")

    depth = 0
    plain.each_char.with_index do |character, index|
      depth += 1 if character == "("
      depth -= 1 if character == ")"
      return false if depth.zero? && index < plain.length - 1
      return false if depth.negative?
    end
    depth.zero?
  end

  def condition_atom_value(atom, event, cron)
    return true if atom == "true"
    return false if atom == "false"

    if (match = atom.match(/\Agithub\.event_name(==|!=)(pull_request|push|schedule)\z/))
      equal = event == match[2]
      return match[1] == "==" ? equal : !equal
    end
    if (match = atom.match(/\A(pull_request|push|schedule)(==|!=)github\.event_name\z/))
      equal = event == match[1]
      return match[2] == "==" ? equal : !equal
    end
    if (match = atom.match(/\Agithub\.event\.schedule(==|!=)(.+)\z/))
      equal = event == "schedule" && normalized_cron(cron) == match[2]
      return match[1] == "==" ? equal : !equal
    end
    if (match = atom.match(/\A(.+)(==|!=)github\.event\.schedule\z/))
      equal = event == "schedule" && normalized_cron(cron) == match[1]
      return match[2] == "==" ? equal : !equal
    end

    false
  end

  def normalized_cron(cron)
    cron.to_s.gsub(/\s/, "")
  end

  def condition_admits_schedule?(condition)
    condition_admits_event?(condition, "schedule", WEEKLY_SECURITY_CRON)
  end

  def condition_admits_pull_request?(condition)
    condition_admits_event?(condition, "pull_request")
  end

  def event_trigger?(events, expected)
    case events
    when String
      events == expected
    when Array
      unless events.all? { |name| name.is_a?(String) }
        raise ParseError, "top-level on sequence contained a non-scalar event"
      end
      events.include?(expected)
    when Hash
      return false unless events.key?(expected)

      configuration = events[expected]
      configuration == "" || valid_event_configuration?(configuration, expected)
    when nil
      false
    else
      raise ParseError, "top-level on value had an unsupported shape"
    end
  end

  def valid_event_configuration?(configuration, _event)
    return false unless configuration.is_a?(Hash)

    # The fleet's default branch is main. An empty mapping is GitHub's
    # unfiltered spelling; the only filtered house form is the exact main
    # branch selector. Paths, ignored branches, tags, and event-type filters
    # can all create a green workflow that never evaluates a relevant change.
    configuration.empty? || configuration == { "branches" => ["main"] }
  end

  def schedule_crons(events)
    return [] unless events.is_a?(Hash) && events.key?("schedule")

    schedules = events["schedule"]
    raise ParseError, "on.schedule must be a sequence" unless schedules.is_a?(Array)

    schedules.map do |entry|
      raise ParseError, "on.schedule entry must be a mapping" unless entry.is_a?(Hash)
      raise ParseError, "on.schedule entry must contain only cron" unless entry.keys == ["cron"]
      cron = entry["cron"]
      raise ParseError, "on.schedule cron must be a scalar" unless cron.is_a?(String)

      validate_cron_expression(cron)
      cron
    end
  end

  def daily_crons(events)
    schedule_crons(events).select { |cron| cron_fields(cron)[2, 3] == ["*", "*", "*"] }
  end

  def cron_fields(cron)
    validate_cron_expression(cron)
  end

  def validate_cron_expression(cron)
    fields = cron.split
    raise ParseError, "cron must have five fields: #{cron.inspect}" unless fields.length == 5

    ranges = [[0, 59, "minute"], [0, 23, "hour"], [1, 31, "day of month"],
              [1, 12, "month"], [0, 6, "day of week"]]
    fields.each_with_index do |field, index|
      validate_cron_field(field, *ranges.fetch(index), cron)
    end
    fields
  end

  def validate_cron_field(value, minimum, maximum, label, cron)
    parts = value.split(",", -1)
    raise ParseError, "cron #{cron.inspect} has an empty #{label} item" if parts.empty? || parts.any?(&:empty?)

    parts.each do |part|
      base, step, extra = part.split("/", -1)
      raise ParseError, "cron #{cron.inspect} has malformed #{label} syntax" if extra || base.empty?
      if step
        unless step.match?(/\A[0-9]+\z/) && step.to_i.positive?
          raise ParseError, "cron #{cron.inspect} has an invalid #{label} step"
        end
      end

      next if base == "*"

      bounds = base.split("-", -1)
      unless bounds.length.between?(1, 2) && bounds.all? { |bound| bound.match?(/\A[0-9]+\z/) }
        raise ParseError, "cron #{cron.inspect} uses unsupported #{label} syntax"
      end
      numbers = bounds.map(&:to_i)
      unless numbers.all? { |number| number.between?(minimum, maximum) }
        raise ParseError, "cron #{cron.inspect} has #{label} outside #{minimum}..#{maximum}"
      end
      if numbers.length == 2 && numbers.first > numbers.last
        raise ParseError, "cron #{cron.inspect} has a descending #{label} range"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    parsed = ActionsYamlInspector.parse($stdin.read)
    case ARGV.fetch(0, "")
    when "pr-trigger"
      exit(ActionsYamlInspector.pull_request_trigger?(parsed) ? 0 : 1)
    when "uses"
      puts JSON.generate(ActionsYamlInspector.uses_entries(parsed))
    when "security"
      puts JSON.generate(ActionsYamlInspector.security_analysis(parsed))
    when "dependabot"
      puts JSON.generate(ActionsYamlInspector.dependabot_analysis(parsed))
    else
      warn "usage: #{File.basename(__FILE__)} {pr-trigger|uses|security|dependabot}"
      exit 2
    end
  rescue ActionsYamlInspector::ParseError, KeyError => e
    warn "YAML inspection failed: #{e.message}"
    exit 2
  end
end
