# vendored from internal-tooling harness/check-ci-parity.sh; do not edit here.
# Edit the source there and re-vendor (internal-tooling/scripts/vendor-harness.sh).
# vendored-from: internal-tooling@b808add
# vendored-sha256: 6ec5d5649648a7d7d5d36f8a2e6309e6c27485db8fbdc633deedab9c264599ce
# check-ci-parity.sh: the two CI copies must agree, so that "one definition" is enforced and not a
# convention. It checks two things:
#
#   1. A job in one copy exists in the other, unless it is a documented platform difference. A
#      repository names extra ones in scripts/ci-parity-allow.txt, and the scenario job is always one,
#      whatever it is called, because the two copies expand it differently.
#   2. The jobs the copies share run the same command: `lint` runs ./scripts/lint.sh and `defects`
#      runs `make defects PG=18` in both; a change to one command in one file fails here.
#
# Which files hold those jobs is per-repository, named in scripts/ci-parity-paths: one line per
# platform's workflow file, and `ignore` for a workflow that is out of scope. A repository with no
# such file keeps the default, .github/workflows/ci.yml against .forgejo/workflows/ci.yml. When the
# file is present it must be complete: a workflow file in either directory that is neither listed nor
# ignored fails, and so does a listed file that does not exist, so a workflow added later cannot
# escape the check silently. That is the same class of gap as a lint job that runs a subset of the
# checks and is otherwise green.
#
# The compare is over the jobs merged across a platform's files, so a repository may split them
# (pg_lock_tree has its Forgejo `lint` job in lint.yml but its `pgtap` jobs in test.yml).
#
# No shebang: this file is vendored and run with `bash`.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, sys, yaml

PATHFILE = "scripts/ci-parity-paths"
ALLOWFILE = "scripts/ci-parity-allow.txt"
DEFAULT = {"github": [".github/workflows/ci.yml"],
           "forgejo": [".forgejo/workflows/ci.yml"]}

def load_paths():
    if not os.path.exists(PATHFILE):
        return DEFAULT, None
    paths = {"github": [], "forgejo": []}
    ignore = []
    for raw in open(PATHFILE):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) == 2 and parts[0] in ("github", "forgejo"):
            paths[parts[0]].append(parts[1])
        elif len(parts) == 2 and parts[0] == "ignore":
            ignore.append(parts[1])
        else:
            print("  FAIL  %s: cannot parse %r" % (PATHFILE, line))
            sys.exit(1)
    return paths, ignore

paths, ignore = load_paths()
bad = []

# The paths file must be complete, or a workflow added later escapes the check silently.
if ignore is not None:
    accounted = set(paths["github"]) | set(paths["forgejo"]) | set(ignore)
    for d in (".github/workflows", ".forgejo/workflows"):
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith((".yml", ".yaml")):
                    p = "%s/%s" % (d, f)
                    if p not in accounted:
                        bad.append("%s is neither listed nor ignored in %s" % (p, PATHFILE))

for plat in ("github", "forgejo"):
    for p in paths[plat]:
        if not os.path.exists(p):
            bad.append("%s lists %s, which does not exist" % (PATHFILE, p))

def jobs_of(files):
    jobs = {}
    for p in files:
        if not os.path.exists(p):
            continue
        wf = yaml.safe_load(open(p)) or {}
        for name, job in (wf.get("jobs") or {}).items():
            jobs[name] = job
    return jobs

ghj = jobs_of(paths["github"])
fjj = jobs_of(paths["forgejo"])

allow = set()
if os.path.exists(ALLOWFILE):
    for raw in open(ALLOWFILE):
        line = raw.split("#", 1)[0].strip()
        if line:
            allow.add(line)

def is_platform_difference(n):
    return n.startswith("scenarios") or n in allow

for n in ghj:
    if n not in fjj and not is_platform_difference(n):
        bad.append("only on GitHub: %s" % n)
for n in fjj:
    if n not in ghj and not is_platform_difference(n):
        bad.append("only on Forgejo: %s" % n)

def command(job, needle):
    for st in (job.get("steps") or []):
        for line in (st.get("run") or "").splitlines():
            s = line.strip()
            if s.startswith("#"):
                continue   # a comment naming the command is not the command
            if needle in s:
                return s
    return None

for job, needle in (("lint", "scripts/lint.sh"), ("defects", "make defects")):
    if job not in ghj:
        bad.append("the GitHub copy has no %s job" % job)
    if job not in fjj:
        bad.append("the Forgejo copy has no %s job" % job)
    if job in ghj and job in fjj:
        a = command(ghj[job], needle)
        b = command(fjj[job], needle)
        if a != b:
            bad.append("%s runs different commands: %r vs %r" % (job, a, b))
        elif a is None:
            bad.append("the %s job does not run %s" % (job, needle))

if bad:
    print("  FAIL  the two CI copies disagree:")
    for b in bad:
        print("        " + b)
    sys.exit(1)
print("  ok    the two CI copies agree (%d GitHub, %d Forgejo workflow file(s), %d shared job(s))"
      % (len(paths["github"]), len(paths["forgejo"]), len(set(ghj) & set(fjj))))
PY
