#!/usr/bin/env bash
# vendored from pg-dev-infra harness/docker-guard.sh; do not edit here.
# Edit the source there and re-vendor (pg-dev-infra/scripts/vendor-harness.sh).
# vendored-from: pg-dev-infra@4fe5694
# vendored-sha256: c58a735bfa4dc43f53a01044ffe9abac2142ffa0e1afe0498e76712fd9d19228
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
# The rules, the same ones the shared-host Docker standard states:
#
#   * act only on exact names, never on a selector that spans all objects
#   * list the objects first, read the list, then remove by name
#   * a protected name is never touched; DG_PROTECTED holds those name prefixes
#   * do not sweep every object for anything that has a name; the build cache has no name, so it
#     keeps its age filter
#   * `cleanup` is a dry run unless --apply is given, and it is never a gate
#
# Any script that removes Docker objects can source this file and call `safe_rm`, which refuses the
# whole request (non-zero) if any name is protected and names what it refused, so a protected name
# cannot be dropped from a list and the rest swept. `is_protected <name>` is the bare predicate.
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
#   DG_PROTECTED      see below  name prefixes that `cleanup` and `safe_rm` never remove
#
# DG_PROTECTED defaults to the objects other work on this host owns: `adguard` (adguardhome and
# adguard_exporter), `forgejo-runner`, `pg-dev-infra-` and `book-` (book-forgejo-runner and
# book-docker-proxy). A name that begins with any prefix is protected.
#
# Usage:
#   docker-guard.sh check
#   docker-guard.sh cleanup [--apply]

set -uo pipefail

DG_DISK_PCT_MAX=${DG_DISK_PCT_MAX:-85}
DG_UNUSED_VOL_MAX=${DG_UNUSED_VOL_MAX:-25}
DG_AGE=${DG_AGE:-168h}
DG_PATH=${DG_PATH:-/}
DG_PROTECTED=${DG_PROTECTED:-"adguard forgejo-runner pg-dev-infra- book-"}

# `cleanup` is a dry run unless --apply is given. The default is set here so a script that sources
# this file and calls cleanup without parsing arguments still cannot remove anything by accident.
apply=0

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

# is_protected NAME: 0 when NAME begins with any prefix in DG_PROTECTED, 1 otherwise. Prefix matching
# is what makes `adguard` cover adguardhome and adguard_exporter, and `book-` cover
# book-forgejo-runner and book-docker-proxy. The list is split on spaces on purpose.
is_protected() {
    local name=$1 pat
    for pat in $DG_PROTECTED; do
        case "$name" in
            "$pat"*) return 0 ;;
        esac
    done
    return 1
}

# safe_rm NAME...: the sanctioned container removal path. If any name is protected it refuses the
# whole request (non-zero) and says which name it refused, so a protected name cannot be dropped
# from a list and the rest swept; otherwise it removes exactly the given names with `docker rm -f
# -v` (no selector, no sweep). A script that sources this file calls `safe_rm` rather than reaching
# for `docker rm` itself.
safe_rm() {
    local n names=("$@") protected=()
    if [ "${#names[@]}" -eq 0 ]; then
        echo "docker-guard safe_rm: no names given" >&2
        return 2
    fi
    for n in "${names[@]}"; do
        is_protected "$n" && protected+=("$n")
    done
    if [ "${#protected[@]}" -gt 0 ]; then
        printf 'docker-guard safe_rm: refusing, protected name(s): %s\n' "${protected[*]}" >&2
        return 1
    fi
    docker rm -f -v "${names[@]}"
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
    local age_s cutoff call=0 crun=0 craw=() cprot=() cid cname cstate ccreated csecs
    local created vsecs v vols=() vprot=()
    age_s=$(age_seconds "$DG_AGE")
    cutoff=$(( $(date +%s) - age_s ))
    echo "docker-guard cleanup: age ${DG_AGE} (${age_s}s)$([ "$apply" -eq 1 ] && echo "" || echo ", dry run (no --apply)")"
    echo "  protected prefixes: ${DG_PROTECTED}"

    # Containers: list them all, keep the ones not running and older than the age (a crashed run's
    # container holds the log that explains it, so anything younger than DG_AGE is left alone), and
    # keep the protected ones out of the removal list. Remove exactly the selected names. A sweep
    # that spans every container cannot skip a protected name, so each one is addressed by name. The
    # anonymous data volume is the leak, so the removal carries -v.
    while IFS=$'\t' read -r cid cname cstate; do
        [ -n "$cid" ] || continue
        call=$((call + 1))
        [ "$cstate" = "running" ] && { crun=$((crun + 1)); continue; }
        ccreated=$(docker inspect -f '{{.Created}}' "$cid" 2>/dev/null)
        [ -n "$ccreated" ] || continue
        csecs=$(date -d "$ccreated" +%s 2>/dev/null) || continue
        [ "$csecs" -lt "$cutoff" ] || continue
        if is_protected "$cname"; then cprot+=("$cname"); else craw+=("$cname"); fi
    done < <(docker ps -a --format $'{{.ID}}\t{{.Names}}\t{{.State}}' 2>/dev/null)
    echo "  containers: ${call} present, ${crun} running; not running and older than ${DG_AGE}: ${#craw[@]} to remove, ${#cprot[@]} protected"
    if [ "${#cprot[@]}" -gt 0 ]; then
        printf '    protected, skipped %s\n' "${cprot[@]}"
    fi
    if [ "${#craw[@]}" -gt 0 ]; then
        if [ "$apply" -eq 1 ]; then
            printf '    removing %s\n' "${craw[@]}"
            safe_rm "${craw[@]}" | sed 's/^/    /'
        else
            printf '    would remove %s\n' "${craw[@]}"
        fi
    fi

    # Dangling volumes: the age is read from each volume's CreatedAt; a volume whose age cannot be
    # read is left, not removed. Protected volumes are kept out of the removal list, and the rest
    # are removed by name.
    for v in $(docker volume ls -qf dangling=true); do
        created=$(docker volume inspect -f '{{.CreatedAt}}' "$v" 2>/dev/null)
        [ -n "$created" ] || continue
        vsecs=$(date -d "$created" +%s 2>/dev/null) || continue
        [ "$vsecs" -lt "$cutoff" ] || continue
        if is_protected "$v"; then vprot+=("$v"); else vols+=("$v"); fi
    done
    echo "  dangling volumes older than ${DG_AGE}: ${#vols[@]} to remove, ${#vprot[@]} protected"
    if [ "${#vprot[@]}" -gt 0 ]; then
        printf '    protected, skipped %s\n' "${vprot[@]}"
    fi
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

# Run a mode only when this file is executed, not when it is sourced. A script that sources this file
# gets `is_protected` and `safe_rm` without a check or a cleanup starting underneath it.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    mode=${1:-check}
    shift 2>/dev/null || true
    for a in "$@"; do [ "$a" = "--apply" ] && apply=1; done

    # A missing daemon is could-not-run (3), in both modes, before anything is measured or removed.
    if ! docker info >/dev/null 2>&1; then
        echo "docker-guard: Docker is not reachable, so nothing was measured (could not run)" >&2
        exit 3
    fi

    case "$mode" in
        check)   check ;;
        cleanup) cleanup ;;
        *) echo "docker-guard.sh: unknown mode '$mode' (check | cleanup)" >&2; exit 2 ;;
    esac
fi
