# ci: how this repository's GitHub Actions runs, and how to reproduce a red run

Two files do the work. `server.sh` owns a throwaway PostgreSQL. `job.sh` runs the pgTAP suite against
it. `.github/workflows/test.yml` calls them.

```bash
./ci/job.sh 18        # the whole pgtap job for one version, exactly as the workflow runs it
./ci/job.sh 14
```

The version argument is the **Docker image tag**, not the apt version, and they are not the same
string. `19beta4` is the tag; the Debian package inside that image is `postgresql-19`. Using the tag
for both stops the matrix at its last version with `Unable to locate package`. `server.sh` derives the
apt version and passes it separately.

## Why the server is a container the job starts, not a service

GitHub has no `command:` override for a service container, and this suite needs two settings that would
have to go there: `max_prepared_transactions`, without which `test/04_prepared.sql` has nothing to
test, and `shared_preload_libraries=pg_cron`, without which `test/06_cron.sql`, `test/07_history.sql`
and `test/14_deadlocks.sql` skip themselves. Skipped tests read as a pass. `server.sh` starts the
container itself, sets both, and then asserts that they took.

## Why the pgtap job does not run `make install`

Because the Forgejo pgtap job does not either, and for the same reason: its runner image *is* a
PostgreSQL. On GitHub the runner is not PostgreSQL at all, so a host-side `make install` would install
into whatever the runner happens to have. The release script is loaded straight into the server
instead, which is also the path the suite has always been tested against.

`make install` is covered by the `install-path-checks` job, which runs it inside the container where
the server lives. That job is the one named in `scripts/check-ci-github.sh`'s
`pg-lock-tree.ci-gates`, and it is the job that went red on v1.1.11 when the `DATA` line listed an
upgrade script twice. It runs the real `make`, not a copy that puts files in the same place, because
the whole value of it is that it is the real thing.

## What each job needs from the image

| need | where it comes from |
|---|---|
| pgTAP | `postgresql-<major>-pgtap`, installed by `ci/Dockerfile` |
| pg_cron | `postgresql-<major>-cron`, installed. **Not** in the official image, despite appearances |
| dblink | already in the official image |
| pg_stat_statements | already in the official image |
| `make` | installed only when `server.sh` is given the word `make`, which only `install-path-checks` does |

## Reproducing a red run

`ci/job.sh` is the job, so a red run reproduces with the same command. The three checks that need a
server, which is what `install-path-checks` runs after `make install`:

```bash
./ci/server.sh up 18 5518 make
docker exec pg-lock-tree-ci mkdir -p /src
docker cp . pg-lock-tree-ci:/src
docker exec -w /src pg-lock-tree-ci make install
export PGHOST=127.0.0.1 PGPORT=5518 PGUSER=postgres PGPASSWORD=test PGDATABASE=postgres
./scripts/check-upgrade.sh
./ci/server.sh down
```

Ports 5514 to 5519 are used by `ci/job.sh`. The `pg-dev-infra` test containers occupy 5414 to 5419, so
the two ranges do not collide.

## The gate that reads these runs

`scripts/check-ci-github.sh` refuses to let a commit be tagged unless every workflow here is green.
Its configuration is in git config rather than in the script:

```bash
git config pg-lock-tree.ci-gates 'test.yml=install-path checks'
```

The name is the workflow **file**, and the value is the job that has to still exist inside it. A
workflow whose gating job is renamed reports success forever, and from the outside that is
indistinguishable from a gate that works, which is why the script reads the run's job list as well as
its conclusion.
