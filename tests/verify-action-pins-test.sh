#!/bin/bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/verify-action-pins-test.XXXXXX")
builtin trap '/bin/rm -rf -- "$TMP"' EXIT HUP INT TERM

PIN_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIGEST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$TMP/bin" "$TMP/home"

# A deterministic tag source lets the tests distinguish a bad claim shape from
# a nonexistent tag. The moving aliases deliberately resolve to the same commit
# as v7.0.1: they are true today and still forbidden because they can move later.
cat >"$TMP/bin/git" <<'MOCK_GIT'
#!/bin/bash
if [ "$#" -ne 3 ] || [ "$1" != "ls-remote" ] || [ "$2" != "--tags" ]; then
  printf 'unexpected mock git invocation:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 97
fi

case "$3" in
  https://github.com/actions/checkout)
    for tag in v7.0.1 latest stable beta v7 v7.0; do
      printf '%s\trefs/tags/%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$tag"
    done
    ;;
  https://github.com/windwardline/windwardline)
    printf '%s\trefs/tags/v1.2.3\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    ;;
  *)
    printf 'unexpected tag repository: %s\n' "$3" >&2
    exit 98
    ;;
esac
MOCK_GIT
chmod +x "$TMP/bin/git"

cat >"$TMP/bin/gh" <<'MOCK_GH'
#!/bin/bash
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
[ "${1:-}" = api ] || exit 96
case "${2:-}" in
  repos/windwardline/fixture/git/trees/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\?recursive=1)
    printf '%s\n' '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","truncated":false,"tree":[{"path":".github/workflows/ci.yml","type":"blob","mode":"100644","sha":"cccccccccccccccccccccccccccccccccccccccc"}]}'
    ;;
  repos/windwardline/fixture/git/blobs/cccccccccccccccccccccccccccccccccccccccc)
    body=$(printf '%s\n' 'name: CI' 'on: pull_request' 'jobs:' '  audit:' '    runs-on: ubuntu-latest' '    steps:' '      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.1' | base64 | tr -d '\n')
    printf '{"encoding":"base64","content":"%s"}\n' "$body"
    ;;
  *) exit 95 ;;
esac
MOCK_GH
chmod +x "$TMP/bin/gh"

passes=0
failures=0

record_result() {
  local name=$1 ok=$2 detail=${3:-}
  if [ "$ok" -eq 1 ]; then
    printf 'ok - %s\n' "$name"
    passes=$((passes + 1))
  else
    printf 'not ok - %s%s\n' "$name" "$detail"
    failures=$((failures + 1))
  fi
}

run_case() {
  local name=$1 expected_rc=$2 pattern=$3 source=$4 fixture="$TMP/$1" rc
  local workflow_path=${5:-.github/workflows/ci.yml}
  mkdir -p "$fixture/.github/workflows"
  printf '%s\n' "$source" >"$fixture/$workflow_path"
  PATH="$TMP/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    HOME="$TMP/home" \
    /bin/bash --noprofile --norc \
    "$ROOT/scripts/verify-action-pins.sh" --local "$fixture" \
    >"$TMP/$name.out" 2>&1
  rc=$?
  if [ "$rc" -eq "$expected_rc" ] && grep -qE "$pattern" "$TMP/$name.out"; then
    record_result "$name" 1
  else
    record_result "$name" 0 " (expected rc=$expected_rc /$pattern/, got rc=$rc)"
    sed -n '1,100p' "$TMP/$name.out" | sed 's/^/  /'
  fi
}

valid_pin_workflow() {
  printf '%s\n' \
    'name: CI' \
    'on: pull_request' \
    'jobs:' \
    '  audit:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    "      - uses: actions/checkout@$PIN_SHA # v7.0.1"
}

run_case exact-release-tag 0 'All action pin comments name the tag' "$(valid_pin_workflow)"

for alias in latest stable beta v7 v7.0; do
  run_case "reject-${alias//./-}" 1 \
    "pin-comment-imprecise:actions/checkout#$alias" \
    "$(valid_pin_workflow | sed "s/# v7\.0\.1/# $alias/")"
done

run_case reject-mutable-docker-ref 1 \
  'pin-docker-mutable:docker://alpine:3\.20' \
  "name: CI
on: pull_request
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: docker://alpine:3.20"

run_case accept-docker-digest 0 \
  'classified 1 third-party ref' \
  "name: CI
on: pull_request
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: docker://ghcr.io/example/auditor@sha256:$DIGEST"

run_case reject-other-same-owner-main 1 \
  'pin-unpinned:windwardline/internal@main' \
  "$(valid_pin_workflow)
      - uses: windwardline/internal@main"

run_case reject-canonical-review-as-step 1 \
  'pin-unpinned:windwardline/windwardline@main' \
  "$(valid_pin_workflow)
      - uses: windwardline/windwardline/.github/workflows/claude-review.yml@main"

run_case accept-canonical-review-as-job 0 \
  'All action pin comments name the tag' \
  "name: CI
on: pull_request
jobs:
  review:
    uses: windwardline/windwardline/.github/workflows/claude-review.yml@main
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$PIN_SHA # v7.0.1" \
  .github/workflows/claude-review.yml

run_case reject-canonical-review-job-in-wrong-file 1 \
  'pin-unpinned:windwardline/windwardline@main' \
  "name: CI
on: pull_request
jobs:
  review:
    uses: windwardline/windwardline/.github/workflows/claude-review.yml@main
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$PIN_SHA # v7.0.1"

run_case reject-canonical-review-in-other-job 1 \
  'pin-unpinned:windwardline/windwardline@main' \
  "$(valid_pin_workflow)
  other:
    uses: windwardline/windwardline/.github/workflows/claude-review.yml@main"

run_case audit-same-owner-sha 0 \
  'classified 1 third-party ref' \
  "name: CI
on: pull_request
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: windwardline/windwardline/actions/example@$PIN_SHA # v1.2.3"

name=snapshot-manifest-uses-exact-sha
: >"$TMP/gh-snapshot.log"
printf 'fixture\t%s\n' "$PIN_SHA" | \
  PATH="$TMP/bin:/opt/homebrew/bin:/usr/bin:/bin" \
  HOME="$TMP/home" MOCK_GH_LOG="$TMP/gh-snapshot.log" \
  /bin/bash --noprofile --norc "$ROOT/scripts/verify-action-pins.sh" \
  --snapshot-manifest - 1 >"$TMP/$name.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] \
  && grep -q 'classified from 1 immutable repository snapshot' "$TMP/$name.out" \
  && grep -q "git/trees/$PIN_SHA" "$TMP/gh-snapshot.log" \
  && ! grep -qE 'user/repos|/branches/' "$TMP/gh-snapshot.log"; then
  record_result "$name" 1
else
  record_result "$name" 0 " (snapshot mode re-enumerated mutable state or failed; rc=$rc)"
  sed -n '1,100p' "$TMP/$name.out" | sed 's/^/  /'
  sed -n '1,100p' "$TMP/gh-snapshot.log" | sed 's/^/  gh: /'
fi

name=snapshot-manifest-rejects-duplicates
: >"$TMP/gh-duplicate.log"
printf 'fixture\t%s\nfixture\t%s\n' "$PIN_SHA" "$PIN_SHA" | \
  PATH="$TMP/bin:/opt/homebrew/bin:/usr/bin:/bin" \
  HOME="$TMP/home" MOCK_GH_LOG="$TMP/gh-duplicate.log" \
  /bin/bash --noprofile --norc "$ROOT/scripts/verify-action-pins.sh" \
  --snapshot-manifest - 2 >"$TMP/$name.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q "repeats repository 'fixture'" "$TMP/$name.out" \
  && [ ! -s "$TMP/gh-duplicate.log" ]; then
  record_result "$name" 1
else
  record_result "$name" 0 " (duplicate snapshot was not rejected before network reads; rc=$rc)"
  sed -n '1,100p' "$TMP/$name.out" | sed 's/^/  /'
fi

name=snapshot-manifest-count-must-match
: >"$TMP/gh-count.log"
printf 'fixture\t%s\n' "$PIN_SHA" | \
  PATH="$TMP/bin:/opt/homebrew/bin:/usr/bin:/bin" \
  HOME="$TMP/home" MOCK_GH_LOG="$TMP/gh-count.log" \
  /bin/bash --noprofile --norc "$ROOT/scripts/verify-action-pins.sh" \
  --snapshot-manifest - 2 >"$TMP/$name.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -q 'covered 1 of 2 expected repositories' "$TMP/$name.out" \
  && [ ! -s "$TMP/gh-count.log" ]; then
  record_result "$name" 1
else
  record_result "$name" 0 " (partial snapshot population was accepted; rc=$rc)"
  sed -n '1,100p' "$TMP/$name.out" | sed 's/^/  /'
fi

name=composite-scrubs-caller-environment
# shellcheck disable=SC2016 # This is Ruby source; shell expansion is unwanted.
if ruby -ryaml -e '
    action = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
    script = File.read(ARGV.fetch(1))
    step = action.fetch("runs").fetch("steps").fetch(0)
    env = step.fetch("env")
    run = step.fetch("run")
    abort "unsafe shell" unless step.fetch("shell") == "/bin/bash --noprofile --norc -euo pipefail {0}"
    abort "BASH_ENV not neutralized" unless env.fetch("BASH_ENV") == "/dev/null"
    abort "ENV not neutralized" unless env.fetch("ENV") == "/dev/null"
    empty = %w[
      BASHOPTS SHELLOPTS CDPATH GLOBIGNORE
      LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE LD_PROFILE_OUTPUT
      LD_ORIGIN_PATH GLIBC_TUNABLES
      DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH
      DYLD_FALLBACK_FRAMEWORK_PATH DYLD_ROOT_PATH DYLD_IMAGE_SUFFIX DYLD_VERSIONED_LIBRARY_PATH
      DYLD_VERSIONED_FRAMEWORK_PATH DYLD_SHARED_CACHE_DIR DYLD_PRINT_TO_FILE
      CURL_HOME
      GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS
      RUBYOPT RUBYLIB GEM_HOME GEM_PATH GEMRC BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_USER_CONFIG
    ]
    empty.each { |key| abort "#{key} not neutralized" unless env.fetch(key) == "" }
    abort "LD_SHOW_AUXV must be absent from the process environment" if env.key?("LD_SHOW_AUXV")
    abort "LD_SHOW_AUXV is not unset before the first command" unless run.lines.first&.strip == "unset LD_SHOW_AUXV"
    abort "GIT_CONFIG_COUNT not neutralized" unless env.fetch("GIT_CONFIG_COUNT") == "0"
    %w[PIN_ACTION_PATH PIN_WORKSPACE PIN_GITHUB_SHA PIN_RUNNER_TEMP].each do |key|
      abort "missing trusted context binding #{key}" unless env.fetch(key).is_a?(String) && !env.fetch(key).empty?
    end
    abort "missing clean environment" unless run.include?("/usr/bin/env -i")
    abort "missing private HOME" unless run.include?(%q(HOME="$pin_home"))
    abort "PATH not allowlisted" unless run.include?("PATH=/usr/bin:/bin")
    abort "Git system config not disabled" unless run.include?("GIT_CONFIG_NOSYSTEM=1")
    abort "Git global config not disabled" unless run.include?("GIT_CONFIG_GLOBAL=/dev/null")
    abort "Git system config path not neutralized" unless run.include?("GIT_CONFIG_SYSTEM=/dev/null")
    abort "Git injected config not neutralized" unless run.include?("GIT_CONFIG_COUNT=0")
    abort "Git prompting not disabled" unless run.include?("GIT_TERMINAL_PROMPT=0")
    abort "auditor status is not captured for cleanup" unless run.include?("if /usr/bin/env -i")
    abort "cleanup is not absolute" unless run.include?(%q(/bin/rm -rf -- "$pin_home"))
    abort "auditor failure is not propagated" unless run.include?("*) /usr/bin/false ;;")
    abort "outer shell invokes a shadowable trap" if run.match?(/(?:^|\s)(?:builtin\s+)?trap(?:\s|$)/)
    abort "script Bash is not absolute" unless run.include?("/bin/bash --noprofile --norc")
    abort "tag lookup lacks system config hardening" unless script.include?("GIT_CONFIG_SYSTEM=/dev/null")
    abort "tag lookup lacks injected-config hardening" unless script.include?("GIT_CONFIG_COUNT=0")
  ' "$ROOT/actions/verify-action-pins/action.yml" "$ROOT/scripts/verify-action-pins.sh" \
  >"$TMP/$name.out" 2>&1; then
  record_result "$name" 1
else
  record_result "$name" 0
  sed -n '1,100p' "$TMP/$name.out" | sed 's/^/  /'
fi

printf '%s passed; %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
