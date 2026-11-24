#!/bin/bash
# The fleet's required Secret scan: gitleaks over a repository's full history.
#
#   secret-scan.sh [--archive FILE --sha256 HEX] <repo-dir>
#
# Runs as the step inside actions/secret-scan, which every fleet repository's
# `Secret scan` job calls. It replaced gitleaks-action on 2026-11-24 after two
# failures that both reported the wrong result for a repository with no leak:
#   - gitleaks-action asks the GitHub API whether the owner is an organization
#     before it scans, and on any API error demands a commercial license and
#     fails. One timeout held windwardline-media's check red 2026-11-16..23.
#   - gitleaks' own container image, the first replacement, passed on
#     "0 commits scanned": Actions sets HOME=/github/home, so the image's
#     safe.directory setting is never read and git refuses the checkout.
# So this downloads the pinned release, verifies its checksum, scans on the
# runner itself, and refuses any result that examined no commits.
#
# --archive/--sha256 exist for tests/secret-scan-test.sh. The action passes a
# fixed argv without them, so a caller's workflow cannot reach either.
#
# Exit 0 clean; 1 a finding, a failed download or checksum, a gitleaks error, or
# a scan of nothing; 64 bad usage.

set -euo pipefail

readonly GITLEAKS_VERSION=8.30.1
readonly GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
readonly GITLEAKS_URL="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"

usage() { echo "usage: secret-scan.sh [--archive FILE --sha256 HEX] <repo-dir>" >&2; exit 64; }
die() { echo "secret-scan: $*" >&2; exit 1; }

archive="" expected_sha="$GITLEAKS_SHA256" repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) [ $# -ge 2 ] || usage; archive=$2; shift 2 ;;
    --sha256) [ $# -ge 2 ] || usage; expected_sha=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$repo" ] || usage; repo=$1; shift ;;
  esac
done
[ -n "$repo" ] || usage
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || usage

work=$(mktemp -d "${TMPDIR:-/tmp}/secret-scan.XXXXXX")
trap '/bin/rm -rf -- "$work"' EXIT

if [ -z "$archive" ]; then
  archive="$work/gitleaks.tgz"
  curl -sSfL --retry 3 --max-time 120 -o "$archive" "$GITLEAKS_URL" \
    || die "could not download gitleaks ${GITLEAKS_VERSION}"
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha=$(sha256sum "$archive" | cut -d' ' -f1)
else
  actual_sha=$(shasum -a 256 "$archive" | cut -d' ' -f1)
fi
[ "$actual_sha" = "$expected_sha" ] || die "checksum mismatch: got $actual_sha, want $expected_sha"

tar -xzf "$archive" -C "$work" gitleaks || die "archive has no gitleaks binary"

commits=$(git -C "$repo" rev-list --count HEAD 2>/dev/null) || die "$repo has no readable history"
[ "$commits" -gt 0 ] || die "$repo has no commits"

if "$work/gitleaks" git --redact --verbose --no-banner --exit-code 1 "$repo" >"$work/log" 2>&1; then
  rc=0
else
  rc=$?
fi
cat "$work/log"

case "$rc" in
  0) ;;
  1) die "gitleaks found secrets" ;;
  *) die "gitleaks exited $rc" ;;
esac

# guard: scanned-count
# A clean exit is only a pass if gitleaks says it read history. "0 commits
# scanned", or no count at all, is a scan of nothing.
scanned=$(sed 's/\x1b\[[0-9;]*m//g' "$work/log" | grep -oE '[0-9]+ commits scanned' | tail -1 | cut -d' ' -f1)
[ -n "$scanned" ] || die "gitleaks reported no scanned-commit count"
[ "$scanned" -gt 0 ] || die "gitleaks scanned 0 commits of $commits"
# end guard

echo "secret-scan: gitleaks ${GITLEAKS_VERSION} scanned ${scanned:-?} commit(s), no leaks"
