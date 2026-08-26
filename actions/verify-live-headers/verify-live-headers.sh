#!/bin/bash

set -u -o pipefail

# The composite invokes this script with two arguments. A third, explicit tool
# path exists only for hermetic regression tests; the action never forwards it.
# Production therefore always executes the runner-owned curl at /usr/bin/curl.
case "$#" in
  2) curl_bin=/usr/bin/curl ;;
  3) curl_bin=$3 ;;
  *)
    echo "ERROR: production invocation requires exactly two arguments; tests may add one absolute curl path." >&2
    exit 2
    ;;
esac

target_url=$1
event_name=$2
attempts=${HEADER_PROBE_ATTEMPTS:-10}
retry_delay=${HEADER_PROBE_RETRY_DELAY_SECONDS:-45}
request_timeout=${HEADER_PROBE_TIMEOUT_SECONDS:-20}

# Never resolve a tool through caller-controlled PATH. The clean composite
# environment already supplies this value; setting it again protects direct
# diagnostic invocations of the script.
PATH=/usr/bin:/bin
export PATH

case "$curl_bin" in
  /*) ;;
  *) echo "ERROR: curl path must be an absolute executable file." >&2; exit 2 ;;
esac
[ -f "$curl_bin" ] && [ -x "$curl_bin" ] \
  || { echo "ERROR: curl path must be an absolute executable file." >&2; exit 2; }

case "$attempts:$retry_delay:$request_timeout" in
  *[!0-9:]*|:*|*::*|*:) echo "ERROR: header-probe timing values must be nonnegative integers." >&2; exit 2 ;;
esac
[ "$attempts" -gt 0 ] || { echo "ERROR: header-probe attempts must be positive." >&2; exit 2; }
[ "$request_timeout" -gt 0 ] || { echo "ERROR: header-probe timeout must be positive." >&2; exit 2; }

# A literal origin is the security boundary. Paths, credentials, ports,
# expressions, and non-HTTPS redirects are deliberately unsupported.
if ! [[ "$target_url" =~ ^https://([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}/?$ ]]; then
  echo "ERROR: url must be a literal HTTPS origin with a DNS hostname." >&2
  exit 2
fi
target_url=${target_url%/}
target_origin=$(printf '%s' "$target_url" | /usr/bin/tr '[:upper:]' '[:lower:]')

headers_file=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/fleet-live-headers.XXXXXX") \
  || { echo "ERROR: could not allocate a response-header file." >&2; exit 2; }
final_headers_file=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/fleet-live-final-headers.XXXXXX") \
  || { /bin/rm -f "$headers_file"; echo "ERROR: could not allocate a final-header file." >&2; exit 2; }
trap '/bin/rm -f "$headers_file" "$final_headers_file"' EXIT HUP INT TERM

required_headers='content-security-policy
strict-transport-security
x-content-type-options
referrer-policy
x-frame-options
permissions-policy
cross-origin-opener-policy'

header_present() {
  local wanted="$1"
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
  ' "$final_headers_file"
}

if [ "$event_name" = push ]; then
  echo "Waiting 60 seconds for the production deployment to become observable."
  /bin/sleep 60
fi

attempt=1
while [ "$attempt" -le "$attempts" ]; do
  : >"$headers_file"
  : >"$final_headers_file"
  curl_result=$("$curl_bin" --disable --silent --show-error --location --max-redirs 5 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time "$request_timeout" \
    --dump-header "$headers_file" --output /dev/null \
    --write-out '%{http_code}\t%{url_effective}' "$target_url")
  curl_rc=$?
  http_code=${curl_result%%$'\t'*}
  effective_url=${curl_result#*$'\t'}
  if [ "$effective_url" = "$curl_result" ]; then
    effective_url=""
  fi
  effective_origin=""
  effective_url_pattern='^(https://([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63})([/\?#][^[:space:]]*)?$'
  if [[ "$effective_url" =~ $effective_url_pattern ]]; then
    effective_origin=$(printf '%s' "${BASH_REMATCH[1]}" | /usr/bin/tr '[:upper:]' '[:lower:]')
  fi

  if [ "$curl_rc" -eq 0 ] && [ -z "$effective_origin" ]; then
    echo "Attempt $attempt/$attempts: final effective URL ${effective_url:-unknown} is not a literal HTTPS URL on a DNS origin." >&2
  elif [ "$curl_rc" -eq 0 ] && [ "$effective_origin" != "$target_origin" ]; then
    echo "Attempt $attempt/$attempts: final effective origin ${effective_url:-unknown} differs from $target_url; cross-origin redirects are forbidden." >&2
  elif [ "$curl_rc" -eq 0 ] && [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
    # curl records every redirect response. Only the last HTTP header block is
    # evidence about the final production response.
    /usr/bin/awk '
      /^HTTP\/[0-9.]+ [0-9][0-9][0-9]/ { block=""; in_headers=1; next }
      in_headers && /^\r?$/ { in_headers=0; next }
      in_headers { sub(/\r$/, ""); block=block $0 "\n" }
      END { printf "%s", block }
    ' "$headers_file" >"$final_headers_file"

    missing=""
    while IFS= read -r header; do
      [ -n "$header" ] || continue
      header_present "$header" || missing="${missing}${missing:+, }$header"
    done <<EOF
$required_headers
EOF
    if [ -z "$missing" ]; then
      echo "Live header probe passed for $target_url (HTTP $http_code)."
      exit 0
    fi
    echo "Attempt $attempt/$attempts: HTTP $http_code is missing nonblank header(s): $missing" >&2
  elif [ "$curl_rc" -ne 0 ]; then
    echo "Attempt $attempt/$attempts: curl failed with exit $curl_rc." >&2
  else
    echo "Attempt $attempt/$attempts: production returned HTTP ${http_code:-unknown}; expected 200-399." >&2
  fi

  if [ "$attempt" -lt "$attempts" ]; then
    /bin/sleep "$retry_delay"
  fi
  attempt=$((attempt + 1))
done

echo "ERROR: live header probe failed after $attempts attempt(s): $target_url" >&2
exit 1
