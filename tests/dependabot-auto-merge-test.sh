#!/bin/bash
#
# The auto-merge lane's DECISION LOGIC, exercised against a stubbed `gh`.
#
# Until 2026-09-07 nothing tested this file. It was pinned byte-identical
# fleet-wide by blob SHA, which proves every repo runs the same logic and says
# nothing about whether that logic is right — and the defect this suite was
# written for proves the difference. mimic#70 finished its four required checks
# in about 75 seconds, inside the time the job needs to reach its final line;
# GitHub refuses to ARM auto-merge on a pull request that is already mergeable;
# the step exited 1; and that failed check then kept the PR unstable, so a
# re-run met the identical refusal. A green, policy-approved patch bump latched
# open permanently, on the only repo fast enough to lose the race.
#
# The safety property under test is NOT "the lane merges nothing" — the lane
# now completes its own decision when arming comes too late. It is that every
# merge path goes through GitHub under a ruleset with zero bypass actors, so a
# refused merge fails the job rather than being swallowed. That is the last
# case below, and it is the one that matters most.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dependabot-auto-merge-test.XXXXXX")
builtin trap '/bin/rm -rf -- "$TMP"' EXIT HUP INT TERM

TEMPLATE="$ROOT/templates/dependabot-auto-merge.yml"
[ -r "$TEMPLATE" ] || { printf 'canonical template missing: %s\n' "$TEMPLATE" >&2; exit 2; }

# Extract the step body from the YAML rather than re-typing it, so the test
# cannot drift from the file the fleet actually runs.
ruby -ryaml -e '
  doc = YAML.safe_load(File.read(ARGV[0]))
  steps = doc.dig("jobs", "dependabot-auto-merge", "steps") or abort "no lane job"
  step = steps.find { |s| s["name"] == "Decide and arm" } or abort "no Decide and arm step"
  File.write(ARGV[1], step.fetch("run"))
' "$TEMPLATE" "$TMP/arm.sh" || { printf 'could not extract the arm step\n' >&2; exit 2; }

bash -n "$TMP/arm.sh" || { printf 'the arm step is not valid bash\n' >&2; exit 2; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'MOCK_GH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$GH_CALLS"
case "$*" in
  *"rules/branches/"*) echo "${GATES:-4}"; exit 0 ;;
  "api repos/"*) echo "${ALLOW_AUTO_MERGE:-true}"; exit 0 ;;
  "pr edit "*) exit 0 ;;
  "pr merge --squash --auto --delete-branch "*)
    if [ "${ARM_FAILS:-0}" = "1" ]; then
      echo "GraphQL: Pull request is in unstable status (enablePullRequestAutoMerge)" >&2
      exit 1
    fi
    exit 0 ;;
  "pr view "*"--json state,mergeable"*)
    i=$(cat "$STATE_IDX"); v=$(sed -n "${i}p" "$STATES")
    [ -n "$v" ] || v=$(tail -1 "$STATES")
    echo $((i + 1)) > "$STATE_IDX"
    printf '%s\n' "$v"; exit 0 ;;
  "pr merge --squash --delete-branch "*)
    if [ "${DIRECT_REFUSED:-0}" = "1" ]; then
      echo "GraphQL: Required status check is expected" >&2; exit 1
    fi
    exit 0 ;;
esac
exit 0
MOCK_GH
chmod +x "$TMP/bin/gh"

passes=0
failures=0

record_result() {
  if [ "$2" -eq 1 ]; then
    passes=$((passes + 1))
    printf 'ok   %s\n' "$1"
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n' "$1"
  fi
}

# Runs the step and reports: exit code, whether a DIRECT merge was attempted,
# and the summary heading. Extra env assignments override the defaults.
run_lane() {
  GH_CALLS="$TMP/calls"; STATES="$TMP/states"; STATE_IDX="$TMP/idx"
  : > "$GH_CALLS"; printf '%s\n' "$LANE_STATES" > "$STATES"; echo 1 > "$STATE_IDX"
  : > "$TMP/summary"
  local deps=${LANE_DEPS:-}
  if [ -z "$deps" ]; then
    deps='[{"dependencyName":"pkg","updateType":"version-update:semver-patch","prevVersion":"16.3.2","newVersion":"16.3.3"}]'
  fi
  env PATH="$TMP/bin:$PATH" \
    GH_CALLS="$GH_CALLS" STATES="$STATES" STATE_IDX="$STATE_IDX" \
    GITHUB_STEP_SUMMARY="$TMP/summary" \
    GITHUB_REPOSITORY=windwardline/testrepo GH_TOKEN=stub APP_ID=1 \
    PR=https://github.com/windwardline/testrepo/pull/70 BASE=main \
    UPDATE_TYPE="${LANE_UPDATE_TYPE:-version-update:semver-patch}" \
    MAINTAINER_CHANGES="${LANE_MAINTAINER:-false}" \
    DEP_NAMES=pkg LABELS="${LANE_LABELS:-dependencies}" AUTOMERGE_ON=false \
    DEPS_JSON="$deps" \
    ARM_FAILS="${LANE_ARM_FAILS:-0}" DIRECT_REFUSED="${LANE_DIRECT_REFUSED:-0}" \
    bash "$TMP/arm.sh" >"$TMP/out" 2>&1
  LANE_RC=$?
  if grep -q '^gh pr merge --squash --delete-branch' "$GH_CALLS"; then
    LANE_DIRECT=yes
  else
    LANE_DIRECT=no
  fi
  LANE_HEADING=$(grep -m1 '^###' "$TMP/summary" || true)
}

check() {
  local name="$1" want_rc="$2" want_direct="$3" want_heading="$4"
  if [ "$LANE_RC" -eq "$want_rc" ] &&
     [ "$LANE_DIRECT" = "$want_direct" ] &&
     case "$LANE_HEADING" in *"$want_heading"*) true ;; *) false ;; esac
  then
    record_result "$name" 1
  else
    record_result "$name" 0
    printf '  rc=%s (want %s), direct_merge=%s (want %s), heading=%s (want ...%s)\n' \
      "$LANE_RC" "$want_rc" "$LANE_DIRECT" "$want_direct" "${LANE_HEADING:-<none>}" "$want_heading"
    sed -n '1,20p' "$TMP/out" | sed 's/^/  /'
  fi
}

reset_env() {
  LANE_STATES="OPEN MERGEABLE"
  LANE_ARM_FAILS=0
  LANE_DIRECT_REFUSED=0
  LANE_UPDATE_TYPE=version-update:semver-patch
  LANE_MAINTAINER=false
  LANE_LABELS=dependencies
  unset LANE_DEPS
}

# --- the arming race, which is why this suite exists ---

reset_env; run_lane
check "arms auto-merge and merges nothing itself" 0 no "armed"

reset_env; LANE_ARM_FAILS=1; run_lane
check "merges directly when arming came too late" 0 yes "merged"

# Mergeability is computed asynchronously: UNKNOWN means "not decided yet".
# Reading it as "not mergeable" would hard-fail the very race this handles.
reset_env; LANE_ARM_FAILS=1; LANE_STATES=$'OPEN UNKNOWN\nOPEN MERGEABLE'; run_lane
check "waits out an undecided mergeability" 0 yes "merged"

reset_env; LANE_ARM_FAILS=1; LANE_STATES="MERGED MERGEABLE"; run_lane
check "accepts a pull request merged while it decided" 0 no "merged"

reset_env; LANE_ARM_FAILS=1; LANE_STATES="OPEN CONFLICTING"; run_lane
check "fails loudly when arming failed for a real reason" 1 no ""

# THE safety case. With zero bypass actors GitHub refuses a merge while any
# required check is unmet. That refusal must take the job down, never be
# swallowed into a green run — otherwise the fallback is a bypass.
reset_env; LANE_ARM_FAILS=1; LANE_DIRECT_REFUSED=1; run_lane
check "propagates a ruleset refusal instead of swallowing it" 1 yes ""

# --- the holds, unchanged: none of them may reach any merge call ---

hold_reaches_no_merge() {
  if grep -qE '^gh pr merge --squash( --auto)? --delete-branch' "$TMP/calls"; then
    return 1
  fi
  return 0
}

check_hold() {
  local name="$1"
  if [ "$LANE_RC" -eq 0 ] && hold_reaches_no_merge &&
     grep -q '### Dependabot auto-merge: held' "$TMP/summary"; then
    record_result "$name" 1
  else
    record_result "$name" 0
    sed -n '1,20p' "$TMP/out" | sed 's/^/  /'
  fi
}

reset_env; LANE_UPDATE_TYPE=version-update:semver-major; run_lane
check_hold "holds a major bump"

reset_env; LANE_MAINTAINER=true; run_lane
check_hold "holds a release that changed maintainers"

reset_env; LANE_LABELS=dependencies,no-automerge; run_lane
check_hold "holds on the no-automerge label"

reset_env; LANE_UPDATE_TYPE=version-update:semver-minor
LANE_DEPS='[{"dependencyName":"p","updateType":"version-update:semver-minor","prevVersion":"0.9.1","newVersion":"0.10.0"}]'
run_lane
check_hold "holds a pre-1.0 package Dependabot labelled minor"

reset_env; LANE_DEPS='[]'; run_lane
check_hold "holds when Dependabot metadata is unverifiable"

# A repo with no gate must hold rather than error, so that arming cannot
# degrade into an immediate ungated merge.
reset_env; run_lane_no_gate() { :; }
GATES=0
GH_CALLS="$TMP/calls"; STATES="$TMP/states"; STATE_IDX="$TMP/idx"
: > "$GH_CALLS"; echo "OPEN MERGEABLE" > "$STATES"; echo 1 > "$STATE_IDX"; : > "$TMP/summary"
env PATH="$TMP/bin:$PATH" GH_CALLS="$GH_CALLS" STATES="$STATES" STATE_IDX="$STATE_IDX" \
  GITHUB_STEP_SUMMARY="$TMP/summary" GITHUB_REPOSITORY=windwardline/testrepo GH_TOKEN=stub \
  PR=https://github.com/windwardline/testrepo/pull/70 BASE=main GATES=0 \
  UPDATE_TYPE=version-update:semver-patch MAINTAINER_CHANGES=false DEP_NAMES=pkg \
  LABELS=dependencies AUTOMERGE_ON=false \
  DEPS_JSON='[{"dependencyName":"pkg","updateType":"version-update:semver-patch","prevVersion":"1.0.0","newVersion":"1.0.1"}]' \
  bash "$TMP/arm.sh" >"$TMP/out" 2>&1
LANE_RC=$?
if [ "$LANE_RC" -eq 0 ] && grep -q 'no merge gate here' "$TMP/summary" &&
   ! grep -qE '^gh pr merge' "$TMP/calls"; then
  record_result "holds a repo with no merge gate" 1
else
  record_result "holds a repo with no merge gate" 0
  sed -n '1,20p' "$TMP/out" | sed 's/^/  /'
fi

printf '%s passed; %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
