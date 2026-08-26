# frozen_string_literal: true

require "base64"
require "json"
require "minitest/autorun"
require "openssl"
require "stringio"

require_relative "../scripts/github_app_key_verifier"

class GitHubAppKeyVerifierTest < Minitest::Test
  Response = Struct.new(:code, :body, keyword_init: true)

  class StubHttp
    def initialize(result, requests, uri)
      @result = result
      @requests = requests
      @uri = uri
    end

    def start
      yield self
    end

    def request(request)
      @requests << [@uri, request]
      raise @result if @result.is_a?(Exception)

      @result
    end
  end

  def setup
    @rsa_key = OpenSSL::PKey::RSA.generate(2048)
    @encoded_rsa = Base64.strict_encode64(@rsa_key.to_pem)
  end

  def test_accepts_exactly_one_lf_or_crlf_terminator
    lf_key = GitHubAppKeyVerifier.decode_private_key("#{@encoded_rsa}\n")
    crlf_key = GitHubAppKeyVerifier.decode_private_key("#{@encoded_rsa}\r\n")

    assert_instance_of OpenSSL::PKey::RSA, lf_key
    assert lf_key.private?
    assert_equal @rsa_key.public_key.to_der, lf_key.public_key.to_der
    assert_instance_of OpenSSL::PKey::RSA, crlf_key
    assert crlf_key.private?
    assert_equal @rsa_key.public_key.to_der, crlf_key.public_key.to_der
  end

  def test_rejects_missing_or_extra_line_terminators_and_other_whitespace
    invalid = [
      @encoded_rsa,
      "#{@encoded_rsa}\n\n",
      "#{@encoded_rsa}\r\n\r\n",
      " #{@encoded_rsa}\n",
      "#{@encoded_rsa} \n",
      "#{@encoded_rsa}\t\n",
      "#{@encoded_rsa[0, 20]}\n#{@encoded_rsa[20..]}\n",
      "#{@encoded_rsa}\r"
    ]

    invalid.each do |input|
      assert_raises(GitHubAppKeyVerifier::InputError) do
        GitHubAppKeyVerifier.decode_private_key(input)
      end
    end
  end

  def test_rejects_malformed_base64_and_malformed_key_material
    [
      "not-base64!\n",
      "AAAA=\n",
      "====\n",
      "#{Base64.strict_encode64('not a key')}\n"
    ].each do |input|
      assert_raises(GitHubAppKeyVerifier::InputError) do
        GitHubAppKeyVerifier.decode_private_key(input)
      end
    end
  end

  def test_rejects_non_rsa_and_public_only_keys
    ec_key = OpenSSL::PKey::EC.generate("prime256v1")
    invalid = [
      Base64.strict_encode64(ec_key.to_pem),
      Base64.strict_encode64(@rsa_key.public_key.to_pem)
    ]

    invalid.each do |encoded|
      assert_raises(GitHubAppKeyVerifier::InputError) do
        GitHubAppKeyVerifier.decode_private_key("#{encoded}\n")
      end
    end
  end

  def test_jwt_has_exact_claim_shape_and_a_valid_rs256_signature
    now = Time.at(1_700_000_000).utc
    jwt = GitHubAppKeyVerifier.build_jwt(@rsa_key, now: now)
    header_segment, payload_segment, signature_segment = jwt.split(".", -1)

    assert_equal 3, jwt.split(".", -1).length
    [header_segment, payload_segment, signature_segment].each do |segment|
      assert_match(/\A[A-Za-z0-9_-]+\z/, segment)
      refute_includes segment, "="
    end

    header = JSON.parse(Base64.urlsafe_decode64(padded(header_segment)))
    claims = JSON.parse(Base64.urlsafe_decode64(padded(payload_segment)))
    signature = Base64.urlsafe_decode64(padded(signature_segment))

    assert_equal({ "alg" => "RS256", "typ" => "JWT" }, header)
    assert_equal(
      {
        "iat" => now.to_i - GitHubAppKeyVerifier::JWT_BACKDATE_SECONDS,
        "exp" => now.to_i + GitHubAppKeyVerifier::JWT_LIFETIME_SECONDS,
        "iss" => 4_562_963
      },
      claims
    )
    assert_operator claims["iss"], :>, 0
    assert_operator claims["exp"] - claims["iat"], :<=, 600
    assert @rsa_key.verify(
      OpenSSL::Digest::SHA256.new,
      signature,
      "#{header_segment}.#{payload_segment}"
    )
  end

  def test_jwt_builder_rejects_non_private_or_non_rsa_keys
    ec_key = OpenSSL::PKey::EC.generate("prime256v1")

    assert_raises(GitHubAppKeyVerifier::InputError) do
      GitHubAppKeyVerifier.build_jwt(@rsa_key.public_key)
    end
    assert_raises(GitHubAppKeyVerifier::InputError) do
      GitHubAppKeyVerifier.build_jwt(ec_key)
    end
  end

  def test_remote_identity_contract_is_fixed
    assert_equal 4_562_963, GitHubAppKeyVerifier::EXPECTED_APP_ID
    assert_operator GitHubAppKeyVerifier::EXPECTED_APP_ID, :>, 0
    assert_equal "windward-line-automerge", GitHubAppKeyVerifier::EXPECTED_SLUG
    assert_equal "windwardline", GitHubAppKeyVerifier::EXPECTED_OWNER
    assert_equal 267_140_241, GitHubAppKeyVerifier::EXPECTED_OWNER_ID
    assert_equal "https", GitHubAppKeyVerifier::API_URI.scheme
    assert_equal "api.github.com", GitHubAppKeyVerifier::API_URI.host
    assert_equal 443, GitHubAppKeyVerifier::API_URI.port
    assert_equal "/app", GitHubAppKeyVerifier::API_URI.request_uri
    assert GitHubAppKeyVerifier::API_URI.frozen?
    assert_equal "https", GitHubAppKeyVerifier::INSTALLATION_URI.scheme
    assert_equal "api.github.com", GitHubAppKeyVerifier::INSTALLATION_URI.host
    assert_equal 443, GitHubAppKeyVerifier::INSTALLATION_URI.port
    assert_equal "/users/windwardline/installation",
                 GitHubAppKeyVerifier::INSTALLATION_URI.request_uri
    assert GitHubAppKeyVerifier::INSTALLATION_URI.frozen?
  end

  def test_remote_verification_requires_exact_app_and_live_all_repository_installation
    factory, requests = stub_factory

    assert GitHubAppKeyVerifier.verify_remote_identity!(
      "secret.jwt",
      http_factory: factory
    )
    assert_equal [
      GitHubAppKeyVerifier::API_URI,
      GitHubAppKeyVerifier::INSTALLATION_URI
    ], requests.map(&:first)

    requests.each do |_uri, request|
      assert_equal "application/vnd.github+json", request["Accept"]
      assert_equal GitHubAppKeyVerifier::USER_AGENT, request["User-Agent"]
      assert_equal GitHubAppKeyVerifier::API_VERSION,
                   request["X-GitHub-Api-Version"]
      assert_nil request["Authorization"], "JWT must be cleared after each request"
    end
  end

  def test_remote_verification_rejects_http_non_200_at_either_endpoint
    [
      { app: response("401", '{"message":"jwt-marker"}') },
      { installation: response("404", '{"message":"body-marker"}') }
    ].each do |overrides|
      factory, = stub_factory(**overrides)

      assert_raises(GitHubAppKeyVerifier::IdentityError) do
        GitHubAppKeyVerifier.verify_remote_identity!(
          "secret.jwt",
          http_factory: factory
        )
      end
    end
  end

  def test_remote_verification_rejects_malformed_or_wrong_app_identity
    invalid_app_bodies = [
      "not-json",
      JSON.generate(valid_app.merge("id" => 99)),
      JSON.generate(valid_app.merge("slug" => "wrong-app")),
      JSON.generate(valid_app.merge("owner" => valid_account.merge("id" => 1))),
      JSON.generate(valid_app.merge(
        "owner" => valid_account.merge("login" => "intruder")
      )),
      JSON.generate(valid_app.merge(
        "owner" => valid_account.merge("type" => "Organization")
      ))
    ]

    invalid_app_bodies.each do |body|
      factory, = stub_factory(app: response("200", body))

      assert_raises(GitHubAppKeyVerifier::IdentityError) do
        GitHubAppKeyVerifier.verify_remote_identity!(
          "secret.jwt",
          http_factory: factory
        )
      end
    end
  end

  def test_remote_verification_rejects_installation_mismatch_or_suspension
    malformed_factory, = stub_factory(
      installation: response("200", "not-json")
    )
    assert_raises(GitHubAppKeyVerifier::IdentityError) do
      GitHubAppKeyVerifier.verify_remote_identity!(
        "secret.jwt",
        http_factory: malformed_factory
      )
    end

    recycled_owner = valid_account.merge("id" => 1)
    invalid_installations = [
      valid_installation.merge("repository_selection" => "selected"),
      valid_installation.merge("suspended_at" => "2026-08-24T00:00:00Z"),
      valid_installation.merge("suspended_by" => { "login" => "windwardline" }),
      valid_installation.reject { |key, _value| key == "suspended_at" },
      valid_installation.reject { |key, _value| key == "suspended_by" },
      valid_installation.merge("app_id" => 99),
      valid_installation.merge("app_slug" => "wrong-app"),
      valid_installation.merge("account" => recycled_owner, "target_id" => 1),
      valid_installation.merge("account" => valid_account.merge("login" => "intruder")),
      valid_installation.merge("account" => valid_account.merge("type" => "Organization")),
      valid_installation.merge("target_type" => "Organization"),
      valid_installation.merge("target_id" => valid_account.fetch("id") + 1),
      valid_installation.merge("id" => 0)
    ]

    invalid_installations.each do |installation|
      factory, = stub_factory(
        installation: response("200", JSON.generate(installation))
      )

      assert_raises(GitHubAppKeyVerifier::IdentityError) do
        GitHubAppKeyVerifier.verify_remote_identity!(
          "secret.jwt",
          http_factory: factory
        )
      end
    end
  end

  def test_remote_verification_reports_network_failure_at_either_endpoint
    [
      { app: SocketError.new("socket-marker") },
      { installation: Timeout::Error.new("timeout-marker") }
    ].each do |overrides|
      factory, = stub_factory(**overrides)

      assert_raises(GitHubAppKeyVerifier::NetworkError) do
        GitHubAppKeyVerifier.verify_remote_identity!(
          "secret.jwt",
          http_factory: factory
        )
      end
    end
  end

  def test_main_default_mode_emits_nothing_after_verified_success
    output = StringIO.new
    error = StringIO.new
    factory, = stub_factory

    status = GitHubAppKeyVerifier.main(
      argv: [],
      input: StringIO.new("#{@encoded_rsa}\n"),
      output: output,
      error: error,
      http_factory: factory
    )

    assert_equal 0, status
    assert_empty output.string
    assert_empty error.string
  end

  def test_main_emit_pem_mode_emits_only_the_decoded_verified_key
    output = StringIO.new
    error = StringIO.new
    factory, = stub_factory

    status = GitHubAppKeyVerifier.main(
      argv: ["--emit-pem"],
      input: StringIO.new("#{@encoded_rsa}\r\n"),
      output: output,
      error: error,
      http_factory: factory
    )

    assert_equal 0, status
    assert_equal @rsa_key.to_pem, output.string
    assert_empty error.string
  end

  def test_main_emit_pem_mode_emits_nothing_when_live_proof_fails
    output = StringIO.new
    error = StringIO.new
    body_marker = "github-response-body-marker"
    factory, = stub_factory(
      installation: response("200", JSON.generate(
        valid_installation.merge("repository_selection" => body_marker)
      ))
    )

    status = GitHubAppKeyVerifier.main(
      argv: ["--emit-pem"],
      input: StringIO.new("#{@encoded_rsa}\n"),
      output: output,
      error: error,
      http_factory: factory
    )

    assert_equal 4, status
    assert_empty output.string
    assert_equal "github_app_key_verifier: GitHub App identity did not match\n",
                 error.string
    refute_includes error.string, body_marker
    refute_includes error.string, "BEGIN RSA PRIVATE KEY"
  end

  def test_main_network_failure_emits_no_sensitive_details
    output = StringIO.new
    error = StringIO.new
    factory, = stub_factory(
      installation: SocketError.new("network-exception-marker")
    )

    status = GitHubAppKeyVerifier.main(
      argv: ["--emit-pem"],
      input: StringIO.new("#{@encoded_rsa}\n"),
      output: output,
      error: error,
      http_factory: factory
    )

    assert_equal 3, status
    assert_empty output.string
    assert_equal "github_app_key_verifier: GitHub identity request failed\n",
                 error.string
    refute_includes error.string, "network-exception-marker"
    refute_includes error.string, "BEGIN RSA PRIVATE KEY"
  end

  private

  def stub_factory(app: nil, installation: nil)
    app ||= response("200", JSON.generate(valid_app))
    installation ||= response("200", JSON.generate(valid_installation))
    results = {
      GitHubAppKeyVerifier::API_URI.request_uri => app,
      GitHubAppKeyVerifier::INSTALLATION_URI.request_uri => installation
    }
    requests = []
    factory = lambda do |uri|
      result = results.fetch(uri.request_uri)
      StubHttp.new(result, requests, uri)
    end
    [factory, requests]
  end

  def response(code, body)
    Response.new(code: code, body: body)
  end

  def valid_app
    {
      "id" => GitHubAppKeyVerifier::EXPECTED_APP_ID,
      "slug" => GitHubAppKeyVerifier::EXPECTED_SLUG,
      "owner" => valid_account
    }
  end

  def valid_account
    {
      "id" => 267_140_241,
      "login" => GitHubAppKeyVerifier::EXPECTED_OWNER,
      "type" => "User"
    }
  end

  def valid_installation
    {
      "id" => 81_234_567,
      "app_id" => GitHubAppKeyVerifier::EXPECTED_APP_ID,
      "app_slug" => GitHubAppKeyVerifier::EXPECTED_SLUG,
      "account" => valid_account,
      "target_id" => valid_account.fetch("id"),
      "target_type" => "User",
      "repository_selection" => "all",
      "suspended_at" => nil,
      "suspended_by" => nil
    }
  end

  def padded(segment)
    segment + ("=" * ((4 - (segment.length % 4)) % 4))
  end
end
