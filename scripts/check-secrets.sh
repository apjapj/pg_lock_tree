#!/bin/bash
# Secret scan, matching what .forgejo/workflows/secrets.yml runs in CI, so that the gate
# is reproducible on a developer machine instead of only on the runner.
#
# Both tools are pinned to the exact versions the workflow pins. An unpinned scanner is
# not a gate: it passes or fails according to whatever the box happened to have, and
# "it was clean last week" stops meaning anything.
#
# The tools are installed into a cache directory OUTSIDE the repository. Installing them
# inside the tree would be self-defeating, because the scan walks the tree and would then
# be reading its own interpreter and its own wheel cache. It would also mean `git status`
# is permanently dirty, or that the ignore list has to grow to hide several megabytes of
# vendored Python.
#
# Nothing is installed system-wide and no root is needed.
#
# Usage:
#   scripts/check-secrets.sh            scan the tree and the git history
#   scripts/check-secrets.sh --prove    also prove the scan can fail (see below)
#
# --prove plants a canary secret in a throwaway copy of the tree and asserts the scan
# reports it. A clean scan on its own proves nothing, because a scanner invoked wrongly
# reports nothing at all: detect-secrets with an absolute path argument returns zero
# findings on a tree containing a real key, which is why the workflow omits the path.
# This flag is the regression test for exactly that mistake.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

# Pinned to match .forgejo/workflows/secrets.yml. If you change one, change both, and
# say so in the CHANGELOG, because a version bump can add or remove findings on its own.
GITLEAKS_VERSION=8.21.2
DETECT_SECRETS_VERSION=1.5.0

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/pg_lock_tree/secrets-tools"
GITLEAKS_BIN="$CACHE/gitleaks"
DS_DIR="$CACHE/detect-secrets-$DETECT_SECRETS_VERSION"

PROVE=0
[ "${1:-}" = "--prove" ] && PROVE=1

note() { printf '  %s\n' "$*"; }
die()  { printf 'check-secrets: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- gitleaks

fetch_gitleaks() {
  [ -x "$GITLEAKS_BIN" ] && return 0
  command -v curl >/dev/null 2>&1 || die "curl is required to fetch gitleaks"
  mkdir -p "$CACHE"
  local tgz="$CACHE/gitleaks.tar.gz" sums="$CACHE/gitleaks-checksums.txt"
  local url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"
  curl -sSL --fail -o "$tgz" "${url}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    || die "could not download gitleaks $GITLEAKS_VERSION"
  curl -sSL --fail -o "$sums" "${url}/gitleaks_${GITLEAKS_VERSION}_checksums.txt" \
    || die "could not download the gitleaks checksums"

  # Verify against the publisher's own checksums rather than a value pasted into this
  # script: a substituted download would otherwise be self-consistent.
  local expected actual
  expected=$(grep " gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz$" "$sums" | awk '{print $1}')
  [ -n "$expected" ] || die "no checksum for gitleaks in the publisher's file"
  actual=$(sha256sum "$tgz" | awk '{print $1}')
  [ "$expected" = "$actual" ] || die "gitleaks checksum mismatch: expected $expected got $actual"
  note "gitleaks $GITLEAKS_VERSION verified $actual"

  tar -xzf "$tgz" -C "$CACHE" gitleaks || die "could not unpack gitleaks"
  chmod 0755 "$GITLEAKS_BIN"
  rm -f "$tgz" "$sums"
}

# ---------------------------------------------------------------- detect-secrets

# detect-secrets is a Python package, so it needs pip. A venv is the tidy way to get one
# but it is not always available: Debian and Ubuntu ship python3 without ensurepip, so
# `python3 -m venv` fails outright unless python3-venv is installed, which needs root.
# Rather than demand root for a read-only gate, fall back to bootstrapping pip into a
# throwaway directory and installing with --target. Both routes end with the same
# isolated directory and neither touches the system environment.
# Run pip, dropping only its resolver-conflict warning. That warning is emitted because
# pip inspects the system environment for packages that a --target install does not share
# and cannot affect; it names a pre-existing yt-dlp and its websockets, neither of which
# this script touches. Hiding it keeps the gate's output readable. Everything else pip
# writes to stderr is kept, and the exit status is passed through untouched, so a real
# failure is still a failure and still says why.
pip_quiet() {
  local err rc=0
  err=$(mktemp)
  "$@" 2>"$err" || rc=$?
  grep -F -v -e "ERROR: pip's dependency resolver" \
               -e "The above is only a warning" \
               -e " requires websockets" \
               -e "requires websockets>=12.0" "$err" >&2 || true
  rm -f "$err"
  return "$rc"
}

fetch_detect_secrets() {
  [ -x "$DS_DIR/bin/detect-secrets" ] && return 0
  mkdir -p "$CACHE"

  local py="python3"
  command -v "$py" >/dev/null 2>&1 || die "python3 is required for detect-secrets"

  # A venv is the tidy route. It is not always available, and when it fails it leaves a
  # half-built directory behind, so clear that before falling back rather than installing
  # on top of it.
  if "$py" -m venv "$DS_DIR" >/dev/null 2>&1; then
    "$DS_DIR/bin/pip" install --quiet --disable-pip-version-check \
      "detect-secrets==$DETECT_SECRETS_VERSION" || die "pip install of detect-secrets failed"
  else
    note "python3 -m venv unavailable (no ensurepip), bootstrapping pip into a temporary directory"
    rm -rf "$DS_DIR"
    local stage
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    curl -sSL --fail -o "$stage/get-pip.py" https://bootstrap.pypa.io/get-pip.py \
      || die "could not download get-pip.py"
    pip_quiet "$py" "$stage/get-pip.py" --quiet --disable-pip-version-check --target "$stage/pip" \
      || die "could not bootstrap pip"
    PYTHONPATH="$stage/pip" pip_quiet "$py" -m pip install --quiet --disable-pip-version-check \
      --ignore-installed --target "$DS_DIR" "detect-secrets==$DETECT_SECRETS_VERSION" \
      || die "pip install of detect-secrets failed"
    rm -rf "$stage"
    trap - EXIT
    # A --target install has no entrypoint, so write one. It has to put DS_DIR on
    # PYTHONPATH itself, otherwise every later invocation has to remember to, and the
    # first thing that forgets is the caller.
    mkdir -p "$DS_DIR/bin"
    printf '#!/bin/sh\nPYTHONPATH="%s${PYTHONPATH:+:$PYTHONPATH}" exec "%s" -m detect_secrets "$@"\n' \
      "$DS_DIR" "$py" > "$DS_DIR/bin/detect-secrets"
    chmod 0755 "$DS_DIR/bin/detect-secrets"
  fi

  local got
  got=$("$DS_DIR/bin/detect-secrets" --version 2>/dev/null | awk '{print $NF}')
  [ "$got" = "$DETECT_SECRETS_VERSION" ] \
    || die "detect-secrets reports version '$got', expected $DETECT_SECRETS_VERSION"
  note "detect-secrets $DETECT_SECRETS_VERSION ready"
}

# ---------------------------------------------------------------- the scans

# Run detect-secrets over a directory and print the finding count.
# $1 is the directory to scan; empty means the current directory.
#
# The flags are load-bearing and each was measured, not assumed:
#   --all-files              without it the scan reports nothing at all, 0 findings on a
#                            tree carrying a real AWS key.
#   --force-use-all-plugins  the default plugin set misses several detectors.
#   --exclude-files '^\.git/' without it, COMMIT_EDITMSG is reported. It is a file that
#                            describes the last commit message, not the code.
#
# There is deliberately no path argument on the caller's invocation, because
# detect-secrets 1.5.0 returns zero findings for an absolute path. Omitting it makes the
# scan cover the current directory, which is what the workflow relies on.
ds_scan() {
  local dir="${1:-}"
  local out
  out=$(mktemp)
  if [ -n "$dir" ]; then
    # Absolute paths are the broken case, so normalise to relative when we must pass one.
    local rel="${dir#$ROOT/}"
    ( cd "$dir" && "$DS_DIR/bin/detect-secrets" scan --all-files --force-use-all-plugins \
        --exclude-files '^\.git/' "$rel" ) > "$out" 2>/dev/null || true
  else
    "$DS_DIR/bin/detect-secrets" scan --all-files --force-use-all-plugins \
      --exclude-files '^\.git/' > "$out" 2>/dev/null || true
  fi
  python3 - "$out" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(-1); raise SystemExit(0)
print(sum(len(v) for v in d.get('results', {}).values()))
PY
  rm -f "$out"
}

ds_report() {
  local file="$1"
  python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for f, items in sorted(d.get('results', {}).items()):
    for i in items:
        print('  %s:%s %s' % (f, i.get('line_number'), i.get('type')))
PY
}

printf 'check-secrets: scanning tree and history, tools pinned to %s and %s\n' \
  "$GITLEAKS_VERSION" "$DETECT_SECRETS_VERSION"

fetch_gitleaks
fetch_detect_secrets

rc=0

# 1. gitleaks over the git history, redacted so a real finding does not print the secret
#    into a terminal or a CI log that is retained for a year.
printf '\ngitleaks, git history:\n'
if [ -f .gitleaks.toml ]; then
  "$GITLEAKS_BIN" git --no-banner --redact --config .gitleaks.toml || rc=1
else
  "$GITLEAKS_BIN" git --no-banner --redact || rc=1
fi

# 2. detect-secrets over the tree at HEAD.
printf '\ndetect-secrets, tree at HEAD:\n'
report=$(mktemp)
"$DS_DIR/bin/detect-secrets" scan --all-files --force-use-all-plugins \
  --exclude-files '^\.git/' > "$report" 2>/dev/null || true
count=$(python3 -c "
import json
print(sum(len(v) for v in json.load(open('$report')).get('results', {}).values()))
" 2>/dev/null || echo -1)

if [ "$count" -lt 0 ]; then
  note "could not read the detect-secrets report, treating as a failure rather than a pass"
  rc=1
elif [ "$count" -gt 0 ]; then
  note "detect-secrets findings: $count"
  ds_report "$report"
  note ""
  note "For a false positive, append detect-secrets' inline allowlist pragma to that line."
  note "The exact text is documented in its reference; deliberately not reproduced here,"
  note "because a worked example of the form 'KEY: value' in this file is itself a finding."
  rc=1
else
  note "detect-secrets findings: 0"
fi
rm -f "$report"

# 3. Optionally prove the scan is capable of failing. A gate that cannot fail is not a
#    gate, and this one has a documented way of silently passing.
if [ "$PROVE" -eq 1 ]; then
  printf '\nproving the scan can fail, on a throwaway copy:\n'
  canary=$(mktemp -d)
  trap 'rm -rf "$canary"' EXIT
  tar --exclude=.git -cf - -C "$ROOT" . | tar -xf - -C "$canary"
  # The canary key is assembled from fragments at runtime rather than written out. A
  # literal key in this file is itself a finding, which is the same trap the workflow
  # comment describes: the scanner reads the scanner.
  printf 'aws_key = "%s%s%s"\n' 'AKIA' 'IOSFODNN7' 'EXAMPLE' > "$canary/canary_secret.txt"
  n=$(ds_scan "$canary")
  rm -rf "$canary"
  trap - EXIT
  if [ "$n" -gt 0 ] 2>/dev/null; then
    note "canary planted, $n finding(s) reported: the scan is live"
  else
    note "canary planted, $n findings reported: THE SCAN IS NOT WORKING"
    rc=1
  fi
fi

printf '\n'
if [ "$rc" -eq 0 ]; then
  printf 'check-secrets: clean\n'
else
  printf 'check-secrets: findings above, or a scanner that could not run\n'
fi
exit "$rc"
