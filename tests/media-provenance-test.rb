# frozen_string_literal: true

# Tests for scripts/media_provenance.rb. Every container the scanner claims to
# cover gets a synthetic fixture that must be flagged, every near-miss must stay
# clean, and every way the fleet audit could report clean without reading the
# whole population must exit 2.

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "zlib"

require_relative "../scripts/media_provenance"

module Fixtures
  module_function

  def jumbf_c2pa
    label = "c2pa\x00".b
    jumd = [8 + 16 + 1 + label.bytesize].pack("N") + "jumd" + ("\x11".b * 16) + "\x03".b + label
    [8 + jumd.bytesize].pack("N") + "jumb" + jumd
  end

  def jpeg(segments = "".b)
    "\xFF\xD8".b + segments + "\xFF\xD9".b
  end

  def jpeg_segment(marker, payload)
    "\xFF".b + marker.chr.b + [payload.bytesize + 2].pack("n") + payload
  end

  def png_chunk(type, data)
    [data.bytesize].pack("N") + type.b + data.b + [Zlib.crc32(type + data)].pack("N")
  end

  def png(*chunks)
    MediaProvenance::PNG_SIGNATURE + png_chunk("IHDR", "\x00".b * 13) + chunks.join.b + png_chunk("IEND", "".b)
  end

  def xmp(value)
    "<x:xmpmeta><Iptc4xmpExt:DigitalSourceType>http://cv.iptc.org/newscodes/digitalsourcetype/#{value}" \
      "</Iptc4xmpExt:DigitalSourceType></x:xmpmeta>".b
  end

  def isobmff(*boxes)
    ftyp = [16].pack("N") + "ftypisom" + [0].pack("N")
    ftyp.b + boxes.join.b
  end

  def box(type, payload)
    [8 + payload.bytesize].pack("N") + type.b + payload.b
  end

  def riff_webp(*chunks)
    body = "WEBP".b + chunks.join.b
    "RIFF".b + [body.bytesize].pack("V") + body
  end

  def riff_chunk(id, data)
    data = data.b
    id.b + [data.bytesize].pack("V") + data + (data.bytesize.odd? ? "\x00".b : "".b)
  end
end

class MarkerTest < Minitest::Test
  include Fixtures

  def flags(data)
    MediaProvenance.markers(data)
  end

  def test_jpeg_app11_manifest_is_flagged
    assert_includes flags(jpeg(jpeg_segment(0xEB, "JP\x02\x11".b + jumbf_c2pa))), "c2pa"
  end

  def test_png_cabx_manifest_is_flagged
    assert_includes flags(png(png_chunk("caBX", jumbf_c2pa))), "c2pa"
  end

  def test_isobmff_uuid_manifest_is_flagged
    uuid = ["d8fec3d61b0e483c92975828877ec481"].pack("H*")
    assert_includes flags(isobmff(box("uuid", uuid + jumbf_c2pa), box("mdat", "x" * 64))), "c2pa"
  end

  def test_webp_c2pa_chunk_is_flagged
    assert_includes flags(riff_webp(riff_chunk("VP8L", "x" * 20), riff_chunk("C2PA", jumbf_c2pa))), "c2pa"
  end

  def test_svg_manifest_is_flagged
    svg = '<svg><metadata><c2pa:manifest>AAAA</c2pa:manifest></metadata></svg>'
    assert_includes flags(svg), "c2pa"
  end

  def test_remote_manifest_reference_is_flagged
    assert_includes flags(jpeg(jpeg_segment(0xE1, "http://ns.adobe.com/xap/1.0/\x00<dcterms:provenance>https://x/m</dcterms:provenance>".b))),
                    "c2pa-remote"
  end

  def test_every_ai_source_type_in_plain_xmp_is_flagged
    MediaProvenance::AI_SOURCE_TYPES.each do |value|
      assert_includes flags(jpeg(jpeg_segment(0xE1, xmp(value)))), "iptc-source:#{value}", value
    end
  end

  def test_source_type_inside_compressed_png_ztxt_is_flagged
    ztxt = "XML:com.adobe.xmp\x00\x00".b + Zlib::Deflate.deflate(xmp("trainedAlgorithmicMedia"))
    assert_includes flags(png(png_chunk("zTXt", ztxt))), "iptc-source:trainedAlgorithmicMedia"
  end

  def test_source_type_inside_compressed_png_itxt_is_flagged
    itxt = "XML:com.adobe.xmp\x00\x01\x00\x00\x00".b + Zlib::Deflate.deflate(xmp("compositeWithTrainedAlgorithmicMedia"))
    assert_includes flags(png(png_chunk("iTXt", itxt))), "iptc-source:compositeWithTrainedAlgorithmicMedia"
  end

  def test_non_ai_source_types_stay_clean
    %w[digitalCapture computationalCapture humanEdits screenCapture].each do |value|
      assert_empty flags(jpeg(jpeg_segment(0xE1, xmp(value)))), value
    end
  end

  def test_a_longer_word_sharing_a_prefix_stays_clean
    assert_empty flags(jpeg(jpeg_segment(0xE1, xmp("trainedAlgorithmicMediaSample"))))
  end

  def test_jumbf_without_a_c2pa_label_nearby_stays_clean
    far = "jumd".b + ("\x00".b * 60) + "c2pa".b
    assert_empty flags(jpeg(jpeg_segment(0xEB, "JP".b + far)))
  end

  def test_plain_media_stays_clean
    assert_empty flags(png(png_chunk("IDAT", Zlib::Deflate.deflate("\x00" * 100))))
    assert_empty flags(jpeg(jpeg_segment(0xE0, "JFIF\x00\x01\x01".b)))
    assert_empty flags(isobmff(box("moov", "x" * 32), box("mdat", "y" * 32)))
  end
end

class CheckTest < Minitest::Test
  include Fixtures

  def run_check(paths)
    out = StringIO.new
    err = StringIO.new
    [MediaProvenance.check(paths, out: out, err: err), out.string + err.string]
  end

  def test_no_file_examined_nothing_and_exits_2
    code, text = run_check([])
    assert_equal 2, code
    assert_match(/examined nothing/, text)
  end

  def test_an_unreadable_path_exits_2
    assert_equal 2, run_check(["/nonexistent/x.png"]).first
  end

  def test_clean_and_flagged_files
    Dir.mktmpdir do |dir|
      clean = File.join(dir, "clean.png")
      dirty = File.join(dir, "dirty.png")
      File.binwrite(clean, png)
      File.binwrite(dirty, png(png_chunk("caBX", jumbf_c2pa)))
      assert_equal 0, run_check([clean]).first
      code, text = run_check([clean, dirty])
      assert_equal 1, code
      assert_match(/2 media file\(s\) examined; 1 carry/, text)
    end
  end
end

# The audit is run as a real process against a fake gh on PATH, so the test
# proves the exit status CI and the checker actually see.
class AuditTest < Minitest::Test
  include Fixtures

  SCRIPT = File.expand_path("../scripts/media_provenance.rb", __dir__)
  COMMIT = "a" * 40

  FAKE_GH = <<~'RUBY'
    #!/usr/bin/env ruby
    require "json"
    routes = JSON.parse(File.read(ENV.fetch("FAKE_GH_ROUTES")))
    endpoint = ARGV.last
    route = routes[endpoint]
    unless route
      $stdout.write("HTTP/2.0 404 Not Found\r\n\r\n{}")
      exit 1
    end
    $stdout.binmode
    $stdout.write("HTTP/2.0 #{route["status"]} X\r\ncontent-type: x\r\n\r\n")
    $stdout.write(File.binread(route["file"]))
    exit(route["status"].to_s.start_with?("2") ? 0 : 1)
  RUBY

  def setup
    @dir = Dir.mktmpdir
    @bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, "gh"), FAKE_GH)
    File.chmod(0o755, File.join(@bin, "gh"))
    @routes = {}
    @tree = []
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def blob(path, data, served: data)
    sha = MediaProvenance.git_blob_sha(data)
    file = File.join(@dir, sha)
    File.binwrite(file, served)
    @routes["repos/windwardline/site/git/blobs/#{sha}"] = { "status" => 200, "file" => file }
    @tree << { "path" => path, "type" => "blob", "sha" => sha }
  end

  def run_audit(tree_status: 200, truncated: false, manifest: "site\t#{COMMIT}\n", count: "1")
    tree_file = File.join(@dir, "tree.json")
    File.write(tree_file, JSON.generate("tree" => @tree + [{ "path" => "README.md", "type" => "blob", "sha" => "b" * 40 }],
                                        "truncated" => truncated))
    @routes["repos/windwardline/site/git/trees/#{COMMIT}?recursive=1"] = { "status" => tree_status, "file" => tree_file }
    routes_file = File.join(@dir, "routes.json")
    File.write(routes_file, JSON.generate(@routes))
    env = { "PATH" => "#{@bin}:#{ENV["PATH"]}", "FAKE_GH_ROUTES" => routes_file }
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec -- fixed argv, no shell; the subject under test.
    out, status = Open3.capture2e(env, "ruby", SCRIPT, "audit", "--snapshot-manifest", "-", count, stdin_data: manifest)
    [status.exitstatus, out.force_encoding(Encoding::UTF_8)]
  end

  def test_the_runner_started
    code, out = run_audit
    refute_nil code
    refute_match(/cannot load|LoadError|command not found/, out)
  end

  def test_clean_population_passes_and_names_its_count
    blob("img/a.png", png)
    blob("img/b.jpg", jpeg)
    code, out = run_audit
    assert_equal 0, code, out
    assert_match(/2 media blob\(s\) across 1 repo\(s\)/, out)
  end

  def test_a_marked_blob_is_drift
    blob("img/a.png", png)
    blob("img/og.png", png(png_chunk("caBX", jumbf_c2pa)))
    code, out = run_audit
    assert_equal 1, code, out
    assert_match(%r{site\s+img/og\.png: c2pa}, out)
  end

  def test_zero_media_refuses_a_vacuous_pass
    code, out = run_audit
    assert_equal 2, code
    assert_match(/no media blob/, out)
  end

  def test_a_refused_tree_read_is_incomplete
    blob("img/a.png", png)
    code, out = run_audit(tree_status: 403)
    assert_equal 2, code
    assert_match(/HTTP 403/, out)
  end

  def test_a_truncated_tree_is_incomplete
    blob("img/a.png", png)
    code, out = run_audit(truncated: true)
    assert_equal 2, code
    assert_match(/truncated/, out)
  end

  def test_bytes_that_do_not_hash_to_the_blob_are_incomplete
    blob("img/a.png", png(png_chunk("caBX", jumbf_c2pa)), served: png)
    code, out = run_audit
    assert_equal 2, code
    assert_match(/not the bytes committed/, out)
  end

  def test_a_missing_blob_is_incomplete_not_clean
    blob("img/a.png", png)
    @routes.delete_if { |k, _| k.include?("/git/blobs/") }
    code, out = run_audit
    assert_equal 2, code, out
  end

  def test_a_tree_naming_a_malformed_blob_sha_is_incomplete
    @tree << { "path" => "img/x.png", "type" => "blob", "sha" => "../../evil" }
    code, out = run_audit
    assert_equal 2, code
    assert_match(/malformed blob SHA/, out)
  end

  def test_a_manifest_that_disagrees_with_its_count_is_incomplete
    blob("img/a.png", png)
    assert_equal 2, run_audit(count: "2").first
    assert_equal 2, run_audit(manifest: "site\tnot-a-sha\n").first
  end
end
