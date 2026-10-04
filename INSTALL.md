# Installing and updating pg_lock_tree

Everything needed to get `pg_lock_tree` running, move it between versions, and undo it. The
[README](README.md) has what it does; this has how to install it.

- [Requirements](#requirements)
- [Where to get it](#where-to-get-it)
- [Install](#install)
  - [A. From source, into a local PostgreSQL](#a-from-source-into-a-local-postgresql)
  - [B. Into a Docker test container](#b-into-a-docker-test-container)
  - [C. On RDS, Aurora, or another managed instance](#c-on-rds-aurora-or-another-managed-instance)
- [Grants](#grants)
- [Verify the install](#verify-the-install)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Upgrading the major PostgreSQL version](#upgrading-the-major-postgresql-version)
- [Troubleshooting](#troubleshooting)

## Requirements

| | |
|---|---|
| PostgreSQL | **14 or later.** Every version needs `pg_locks.waitstart`, added in 14. Tested on 14, 15, 16, 17, 18 and 19beta4. On 13 and earlier the extension refuses to install, and says why in the error. |
| Upcoming | PostgreSQL 14 reaches end of life on **12 November 2026**. The extension itself has nothing to change, but that is the floor of the tested matrix, so 14 will stop being tested when it stops being supported. |
| Language | SQL only. No C, no compiler, no `shared_preload_libraries`, no restart. |
| Superuser | **Required to `CREATE EXTENSION`.** The control file sets `trusted = false`, so PostgreSQL will not let an ordinary role install it. |
| To run the tests, demo or scenarios | the `dblink` contrib module, plus superuser (they open sessions and terminate backends) |
| To exercise prepared transactions | `max_prepared_transactions > 0` |
| One setting you can turn off | `SET lock_tree.actions = off` suppresses `lock_tree_actions()` for the session, for anyone who prefers the columns in `lock_tree_roots()`. Not needed by the extension; it is a display preference. |
| To use the history | **optional.** `lock_tree_sample()` is a function you schedule yourself; `pg_cron` is one way to schedule it and needs `shared_preload_libraries = 'pg_cron'` in `postgresql.conf` plus a restart. Any scheduler works, including a host cron job running `psql -c 'SELECT lock_tree_sample()'`. The extension itself needs none of this. |
| To check the docs against the code | `./scripts/lint-docs.sh`, or `make lint-docs`. Pure text and git: no database, no superuser. Verifies the version agrees across `pg_lock_tree.control`, `README.md` and `CHANGELOG.md`, that every object and file the docs name exists, that each test file's `plan()` matches its assertions, and that there are no em-dashes or en-dashes. |

That last row catches people. `max_prepared_transactions` defaults to **0**, and with it at 0
`PREPARE TRANSACTION` is refused. It does not affect normal use of the extension. Only the
prepared-transaction test needs it, but if you want to see that path work, set it before starting
the server.

## Where to get it

The extension is not packaged on PGXN yet. It is a Git repository:

```bash
git clone https://forgejo/apjapj/pg_lock_tree.git    # adjust the host to yours
cd pg_lock_tree
```

Check out the version you want. Tags are releases; `main` is whatever is newest and may be
ahead of the last tag:

```bash
git tag                 # v0.1, v0.2, v0.3, v0.4
git checkout v0.4       # or: git checkout main
```

## Install

### A. From source, into a local PostgreSQL

This is the real path. Three steps: copy the files in, tell the database, grant access.

**1. Copy the extension files into PostgreSQL's extension directory.**

`make install` does this, but it writes to a system directory, so it needs root:

```bash
sudo make install
```

You need the matching `postgresql-server-dev-<version>` package for `pg_config` and the PGXS
makefiles. On Debian/Ubuntu with PGDG configured:

```bash
sudo apt install postgresql-server-dev-18      # match your major version
```

`pg_config` must be on your `PATH`. If you have several versions installed, point at the one
you want rather than relying on which one comes first:

```bash
sudo make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config install
```

Check what it landed on before continuing:

```bash
ls "$(pg_config --sharedir)"/extension/pg_lock_tree*
# pg_lock_tree--0.1--0.2.sql   the update path from 0.1
# pg_lock_tree--0.2--0.3.sql   the update path from 0.2
# pg_lock_tree--0.3--0.4.sql   the update path from 0.3
# pg_lock_tree--0.1.sql         release
# pg_lock_tree--0.2.sql         release
# pg_lock_tree--0.3.sql         release
# pg_lock_tree--0.4.sql         current release
# pg_lock_tree.control
```

If `pg-test:14` is missing while the others are present, `make` did not pick up the update
script. That is a Makefile bug, not something you did wrong. Report it.

**2. Create the extension in each database where you want it.**

The extension is per-database, like every PostgreSQL extension. `CREATE EXTENSION` also needs a
superuser (or a role you have granted that specifically):

```bash
sudo -u postgres psql -c 'CREATE EXTENSION pg_lock_tree;'
```

To install into a specific schema instead of `public`:

```sql
CREATE SCHEMA monitoring;
CREATE EXTENSION pg_lock_tree SCHEMA monitoring;
```

Then reference it as `monitoring.lock_tree`. Verified working: the view and all five functions
resolve their own schema correctly.

**3. Grant access to whatever reads it.** See [Grants](#grants).

### B. Into a Docker test container

The shared test images already have the extension's test dependencies but not the extension
itself. Mount the checkout and install:

```bash
docker cp . pg-test-18:/tmp/src          # or bind-mount the checkout
docker exec -u root pg-test-18 make -C /tmp/src install
docker exec pg-test-18 psql -U postgres -c 'CREATE EXTENSION pg_lock_tree;'
```

Or just use the suite, which does all of this for you:

```bash
cd ~/dev/pg-dev-infra && ./build-push-images.sh --push     # rebuild the images
cd ~/software/pg_lock_tree
EXT_SRC=$PWD COMPOSE_FILE=~/dev/pg-dev-infra/docker-compose.test.yml scripts/matrix.sh
```

### C. On RDS, Aurora, or another managed instance

You cannot run `make install` on a managed instance, so this path is untested. Stated plainly, because the README
has claimed it before without evidence.

The extension is pure SQL, which is what makes it plausible: AWS's `pg_tle` (Trusted Language
Extensions) loads SQL extensions without filesystem access.

```sql
CREATE EXTENSION pg_tle;
SELECT pg_tle.create_extension('pg_lock_tree', 'pg_tle');
```

That is the shape of it. **Treat it as unverified** until someone has run it, and check
particularly whether `pg_blocking_pids()` is reachable under `pg_tle`, which is the one
dependency that might not be.

## Grants

**To use it as a superuser**, nothing more. This is fine for `psql` at a terminal during an
incident, which is the common case.

**For a monitoring role**, give it two grants. Both are required, and this trips people:

```sql
CREATE ROLE monitoring LOGIN PASSWORD '...' ;   -- LOGIN only if something connects over TCP

GRANT pg_read_all_stats TO monitoring;         -- may see other sessions' rows and query text
GRANT SELECT ON lock_tree TO monitoring;       -- may read the view at all
```

`pg_read_all_stats` on its own is **not** sufficient. A view's own `SELECT` privilege is checked
before PostgreSQL decides what the underlying `pg_stat_activity` rows may show, so without the
second grant every query fails with:

```
ERROR:  permission denied for view lock_tree
```

`lock_tree_roots()`, `lock_tree_text()`, `lock_tree_text_short()`, `lock_tree_actions()`,
`lock_tree_command()`, `lock_tree_sample()`, `lock_tree_incidents()`, `lock_tree_prune()` and the
three formatting helpers are executable by `PUBLIC` by default and become usable once the view
is readable. If you install into a non-public schema, grant against that schema instead:

```sql
GRANT USAGE ON SCHEMA monitoring TO monitoring;
GRANT SELECT ON monitoring.lock_tree TO monitoring;
```

## Verify the install

Or run the checker, which does all of the below plus an object inventory and reports the first
real failure:

```bash
./scripts/check-install.sh          # or: PGHOST=... PGUSER=monitoring ./scripts/check-install.sh
```

Exits non-zero on failure. Run it as your monitoring role too, since that is how you confirm the
grants rather than assuming them.

By hand, three queries. The first two should return **zero rows**, not an error. An error means
the objects are missing or the schema is wrong, and an empty result just means nothing is
blocked:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_lock_tree';   -- 0.4
SELECT count(*) FROM lock_tree;                                        -- 0
SELECT * FROM lock_tree_text();                                        -- 0 rows
```

Then check the whole surface is reachable from your monitoring role:

```sql
SET ROLE monitoring;
SELECT count(*) FROM lock_tree;          -- 0, not an error
SELECT * FROM lock_tree_roots();         -- 0 rows
SELECT * FROM lock_tree_text();          -- 0 rows
SELECT * FROM lock_tree_text_short();    -- 0 rows
SELECT * FROM lock_tree_actions();       -- 1 row: the "-- 0 root blocker(s)" header
SELECT * FROM lock_tree_command();       -- 0 rows: a quiet database needs no commands
SELECT * FROM lock_tree_incidents();      -- 0 rows: history is opt-in and starts empty
RESET ROLE;
```

To see it with something actually blocked, run the demo:

```bash
psql -X -f demo.sql                      # needs superuser and dblink
```

## Updating

The extension lives inside each database and is versioned independently of the PostgreSQL
major version, so updating is two steps: copy the new files in, then move the database forward.

**1. Check what you are on, and what is available.**

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_lock_tree';
```

```bash
grep default_version "$(pg_config --sharedir)"/extension/pg_lock_tree.control
```

**2. Copy the new files in.** Same as installing, and safe to do before upgrading. An
installed `.control` and unused `.sql` files do nothing on their own:

```bash
git pull && sudo make install
```

**3. Move the database forward:**

```sql
ALTER EXTENSION pg_lock_tree UPDATE;              -- to the default version
ALTER EXTENSION pg_lock_tree UPDATE TO '0.4';     -- or name it explicitly
```

Repeat per database.

**If you get `no update path from version "0.x" to version "0.4"`**, the update script is not
installed. PostgreSQL looks for a file named exactly `pg_lock_tree--0.x--0.4.sql` in the
extension directory; check it is there:

```bash
ls "$(pg_config --sharedir)"/extension/pg_lock_tree--0.3--0.4.sql
```

Also make sure `make` picked up the *same* PostgreSQL version you are connected to. See
[Troubleshooting](#troubleshooting).

**What 0.4 changes:** adds `lock_tree_history` and three functions around it. Nothing existing
is altered, so there is nothing to migrate and nothing that can break. The history table arrives
**empty** and stays empty until you schedule `lock_tree_sample()`; see
[After the incident has cleared](README.md#after-the-incident-has-cleared).

**Downgrade is not supported.** There is no `0.4--0.3` script, and `ALTER EXTENSION ... UPDATE TO`
will not go backwards. To get 0.3 behaviour back, install 0.3 in a scratch database alongside it.

**Upgrading from an earlier version chains automatically.** There is no `0.2--0.4` script, and
that is correct: `ALTER EXTENSION pg_lock_tree UPDATE` applies one step at a time and walks the
chain itself. Verified:

```sql
SELECT source, target, path FROM pg_extension_update_paths('pg_lock_tree') ORDER BY source;
```

## Uninstalling

**From the database.** Takes the view and all functions with it:

```sql
DROP EXTENSION pg_lock_tree;          -- add CASCADE only if something depends on the view
```

Verified: nothing is left behind in `pg_class` or `pg_proc`.

**From the filesystem** (optional). Dropping the extension first and leaving the files is
harmless; PostgreSQL ignores extension files for extensions that are not installed.

```bash
sudo rm "$(pg_config --sharedir)"/extension/pg_lock_tree*
```

## Upgrading the major PostgreSQL version

Nothing to do to the extension itself: it is pure SQL with no shared libraries, so there is no
`.so` to rebuild and no `shared_preload_libraries` entry to carry over.

The extension lives **inside each database**, so:

- `pg_upgrade` carries the installed extension and its version forward automatically.
- A dump/restore (`pg_dumpall` / `pg_restore`) carries the `CREATE EXTENSION` statement, so
  target the server with `make install` first, or the restore fails with
  `could not access file "pg_lock_tree--0.4.sql"`.
- To install into a fresh major version, repeat [Install](#install) against the new
  `pg_config`:
  ```bash
  sudo make PG_CONFIG=/usr/lib/postgresql/19/bin/pg_config install
  ```

## Troubleshooting

**`permission denied for view lock_tree`**, the most common one. You granted
`pg_read_all_stats` but not `SELECT`. See [Grants](#grants).

**`permission denied to create extension "pg_lock_tree"` / `Must be superuser to create this
extension`**. The control file sets `trusted = false`. Run `CREATE EXTENSION` as a superuser.

**`relation "lock_tree" does not exist`**: the files are installed but the extension was never
created in *this* database. Extensions are per-database; check the others too.

**`prepared transactions are disabled`**, from the prepared-transaction test or scenario only.
Set `max_prepared_transactions` above 0 and restart. In the shared test images it is already set
in the image's `CMD`; note Forgejo v16 ignores a `command:` override on a workflow service
container, so it cannot be set from a workflow.

**`pg_config: No such file or directory`**: install `postgresql-server-dev-<your version>`, or
set `PG_CONFIG=/usr/lib/postgresql/<version>/bin/pg_config`.

**`make install: Permission denied`**: it writes to a system directory. Use `sudo make install`.

**Installed to the wrong PostgreSQL version.** `pg_config` resolves to whichever version comes
first on your `PATH`, which on a multi-version box is rarely the one you meant. Always pass
`PG_CONFIG=` explicitly, and confirm with `pg_config --version` before creating the extension.
PostgreSQL does not warn about this. It will happily load a 0.4 built for a different major
version, and you will find out at runtime.

**`FATAL: Peer authentication failed for user "postgres"`**, stock Debian/Ubuntu behaviour and not
a problem with this extension. Local socket connections must match your OS user, so use
`sudo -u postgres psql`, or connect over TCP with a password.

**`SELECT * FROM lock_tree` returns a session as `exited`.** Expected and documented: the view
reads `pg_stat_activity` and `pg_locks` separately, so a chain that changes mid-query can show a
backend that has since gone. Re-run the query.

**A deadlock shows up as several roots rather than one.** Also expected. A wait-for cycle has no
head of the queue, so every session in it is reported as its own depth-0 root. `blocked_by` shows
who each one is actually stuck behind. PostgreSQL resolves deadlocks on its own after
`deadlock_timeout` (1s by default), so the window is short unless you have raised it.

**Nothing blocked, but the application is slow.** This extension reports *lock waits*. A session
that is running but slow, or waiting on IO or a network, is not in the tree. Check
`pg_stat_activity.wait_event_type` for those.