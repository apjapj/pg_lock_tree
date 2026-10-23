# vendored from internal-tooling harness/check-vendored-hashes.sh; do not edit here.
# Edit the source there and re-vendor (internal-tooling/scripts/vendor-harness.sh).
# vendored-from: internal-tooling@be60e58
# vendored-sha256: da9f8bba5eac727d216ab058f68151a165012e1a9760165311042194f1caa266
# check-vendored-hashes.sh: every vendored harness file in this repository must match the sha256 in
# its own header. The canonical lives in the private internal-tooling, which this repository's public CI
# cannot reach, so this is the in-repo half of the sync: a hand edit to a vendored file turns this red
# at once. internal-tooling's own check catches the other half, a canonical change a repo has not adopted.
# No shebang: this file is vendored and run with `bash`.
set -uo pipefail
cd "$(dirname "$0")/.."

bad=""
for f in scripts/order-rules.sh scripts/check-ci-parity.sh scripts/check-vendored-hashes.sh scripts/docker-guard.sh; do
    [ -e "$f" ] || continue
    declared=$(sed -n 's/^# vendored-sha256: //p' "$f" | head -1)
    if [ -z "$declared" ]; then bad="$bad $f(no hash in header)"; continue; fi
    body=$(mktemp)
    sed '1,/^# vendored-sha256:/d' "$f" > "$body"
    got=$(sha256sum "$body" | cut -d' ' -f1)
    rm -f "$body"
    [ "$declared" = "$got" ] || bad="$bad $f(declared ${declared%${declared#????????????}}, computed ${got%${got#????????????}})"
done
if [ -z "$bad" ]; then
    echo "  ok    every vendored harness file matches its header hash"
else
    echo "  FAIL  a vendored harness file does not match its header hash:$bad"
    echo "        re-vendor from internal-tooling/scripts/vendor-harness.sh; do not edit the copy"
    exit 1
fi
