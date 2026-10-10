#!/usr/bin/env bash
# scripts/check-ci-github.sh: scripts/check-ci.sh for GitHub Actions. A DRAFT for the move to GitHub:
# it has been run only against a local mock of the Actions API (see the commit that added it), never
# against github.com, and nothing uses it for a tag until it has been.
#
# Same rules, same configuration shape, same exit codes as check-ci.sh. What differs is the API:
#   base        https://api.github.com, Bearer token, Accept: application/vnd.github+json
#   runs        GET /repos/{owner}/{repo}/actions/runs?head_sha={sha}&per_page=100
#               a run is finished when status == "completed", and green when conclusion == "success"
#               (Forgejo has one `status` field that is "success"; GitHub splits it in two)
#   workflow    identified by the basename of the run's `path` (.github/workflows/ci.yml -> ci.yml),
#               so ci-gates keys are the same workflow file names as on Forgejo
#   jobs        GET /repos/{owner}/{repo}/actions/runs/{id}/jobs, under a "jobs" key; a matrix job is
#               named "test (14)", so a gate names the job WITHOUT the matrix suffix and matches any
#               job whose name is it, or starts with it followed by " ("
#
# What follows is check-ci.sh's own header, which still applies word for word.
#
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
#   git config pg-lock-tree.ci-api    https://api.github.com     (the default here)
#   git config pg-lock-tree.ci-token  /path/to/token             (default $XDG_CONFIG_HOME/github/token)
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

api=$(cfg ci-api); [ -n "$api" ] || api="https://api.github.com"; api=${api%/}

# WHICH REMOTE, and why this is not simply `origin`.
#
# The first run of this script against a real repository caught itself. It read `origin` for the push
# check while querying api.github.com for the runs. With one remote that is fine, and the local mock
# has one remote, so the mock could not have found it. With origin=Forgejo and github=GitHub the two
# halves disagreed, and it reported a Forgejo state against a GitHub API.
#
# So the remote is derived from the API base rather than assumed, and it can still be named outright.
# Two rules, in order:
#
#   1. pg-lock-tree.ci-remote, if set. An explicit override always wins.
#   2. Otherwise the first remote whose URL names the same site as the API. The API host is
#      api.github.com and the git host is github.com, so the leading "api." is dropped before
#      matching; GitLab and Gitea serve both from one host, so the bare host is tried as well.
#      https://github.com/apjapj/pg_lock_tree.git matches and git@<forgejo-host>:... does not.
#
# Rule 2 is what makes the default correct with several remotes present, which is the normal state
# now that both platforms are in use. It is also why the first attempt at this failed and refused:
# matching "api.github.com" against a git URL finds nothing, and refusing is what that should do.
remote=$(cfg ci-remote)
if [ -z "$remote" ]; then
    api_host=$(printf '%s' "$api" | sed -E 's#^https?://##; s#[:/].*$##')
    site_host=${api_host#api.}
    for r in $(git remote); do
        url=$(git remote get-url "$r" 2>/dev/null) || continue
        if printf '%s' "$url" | grep -q "$site_host" || printf '%s' "$url" | grep -q "$api_host"; then
            remote=$r
            break
        fi
    done
fi
[ -n "$remote" ] || die "no remote points at $api, so there is nowhere to read CI from. Name one with: git config pg-lock-tree.ci-remote <name>. Refusing."

remote_url=$(git remote get-url "$remote" 2>/dev/null) || die "remote '$remote' has no URL."

# owner/repo out of either an ssh or an https remote.
#
# Two shapes, handled differently, because a one-size-fits-all strip gets one of them wrong:
#
#   scheme://authority/owner/repo.git   strip the scheme, then the authority
#   [user@]host:owner/repo.git          strip up to the colon
#
# ${x#*:} alone is wrong for the first shape: it stops at the colon in "https:", leaving the host and a
# doubled slash, so owner comes out empty and the request 404s in a way that reads like a permissions
# problem. Stripping "everything up to the first /" is wrong for the second: it eats the owner and
# leaves the repo name. Both were found by pointing this at a real https remote, which the local mock
# with a single ssh remote could never have produced. Same fix as in check-ci.sh, deliberately.
case "$remote_url" in
    *://*) path=${remote_url#*://}; path=${path#*/} ;;   # https://host/owner/repo.git
    *:*)   path=${remote_url#*:} ;;                      # [user@]host:owner/repo.git
    *)     path=$remote_url ;;
esac
path=${path%.git}
path=${path#/}
case "$path" in
    */*) : ;;
    *)   die "cannot read owner/repo out of remote '$remote_url' (got '$path'). Refusing." ;;
esac
owner=${path%%/*}
repo=${path##*/}

token_file=$(cfg ci-token)
[ -n "$token_file" ] || token_file="${XDG_CONFIG_HOME:-$HOME/.config}/github/token"
[ -r "$token_file" ] || die "no readable token at '$token_file'. Set: git config pg-lock-tree.ci-token <path>. Refusing."

subject=$(git log -1 --format=%s "$sha" | cut -c1-60)

# Is the commit on THAT remote, the one whose runs are about to be read? A commit nobody pushed has no
# runs, and "no runs" must never be mistaken for "no problems".
# "On the remote" means reachable from a remote ref, not equal to one. Every commit except the tip has
# already been superseded by a later push, and ls-remote only lists tips, so a plain grep would report
# the entire history as unpushed.
tips=$(git ls-remote "$remote" 2>/dev/null | awk '{print $1}') \
  || die "cannot reach '$remote' to confirm $sha was pushed. Refusing rather than assume it was."
[ -n "$tips" ] || die "'$remote' has no refs. Refusing rather than assume the push landed."

pushed=0
for tip in $tips; do
    if [ "$tip" = "$sha" ] || git merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
        pushed=1
        break
    fi
done
[ "$pushed" -eq 1 ] \
  || die "$sha ($subject) is not on $remote yet. Push it and let CI run first."

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
        headers={"Authorization": "Bearer " + token,
                 "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.urlopen(req, timeout=30) as fh:
            return json.load(fh)
    except urllib.error.HTTPError as e:
        fail("CI API returned HTTP %s for %s. Refusing." % (e.code, path))
    except Exception as e:
        fail("could not reach the CI API at %s (%s). Refusing." % (api, e))
    except json.JSONDecodeError as e:
        fail("CI API at %s returned something that is not JSON (%s). Refusing." % (api, e))

runs = get("/repos/%s/%s/actions/runs?head_sha=%s&per_page=100" % (owner, repo, sha)).get("workflow_runs")
if runs is None:
    fail("CI API returned no workflow_runs list. Refusing.")

# Latest run per workflow for this commit. A stale 'cancelled' run left behind by a superseded
# push must not veto a release forever, and the latest run is what a human reads in the Actions
# tab, so that is what counts.
latest = {}
for r in runs:
    if str(r.get("head_sha", "")) == sha:
        wf = os.path.basename(str(r.get("path", ""))) or str(r.get("name") or "?")
        if wf not in latest or r["id"] > latest[wf]["id"]:
            latest[wf] = r

print("  CI for %s  %s" % (sha[:7], subject))
print("")

if not latest:
    fail("%s has no CI run at all. A commit nobody tested is not releasable." % sha[:7])

bad = []
for wf in sorted(latest):
    r = latest[wf]
    # Finished AND green. A run that is queued or in progress has conclusion null, and must be
    # refused as "not finished", never read as "not failed".
    status, conclusion = r.get("status"), r.get("conclusion")
    shown = conclusion if status == "completed" else status
    print("  %-12s run %-12s %s" % (wf, r["id"], shown))
    if status != "completed" or conclusion != "success":
        if r.get("html_url"):
            print("      %s" % r["html_url"])
        bad.append("%s run %s is '%s', not a completed success" % (wf, r["id"], shown))
        continue

    if wf not in gates:
        continue

    jobs = get("/repos/%s/%s/actions/runs/%s/jobs?per_page=100" % (owner, repo, r["id"])).get("jobs")
    if jobs is None:
        fail("CI API returned no jobs list for run %s. Refusing." % r["id"])
    names = [j.get("name", "") for j in jobs]
    gate = gates[wf]
    if not any(n == gate or n.startswith(gate + " (") for n in names):
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