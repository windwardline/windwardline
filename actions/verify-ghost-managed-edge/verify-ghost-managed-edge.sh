#!/bin/bash

set -u -o pipefail

# Production takes only the triggering event. Two additional absolute tool
# paths are accepted solely by the hermetic regression tests; action.yml never
# supplies them, so a caller cannot replace either runner-owned binary.
case "$#" in
  1)
    curl_bin=/usr/bin/curl
    dig_bin=/usr/bin/dig
    ;;
  3)
    curl_bin=$2
    dig_bin=$3
    ;;
  *)
    echo "ERROR: production invocation requires exactly one argument; tests may add absolute curl and dig paths." >&2
    exit 2
    ;;
esac

event_name=$1
case "$event_name" in
  push|schedule) ;;
  *) echo "ERROR: event must be the literal push or schedule trigger." >&2; exit 2 ;;
esac

PATH=/usr/bin:/bin
export PATH
for tool in "$curl_bin" "$dig_bin"; do
  case "$tool" in
    /*) ;;
    *) echo "ERROR: probe tool paths must be absolute executable files." >&2; exit 2 ;;
  esac
  [ -f "$tool" ] && [ -x "$tool" ] \
    || { echo "ERROR: probe tool paths must be absolute executable files." >&2; exit 2; }
done

attempts=${GHOST_EDGE_ATTEMPTS:-5}
retry_delay=${GHOST_EDGE_RETRY_DELAY_SECONDS:-45}
request_timeout=${GHOST_EDGE_REQUEST_TIMEOUT_SECONDS:-20}
push_delay=${GHOST_EDGE_PUSH_DELAY_SECONDS:-60}
case "$attempts:$retry_delay:$request_timeout:$push_delay" in
  *[!0-9:]*|:*|*::*|*:) echo "ERROR: probe timing values must be nonnegative integers." >&2; exit 2 ;;
esac
[ "$attempts" -gt 0 ] || { echo "ERROR: probe attempts must be positive." >&2; exit 2; }
[ "$request_timeout" -gt 0 ] || { echo "ERROR: request timeout must be positive." >&2; exit 2; }

apex_host=grownmengrow.com
ghost_host=grown-men-grow.ghost.io
www_host=www.grownmengrow.com
apex_url=https://grownmengrow.com
www_url=https://www.grownmengrow.com
expected_www_ipv4=178.128.137.126
resolver=1.1.1.1

work_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/fleet-ghost-edge.XXXXXX") \
  || { echo "ERROR: could not allocate probe state." >&2; exit 2; }
www_headers=$work_root/www.headers
apex_headers=$work_root/apex.headers
final_headers=$work_root/apex-final.headers
trap '/bin/rm -rf -- "$work_root"' EXIT HUP INT TERM

resolve_ipv4() {
  local host=$1 answers
  answers=$("$dig_bin" "@$resolver" +time=5 +tries=2 +short A "$host" | /usr/bin/awk '
    $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
      split($0, octet, ".")
      valid=1
      for (i=1; i<=4; i++) if (octet[i] !~ /^[0-9]+$/ || octet[i] + 0 > 255) valid=0
      if (valid) print $0
    }
  ' | /usr/bin/sort -u) || return 1
  [ -n "$answers" ] || return 1
  printf '%s\n' "$answers"
}

extract_final_headers() {
  local source=$1 destination=$2
  /usr/bin/awk '
    /^HTTP\/[0-9.]+ [0-9][0-9][0-9]/ { block=""; in_headers=1; next }
    in_headers && /^\r?$/ { in_headers=0; next }
    in_headers { sub(/\r$/, ""); block=block $0 "\n" }
    END { printf "%s", block }
  ' "$source" >"$destination"
}

header_value() {
  local wanted=$1 source=$2
  /usr/bin/awk -v wanted="$wanted" '
    {
      line=$0
      sub(/\r$/, "", line)
      separator=index(line, ":")
      if (separator == 0) next
      name=tolower(substr(line, 1, separator-1))
      value=substr(line, separator+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (name == wanted) print value
    }
  ' "$source"
}

header_present() {
  local wanted=$1 source=$2
  /usr/bin/awk -v wanted="$wanted" '
    {
      line=$0
      sub(/\r$/, "", line)
      separator=index(line, ":")
      if (separator == 0) next
      name=tolower(substr(line, 1, separator-1))
      value=substr(line, separator+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (name == wanted && length(value) > 0) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$source"
}

header_name_present() {
  local wanted=$1 source=$2
  /usr/bin/awk -v wanted="$wanted" '
    {
      line=$0
      sub(/\r$/, "", line)
      separator=index(line, ":")
      if (separator == 0) next
      name=tolower(substr(line, 1, separator-1))
      if (name == wanted) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$source"
}

if [ "$event_name" = push ] && [ "$push_delay" -gt 0 ]; then
  echo "Waiting $push_delay seconds for the managed production edge to become observable."
  /bin/sleep "$push_delay"
fi

required_headers='content-security-policy
strict-transport-security
x-content-type-options
referrer-policy
x-frame-options
permissions-policy
cross-origin-opener-policy'

attempt=1
while [ "$attempt" -le "$attempts" ]; do
  failure=""
  apex_ipv4=$(resolve_ipv4 "$apex_host") || failure="apex DNS returned no valid IPv4 set"
  ghost_ipv4=$(resolve_ipv4 "$ghost_host") || failure="Ghost target DNS returned no valid IPv4 set"
  www_ipv4=$(resolve_ipv4 "$www_host") || failure="www DNS returned no valid IPv4 set"
  if [ -z "$failure" ] && [ "$apex_ipv4" != "$ghost_ipv4" ]; then
    failure="apex IPv4 set differs from the live Ghost target IPv4 set"
  fi
  if [ -z "$failure" ] && [ "$www_ipv4" != "$expected_www_ipv4" ]; then
    failure="www IPv4 set is not exactly $expected_www_ipv4"
  fi

  : >"$www_headers"
  if [ -z "$failure" ]; then
    www_result=$("$curl_bin" --disable --silent --show-error \
      --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time "$request_timeout" \
      --dump-header "$www_headers" --output /dev/null \
      --write-out '%{http_code}\t%{url_effective}' "$www_url")
    curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
      failure="www HTTPS probe failed with curl exit $curl_rc"
    else
      IFS="$(printf '\t')" read -r www_code www_effective <<EOF
$www_result
EOF
      case "$www_code" in 301|302|303|307|308) ;; *) failure="www returned HTTP ${www_code:-unknown}, not a redirect" ;; esac
      location=$(header_value location "$www_headers")
      [ "$www_effective" = "$www_url/" ] || [ "$www_effective" = "$www_url" ] \
        || failure="www probe did not address the literal managed hostname"
      [ "$location" = "$apex_url/" ] || failure="www redirect Location is not exactly $apex_url/"
    fi
  fi

  : >"$apex_headers"
  : >"$final_headers"
  if [ -z "$failure" ]; then
    apex_result=$("$curl_bin" --disable --silent --show-error --location --max-redirs 5 \
      --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --connect-timeout 10 --max-time "$request_timeout" \
      --dump-header "$apex_headers" --output /dev/null \
      --write-out '%{http_code}\t%{url_effective}' "$apex_url")
    curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
      failure="apex HTTPS probe failed with curl exit $curl_rc"
    else
      IFS="$(printf '\t')" read -r apex_code apex_effective <<EOF
$apex_result
EOF
      case "$apex_code" in 2??) ;; *) failure="final apex response was HTTP ${apex_code:-unknown}, not 200-299" ;; esac
      [ "$apex_effective" = "$apex_url/" ] || [ "$apex_effective" = "$apex_url" ] \
        || failure="apex request escaped the literal production origin"
      extract_final_headers "$apex_headers" "$final_headers"
    fi
  fi

  if [ -z "$failure" ]; then
    server=$(header_value server "$final_headers")
    ghost_marker=$(header_value ghost-fastly "$final_headers")
    via=$(header_value via "$final_headers")
    header_name_present cf-ray "$final_headers" \
      && failure="final apex response carries cf-ray"
    header_name_present cf-cache-status "$final_headers" \
      && failure="final apex response carries cf-cache-status"
    if printf '%s\n' "$server" | /usr/bin/grep -Fiq cloudflare; then
      failure="final apex response reports a Cloudflare server"
    fi
    [ "$ghost_marker" = 'true;production' ] \
      || failure="final apex response lacks the exact Ghost production marker"
    printf '%s\n' "$via" | /usr/bin/grep -Eiq '(^|[ ,])varnish([ ,]|$)' \
      || failure="final apex response lacks the Fastly/Varnish path marker"
  fi

  if [ -z "$failure" ]; then
    missing=""
    while IFS= read -r header; do
      [ -n "$header" ] || continue
      header_present "$header" "$final_headers" || missing="${missing}${missing:+, }$header"
    done <<EOF
$required_headers
EOF
    if [ -z "$missing" ]; then
      echo "ERROR: all seven fleet headers are now present; remove the stale Ghost managed-edge exception." >&2
      exit 1
    fi
    echo "Ghost managed-edge probe passed: DNS-only Ghost/Fastly topology holds; absent fleet header(s): $missing"
    exit 0
  fi

  echo "Attempt $attempt/$attempts: $failure." >&2
  if [ "$attempt" -lt "$attempts" ]; then
    /bin/sleep "$retry_delay"
  fi
  attempt=$((attempt + 1))
done

echo "ERROR: Ghost managed-edge probe failed after $attempts attempt(s)." >&2
exit 1
