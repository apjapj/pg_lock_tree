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
| Upcoming | PostgreSQL 14 reaches end of life on **12 November 2026**. The extension has nothing to change, and **14 stays in the tested matrix past that date**, until PostgreSQL 19 is stable. The honest part: no further fixes for 14 will come from PostgreSQL upstream, so anything 14-specific that breaks later is unfixable by upgrading PostgreSQL and is this extension's problem. Keeping it tested costs one matrix entry and buys anyone still on it a working tool. |
| Language | SQL only. No C, no compiler, no `shared_preload_libraries`, no restart. |
| Superuser | **Required to `CREATE EXTENSION`.** The control file sets `trusted = false`, so PostgreSQL will not let an ordinary role install it. |
| To run the tests, demo or scenarios | the `dblink` contrib module, plus superuser (they open sessions and terminate backends) |
| To exercise prepared transactions | `max_prepared_transactions > 0` |
| One setting you can turn off | `SET lock_tree.actions = off` suppresses `lock_tree_actions()` for the session, for anyone who prefers the columns in `lock_tree_roots()`. Not needed by the extension; it is a display preference. |
| To use `lock_tree_statements()` | **optional.** `pg_stat_statements` must be in `shared_preload_libraries` in `postgresql.conf`, and a restart, or every read of its view raises `must be loaded via shared_preload_libraries`. It also needs `CREATE EXTENSION pg_stat_statements;` per database. Without it the function still reports every root and how much each blocks, with the statement columns empty. |
| To use the history | **optional.** `lock_tree_sample()` is a function you schedule yourself; `pg_cron` is one way to schedule it and needs `shared_preload_libraries = 'pg_cron'` in `postgresql.conf` plus a restart. Any scheduler works, including a host cron job running `psql -c 'SELECT lock_tree_sample()'`. The extension itself needs none of this. |
| To check the docs against the code | `./scripts/lint-docs.sh`, or `make lint-docs`. Pure text and git: no database, no superuser. Verifies the version agrees across `pg_lock_tree.control`, `README.md` and `CHANGELOG.md`, that every object and file the docs name exists, that each test file's `plan()` matches its assertions, and that there are no em-dashes or en-dashes. |

That last row catches people. `max_prepared_transactions` defaults to **0**, and with it at 0
`PREPARE TRANSACTION` is refused. It does not affect normal use of the extension. Only the
prepared-transaction test needs it, but if you want to see that path work, set it before starting
the server.

## Where to get it

The extension is not packaged on PGXN yet. It is a Git repository:

```bash
git clone https://github.com/apjapj/pg_lock_tree.git
cd pg_lock_tree
```

Check out the version you want. Tags are releases; `main` is whatever is newest and may be
ahead of the last tag:

```bash
git tag --sort=v:refname    # every release, oldest first; CHANGELOG.md has what each one did
git checkout v1.1.16        # or: git checkout main for whatever is newest
```

The tag to check out is the current release, v1.1.16. Every release tag from v1.1.15 onward
exists on GitHub, which is where a public clone comes from; the v0.* and early v1.1.x tags
exist only on the author's Forgejo, so `git checkout` for one of those will not resolve on a
public clone. `main` always works and is at or ahead of the newest tag.

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
# pg_lock_tree--1.0.0.sql ... pg_lock_tree--1.1.16.sql     one full script per release from 1.0.0
# pg_lock_tree--1.0.0--1.0.1.sql ... --1.1.15--1.1.16.sql  the update path from each release to the next
# pg_lock_tree--1.1.8--1.1.10.sql                          a direct path past 1.1.9's faulty check
# pg_lock_tree--1.1.10--1.1.12.sql                         a direct path past 1.1.11's lost grants
# pg_lock_tree.control
```

Nothing older than 1.0.0 is installed. The 0.x release and update scripts were removed from the tree
after 1.1.13; they remain in git history. No 0.x installation is known to exist, and one that did would
first update with a checkout from before the removal. `make install` adds files and never removes them,
so a server that once had the 0.x scripts keeps them in its extension directory; they are harmless, and
`rm "$(pg_config --sharedir)"/extension/pg_lock_tree--0.*.sql` clears them.

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

  **Some of those also read the history, and need a third grant.** Everything above the view is
  `SECURITY INVOKER`, so a function runs as whoever called it, and the history is the caller's to read
  or not. Seven of them read `lock_tree_history` and fail without this:

  ```sql
  GRANT SELECT ON lock_tree_history TO monitoring;   -- the two history tables
  GRANT SELECT ON lock_tree_deadlock TO monitoring;
  ```

  The seven, so you can tell whether you need it rather than discovering it one error at a time:

  | | |
  |---|---|
  | `lock_tree_replay()` | the tree at a past sample |
  | `lock_tree_replay_text()` | the same, rendered |
  | `lock_tree_incidents()` | the history grouped into incidents |
  | `lock_tree_sampling_advice()` | a suggested sample interval |
  | `lock_tree_duration()` | per-query blocking time |
  | `lock_tree_duration_by_application()` | per-application blocking time |
  | `lock_tree_history_statements()` | per-query session-samples |

  Without it each fails with `ERROR: permission denied for table lock_tree_history`, which says
  nothing about which grant is missing: the error names the table, and the table is not what you were
  thinking about.

  The extension does not paper over this by making them `SECURITY DEFINER`, and it should not. The
  history holds the first 300 characters of blocked queries, which is application data, and a definer
  function would hand it to every role with `EXECUTE` on it, which is `PUBLIC` by default. If that
  text is not something `monitoring` may see, the answer is not to grant it and not to deny it, but to
  leave `lock_tree_sample()` unscheduled so that there is no history to read.

  **One inconsistency, stated rather than fixed.** `lock_tree_replay_samples` is a *view* over the
  same table, and a view runs with the **definer's** rights in PostgreSQL, so `monitoring` can read it
  with no grant at all. It exposes the shape of each sample and the application names and query ids at
  the head. It does **not** expose query text, which is the part worth protecting. This is not changed
  here, because `security_invoker` on a view needs PostgreSQL 15 and this extension supports 14.

  Everything else is executable by `PUBLIC` by default, including `lock_tree_roots()`,
  `lock_tree_text()`, `lock_tree_text_short()`, `lock_tree_actions()`, `lock_tree_command()`,
  `lock_tree_prune()`, `lock_tree_wide()`, `lock_tree_summary()`,
  `lock_tree_statements()`, `lock_tree_prune_alerts()`, `lock_tree_deadlocks()`,
  `lock_tree_history_size()` and the three formatting helpers.

  **Not `lock_tree_sample()`.** Since 1.0.1 it is *not* executable by `PUBLIC`, and that is
  deliberate. It is `SECURITY DEFINER`, so it reads `pg_stat_activity` as its owner and can see
  every session's query text. While it was also callable by any role, a role holding nothing but
  `SELECT` on the history could set `lock_tree.history_query = 'full'` for its own session, call the
  sampler, and read another session's blocked statement back out of the table, password included,
  even though `pg_stat_activity` showed that same text to it as `<insufficient privilege>`. So the
  role that schedules the sample needs it granted:

  ```sql
  GRANT EXECUTE ON FUNCTION lock_tree_sample() TO monitoring;
  ```

  The grant is not restored for anyone on upgrade, on purpose. Reinstating it silently would put the
  hole back for exactly the roles that had it.

**If the same role also archives**, which since 1.1.6 is a separate decision from sampling, see
[Grants for the archive](#grants-for-the-archive) below. It is four privileges across two tables and
none of them come from the grants above, so a role that samples and reads successfully will still get
`permission denied` from `lock_tree_archive()` until you add them.

**If the same role also raises alerts**, `lock_tree_notify()` and `lock_tree_notify_resolved()` need
access to `lock_tree_alert`, and it is more than one privilege. Measured on 1.0.1:

| Grants on `lock_tree_alert` | `lock_tree_notify()` |
|---|---|
| none | `permission denied for table lock_tree_alert` |
| `SELECT, INSERT, UPDATE, DELETE` | works |

The middle of that table is deliberately blank. Every subset tried was accepted on one run and refused
on the next, with the same grants and the same empty `lock_tree_alert`, so which of them are needed
appears to depend on what the channel has already recorded. A minimum that changes with the contents of
the table is not a minimum worth writing down, and a reader who grants three of four and gets a working
alert has not been told they are one privilege short.

So grant all four:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON lock_tree_alert TO monitoring;
```

`DELETE` on a state table is a wider privilege than it looks, and it is deliberate: the function is not
`SECURITY DEFINER`, because a role that can set thresholds is a role that can page people. Give this to
the role that schedules the sampler and to nobody else. The error a reader gets names the table and not
the missing privilege, which is why it is written down here.

`lock_tree.history_query` is read from the caller's session, so the role that samples decides. Set
  it on that role's connection, or per database with `ALTER DATABASE`, and the value applies to
  everyone. An unrecognised value redacts.

  If you install into a non-public schema, grant against that schema instead:

```sql
GRANT USAGE ON SCHEMA monitoring TO monitoring;
GRANT SELECT ON monitoring.lock_tree TO monitoring;
```

## Grants for the archive

**The archive table already exists.** `lock_tree_history_archive` is created empty by the extension
on every install, and by every upgrade path, exactly as `lock_tree_history` is. There is nothing to
enable, no flag, and no function to call first, and there is no way to install 1.1.6 without it. An
empty table with an empty BRIN index is a few pages.

If you have read somewhere that it is optional, what is optional is **using** it: nothing reads it,
nothing writes to it, and if you never call `lock_tree_archive()` it stays empty forever. The reason
it is created unconditionally rather than on demand is that a function which created it would have to
be `SECURITY DEFINER` to be usable by an operator without `CREATE` on the schema, and handing that
privilege to a function whose job is to move rows is a poor trade for a few pages of disk.

`lock_tree_archive()`, added in 1.1.6, moves rows out of `lock_tree_history` and into
`lock_tree_history_archive`. It is `SECURITY INVOKER`, so it runs as the caller and needs table
privileges of its own. **None of the grants above are sufficient**, and the error names the table
rather than the privilege, so the four below are written out rather than left to be discovered.

```sql
GRANT SELECT, DELETE ON lock_tree_history          TO monitoring;
GRANT SELECT, INSERT ON lock_tree_history_archive  TO monitoring;
GRANT EXECUTE ON PROCEDURE lock_tree_archive(interval, integer) TO monitoring;
```

Measured, one privilege at a time, on 1.1.6:

| Grants | Result |
|---|---|
| none | `permission denied for table lock_tree_history` |
| `SELECT ON lock_tree_history` | `permission denied for table lock_tree_history_archive` |
| the three above | moves rows |

`DELETE` on the history is required and is the widest privilege in the set. It is there because the
procedure's job is to remove what it has copied, and a role that can call it can therefore destroy
history: it is a maintenance role, not a monitoring one. `lock_tree_prune()` and
`lock_tree_prune_batched()` need the same privilege for the same reason, and this is not a new shape,
but it is a fourth thing to think about before handing a role to a job.

**Give this to the role that runs the archive job, not to the role that samples or alerts.** They are
separate jobs on separate cadences, and a read-only monitoring role has no business deleting history.

For a non-public schema, qualify the table names:

```sql
GRANT SELECT, DELETE ON monitoring.lock_tree_history         TO monitoring;
GRANT SELECT, INSERT ON monitoring.lock_tree_history_archive TO monitoring;
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
SELECT extversion FROM pg_extension WHERE extname = 'pg_lock_tree';   -- 0.15
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
SELECT * FROM lock_tree_summary();         -- 1 row of zeros, not no rows
SELECT * FROM lock_tree_sampling_advice(); -- an interval sized on the window's peak, and why
SELECT * FROM lock_tree_deadlocks();      -- when pg_stat_database.deadlocks moved
SELECT * FROM lock_tree_history_size();  -- what it costs, and days to a gigabyte
SELECT * FROM lock_tree_history_statements(); -- per-query blocking time, worst first
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
ALTER EXTENSION pg_lock_tree UPDATE TO '1.1.16';  -- or name it explicitly
```

Repeat per database.

**If you get `no update path from version "1.1.15" to version "1.1.16"`**, the update script is not
installed. PostgreSQL looks for a file named exactly `pg_lock_tree--1.1.15--1.1.16.sql` in the
extension directory; check it is there:

```bash
ls "$(pg_config --sharedir)"/extension/pg_lock_tree--1.1.15--1.1.16.sql
```

Also make sure `make` picked up the *same* PostgreSQL version you are connected to. See
[Troubleshooting](#troubleshooting).

**Updating to 1.1.0 rebuilds one index, and that takes a lock.** It replaces
`lock_tree_history_application_idx` with the same partial index plus `INCLUDE (query_id)`. PostgreSQL
14, the oldest version supported here, has no `ALTER INDEX ... ADD INCLUDE`, so the index is dropped
and rebuilt. That is a 1.9 MB index on the standard fixture, but it grows with the number of samples,
and the rebuild holds a lock that blocks writes to the history for its duration. `lock_tree_sample()`
will queue behind it. On a large history, build the replacement under another name and swap, rather
than doing it in the same transaction as everything else.

Nothing else in 1.1.0 touches the table. `lock_tree_incidents()` gains a `since` parameter that
defaults to `NULL`, which means the whole retained history, so a call that does not pass it behaves
exactly as it did in 1.0.2 and earlier.

**What 0.10 changes:** adds `lock_tree_deadlock` (a table) and `lock_tree_deadlocks()`, so the
`pg_stat_database.deadlocks` counter is sampled and you can see **when** deadlocks happened. It does
name the two statements involved only when a sample lands while the cycle exists; otherwise they are in the server log. See
[Deadlocks](docs/after-the-incident.md#deadlocks).

**What 0.11 changes:** adds `lock_tree_history_size()` and `lock_tree_prune_batched()`, which is a
**procedure** rather than a function because only a procedure can `COMMIT`, and a batched prune that
cannot commit between batches still holds everything. `lock_tree_prune()` is unchanged.

Nothing is rewritten and no rewrite lock is taken; both objects are new.

```sql
CALL lock_tree_prune_batched(interval '7 days', 20000);
```

Put the `CALL` on its own line. Inside `BEGIN`/`COMMIT` it is refused, and it checks for that
**before deleting anything**. See [Why the history is not partitioned](docs/roadmap.md#considered-and-not-planned).

**What 0.12 changes:** adds `lock_tree_duration()`, which reports per-query blocking **time** rather
than the session-sample count that `lock_tree_history_statements()` reports, and
`lock_tree_notify_resolved()`, which raises a `NOTIFY` with `event: "cleared"` when a notified
incident ends. Both are new. `lock_tree_history_statements()` and `lock_tree_notify()` are unchanged.

`lock_tree_duration()` needs a sampled history to have any figure to work from, so schedule
`lock_tree_sample()` before you expect it to say anything. See
[Which query is costing the most time](docs/incident.md#which-query-is-costing-the-most-time), including the
sampling hazard described there: samples must be separate statements, or every one of them shares a
single `sampled_at` and no duration can be recovered from them.

```sql
-- run it from the same cron entry as lock_tree_notify(), with the SAME thresholds
SELECT lock_tree_notify_resolved('lock_tree', 10, 3, '30 seconds');
```

**What 0.13 changes:** adds `lock_tree_duration_by_application()`, which reports the same blocking
**time** keyed on `application_name` rather than on the statement, and corrects three columns
`lock_tree_duration()` reported wrongly in 0.12.

`lock_tree_duration_by_application()` is **not** `lock_tree_duration()` grouped by application, and
the two disagree wherever an application hands the queue from one statement to another, which is
what a batch job running a fixed script does constantly. Measured on one such incident, the per-query
figures summed to 4.0 seconds where the application had in fact held the queue for 15.4. See
[Which application is costing the most](docs/incident.md#which-application-is-costing-the-most).

**Grants survive this update.** The three corrected columns are changed with `CREATE OR REPLACE
FUNCTION`, not `DROP` and `CREATE`, so the function keeps its identity and any `GRANT EXECUTE ON
FUNCTION lock_tree_duration(interval)` you have issued is still in force afterwards. Nothing is
dropped and no view is re-created.

```sql
SELECT application_name, blocking_seconds, blocked_sessions_peak, longest_wait, query_ids
FROM lock_tree_duration_by_application() LIMIT 20;
```

**What 0.14 changes:** adds replay, so the history can be *looked at* rather than only queried.
`lock_tree_replay(as_of)` returns the tree as it was at a past sample and
`lock_tree_replay_text(as_of)` renders it. `lock_tree_replay_samples` is a new view listing which
samples exist, because the history holds one row per session and its own row count does not tell you
how many moments there were.

Replay returns the columns the history **recorded**, which is fewer than `lock_tree` has. Nine are
absent and cannot be supplied: `path` and `blocked_by` because the history stores one row per
session rather than the edge between them, and `usename`, `datname`, `client_addr`,
`wait_event_type`, `wait_event`, `xact_age` and `state_age` because they were never recorded.
Nothing existing changes and no table is rewritten, so the update is instant whatever the history
size.

```sql
-- which moments can you ask about?
SELECT * FROM lock_tree_replay_samples ORDER BY sampled_at DESC LIMIT 10;

-- and then ask about one
SELECT * FROM lock_tree_replay_text(now() - interval '2 hours');
```

**What 0.15 changes:** the read functions stop reading the whole table. Fifteen window bounds used
`clock_timestamp()`, which is volatile, so the planner could not turn them into index seeks and every
one of them became a filter over the entire index. On a seven day history of 1.2 million rows, a
one millisecond window went from 980 ms to 78 ms and `lock_tree_replay()` from 987 ms to 0.3 ms.

Those figures are from the release that fixed it, and they are kept as they were recorded. A fixture
loaded by a single bulk insert has no visibility map, so every index-only scan in it was fetching
every page; once the fixture is vacuumed the same one millisecond window measures 0.4 ms rather than
78 ms. If you are comparing your own numbers against this line, vacuum the table first and see
[what the benchmark script prints](scripts/bench-history.sh).

It also **fixes two columns**: `blocked_sessions_peak` and `sessions_total` in both duration
functions were one too high per sample, because the root-to-waiter join matched each root to itself.
If you built a query against those figures in 0.13 or 0.14, subtract one per sample.

Everything else is unchanged, and it is all a replace, so no grants are revoked.

```bash
make bench-history     # time the read side against a synthetic 1.2M row history
```

That **truncates `lock_tree_history` and `lock_tree_history_archive`**. Run it against a scratch database.

**Updating from 1.1.8 drops and recreates `lock_tree_archive_find()`.** 1.1.9 removed its `samples`
output column, which was the constant 1, and an output column cannot be removed by a replace. If you
built a view or a `BEGIN ATOMIC` function on it, the update refuses, names each one by its
schema-qualified name, and changes nothing: the extension stays at 1.1.8. Save their definitions, drop
them, update, and recreate them against the six columns that remain. A plpgsql function, or a
`LANGUAGE sql` function with a string body, that calls it records no dependency, so no check can list
it: look for those yourself, because they fail on their next call rather than at the update.

**Go from 1.1.8 straight to 1.1.10 or later, not to 1.1.9.** The check that produces that message
was wrong in 1.1.9: it missed views outside the extension's schema and named the function instead of
the view. The update was still safe, because the `DROP` refuses on its own and the whole update
rolls back, but the error was PostgreSQL's generic one. 1.1.10 ships a direct
`pg_lock_tree--1.1.8--1.1.10.sql` with the corrected check, and a plain `ALTER EXTENSION pg_lock_tree
UPDATE` takes it, because PostgreSQL chooses the shortest path. An explicit `UPDATE TO '1.1.9'` still
runs the 1.1.9 script and its old message, since 1.1.9 is a released tag and is not edited.

**Upgrading through 1.1.11 removes your grants on two functions.** If you granted `EXECUTE` on
`lock_tree_notify()` or `lock_tree_notify_resolved()` to a role, or revoked it from `PUBLIC`, and your
upgrade **passed through 1.1.11**, that privilege is gone and both functions are back to their
defaults. Re-apply it by hand; nothing in a later update can restore a grant it does not know existed.

```sql
REVOKE EXECUTE ON FUNCTION lock_tree_notify(text,integer,integer,interval) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION lock_tree_notify(text,integer,integer,interval) TO your_role;
```

**If you are on 1.1.10 or earlier, this does not happen to you.** 1.1.12 ships a direct
`pg_lock_tree--1.1.10--1.1.12.sql`, one hop rather than two, so a plain
`ALTER EXTENSION pg_lock_tree UPDATE` takes it and never executes 1.1.11's `DROP`. The 1.1.9 case is
separate and older: `lock_tree_archive_find()` was genuinely dropped in 1.1.9 because removing its
`samples` output column changes the return type, so anything you granted on it went then, and only
you can restore it.

**Downgrade is not supported.** There is no `1.1.13--1.1.12` script, and `ALTER EXTENSION ... UPDATE TO`
will not go backwards. To get 1.1.12 behaviour back, install 1.1.12 in a scratch database alongside it.

**Upgrading from an earlier version chains automatically.** There is no `1.0.0--1.0.2` script, and
that is correct: `ALTER EXTENSION pg_lock_tree UPDATE` applies one step at a time and walks the
chain itself. The two exceptions are deliberate shortcuts, `1.1.8--1.1.10` past 1.1.9's faulty check
and `1.1.10--1.1.12` past 1.1.11's dropped grants, both described above. The oldest version an update
starts from is 1.0.0. Verified:

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
  `could not access file "pg_lock_tree--1.1.13.sql"`.
- To install into a fresh major version, repeat [Install](#install) against the new
  `pg_config`:
  ```bash
  sudo make PG_CONFIG=/usr/lib/postgresql/19/bin/pg_config install
  ```

## Backups and restores

**None of the three tables is registered with `pg_dump`, and that is a decision rather than an
oversight.** It is pinned by a test, so nobody has to take this paragraph's word for it, and
`scripts/check-upgrade.sh` re-checks it on every upgrade path.

| Table | In a `pg_dump`? | Why not |
|---|---|---|
| `lock_tree_history` | No | It grows without bound and holds query text. A restore usually lands on a different server, where its pids and timestamps describe nothing that ever happened there. |
| `lock_tree_alert` | No | Hysteresis state, keyed to roots that existed on the source server. Restored onto a new one it would suppress the first real alert there. |
| `lock_tree_deadlock` | No | A counter baseline from the source. On the target `pg_stat_database.deadlocks` starts again from zero, so the first sample would record a `counter_reset` and the history would read as a gap. |

**What this does not protect you from, and the thing worth being clear about.** A physical backup, a
base backup, a filesystem snapshot and a streaming replica all copy `lock_tree_history` whatever this
extension decides about `pg_dump`. Dump policy was never the control for credentials reaching a backup.
What keeps them out is `lock_tree_redact()`, applied by `lock_tree_sample()` on the way in, and that is
why it defaults to redacting and why 1.0.1 widened it.

**A dump taken before 1.0.1, and every physical backup taken before 1.0.1, still contains whatever the
history held at the time.** Upgrading scrubs the live table; it cannot reach into a backup already
written.

**To carry the history across a restore**, take it out explicitly before you dump:

```sql
COPY (SELECT * FROM lock_tree_history WHERE sampled_at >= now() - interval '7 days')
  TO PROGRAM 'gzip > /var/backups/lock_tree_history.csv.gz' WITH (FORMAT csv);
```

and load it back with `COPY ... FROM`. The `sampled_at` bound matters: the whole table on a long-lived
server is large, and the value of the history is recent.

**Exporting, rather than archiving in place.** If the goal is getting old history off the cluster,
export it. Measured on a 63M-row year of history, copying the rows older than seven days into a
table in the same database took **298 seconds** and roughly doubled peak disk while it ran, and the
original table still measured 9740 MB afterwards, because deleting rows does not return a file's
high-water mark. An archive built that way costs a year of extra disk and returns none of it. A
`COPY ... TO PROGRAM` to compressed file or Parquet has neither problem, and drops the query text
saving 77% of a row if you do not need it in the archive.

The full costs, the BRIN recipe for anyone who does want an archive table queryable in place, and why
the shipped read functions will not see it are in
[docs/history.md](docs/history.md#retiring-old-history).

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
PostgreSQL does not warn about this. It will happily load a 0.11 built for a different major
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