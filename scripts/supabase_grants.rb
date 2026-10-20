# frozen_string_literal: true

# Supabase migrations decide every API role for each new public table
# (FLEET.md "Supabase tables carry explicit grants").
#
# From 2026-10-30 Supabase stops granting Data API access to new tables in the
# "public" schema, and that covers every schema rebuilt from migrations:
# preview branches, a new project, `supabase db reset`. A table created without
# grants answers "permission denied" to supabase-js; a table created with the
# grants Supabase's notice suggests hands `anon` select. Neither is a decision.
# So a migration dated on or after 2026-10-20 (the notice) that creates a table
# in public must name that table in a GRANT or a REVOKE for each of anon,
# authenticated and service_role, in the same file.
#
#   supabase_grants.rb check FILE...                       local files
#   supabase_grants.rb audit --snapshot-manifest FILE N    every repo, at the
#                                                          checker's snapshot
#
# Exit 0 conformant, 1 a migration leaves a role undecided, 2 incomplete.

require "digest"
require "json"
require "open3"

# Scheduled runs start with LANG unset, and Ruby then reads every external
# string as US-ASCII; the report and its inputs are UTF-8.
Encoding.default_external = Encoding::UTF_8

module SupabaseGrants
  class Incomplete < StandardError; end

  OWNER = "windwardline"
  CUTOFF = "20261020000000"
  ROLES = %w[anon authenticated service_role].freeze
  MIGRATION_PATH = %r{(?:\A|/)supabase/migrations/(\d{14})_[a-z0-9_]+\.sql\z}
  # Literal patterns only: identifiers are captured and compared as strings,
  # never interpolated into a Regexp. Line comments are stripped first, so a
  # GRANT that was commented out is not a decision.
  CREATE = /\bcreate\s+(?:unlogged\s+)?table\s+(?:if\s+not\s+exists\s+)?(?:(?:"([a-z0-9_]+)"|([a-z0-9_]+))\s*\.\s*)?(?:"([a-z0-9_]+)"|([a-z0-9_]+))/i.freeze
  TARGET = /\bon\s+(?:table\s+)?(?:(?:"([a-z0-9_]+)"|([a-z0-9_]+))\s*\.\s*)?(?:"([a-z0-9_]+)"|([a-z0-9_]+))(?![a-z0-9_])/i.freeze
  GRANTEES = /\b(?:to|from)\s+([^;]*)\z/i.freeze

  module_function

  def in_scope?(path)
    m = path.match(MIGRATION_PATH)
    m && m[1] >= CUTOFF
  end

  def without_comments(sql)
    sql.gsub(/--[^\n]*/, "")
  end

  def public_tables(sql)
    without_comments(sql).scan(CREATE).map do |s1, s2, t1, t2|
      schema = (s1 || s2 || "public").downcase
      (t1 || t2).downcase if schema == "public"
    end.compact
  end

  def decides?(sql, table, role)
    without_comments(sql).split(";").any? do |statement|
      next false unless statement.match?(/\A\s*(?:grant|revoke)\b/i)

      target = statement.match(TARGET)
      next false unless target && (target[1] || target[2] || "public").downcase == "public"
      next false unless (target[3] || target[4]).downcase == table

      grantees = statement.match(GRANTEES)
      grantees && grantees[1].downcase.split(/[\s,"]+/).include?(role)
    end
  end

  # [[table, [undecided roles]], ...] for one migration's text.
  def findings(sql)
    public_tables(sql).map do |table|
      missing = ROLES.reject { |role| decides?(sql, table, role) }
      [table, missing] unless missing.empty?
    end.compact
  end

  def check(paths, out: $stdout)
    flagged = 0
    paths.each do |path|
      next unless in_scope?(path)

      findings(File.read(path)).each do |table, missing|
        flagged += 1
        out.puts "#{path}: public.#{table} has no GRANT or REVOKE for #{missing.join(", ")}"
      end
    end
    flagged.zero? ? 0 : 1
  end

  # --- audit -----------------------------------------------------------------

  def gh_get(endpoint, accept: nil)
    args = ["gh", "api", "--include"]
    args += ["-H", "Accept: #{accept}"] if accept
    args << endpoint
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec -- argv array, no shell; every endpoint part is validated (repo name, 40-hex SHAs).
    raw, _err, status = Open3.capture3(*args, binmode: true)
    raw = raw.b
    head, sep, body = raw.partition("\r\n\r\n".b)
    head, sep, body = raw.partition("\n\n".b) if sep.empty?
    code = head[%r{\AHTTP/\S+ (\d{3})}n, 1]
    raise Incomplete, "#{endpoint} returned no parseable HTTP status (gh rc=#{status.exitstatus})" unless code
    raise Incomplete, "#{endpoint} was refused (HTTP #{code})" unless code.start_with?("2")
    raise Incomplete, "#{endpoint} returned HTTP #{code} but gh exited #{status.exitstatus}" unless status.success?

    body
  end

  def migrations(repo, sha)
    tree = JSON.parse(gh_get("repos/#{OWNER}/#{repo}/git/trees/#{sha}?recursive=1").dup.force_encoding(Encoding::UTF_8))
    raise Incomplete, "#{repo} tree at #{sha} had an unexpected shape" unless tree.is_a?(Hash) && tree["tree"].is_a?(Array)
    raise Incomplete, "#{repo} tree at #{sha} was truncated; its migrations are incomplete" if tree["truncated"]

    found = tree["tree"].select { |e| e["type"] == "blob" && e["path"].to_s.match?(MIGRATION_PATH) }
                        .map { |e| [e["path"], e["sha"]] }
    bad = found.find { |_, blob| !blob.to_s.match?(/\A[0-9a-f]{40}\z/) }
    raise Incomplete, "#{repo} tree at #{sha} named #{bad[0]} with a malformed blob SHA" if bad

    found
  rescue JSON::ParserError
    raise Incomplete, "#{repo} tree at #{sha} was malformed JSON"
  end

  def fetch_blob(repo, blob_sha)
    data = gh_get("repos/#{OWNER}/#{repo}/git/blobs/#{blob_sha}", accept: "application/vnd.github.raw+json")
    # nosemgrep: ruby.lang.security.weak-hashes-sha1.weak-hashes-sha1 -- git names blobs by SHA-1; this is an integrity match against that name, not a security hash.
    got = Digest::SHA1.hexdigest("blob #{data.bytesize}\0".b + data)
    raise Incomplete, "#{repo} blob #{blob_sha} arrived as #{got}; the bytes read are not the bytes committed" unless got == blob_sha

    data.dup.force_encoding(Encoding::UTF_8)
  end

  def read_manifest(source, expected)
    text = source == "-" ? $stdin.read : File.read(source)
    rows = text.lines.map(&:strip).reject(&:empty?).map { |l| l.split("\t") }
    unless rows.all? { |r| r.size == 2 && r[0].match?(/\A[A-Za-z0-9._-]+\z/) && r[1].match?(/\A[0-9a-f]{40}\z/) }
      raise Incomplete, "snapshot manifest rows must be repo<TAB>40-hex commit"
    end
    raise Incomplete, "snapshot manifest is empty" if rows.empty?
    raise Incomplete, "snapshot manifest holds #{rows.size} rows; expected #{expected}" unless rows.size == expected

    rows
  end

  def audit(rows, out: $stdout)
    total = 0
    scoped = 0
    supabase_repos = 0
    lines = []
    rows.each do |repo, sha|
      found = migrations(repo, sha)
      supabase_repos += 1 unless found.empty?
      total += found.size
      found.select { |path, _| in_scope?(path) }.each do |path, blob|
        scoped += 1
        findings(fetch_blob(repo, blob)).each do |table, missing|
          lines << format("%-22s %s", repo, "#{path}: public.#{table} has no GRANT or REVOKE for #{missing.join(", ")}")
        end
      end
    end
    out.puts format("%-22s %s", "REPO", "SUPABASE TABLES WITHOUT EXPLICIT GRANTS (empty = conformant)")
    lines.each { |l| out.puts l }
    summary = "#{total} migration(s) across #{supabase_repos} Supabase repo(s) of #{rows.size}; " \
              "#{scoped} dated on or after #{CUTOFF[0, 8]} and judged"
    if lines.empty?
      out.puts "Supabase grants conformant — #{summary}."
      0
    else
      out.puts "Supabase grants: #{lines.size} table(s) leave an API role undecided — #{summary}."
      1
    end
  end

  def main(argv)
    case argv[0]
    when "check"
      return usage if argv.size < 2

      check(argv[1..])
    when "audit"
      return usage unless argv[1] == "--snapshot-manifest" && argv.size == 4 && argv[3].match?(/\A[1-9][0-9]*\z/)

      audit(read_manifest(argv[2], argv[3].to_i))
    else
      usage
    end
  rescue Incomplete => e
    warn "ERROR: SUPABASE GRANTS AUDIT INCOMPLETE — #{e.message}"
    2
  end

  def usage
    warn "usage: supabase_grants.rb check FILE... | audit --snapshot-manifest FILE COUNT"
    2
  end
end

exit(SupabaseGrants.main(ARGV)) if $PROGRAM_NAME == __FILE__
