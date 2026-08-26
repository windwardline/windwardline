# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

module GitHubAppKeyVerifier
  class InputError < StandardError; end
  class NetworkError < StandardError; end
  class IdentityError < StandardError; end

  EXPECTED_APP_ID = 4_562_963
  EXPECTED_SLUG = "windward-line-automerge"
  EXPECTED_OWNER = "windwardline"
  EXPECTED_OWNER_ID = 267_140_241
  EXPECTED_ACCOUNT_TYPE = "User"
  API_URI = URI("https://api.github.com/app").freeze
  INSTALLATION_URI = URI(
    "https://api.github.com/users/#{EXPECTED_OWNER}/installation"
  ).freeze
  API_VERSION = "2022-11-28"
  USER_AGENT = "windwardline-github-app-key-verifier"
  MAX_INPUT_BYTES = 32 * 1024
  MAX_RESPONSE_BYTES = 128 * 1024
  JWT_BACKDATE_SECONDS = 30
  JWT_LIFETIME_SECONDS = 540
  BASE64_PATTERN = /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/

  raise "EXPECTED_APP_ID must be positive" unless EXPECTED_APP_ID.positive?

  module_function

  def decode_private_key(encoded_input)
    key, decoded = decode_private_key_material(encoded_input)
    key
  ensure
    decoded&.clear
  end

  def decode_private_key_material(encoded_input)
    raise InputError unless encoded_input.is_a?(String)
    raise InputError if encoded_input.empty? || encoded_input.bytesize > MAX_INPUT_BYTES

    encoded = String.new(encoded_input, encoding: Encoding::BINARY)
    payload = strip_one_terminal_line_ending(encoded)
    raise InputError if payload.empty? || !BASE64_PATTERN.match?(payload)

    decoded = Base64.strict_decode64(payload)
    canonical = Base64.strict_encode64(decoded)
    raise InputError unless canonical == payload

    # An explicit empty passphrase prevents OpenSSL from prompting on encrypted
    # material. GitHub App keys are unencrypted; encrypted input is rejected.
    key = OpenSSL::PKey.read(decoded, "")
    raise InputError unless key.is_a?(OpenSSL::PKey::RSA) && key.private?

    accepted = true
    [key, decoded]
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    raise InputError
  ensure
    encoded&.clear
    payload&.clear
    decoded&.clear unless accepted
    canonical&.clear
  end
  private_class_method :decode_private_key_material

  def build_jwt(private_key, now: Time.now)
    unless private_key.is_a?(OpenSSL::PKey::RSA) && private_key.private?
      raise InputError
    end

    timestamp = Integer(now.to_i)
    raise InputError unless timestamp.positive?

    header_json = JSON.generate("alg" => "RS256", "typ" => "JWT")
    payload_json = JSON.generate(
      "iat" => timestamp - JWT_BACKDATE_SECONDS,
      "exp" => timestamp + JWT_LIFETIME_SECONDS,
      "iss" => EXPECTED_APP_ID
    )
    header_segment = urlsafe_encode(header_json)
    payload_segment = urlsafe_encode(payload_json)
    signing_input = +"#{header_segment}.#{payload_segment}"
    signature = private_key.sign(OpenSSL::Digest::SHA256.new, signing_input)
    signature_segment = urlsafe_encode(signature)

    +"#{signing_input}.#{signature_segment}"
  ensure
    header_json&.clear
    payload_json&.clear
    header_segment&.clear
    payload_segment&.clear
    signing_input&.clear
    signature&.clear
    signature_segment&.clear
  end

  def verify_remote_identity!(jwt, http_factory: nil)
    identity = fetch_json!(API_URI, jwt, http_factory: http_factory)
    owner = identity["owner"] if identity.is_a?(Hash)
    unless identity.is_a?(Hash) &&
           identity["id"] == EXPECTED_APP_ID &&
           identity["slug"] == EXPECTED_SLUG &&
           owner.is_a?(Hash) &&
           owner["id"] == EXPECTED_OWNER_ID &&
           owner["login"] == EXPECTED_OWNER &&
           owner["type"] == EXPECTED_ACCOUNT_TYPE
      raise IdentityError
    end

    installation = fetch_json!(
      INSTALLATION_URI,
      jwt,
      http_factory: http_factory
    )
    account = installation["account"] if installation.is_a?(Hash)
    unless installation.is_a?(Hash) &&
           installation["id"].is_a?(Integer) &&
           installation["id"].positive? &&
           installation["app_id"] == EXPECTED_APP_ID &&
           installation["app_slug"] == EXPECTED_SLUG &&
           installation["repository_selection"] == "all" &&
           installation.key?("suspended_at") &&
           installation["suspended_at"].nil? &&
           installation.key?("suspended_by") &&
           installation["suspended_by"].nil? &&
           account.is_a?(Hash) &&
           account["id"] == EXPECTED_OWNER_ID &&
           account["login"] == EXPECTED_OWNER &&
           account["type"] == EXPECTED_ACCOUNT_TYPE &&
           installation["target_id"] == account["id"] &&
           installation["target_type"] == EXPECTED_ACCOUNT_TYPE
      raise IdentityError
    end

    true
  end

  def fetch_json!(uri, jwt, http_factory:)
    raise InputError unless jwt.is_a?(String) && !jwt.empty?
    unless uri.equal?(API_URI) || uri.equal?(INSTALLATION_URI)
      raise IdentityError
    end

    request = Net::HTTP::Get.new(uri.request_uri)
    request["Accept"] = "application/vnd.github+json"
    request["Authorization"] = "Bearer #{jwt}"
    request["User-Agent"] = USER_AGENT
    request["X-GitHub-Api-Version"] = API_VERSION

    http = if http_factory
             http_factory.call(uri)
           else
             build_http(uri)
           end

    response = http.start { |connection| connection.request(request) }
    raise IdentityError unless response.code == "200"

    body = +response.body.to_s
    raise IdentityError if body.empty? || body.bytesize > MAX_RESPONSE_BYTES

    JSON.parse(body)
  rescue JSON::ParserError
    raise IdentityError
  rescue OpenSSL::SSL::SSLError, SocketError, SystemCallError, Timeout::Error,
         EOFError, IOError, Net::HTTPBadResponse, Net::ProtocolError
    raise NetworkError
  ensure
    request&.delete("Authorization")
    body&.clear
  end
  private_class_method :fetch_json!

  def build_http(uri)
    # Passing an explicit nil proxy address disables Net::HTTP's ENV proxy
    # discovery. Both destinations are compile-time constants and cannot be
    # supplied by a caller or environment.
    http = Net::HTTP.new(uri.host, uri.port, nil, nil, nil, nil)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.verify_hostname = true if http.respond_to?(:verify_hostname=)
    http.min_version = OpenSSL::SSL::TLS1_2_VERSION if http.respond_to?(:min_version=)
    http.open_timeout = 10
    http.read_timeout = 10
    http.write_timeout = 10 if http.respond_to?(:write_timeout=)
    http
  end
  private_class_method :build_http

  def main(argv: ARGV, input: STDIN, output: STDOUT, error: STDERR,
           http_factory: nil)
    emit_pem = emit_pem_mode?(argv)
    input.binmode if input.respond_to?(:binmode)
    encoded = input.read(MAX_INPUT_BYTES + 1)
    raise InputError if encoded.bytesize > MAX_INPUT_BYTES

    key, decoded = decode_private_key_material(encoded)
    jwt = build_jwt(key)
    verify_remote_identity!(jwt, http_factory: http_factory)
    if emit_pem
      output.binmode if output.respond_to?(:binmode)
      output.write(decoded)
    end
    0
  rescue InputError
    error.puts "github_app_key_verifier: private key input rejected"
    2
  rescue NetworkError
    error.puts "github_app_key_verifier: GitHub identity request failed"
    3
  rescue IdentityError
    error.puts "github_app_key_verifier: GitHub App identity did not match"
    4
  rescue StandardError
    error.puts "github_app_key_verifier: verification failed"
    1
  ensure
    encoded&.clear
    jwt&.clear
    decoded&.clear
  end

  def emit_pem_mode?(argv)
    raise InputError unless argv.is_a?(Array)
    return false if argv.empty?
    return true if argv == ["--emit-pem"]

    raise InputError
  end
  private_class_method :emit_pem_mode?

  def strip_one_terminal_line_ending(encoded)
    if encoded.end_with?("\r\n")
      encoded.byteslice(0, encoded.bytesize - 2)
    elsif encoded.end_with?("\n")
      encoded.byteslice(0, encoded.bytesize - 1)
    else
      raise InputError
    end
  end
  private_class_method :strip_one_terminal_line_ending

  def urlsafe_encode(value)
    Base64.urlsafe_encode64(value, padding: false)
  end
  private_class_method :urlsafe_encode
end

exit GitHubAppKeyVerifier.main if $PROGRAM_NAME == __FILE__
