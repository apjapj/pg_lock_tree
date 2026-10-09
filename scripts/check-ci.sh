#!/usr/bin/env bash
# scripts/check-ci.sh: refuse to treat a commit as releasable unless CI has actually run on it
# and actually passed.
#
# Why this exists: v1.1.11 shipped with a `make install` that failed on every PostgreSQL version,
# and CI caught it. .forgejo/workflows/test.yml has a job called `install-path checks` that runs
# `make install`, the tag push triggered it, and it went red with the same
# `install: will not overwrite just-created` error that was later found by hand. Nobody read the
# run, because nothing in this repository read it either. A gate that reports success because
# nobody looked is worse than no gate, so this reads it.
#
# FAIL CLOSED, in every direction:
#   * no token, no network, no API, malformed JSON            -> refuse
#   * the commit is not on the remote yet                     -> refuse
#   * CI has not started, or is running, or waiting           -> refuse
#   * any workflow's latest run is not `success`              -> refuse
#   * a workflow reported success but the job that does the   -> refuse
#     gating is missing from it
# That last one matters more than it looks. A workflow whose gating job is renamed, or dropped by
# a bad merge, reports success forever, and a gate that can silently stop gating is not a gate.
#
# Usage:  scripts/check-ci.sh [commit-ish]        (default: HEAD)
#
# Configuration, read from git config so it survives a fresh clone:
#   git config pg-lock-tree.ci-api    http://host:3000           (default http://<remote host>:3000)
#   git config pg-lock-tree.ci-token  /path/to/token             (default $XDG_CONFIG_HOME/forgejo/token)
#   git config pg-lock-tree.ci-gates  'test.yml=install-path checks'
#
# ci-gates maps a workflow to the job inside it that must exist for the run to mean anything.
# Every workflow on the commit must be green regardless; the gates are an extra check, and only on
# the workflows named. lint.yml and secrets.yml have jobs of their own and are not expected to
# carry the one from test.yml.
#
# Exit 0 = every workflow green. Exit 1 = not releasable, with the reason.
set -euo pipefail

die() { printf 'check-ci: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is not installed, so CI status cannot be read. Refusing."

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$repo_root"

cfg() { git config "pg-lock-tree.$1" 2>/dev/null || true; }

sha=$(git rev-parse --verify "${1:-HEAD}^{commit}" 2>/dev/null) \
  || die "'${1:-HEAD}' is not a commit in this repository"

remote_url=$(git remote get-url origin 2>/dev/null) || die "no origin remote, so there is no CI to ask"

# owner/repo out of either an ssh or an https remote
path=${remote_url#*:}
path=${path%.git}
path=${path#/}
case "$path" in
    */*) : ;;
    *)   die "cannot read owner/repo out of remote '$remote_url'. Refusing." ;;
esac
owner=${path%%/*}
repo=${path##*/}

host=$(printf '%s' "$remote_url" | sed -E 's#^(ssh://)?git@##; s#^(https?://)##; s#[:/].*$##')

api=$(cfg ci-api); [ -n "$api" ] || api="http://${host}:3000"; api=${api%/}

token_file=$(cfg ci-token)
[ -n "$token_file" ] || token_file="${XDG_CONFIG_HOME:-$HOME/.config}/forgejo/token"
[ -r "$token_file" ] || die "no readable token at '$token_file'. Set: git config pg-lock-tree.ci-token <path>. Refusing."

subject=$(git log -1 --format=%s "$sha" | cut -c1-60)

# Is the commit even on the remote? A commit nobody pushed has no runs, and "no runs" must never
# be mistaken for "no problems".
# "On the remote" means reachable from a remote ref, not equal to one. Every commit except the tip
# has already been superseded by a later push, and ls-remote only lists tips, so a plain grep would
# report the entire history as unpushed.
tips=$(git ls-remote origin 2>/dev/null | awk '{print $1}') \
  || die "cannot reach origin to confirm $sha was pushed. Refusing rather than assume it was."
[ -n "$tips" ] || die "origin has no refs. Refusing rather than assume the push landed."

pushed=0
for tip in $tips; do
    if [ "$tip" = "$sha" ] || git merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
        pushed=1
        break
    fi
done
[ "$pushed" -eq 1 ] \
  || die "$sha ($subject) is not on origin yet. Push it and let CI run first."

gates=$(cfg ci-gates); [ -n "$gates" ] || gates="test.yml=install-path checks"

# The token is read inside python and never appears in argv, so it cannot show up in ps output.
CI_GATE_SHA="$sha" CI_GATE_API="$api" CI_GATE_OWNER="$owner" CI_GATE_REPO="$repo" \
CI_GATE_TOKEN_FILE="$token_file" CI_GATE_JOBS="$gates" CI_GATE_SUBJECT="$subject" \
python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

sha     = os.environ["CI_GATE_SHA"]
api     = os.environ["CI_GATE_API"]
owner   = os.environ["CI_GATE_OWNER"]
repo    = os.environ["CI_GATE_REPO"]
subject = os.environ["CI_GATE_SUBJECT"]
# "workflow=job;workflow2=job2" -> {workflow: job}. A workflow listed here must still contain its
# job; a workflow not listed here is only required to be green.
gates = {}
for pair in os.environ["CI_GATE_JOBS"].split(";"):
    if "=" in pair:
        wf, job = pair.split("=", 1)
        gates[wf.strip()] = job.strip()

def fail(msg):
    sys.stderr.write("check-ci: %s\n" % msg)
    sys.exit(1)

try:
    with open(os.environ["CI_GATE_TOKEN_FILE"]) as fh:
        token = fh.read().strip()
except OSError as e:
    fail("cannot read the token file (%s). Refusing." % e)
if not token:
    fail("token file is empty. Refusing.")

def get(path):
    req = urllib.request.Request(
        api + path,
        headers={"Authorization": "token " + token, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as fh:
            return json.load(fh)
    except urllib.error.HTTPError as e:
        fail("CI API returned HTTP %s for %s. Refusing." % (e.code, path))
    except Exception as e:
        fail("could not reach the CI API at %s (%s). Refusing." % (api, e))
    except json.JSONDecodeError as e:
        fail("CI API at %s returned something that is not JSON (%s). Refusing." % (api, e))

runs = get("/api/v1/repos/%s/%s/actions/runs?limit=50&page=1" % (owner, repo)).get("workflow_runs")
if runs is None:
    fail("CI API returned no workflow_runs list. Refusing.")

# Latest run per workflow for this commit. A stale 'cancelled' run left behind by a superseded
# push must not veto a release forever, and the latest run is what a human reads in the Actions
# tab, so that is what counts.
latest = {}
for r in runs:
    if str(r.get("commit_sha", "")).startswith(sha):
        wf = r.get("workflow_id") or r.get("prettyref") or "?"
        if wf not in latest or r["id"] > latest[wf]["id"]:
            latest[wf] = r

print("  CI for %s  %s" % (sha[:7], subject))
print("")

if not latest:
    fail("%s has no CI run at all. A commit nobody tested is not releasable." % sha[:7])

bad = []
for wf in sorted(latest):
    r = latest[wf]
    status = r.get("status")
    print("  %-12s run %-5s %s" % (wf, r["id"], status))
    if status != "success":
        if r.get("html_url"):
            print("      %s" % r["html_url"])
        bad.append("%s run %s is '%s', not 'success'" % (wf, r["id"], status))
        continue

    if wf not in gates:
        continue

    jobs = get("/api/v1/repos/%s/%s/actions/runs/%s/jobs" % (owner, repo, r["id"]))
    names = [j.get("name", "") for j in jobs]
    if gates[wf] not in names:
        bad.append("%s run %s says success but has no job named %r: "
                   "the gate has stopped gating" % (wf, r["id"], gates[wf]))
    else:
        print("      gating job present: %s" % gates[wf])

print("")
for b in bad:
    sys.stderr.write("  FAIL  %s\n" % b)
if bad:
    sys.exit(1)
print("  every workflow green on %s" % sha[:7])
PY