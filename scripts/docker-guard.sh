# vendored from pg-dev-infra harness/docker-guard.sh; do not edit here.
# Edit the source there and re-vendor (pg-dev-infra/scripts/vendor-harness.sh).
# vendored-from: pg-dev-infra@be60e58
# vendored-sha256: 19b284c1e88e28ee4870d5b69bc8cc918ee303543091aa2ac1a9b00a65e05f23
#!/usr/bin/env bash
# docker-guard.sh: keep a host's Docker footprint from growing without bound.
#
# Two modes, deliberately separate, so a CI job never deletes and a housekeeping run never fails a
# build. Run `check` in CI on every job; run `cleanup` from a host timer.
#
#   check     fail if the filesystem is at DG_DISK_PCT_MAX or more, or DG_UNUSED_VOL_MAX or more
#             dangling volumes remain. Deletes nothing.
#   cleanup   remove stopped containers, dangling volumes and old build cache, but only those older
#             than DG_AGE. Prints what it would remove unless --apply is given. Never a gate.
#
# The leak this exists for. The postgres image declares a data volume, so a container removed with
# `docker rm -f` (no -v) after `docker run` without --rm leaves an anonymous volume behind, about
# 290 MB each. Over a thousand accumulated on one host and took the disk to 95%. `docker rm -f -v`
# stops it at the source; this notices if it starts again, and reclaims what is already there. It is
# not the fix, it is the smoke alarm.
#
# Exit codes, the family's table: 0 fine, 1 the check failed, 3 could not run. A Docker daemon that
# is not reachable is 3, never 0, so "Docker is down" is never read as "no leak".
#
# Defaults are here, once, and every one is an environment override, so a host can tighten them
# without editing the vendored copy:
#
#   DG_DISK_PCT_MAX   85      fail `check` at or above this percent full
#   DG_UNUSED_VOL_MAX 25      fail `check` at or above this many dangling volumes
#   DG_AGE            168h    leave containers and volumes younger than this (a week)
#   DG_PATH           /       the filesystem `check` looks at
#
# Usage:
#   docker-guard.sh check
#   docker-guard.sh cleanup [--apply]

set -uo pipefail

DG_DISK_PCT_MAX=${DG_DISK_PCT_MAX:-85}
DG_UNUSED_VOL_MAX=${DG_UNUSED_VOL_MAX:-25}
DG_AGE=${DG_AGE:-168h}
DG_PATH=${DG_PATH:-/}

mode=${1:-check}
shift 2>/dev/null || true
apply=0
for a in "$@"; do [ "$a" = "--apply" ] && apply=1; done

# A missing daemon is could-not-run (3), in both modes, before anything is measured or removed.
if ! docker info >/dev/null 2>&1; then
    echo "docker-guard: Docker is not reachable, so nothing was measured (could not run)" >&2
    exit 3
fi

disk_pct()     { df -P "$DG_PATH" | awk 'NR==2 { gsub("%", "", $5); print $5 }'; }
unused_vols()  { docker volume ls -qf dangling=true | wc -l | tr -d ' '; }

# DG_AGE as seconds. Accepts 30s, 30m, 24h, 7d, 1w, or a bare number of seconds; anything else is
# treated as seconds, so a typo shortens the window rather than silently deleting everything.
age_seconds() {
    local a=$1 n unit
    n=${a//[^0-9]/}; [ -n "$n" ] || n=0
    unit=${a//[0-9]/}
    case "$unit" in
        ""|s) echo "$n" ;;
        m)    echo $((n * 60)) ;;
        h)    echo $((n * 3600)) ;;
        d)    echo $((n * 86400)) ;;
        w)    echo $((n * 604800)) ;;
        *)    echo "$n" ;;
    esac
}

check() {
    local pct vols rc=0
    pct=$(disk_pct); vols=$(unused_vols)
    echo "docker-guard check: ${DG_PATH} ${pct}% full (max ${DG_DISK_PCT_MAX}%), ${vols} dangling volume(s) (max ${DG_UNUSED_VOL_MAX})"
    if [ "${pct:-100}" -ge "$DG_DISK_PCT_MAX" ]; then
        echo "  FAIL  ${DG_PATH} is ${pct}% full, at or above ${DG_DISK_PCT_MAX}%"; rc=1
    fi
    if [ "${vols:-0}" -ge "$DG_UNUSED_VOL_MAX" ]; then
        echo "  FAIL  ${vols} dangling volumes, at or above ${DG_UNUSED_VOL_MAX}"; rc=1
    fi
    [ "$rc" -eq 0 ] && echo "  ok"
    return $rc
}

cleanup() {
    local age_s cutoff cstops created vol vols=() v
    age_s=$(age_seconds "$DG_AGE")
    cutoff=$(( $(date +%s) - age_s ))
    echo "docker-guard cleanup: age ${DG_AGE} (${age_s}s)$([ "$apply" -eq 1 ] && echo "" || echo ", dry run (no --apply)")"

    # Stopped containers older than the age. A crashed run's container holds the log that explains it,
    # so anything younger than DG_AGE is left alone, which is why this is not `container prune -f`.
    cstops=$(docker ps -aq --filter status=exited --filter status=created 2>/dev/null | wc -l | tr -d ' ')
    echo "  stopped containers present: ${cstops}; removing those older than ${DG_AGE}"
    if [ "$apply" -eq 1 ]; then
        docker container prune -f --filter "until=$DG_AGE" 2>/dev/null | sed 's/^/    /'
    fi

    # Dangling volumes older than the age. `volume prune` has no --filter until, so the age is read
    # from each volume's CreatedAt; a volume the age cannot be read from is left, not removed.
    for v in $(docker volume ls -qf dangling=true); do
        created=$(docker volume inspect -f '{{.CreatedAt}}' "$v" 2>/dev/null)
        [ -n "$created" ] || continue
        if [ "$(date -d "$created" +%s 2>/dev/null || echo 0)" -lt "$cutoff" ]; then vols+=("$v"); fi
    done
    echo "  dangling volumes older than ${DG_AGE}: ${#vols[@]}"
    if [ "${#vols[@]}" -gt 0 ]; then
        if [ "$apply" -eq 1 ]; then
            printf '    removing %s\n' "${vols[@]}"
            docker volume rm "${vols[@]}" >/dev/null 2>&1 || true
        else
            printf '    would remove %s\n' "${vols[@]}"
        fi
    fi

    # Build cache older than the age. The dry run does not invoke the prune at all: without -f it
    # prompts, and a housekeeping script should not sit on a question waiting for a terminal.
    echo "  build cache older than ${DG_AGE}:"
    if [ "$apply" -eq 1 ]; then
        docker builder prune -f --filter "until=$DG_AGE" 2>/dev/null | tail -1 | sed 's/^/    /'
    else
        echo "    would prune cache older than ${DG_AGE} (no figure without --apply)"
    fi
    echo "  ($([ "$apply" -eq 1 ] && echo "applied" || echo "dry run: nothing removed without --apply"))"
}

case "$mode" in
    check)   check ;;
    cleanup) cleanup ;;
    *) echo "docker-guard.sh: unknown mode '$mode' (check | cleanup)" >&2; exit 2 ;;
esac
