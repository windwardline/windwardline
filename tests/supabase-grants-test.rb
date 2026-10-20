# frozen_string_literal: true

# Tests for scripts/supabase_grants.rb. Each rule gets a fixture that must be
# flagged and a near miss that must stay clean, and the fleet audit is driven
# through a stub gh so a truncated tree or a refused read exits 2, never 0.

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"

Encoding.default_external = Encoding::UTF_8

require_relative "../scripts/supabase_grants"

class SupabaseGrantsTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/supabase_grants.rb", __dir__)
  CREATE = "create table public.widgets (id bigint primary key);\n"
  DECIDED = "revoke all on public.widgets from anon;\n" \
            "grant select on public.widgets to authenticated;\n" \
            "grant select, insert, update, delete on public.widgets to service_role;\n"

  def findings(sql)
    SupabaseGrants.findings(sql)
  end

  def test_a_table_with_no_grants_leaves_every_role_undecided
    assert_equal [["widgets", %w[anon authenticated service_role]]], findings(CREATE)
  end

  def test_one_role_left_to_the_default_is_named_alone
    sql = CREATE + DECIDED.lines.reject { |l| l.include?("anon") }.join
    assert_equal [["widgets", %w[anon]]], findings(sql)
  end

  def test_grants_and_revokes_both_count_as_a_decision
    assert_empty findings(CREATE + DECIDED)
  end

  def test_quoted_names_if_not_exists_unqualified_and_multi_role
    sql = "create table if not exists \"gadgets\" (id bigint);\n" \
          "grant select on table \"public\".\"gadgets\" to anon, authenticated;\n" \
          "grant all on gadgets to service_role;\n"
    assert_empty findings(sql)
  end

  def test_a_grant_on_another_table_does_not_count
    refute_empty findings(CREATE + DECIDED.gsub("public.widgets", "public.other"))
  end

  def test_a_prefix_named_table_does_not_count
    refute_empty findings(CREATE + DECIDED.gsub("public.widgets", "public.widgets_archive"))
  end

  def test_a_commented_out_grant_does_not_count
    sql = CREATE + DECIDED.sub("revoke all on public.widgets from anon;", "-- revoke all on public.widgets from anon;")
    assert_equal [["widgets", %w[anon]]], findings(sql)
  end

  def test_other_schemas_are_out_of_scope
    assert_empty findings("create table private.audit (id bigint);\n")
  end

  def test_scope_starts_at_the_cutoff
    assert SupabaseGrants.in_scope?("supabase/migrations/20261020000000_x.sql")
    refute SupabaseGrants.in_scope?("supabase/migrations/20261019235959_x.sql")
    assert SupabaseGrants.in_scope?("apps/api/supabase/migrations/20261101000000_x.sql")
    refute SupabaseGrants.in_scope?("docs/supabase/migrations-20261101000000_x.sql")
  end

  def test_check_mode_exit_codes
    Dir.mktmpdir do |dir|
      dir = File.join(dir, "supabase", "migrations")
      FileUtils.mkdir_p(dir)
      bad = File.join(dir, "20261021000000_widgets.sql")
      File.write(bad, CREATE)
      old = File.join(dir, "20260901000000_widgets.sql")
      File.write(old, CREATE)
      _out, _err, status = Open3.capture3("ruby", SCRIPT, "check", bad, old)
      assert_equal 1, status.exitstatus
      _out, _err, status = Open3.capture3("ruby", SCRIPT, "check", old)
      assert_equal 0, status.exitstatus
    end
  end

  # --- audit through a stub gh --------------------------------------------

  FAKE_SHA = "a" * 40

  def blob_sha(data)
    # nosemgrep: ruby.lang.security.weak-hashes-sha1.weak-hashes-sha1 -- git names blobs by SHA-1; the fixture must hash the way git does.
    Digest::SHA1.hexdigest("blob #{data.bytesize}\0#{data}")
  end

  def with_stub_gh(tree:, blobs:, refuse: false)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "tree.json"), JSON.generate(tree))
      blobs.each { |sha, data| File.write(File.join(dir, sha), data) }
      gh = File.join(dir, "gh")
      File.write(gh, <<~SH)
        #!/bin/bash
        endpoint="${@: -1}"
        #{refuse ? 'printf "HTTP/2.0 403 Forbidden\\r\\n\\r\\n{}"; exit 1' : ""}
        case "$endpoint" in
          */git/trees/*) printf 'HTTP/2.0 200 OK\\r\\n\\r\\n'; cat "#{dir}/tree.json" ;;
          */git/blobs/*) printf 'HTTP/2.0 200 OK\\r\\n\\r\\n'; cat "#{dir}/${endpoint##*/}" ;;
          *) exit 97 ;;
        esac
      SH
      File.chmod(0o755, gh)
      env = { "PATH" => "#{dir}:#{ENV.fetch("PATH")}" }
      yield Open3.capture3(env, "ruby", SCRIPT, "audit", "--snapshot-manifest", "-", "1", stdin_data: "fixture\t#{FAKE_SHA}\n")
    end
  end

  def tree_with(path, data)
    { "tree" => [{ "type" => "blob", "path" => path, "sha" => blob_sha(data) }], "truncated" => false }
  end

  def test_audit_flags_an_undecided_table_in_a_repo
    data = CREATE
    with_stub_gh(tree: tree_with("supabase/migrations/20261021000000_w.sql", data), blobs: { blob_sha(data) => data }) do |out, _err, status|
      assert_equal 1, status.exitstatus, out
      assert_match(/fixture .*public\.widgets has no GRANT or REVOKE for anon, authenticated, service_role/, out)
    end
  end

  def test_audit_passes_a_decided_table_and_reports_what_it_read
    data = CREATE + DECIDED
    with_stub_gh(tree: tree_with("supabase/migrations/20261021000000_w.sql", data), blobs: { blob_sha(data) => data }) do |out, _err, status|
      assert_equal 0, status.exitstatus, out
      assert_match(/1 migration\(s\) across 1 Supabase repo\(s\) of 1; 1 dated on or after 20261020 and judged/, out)
    end
  end

  def test_audit_refuses_a_truncated_tree
    tree = tree_with("supabase/migrations/20261021000000_w.sql", CREATE).merge("truncated" => true)
    with_stub_gh(tree: tree, blobs: {}) do |_out, err, status|
      assert_equal 2, status.exitstatus
      assert_match(/truncated/, err)
    end
  end

  def test_audit_refuses_bytes_that_do_not_hash_back
    path = "supabase/migrations/20261021000000_w.sql"
    tree = tree_with(path, CREATE + DECIDED)
    with_stub_gh(tree: tree, blobs: { blob_sha(CREATE + DECIDED) => CREATE }) do |_out, err, status|
      assert_equal 2, status.exitstatus
      assert_match(/not the bytes committed/, err)
    end
  end

  def test_audit_refuses_a_refused_read
    with_stub_gh(tree: { "tree" => [] }, blobs: {}, refuse: true) do |_out, err, status|
      assert_equal 2, status.exitstatus
      assert_match(/refused \(HTTP 403\)/, err)
    end
  end
end
