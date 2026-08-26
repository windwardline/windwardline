#!/bin/zsh -f
# Create one Windward Line repository from the fleet template and carry its
# initial configuration through a gated pull request. The manifest contains
# configuration only. Secret values move directly from Keychain stdout to
# `gh secret set` stdin; this process never stores, expands, or prints them.

set -eu
set -o pipefail
umask 077

OWNER="windwardline"
TEMPLATE="$OWNER/fleet-template"
case "$0" in
  */*) SCRIPT_DIR=$(cd -P "${0%/*}" && pwd -P) ;;
  *) SCRIPT_DIR=$(cd -P . && pwd -P) ;;
esac
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VALIDATOR="$SCRIPT_DIR/bootstrap_config_validator.rb"
INSPECTOR="$SCRIPT_DIR/actions_yaml_inspector.rb"
PIN_AUDITOR_DEFAULT="$SCRIPT_DIR/verify-action-pins.sh"
HEADER_PROBE_DEFAULT="$ROOT/actions/verify-live-headers/verify-live-headers.sh"
FLEET_MD="$ROOT/FLEET.md"
REVIEW_CALLER="$ROOT/templates/claude-review.yml"
AUTOMERGE_WORKFLOW="$ROOT/templates/dependabot-auto-merge.yml"
LICENSE_TEMPLATE="$ROOT/templates/proprietary-license.txt"
SCRATCH_TEMPLATE="$ROOT/templates/scratch-clone.sh"
APP_KEY_VERIFIER="$SCRIPT_DIR/github_app_key_verifier.rb"
PROJECTS_ROOT="/Users/peacock/Projects"
SECURITY_BIN="/usr/bin/security"
GH_BIN="/opt/homebrew/bin/gh"
GIT_BIN="/opt/homebrew/bin/git"
JQ_BIN="/opt/homebrew/bin/jq"
RUBY_BIN="/usr/bin/ruby"
ACTIONLINT_BIN="/opt/homebrew/bin/actionlint"
GITLEAKS_BIN="/opt/homebrew/bin/gitleaks"
PIN_AUDITOR="$PIN_AUDITOR_DEFAULT"
HEADER_PROBE_BIN="$HEADER_PROBE_DEFAULT"
CONFORMANCE_BIN="$SCRIPT_DIR/fleet-conformance.sh"
POLL_SECONDS=15
WAIT_SECONDS=1200
EXPECTED_AUTOMERGE_APP_ID=4562963

# Host startup files, dynamic loaders, language hooks, and Git's ambient config
# are all executable trust boundaries. This bootstrap runs with one known tool
# path, the canonical gh account store, and no inherited Git rewrite, hook, or
# replacement-ref configuration.
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HOME="/Users/peacock"
USER="peacock"
GH_CONFIG_DIR="/Users/peacock/.config/gh"
GIT_CONFIG_GLOBAL="/dev/null"
GIT_CONFIG_NOSYSTEM=1
GIT_NO_REPLACE_OBJECTS=1
GIT_ATTR_NOSYSTEM=1
GIT_LITERAL_PATHSPECS=1
GIT_TERMINAL_PROMPT=0
GIT_PAGER='cat'
GH_PAGER='cat'
PAGER='cat'
TMPDIR=/tmp
LC_ALL=C.UTF-8
export PATH HOME USER GH_CONFIG_DIR GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
export GIT_NO_REPLACE_OBJECTS GIT_ATTR_NOSYSTEM GIT_TERMINAL_PROMPT
export GIT_LITERAL_PATHSPECS
export GIT_PAGER GH_PAGER PAGER
export TMPDIR LC_ALL
unset BASH_ENV ENV ZDOTDIR ZSH_ENV CDPATH XDG_CONFIG_HOME
unset LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_ORIGIN_PATH LD_PRELOAD LD_PROFILE
unset LD_PROFILE_OUTPUT LD_SHOW_AUXV LD_LIBRARY_PATH GLIBC_TUNABLES
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
unset DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_ROOT_PATH
unset DYLD_IMAGE_SUFFIX DYLD_VERSIONED_LIBRARY_PATH DYLD_VERSIONED_FRAMEWORK_PATH
unset DYLD_SHARED_CACHE_DIR DYLD_PRINT_TO_FILE
unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE
unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
unset GIT_CONFIG_SYSTEM GIT_EXEC_PATH GIT_TEMPLATE_DIR
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE
unset GIT_NAMESPACE GIT_QUARANTINE_PATH GIT_CEILING_DIRECTORIES
unset GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_ASKPASS SSH_ASKPASS
unset GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_ALLOW_PROTOCOL GIT_PROXY_COMMAND
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
unset GIT_TRACE GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE_PACKET
unset GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA GIT_CURL_VERBOSE
unset GIT_SSL_NO_VERIFY GIT_SSL_CAINFO GIT_SSL_CAPATH
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
unset GH_HOST GH_REPO GH_DEBUG DEBUG
unset CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
unset REQUESTS_CA_BUNDLE HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY
unset https_proxy http_proxy all_proxy no_proxy
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML

die() {
  printf 'bootstrap: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
usage: scripts/bootstrap-repo.sh --manifest FILE [--dry-run]

The JSON manifest must contain:
  repository, display_name, description, visibility (public by default),
  production_url (an HTTPS origin or null), automerge_app_id, ci_gates,
  required_checks, lockfiles, header_contract_tests, and files.

`files` maps repository-relative targets to source files. It must supply a real
AGENTS.md, README.md, ci.yml, security.yml, and dependabot.yml. The bootstrap
owns CLAUDE.md, LICENSE, SECURITY.md, claude-review.yml, and
dependabot-auto-merge.yml. Secret values never belong in the manifest.

Use --dry-run first. It validates the complete plan, GitHub identity, current
fleet action release, GitHub Actions App identity, and Keychain item presence
without creating a repository or reading a secret.
EOF
}

gh() {
  "$GH_BIN" "$@"
}

git() {
  "$GIT_BIN" \
    -c core.hooksPath=/dev/null \
    -c protocol.allow=never \
    -c protocol.https.allow=always \
    -c credential.helper= \
    -c "credential.https://github.com.helper=!$GH_BIN auth git-credential" \
    -c user.name='Windward Line' \
    -c user.email='windwardline@users.noreply.github.com' \
    "$@"
}

jq() {
  "$JQ_BIN" "$@"
}

ruby() {
  "$RUBY_BIN" "$@"
}

actionlint() {
  "$ACTIONLINT_BIN" "$@"
}

manifest=""
dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      [ "$#" -ge 2 ] || die "--manifest requires a path"
      manifest=$2
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done
[ -n "$manifest" ] || { usage >&2; exit 64; }

# Test doubles exist only in a copied fixture. The canonical production script
# cannot redirect GitHub, Git, Keychain, conformance, or the destination, even
# when a caller sets the test variables deliberately.
if [ "${BOOTSTRAP_TEST_MODE:-}" = "1" ]; then
  case "$ROOT" in
    */bootstrap-repo-test.*/harness) ;;
    *) die "test mode is available only from an isolated bootstrap test fixture" ;;
  esac
  test_marker="$ROOT/.bootstrap-test-fixture"
  [ -f "$test_marker" ] && [ ! -L "$test_marker" ] \
    || die "test fixture marker is missing or unsafe"
  [ -n "${BOOTSTRAP_TEST_TOKEN:-}" ] \
    || die "test fixture token is missing"
  [ "$(/bin/cat "$test_marker")" = "$BOOTSTRAP_TEST_TOKEN" ] \
    || die "test fixture token does not match"
  GH_BIN="$ROOT/.test-bin/gh"
  GIT_BIN="$ROOT/.test-bin/git"
  SECURITY_BIN="$ROOT/.test-bin/security"
  PIN_AUDITOR="$ROOT/.test-bin/pin-auditor"
  HEADER_PROBE_BIN="$ROOT/.test-bin/header-probe"
  CONFORMANCE_BIN="$ROOT/.test-bin/conformance"
  APP_KEY_VERIFIER="$ROOT/.test-bin/github-app-key-verifier.rb"
  GITLEAKS_BIN="$ROOT/.test-bin/gitleaks"
  PROJECTS_ROOT="$ROOT/projects"
  POLL_SECONDS=0
  WAIT_SECONDS=10
else
  [ -z "${BOOTSTRAP_TEST_TOKEN:-}" ] \
    || die "BOOTSTRAP_TEST_TOKEN is test-only"
fi

for tool_path in "$GH_BIN" "$GIT_BIN" "$JQ_BIN" "$RUBY_BIN" "$ACTIONLINT_BIN" "$GITLEAKS_BIN"; do
  [ -x "$tool_path" ] || die "required executable is unavailable: $tool_path"
done
[ -x "$SECURITY_BIN" ] || die "Keychain reader is unavailable: $SECURITY_BIN"
[ -x "$PIN_AUDITOR" ] || die "action-pin release resolver is unavailable: $PIN_AUDITOR"
[ -x "$HEADER_PROBE_BIN" ] || die "live-header probe is unavailable: $HEADER_PROBE_BIN"
[ -x "$CONFORMANCE_BIN" ] || die "fleet conformance checker is unavailable: $CONFORMANCE_BIN"
for required_file in "$VALIDATOR" "$INSPECTOR" "$FLEET_MD" "$REVIEW_CALLER" \
                     "$AUTOMERGE_WORKFLOW" "$LICENSE_TEMPLATE" "$SCRATCH_TEMPLATE" \
                     "$APP_KEY_VERIFIER"; do
  [ -r "$required_file" ] || die "required bootstrap source is unavailable: $required_file"
done

tmp=$(/usr/bin/mktemp -d "/tmp/windwardline-bootstrap.XXXXXX")
tmp=$(cd -P "$tmp" && pwd -P)
remote_state="none"
destination=""
partial_marker="$tmp/partial-state-reported"
report_partial_state() {
  if [ "$remote_state" != "none" ] && [ ! -e "$partial_marker" ]; then
    : >"$partial_marker"
    if [ "$remote_state" = "confirmed" ]; then
      printf 'bootstrap: PARTIAL STATE: https://github.com/%s exists.\n' "$full_repository" >&2
    else
      printf 'bootstrap: PARTIAL STATE: https://github.com/%s may exist; creation readback was inconclusive.\n' \
        "$full_repository" >&2
    fi
    if [ -n "$destination" ] && [ -e "$destination" ]; then
      printf 'bootstrap: PARTIAL STATE: local checkout exists at %s.\n' "$destination" >&2
    else
      printf 'bootstrap: PARTIAL STATE: no local checkout exists at %s.\n' "$destination" >&2
    fi
    printf 'bootstrap: No rollback was attempted; repair or remove both targets deliberately.\n' >&2
  fi
}
cleanup() {
  cleanup_rc=$?
  trap - EXIT
  [ "$cleanup_rc" -eq 0 ] || report_partial_state
  /bin/rm -rf -- "$tmp"
  exit "$cleanup_rc"
}
trap cleanup EXIT
trap report_partial_state ERR

# Prove the checkout before executing any repository-provided Ruby or shell
# helper. Then freeze every bootstrap-owned byte into the private run directory;
# every later execution and copy consumes that snapshot.
source_origin=$(git -C "$ROOT" remote get-url origin) \
  || die "bootstrap source origin could not be read"
case "$source_origin" in
  "https://github.com/$OWNER/windwardline"|"https://github.com/$OWNER/windwardline.git") ;;
  *) die "bootstrap source is not the canonical $OWNER/windwardline checkout" ;;
esac
source_branch=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD) \
  || die "bootstrap source is detached"
[ "$source_branch" = "main" ] || die "bootstrap source must be on main, not $source_branch"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ] \
  || die "bootstrap source must be clean"
source_head=$(git -C "$ROOT" rev-parse HEAD) || die "bootstrap source HEAD could not be read"
printf '%s' "$source_head" | grep -Eq '^[0-9a-f]{40}$' \
  || die "bootstrap source HEAD is malformed"
remote_main=$(gh api "repos/$OWNER/windwardline/commits/main" --jq '.sha') \
  || die "remote bootstrap source could not be read"
[ "$source_head" = "$remote_main" ] \
  || die "bootstrap source main is stale relative to GitHub"

mkdir "$tmp/bootstrap-owned"
/usr/bin/ruby -e '
  root, *pairs = ARGV
  root = File.realpath(root)
  abort "bootstrap snapshot argument list is malformed" unless pairs.length.even?
  pairs.each_slice(2) do |source, destination|
    source = File.expand_path(source)
    unless File.realpath(source) == source && source.start_with?("#{root}/")
      abort "bootstrap-owned source escaped the canonical checkout"
    end
    File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
      opened = input.stat
      current = File.stat(source)
      unless opened.file? && opened.dev == current.dev && opened.ino == current.ino
        abort "bootstrap-owned source changed while opened"
      end
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, opened.mode & 0o777) do |output|
        IO.copy_stream(input, output)
        output.flush
        output.fsync
      end
    end
  end
' "$ROOT" \
  "$VALIDATOR" "$tmp/bootstrap-owned/bootstrap_config_validator.rb" \
  "$INSPECTOR" "$tmp/bootstrap-owned/actions_yaml_inspector.rb" \
  "$PIN_AUDITOR" "$tmp/bootstrap-owned/verify-action-pins.sh" \
  "$FLEET_MD" "$tmp/bootstrap-owned/FLEET.md" \
  "$REVIEW_CALLER" "$tmp/bootstrap-owned/claude-review.yml" \
  "$AUTOMERGE_WORKFLOW" "$tmp/bootstrap-owned/dependabot-auto-merge.yml" \
  "$LICENSE_TEMPLATE" "$tmp/bootstrap-owned/proprietary-license.txt" \
  "$SCRATCH_TEMPLATE" "$tmp/bootstrap-owned/scratch-clone.sh" \
  "$APP_KEY_VERIFIER" "$tmp/bootstrap-owned/github-app-key-verifier.rb" \
  "$HEADER_PROBE_BIN" "$tmp/bootstrap-owned/verify-live-headers.sh" \
  "$CONFORMANCE_BIN" "$tmp/bootstrap-owned/fleet-conformance.sh" \
  || die "bootstrap-owned source snapshot failed"
VALIDATOR="$tmp/bootstrap-owned/bootstrap_config_validator.rb"
INSPECTOR="$tmp/bootstrap-owned/actions_yaml_inspector.rb"
PIN_AUDITOR="$tmp/bootstrap-owned/verify-action-pins.sh"
FLEET_MD="$tmp/bootstrap-owned/FLEET.md"
REVIEW_CALLER="$tmp/bootstrap-owned/claude-review.yml"
AUTOMERGE_WORKFLOW="$tmp/bootstrap-owned/dependabot-auto-merge.yml"
LICENSE_TEMPLATE="$tmp/bootstrap-owned/proprietary-license.txt"
SCRATCH_TEMPLATE="$tmp/bootstrap-owned/scratch-clone.sh"
APP_KEY_VERIFIER="$tmp/bootstrap-owned/github-app-key-verifier.rb"
HEADER_PROBE_BIN="$tmp/bootstrap-owned/verify-live-headers.sh"
CONFORMANCE_BIN="$tmp/bootstrap-owned/fleet-conformance.sh"

if ! release=$(/bin/bash --noprofile --norc "$PIN_AUDITOR" --latest-release "$OWNER/windwardline"); then
  die "current fleet action release could not be resolved"
fi
[ "$(printf '%s\n' "$release" | awk 'NF { n++ } END { print n+0 }')" -eq 1 ] \
  || die "current fleet action release was not exactly one row"
tab=$(printf '\t')
IFS=$tab read -r release_tag release_sha release_extra <<EOF
$release
EOF
[ -z "${release_extra:-}" ] || die "current fleet action release had extra fields"
printf '%s' "$release_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "current fleet action tag is malformed"
printf '%s' "$release_sha" | grep -Eq '^[0-9a-f]{40}$' \
  || die "current fleet action SHA is malformed"
release_tree=$(gh api "repos/$OWNER/windwardline/git/trees/$release_sha?recursive=1") \
  || die "current fleet action release tree could not be read"
printf '%s' "$release_tree" | jq -e --arg sha "$release_sha" '
  type == "object" and .sha == $sha and .truncated == false and (.tree | type == "array") and
  all(.tree[]; (.path | type == "string") and (.type | type == "string")) and
  (([.tree[] | select(.type == "blob") | .path]) as $paths |
    all([
      "actions/verify-action-pins/action.yml",
      "scripts/verify-action-pins.sh",
      "scripts/actions_yaml_inspector.rb",
      "actions/verify-live-headers/action.yml",
      "actions/verify-live-headers/verify-live-headers.sh",
      "actions/verify-ghost-managed-edge/action.yml",
      "actions/verify-ghost-managed-edge/verify-ghost-managed-edge.sh"
    ][]; . as $required | ($paths | index($required)) != null))
' >/dev/null || die "current fleet release does not contain every required action path"

mkdir "$tmp/manifest-snapshot"
validator_mode=apply
[ "$dry_run" -eq 1 ] && validator_mode=dry-run
if ! ruby "$VALIDATOR" "$manifest" "$FLEET_MD" "$release_tag" "$release_sha" \
  "$EXPECTED_AUTOMERGE_APP_ID" "$tmp/manifest-snapshot" "$validator_mode" \
  >"$tmp/plan.json"; then
  die "manifest validation failed"
fi

repository=$(jq -er '.repository' "$tmp/plan.json")
full_repository=$(jq -er '.full_repository' "$tmp/plan.json")
display_name=$(jq -er '.display_name' "$tmp/plan.json")
description=$(jq -er '.description' "$tmp/plan.json")
visibility=$(jq -er '.visibility' "$tmp/plan.json")
production_url=$(jq -r '.production_url // empty' "$tmp/plan.json")
license_subject=$(jq -er '.license_subject' "$tmp/plan.json")
automerge_app_id=$(jq -er '.automerge_app_id' "$tmp/plan.json")
private_registration_present=$(jq -r '.private_registration_present' "$tmp/plan.json")
case "$private_registration_present" in
  true|false) ;;
  *) die "private registration state was malformed" ;;
esac

# Validate the supplied workflows with GitHub's grammar before any remote
# mutation. The structural inspector above proves the security semantics;
# actionlint catches the rest of the Actions schema.
actionlint \
  "$(jq -r '.files[".github/workflows/ci.yml"]' "$tmp/plan.json")" \
  "$(jq -r '.files[".github/workflows/security.yml"]' "$tmp/plan.json")" \
  "$REVIEW_CALLER" \
  "$AUTOMERGE_WORKFLOW"

login=$(gh api user --jq '.login') || die "GitHub identity could not be read"
[ "$login" = "$OWNER" ] || die "gh is authenticated as $login; expected $OWNER"

template_json=$(gh api "repos/$TEMPLATE") || die "fleet template metadata could not be read"
printf '%s' "$template_json" | jq -e \
  --arg owner "$OWNER" \
  '.name == "fleet-template" and .is_template == true and .archived == false and
   .visibility == "public" and .default_branch == "main"' >/dev/null \
  || die "fleet template is not the expected public, live main-branch template"

# A failed `gh api` can mean 404 or refusal. Only an exact HTTP 404 proves the
# target name is available.
set +e
target_response=$(gh api --include "repos/$full_repository" 2>/dev/null)
target_rc=$?
set -e
target_status=$(printf '%s\n' "$target_response" | sed -n '1s/^HTTP\/[^ ]* \([0-9][0-9][0-9]\).*/\1/p')
case "$target_status:$target_rc" in
  404:*) ;;
  2??:0) die "$full_repository already exists" ;;
  *) die "repository-name check was refused or returned no parseable HTTP status" ;;
esac

actions_app=$(gh api apps/github-actions) || die "GitHub Actions App identity could not be read"
actions_app_id=$(printf '%s' "$actions_app" | jq -er \
  'select(.slug == "github-actions" and .name == "GitHub Actions") | .id |
   select(type == "number" and . > 0)') \
  || die "GitHub Actions App identity response was malformed"

keychain_account="peacock"
for service in anthropic-actions-oauth github-automerge-app-key; do
  "$SECURITY_BIN" find-generic-password -a "$keychain_account" -s "$service" >/dev/null 2>&1 \
    || die "required Keychain item is missing: $service"
done

visibility_upper=$(printf '%s' "$visibility" | tr '[:lower:]' '[:upper:]')
printf 'Preflight complete: %s (%s), %d ordered required checks, fleet actions %s.\n' \
  "$full_repository" "$visibility_upper" \
  "$(jq '.required_checks | length' "$tmp/plan.json")" "$release_tag"
if [ "$dry_run" -eq 1 ]; then
  if [ "$visibility" = "private" ] && [ "$private_registration_present" != "true" ]; then
    printf 'Reservation required: add %s to the private-by-design register before apply mode.\n' \
      "$repository"
  fi
  exit 0
fi

# Keychain holds the multiline App private key as one strict-base64 value. Prove
# that it authenticates as the one reviewed App before creating either target.
# The verifier emits neither the key, the JWT, nor GitHub's response body. The
# later upload repeats the decoder directly into gh stdin; no shell variable,
# argument, temporary file, or log ever receives the decoded PEM.
"$SECURITY_BIN" find-generic-password -a "$keychain_account" \
  -s github-automerge-app-key -w 2>/dev/null \
  | "$RUBY_BIN" "$APP_KEY_VERIFIER" >/dev/null \
  || die "github-automerge-app-key could not authenticate as App $EXPECTED_AUTOMERGE_APP_ID"

destination="$PROJECTS_ROOT/$repository"
case "$destination" in
  "$PROJECTS_ROOT"/*) ;;
  *) die "resolved destination escaped $PROJECTS_ROOT" ;;
esac
[ ! -e "$destination" ] || die "local destination already exists: $destination"

create_visibility="--public"
[ "$visibility" = "private" ] && create_visibility="--private"
remote_state="attempted"
if ! gh repo create "$full_repository" "$create_visibility" --template "$TEMPLATE" \
  --description "$description"; then
  set +e
  create_readback=$(gh api --include "repos/$full_repository" 2>/dev/null)
  create_readback_rc=$?
  set -e
  create_readback_status=$(printf '%s\n' "$create_readback" \
    | sed -n '1s/^HTTP\/[^ ]* \([0-9][0-9][0-9]\).*/\1/p')
  case "$create_readback_status:$create_readback_rc" in
    2??:0)
      remote_state="confirmed"
      die "repository creation command failed, but exact readback confirms $full_repository exists"
      ;;
    404:*)
      remote_state="none"
      die "repository creation failed and exact readback confirms $full_repository is absent"
      ;;
    *)
      die "repository creation failed and exact readback could not resolve whether $full_repository exists"
      ;;
  esac
fi
remote_state="confirmed"
created_repository=$(gh api "repos/$full_repository") \
  || die "created repository metadata could not be read back"
printf '%s' "$created_repository" | jq -e \
  --arg full_repository "$full_repository" \
  --arg visibility "$visibility" '
    .full_name == $full_repository and .archived == false and
    .default_branch == "main" and .visibility == $visibility
  ' >/dev/null || die "created repository metadata does not match the requested target"

# Everything below is scoped to the repository just created. The initial main
# branch remains the template seed; real project files land through a branch
# and pull request, never by committing directly to main.
assert_destination_origin() {
  checked_origin=$(git -C "$destination" remote get-url origin) \
    || die "destination origin could not be read"
  case "$checked_origin" in
    "https://github.com/$full_repository"|"https://github.com/$full_repository.git") ;;
    *) die "destination origin does not match $full_repository" ;;
  esac
}

git clone "https://github.com/$full_repository.git" "$destination"
assert_destination_origin
[ -z "$(git -C "$destination" status --porcelain)" ] || die "new clone is unexpectedly dirty"
ruby -rfind -e '
  root = File.realpath(ARGV.fetch(0))
  abort "destination path is not physical" unless root == File.expand_path(ARGV.fetch(0))
  Find.find(root) do |path|
    relative = path.delete_prefix("#{root}/")
    if relative == ".git"
      Find.prune
      next
    end
    next if path == root
    stat = File.lstat(path)
    abort "template checkout contains a symlink: #{relative}" if stat.symlink?
    abort "template checkout contains a special file: #{relative}" unless stat.file? || stat.directory?
    resolved = File.realpath(path)
    unless resolved == path && resolved.start_with?("#{root}/")
      abort "template checkout path escapes the destination: #{relative}"
    end
  end
' "$destination" || die "template checkout contains an unsafe filesystem entry"

branch="chore/bootstrap-$repository"
git -C "$destination" switch -c "$branch"

jq -r '.files | to_entries[] | [.key, .value] | @tsv' "$tmp/plan.json" \
  >"$tmp/files.tsv"
typeset -a staged_paths
staged_paths=()
while IFS=$tab read -r target source extra; do
  [ -n "$target" ] && [ -n "$source" ] && [ -z "${extra:-}" ] \
    || die "normalized file mapping was malformed"
  mkdir -p "$destination/$(dirname "$target")"
  cp -- "$source" "$destination/$target"
  staged_paths+=("$target")
done <"$tmp/files.tsv"

cp -- "$REVIEW_CALLER" "$destination/.github/workflows/claude-review.yml"
cp -- "$AUTOMERGE_WORKFLOW" "$destination/.github/workflows/dependabot-auto-merge.yml"
/bin/mkdir -p "$destination/scripts"
cp -- "$SCRATCH_TEMPLATE" "$destination/scripts/scratch-clone.sh"
printf '@AGENTS.md\n' >"$destination/CLAUDE.md"
staged_paths+=(
  ".github/workflows/claude-review.yml"
  ".github/workflows/dependabot-auto-merge.yml"
  "CLAUDE.md"
  "LICENSE"
  "SECURITY.md"
  "scripts/scratch-clone.sh"
)

ruby -e '
  source, destination, subject = ARGV
  body = File.binread(source)
  count = body.scan("{{DOMAIN}}").length
  abort "license template must contain exactly one DOMAIN placeholder" unless count == 1
  File.binwrite(destination, body.sub("{{DOMAIN}}", subject))
' "$LICENSE_TEMPLATE" "$destination/LICENSE" "$license_subject"

cat >"$destination/SECURITY.md" <<'EOF'
# Security Policy

## Reporting a Vulnerability

Do not disclose suspected vulnerabilities or exploit details in a public
issue or pull request.

EOF
if [ "$visibility" = "public" ]; then
  cat >>"$destination/SECURITY.md" <<'EOF'

Use this repository's private vulnerability-reporting workflow (Security →
Report a vulnerability). Include the affected component, reproduction steps,
observed and expected behavior, and potential impact.

EOF
else
  cat >>"$destination/SECURITY.md" <<'EOF'

This repository is private, so GitHub does not expose the public-repository
vulnerability-reporting form. Contact a repository administrator through an
existing private channel. Include the affected component, reproduction steps,
observed and expected behavior, and potential impact.

EOF
fi
cat >>"$destination/SECURITY.md" <<'EOF'

You should receive a reply within 72 hours.

## Scope

EOF
if [ -n "$production_url" ]; then
  printf -- '- This repository and the deployment at %s\n' "$production_url" >>"$destination/SECURITY.md"
else
  printf -- '- This repository. It has no production deployment.\n' >>"$destination/SECURITY.md"
fi
printf '%s\n' '- Other Windward Line products have their own repositories and policies.' \
  >>"$destination/SECURITY.md"

if [ -f "$destination/templates/LICENSE" ]; then
  rm -f -- "$destination/templates/LICENSE"
  staged_paths+=("templates/LICENSE")
fi

set +e
placeholder_paths=$(grep -RIlE --exclude-dir=.git \
  '\{\{(NAME|DOMAIN)\}\}|TODO\((one sentence:|framework \+|exact dev/|the 3-6|app-class repos|prod-facing repos)|TODO: this repo.s real gates' \
  "$destination")
placeholder_rc=$?
set -e
case "$placeholder_rc" in
  0) die "generated repository still contains template placeholders: $(printf '%s' "$placeholder_paths" | tr '\n' ' ')" ;;
  1) ;;
  *) die "generated repository placeholder scan failed" ;;
esac
[ "$(wc -c <"$destination/CLAUDE.md" | tr -d ' ')" -eq 11 ] \
  || die "generated CLAUDE.md is not the exact pointer"

actionlint \
  "$destination/.github/workflows/ci.yml" \
  "$destination/.github/workflows/security.yml" \
  "$destination/.github/workflows/claude-review.yml" \
  "$destination/.github/workflows/dependabot-auto-merge.yml"
ruby "$INSPECTOR" dependabot <"$destination/.github/dependabot.yml" >/dev/null

ruby -e '
  directory = ARGV.fetch(0)
  expected = %w[ci.yml claude-review.yml dependabot-auto-merge.yml security.yml]
  actual = Dir.children(directory).sort
  abort "workflow population differs from the exact bootstrap set" unless actual == expected
  actual.each do |name|
    path = File.join(directory, name)
    stat = File.lstat(path)
    abort "workflow entry is not one regular file" unless stat.file? && !stat.symlink?
  end
' "$destination/.github/workflows"

[ ! -e "$destination/.gitleaks.toml" ] && [ ! -e "$destination/.gitleaksignore" ] \
  || die "generated repository contains a forbidden gitleaks override"

git -C "$destination" add --force -- "${staged_paths[@]}"
if git -C "$destination" diff --cached --quiet; then
  die "bootstrap produced no staged change"
fi
if ! "$GITLEAKS_BIN" git --staged --redact=100 --no-banner --no-color \
  --log-level info --ignore-gitleaks-allow "$destination" \
  >"$tmp/gitleaks.stdout" 2>"$tmp/gitleaks.stderr"; then
  die "staged secret scan failed; nothing was committed or pushed"
fi
scan_bytes=$(sed -nE 's/.*scanned ~.*\(([1-9][0-9]*)( bytes)?\) in .*/\1/p' \
  "$tmp/gitleaks.stderr" | tail -1)
printf '%s' "$scan_bytes" | grep -Eq '^[1-9][0-9]*$' \
  || die "staged secret scan reported no positive examined-byte count"
printf 'Staged secret scan: %s bytes examined.\n' "$scan_bytes"
git -C "$destination" commit -m "chore: bootstrap $display_name"
head_sha=$(git -C "$destination" rev-parse HEAD)
printf '%s' "$head_sha" | grep -Eq '^[0-9a-f]{40}$' || die "bootstrap commit SHA is malformed"

assert_destination_origin
git -C "$destination" push -u origin "$branch"
cat >"$tmp/pr-body.md" <<'EOF'
Installs the concrete project contract, proprietary license, ordered CI gates,
security scans, dependency policy, and fleet automation seeded by the canonical
bootstrap.

Documentation changes: README.md, AGENTS.md, SECURITY.md, and the license now
describe this repository rather than the fleet template.
EOF
pr_url=$(gh pr create --repo "$full_repository" --base main --head "$branch" \
  --title "chore: bootstrap $display_name" --body-file "$tmp/pr-body.md") \
  || die "bootstrap pull request could not be created"
printf '%s' "$pr_url" | grep -Eq '^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$' \
  || die "bootstrap pull request URL was malformed"

deadline=$(( $(date +%s) + WAIT_SECONDS ))
checks_json=""
while :; do
  checks_json=$(gh api --paginate --slurp \
    "repos/$full_repository/commits/$head_sha/check-runs?filter=latest&per_page=100") \
    || die "bootstrap check runs could not be read"
  if printf '%s' "$checks_json" | jq -e --argjson required "$(jq '.required_checks' "$tmp/plan.json")" '
      ([.[].check_runs[]] // []) as $runs |
      all($required[];
        . as $name |
        ([$runs[] | select(.name == $name)] | length) == 1 and
        ([$runs[] | select(.name == $name)][0].status == "completed"))
    ' >/dev/null; then
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] \
    || die "timed out waiting for every declared required check on $head_sha"
  sleep "$POLL_SECONDS"
done

printf '%s' "$checks_json" | jq -e \
  --argjson required "$(jq '.required_checks' "$tmp/plan.json")" \
  --argjson app "$actions_app_id" '
    ([.[].check_runs[]] // []) as $runs |
    all($required[];
      . as $name |
      ([$runs[] | select(.name == $name)] | length) == 1 and
      ([$runs[] | select(.name == $name)][0] |
        .status == "completed" and .app.id == $app and
        .conclusion == "success"))
  ' >/dev/null \
  || die "a declared required check failed, was ambiguous, or did not come from GitHub Actions"

# The manifest-derived required list is complete only if the actual GitHub
# Actions population contains no other PR job. A bootstrap PR has no repository
# secrets yet, so the canonical reusable review emits one successful gate and
# one skipped review; the Dependabot-only lane is skipped. Require all three by
# exact rendered check name. Deploy-platform Apps are excluded by App identity,
# as required by the fleet standard.
printf '%s' "$checks_json" | jq -e \
  --argjson required "$(jq '.required_checks' "$tmp/plan.json")" \
  --arg production_url "$production_url" \
  --argjson app "$actions_app_id" \
  --argjson advisory_base '{
      "review / gate": "success",
      "review / review": "skipped",
      "dependabot-auto-merge": "skipped"
    }' '
    ([.[].check_runs[] | select(.app.id == $app)] // []) as $actions |
    ($advisory_base +
      (if $production_url == "" then {} else {"Headers live": "skipped"} end)) as $advisory |
    ($required + ($advisory | keys)) as $known |
    all($actions[]; .name as $name | ($known | index($name)) != null) and
    all($advisory | to_entries[];
      . as $expected |
      ([$actions[] | select(.name == $expected.key)] | length) == 1 and
      ([$actions[] | select(.name == $expected.key)][0] |
        .status == "completed" and .conclusion == $expected.value))
  ' >/dev/null \
  || die "the live GitHub Actions check population contains an undeclared gate"

gh repo edit "$full_repository" --enable-auto-merge

ruleset_count=$(gh api --paginate --slurp "repos/$full_repository/rulesets?per_page=100" \
  --jq '[.[][] | select(.name == "main-requires-green-ci")] | length') \
  || die "existing rulesets could not be enumerated"
[ "$ruleset_count" -eq 0 ] || die "main-requires-green-ci already exists; refusing a duplicate"

jq -n \
  --argjson checks "$(jq '.required_checks' "$tmp/plan.json")" \
  --argjson app "$actions_app_id" '
  {
    name: "main-requires-green-ci",
    target: "branch",
    enforcement: "active",
    bypass_actors: [],
    conditions: {ref_name: {exclude: [], include: ["~DEFAULT_BRANCH"]}},
    rules: [
      {
        type: "required_status_checks",
        parameters: {
          strict_required_status_checks_policy: false,
          do_not_enforce_on_create: false,
          required_status_checks: [$checks[] | {context: ., integration_id: $app}]
        }
      },
      {type: "required_linear_history"},
      {type: "non_fast_forward"}
    ]
  }' >"$tmp/ruleset.json"
ruleset_id=$(gh api -X POST "repos/$full_repository/rulesets" --input "$tmp/ruleset.json" --jq '.id') \
  || die "main-requires-green-ci could not be created"
printf '%s' "$ruleset_id" | grep -Eq '^[0-9]+$' || die "created ruleset id was malformed"

gh pr merge "$pr_url" --squash --auto --delete-branch
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  pr_state=$(gh pr view "$pr_url" --json state,mergedAt,headRefOid,mergeCommit)
  if printf '%s' "$pr_state" | jq -e '.state == "MERGED" and (.mergedAt | type == "string")' >/dev/null; then
    break
  fi
  if printf '%s' "$pr_state" | jq -e '.state == "CLOSED" and .mergedAt == null' >/dev/null; then
    die "bootstrap pull request closed without merging"
  fi
  [ "$(date +%s)" -lt "$deadline" ] || die "timed out waiting for bootstrap pull request to merge"
  sleep "$POLL_SECONDS"
done

merged_head=$(printf '%s' "$pr_state" | jq -er '.headRefOid | select(type == "string")') \
  || die "merged pull request head could not be verified"
[ "$merged_head" = "$head_sha" ] \
  || die "merged pull request head differs from the validated bootstrap commit"
merge_commit=$(printf '%s' "$pr_state" | jq -er '.mergeCommit.oid | select(type == "string")') \
  || die "merged pull request commit could not be verified"
printf '%s' "$merge_commit" | grep -Eq '^[0-9a-f]{40}$' \
  || die "merged pull request commit SHA is malformed"
remote_main_after_merge=$(gh api "repos/$full_repository/commits/main" --jq '.sha') \
  || die "merged default-branch head could not be read"
[ "$remote_main_after_merge" = "$merge_commit" ] \
  || die "default branch moved before bootstrap credentials could be installed"
assert_destination_origin
git -C "$destination" fetch --prune origin
git -C "$destination" diff --quiet "$head_sha^{tree}" "$merge_commit^{tree}" -- \
  || die "merged repository tree differs from the validated bootstrap tree"

# Install repository credentials only after caller-supplied workflows have
# passed, the exact ruleset is active, and the verified merged tree equals the
# reviewed commit. These streams never enter a shell variable or file. The App
# helper proves the exact live App and all-repository installation from the same
# Keychain read whose decoded PEM it emits to gh, binding proof to upload.
"$SECURITY_BIN" find-generic-password -a "$keychain_account" -s anthropic-actions-oauth -w 2>/dev/null \
  | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$full_repository"
printf '%s' "$automerge_app_id" \
  | gh secret set FLEET_AUTOMERGE_APP_ID --app dependabot --repo "$full_repository"
"$SECURITY_BIN" find-generic-password -a "$keychain_account" -s github-automerge-app-key -w 2>/dev/null \
  | ruby "$APP_KEY_VERIFIER" --emit-pem \
  | gh secret set FLEET_AUTOMERGE_PRIVATE_KEY --app dependabot --repo "$full_repository"

gh api -X PUT "repos/$full_repository/vulnerability-alerts" >/dev/null
gh api -X PUT "repos/$full_repository/automated-security-fixes" >/dev/null
if [ "$visibility" = "public" ]; then
  gh api -X PUT "repos/$full_repository/private-vulnerability-reporting" >/dev/null
fi

repo_state=$(gh api "repos/$full_repository") || die "final repository settings could not be read"
printf '%s' "$repo_state" | jq -e \
  --arg visibility "$visibility" \
  '.archived == false and .default_branch == "main" and .allow_auto_merge == true and
   .visibility == $visibility' >/dev/null \
  || die "final repository settings do not match the bootstrap plan"

ruleset_state=$(gh api "repos/$full_repository/rulesets/$ruleset_id") \
  || die "created ruleset could not be verified"
printf '%s' "$ruleset_state" | jq -e \
  --argjson expected "$(cat "$tmp/ruleset.json")" '
    .name == $expected.name and .target == $expected.target and
    .enforcement == $expected.enforcement and .bypass_actors == [] and
    .conditions == $expected.conditions and
    [.rules[] | {type, parameters}] == [$expected.rules[] | {type, parameters}]
  ' >/dev/null || die "created ruleset differs from the exact requested rule set"

actions_secrets=$(gh secret list --repo "$full_repository" --json name)
printf '%s' "$actions_secrets" | jq -e \
  '[.[] | select(.name == "CLAUDE_CODE_OAUTH_TOKEN")] | length == 1' >/dev/null \
  || die "CLAUDE_CODE_OAUTH_TOKEN was not present after upload"
dependabot_secrets=$(gh secret list --app dependabot --repo "$full_repository" --json name)
printf '%s' "$dependabot_secrets" | jq -e '
  ([.[].name] | sort) as $names |
  ($names | index("FLEET_AUTOMERGE_APP_ID")) != null and
  ($names | index("FLEET_AUTOMERGE_PRIVATE_KEY")) != null
' >/dev/null || die "Dependabot App secret pair was not present after upload"

gh api "repos/$full_repository/vulnerability-alerts" >/dev/null \
  || die "Dependabot vulnerability alerts are not enabled"
security_fix=$(gh api "repos/$full_repository/automated-security-fixes") \
  || die "Dependabot automated security fixes could not be read"
printf '%s' "$security_fix" | jq -e '.enabled == true' >/dev/null \
  || die "Dependabot automated security fixes are not enabled"
if [ "$visibility" = "public" ]; then
  private_reporting=$(gh api "repos/$full_repository/private-vulnerability-reporting") \
    || die "private vulnerability reporting could not be read"
  printf '%s' "$private_reporting" | jq -e '.enabled == true' >/dev/null \
    || die "private vulnerability reporting is not enabled"
fi

git -C "$destination" fetch --prune origin
git -C "$destination" switch main
git -C "$destination" pull --ff-only origin main
[ -z "$(git -C "$destination" for-each-ref --format='%(refname)' "refs/remotes/origin/$branch")" ] \
  || die "merged remote bootstrap branch still exists: $branch"
git -C "$destination" branch -D "$branch" >/dev/null
[ -z "$(git -C "$destination" for-each-ref --format='%(refname)' "refs/heads/$branch")" ] \
  || die "local bootstrap branch still exists: $branch"
[ -z "$(git -C "$destination" status --porcelain)" ] || die "final local checkout is dirty"
[ "$(git -C "$destination" rev-parse HEAD)" = "$(git -C "$destination" rev-parse origin/main)" ] \
  || die "final local main does not match origin/main"

if [ -n "$production_url" ]; then
  /bin/bash --noprofile --norc \
    "$HEADER_PROBE_BIN" "$production_url" bootstrap
fi

/bin/bash --noprofile --norc "$CONFORMANCE_BIN"
printf 'Bootstrap complete: %s is merged, gated, verified, and clean on main.\n' "$full_repository"
