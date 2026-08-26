#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-repo-test.XXXXXX")
TMP=$(cd -P "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
HARNESS="$TMP/harness"
TEST_BIN="$HARNESS/.test-bin"
TEST_TOKEN="bootstrap-fixture-$$-$RANDOM"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  printf 'ok %d - %s\n' "$pass" "$1"
}

not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1" >&2
}

mkdir -p "$TMP/input/.github/workflows" "$TMP/input/.github" "$TMP/generated" \
  "$HARNESS/scripts" "$HARNESS/templates" "$TEST_BIN" "$HARNESS/projects"
cp "$ROOT/scripts/bootstrap-repo.sh" "$HARNESS/scripts/bootstrap-repo.sh"
cp "$ROOT/scripts/bootstrap_config_validator.rb" "$HARNESS/scripts/bootstrap_config_validator.rb"
cp "$ROOT/scripts/actions_yaml_inspector.rb" "$HARNESS/scripts/actions_yaml_inspector.rb"
cp "$ROOT/FLEET.md" "$HARNESS/FLEET.md"
cp "$ROOT/templates/claude-review.yml" "$HARNESS/templates/claude-review.yml"
cp "$ROOT/templates/dependabot-auto-merge.yml" "$HARNESS/templates/dependabot-auto-merge.yml"
cp "$ROOT/templates/proprietary-license.txt" "$HARNESS/templates/proprietary-license.txt"
cp "$ROOT/templates/scratch-clone.sh" "$HARNESS/templates/scratch-clone.sh"
printf '%s\n' "$TEST_TOKEN" >"$HARNESS/.bootstrap-test-fixture"
HARNESS_PHYSICAL=$(cd -P "$HARNESS" && pwd -P)

cat >"$TMP/input/AGENTS.md" <<'EOF'
# Fixture - operating contract

The global contract applies. FLEET.md governs the working method.

## Commands

- Verify: `true`

## Gates - CI in order

- Validate repository

## Workflows

- `ci.yml`
- `security.yml`
- `claude-review.yml`
- `dependabot-auto-merge.yml`
EOF

cat >"$TMP/input/README.md" <<'EOF'
# Fixture

Fixture repository.
EOF

cat >"$TMP/input/.gitignore" <<'EOF'
.DS_Store
EOF

cat >"$TMP/input/.github/workflows/ci.yml" <<'EOF'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Validate repository
        run: 'true'
EOF

cat >"$TMP/input/.github/workflows/security.yml" <<'EOF'
name: Security analysis
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  schedule:
    - cron: "17 9 * * 1"
  workflow_dispatch:
permissions:
  actions: read
  contents: read
  pull-requests: read
  security-events: write
jobs:
  semgrep:
    name: Semgrep CE
    runs-on: ubuntu-latest
    timeout-minutes: 15
    if: ${{ github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1' }}
    container:
      image: semgrep/semgrep@sha256:2b33f46ba66cf8cc2ad59ccfa7d22951fd00c632c38f1339e84ec8e6e641a942
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Scan repository content
        run: semgrep scan --config auto --error
  secret-scan:
    name: Secret scan
    runs-on: ubuntu-latest
    timeout-minutes: 10
    if: ${{ github.event_name != 'schedule' || github.event.schedule == '17 9 * * 1' }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e # v3.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - uses: windwardline/windwardline/actions/verify-action-pins@a7df3fb364021d34f501cd1aa3a481f39135c034 # v1.0.0
EOF

cat >"$TMP/input/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: monday
      time: "09:30"
      timezone: America/New_York
    cooldown:
      default-days: 7
    groups:
      github-actions:
        patterns:
          - "*"
EOF

pin_sha=$(sed -n 's#.*verify-action-pins@\([0-9a-f]\{40\}\).*#\1#p' \
  "$TMP/input/.github/workflows/security.yml")

cat >"$TEST_BIN/pin-auditor" <<EOF
#!/bin/sh
[ -z "\${BOOTSTRAP_TEST_PIN_MARKER:-}" ] || /usr/bin/touch "\$BOOTSTRAP_TEST_PIN_MARKER"
[ "\${1:-}" = --latest-release ] || exit 64
printf 'v1.0.0\\t%s\\n' '$pin_sha'
EOF
chmod +x "$TEST_BIN/pin-auditor"

cat >"$TEST_BIN/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
[ "${HOME:-}" = /Users/peacock ] || exit 89
[ "${USER:-}" = peacock ] || exit 89
[ "${GH_CONFIG_DIR:-}" = /Users/peacock/.config/gh ] || exit 89
printf '%s\n' "$*" >>"$BOOTSTRAP_TEST_GH_LOG"
if [[ "$*" == api\ --include\ repos/windwardline/* ]]; then
  if [ "${BOOTSTRAP_TEST_AMBIGUOUS_CREATE:-0}" = 1 ] &&
     [ -f "$BOOTSTRAP_TEST_CREATED_MARKER" ]; then
    printf 'HTTP/2 200 OK\r\n\r\n{"name":"fixture-ambiguous","owner":{"login":"windwardline"}}\n'
    exit 0
  fi
  printf 'HTTP/2 404 Not Found\r\n\r\n{}\n'
  exit 1
fi
case "$1 ${2:-}" in
  'api user') printf 'windwardline\n' ;;
  'api repos/windwardline/fleet-template')
    printf '{"name":"fleet-template","is_template":true,"archived":false,"visibility":"public","default_branch":"main"}\n'
    ;;
  'api repos/windwardline/windwardline/commits/main')
    printf '%s\n' "${BOOTSTRAP_TEST_REMOTE_MAIN:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    ;;
  'api repos/windwardline/windwardline/git/trees/a7df3fb364021d34f501cd1aa3a481f39135c034?recursive=1')
    if [ "${BOOTSTRAP_TEST_RELEASE_PATH_MISSING:-0}" = 1 ]; then
      printf '%s\n' '{"sha":"a7df3fb364021d34f501cd1aa3a481f39135c034","truncated":false,"tree":[{"path":"actions/verify-action-pins/action.yml","type":"blob"},{"path":"scripts/verify-action-pins.sh","type":"blob"},{"path":"scripts/actions_yaml_inspector.rb","type":"blob"},{"path":"actions/verify-live-headers/action.yml","type":"blob"},{"path":"actions/verify-live-headers/verify-live-headers.sh","type":"blob"},{"path":"actions/verify-ghost-managed-edge/action.yml","type":"blob"}]}'
    else
      printf '%s\n' '{"sha":"a7df3fb364021d34f501cd1aa3a481f39135c034","truncated":false,"tree":[{"path":"actions/verify-action-pins/action.yml","type":"blob"},{"path":"scripts/verify-action-pins.sh","type":"blob"},{"path":"scripts/actions_yaml_inspector.rb","type":"blob"},{"path":"actions/verify-live-headers/action.yml","type":"blob"},{"path":"actions/verify-live-headers/verify-live-headers.sh","type":"blob"},{"path":"actions/verify-ghost-managed-edge/action.yml","type":"blob"},{"path":"actions/verify-ghost-managed-edge/verify-ghost-managed-edge.sh","type":"blob"}]}'
    fi
    ;;
  'api apps/github-actions') printf '{"id":15368,"slug":"github-actions","name":"GitHub Actions"}\n' ;;
  'repo view')
    if [ "${BOOTSTRAP_TEST_AMBIGUOUS_CREATE:-0}" = 1 ] &&
       [ -f "$BOOTSTRAP_TEST_CREATED_MARKER" ]; then
      printf '{"nameWithOwner":"windwardline/fixture-ambiguous","url":"https://github.com/windwardline/fixture-ambiguous"}\n'
    else
      exit 1
    fi
    ;;
  'run list')
    printf '[{"databaseId":99,"status":"completed","conclusion":"success"}]\n'
    ;;
  'run view') printf 'repository_selection=all, 17 repositories reachable.\n' ;;
  'repo create')
    if [ -n "${BOOTSTRAP_TEST_MUTATE_SOURCE:-}" ]; then
      cp "$BOOTSTRAP_TEST_MUTATE_REPLACEMENT" "$BOOTSTRAP_TEST_MUTATE_SOURCE"
    fi
    if [ "${BOOTSTRAP_TEST_AMBIGUOUS_CREATE:-0}" = 1 ]; then
      /usr/bin/touch "$BOOTSTRAP_TEST_CREATED_MARKER"
      exit 87
    fi
    ;;
  'secret set')
    [ "${BOOTSTRAP_TEST_FAIL_SECRET:-0}" != 1 ] || exit 88
    bytes=$(wc -c | tr -d ' ')
    printf 'secret-input %s bytes=%s\n' "$*" "$bytes" >>"$BOOTSTRAP_TEST_GH_LOG"
    ;;
  'api -X')
    if [[ "$*" == *'/rulesets'* ]]; then
      input=''
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --input ]; then input=$2; break; fi
        shift
      done
      [ -n "$input" ] || exit 96
      cp "$input" "$BOOTSTRAP_TEST_RULESET"
      printf '77\n'
    elif [[ "$*" == *'/automated-security-fixes'* ]]; then
      printf '{"enabled":true}\n'
    fi
    ;;
  'repo edit') ;;
  'pr create')
    repo=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --repo ]; then repo=$2; break; fi
      shift
    done
    [ -n "$repo" ] || exit 96
    printf 'https://github.com/%s/pull/1\n' "$repo"
    ;;
  'pr merge') ;;
  'pr view')
    printf '{"state":"MERGED","mergedAt":"2026-08-22T00:00:00Z","headRefOid":"%s","mergeCommit":{"oid":"%s"}}\n' \
      "${BOOTSTRAP_TEST_PR_HEAD:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
      "${BOOTSTRAP_TEST_MERGE_COMMIT:-cccccccccccccccccccccccccccccccccccccccc}"
    ;;
  'secret list')
    if [[ "$*" == *'--app dependabot'* ]]; then
      printf '[{"name":"FLEET_AUTOMERGE_APP_ID"},{"name":"FLEET_AUTOMERGE_PRIVATE_KEY"}]\n'
    else
      printf '[{"name":"CLAUDE_CODE_OAUTH_TOKEN"}]\n'
    fi
    ;;
  'api --paginate')
    if [[ "$*" == *'/check-runs?'* ]]; then
      if [ "${BOOTSTRAP_TEST_BAD_ADVISORY:-0}" = 1 ]; then
        printf '[{"check_runs":[{"name":"verify","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"Semgrep CE","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"Secret scan","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"review","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"dependabot-auto-merge","status":"completed","conclusion":"skipped","app":{"id":15368}}]}]\n'
      elif [[ "$*" == *'fixture-production'* ]]; then
        printf '[{"check_runs":[{"name":"verify","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"Semgrep CE","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"Secret scan","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"Headers live","status":"completed","conclusion":"skipped","app":{"id":15368}},{"name":"review / gate","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"review / review","status":"completed","conclusion":"skipped","app":{"id":15368}},{"name":"dependabot-auto-merge","status":"completed","conclusion":"skipped","app":{"id":15368}}]}]\n'
      else
        printf '[{"check_runs":[{"name":"verify","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"Semgrep CE","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"Secret scan","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"review / gate","status":"completed","conclusion":"success","app":{"id":15368}},{"name":"review / review","status":"completed","conclusion":"skipped","app":{"id":15368}},{"name":"dependabot-auto-merge","status":"completed","conclusion":"skipped","app":{"id":15368}}]}]\n'
      fi
    elif [[ "$*" == *'/rulesets?'* ]]; then
      printf '0\n'
    else
      exit 95
    fi
    ;;
  api\ repos/windwardline/fixture-*)
    if [[ "$*" == *'/commits/main'* ]]; then
      printf '%s\n' "${BOOTSTRAP_TEST_MERGE_COMMIT:-cccccccccccccccccccccccccccccccccccccccc}"
    elif [[ "$*" == *'/rulesets/77'* ]]; then
      jq '. + {id:77}' "$BOOTSTRAP_TEST_RULESET"
    elif [[ "$*" == *'/automated-security-fixes'* ]]; then
      printf '{"enabled":true}\n'
    elif [[ "$*" == *'/private-vulnerability-reporting'* ]]; then
      printf '{"enabled":true}\n'
    elif [[ "$*" == *'/vulnerability-alerts'* ]]; then
      :
    else
      endpoint=${2#repos/}
      endpoint_owner=${endpoint%%/*}
      endpoint_repo=${endpoint#*/}
      endpoint_repo=${endpoint_repo%%/*}
      printf '{"full_name":"%s/%s","archived":false,"default_branch":"main","allow_auto_merge":true,"visibility":"public"}\n' \
        "$endpoint_owner" "$endpoint_repo"
    fi
    ;;
  *) printf 'unexpected mock gh call: %s\n' "$*" >&2; exit 97 ;;
esac
EOF
chmod +x "$TEST_BIN/gh"

cat >"$TEST_BIN/security" <<'EOF'
#!/bin/sh
case " $* " in
  *' -a peacock '*) ;;
  *) exit 92 ;;
esac
service=''
want_value=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s) service=$2; shift 2 ;;
    -w) want_value=1; shift ;;
    *) shift ;;
  esac
done
if [ "$want_value" -eq 1 ]; then
  if [ "$service" = github-automerge-app-key ]; then
    /bin/cat "$BOOTSTRAP_TEST_APP_KEY_B64"
    printf '\n'
  else
    printf '%s\n' 'TEST_SECRET_SENTINEL_9d8a'
  fi
fi
exit 0
EOF
chmod +x "$TEST_BIN/security"

/usr/bin/ruby -ropenssl -rbase64 -e '
  key = OpenSSL::PKey::RSA.generate(2048)
  print Base64.strict_encode64(key.to_pem)
' >"$TMP/test-app-key.b64"

cat >"$TEST_BIN/git" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$BOOTSTRAP_TEST_GIT_LOG"
[ "${GIT_CONFIG_GLOBAL:-}" = /dev/null ] || exit 90
[ "${GIT_CONFIG_NOSYSTEM:-}" = 1 ] || exit 90
[ "${GIT_NO_REPLACE_OBJECTS:-}" = 1 ] || exit 90
[ "${GIT_ATTR_NOSYSTEM:-}" = 1 ] || exit 90
[ "${GIT_LITERAL_PATHSPECS:-}" = 1 ] || exit 90
[ -z "${GIT_CONFIG_COUNT:-}" ] || exit 90
[ -z "${GIT_CONFIG_PARAMETERS:-}" ] || exit 90
[ -z "${GIT_EXEC_PATH:-}" ] && [ -z "${GIT_TEMPLATE_DIR:-}" ] || exit 90
[ -z "${BASH_ENV:-}" ] && [ -z "${ENV:-}" ] || exit 90
[ -z "${RUBYOPT:-}" ] && [ -z "${RUBYLIB:-}" ] || exit 90
[ -z "${LD_AUDIT:-}" ] && [ -z "${GLIBC_TUNABLES:-}" ] || exit 90
[ -z "${DYLD_FRAMEWORK_PATH:-}" ] && [ -z "${DYLD_PRINT_TO_FILE:-}" ] || exit 90
while [ "${1:-}" = -c ]; do
  [ "$#" -ge 2 ] || exit 91
  shift 2
done
if [ "$1" = clone ]; then
  destination=$3
  mkdir -p "$destination/.git"
  cp -R "$BOOTSTRAP_TEST_TEMPLATE/." "$destination/"
  printf '%s\n' "$2" >"$destination/.git/mock-origin"
  exit 0
fi
if [ "$1" = -C ]; then
  destination=$2
  shift 2
  if [ "$destination" = "$BOOTSTRAP_TEST_SOURCE_ROOT" ]; then
    case "$1 ${2:-}" in
      'remote get-url') printf 'https://github.com/windwardline/windwardline.git\n' ;;
      'symbolic-ref --quiet') printf '%s\n' "${BOOTSTRAP_TEST_SOURCE_BRANCH:-main}" ;;
      'status --porcelain') printf '%s' "${BOOTSTRAP_TEST_SOURCE_DIRTY:-}" ;;
      'rev-parse HEAD') printf '%s\n' "${BOOTSTRAP_TEST_SOURCE_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
      *) printf 'unexpected source mock git call: %s\n' "$*" >&2; exit 94 ;;
    esac
    exit 0
  fi
  case "$1 ${2:-}" in
    'remote get-url') cat "$destination/.git/mock-origin" ;;
    'status --porcelain') ;;
    'switch -c'|'switch main'|'add --force'|'commit -m'|'push -u'|'fetch --prune'|'pull --ff-only'|'branch -D') ;;
    'for-each-ref --format=%(refname)') ;;
    'diff --cached') exit 1 ;;
    'diff --quiet') [ "${BOOTSTRAP_TEST_TREE_MISMATCH:-0}" != 1 ] ;;
    'rev-parse HEAD'|'rev-parse origin/main') printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
    *) printf 'unexpected mock git call: %s\n' "$*" >&2; exit 94 ;;
  esac
  exit 0
fi
printf 'unexpected mock git call: %s\n' "$*" >&2
exit 94
EOF
chmod +x "$TEST_BIN/git"

cat >"$TEST_BIN/conformance" <<'EOF'
#!/bin/sh
printf 'fleet conformance invoked\n' >>"$BOOTSTRAP_TEST_GH_LOG"
printf 'fixture conformant\n'
EOF
chmod +x "$TEST_BIN/conformance"

cat >"$TEST_BIN/header-probe" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] || exit 93
[ "$1" = 'https://fixture.example.com' ] || exit 93
[ "$2" = bootstrap ] || exit 93
printf 'header probe invoked\n' >>"$BOOTSTRAP_TEST_GH_LOG"
EOF
chmod +x "$TEST_BIN/header-probe"

cat >"$TEST_BIN/gitleaks" <<'EOF'
#!/bin/sh
printf 'gitleaks %s\n' "$*" >>"$BOOTSTRAP_TEST_GH_LOG"
if [ "${BOOTSTRAP_TEST_GITLEAKS_FAIL:-0}" = 1 ]; then
  printf 'synthetic gitleaks finding\n' >&2
  exit 1
fi
if [ "${BOOTSTRAP_TEST_GITLEAKS_VACUOUS:-0}" = 1 ]; then
  printf 'INF scanned ~0 bytes (0) in 1ms\n' >&2
else
  printf 'INF scanned ~1 KB (1024 bytes) in 1ms\n' >&2
fi
EOF
chmod +x "$TEST_BIN/gitleaks"

cat >"$TEST_BIN/github-app-key-verifier.rb" <<'RUBY'
# frozen_string_literal: true

require "base64"
require "openssl"

begin
  encoded = STDIN.binmode.read
  encoded = encoded.sub(/\r?\n\z/, "")
  decoded = Base64.strict_decode64(encoded)
  key = OpenSSL::PKey.read(decoded, "")
  exit 1 unless key.is_a?(OpenSSL::PKey::RSA) && key.private?
  if ARGV == ["--emit-pem"]
    STDOUT.binmode
    STDOUT.write(decoded)
  elsif !ARGV.empty?
    exit 1
  end
  exit 0
rescue ArgumentError, OpenSSL::PKey::PKeyError
  exit 1
end
RUBY

make_manifest() {
  local output=$1 visibility=${2:-public} repo=${3:-fixture-new}
  jq -n \
    --arg repo "$repo" \
    --arg visibility "$visibility" \
    --arg input "$TMP/input" \
    '{
      repository: $repo,
      display_name: "Fixture New",
      description: "Fixture bootstrap repository.",
      visibility: $visibility,
      production_url: null,
      automerge_app_id: 4562963,
      ci_gates: ["Validate repository"],
      required_checks: ["verify", "Semgrep CE", "Secret scan"],
      lockfiles: [],
      header_contract_tests: [],
      files: {
        "AGENTS.md": ($input + "/AGENTS.md"),
        "README.md": ($input + "/README.md"),
        ".gitignore": ($input + "/.gitignore"),
        ".github/workflows/ci.yml": ($input + "/.github/workflows/ci.yml"),
        ".github/workflows/security.yml": ($input + "/.github/workflows/security.yml"),
        ".github/dependabot.yml": ($input + "/.github/dependabot.yml")
      }
    }' >"$output"
}

make_production_manifest() {
  local output=$1 repo=${2:-fixture-production}
  local ci="$TMP/generated/ci-$repo.yml"
  local security="$TMP/generated/security-$repo.yml"
  local vercel="$TMP/generated/vercel-$repo.json"
  local header="$TMP/generated/header-$repo.test"
  local agents="$TMP/generated/agents-$repo.md"
  sed '/^- Validate repository$/a\
- Header contract' "$TMP/input/AGENTS.md" >"$agents"
  cp "$TMP/input/.github/workflows/ci.yml" "$ci"
  sed -i '' "/        run: 'true'/a\\
      - name: Header contract\\
        run: node header-contract.test" "$ci"
  sed 's/    - cron: "17 9 \* \* 1".*/&\
    - cron: "17 13 * * *"/' \
    "$TMP/input/.github/workflows/security.yml" >"$security"
  cat >>"$security" <<EOF

  headers-live:
    name: Headers live
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    timeout-minutes: 12
    steps:
      - name: Assert the seven security headers on production
        uses: windwardline/windwardline/actions/verify-live-headers@$pin_sha # v1.0.0
        with:
          url: https://fixture.example.com
EOF
  cat >"$vercel" <<'EOF'
{"headers":[{"source":"/(.*)","headers":[
  {"key":"Content-Security-Policy","value":"default-src 'self'"},
  {"key":"Strict-Transport-Security","value":"max-age=63072000"},
  {"key":"X-Content-Type-Options","value":"nosniff"},
  {"key":"Referrer-Policy","value":"strict-origin-when-cross-origin"},
  {"key":"X-Frame-Options","value":"DENY"},
  {"key":"Permissions-Policy","value":"camera=()"},
  {"key":"Cross-Origin-Opener-Policy","value":"same-origin"}
]}]}
EOF
  printf 'header contract fixture\n' >"$header"
  jq -n \
    --arg repo "$repo" \
    --arg input "$TMP/input" \
    --arg ci "$ci" \
    --arg security "$security" \
    --arg vercel "$vercel" \
    --arg header "$header" \
    --arg agents "$agents" \
    '{
      repository: $repo,
      display_name: "Fixture Production",
      description: "Fixture production bootstrap repository.",
      visibility: "public",
      production_url: "https://fixture.example.com",
      automerge_app_id: 4562963,
      ci_gates: ["Validate repository", "Header contract"],
      required_checks: ["verify", "Semgrep CE", "Secret scan"],
      lockfiles: [],
      header_contract_tests: ["header-contract.test"],
      files: {
        "AGENTS.md": $agents,
        "README.md": ($input + "/README.md"),
        ".gitignore": ($input + "/.gitignore"),
        "vercel.json": $vercel,
        "header-contract.test": $header,
        ".github/workflows/ci.yml": $ci,
        ".github/workflows/security.yml": $security,
        ".github/dependabot.yml": ($input + "/.github/dependabot.yml")
      }
    }' >"$output"
}

run_bootstrap() {
  env \
    BOOTSTRAP_TEST_MODE=1 \
    BOOTSTRAP_TEST_TOKEN="$TEST_TOKEN" \
    BOOTSTRAP_TEST_GH_LOG="$TMP/gh.log" \
    BOOTSTRAP_TEST_GIT_LOG="$TMP/git.log" \
    BOOTSTRAP_TEST_RULESET="$TMP/ruleset.json" \
    BOOTSTRAP_TEST_SOURCE_ROOT="$HARNESS_PHYSICAL" \
    BOOTSTRAP_TEST_SOURCE_BRANCH="${BOOTSTRAP_TEST_SOURCE_BRANCH:-main}" \
    BOOTSTRAP_TEST_SOURCE_DIRTY="${BOOTSTRAP_TEST_SOURCE_DIRTY:-}" \
    BOOTSTRAP_TEST_SOURCE_HEAD="${BOOTSTRAP_TEST_SOURCE_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
    BOOTSTRAP_TEST_REMOTE_MAIN="${BOOTSTRAP_TEST_REMOTE_MAIN:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
    BOOTSTRAP_TEST_TEMPLATE="${BOOTSTRAP_TEST_TEMPLATE_OVERRIDE:-$TMP/input}" \
    BOOTSTRAP_TEST_APP_KEY_B64="${BOOTSTRAP_TEST_APP_KEY_B64_OVERRIDE:-$TMP/test-app-key.b64}" \
    BOOTSTRAP_TEST_FAIL_SECRET="${BOOTSTRAP_TEST_FAIL_SECRET:-0}" \
    BOOTSTRAP_TEST_GITLEAKS_FAIL="${BOOTSTRAP_TEST_GITLEAKS_FAIL:-0}" \
    BOOTSTRAP_TEST_GITLEAKS_VACUOUS="${BOOTSTRAP_TEST_GITLEAKS_VACUOUS:-0}" \
    BOOTSTRAP_TEST_PR_HEAD="${BOOTSTRAP_TEST_PR_HEAD:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
    BOOTSTRAP_TEST_MERGE_COMMIT="${BOOTSTRAP_TEST_MERGE_COMMIT:-cccccccccccccccccccccccccccccccccccccccc}" \
    BOOTSTRAP_TEST_TREE_MISMATCH="${BOOTSTRAP_TEST_TREE_MISMATCH:-0}" \
    BOOTSTRAP_TEST_MUTATE_SOURCE="${BOOTSTRAP_TEST_MUTATE_SOURCE:-}" \
    BOOTSTRAP_TEST_MUTATE_REPLACEMENT="${BOOTSTRAP_TEST_MUTATE_REPLACEMENT:-}" \
    BOOTSTRAP_TEST_BAD_ADVISORY="${BOOTSTRAP_TEST_BAD_ADVISORY:-0}" \
    BOOTSTRAP_TEST_PIN_MARKER="${BOOTSTRAP_TEST_PIN_MARKER:-}" \
    BOOTSTRAP_TEST_RELEASE_PATH_MISSING="${BOOTSTRAP_TEST_RELEASE_PATH_MISSING:-0}" \
    BOOTSTRAP_TEST_AMBIGUOUS_CREATE="${BOOTSTRAP_TEST_AMBIGUOUS_CREATE:-0}" \
    BOOTSTRAP_TEST_CREATED_MARKER="$TMP/ambiguous-created" \
    "$HARNESS/scripts/bootstrap-repo.sh" "$@"
}

make_manifest "$TMP/public.json"
: >"$TMP/gh.log"
if run_bootstrap --dry-run --manifest "$TMP/public.json" >"$TMP/public.out" 2>&1 &&
   grep -q 'Preflight complete.*PUBLIC' "$TMP/public.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'dry-run validates a public bootstrap without mutation'
else
  not_ok 'dry-run validates a public bootstrap without mutation'
  cat "$TMP/public.out" >&2
fi

: >"$TMP/gh.log"
rm -f "$TMP/untrusted-pin-ran"
if ! BOOTSTRAP_TEST_SOURCE_BRANCH='feature/unreleased' \
     BOOTSTRAP_TEST_PIN_MARKER="$TMP/untrusted-pin-ran" \
     run_bootstrap --dry-run --manifest "$TMP/public.json" >"$TMP/source-branch.out" 2>&1 &&
   grep -q 'source must be on main' "$TMP/source-branch.out" &&
   [ ! -e "$TMP/untrusted-pin-ran" ] &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'a feature-branch bootstrap source fails before executing mutable repository code'
else
  not_ok 'a feature-branch bootstrap source fails before executing mutable repository code'
  cat "$TMP/source-branch.out" >&2
fi

: >"$TMP/gh.log"
if ! BOOTSTRAP_TEST_RELEASE_PATH_MISSING=1 \
     run_bootstrap --dry-run --manifest "$TMP/public.json" >"$TMP/release-path.out" 2>&1 &&
   grep -q 'release.*action path' "$TMP/release-path.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'the release commit must contain every action path the bootstrap publishes'
else
  not_ok 'the release commit must contain every action path the bootstrap publishes'
  cat "$TMP/release-path.out" >&2
fi

: >"$TMP/gh.log"
if ! BOOTSTRAP_TEST_REMOTE_MAIN='cccccccccccccccccccccccccccccccccccccccc' \
     run_bootstrap --dry-run --manifest "$TMP/public.json" >"$TMP/source-stale.out" 2>&1 &&
   grep -q 'source main is stale relative to GitHub' "$TMP/source-stale.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'a stale bootstrap source fails before mutation'
else
  not_ok 'a stale bootstrap source fails before mutation'
  cat "$TMP/source-stale.out" >&2
fi

make_manifest "$TMP/private.json" private private-fixture
: >"$TMP/gh.log"
if run_bootstrap --dry-run --manifest "$TMP/private.json" >"$TMP/private.out" 2>&1 &&
   grep -q 'Reservation required: add private-fixture' "$TMP/private.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'dry-run validates an unregistered private plan and names the required reservation'
else
  not_ok 'dry-run validates an unregistered private plan and names the required reservation'
  cat "$TMP/private.out" >&2
fi

: >"$TMP/gh.log"
if ! run_bootstrap --manifest "$TMP/private.json" >"$TMP/private-apply.out" 2>&1 &&
   grep -q 'private-by-design register' "$TMP/private-apply.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'apply refuses an unregistered private repository before mutation'
else
  not_ok 'apply refuses an unregistered private repository before mutation'
  cat "$TMP/private-apply.out" >&2
fi

jq '.required_checks += ["dependabot-auto-merge"]' "$TMP/public.json" >"$TMP/reserved.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/reserved.json" >"$TMP/reserved.out" 2>&1 &&
   grep -q 'dependabot-auto-merge.*must never be required' "$TMP/reserved.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'the auto-merge lane cannot enter the ruleset'
else
  not_ok 'the auto-merge lane cannot enter the ruleset'
  cat "$TMP/reserved.out" >&2
fi

jq '.required_checks += ["Headers live"]' "$TMP/public.json" >"$TMP/header-required.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/header-required.json" >"$TMP/header-required.out" 2>&1 &&
   grep -q 'Headers live.*must never be required' "$TMP/header-required.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'the push-and-daily header probe cannot enter the pull-request ruleset'
else
  not_ok 'the push-and-daily header probe cannot enter the pull-request ruleset'
  cat "$TMP/header-required.out" >&2
fi

cat >"$TMP/extra-workflow.yml" <<'EOF'
name: Extra
on: push
permissions:
  contents: read
jobs:
  extra:
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
EOF
jq --arg extra "$TMP/extra-workflow.yml" \
  '.files[".github/workflows/extra.yml"] = $extra' \
  "$TMP/public.json" >"$TMP/extra-workflow.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/extra-workflow.json" >"$TMP/extra-workflow.out" 2>&1 &&
   grep -q 'cannot add bootstrap-time workflow' "$TMP/extra-workflow.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'caller-supplied extra workflows fail before mutation'
else
  not_ok 'caller-supplied extra workflows fail before mutation'
  cat "$TMP/extra-workflow.out" >&2
fi

sed "s#run: 'true'#env:\n          EXFILTRATE: \${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}\n        run: 'true'#" \
  "$TMP/input/.github/workflows/ci.yml" >"$TMP/ci-secret.yml"
jq --arg source "$TMP/ci-secret.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/public.json" >"$TMP/secret-context.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/secret-context.json" >"$TMP/secret-context.out" 2>&1 &&
   grep -q 'ci.yml cannot reference a credential-bearing Actions context' \
     "$TMP/secret-context.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'caller-supplied workflows cannot reference the Actions secrets context'
else
  not_ok 'caller-supplied workflows cannot reference the Actions secrets context'
  cat "$TMP/secret-context.out" >&2
fi

sed "s#run: 'true'#env:\n          EXFILTRATE: \${{ fromJSON(toJSON(github)).token }}\n        run: 'true'#" \
  "$TMP/input/.github/workflows/ci.yml" >"$TMP/ci-indirect-token.yml"
jq --arg source "$TMP/ci-indirect-token.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/public.json" >"$TMP/indirect-token.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/indirect-token.json" >"$TMP/indirect-token.out" 2>&1 &&
   grep -q 'ci.yml cannot reference a credential-bearing Actions context' \
     "$TMP/indirect-token.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'indirect serialization cannot hide the GitHub token context'
else
  not_ok 'indirect serialization cannot hide the GitHub token context'
  cat "$TMP/indirect-token.out" >&2
fi

ln -s "$TMP" "$TMP/manifest-parent-link"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/manifest-parent-link/public.json" \
     >"$TMP/manifest-parent-link.out" 2>&1 &&
   grep -Eiq 'manifest path.*symlink' "$TMP/manifest-parent-link.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'the manifest path cannot traverse a symlinked parent'
else
  not_ok 'the manifest path cannot traverse a symlinked parent'
  cat "$TMP/manifest-parent-link.out" >&2
fi

jq --arg outside /etc/hosts \
  '.files["README.md"] = $outside' \
  "$TMP/public.json" >"$TMP/outside-source.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/outside-source.json" >"$TMP/outside-source.out" 2>&1 &&
   grep -Eiq 'source.*manifest|manifest.*source' "$TMP/outside-source.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'file sources outside the manifest root fail before mutation'
else
  not_ok 'file sources outside the manifest root fail before mutation'
  cat "$TMP/outside-source.out" >&2
fi

ln -s /etc "$TMP/source-escape"
jq --arg escaped "$TMP/source-escape/hosts" \
  '.files["README.md"] = $escaped' \
  "$TMP/public.json" >"$TMP/symlink-source.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/symlink-source.json" >"$TMP/symlink-source.out" 2>&1 &&
   grep -Eiq 'source.*(symlink|manifest)|symlink.*source' "$TMP/symlink-source.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'file sources cannot escape the manifest root through a symlinked ancestor'
else
  not_ok 'file sources cannot escape the manifest root through a symlinked ancestor'
  cat "$TMP/symlink-source.out" >&2
fi

jq --arg source "$TMP/input/.gitignore" \
  '.files[".GIT/config"] = $source' \
  "$TMP/public.json" >"$TMP/dot-git-case.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/dot-git-case.json" >"$TMP/dot-git-case.out" 2>&1 &&
   grep -q 'unsafe repository path' "$TMP/dot-git-case.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'case-insensitive .git aliases cannot enter the generated repository'
else
  not_ok 'case-insensitive .git aliases cannot enter the generated repository'
  cat "$TMP/dot-git-case.out" >&2
fi

jq --arg source "$TMP/input/.gitignore" \
  '.files["scripts/scratch-clone.sh"] = $source' \
  "$TMP/public.json" >"$TMP/scratch-replacement.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/scratch-replacement.json" \
     >"$TMP/scratch-replacement.out" 2>&1 &&
   grep -q 'cannot replace bootstrap-controlled target scripts/scratch-clone.sh' \
     "$TMP/scratch-replacement.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'caller files cannot replace the canonical scratch-clone helper'
else
  not_ok 'caller files cannot replace the canonical scratch-clone helper'
  cat "$TMP/scratch-replacement.out" >&2
fi

gitleaks_targets_rejected=1
gitleaks_target_outputs=''
for target in .gitleaks.toml .gitleaksignore; do
  suffix=$(printf '%s' "$target" | tr -cd '[:alnum:]')
  jq --arg target "$target" --arg source "$TMP/input/.gitignore" \
    '.files[$target] = $source' \
    "$TMP/public.json" >"$TMP/gitleaks-target-$suffix.json"
  : >"$TMP/gh.log"
  if run_bootstrap --dry-run --manifest "$TMP/gitleaks-target-$suffix.json" \
       >"$TMP/gitleaks-target-$suffix.out" 2>&1 ||
     ! grep -Eiq 'gitleaks|secret.*(control|ignore|config)|scanner.*(control|ignore|config)' \
       "$TMP/gitleaks-target-$suffix.out" ||
     grep -q 'repo create' "$TMP/gh.log"; then
    gitleaks_targets_rejected=0
    gitleaks_target_outputs="$gitleaks_target_outputs $TMP/gitleaks-target-$suffix.out"
  fi
done
if [ "$gitleaks_targets_rejected" -eq 1 ]; then
  ok 'caller files cannot install gitleaks configuration or ignore controls'
else
  not_ok 'caller files cannot install gitleaks configuration or ignore controls'
  for output in $gitleaks_target_outputs; do cat "$output" >&2; done
fi

sed "/      - name: Validate repository/a\\
        if: false" "$TMP/input/.github/workflows/ci.yml" >"$TMP/ci-skipped-gate.yml"
jq --arg source "$TMP/ci-skipped-gate.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/public.json" >"$TMP/skipped-gate.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/skipped-gate.json" >"$TMP/skipped-gate.out" 2>&1 &&
   grep -q 'ci_gates entry "Validate repository" cannot be skipped, ignored, or override its shell' \
     "$TMP/skipped-gate.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'a named CI gate cannot be conditionally skipped'
else
  not_ok 'a named CI gate cannot be conditionally skipped'
  cat "$TMP/skipped-gate.out" >&2
fi

sed "/      - name: Validate repository/a\\
        continue-on-error: true" "$TMP/input/.github/workflows/ci.yml" \
  >"$TMP/ci-continue-gate.yml"
jq --arg source "$TMP/ci-continue-gate.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/public.json" >"$TMP/continue-gate.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/continue-gate.json" >"$TMP/continue-gate.out" 2>&1 &&
   grep -q 'ci_gates entry "Validate repository" cannot be skipped, ignored, or override its shell' \
     "$TMP/continue-gate.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'a named CI gate cannot continue after failure'
else
  not_ok 'a named CI gate cannot continue after failure'
  cat "$TMP/continue-gate.out" >&2
fi

sed "/      - name: Validate repository/a\\
        shell: true {0}" "$TMP/input/.github/workflows/ci.yml" >"$TMP/ci-shell-bypass.yml"
jq --arg source "$TMP/ci-shell-bypass.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/public.json" >"$TMP/shell-bypass.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/shell-bypass.json" >"$TMP/shell-bypass.out" 2>&1 &&
   grep -q 'override its shell' "$TMP/shell-bypass.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'a named CI gate cannot replace its execution shell with a false-green template'
else
  not_ok 'a named CI gate cannot replace its execution shell with a false-green template'
  cat "$TMP/shell-bypass.out" >&2
fi

cp "$TMP/input/.github/workflows/ci.yml" "$TMP/ci-vacuous-job.yml"
cat >>"$TMP/ci-vacuous-job.yml" <<'EOF'
  vacuous:
    name: vacuous
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Never runs
        if: false
        run: exit 99
EOF
jq --arg source "$TMP/ci-vacuous-job.yml" \
  '.files[".github/workflows/ci.yml"] = $source | .required_checks += ["vacuous"]' \
  "$TMP/public.json" >"$TMP/vacuous-job.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/vacuous-job.json" >"$TMP/vacuous-job.out" 2>&1 &&
   grep -q 'ci_gates must equal the ordered unconditional run-step population' "$TMP/vacuous-job.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'every CI run step is declared before a context can be treated as audited'
else
  not_ok 'every CI run step is declared before a context can be treated as audited'
  cat "$TMP/vacuous-job.out" >&2
fi

make_production_manifest "$TMP/header-not-executed.json" fixture-header-not-executed
header_contract_ci=$(jq -r '.files[".github/workflows/ci.yml"]' \
  "$TMP/header-not-executed.json")
sed "s/run: node header-contract.test/run: 'true'/" \
  "$header_contract_ci" >"$TMP/ci-header-not-executed.yml"
jq --arg source "$TMP/ci-header-not-executed.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/header-not-executed.json" >"$TMP/header-not-executed-final.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/header-not-executed-final.json" \
     >"$TMP/header-not-executed.out" 2>&1 &&
   grep -Eiq 'header contract.*(only|canonical|execute|reference|header-contract\.test)' \
     "$TMP/header-not-executed.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'a declared header-contract test must be executed by its named gate'
else
  not_ok 'a declared header-contract test must be executed by its named gate'
  cat "$TMP/header-not-executed.out" >&2
fi

sed "s/run: node header-contract.test/run: |\n          # node header-contract.test\n          true/" \
  "$header_contract_ci" >"$TMP/ci-header-comment-only.yml"
jq --arg source "$TMP/ci-header-comment-only.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/header-not-executed.json" >"$TMP/header-comment-only.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/header-comment-only.json" \
     >"$TMP/header-comment-only.out" 2>&1 &&
   grep -Eiq 'header contract.*(only|canonical|execute).*' \
     "$TMP/header-comment-only.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'a shell comment cannot impersonate header-contract execution'
else
  not_ok 'a shell comment cannot impersonate header-contract execution'
  cat "$TMP/header-comment-only.out" >&2
fi

sed "s/run: node header-contract.test/run: |\n          exit 0\n          node header-contract.test/" \
  "$header_contract_ci" >"$TMP/ci-header-unreachable.yml"
jq --arg source "$TMP/ci-header-unreachable.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/header-not-executed.json" >"$TMP/header-unreachable.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/header-unreachable.json" \
     >"$TMP/header-unreachable.out" 2>&1 &&
   grep -Eiq 'Header contract.*(only|exact|reachable|command)' "$TMP/header-unreachable.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'an unreachable header-contract invocation is not execution evidence'
else
  not_ok 'an unreachable header-contract invocation is not execution evidence'
  cat "$TMP/header-unreachable.out" >&2
fi

cp "$TMP/input/.github/workflows/ci.yml" "$TMP/ci-undeclared-gate.yml"
sed -i '' "/      - name: Validate repository/i\\
      - name: Undeclared lint\\
        run: 'true'" "$TMP/ci-undeclared-gate.yml"
jq --arg source "$TMP/ci-undeclared-gate.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/public.json" >"$TMP/undeclared-gate.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/undeclared-gate.json" \
     >"$TMP/undeclared-gate.out" 2>&1 &&
   grep -q 'ci_gates must equal the ordered unconditional run-step population' \
     "$TMP/undeclared-gate.out"; then
  ok 'ci_gates is the exact workflow run-step population, not a curated subset'
else
  not_ok 'ci_gates is the exact workflow run-step population, not a curated subset'
  cat "$TMP/undeclared-gate.out" >&2
fi

sed '/^- Validate repository$/d' "$TMP/input/AGENTS.md" >"$TMP/agents-missing-gate.md"
jq --arg agents "$TMP/agents-missing-gate.md" \
  '.files["AGENTS.md"] = $agents' "$TMP/public.json" >"$TMP/agents-missing-gate.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/agents-missing-gate.json" \
     >"$TMP/agents-missing-gate.out" 2>&1 &&
   grep -q 'AGENTS.md.*ordered CI gates' "$TMP/agents-missing-gate.out"; then
  ok 'AGENTS.md gate enumeration must equal ci_gates'
else
  not_ok 'AGENTS.md gate enumeration must equal ci_gates'
  cat "$TMP/agents-missing-gate.out" >&2
fi

cp "$TMP/input/.github/workflows/security.yml" "$TMP/security-extra-job.yml"
cat >>"$TMP/security-extra-job.yml" <<'EOF'
  unexpected:
    name: Unexpected security job
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
EOF
jq --arg source "$TMP/security-extra-job.yml" \
  '.files[".github/workflows/security.yml"] = $source' \
  "$TMP/public.json" >"$TMP/security-extra-job.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/security-extra-job.json" \
     >"$TMP/security-extra-job.out" 2>&1 &&
   grep -q 'security.yml jobs must equal the ordered canonical job set' \
     "$TMP/security-extra-job.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'security.yml cannot add an unmeasured job'
else
  not_ok 'security.yml cannot add an unmeasured job'
  cat "$TMP/security-extra-job.out" >&2
fi

sed '/  semgrep:/a\
    permissions: write-all' "$TMP/input/.github/workflows/security.yml" \
  >"$TMP/security-write-all.yml"
jq --arg source "$TMP/security-write-all.yml" \
  '.files[".github/workflows/security.yml"] = $source' \
  "$TMP/public.json" >"$TMP/security-write-all.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/security-write-all.json" \
     >"$TMP/security-write-all.out" 2>&1 &&
   grep -q 'canonical live Semgrep CE job' "$TMP/security-write-all.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'canonical security jobs cannot widen their inherited token permissions'
else
  not_ok 'canonical security jobs cannot widen their inherited token permissions'
  cat "$TMP/security-write-all.out" >&2
fi

make_production_manifest "$TMP/multi-lockfile-base.json" fixture-multi-lockfile
multi_security=$(jq -r '.files[".github/workflows/security.yml"]' \
  "$TMP/multi-lockfile-base.json")
sed '/^  headers-live:/,$d' "$multi_security" >"$TMP/security-multi-lockfile.yml"
cat >>"$TMP/security-multi-lockfile.yml" <<'EOF'
  # The second declared lockfile appears here only as a comment:
  # --lockfile=apps/web/pnpm-lock.yaml
  dependency-scan:
    name: Dependency scan
    uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@8deb546fdb875b9996d27d4950be7312dac076a1 # v2.5.0
    with:
      scan-args: |-
        --lockfile=package-lock.json
      fail-on-vuln: true
      upload-sarif: false
    permissions:
      actions: read
      contents: read
      security-events: write
EOF
sed -n '/^  headers-live:/,$p' "$multi_security" >>"$TMP/security-multi-lockfile.yml"
printf '{"scripts":{"typecheck":"true","lint":"true","test":"true"}}\n' \
  >"$TMP/package.json"
printf '{"lockfileVersion":3,"packages":{}}\n' >"$TMP/package-lock.json"
mkdir -p "$TMP/apps/web"
printf 'lockfileVersion: 9.0\n' >"$TMP/apps/web/pnpm-lock.yaml"
cat >"$TMP/dependabot-multi.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: npm
    directories: [/, /apps/web]
    schedule: { interval: weekly }
    cooldown: { default-days: 7 }
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    cooldown: { default-days: 7 }
EOF
jq --arg security "$TMP/security-multi-lockfile.yml" \
   --arg package "$TMP/package.json" \
   --arg package_lock "$TMP/package-lock.json" \
   --arg nested_lock "$TMP/apps/web/pnpm-lock.yaml" \
   --arg dependabot "$TMP/dependabot-multi.yml" '
  .files[".github/workflows/security.yml"] = $security |
  .files["package.json"] = $package |
  .files["package-lock.json"] = $package_lock |
  .files["apps/web/pnpm-lock.yaml"] = $nested_lock |
  .files[".github/dependabot.yml"] = $dependabot |
  .lockfiles = ["package-lock.json", "apps/web/pnpm-lock.yaml"] |
  .required_checks = ["verify", "Semgrep CE", "Secret scan", "Dependency scan / osv-scan"]
' "$TMP/multi-lockfile-base.json" >"$TMP/multi-lockfile.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/multi-lockfile.json" \
     >"$TMP/multi-lockfile.out" 2>&1 &&
   grep -q 'OSV inputs must equal the ordered declared lockfile population' \
     "$TMP/multi-lockfile.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'comments cannot impersonate a parsed OSV input for a second lockfile'
else
  not_ok 'comments cannot impersonate a parsed OSV input for a second lockfile'
  cat "$TMP/multi-lockfile.out" >&2
fi

sed '/        --lockfile=package-lock.json/a\
        --lockfile=apps/web/pnpm-lock.yaml' "$TMP/security-multi-lockfile.yml" \
  >"$TMP/security-multi-lockfile-complete.yml"
jq --arg security "$TMP/security-multi-lockfile-complete.yml" \
  '.files[".github/workflows/security.yml"] = $security' \
  "$TMP/multi-lockfile.json" >"$TMP/multi-lockfile-complete.json"
: >"$TMP/gh.log"
if run_bootstrap --dry-run --manifest "$TMP/multi-lockfile-complete.json" \
     >"$TMP/multi-lockfile-complete.out" 2>&1 &&
   grep -q '4 ordered required checks' "$TMP/multi-lockfile-complete.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'one canonical OSV job can scan the exact ordered multi-lockfile population'
else
  not_ok 'one canonical OSV job can scan the exact ordered multi-lockfile population'
  cat "$TMP/multi-lockfile-complete.out" >&2
fi

jq --arg dependabot "$TMP/input/.github/dependabot.yml" \
  '.files[".github/dependabot.yml"] = $dependabot' \
  "$TMP/multi-lockfile-complete.json" >"$TMP/missing-ecosystem.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/missing-ecosystem.json" \
     >"$TMP/missing-ecosystem.out" 2>&1 &&
   grep -q 'Dependabot lane population must equal the derived repository ecosystem population' \
     "$TMP/missing-ecosystem.out"; then
  ok 'Dependabot ecosystems and directories are derived from the supplied lockfiles'
else
  not_ok 'Dependabot ecosystems and directories are derived from the supplied lockfiles'
  cat "$TMP/missing-ecosystem.out" >&2
fi

mkdir -p "$TMP/undeclared-lock"
printf '{"lockfileVersion":3,"packages":{}}\n' >"$TMP/undeclared-lock/package-lock.json"
jq --arg lock "$TMP/undeclared-lock/package-lock.json" \
  '.files["nested/package-lock.json"] = $lock' \
  "$TMP/public.json" >"$TMP/undeclared-lockfile.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/undeclared-lockfile.json" \
     >"$TMP/undeclared-lockfile.out" 2>&1 &&
   grep -q 'lockfiles must equal the lockfile population derived from files' \
     "$TMP/undeclared-lockfile.out"; then
  ok 'the manifest cannot omit a lockfile present in its closed file population'
else
  not_ok 'the manifest cannot omit a lockfile present in its closed file population'
  cat "$TMP/undeclared-lockfile.out" >&2
fi

sed 's/default-days: 7/default-days: 7garbage/' "$TMP/input/.github/dependabot.yml" \
  >"$TMP/dependabot-garbage-cooldown.yml"
jq --arg dependabot "$TMP/dependabot-garbage-cooldown.yml" \
  '.files[".github/dependabot.yml"] = $dependabot' \
  "$TMP/public.json" >"$TMP/garbage-cooldown.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/garbage-cooldown.json" \
     >"$TMP/garbage-cooldown.out" 2>&1 &&
   grep -q 'cooldown.default-days must be an integer' "$TMP/garbage-cooldown.out"; then
  ok 'cooldown parsing rejects numeric prefixes with trailing garbage'
else
  not_ok 'cooldown parsing rejects numeric prefixes with trailing garbage'
  cat "$TMP/garbage-cooldown.out" >&2
fi

: >"$TMP/gh.log"
if ! env BOOTSTRAP_TEST_MODE=1 BOOTSTRAP_TEST_TOKEN="$TEST_TOKEN" \
     "$ROOT/scripts/bootstrap-repo.sh" --dry-run --manifest "$TMP/public.json" \
     >"$TMP/production-bypass.out" 2>&1 &&
   grep -q 'only from an isolated bootstrap test fixture' "$TMP/production-bypass.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'the production script cannot enable test redirects'
else
  not_ok 'the production script cannot enable test redirects'
  cat "$TMP/production-bypass.out" >&2
fi

jq '.automerge_app_id = 4562964' "$TMP/public.json" >"$TMP/wrong-app.json"
: >"$TMP/gh.log"
if ! run_bootstrap --dry-run --manifest "$TMP/wrong-app.json" >"$TMP/wrong-app.out" 2>&1 &&
   grep -q 'must equal the reviewed windward-line-automerge App ID 4562963' "$TMP/wrong-app.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'a wrong fleet auto-merge App ID fails before mutation'
else
  not_ok 'a wrong fleet auto-merge App ID fails before mutation'
  cat "$TMP/wrong-app.out" >&2
fi

printf '%s' 'not-base64' >"$TMP/invalid-app-key.b64"
make_manifest "$TMP/invalid-key.json" public fixture-invalid-key
: >"$TMP/gh.log"
if ! BOOTSTRAP_TEST_APP_KEY_B64_OVERRIDE="$TMP/invalid-app-key.b64" \
     run_bootstrap --manifest "$TMP/invalid-key.json" >"$TMP/invalid-key.out" 2>&1 &&
   grep -q 'could not authenticate as App 4562963' "$TMP/invalid-key.out" &&
   ! grep -q 'repo create' "$TMP/gh.log"; then
  ok 'an invalid Keychain App key fails before repository creation'
else
  not_ok 'an invalid Keychain App key fails before repository creation'
  cat "$TMP/invalid-key.out" >&2
fi

make_manifest "$TMP/gitleaks-failure.json" public fixture-gitleaks-failure
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_GITLEAKS_FAIL=1 \
     run_bootstrap --manifest "$TMP/gitleaks-failure.json" >"$TMP/gitleaks-failure.out" 2>&1; then
  gitleaks_failed=0
else
  gitleaks_failed=1
fi
if [ "$gitleaks_failed" -eq 1 ] &&
   grep -q 'gitleaks ' "$TMP/gh.log" &&
   grep -Eiq 'gitleaks|secret scan' "$TMP/gitleaks-failure.out" &&
   grep -q 'PARTIAL STATE: https://github.com/windwardline/fixture-gitleaks-failure exists' \
     "$TMP/gitleaks-failure.out" &&
   ! grep -q 'secret set' "$TMP/gh.log" &&
   ! grep -q 'push -u' "$TMP/git.log" &&
   ! grep -q 'Bootstrap complete' "$TMP/gitleaks-failure.out"; then
  ok 'a local gitleaks finding stops secrets, push, and completion claims'
else
  not_ok 'a local gitleaks finding stops secrets, push, and completion claims'
  cat "$TMP/gitleaks-failure.out" >&2
  cat "$TMP/gh.log" >&2
  cat "$TMP/git.log" >&2
fi

make_manifest "$TMP/gitleaks-vacuous.json" public fixture-gitleaks-vacuous
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_GITLEAKS_VACUOUS=1 \
     run_bootstrap --manifest "$TMP/gitleaks-vacuous.json" >"$TMP/gitleaks-vacuous.out" 2>&1; then
  gitleaks_vacuous_failed=0
else
  gitleaks_vacuous_failed=1
fi
if [ "$gitleaks_vacuous_failed" -eq 1 ] &&
   grep -q 'reported no positive examined-byte count' "$TMP/gitleaks-vacuous.out" &&
   ! grep -q 'secret set' "$TMP/gh.log" &&
   ! grep -q 'push -u' "$TMP/git.log"; then
  ok 'a zero-byte gitleaks success is refused as a vacuous scan'
else
  not_ok 'a zero-byte gitleaks success is refused as a vacuous scan'
  cat "$TMP/gitleaks-vacuous.out" >&2
  cat "$TMP/gh.log" >&2
  cat "$TMP/git.log" >&2
fi

make_manifest "$TMP/ambiguous-create.json" public fixture-ambiguous
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_AMBIGUOUS_CREATE=1 \
     run_bootstrap --manifest "$TMP/ambiguous-create.json" >"$TMP/ambiguous-create.out" 2>&1; then
  ambiguous_failed=0
else
  ambiguous_failed=1
fi
if [ "$ambiguous_failed" -eq 1 ] &&
   grep -q 'PARTIAL STATE: https://github.com/windwardline/fixture-ambiguous exists' \
     "$TMP/ambiguous-create.out" &&
   ! grep -q ' clone ' "$TMP/git.log" &&
   ! grep -q 'push -u' "$TMP/git.log" &&
   ! grep -q 'Bootstrap complete' "$TMP/ambiguous-create.out"; then
  ok 'an ambiguous create response reads back and reports the retained remote'
else
  not_ok 'an ambiguous create response reads back and reports the retained remote'
  cat "$TMP/ambiguous-create.out" >&2
  cat "$TMP/gh.log" >&2
  cat "$TMP/git.log" >&2
fi

cp "$TMP/input/.github/workflows/ci.yml" "$TMP/mutable-ci.yml"
sed "s#run: 'true'#env:\n          EXFILTRATE: \${{ fromJSON(toJSON(github)).token }}\n        run: 'true'#" \
  "$TMP/input/.github/workflows/ci.yml" >"$TMP/mutated-ci.yml"
make_manifest "$TMP/source-snapshot.json" public fixture-source-snapshot
jq --arg source "$TMP/mutable-ci.yml" \
  '.files[".github/workflows/ci.yml"] = $source' \
  "$TMP/source-snapshot.json" >"$TMP/source-snapshot-final.json"
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_MUTATE_SOURCE="$TMP/mutable-ci.yml" \
   BOOTSTRAP_TEST_MUTATE_REPLACEMENT="$TMP/mutated-ci.yml" \
   run_bootstrap --manifest "$TMP/source-snapshot-final.json" \
     >"$TMP/source-snapshot.out" 2>&1 &&
   grep -q 'Bootstrap complete: windwardline/fixture-source-snapshot' "$TMP/source-snapshot.out" &&
   ! rg -q 'EXFILTRATE|fromJSON' \
     "$HARNESS_PHYSICAL/projects/fixture-source-snapshot/.github/workflows/ci.yml"; then
  ok 'post-validation source replacement cannot change the snapshotted bytes that are published'
else
  not_ok 'post-validation source replacement cannot change the snapshotted bytes that are published'
  cat "$TMP/source-snapshot.out" >&2
fi

cp -R "$TMP/input" "$TMP/symlink-template"
mkdir -p "$TMP/symlink-template/templates"
printf 'outside remains intact\n' >"$TMP/outside-victim"
ln -s "$TMP/outside-victim" "$TMP/symlink-template/templates/LICENSE"
make_manifest "$TMP/destination-symlink.json" public fixture-destination-symlink
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_TEMPLATE_OVERRIDE="$TMP/symlink-template" \
     run_bootstrap --manifest "$TMP/destination-symlink.json" \
       >"$TMP/destination-symlink.out" 2>&1; then
  destination_symlink_failed=0
else
  destination_symlink_failed=1
fi
if [ "$destination_symlink_failed" -eq 1 ] &&
   grep -Eiq 'template checkout.*symlink|unsafe filesystem' "$TMP/destination-symlink.out" &&
   [ "$(/bin/cat "$TMP/outside-victim")" = 'outside remains intact' ] &&
   ! grep -q 'secret set' "$TMP/gh.log" &&
   ! grep -q 'push -u' "$TMP/git.log"; then
  ok 'template symlinks are rejected before generated files can escape the checkout'
else
  not_ok 'template symlinks are rejected before generated files can escape the checkout'
  cat "$TMP/destination-symlink.out" >&2
fi

make_manifest "$TMP/advisory-names.json" public fixture-advisory-names
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_BAD_ADVISORY=1 \
     run_bootstrap --manifest "$TMP/advisory-names.json" >"$TMP/advisory-names.out" 2>&1; then
  advisory_failed=0
else
  advisory_failed=1
fi
if [ "$advisory_failed" -eq 1 ] &&
   grep -q 'live GitHub Actions check population contains an undeclared gate' \
     "$TMP/advisory-names.out" &&
   ! grep -q 'secret set' "$TMP/gh.log"; then
  ok 'live advisory checks must use the canonical reusable-workflow names'
else
  not_ok 'live advisory checks must use the canonical reusable-workflow names'
  cat "$TMP/advisory-names.out" >&2
fi

make_manifest "$TMP/merged-head.json" public fixture-merged-head
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_PR_HEAD='dddddddddddddddddddddddddddddddddddddddd' \
     run_bootstrap --manifest "$TMP/merged-head.json" >"$TMP/merged-head.out" 2>&1; then
  merged_head_failed=0
else
  merged_head_failed=1
fi
if [ "$merged_head_failed" -eq 1 ] &&
   grep -q 'head differs from the validated bootstrap commit' "$TMP/merged-head.out" &&
   ! grep -q 'secret set' "$TMP/gh.log"; then
  ok 'a force-pushed pull-request head cannot receive repository secrets'
else
  not_ok 'a force-pushed pull-request head cannot receive repository secrets'
  cat "$TMP/merged-head.out" >&2
fi

make_manifest "$TMP/merged-tree.json" public fixture-merged-tree
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_TREE_MISMATCH=1 \
     run_bootstrap --manifest "$TMP/merged-tree.json" >"$TMP/merged-tree.out" 2>&1; then
  merged_tree_failed=0
else
  merged_tree_failed=1
fi
if [ "$merged_tree_failed" -eq 1 ] &&
   grep -q 'merged repository tree differs from the validated bootstrap tree' \
     "$TMP/merged-tree.out" &&
   ! grep -q 'secret set' "$TMP/gh.log"; then
  ok 'merged tree equality is proved before any repository secret upload'
else
  not_ok 'merged tree equality is proved before any repository secret upload'
  cat "$TMP/merged-tree.out" >&2
fi

mkdir -p "$TMP/hostile-bin" "$TMP/hostile-zdot" "$TMP/hostile-hooks"
cat >"$TMP/hostile-startup" <<EOF
#!/bin/sh
/usr/bin/touch "$TMP/hostile-ran"
EOF
cat >"$TMP/hostile-ruby.rb" <<EOF
File.write("$TMP/hostile-ran", "ruby hook ran")
EOF
cat >"$TMP/hostile-zdot/.zshenv" <<EOF
/usr/bin/touch "$TMP/hostile-ran"
EOF
cat >"$TMP/hostile-gitconfig" <<EOF
[url "https://attacker.invalid/"]
  insteadOf = https://github.com/
[core]
  hooksPath = $TMP/hostile-hooks
EOF
cat >"$TMP/hostile-bin/gh" <<EOF
#!/bin/sh
/usr/bin/touch "$TMP/hostile-ran"
exit 99
EOF
chmod +x "$TMP/hostile-startup" "$TMP/hostile-bin/gh"

make_manifest "$TMP/apply.json" public fixture-apply
: >"$TMP/gh.log"
: >"$TMP/git.log"
if PATH="$TMP/hostile-bin:/usr/bin:/bin" \
   HOME="$TMP/hostile-home" USER='attacker' GH_CONFIG_DIR="$TMP/hostile-gh" \
   BASH_ENV="$TMP/hostile-startup" ENV="$TMP/hostile-startup" \
   ZDOTDIR="$TMP/hostile-zdot" RUBYOPT="-r$TMP/hostile-ruby.rb" \
   LD_AUDIT="$TMP/hostile-loader.so" GLIBC_TUNABLES='glibc.malloc.check=3' \
   DYLD_FRAMEWORK_PATH="$TMP/hostile-frameworks" DYLD_PRINT_TO_FILE="$TMP/hostile-ran" \
   RUBYLIB="$TMP" GIT_CONFIG_GLOBAL="$TMP/hostile-gitconfig" \
   GIT_CONFIG_COUNT=2 \
   GIT_CONFIG_KEY_0='url.https://attacker.invalid/.insteadOf' \
   GIT_CONFIG_VALUE_0='https://github.com/' \
   GIT_CONFIG_KEY_1='core.hooksPath' \
   GIT_CONFIG_VALUE_1="$TMP/hostile-hooks" \
   GIT_REPLACE_REF_BASE='refs/hostile-replacements/' \
   GIT_EXEC_PATH="$TMP/hostile-bin" GIT_TEMPLATE_DIR="$TMP/hostile-hooks" \
   GIT_AUTHOR_NAME='Attacker' GIT_SSL_NO_VERIFY=1 GH_DEBUG=api \
   run_bootstrap --manifest "$TMP/apply.json" >"$TMP/apply.out" 2>&1 &&
   grep -q 'repo create windwardline/fixture-apply --public --template windwardline/fleet-template' "$TMP/gh.log" &&
   grep -q 'fleet conformance invoked' "$TMP/gh.log" &&
   grep -q 'Bootstrap complete: windwardline/fixture-apply' "$TMP/apply.out" &&
   jq -e '
     .name == "main-requires-green-ci" and
     .target == "branch" and .enforcement == "active" and
     .bypass_actors == [] and
     .conditions.ref_name == {exclude:[],include:["~DEFAULT_BRANCH"]} and
     [.rules[].type] == ["required_status_checks","required_linear_history","non_fast_forward"] and
     .rules[0].parameters.strict_required_status_checks_policy == false and
     .rules[0].parameters.do_not_enforce_on_create == false and
     [.rules[0].parameters.required_status_checks[].context] == ["verify","Semgrep CE","Secret scan"] and
     all(.rules[0].parameters.required_status_checks[]; .integration_id == 15368) and
     ([.rules[0].parameters.required_status_checks[].context] | index("dependabot-auto-merge")) == null
   ' "$TMP/ruleset.json" >/dev/null &&
   grep -q -- '-c core.hooksPath=/dev/null' "$TMP/git.log" &&
   grep -q 'fetch --prune origin' "$TMP/git.log" &&
   grep -q 'branch -D chore/bootstrap-fixture-apply' "$TMP/git.log" &&
   cmp -s "$HARNESS/templates/scratch-clone.sh" \
     "$HARNESS_PHYSICAL/projects/fixture-apply/scripts/scratch-clone.sh" &&
   ! test -e "$TMP/hostile-ran" &&
   ! grep -q 'attacker.invalid' "$TMP/git.log" &&
   ! grep -q 'TEST_SECRET_SENTINEL_9d8a' "$TMP/apply.out" "$TMP/gh.log" "$TMP/git.log" &&
   ! rg --hidden --fixed-strings 'TEST_SECRET_SENTINEL_9d8a' \
     "$HARNESS_PHYSICAL/projects/fixture-apply" >/dev/null 2>&1; then
  ok 'apply ignores hostile startup, PATH, Ruby, and Git configuration while completing exact verification'
else
  not_ok 'apply ignores hostile startup, PATH, Ruby, and Git configuration while completing exact verification'
  cat "$TMP/apply.out" >&2
  cat "$TMP/gh.log" >&2
  cat "$TMP/git.log" >&2
fi

make_production_manifest "$TMP/production.json"
: >"$TMP/gh.log"
: >"$TMP/git.log"
if run_bootstrap --manifest "$TMP/production.json" >"$TMP/production.out" 2>&1 &&
   grep -q 'repo create windwardline/fixture-production --public --template windwardline/fleet-template' "$TMP/gh.log" &&
   grep -q 'header probe invoked' "$TMP/gh.log" &&
   grep -q 'Bootstrap complete: windwardline/fixture-production' "$TMP/production.out" &&
   jq -e '
     [.rules[0].parameters.required_status_checks[].context] ==
       ["verify","Semgrep CE","Secret scan"] and
     all(.rules[0].parameters.required_status_checks[]; .integration_id == 15368)
   ' "$TMP/ruleset.json" >/dev/null; then
  ok 'production bootstrap keeps Headers live postmerge while requiring only PR-running gates'
else
  not_ok 'production bootstrap keeps Headers live postmerge while requiring only PR-running gates'
  cat "$TMP/production.out" >&2
  cat "$TMP/gh.log" >&2
  cat "$TMP/git.log" >&2
fi

make_manifest "$TMP/partial.json" public fixture-partial
: >"$TMP/gh.log"
: >"$TMP/git.log"
if BOOTSTRAP_TEST_FAIL_SECRET=1 \
   run_bootstrap --manifest "$TMP/partial.json" >"$TMP/partial.out" 2>&1; then
  partial_failed=0
else
  partial_failed=1
fi
if [ "$partial_failed" -eq 1 ] &&
   [ "$(grep -c 'PARTIAL STATE: https://github.com/windwardline/fixture-partial exists' "$TMP/partial.out")" -eq 1 ] &&
   [ "$(grep -c "PARTIAL STATE: local checkout exists at $HARNESS_PHYSICAL/projects/fixture-partial" "$TMP/partial.out")" -eq 1 ] &&
   [ "$(grep -c 'No rollback was attempted' "$TMP/partial.out")" -eq 1 ]; then
  ok 'a post-create failure reports each retained target and the lack of rollback exactly once'
else
  not_ok 'a post-create failure reports each retained target and the lack of rollback exactly once'
  cat "$TMP/partial.out" >&2
  cat "$TMP/gh.log" >&2
  cat "$TMP/git.log" >&2
fi

printf 'bootstrap tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
