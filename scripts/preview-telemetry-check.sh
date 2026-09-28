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
#     so the absence of rows is n/a, not a finding. A CANCELED build is not
#     counted, and neither is a static build with no function output, since
#     neither has a runtime that could error;
#   * preview deployments existed and preview log rows came back: proven;
#   * preview deployments existed and no preview row came back: UNPROVEN, a
#     finding, never folded into clean.
#
# Runtime logs are retained one day on Pro, so a preview built midweek and not
# visited since has no row to find. Before calling that UNPROVEN, the check
# requests the newest READY preview once with `vercel curl` and reads the logs
# again, so the proof is a row it caused. SSO protection is passed with the
# project's automation bypass, which `vercel curl` retrieves or generates
# through the existing CLI login and Vercel holds; nothing is stored here. The
# owner accepted that on 2026-09-27 and ruled out any per-app secret held
# locally. A probe answered 5xx is FAILING: run four found every preview
# 500ing on `/` while builds read Ready.
#
# The probe runs from a temporary directory whose .vercel/project.json this
# script writes itself. `vercel link` is avoided on purpose: it can pull
# environment variables to disk.
#
# Exit 0 every project is proven or n/a; 1 at least one is UNPROVEN or
# FAILING; 2 the check could not complete. A failed CLI call, an unparseable answer and an
# empty project list are all 2: an unread population is not an empty one.

set -u

SCOPE="windwardline"
SINCE=""
PROBE_WAIT=120

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
    --probe-wait) [ $# -ge 2 ] || incomplete "--probe-wait needs seconds"
             PROBE_WAIT="$2"; shift 2 ;;
    *) incomplete "unknown argument: $1" ;;
  esac
done

command -v vercel >/dev/null || incomplete "the vercel CLI is not installed"
command -v python3 >/dev/null || incomplete "python3 is not installed"

case "$PROBE_WAIT" in ''|*[!0-9]*) incomplete "--probe-wait must be whole seconds, got: $PROBE_WAIT" ;; esac

exec python3 - "$SCOPE" "$SINCE" "$PROBE_WAIT" <<'PY'
import datetime as dt
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

scope, since_arg, probe_wait = sys.argv[1], sys.argv[2], int(sys.argv[3])
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


def vercel(*args, cwd=None):
    # --scope belongs to vercel; anything after a `--` is handed to curl.
    args = list(args)
    cut = args.index("--") if "--" in args else len(args)
    proc = subprocess.run(
        ["vercel", *args[:cut], "--scope", scope, *args[cut:]],
        capture_output=True, text=True, timeout=120, cwd=cwd,
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
    """Count preview deployments created at or after `since`, and return the
    newest READY one's URL for the probe."""
    count, cursor, newest_ready = 0, None, None
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
            # A canceled build never rendered, so it is not a preview that could.
            if d.get("target") in (None, "preview") and d.get("state") != "CANCELED":
                count += 1
                if newest_ready is None and d.get("state") == "READY" and d.get("url"):
                    newest_ready = d["url"]
        cursor = (page.get("pagination") or {}).get("next")
        if reached_older or not deployments or cursor is None:
            return count, newest_ready


def runtime_functions(url):
    """Count the function outputs a deployment carries. Zero means a static
    build: nothing on Vercel can raise a runtime error, and an edge-cached
    request writes no log row. levelflow-cloud's Vite output is the case —
    its runtime lives in Supabase — and before this it read UNPROVEN weekly
    with nothing anyone could do about it."""
    detail = load(vercel("api", f"/v13/deployments/{url}"), f"the {url} deployment detail")
    lambdas = detail.get("lambdas") if isinstance(detail, dict) else None
    if not isinstance(lambdas, list):
        raise Incomplete(f"the {url} deployment detail carried no lambdas list")
    return sum(len(l.get("output") or []) for l in lambdas if isinstance(l, dict))


team_id = None


def resolve_team():
    global team_id
    if team_id is None:
        listing = load(vercel("teams", "ls", "--json"), "the team listing")
        teams = listing.get("teams") if isinstance(listing, dict) else None
        ids = [t.get("id") for t in teams or [] if isinstance(t, dict) and t.get("slug") == scope]
        if len(ids) != 1 or not ids[0]:
            raise Incomplete(f"could not resolve one team id for scope {scope}")
        team_id = ids[0]
    return team_id


def probe(project_id, url):
    """Request the preview once through its automation bypass; return the
    HTTP status."""
    with tempfile.TemporaryDirectory() as tmp:
        link = Path(tmp) / ".vercel"
        link.mkdir()
        (link / "project.json").write_text(
            json.dumps({"orgId": resolve_team(), "projectId": project_id}, separators=(",", ":"))
        )
        out = vercel("curl", "/", "--deployment", url, "--yes",
                     "--", "-s", "-o", "/dev/null", "-w", "%{http_code}", cwd=tmp)
    status = out.strip().splitlines()[-1] if out.strip() else ""
    if not (status.isdigit() and len(status) == 3) or status == "000":
        raise Incomplete(f"the probe of {url} returned no HTTP status")
    return int(status)


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
    ids = {p["name"]: p.get("id") for p in projects if isinstance(p, dict) and p.get("name")}
    names = sorted(ids)
    if len(names) != len(projects) or not all(ids.values()):
        raise Incomplete("a project in the listing carried no name or id")
except Incomplete as exc:
    print(f"preview-telemetry-check: INCOMPLETE — {exc}", file=sys.stderr)
    sys.exit(2)

unproven = incomplete = 0
print(f"Preview telemetry since {since.date()} (scope {scope})")
for name in names:
    try:
        n, ready_url = previews_since(name)
        if n == 0:
            verdict = "n/a — no preview deployment in the window"
        elif preview_rows(name):
            verdict = f"proven — {n} preview deployment(s), preview rows in retention"
        elif ready_url is None:
            verdict = f"UNPROVEN — {n} preview deployment(s), no row and none READY to probe"
            unproven += 1
        elif runtime_functions(ready_url) == 0:
            verdict = f"n/a — {n} preview deployment(s), static build with no runtime surface"
        else:
            status = probe(ids[name], ready_url)
            deadline = time.monotonic() + probe_wait
            rows = preview_rows(name)
            while not rows and time.monotonic() < deadline:
                time.sleep(10)
                rows = preview_rows(name)
            if status >= 500:
                verdict = f"FAILING — {n} preview deployment(s), newest answered HTTP {status}"
                unproven += 1
            elif rows:
                verdict = f"proven — {n} preview deployment(s), probed newest (HTTP {status}), {rows} preview row(s)"
            else:
                verdict = f"UNPROVEN — {n} preview deployment(s), probed newest (HTTP {status}), no row within {probe_wait}s"
                unproven += 1
    except (Incomplete, subprocess.TimeoutExpired) as exc:
        verdict = f"INCOMPLETE — {exc}"
        incomplete += 1
    print(f"  {name:28} {verdict}")

print(f"{len(names)} project(s) examined; {unproven} unproven or failing, {incomplete} incomplete.")
if incomplete:
    sys.exit(2)
sys.exit(1 if unproven else 0)
PY
