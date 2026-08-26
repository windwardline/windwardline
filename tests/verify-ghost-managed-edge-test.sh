#!/bin/bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUBJECT="$ROOT/actions/verify-ghost-managed-edge/verify-ghost-managed-edge.sh"
ACTION="$ROOT/actions/verify-ghost-managed-edge/action.yml"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/verify-ghost-edge-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cat >"$TMP/dig" <<'MOCK_DIG'
#!/bin/bash
host=${!#}
case "$host:${MOCK_MODE:-valid}" in
  grownmengrow.com:apex-mismatch) printf '%s\n' 151.101.3.7 ;;
  grownmengrow.com:*) printf '%s\n' 151.101.3.7 151.101.67.7 151.101.131.7 151.101.195.7 ;;
  grown-men-grow.ghost.io:*)
    printf '%s\n' ghost.map.fastly.net. 151.101.195.7 151.101.3.7 151.101.131.7 151.101.67.7
    ;;
  www.grownmengrow.com:www-extra) printf '%s\n' 178.128.137.126 203.0.113.9 ;;
  www.grownmengrow.com:*) printf '%s\n' 178.128.137.126 ;;
  *) exit 9 ;;
esac
MOCK_DIG

cat >"$TMP/curl" <<'MOCK_CURL'
#!/bin/bash
set -u
dump=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dump-header) shift; dump=$1 ;;
    https://*) url=$1 ;;
  esac
  shift
done
[ -n "$dump" ] && [ -n "$url" ] || exit 8

if [ "$url" = https://www.grownmengrow.com ]; then
  code=302
  location=https://grownmengrow.com/
  [ "${MOCK_MODE:-valid}" = www-not-redirect ] && code=200
  [ "${MOCK_MODE:-valid}" = www-wrong-location ] && location=https://example.com/
  printf 'HTTP/2 %s\r\nLocation: %s\r\nServer: Caddy\r\n\r\n' "$code" "$location" >"$dump"
  printf '%s\thttps://www.grownmengrow.com/' "$code"
  exit 0
fi

[ "$url" = https://grownmengrow.com ] || exit 7
mode=${MOCK_MODE:-valid}
if [ "$mode" = redirect-marker-forgery ]; then
  printf '%s' 'HTTP/2 301
Ghost-Fastly: true;production
Via: 1.1 varnish
Location: https://grownmengrow.com/

HTTP/2 200
Server: openresty
Strict-Transport-Security: max-age=31536000

' >"$dump"
  printf '200\thttps://grownmengrow.com/'
  exit 0
fi

server=openresty
ghost='Ghost-Fastly: true;production'
via='Via: 1.1 varnish, 1.1 varnish'
case "$mode" in
  cf-server) server=cloudflare ;;
  ghost-missing) ghost='' ;;
  via-missing) via='' ;;
esac
{
  printf 'HTTP/2 200\r\nServer: %s\r\n' "$server"
  [ -z "$ghost" ] || printf '%s\r\n' "$ghost"
  [ -z "$via" ] || printf '%s\r\n' "$via"
  printf 'Strict-Transport-Security: max-age=31536000\r\n'
  [ "$mode" = cf-ray ] && printf 'Cf-Ray: forged\r\n'
  [ "$mode" = cf-ray-blank ] && printf 'Cf-Ray: \r\n'
  [ "$mode" = cf-cache ] && printf 'CF-Cache-Status: HIT\r\n'
  [ "$mode" = cf-cache-blank ] && printf 'CF-Cache-Status: \r\n'
  if [ "$mode" = stale ]; then
    printf 'Content-Security-Policy: default-src self\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf 'Referrer-Policy: strict-origin-when-cross-origin\r\n'
    printf 'X-Frame-Options: DENY\r\n'
    printf 'Permissions-Policy: camera=()\r\n'
    printf 'Cross-Origin-Opener-Policy: same-origin\r\n'
  fi
  printf '\r\n'
} >"$dump"
printf '200\thttps://grownmengrow.com/'
MOCK_CURL
chmod +x "$TMP/dig" "$TMP/curl"

passes=0
failures=0

run_case() {
  name=$1 mode=$2 expected_rc=$3 pattern=$4
  MOCK_MODE=$mode \
    GHOST_EDGE_ATTEMPTS=1 \
    GHOST_EDGE_RETRY_DELAY_SECONDS=0 \
    GHOST_EDGE_REQUEST_TIMEOUT_SECONDS=1 \
    GHOST_EDGE_PUSH_DELAY_SECONDS=0 \
    bash "$SUBJECT" schedule "$TMP/curl" "$TMP/dig" >"$TMP/$name.out" 2>&1
  rc=$?
  if [ "$rc" -eq "$expected_rc" ] && grep -qE "$pattern" "$TMP/$name.out"; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s (rc=%s, wanted %s /%s/)\n' "$name" "$rc" "$expected_rc" "$pattern"
    sed 's/^/  /' "$TMP/$name.out"
    failures=$((failures + 1))
  fi
}

run_case canonical-dns-only-edge valid 0 'managed-edge probe passed'
run_case apex-must-equal-ghost-set apex-mismatch 1 'apex IPv4 set differs'
run_case www-must-have-one-fixed-address www-extra 1 'www IPv4 set is not exactly'
run_case www-must-redirect www-not-redirect 1 'not a redirect'
run_case www-location-must-be-apex www-wrong-location 1 'Location is not exactly'
run_case cf-ray-rejects-proxy cf-ray 1 'carries cf-ray'
run_case blank-cf-ray-still-rejects-proxy cf-ray-blank 1 'carries cf-ray'
run_case cf-cache-rejects-proxy cf-cache 1 'carries cf-cache-status'
run_case blank-cf-cache-still-rejects-proxy cf-cache-blank 1 'carries cf-cache-status'
run_case cloudflare-server-rejects-proxy cf-server 1 'reports a Cloudflare server'
run_case ghost-marker-is-required ghost-missing 1 'lacks the exact Ghost production marker'
run_case fastly-marker-is-required via-missing 1 'lacks the Fastly/Varnish path marker'
run_case redirect-headers-cannot-forge-final redirect-marker-forgery 1 'lacks the (exact Ghost production|Fastly/Varnish path) marker'
run_case exception-self-expires stale 1 'all seven fleet headers are now present.*remove the stale'

GHOST_EDGE_ATTEMPTS=1 GHOST_EDGE_RETRY_DELAY_SECONDS=0 \
  GHOST_EDGE_REQUEST_TIMEOUT_SECONDS=1 GHOST_EDGE_PUSH_DELAY_SECONDS=0 \
  bash "$SUBJECT" pull_request "$TMP/curl" "$TMP/dig" >"$TMP/bad-event.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q 'literal push or schedule' "$TMP/bad-event.out"; then
  printf 'ok - event-is-literal\n'; passes=$((passes + 1))
else
  printf 'not ok - event-is-literal (rc=%s)\n' "$rc"; failures=$((failures + 1))
fi

bash "$SUBJECT" schedule ./curl ./dig >"$TMP/relative-tools.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q 'absolute executable' "$TMP/relative-tools.out"; then
  printf 'ok - production-tools-cannot-follow-path\n'; passes=$((passes + 1))
else
  printf 'not ok - production-tools-cannot-follow-path (rc=%s)\n' "$rc"; failures=$((failures + 1))
fi

if grep -q '/usr/bin/env -i' "$ACTION" \
  && grep -q 'GITHUB_EVENT_NAME: \${{ github.event_name }}' "$ACTION" \
  && ! grep -q 'LD_SHOW_AUXV:' "$ACTION" \
  && grep -q '^        unset LD_SHOW_AUXV$' "$ACTION" \
  && ! grep -q '^inputs:' "$ACTION"; then
  printf 'ok - composite-has-no-caller-controlled-subject-or-environment\n'
  passes=$((passes + 1))
else
  printf 'not ok - composite-has-no-caller-controlled-subject-or-environment\n'
  failures=$((failures + 1))
fi

printf '%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
