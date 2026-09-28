#!/bin/bash
# Preview telemetry check — CADENCE step 4's preview verdict, derived rather
# than judged by eye.
#
# The runtime-errors table mixes production and preview, and a zero from it is
# reportable only when a probe shows the pipeline returns rows in the
# environment being cleared. Production always has traffic to probe; preview
# often has none. Run thirteen (2026-09-27) found no preview rows on any app
# and could only report preview as unproven, the same words a broken pipeline
# would earn. The owner ruled the distinction the same evening:
#
#   * no preview deployment created since --since: nothing existed to render,
#     so the absence of rows is n/a, not a finding;
#   * preview deployments existed and preview log rows came back: proven;
#   * preview deployments existed and no preview row came back: UNPROVEN, a
#     finding, never folded into clean.
#
# Runtime logs are retained one day on Pro, so a preview built early in the
# week and not visited since reads UNPROVEN. That is deliberate: the ruling
# makes n/a depend on the deployment population, never on the logs.
#
# Exit 0 every project is proven or n/a; 1 at least one is UNPROVEN; 2 the
# check could not complete. A failed CLI call, an unparseable answer and an
# empty project list are all 2: an unread population is not an empty one.

set -u

SCOPE="windwardline"
SINCE=""

incomplete() {
  echo "preview-telemetry-check: INCOMPLETE — $1" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || incomplete "--since needs a date"
             SINCE="$2"; shift 2 ;;
    --scope) [ $# -ge 2 ] || incomplete "--scope needs a value"
             SCOPE="$2"; shift 2 ;;
    *) incomplete "unknown argument: $1" ;;
  esac
done

command -v vercel >/dev/null || incomplete "the vercel CLI is not installed"
command -v python3 >/dev/null || incomplete "python3 is not installed"

exec python3 - "$SCOPE" "$SINCE" <<'PY'
import datetime as dt
import json
import subprocess
import sys

scope, since_arg = sys.argv[1], sys.argv[2]
now = dt.datetime.now(dt.timezone.utc)
if since_arg:
    try:
        since = dt.datetime.strptime(since_arg, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        print(f"preview-telemetry-check: INCOMPLETE — --since must be YYYY-MM-DD, got {since_arg}", file=sys.stderr)
        sys.exit(2)
else:
    since = now - dt.timedelta(days=7)
since_ms = int(since.timestamp() * 1000)


class Incomplete(Exception):
    pass


def vercel(*args):
    proc = subprocess.run(
        ["vercel", *args, "--scope", scope],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        raise Incomplete(f"`vercel {' '.join(args)}` exited {proc.returncode}")
    return proc.stdout


def load(text, what):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise Incomplete(f"{what} was not JSON")


def previews_since(project):
    """Count preview deployments created at or after `since`."""
    count, cursor = 0, None
    while True:
        args = ["list", project, "--environment", "preview", "--json", "--limit", "100"]
        if cursor is not None:
            args += ["--next", str(cursor)]
        page = load(vercel(*args), f"the {project} deployment listing")
        deployments = page.get("deployments") if isinstance(page, dict) else None
        if not isinstance(deployments, list):
            raise Incomplete(f"the {project} deployment listing carried no deployments list")
        reached_older = False
        for d in deployments:
            created = d.get("createdAt") if isinstance(d, dict) else None
            if not isinstance(created, (int, float)) or isinstance(created, bool):
                raise Incomplete(f"a {project} deployment carried no numeric createdAt")
            if created < since_ms:
                reached_older = True
                continue
            if d.get("target") in (None, "preview"):
                count += 1
        cursor = (page.get("pagination") or {}).get("next")
        if reached_older or not deployments or cursor is None:
            return count


def preview_rows(project):
    out = vercel("logs", "--project", project, "--environment", "preview",
                 "--since", "24h", "--json", "--limit", "20")
    rows = 0
    for line in out.splitlines():
        if not line.strip():
            continue
        row = load(line, f"a {project} log line")
        if isinstance(row, dict) and row.get("environment") == "preview":
            rows += 1
    return rows


try:
    listing = load(vercel("project", "ls", "--json"), "the project listing")
    projects = listing.get("projects") if isinstance(listing, dict) else None
    if not isinstance(projects, list) or not projects:
        raise Incomplete("no projects returned for scope " + scope)
    names = sorted(p["name"] for p in projects if isinstance(p, dict) and p.get("name"))
    if len(names) != len(projects):
        raise Incomplete("a project in the listing carried no name")
except Incomplete as exc:
    print(f"preview-telemetry-check: INCOMPLETE — {exc}", file=sys.stderr)
    sys.exit(2)

unproven = incomplete = 0
print(f"Preview telemetry since {since.date()} (scope {scope})")
for name in names:
    try:
        n = previews_since(name)
        if n == 0:
            verdict = "n/a — no preview deployment in the window"
        else:
            rows = preview_rows(name)
            if rows:
                verdict = f"proven — {n} preview deployment(s), {rows} preview row(s) in retention"
            else:
                verdict = f"UNPROVEN — {n} preview deployment(s), no preview row in retention"
                unproven += 1
    except (Incomplete, subprocess.TimeoutExpired) as exc:
        verdict = f"INCOMPLETE — {exc}"
        incomplete += 1
    print(f"  {name:28} {verdict}")

print(f"{len(names)} project(s) examined; {unproven} unproven, {incomplete} incomplete.")
if incomplete:
    sys.exit(2)
sys.exit(1 if unproven else 0)
PY
