#!/bin/bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$ROOT/scripts/preview-telemetry-check.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/preview-telemetry-check-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"

# Stub vercel. Each subcommand answers from a fixture in $STUB_DIR, keyed by
# project and page, and a missing fixture is a failed call.
cat >"$TMP/bin/vercel" <<'MOCK_VERCEL'
#!/bin/bash
sub=$1; shift
project=""; next="first"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) project=$2; shift ;;
    --next) next=$2; shift ;;
    --environment|--scope|--limit|--since) shift ;;
    --*) ;;
    *) [ -z "$project" ] && project=$1 ;;
  esac
  shift
done
case "$sub" in
  project) f="$STUB_DIR/projects.json" ;;
  list) f="$STUB_DIR/list-$project-$next.json" ;;
  logs) f="$STUB_DIR/logs-$project.jsonl" ;;
  *) exit 98 ;;
esac
[ -f "$f" ] || exit 9
cat "$f"
MOCK_VERCEL
chmod +x "$TMP/bin/vercel"

pass=0
fail=0
IN_WINDOW=1790500000000
BEFORE_WINDOW=1789000000000

scenario() {
  STUB_DIR="$TMP/$1"
  rm -rf "$STUB_DIR"
  mkdir -p "$STUB_DIR"
  printf '{"projects":[{"name":"alpha","id":"prj_a"}]}' >"$STUB_DIR/projects.json"
}

deployments() { # project page next createdAt...
  local project=$1 page=$2 nxt=$3
  shift 3
  local items="" sep=""
  for ts in "$@"; do
    items="$items$sep{\"url\":\"$project-$ts.vercel.app\",\"target\":null,\"createdAt\":$ts,\"state\":\"READY\"}"
    sep=","
  done
  printf '{"deployments":[%s],"pagination":{"count":%d,"next":%s}}' \
    "$items" "$#" "$nxt" >"$STUB_DIR/list-$project-$page.json"
}

run() {
  OUT=$(PATH="$TMP/bin:$PATH" STUB_DIR="$STUB_DIR" "$CHECK" --since 2026-09-21 2>&1)
  CODE=$?
}

expect() { # name code pattern
  if [ "$CODE" -eq "$2" ] && printf '%s' "$OUT" | grep -q -- "$3"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: exit %s (want %s), output:\n%s\n' "$1" "$CODE" "$2" "$OUT"
  fi
}

# No preview deployment in the window: there was nothing to render, so the
# absence of rows is not a finding.
scenario none
deployments alpha first null
run
expect "no previews is n/a" 0 "alpha.*n/a"

# Only deployments older than the window are the same case.
scenario old
deployments alpha first null "$BEFORE_WINDOW"
run
expect "previews before the window are n/a" 0 "alpha.*n/a"

# Previews existed and the pipeline returned preview rows.
scenario proven
deployments alpha first null "$IN_WINDOW"
printf '{"environment":"preview","responseStatusCode":200}\n' >"$STUB_DIR/logs-alpha.jsonl"
run
expect "previews with rows are proven" 0 "alpha.*proven"

# Previews existed and nothing came back: unproven is a finding, never clean.
scenario unproven
deployments alpha first null "$IN_WINDOW"
: >"$STUB_DIR/logs-alpha.jsonl"
run
expect "previews without rows are unproven" 1 "alpha.*UNPROVEN"

# A row from another environment proves nothing about preview.
scenario wrong-env
deployments alpha first null "$IN_WINDOW"
printf '{"environment":"production","responseStatusCode":200}\n' >"$STUB_DIR/logs-alpha.jsonl"
run
expect "a production row does not prove preview" 1 "alpha.*UNPROVEN"

# A production deployment in a preview listing is not counted as a preview.
scenario prod-in-list
printf '{"deployments":[{"url":"x","target":"production","createdAt":%s}],"pagination":{"next":null}}' \
  "$IN_WINDOW" >"$STUB_DIR/list-alpha-first.json"
run
expect "production targets are not previews" 0 "alpha.*n/a"

# The first page is entirely inside the window, so the next page must be read.
scenario paged
deployments alpha first 555 "$IN_WINDOW"
deployments alpha 555 null "$IN_WINDOW" "$BEFORE_WINDOW"
: >"$STUB_DIR/logs-alpha.jsonl"
run
expect "pagination is followed" 1 "alpha.*2 preview"

# Every failure to read is incomplete, never a pass.
scenario list-fails
run
expect "a failed listing is incomplete" 2 "alpha"

scenario logs-fail
deployments alpha first null "$IN_WINDOW"
run
expect "a failed log read is incomplete" 2 "alpha"

scenario no-projects
printf '{"projects":[]}' >"$STUB_DIR/projects.json"
run
expect "an empty project list is incomplete" 2 "no projects"

scenario malformed
printf 'not json' >"$STUB_DIR/list-alpha-first.json"
run
expect "a malformed listing is incomplete" 2 "alpha"

# The summary states what was examined, so a clean run is visibly non-empty.
scenario summary
deployments alpha first null
run
expect "the summary counts projects examined" 0 "1 project(s) examined"

OUT=$("$CHECK" --bogus 2>&1)
CODE=$?
expect "an unknown argument is incomplete" 2 "bogus"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
