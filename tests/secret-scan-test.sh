#!/bin/bash
# Tests for scripts/secret-scan.sh, the fleet's required Secret scan.
#
# Both scanners before it reported the wrong result with no leak present:
# gitleaks-action failed on a GitHub API timeout (red for a week), and the first
# replacement, gitleaks' own container image, went green on "0 commits scanned"
# because git in the container refused the checkout. So the cases that
# matter most are the ones where gitleaks exits 0 having looked at nothing.
#
# gitleaks is replaced by a fake packed into a real tarball, so the download,
# checksum and extraction path the action uses runs unchanged. The suite ends
# with a mutation that deletes the scanned-count guard and requires the vacuous
# case to pass, proving the guard is what catches it.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCAN="$ROOT/scripts/secret-scan.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/secret-scan-test.XXXXXX")
builtin trap '/bin/rm -rf -- "$TMP"' EXIT HUP INT TERM
pass=0; fail=0

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fake_archive NAME EXIT MESSAGE: a tarball whose gitleaks prints MESSAGE,
# records that it ran, and exits EXIT.
fake_archive() {
  local dir="$TMP/pkg-$1"
  mkdir -p "$dir"
  cat >"$dir/gitleaks" <<EOF
#!/bin/bash
echo ran >> "$TMP/ran-$1"
echo "INF $3"
exit $2
EOF
  chmod +x "$dir/gitleaks"
  tar -czf "$TMP/$1.tgz" -C "$dir" gitleaks
}

repo() { # repo DIR COMMITS
  mkdir -p "$1"
  git -C "$1" init -q .
  git -C "$1" config user.email t@example.invalid
  git -C "$1" config user.name t
  local i
  for ((i = 1; i <= $2; i++)); do
    echo "$i" > "$1/f"; git -C "$1" add f; git -C "$1" commit -qm "c$i"
  done
}

expect() { # name want-exit got-exit
  if [ "$3" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: exit $3 (want $2)"; fi
}

repo "$TMP/r" 3
repo "$TMP/empty" 0

run() { # archive-name repo [script]
  local s="${3:-$SCAN}"
  /bin/bash "$s" --archive "$TMP/$1.tgz" --sha256 "$(sha256 "$TMP/$1.tgz")" "$2" >"$TMP/out-$1" 2>&1
}

fake_archive clean 0 "3 commits scanned."
run clean "$TMP/r"; expect "clean history passes" 0 $?

fake_archive vacuous 0 "0 commits scanned."
run vacuous "$TMP/r"; expect "a scan of zero commits fails" 1 $?

fake_archive silent 0 "no leaks found"
run silent "$TMP/r"; expect "a scan that reports no count fails" 1 $?

fake_archive leak 1 "3 commits scanned."
run leak "$TMP/r"; expect "a finding fails" 1 $?

fake_archive broken 2 "3 commits scanned."
run broken "$TMP/r"; expect "a gitleaks error fails" 1 $?

run clean "$TMP/empty"; expect "a repository with no commits fails" 1 $?

fake_archive tampered 0 "3 commits scanned."
/bin/bash "$SCAN" --archive "$TMP/tampered.tgz" --sha256 "$(printf '0%.0s' {1..64})" "$TMP/r" >/dev/null 2>&1
expect "a checksum mismatch fails" 1 $?
if [ -e "$TMP/ran-tampered" ]; then fail=$((fail + 1)); echo "FAIL tampered binary was executed"; else pass=$((pass + 1)); fi

/bin/bash "$SCAN" "$TMP/r" --bogus >/dev/null 2>&1; expect "an unknown argument is refused" 64 $?

# The production checksum must name the release the script downloads.
if grep -qE '^readonly GITLEAKS_SHA256=[0-9a-f]{64}$' "$SCAN" && grep -qE '^readonly GITLEAKS_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$SCAN"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL pinned version or checksum is malformed"
fi

# Mutation: without the scanned-count guard, the vacuous scan must pass.
mutant="$TMP/mutant.sh"
sed '/^# guard: scanned-count$/,/^# end guard$/d' "$SCAN" > "$mutant"
if grep -q 'scanned-count' "$mutant" || ! grep -q 'scanned-count' "$SCAN"; then
  fail=$((fail + 1)); echo "FAIL mutation did not land"
else
  run vacuous "$TMP/r" "$mutant"; expect "mutant without the guard passes a vacuous scan" 0 $?
fi

echo "secret-scan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
