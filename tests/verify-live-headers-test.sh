#!/bin/bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/verify-live-headers-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/runtime" "$TMP/hostile-bin"

cat >"$TMP/bin/curl" <<'MOCK_CURL'
#!/bin/bash
headers_file=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --dump-header ]; then
    shift
    headers_file=$1
  fi
  shift
done
[ -n "$headers_file" ] || exit 97
effective_url=https://example.com
case "${CURL_SCENARIO:-valid}" in
  transport) exit 7 ;;
  status_404)
    printf 'HTTP/2 404\r\nContent-Type: text/plain\r\n\r\n' >"$headers_file"
    printf 404
    ;;
  redirect_final_missing)
    printf 'HTTP/2 301\r\nContent-Security-Policy: default-src '\''self'\''\r\nStrict-Transport-Security: max-age=1\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nPermissions-Policy: camera=()\r\nCross-Origin-Opener-Policy: same-origin\r\nLocation: https://example.com\r\n\r\nHTTP/2 200\r\nContent-Type: text/html\r\n\r\n' >"$headers_file"
    printf 200
    ;;
  blank_header)
    printf 'HTTP/2 200\r\nContent-Security-Policy: default-src '\''self'\''\r\nStrict-Transport-Security: max-age=1\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nPermissions-Policy:   \r\nCross-Origin-Opener-Policy: same-origin\r\n\r\n' >"$headers_file"
    printf 200
    ;;
  cross_origin)
    effective_url=https://attacker.example
    printf 'HTTP/2 302\r\nLocation: https://attacker.example\r\n\r\nHTTP/2 200\r\ncontent-security-policy: default-src '\''self'\''\r\nStrict-Transport-Security: max-age=31536000\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: strict-origin-when-cross-origin\r\nX-Frame-Options: DENY\r\nPermissions-Policy: camera=()\r\nCross-Origin-Opener-Policy: same-origin\r\n\r\n' >"$headers_file"
    printf 200
    ;;
  same_origin_path)
    effective_url=https://example.com/welcome
    printf 'HTTP/2 302\r\nLocation: /welcome\r\n\r\nHTTP/2 200\r\ncontent-security-policy: default-src '\''self'\''\r\nStrict-Transport-Security: max-age=31536000\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: strict-origin-when-cross-origin\r\nX-Frame-Options: DENY\r\nPermissions-Policy: camera=()\r\nCross-Origin-Opener-Policy: same-origin\r\n\r\n' >"$headers_file"
    printf 200
    ;;
  *)
    printf 'HTTP/2 200\r\ncontent-security-policy: default-src '\''self'\''\r\nStrict-Transport-Security: max-age=31536000\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: strict-origin-when-cross-origin\r\nX-Frame-Options: DENY\r\nPermissions-Policy: camera=()\r\nCross-Origin-Opener-Policy: same-origin\r\n\r\n' >"$headers_file"
    printf 200
    ;;
esac
printf '\t%s' "$effective_url"
MOCK_CURL
chmod +x "$TMP/bin/curl"

for hostile_tool in awk bash curl env grep mktemp rm sleep; do
  cat >"$TMP/hostile-bin/$hostile_tool" <<'HOSTILE_TOOL'
#!/bin/bash
printf '%s\n' "${0##*/}" >>"$HOSTILE_TOOL_LOG"
exit 99
HOSTILE_TOOL
  chmod +x "$TMP/hostile-bin/$hostile_tool"
done

cat >"$TMP/hostile-bash-env" <<'HOSTILE_BASH_ENV'
printf '%s\n' BASH_ENV >>"$HOSTILE_TOOL_LOG"
HOSTILE_BASH_ENV

passes=0
failures=0
run_case() {
  name=$1
  scenario=$2
  url=$3
  expected_rc=$4
  pattern=$5
  /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    LC_ALL=C \
    HOME="$TMP/home" \
    TMPDIR="$TMP/runtime" \
    CURL_SCENARIO="$scenario" \
    HEADER_PROBE_ATTEMPTS=1 \
    HEADER_PROBE_RETRY_DELAY_SECONDS=0 \
    HEADER_PROBE_TIMEOUT_SECONDS=1 \
    /bin/bash --noprofile --norc \
    "$ROOT/actions/verify-live-headers/verify-live-headers.sh" \
    "$url" schedule "$TMP/bin/curl" >"$TMP/$name.out" 2>&1
  rc=$?
  if [ "$rc" -eq "$expected_rc" ] && grep -qE "$pattern" "$TMP/$name.out"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (expected rc=%s /%s/, got rc=%s)\n' "$name" "$expected_rc" "$pattern" "$rc"
    sed -n '1,80p' "$TMP/$name.out" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_hostile_environment_case() {
  name=hostile-path-cannot-replace-tools
  : >"$TMP/hostile-tools.log"
  # Model a caller-provided shell hook, then apply the composite step's
  # BASH_ENV override at process creation. The YAML assertion below binds that
  # override to the action rather than trusting this fixture alone.
  BASH_ENV="$TMP/hostile-bash-env"
  export BASH_ENV
  PATH="$TMP/hostile-bin" \
    BASH_ENV=/dev/null \
    ENV="$TMP/hostile-bash-env" \
    HOSTILE_TOOL_LOG="$TMP/hostile-tools.log" \
    CURL_SCENARIO=valid \
    HEADER_PROBE_ATTEMPTS=1 \
    HEADER_PROBE_RETRY_DELAY_SECONDS=0 \
    HEADER_PROBE_TIMEOUT_SECONDS=1 \
    HOME="$TMP/home" \
    TMPDIR="$TMP/runtime" \
    /bin/bash --noprofile --norc \
    "$ROOT/actions/verify-live-headers/verify-live-headers.sh" \
    https://example.com schedule "$TMP/bin/curl" >"$TMP/$name.out" 2>&1
  rc=$?
  unset BASH_ENV
  if [ "$rc" -eq 0 ] && grep -q 'probe passed' "$TMP/$name.out" \
    && [ ! -s "$TMP/hostile-tools.log" ]; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (hostile PATH or shell startup hook influenced the probe; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/$name.out" | sed 's/^/  /'
    sed -n '1,80p' "$TMP/hostile-tools.log" | sed 's/^/  hostile: /'
    failures=$((failures + 1))
  fi
}

run_action_environment_case() {
  name=composite-scrubs-caller-environment
  if ruby -ryaml -e '
      action = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
      step = action.fetch("runs").fetch("steps").fetch(0)
      env = step.fetch("env")
      run = step.fetch("run")
      abort "unsafe shell" unless step.fetch("shell") == "/bin/bash --noprofile --norc -euo pipefail {0}"
      abort "BASH_ENV not neutralized" unless env.fetch("BASH_ENV") == "/dev/null"
      abort "ENV not neutralized" unless env.fetch("ENV") == "/dev/null"
      %w[
        BASHOPTS BASH_COMPAT BASH_LOADABLES_PATH CDPATH CURL_HOME GLOBIGNORE PS4 SHELLOPTS
        DYLD_FALLBACK_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH
        DYLD_IMAGE_SUFFIX DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_PRINT_TO_FILE DYLD_ROOT_PATH
        LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_LIBRARY_PATH LD_ORIGIN_PATH LD_PRELOAD LD_PROFILE
        XDG_CONFIG_HOME
      ].each do |name|
        abort "#{name} not neutralized" unless env.fetch(name) == ""
      end
      abort "LD_SHOW_AUXV must be absent from the process environment" if env.key?("LD_SHOW_AUXV")
      abort "LD_SHOW_AUXV is not unset before the first command" unless run.lines.first&.strip == "unset LD_SHOW_AUXV"
      abort "missing clean environment" unless run.include?("/usr/bin/env -i")
      abort "missing private HOME" unless run.include?(%q(HOME="$probe_home"))
      abort "missing private TMPDIR" unless run.include?(%q(TMPDIR="$probe_tmp"))
      abort "PATH not allowlisted" unless run.include?("PATH=/usr/bin:/bin")
      invocation = run.lines.drop_while { |line| !line.include?("verify-live-headers.sh") }
        .map(&:strip).reject(&:empty?)
      expected = [
        %q("$GITHUB_ACTION_PATH/verify-live-headers.sh" \\),
        %q("$TARGET_URL" \\),
        %q("$GITHUB_EVENT_NAME")
      ]
      abort "script invocation is not exactly two arguments" unless invocation == expected
    ' "$ROOT/actions/verify-live-headers/action.yml" >"$TMP/$name.out" 2>&1; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s\n' "$name"
    sed -n '1,80p' "$TMP/$name.out" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_argument_boundary_case() {
  name=test-curl-must-be-absolute
  HEADER_PROBE_ATTEMPTS=1 HEADER_PROBE_RETRY_DELAY_SECONDS=0 HEADER_PROBE_TIMEOUT_SECONDS=1 \
    /bin/bash --noprofile --norc "$ROOT/actions/verify-live-headers/verify-live-headers.sh" \
    https://example.com schedule relative/curl >"$TMP/$name.out" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ] && grep -q 'absolute executable' "$TMP/$name.out"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (relative test curl path was accepted; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/$name.out" | sed 's/^/  /'
    failures=$((failures + 1))
  fi

  name=extra-arguments-are-rejected
  /bin/bash --noprofile --norc "$ROOT/actions/verify-live-headers/verify-live-headers.sh" \
    https://example.com schedule "$TMP/bin/curl" extra >"$TMP/$name.out" 2>&1
  rc=$?
  if [ "$rc" -eq 2 ] && grep -q 'exactly two arguments' "$TMP/$name.out"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (extra argument was accepted; rc=%s)\n' "$name" "$rc"
    sed -n '1,80p' "$TMP/$name.out" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

run_case complete-header-set valid https://example.com 0 'probe passed'
run_case missing-final-redirect-headers redirect_final_missing https://example.com 1 'missing nonblank header'
run_case blank-header-value blank_header https://example.com 1 'permissions-policy'
run_case reject-cross-origin-final-response cross_origin https://example.com 1 'effective origin|cross-origin'
run_case accept-same-origin-final-path same_origin_path https://example.com 0 'probe passed'
run_case error-status status_404 https://example.com 1 'HTTP 404'
run_case transport-failure transport https://example.com 1 'curl failed with exit 7'
run_case reject-path valid https://example.com/path 2 'literal HTTPS origin'
run_case reject-expression valid '${{ github.event.inputs.url }}' 2 'literal HTTPS origin'
run_hostile_environment_case
run_action_environment_case
run_argument_boundary_case

printf '%s passed; %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
