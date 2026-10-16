# vendored from pg-dev-infra harness/check-vendored-hashes.sh; do not edit here.
# Edit the source there and re-vendor (pg-dev-infra/scripts/vendor-harness.sh).
# vendored-from: pg-dev-infra@5310af5
# vendored-sha256: 93ba35d6183fd32db9074c06cc3e243842d911f92b0e0d7714bdb4c488b98abb
# check-vendored-hashes.sh: every vendored harness file in this repository must match the sha256 in
# its own header. The canonical lives in the private pg-dev-infra, which this repository's public CI
# cannot reach, so this is the in-repo half of the sync: a hand edit to a vendored file turns this red
# at once. pg-dev-infra's own check catches the other half, a canonical change a repo has not adopted.
# No shebang: this file is vendored and run with `bash`.
set -uo pipefail
cd "$(dirname "$0")/.."

bad=""
for f in scripts/order-rules.sh scripts/check-ci-parity.sh scripts/check-vendored-hashes.sh; do
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
    echo "        re-vendor from pg-dev-infra/scripts/vendor-harness.sh; do not edit the copy"
    exit 1
fi
