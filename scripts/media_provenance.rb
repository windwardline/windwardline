# frozen_string_literal: true

# Published-media provenance scanner and fleet auditor — FLEET.md "Published
# media carries no embedded AI indicator".
#
# Media the owner publishes carries no embedded marker of AI involvement; the
# owner discloses through each platform's own labeling tool wherever that
# platform's rules require it. scripts/strip-ai-provenance.sh removes the
# markers; this file detects what is left.
#
# What it detects, and why each is exact rather than guessed:
#   c2pa            A C2PA manifest store. Every embedding (JPEG APP11, PNG caBX,
#                   RIFF C2PA chunk, ISOBMFF uuid box) wraps a JUMBF superbox
#                   whose description box `jumd` carries the label `c2pa` within
#                   a few bytes; SVG embeds `<c2pa:manifest>`.
#   c2pa-remote     An XMP `dcterms:provenance` reference to a remote manifest.
#   iptc-source     An IPTC digitalSourceType value from IPTC's own closed
#                   vocabulary for algorithmic or AI media. Compressed PNG text
#                   chunks are inflated before the search.
# What it does not detect: EXIF or XMP fields that merely name a generative
# tool (any list of names is only as complete as its last spelling; the strip
# step removes all such fields instead), and invisible pixel watermarks, which
# FLEET.md leaves alone by rule.
#
# Usage:
#   ruby media_provenance.rb check FILE...
#   ruby media_provenance.rb extensions      the media population, one line
#   ruby media_provenance.rb audit --snapshot-manifest FILE COUNT
#                     audit every media blob at the exact repo<TAB>commit rows
#                     the conformance checker captured ("-" reads stdin)
# Exit: 0 clean, 1 marker found, 2 the scan could not be completed or examined
# nothing. A scan that examined no file never reports clean.

require "digest"
require "json"
require "open3"
require "zlib"

# A scheduled run has LANG unset, which makes Ruby's default external encoding
# US-ASCII; a non-ASCII path in a tree or the manifest would then abort the
# audit as though the fleet had failed. Pin it, as fleet-conformance.sh does.
Encoding.default_external = Encoding::UTF_8

module MediaProvenance
  class Incomplete < StandardError; end

  OWNER = "windwardline"
  MEDIA_EXTENSIONS = %w[
    png jpg jpeg webp gif avif heic heif tif tiff svg
    mp4 mov m4v webm mp3 m4a wav aac ogg flac
  ].freeze
  MEDIA_PATH = /\.(?:#{MEDIA_EXTENSIONS.join("|")})\z/i.freeze
  JUMBF_C2PA = /jumd.{0,40}?c2pa/mn.freeze
  SVG_MANIFEST = /<c2pa:manifest\b/in.freeze
  REMOTE_MANIFEST = /dcterms:provenance/in.freeze
  # https://cv.iptc.org/newscodes/digitalsourcetype/ — the values describing
  # media made or materially altered by an algorithm or trained model.
  AI_SOURCE_TYPES = %w[
    trainedAlgorithmicMedia compositeWithTrainedAlgorithmicMedia
    algorithmicMedia compositeSynthetic algorithmicallyEnhanced
  ].freeze
  SOURCE_TYPE = /digitalsourcetype\/(#{AI_SOURCE_TYPES.join("|")})(?![A-Za-z])/in.freeze
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
  WORKERS = 8

  module_function

  # Returns the marker names found in one file's bytes; empty means clean.
  def markers(data)
    data = data.b
    found = []
    found << "c2pa" if data.match?(JUMBF_C2PA) || data.match?(SVG_MANIFEST)
    texts = [data] + png_inflated_texts(data)
    found << "c2pa-remote" if texts.any? { |t| t.match?(REMOTE_MANIFEST) }
    source = texts.map { |t| t[SOURCE_TYPE, 1] }.compact.first
    found << "iptc-source:#{source}" if source
    found
  end

  # PNG zTXt chunks, and iTXt chunks with the compression flag set, hold
  # deflated text; XMP carrying a digitalSourceType can sit inside either.
  def png_inflated_texts(data)
    return [] unless data.start_with?(PNG_SIGNATURE)

    texts = []
    pos = PNG_SIGNATURE.bytesize
    while pos + 8 <= data.bytesize
      length = data[pos, 4].unpack1("N")
      type = data[pos + 4, 4]
      body = data[pos + 8, length] || "".b
      break if body.bytesize < length

      begin
        case type
        when "zTXt"
          sep = body.index("\x00".b)
          texts << Zlib::Inflate.inflate(body[(sep + 2)..-1]) if sep
        when "iTXt"
          sep = body.index("\x00".b)
          if sep && body.getbyte(sep + 1) == 1
            rest = body[(sep + 3)..-1]
            2.times { rest = rest[(rest.index("\x00".b) + 1)..-1] }
            texts << Zlib::Inflate.inflate(rest)
          end
        end
      rescue Zlib::Error, NoMethodError, TypeError
        texts << "digitalsourcetype/unreadable-compressed-text".b if body.match?(/digitalsourcetype/in)
      end
      break if type == "IEND"

      pos += 12 + length
    end
    texts.map(&:b)
  end

  def git_blob_sha(data)
    # nosemgrep: ruby.lang.security.weak-hashes-sha1.weak-hashes-sha1 -- git names blobs by SHA-1; this is an integrity match against that name, not a security hash.
    Digest::SHA1.hexdigest("blob #{data.bytesize}\0".b + data.b)
  end

  # --- check -----------------------------------------------------------------

  def check(paths, out: $stdout, err: $stderr)
    if paths.empty?
      err.puts "ERROR: no file given; a scan that examined nothing is not clean."
      return 2
    end
    flagged = 0
    paths.each do |path|
      unless File.file?(path) && File.readable?(path)
        err.puts "ERROR: #{path} is not a readable regular file."
        return 2
      end
      found = markers(File.binread(path))
      next if found.empty?

      flagged += 1
      out.puts "#{path}: #{found.join(" ")}"
    end
    out.puts "#{paths.size} media file(s) examined; #{flagged} carry an embedded AI indicator."
    flagged.zero? ? 0 : 1
  end

  # --- audit -----------------------------------------------------------------

  # gh is the only GitHub client, so every read keeps its HTTP status. Anything
  # but a 2xx, a status that cannot be parsed, or bytes that do not hash back to
  # the requested blob aborts the audit: none of those is a clean file.
  def gh_get(endpoint, accept: nil)
    args = ["gh", "api", "--include"]
    args += ["-H", "Accept: #{accept}"] if accept
    args << endpoint
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec -- argv array, no shell; every endpoint part is validated (repo name, 40-hex SHAs).
    raw, _err, status = Open3.capture3(*args, binmode: true)
    raw = raw.b
    head, sep, body = raw.partition("\r\n\r\n".b)
    head, sep, body = raw.partition("\n\n".b) if sep.empty?
    code = head[/\AHTTP\/\S+ (\d{3})/n, 1]
    raise Incomplete, "#{endpoint} returned no parseable HTTP status (gh rc=#{status.exitstatus})" unless code
    raise Incomplete, "#{endpoint} was refused (HTTP #{code})" unless code.start_with?("2")
    raise Incomplete, "#{endpoint} returned HTTP #{code} but gh exited #{status.exitstatus}" unless status.success?

    body
  end

  def media_blobs(repo, sha)
    body = gh_get("repos/#{OWNER}/#{repo}/git/trees/#{sha}?recursive=1")
    tree = JSON.parse(body.dup.force_encoding(Encoding::UTF_8))
    raise Incomplete, "#{repo} tree at #{sha} had an unexpected shape" unless tree.is_a?(Hash) && tree["tree"].is_a?(Array)
    raise Incomplete, "#{repo} tree at #{sha} was truncated; the media population is incomplete" if tree["truncated"]

    blobs = tree["tree"].select { |e| e["type"] == "blob" && e["path"].to_s.match?(MEDIA_PATH) }
                        .map { |e| [e["path"], e["sha"]] }
    bad = blobs.find { |_, blob| !blob.to_s.match?(/\A[0-9a-f]{40}\z/) }
    raise Incomplete, "#{repo} tree at #{sha} named #{bad[0]} with a malformed blob SHA" if bad

    blobs
  rescue JSON::ParserError
    raise Incomplete, "#{repo} tree at #{sha} was malformed JSON"
  end

  def fetch_blob(repo, blob_sha)
    data = gh_get("repos/#{OWNER}/#{repo}/git/blobs/#{blob_sha}", accept: "application/vnd.github.raw+json")
    got = git_blob_sha(data)
    raise Incomplete, "#{repo} blob #{blob_sha} arrived as #{got}; the bytes read are not the bytes committed" unless got == blob_sha

    data
  end

  def read_manifest(source, expected)
    text = source == "-" ? $stdin.read : File.read(source)
    rows = text.lines.map(&:strip).reject(&:empty?).map { |l| l.split("\t") }
    unless rows.all? { |r| r.size == 2 && r[0].match?(/\A[A-Za-z0-9._-]+\z/) && r[1].match?(/\A[0-9a-f]{40}\z/) }
      raise Incomplete, "snapshot manifest rows must be repo<TAB>40-hex commit"
    end
    raise Incomplete, "snapshot manifest holds #{rows.size} rows; expected #{expected}" unless rows.size == expected
    raise Incomplete, "snapshot manifest is empty" if rows.empty?

    rows
  end

  def audit(rows, out: $stdout)
    jobs = rows.flat_map { |repo, sha| media_blobs(repo, sha).map { |path, blob| [repo, path, blob] } }
    queue = Queue.new
    jobs.each { |j| queue << j }
    results = []
    lock = Mutex.new
    errors = []
    threads = Array.new([WORKERS, jobs.size].min) do
      Thread.new do
        loop do
          job = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          begin
            found = markers(fetch_blob(job[0], job[2]))
            lock.synchronize { results << [job, found] }
          rescue Incomplete => e
            lock.synchronize { errors << e.message }
          end
        end
      end
    end
    threads.each(&:join)
    raise Incomplete, errors.first unless errors.empty?
    raise Incomplete, "examined #{results.size} of #{jobs.size} media blobs" unless results.size == jobs.size
    raise Incomplete, "the fleet holds no media blob; refusing a vacuous pass" if jobs.empty?

    flagged = results.reject { |_, found| found.empty? }.sort_by { |(job, _)| [job[0], job[1]] }
    per_repo = Hash.new(0)
    results.each { |(job, _)| per_repo[job[0]] += 1 }
    out.puts format("%-22s %s", "REPO", "MEDIA WITH EMBEDDED AI INDICATORS (empty = conformant)")
    rows.each do |repo, _|
      hits = flagged.select { |(job, _)| job[0] == repo }
      if hits.empty?
        out.puts format("%-22s %s", repo, "✓ (#{per_repo[repo]} media file#{per_repo[repo] == 1 ? "" : "s"})")
      else
        hits.each { |(job, found)| out.puts format("%-22s %s: %s", repo, job[1], found.join(" ")) }
      end
    end
    if flagged.empty?
      out.puts "Published media conformant — #{results.size} media blob(s) across #{rows.size} repo(s), none carrying an embedded AI indicator."
      0
    else
      out.puts "Published media: #{flagged.size} of #{results.size} media blob(s) carry an embedded AI indicator."
      1
    end
  end

  def main(argv)
    case argv[0]
    when "extensions"
      puts MEDIA_EXTENSIONS.join(" ")
      0
    when "check"
      check(argv[1..-1])
    when "audit"
      unless argv[1] == "--snapshot-manifest" && argv.size == 4 && argv[3].match?(/\A[1-9][0-9]*\z/)
        warn "usage: media_provenance.rb audit --snapshot-manifest FILE COUNT"
        return 2
      end
      audit(read_manifest(argv[2], argv[3].to_i))
    else
      warn "usage: media_provenance.rb check FILE... | audit --snapshot-manifest FILE COUNT"
      2
    end
  rescue Incomplete => e
    warn "ERROR: PUBLISHED MEDIA AUDIT INCOMPLETE — #{e.message}"
    2
  end
end

exit(MediaProvenance.main(ARGV)) if $PROGRAM_NAME == __FILE__
