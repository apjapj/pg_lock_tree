# Changelog

All notable changes to `pg_lock_tree` are recorded here. Versions follow the extension's
`default_version` in `pg_lock_tree.control`; `CREATE EXTENSION pg_lock_tree VERSION '0.10'`
selects a release.

## 1.1.3 (2026-10-06)

1.1.3: the release notes contradicted the reference documentation, and one documented
behaviour was asserted nowhere

No SQL object changes. Both items were found by reviewing 1.1.2 against the rest of the tree,
and both are things a reader would have been misled by rather than broken by.

**1. The cost projection in the release script was wrong by about 2.8 times.**

`pg_lock_tree--1.1.2.sql` said of `lock_tree_incidents()`:

> Measured at 1.95 us per row as a caller uses it, which is 1.2 seconds per million rows: a
> month of history is about 30 seconds

`docs/history.md`, in the same release, said 1.55 us per row and put a month at 9.1 seconds.
One of them was wrong and both shipped. The per-row measurement was sound; the error was doing
the projection twice over, having taken 1.95 us with all three array columns present and then
multiplying by three again as though it covered one column rather than all of them.

The corrected figures, cold and best of three on the `scripts/bench-history.sh` fixture at one
sample per 10 seconds and 20 blocked sessions per sample:

| retain | rows | `incidents()` |
|---|---|---|
| 7 days | 1,209,620 | 1.8 s |
| 30 days | 5,184,020 | 9.1 s |
| 90 days | 15,552,020 | 25.6 s |
| 365 days | 63,072,020 | 110.5 s |

That is 1.55 us per row, or 1.55 seconds per million. The old note put a month of history at
half a minute when it is nearer a tenth of one, and it did so in the paragraph whose whole
purpose was to stop people being daunted by a large `lock_tree_history`.

The note now also says the thing that made the original mistake easy to repeat: `SELECT
count(*)` on this function is about eight times cheaper, at 0.20 us per row, because the
planner drops all three array columns. Timing this function with `count(*)` measures something
the documentation never claimed.

**2. The NULL asymmetry between two array columns is now asserted, in both directions.**

`lock_tree_incidents()` returns `applications` and `root_objects`. They treat NULL
differently, and the 1.1.2 notes described the difference without anything enforcing it:

- `applications` **keeps** a NULL element, because a session with no `application_name` is a
  real thing worth reporting, and `array_agg` does not skip NULLs.
- `root_objects` **drops** NULLs, because there a NULL means a prepared root whose object
  could not be resolved, and an empty element would be indistinguishable from an empty string.

This was not a hypothetical. While writing the 1.1.2 change, adding `IS NOT NULL` to
`applications` to make the two columns look consistent was tried, measured as a different
result, and discarded. The behaviour was load-bearing and unpinned, so the next person to
tidy it would have had no test to stop them.

`test/07_history.sql` now pins both halves. Each is a count of NULL elements rather than an
equality against a literal array, because an array containing a NULL cannot be compared with
`=` and a test written that way would error or quietly pass. The fixture plants a session with
no `application_name` and a root whose object is unresolvable, two minutes after an existing
sample so it folds into the incident already there rather than opening a third one.

Proven to fail in both directions, not merely to pass:

| build | result |
|---|---|
| as shipped | `Tests=35, Result: PASS` |
| `applications` filtered with `IS NOT NULL` | assertions 20 and 24 fail: `have: 0, want: 1` |
| `root_objects` no longer filtering NULLs | assertions 22 and 23 fail: `have: 2, want: 0` |

Five assertions added, `test/07_history.sql` from `plan(30)` to `plan(35)`. Three row-count
assertions in the same file moved from 15 to 17 because the fixture plants two rows, and the
comment describing the window's sample times was corrected to list the new sample.

**Not in this release, and still open.** `lock_tree_deadlocks()` does not name the two
participants of a deadlock. And `.forgejo/workflows/test.yml` still loads the release SQL by
piping it into `psql` rather than using `CREATE EXTENSION`, which is not equivalent: measured
on PostgreSQL 18, a proper install runs 423 of 423 tests and the piped load runs 364 with 59
failures across six files, because `CREATE EXTENSION` reads from the server's extension
directory, baked into the container image. That needs the test images rebuilt per commit, and
is recorded in `docs/roadmap.md`.

**Checks.** 428 tests pass on PostgreSQL 14, 15, 16, 17, 18 and 19beta4. All seven upgrade
paths to 1.1.3 end in exactly the objects a fresh install produces. 554 documentation checks
pass, including that every test file's `plan()` matches its assertions. And the empty update
script does what it exists for: one row in `lock_tree_history` before `ALTER EXTENSION pg_lock_tree
UPDATE`, one row after.

## 1.1.2 (2026-10-06)

1.1.2: lock_tree_incidents() stops sorting every row to find a few distinct values

One function body changes, `lock_tree_incidents()`, and **nothing it returns changes**. It is faster
because the work changed shape, not because it does less.

WHAT WAS SLOW

Each of the three array columns, `roots`, `applications` and `root_objects`, was a correlated subquery
of the form `array_agg(DISTINCT x ORDER BY x)`. PostgreSQL satisfies that by sorting every row in the
incident's time range, and on the standard fixture that is 1,209,620 rows sorted to produce arrays of
one and five elements. With the default `work_mem` the sort went to disk, once per column: 3,286 temp
blocks per call at a week of history, 557,041 (4.25 GB) at a year.

WHAT CHANGED

The `DISTINCT` is taken in a subquery first, which the planner satisfies with a hash aggregate, and only
the distinct values are sorted into the array:

    (SELECT array_agg(d.root_pid ORDER BY d.root_pid)
       FROM (SELECT DISTINCT h.root_pid FROM lock_tree_history h WHERE ...) d)

The `root_object IS NOT NULL` filter stays where it was. NULL handling is unchanged: `DISTINCT` keeps one
NULL and `array_agg` keeps it, sorted last, exactly as `array_agg(DISTINCT ...)` did, so `applications`
still carries a NULL element when a session had no `application_name`, and `root_objects` still has
none.

MEASURED

Same fixture, the 1.1.1 body and the 1.1.2 body alternated in one session, best of three,
`EXPLAIN (ANALYZE, TIMING OFF)`, PostgreSQL 18, fixture built by `scripts/bench-history.sh` with one
sample every 10 seconds and 20 sessions per sample, vacuumed before timing:

| retain | rows | 1.1.1 | 1.1.2 | change |
|---|---|---|---|---|
| 7 days | 1,209,620 | 2107.0 ms | 1785.1 ms | -15% |
| 30 days | 5,184,020 | 11410.8 ms | 9059.1 ms | -21% |
| 90 days | 15,552,020 | 32941.0 ms | 25569.4 ms | -22% |
| 365 days | 63,072,020 | 159110.4 ms | 110475.0 ms | -31% |

At 7, 30 and 90 days 1.1.2 writes no temp blocks at all. At 365 days it writes 44,818, against 557,041,
and those come from sorting 3,153,601 per-sample rows into incidents, a step this release does not
touch. With cold `shared_buffers` on the 7-day fixture the figures are 2188.1 and 1878.8 ms, -14%. The
measurement that proposed the change, in an earlier session, read 2411 and 2095 ms, -13%; the
absolute times move between sessions and the ratio is what has held.

PROVEN IDENTICAL, NOT ARGUED

The two bodies were compared row for row, both as text and as `EXCEPT ALL` in both directions:

- on the 7-day bench fixture, `max_gap` at 5 seconds, 1 minute, 5 minutes and 1 day, `since` at NULL,
  1 hour, 6 hours, 1 day and 30 days: 20 cases, up to 60,481 incidents in one call, all identical;
- on a small fixture in its own database with NULL `application_name`, an empty-string
  `application_name`, NULL, empty-string and non-NULL `root_object`, pid 0 roots, and an incident whose
  rows are all NULL: 8 `max_gap` values by 8 `since` values, 64 cases and 308 incidents, all identical.

THE DOCUMENTATION, MEASURED AT 30, 90 AND 365 DAYS

The retention tables in [docs/history.md](docs/history.md#reading-is-bounded-by-the-window-not-by-the-retention)
were projections from a 7-day per-row cost. The `incidents()` column is now measured at each retention,
with the fixture parameters stated beside the table, and the measuring turned up two things:

- **`incidents()` was not linear.** Its 1.1.1 cost per row rose from 1.74 us at a week to 2.52 us at a
  year, so the projected 132.5 s for a year was 17% light against 159.1 s measured. 90 days held.
- **`lock_tree_duration_by_application()` is not bounded by its window.** At its 7-day default it took
  2.3 s on a week of history and 30.3 s on a year. The page said it did not move. It does, and that is
  now written down there and in [docs/roadmap.md](docs/roadmap.md) as open and not yet diagnosed.
  `lock_tree_duration()` does stay flat, between 2.0 and 2.6 s.

The row counts in the whole-window table were also corrected to the fixture's own: they read
1,270,080 for seven days, which is not what seven days at 10 seconds and 20 sessions produces, and the
two projected columns were recomputed from the same per-row costs on the right counts.

UPDATE PATH

[`pg_lock_tree--1.1.1--1.1.2.sql`](pg_lock_tree--1.1.1--1.1.2.sql) is `CREATE OR REPLACE FUNCTION` with
the body and the `COMMENT` copied from the release file, not written again. The comment is unchanged and
restated anyway, because a body or comment that differs between the two files has failed
`check-upgrade` on every path before. No table, index or grant changes.

## 1.1.1 (2026-10-06)

1.1.1: the documentation said things that were not true, and nothing was checking

A release with **no SQL change**. Everything in it is documentation and release tooling. It is tagged
and versioned anyway, for the reason given under the update script below: a release with no update
path can only be installed by dropping the extension, and dropping it takes `lock_tree_history` with
it.

SEVEN LINKS THAT 404 IN THE BROWSER

Reported from the rendered page, not from the files. `docs/reference.md` linked to
`INSTALL.md#backups-and-restores`, and a renderer resolves a relative link against the file containing
it, so it looked for that file inside the `docs` directory, where there is no such file. The target
is at the repository root, one level above the document holding the link.

It was seven links, all with that one cause, and two of them were added by 1.1.0. All now carry the
`../` a renderer needs.

The check that should have caught it was wrong in a specific way. [`scripts/lint-docs.sh`](scripts/lint-docs.sh) tested
`[ -e "$p" ]` from the repo root **first**, and only then relative to the document, so a link from
`docs/` to a root file passed, because the file does exist at the root. Every existence test in the
script agreed with itself and disagreed with the browser. Two other things had to be untangled:

- Membership of "is this a markdown link" was first tested with `case " $link_targets " in *" $p "*`,
  which never matched, because `link_targets` is newline separated and the characters around a target
  are newlines rather than the spaces the pattern asks for. Every link was falling into the bare-name
  branch and the two rules had silently collapsed into one. It is an exact whole-line match now.
- Bare backticked paths are not links at all. `` `test/06_cron.sql` `` in prose renders as code, so
  it only has to exist somewhere. Applying the renderer's rule to it reported 24 false failures, which
  is why the two categories are now checked separately and the reason is written down.

**Anchors had never been checked at all**, because the extraction pattern excluded `#`. A target
carrying a fragment never matched, which is why the reported link slipped through even after the path
rule was right. Fragments are extracted now, split off, and tested against the target's headings,
slugified the way GitHub and Forgejo do it. That is 104 anchors verified for the first time.

NINE COMMANDS THAT WERE NOT RUNNABLE

Stripping link syntax out of fences exposed something worse underneath it.
`` [`scripts/check-alert.sh`](scripts/check-alert.sh) `` inside a `bash` block is not a link, because
a fence renders as code, and it is not runnable either, because `[` is the test command and the shell
would try to execute the label as if it were the command. Nine lines of the documentation looked like that, including commands a
reader would reasonably copy and paste. They are now plain commands, with the clickable link moved
into the prose above where a link belongs. One transcript fence was untagged and had to be tagged
`console` before the work could be done, which is recorded in the check rather than left as a mystery.

`scripts/lint-docs.sh` now fails on link syntax inside a fenced shell block, restricted to shell-ish
languages because inside an `md` block showing link syntax is the point. Verified in both directions.

AN SQL EXAMPLE THAT NEVER WORKED

    SELECT * FROM lock_tree_replay(42);      -- captioned "replay one incident, given its id"

`lock_tree_replay()` takes a `timestamptz` and always has, so that example has been wrong since 0.14.
Nothing in the repository executed the documentation's examples: [`scripts/lint-docs.sh`](scripts/lint-docs.sh) checked that the names
inside them exist and that their links resolve, which is not the same as the statement running. There
are 77 example statements across seven documents and none of them were checked.

`make check-examples` now plans every one of them with `EXPLAIN`, which parses and plans without
executing, so nothing is written and nothing is locked. Three cannot plan here because they call
`pg_cron` or `pg_tle`, which the documentation itself calls optional; those are listed with their
reason, and adding to that list has to be deliberate rather than a way to quiet a failure.

The example now finds the incident and replays from its start, which is what the caption meant, and
that form is verified to return rows.

Proven in three directions: a planted function name inside a named-argument call fails and exits 1;
the original `lock_tree_replay(42)` bug, reintroduced, fails with the message it always had; the clean
tree passes.

**One skip rule in that check hid the check from itself, and it is worth recording.** The first version
skipped any statement containing `<` or `>`, on the theory that placeholders look like `<PID>`. Named
arguments are written `since => interval '7 days'`, so it skipped every example using them, and named
arguments are what this project's own documentation recommends. So a planted

```sql
SELECT * FROM lock_tree_incidents_typo(since => interval '7 days');
```

was skipped, and the check reported zero failures on a tree carrying it. It now looks for an
angle-bracket **pair**.

THREE FIGURES THAT NO LONGER MATCHED

Reviewing the same pages turned up numbers that had drifted, all from the benchmark correction in 1.1.0.

`docs/roadmap.md` said the difference between the two duration functions was 688 ms while the table
above it, already updated, said 353 ms. The document contradicted itself, which is the failure mode
that table exists to prevent.

`docs/incident.md` quoted `lock_tree_statements()` at 17.9 ms, which was no longer the figure and is
not the same on two consecutive runs. It gives bounds now, because the point is the order of magnitude
and an exact figure that moves is worse than none.

`INSTALL.md` keeps the 0.15 figures of 980 ms and 78 ms, which are correct for that release, but a
reader could take 78 ms as current. It is not: the fixture those were measured on had never been
vacuumed, so every index-only scan in it was fetching every page, and the same one-millisecond window
measures 0.4 ms on a vacuumed fixture. The historical figure stays and now says so.

WHY AN EMPTY UPDATE SCRIPT

`pg_lock_tree--1.1.0--1.1.1.sql` contains nothing but a comment, deliberately. Measured on a database
carrying one sampled row:

    ALTER EXTENSION pg_lock_tree UPDATE,  1.0.2 -> 1.1.0:   1 row before, 1 row after
    DROP EXTENSION then CREATE EXTENSION:                    1 row before, 0 rows after

There is no other way to move an extension forward in PostgreSQL, so a release with no update path can
only be installed by dropping it, which takes `lock_tree_history`, `lock_tree_alert` and
`lock_tree_deadlock` with it. One empty file per release is a fair price for that.

VERIFIED

  - 423 tests pass on PostgreSQL 14, 15, 16, 17, 18 and 19beta4, none of them changed by this release
  - all 20 upgrade paths converge on a fresh install, including the empty one
  - `make check-schema` green
  - `make check-examples` green, 53 example statements planned and 0 failed
  - 541 documentation checks, under `LC_ALL=POSIX` and `LC_ALL=C.UTF-8`
  - `make demo` exits 0
  - gitleaks clean on the staged tree and on the history

Not verified: the Forgejo Actions verdicts, for the reason given in 1.1.0 and unchanged.

## 1.1.0 (2026-10-06)

1.1.0: the last read function you could not bound, and a benchmark that measured less work than it claimed

A minor release. Two changes to the extension and one to the tooling, all measured before they were
written. No function changes what it returns for the arguments it already accepted.

THE WINDOW ON `lock_tree_incidents()`

It was the only history read function with no `since`, so its cost followed how much history you had
retained rather than how much of it you were asking about. Measured at 1.95 microseconds per row as a
caller uses it, which is about 1.2 seconds per million rows: a month of history is roughly 30
seconds, and there was no way to ask it about less.

    lock_tree_incidents(max_gap interval DEFAULT '5 minutes', since interval DEFAULT NULL)

Two details that are easy to get wrong, and both are deliberate.

**`since` goes after `max_gap`, not before.** `test/07_history.sql` and `docs/after-the-incident.md`
both call this positionally. A new first parameter would have reinterpreted their argument:
`lock_tree_incidents(interval '7 days')` would have become a window rather than a gap threshold, and
would have returned one incident per sample.

**The default is `NULL`, not `interval '7 days'`.** NULL means the whole retained history, which is
what the function did in every release before this one, so an existing call changes nothing. A seven
day default would have matched its neighbours and would have quietly returned fewer incidents than
before on any database holding more than a week. That is a behaviour change wearing an additive
change's clothes, and it is invisible in review and visible in production.

Verified by fingerprinting rather than by argument: 1.0.2 installed into its own database, the same
fixture generated into both from one captured anchor, and the rows compared. Byte-identical for both
the no-argument call and the same-`max_gap` call, with the two fixture fingerprints asserted equal
first so a difference could not be blamed on the data. The first attempt at that comparison reported a
false DIFFERENT because each database called `now()` separately, which is why the anchor is captured
once and the fixtures are checked.

The filter is `WHERE sampled_at >= coalesce(statement_timestamp() - since, '-infinity'::timestamptz)`
rather than `WHERE since IS NULL OR sampled_at >= ...`, because the `OR` form cannot become an
`Index Cond` and would make even a call with no arguments scan the whole index. Confirmed in the plan:
with no window it is still an `Index Cond`, on `-infinity`.

`INCLUDE (query_id)` ON THE APPLICATION INDEX

`lock_tree_duration_by_application()` aggregates `DISTINCT query_id` per application. Without the
column in the leaf, that step was a bitmap heap scan fetching 24,133 pages to answer a question the
index already held.

| | plan | buffers | Heap Fetches | the step | the whole function |
|---|---|---|---|---|---|
| 1.0.2 | Bitmap Heap Scan | 24,133 | n/a | 117.0 ms | 2249 ms |
| 1.1.0 | Index Only Scan | 300 | **0** | **31.2 ms** | 2146 ms |

Measured cold, `shared_buffers` emptied by a server restart before every measurement, A/B/A/B:
2249.4 / 2225.7 ms flat against 2146.0 / 2157.2 ms with the column, so 103 ms cold and 87 ms warm.
The index grows 1,888 kB to 2,416 kB, which is 528 kB and 27% of a partial index holding one entry per
sample. One row per sample enters it, so the insert path measured flat: 15.4 ms against 14.8 ms for
one `lock_tree_sample()` with a real five-row chain up.

**This is a four percent win on a two-second function and is not a fix for that function.** The
remaining cost is aggregation, not access.

One caveat that comes with it. `Heap Fetches: 0` is the best case, on a table vacuumed once.
`lock_tree_history` is appended to by design, and new tuples are never all-visible on arrival. After
8,640 new root rows were added without vacuuming, the same scan reported `Heap Fetches: 29719` and took
55.1 ms. It recovers on the next vacuum. Still better than the 117 ms it replaces, but the headline
number assumes autovacuum is keeping up.

THE BENCHMARK WAS MEASURING LESS WORK THAN IT CLAIMED

`scripts/bench-history.sh` timed every read function as `SELECT count(*)`. `count(*)` asks only how many
rows came back, so the planner is free to drop any output column nobody looks at, and for
`lock_tree_duration_by_application()` that dropped the entire `qids` CTE: the plan contained no
`query_id` aggregation at all. Six of the seven read functions produced a different plan under
`count(*)`.

    SELECT count(*) FROM lock_tree_duration_by_application()   2048.3 ms, no ids aggregation
    SELECT *      FROM lock_tree_duration_by_application()   2249.1 ms, with it

For `lock_tree_incidents()` the understatement was tenfold. The three array columns are per-session
aggregates that `count(*)` drops, so any figure ever taken that way is a tenth of the real one:

| what is asked for | time |
|---|---|
| `count(*)` | 235.4 ms |
| `incident`, or `samples`, or `peak_sessions` | 233 to 254 ms |
| `longest_wait` | 494.2 ms |
| `root_objects` | 620.3 ms |
| `roots` | 831.1 ms |
| `applications` | 1125.9 ms |
| all ten columns | **2469.1 ms** |

So `lock_tree_incidents()` is the slowest function in the extension at 2.5 seconds, not the 0.24
seconds the benchmark had been reporting, and that is what put the window parameter first.

The script now times `SELECT *`, and asserts in its own output that the work it is timing is still in
the plan, including the half of the check that shows `count(*)` still drops it. That assertion is
structural rather than a time bound, because a time bound passes vacuously on a warm cache.

It also now vacuums the fixture before timing, which it never did. A fixture loaded by one big INSERT
has no visibility map, so every index-only scan was fetching every page: `lock_tree_incidents()`
measured 2660.5 ms before the vacuum and 233.3 ms after, an order of magnitude, same data and same
query. The script prints the all-visible page count so a reader can see the state the numbers were
taken in.

Corrected figures, PostgreSQL 18, the standard fixture, vacuumed:

| Function | Time | Reads |
|---|---|---|
| `lock_tree_statements()` | 15.8 ms | the live tree |
| `lock_tree_roots()` | 2.6 ms | the live tree |
| `lock_tree_text()` | 11.4 ms | the live tree |
| `lock_tree_history_statements()` | 245.5 ms | the history |
| `lock_tree_sampling_advice()` | 161.3 ms | the history |
| `lock_tree_history_size()` | 157.1 ms | the history |
| `lock_tree_replay_samples` | 1413.1 ms | the history |
| `lock_tree_duration()` | 1810.0 ms | the history |
| `lock_tree_duration_by_application()` | 2163.5 ms | the history |
| `lock_tree_incidents()` | 2476.8 ms | the history |

DOCUMENTATION

`docs/history.md` gains a section on holding more than a few weeks, because 7 days is not always
enough and nothing said what to do instead. The measurements behind it: a row costs 409.6 bytes with
the 300-character query text production stores and 93.2 bytes without it, so the query text is 77% of
the row and a year of retention is either 6.4 GB or 28 GB depending on it; the five bounded read
functions cost the same at a 7-day window however much you retain, while `lock_tree_incidents()` did
not; and plain `VACUUM` does not shrink the file, so the disk you need is the high-water mark of your
largest retention rather than your current one.

`docs/after-the-incident.md` had `lock_tree_incidents(interval '7 days')`, which passed a week as the
**gap threshold**, so every gap smaller than a week counted as no gap and the answer was a single
incident spanning everything. It now says `since => interval '7 days'`, which is what the surrounding
examples meant. Pre-existing, and invisible until the function had a second parameter to confuse.

`scripts/lint-docs.sh` learned to recognise an index. It checks that every `lock_tree_*` name in the
documentation is defined in the release SQL, for functions, views, tables and procedures, and 1.1.0
discusses `lock_tree_history_application_idx` by name in prose, which the check reported as an object
that does not exist. The name has to match in either order, because `CREATE INDEX` puts it before the
schema and qualifies the table instead. Verified by planting all four real index names, which pass, and
a name matching nothing, which fails.

PARTITIONING `lock_tree_history`, RE-MEASURED AND STILL NO

Not a change, a measurement that closes an old question with better numbers. The 0.11 decision not to
partition the history is still right, and the access argument is now stronger than it was. Against a
range-partitioned clone carrying the same four indexes, cold `shared_buffers` per measurement:

| window | `duration()` flat | partitioned | `by_application()` flat | partitioned |
|---|---|---|---|---|
| 7 days | 1606 ms | 2224 ms (+38%) | 2249 ms | 3324 ms (+48%) |
| 1 day | 257 ms | 233 ms (−9%) | 308 ms | 933 ms (+203%) |
| 6 hours | 61 ms | 67 ms (+10%) | 69 ms | 77 ms (+11%) |

Pruning does work, at a one-day window touching two partitions instead of eight. The problem is that
the planner does not choose a partition-wise join for the `root_wait` self-join, so the inner side of a
nested loop keeps no pruning qual and becomes an eight-way `Append` run once per outer row: 8,610
loops over eight partitions, reading 1,149,139 rows for a 172,320-row question. That node is the 203%.

What partitioning would buy is retention rather than access, and that is a different argument from the
one that has been made.

VERIFIED

  - 423 tests pass on PostgreSQL 18, 413 of them unchanged from 1.0.2
  - all 19 upgrade paths converge on a fresh install
  - `make check-schema` green
  - 455 documentation checks
  - the new window assertions proven non-vacuous by removing the filter from the shipped function and
    watching three of them fail, and the index assertions proven the same way
  - gitleaks clean on the staged tree

Not run here: the other five PostgreSQL versions, which is stated rather than implied.

Not verified: the Forgejo Actions verdicts. Every API endpoint answers 403 from this host and no token
is available, so the gates were run locally with CI's exact commands instead. That is not the same as
the workflow being green, and it is not claimed to be.

## 1.0.2 (2026-10-05)

1.0.2: the sampling advice contradicted itself on a quiet database

A patch release, and it changes one sentence. No function changes what it returns, no signature
changes, no column and no grant changes.

THE BUG

`lock_tree_sampling_advice()` on a database with nothing blocked and an empty history returned:

    suggested_every  00:00:05
    reason           nothing blocked now and nothing in the window: the table stays empty at any
                     interval, so sample rarely

`00:00:05` is the **finest interval the function ever returns**. The reason told a reader to sample
rarely, in the same row, beside the advice to sample five times more often than anything else it
offers. Found in the 1.0.1 review, and unchanged since 1.0.0.

The interval was right and the wording was wrong, so the interval is untouched. Nothing is blocked, a
sample writes no rows at all, and 5 seconds costs one cheap query while catching the next incident in
detail. The reason now says that:

    nothing blocked now and nothing in the window: a sample writes nothing here, so 5 seconds costs
    one cheap query and still catches the next incident in detail

That is the review's suggested wording, with `a sample writes nothing here` rather than `a sample
writes nothing`, because the second row of the example in `docs/alerting.md` describes an empty history
rather than a quiet one, and the two now read differently on purpose.

HOW IT IS SHIPPED

`pg_lock_tree--1.0.1--1.0.2.sql` replaces the whole function, because the string is inside its body
and a versioned script has no narrower way to change one. The body is byte-identical to 1.0.1's apart
from that one line, verified by diffing the two files, and `look_back`, the seventh returned column,
is present: it is the one a rewrite is most likely to drop.

`scripts/check-upgrade.sh` is the real check. It compares the catalog a fresh 1.0.2 install produces
against the catalog every upgrade path produces, so anything else that moved fails there rather than
passing unnoticed. All 18 paths are verified.

Also in this release, from the same review, with no version change of its own:

  - the em-dash and en-dash checks had never run in CI. `printf '\u2014'` only emits the character in
    a UTF-8 locale, and a bare container gives you POSIX, so both checks passed on a file full of
    dashes. Reproduced: an injected em-dash gave "all 439 checks passed" under `LC_ALL=POSIX`. The
    characters are now built from their UTF-8 bytes.
  - outside a git checkout [`scripts/lint-docs.sh`](scripts/lint-docs.sh) failed on itself, because the no-git fallback lists paths
    with a leading `./` that the self-exclusion did not match. The fallback exists for tarball users,
    so they were the only people who hit it.
  - the version classifier assumed two-part version numbers in two places, so it reported 16 release
    scripts and 15 update paths where there are 18 and 17, and both 1.0.x update paths were checked as
    releases. They passed only because the Makefile lists them in DATA, which its own comment says
    update scripts must not be.
  - the deadlock section said "Nothing in SQL does" name the two statements. It does, when a sample
    lands while the cycle exists: verified on PostgreSQL 16 with `deadlock_timeout` at 15s, where a
    sample during a real cycle put two rows in `lock_tree_history` at depth 0 with `waiting_for` set
    and the query text. On the 60,481-root benchmark fixture, **zero** depth-0 rows have `waiting_for`
    set, so the shape really is unique to a deadlock.
  - the log format shown for a deadlock was not PostgreSQL's. The real entry has one `DETAIL` with
    both participants as `Process N:` lines, which the client never sees, then `HINT`, `CONTEXT` and
    `STATEMENT`. Verified on PG16 with `log_lock_waits=off` and `log_min_duration_statement=-1`.
  - the sampling-advice example in `docs/alerting.md` showed output the function cannot produce: the
    wrong reason for the first row, and `roots = 9` where the real value is 0. Both rows are now the
    function's output on a seeded history.

The review's own summary is that findings 1 to 3 are tooling and 4 to 6 are doc and text defects, and
that none of them changes what the extension does to a database. That is the right reading, and the
only behaviour change in this release is the sentence above.

VERIFIED

  - 414 tests pass on PostgreSQL 14, 15, 16, 17, 18 and 19beta4
  - all 18 upgrade paths converge on a fresh install
  - `make check-schema` green
  - 446 documentation checks, under both `LC_ALL=POSIX` and `LC_ALL=C.UTF-8`
  - gitleaks clean on the staged tree and the history

a number that belonged to a different function, and every example now says whether it was checked

No SQL change, so no version bump.

`lock_tree_statements()` WAS NOT THE SLOW ONE, AND WAS NOT IN THE BENCHMARK

I suggested reviewing it for being slow, on the strength of a 3026 ms figure in the benchmark table.
That figure is `lock_tree_duration_by_application()`. `lock_tree_statements()` appears **zero times** in
`scripts/bench-history.sh`, so the number I quoted was for a function that had never been measured.

Measured, against the same 1.2 million row fixture:

| Function | Time | Reads |
|---|---|---|
| `lock_tree_statements()` | **17.9 ms** | the live tree, and `pg_stat_statements` |
| `lock_tree_roots()` | 2.4 ms | the live tree |
| `lock_tree_text()` | 12.8 ms | the live tree |
| `lock_tree_duration()` | 1941.6 ms | the history |
| `lock_tree_duration_by_application()` | 2629.6 ms | the history |

Seventeen milliseconds against seven days of history, because it reads the tree as it is now. It was
never a candidate.

The benchmark now times the live-tree reads as a separate group, labelled as not touching the history.
That is the actual fix: the omission is what let a number be attributed to the wrong function, and a
reader should not have to know which of these reads the history to know which will be slow.

THE 688 ms IS A FIFTH SCAN, AND THE SCAN IS REQUIRED

The per-application variant has an extra CTE, `qids`, collecting the distinct `query_id`s an application
was root for, worth 100 to 160 ms on its own. The obvious cheaper shape derives it from `rooted`, which is
already filtered to `depth = 0` and grouped by application, and that would remove a scan. It would also be
wrong: `rooted` is at the grain `(sampled_at, application_name)`, and adding `query_id` to that grain
takes it from 23,036 rows to 150,485 on the fixture, because one application can be root for several
queries at one instant. `rooted` is joined at both ends of every gap, so the wider grain double-counts the
gaps for exactly the applications that were busiest. Measured, not reasoned: that is the row count.

So it is not a defect, and it is recorded because the number was quoted at the wrong function.

EVERY EXAMPLE NOW SAYS WHETHER IT WAS CHECKED

The scheme only works if an example is one or the other. An unmarked block is indistinguishable from a
capture, and a reader has no way to know whether anybody checked it. Four blocks were unmarked, and two of
them were a psql prompt with no output under it, which reads like a transcript that got truncated. There
is no capture for either: no scenario runs `lock_tree_deadlocks()` and none lists `pg_prepared_xacts`, so
both now show the query rather than a fake transcript of it.

The other six are marked written, each with why it is not a capture: the replay block shows a longer
incident than the demo's by-hand samples produce, the incidents table selects `started_at` where the
demo's does not, and the escalation timeline and the pid-0 tables are drawn to make a point that
scenarios 4 and 7 print for real.

[`scripts/lint-docs.sh`](scripts/lint-docs.sh) now checks every fenced block which looks like output carries a marker. The test for
"looks like output" is deliberately loose: a psql prompt, a table header starting with a column name, a
numeric row, a box-drawing glyph, a rule of dashes. A false positive costs one comment; a false negative
costs a reader's trust. `CHANGELOG.md` is exempt, for the same reason the object check exempts it: a
changelog records what was true at the time.

Proven in both directions. Removing one marker fails with the file and line. Removing a marker *and*
replacing the block's body with a single plain query passes, so the check is not asking for a comment on
every code block.

Verified: 413 tests pass on PostgreSQL 18, `make check-schema` and `make check-upgrade` green, the demo
exits 0, the captures are byte-identical across runs, 439 documentation checks, gitleaks clean.

documentation review: one real omission, and the checks that would have caught it

Every claim in the ten documentation files checked against the release, the tests or a live server.
One omission was real and it is about privileges, which is the category where a documentation bug is a
security bug.

RAISING AN ALERT NEEDS FOUR PRIVILEGES, AND IT SAID "WRITABLE"

`docs/alerting.md` said `lock_tree_alert` "must be writable by whoever runs the sampler", and INSTALL.md's
Grants section did not mention the table at all. A reader who followed the documentation, granted
`INSERT` because that is what "writable" suggests, and called `lock_tree_notify()` got:

    ERROR:  permission denied for table lock_tree_alert

which names the table and not the missing privilege. Measured on 1.0.1 with a role holding everything
else INSTALL documents: no privileges at all is refused, and `SELECT, INSERT, UPDATE, DELETE` works.

**No minimum is quoted, because there is not one that can be relied on.** Every subset tried was
accepted on one run and refused on the next, with the same grants and the same empty `lock_tree_alert`,
so which privileges are individually required appears to depend on what the channel has already
recorded. A minimum that changes with the contents of the table is not worth writing down, and a reader
who grants three of four and gets a working alert has not been told they are one privilege short. Both
pages now say to grant all four, and say why no smaller answer is given.

`test/02_permissions.sql` gained four assertions. Two of them are functional and proven non-vacuous by
planting a three-privilege grant and watching them fail.

**The refusal itself is not asserted, and the reason is in the test's header.** Run outside the harness
the call fails as described. Inside pgTAP it completes: same role, same grants, same empty table, the
only difference being that pg_prove runs the file in a transaction. An assertion that passes in the
harness and fails in a shell is worse than no assertion, so what is asserted is the precondition, which
is a catalog fact: the table exists, and the role holds none of the four privileges on it. Both were
shown to fail when pointed at a table name that does not exist, so neither passes on an empty set.

WHAT ELSE WAS CHECKED, AND WHAT WAS WRONG WITH IT

  - every function the documentation names exists in 1.0.1, and every documented argument list matches
    the real one. The differences a mechanical comparison found are parameter names against types, such
    as `lock_tree_age(interval)` where the release says `i interval`, which is correct as written
  - the two example NOTIFY payloads in docs/alerting.md carry exactly the keys the SQL builds, no more
    and no fewer, and the 8000-byte payload limit quoted is PostgreSQL's
  - 413 tests, 60,481 instants, 1.2 million rows, six matrix versions, eight scenarios, fifteen window
    bounds: all of them still true
  - the performance notes said "187 MB" for what `make bench-history` prints as 266 MB. Both are right
    and they are different things: 187 MB is the heap, 266 MB includes the indexes. Both pages now say
    which is which, because a reader comparing the two numbers would conclude one of them was wrong

The `lock_tree_alert` row in the new table is deliberately blank, and the first draft of that table was
not: it named a minimum, from a single run, that the next run contradicted.

Verified: 413 tests pass on PostgreSQL 18, `make check-schema` and `make check-upgrade` green, the demo
exits 0, the captures are byte-identical across runs, 424 documentation checks, gitleaks clean.

the whole-window read, measured and left alone; the demo now matches the README

No SQL change, so no version bump. Two findings and one fix to the documentation's own tooling.

WHOLE-WINDOW `lock_tree_duration()`, AND WHY THE ROADMAP ITEM WAS WRONG

The first item on the roadmap for several releases, on the reasoning that the four CTEs each re-read
the history and merging them into one pass should help. Three implementations were built and timed
against `make bench-history`'s fixture: seven days, a ten second interval, twenty blocked sessions,
1,209,620 rows on PostgreSQL 18, a 187 MB heap and 266 MB including indexes, which is the figure `make bench-history` prints. Each was timed alternating with the shipped function so
both saw the same cache, four runs, mean of the `root_wait` join, which is 43% of the function.

| Version | Mean |
|---|---|
| Shipped: the root rows probe the same sample's waiter rows | **643.9 ms** |
| The waiters aggregated once by (sample, root, object), then joined | 643.0 ms |
| One materialised CTE, read once, all four CTEs derived from it | 2,900 ms, against 1,460 ms for the whole shipped function |

The third is the failure the reasoning predicted would work, and the reason is worth keeping. A CTE has
no index, so the self-join stops being an index probe per root row and becomes a scan of the
materialised set. Reading the table once is not the same as reading it cheaply, and merging passes over
an indexed table loses more than it saves.

A covering index on `(sampled_at) INCLUDE (depth, query_id, root_pid, root_object, wait_age, pid)` was
built and measured: 79 MB, 42% of the heap it indexes, and no measurable gain. The planner used it for
one side of the join and the time did not move, so the cost is not the heap access. `work_mem` buys
about ten percent, from 1,360 ms at 4 MB to 1,220 ms at 256 MB.

So the cost is the scan and the aggregate over 1.15 million joined rows, and neither is removable by
restructuring. It stays the slowest read in the extension.

Two false readings on the way, both of which would have gone in a commit message as results:

  - the aggregated-then-joined version first measured 158 ms against 704 ms, which is a 4.4x
    improvement. It was matching nothing: `USING` will not match a NULL `root_object`, which is most
    rows, so it returned zero rows. With `coalesce` it returns 60,471 rows, identical to the shipped
    version in both directions, and takes the same time. A 4x speedup that produces no rows is not a
    speedup
  - a 2,900 ms candidate was described as "worse" before noticing it is 2x the whole shipped function
    rather than 2x the one query it replaced

DEMO.SQL BUILDS THE INCIDENT THE README ILLUSTRATES

The README's example and the demo's output were two different incidents: the README showed a table
called ledger with one ALTER and two reads, the demo built demo_ledger with one ALTER and three reads,
with different numbers. A reader who ran `make demo` saw something the README did not promise.

Each waiter's `application_name` now goes in its own `dblink_exec`, before the query that is going to
block. Sent as one string the recorded query is the whole string, so `lock_tree_text()` truncated
"BEGIN; SET application_name='schema_change'; ALTER TABLE ..." and the tree showed the SET rather than
the DDL the session exists to illustrate. The demo was printing the wrong statement.

That exposed a hang. The cleanup collected the backends to terminate by asking each dblink connection
for its own pid, which needs that connection to have no query in flight, and four of them do: they are
blocked on the culprit's lock, which is not released until the next step terminates it. The collect
step waited for a lock only the following step could release, and the demo exited 124 on every run. It
collects from `pg_stat_activity` now, which needs no cooperation from the session it asks about and
finds the deadlock sessions without a hard-coded name list. Verified: exit 0, and the demo's own
leftover count reports zero.

BOTH README TRANSCRIPTS ARE NOW CAPTURES

The tree needed one thing psql will not give. psql right-aligns each column to its widest value, so a
run where every pid is three digits lays out differently from one where a pid is four, and masking
happens afterwards and cannot undo a choice psql has already made. Runs of two or more spaces become
exactly two, which keeps the columns apart and is the same whatever the pids were; leading indentation
is left alone because it is the depth; single spaces inside a statement are left alone because
"SELECT sum(amount) FROM x" has one. Proven by feeding the extractor a narrow and a wide transcript:
five lines each, identical.

The second transcript was worse than a different example: hand-written, it said pid 166 and three
blocked sessions, directly under a tree that said `<PID>` and four. Both now come from the same run.

Four generated blocks are compared on every run. No illustrative blocks are left in the README.

Verified: demo exits 0 leaving no sessions, 409 tests pass, check-schema and check-upgrade green, 421
documentation checks, no em-dashes or en-dashes.

the CI verdicts could not be read, so the gates were run locally instead

No code change. This is what was found while trying to answer the one open question the API could
not.

WHAT THE RUNNER SAYS

All four job types do run, and have been running on every push. Read from the runner container's log
rather than the API: `lint`, `gitleaks (history)`, `detect-secrets (tree at HEAD)` and `pgtap` for 14,
15, 16, 17, 18 and 19beta4. Tasks for this repository are in the log continuously, the most recent
matching these pushes, and the whole log contains zero lines at error or warn level.

WHAT IT DOES NOT SAY

The runner log records task lifecycle and network cleanup, and nothing else: no exit code, no
conclusion, no failed step. So it can tell that every job ran and cannot tell that any of them
passed. The API would, and every endpoint returns 403 from this host: the repository endpoint, the
commit status endpoint and the actions endpoint alike, with or without a token, and no Forgejo
credential is present in the environment or on disk.

So the verdicts are unreadable from here and are not claimed.

WHAT WAS RUN INSTEAD, WITH THE CI COMMANDS AND VERSIONS

  - `./scripts/lint-docs.sh`, which is the whole of the lint job: 418 checks pass
  - `gitleaks git --no-banner --redact --config .gitleaks.toml`, the gitleaks job verbatim: 42 commits
    scanned, no leaks found
  - `detect-secrets scan --all-files --force-use-all-plugins --exclude-files '^\.git/'`, with
    detect-secrets 1.5.0 as pinned: 0 findings, including the newly committed captures
  - `pg_prove --dbname postgres test/*.sql` on all six versions: 409 tests pass on each

The detect-secrets run is the one worth having. The new committed files are captured program output,
which is exactly the shape that a secret scanner exists to look at, and the answer is that the masking
replaces every pid, wait and timestamp with a named token before anything is written.

FOUR THINGS THIS FOUND, NONE OF THEM ABOUT SECRETS

  - the two secret jobs install their tools inside the job container, and that image has neither
    apt-get nor python3, so neither gate can be reproduced on this host without a different image. CI
    does it inside its own container and has always done so
  - `mapfile`, which the new generated-example check used to split the mask, is a bash 4 builtin and
    this script runs in a container whose bash version the repository does not control. Replaced with a
    while loop, which every bash that can run the rest of the file supports
  - the mask was being read out of capture.sh with a sed line range, which also swallowed the comment
    lines inside the array. GNU sed ignores an expression beginning with #, so it worked by accident,
    and 21 "expressions" were read where there are 11. Left alone it would have kept working only for
    as long as that accident held
  - the check that the mask actually masks was defeated by renaming a replacement string, because it
    only asserted that volatile tokens had gone and not what had replaced them. It now asserts the
    four named tokens are present, and all three sabotages are caught: renaming a replacement, deleting
    a rule, emptying the array

documentation: captured examples, and a check that had never been shown to fail

Three things, none of which changes the extension. No SQL behaviour change, no control file change,
and no version bump.

`make scenarios` WAS SILENTLY DOING NOTHING

`make scenarios` printed "make: 'scenarios' is up to date." and exited 0. make saw the scenarios/
directory, found no prerequisites newer than it, and declined to run the recipe. The README,
CONTRIBUTING.md and the Makefile's own comment all say it captures the eight scenarios, and it has not
done so since the directory was added.

Every target is now .PHONY. None of them produces a file of its own name, so all of them are
procedural. `scripts/lint-docs.sh` checks that every target in the Makefile is .PHONY and names the
consequence when one is not: if the target is also a path in the tree, make would report it up to date
and do nothing. Proven by putting the bug back.

GENERATED EXAMPLES, AND THE ONES THAT ARE NOT

Every example in the documentation is either captured from a run or written by hand, and only the
first kind can be checked. Both are now marked.

Captured: `scripts/capture.sh` runs the code, masks what moves between runs, writes `docs/examples/`,
and `scripts/lint-docs.sh` compares the documentation's copy against it. Two are wired up, chosen because
they were the two hand-transcribed measurements: the coverage table in scenarios/README.md, which was
eight rows of numbers copied out of scenarios/out/ by a person while run.sh derived them
independently, and the order the demo prints.

Written: the README's two transcripts are shortened for reading, with round pids and every wait 0s.
They carry an `illustrative` marker and the README says what that means, including that `make demo`
prints the same shape on a different table with one more reader. Nothing checks them, because there is
nothing to check them against. The marker stops a hand-written example reading as evidence for itself.

The mask covers pids standing alone, after a box-drawing glyph, inside brackets and inside arrays,
waits in every form including 1m30s, and timestamps, each with a named replacement so a diff shows what
was hidden. It deliberately does not mask the coverage numbers, because masking the thing under test is
not a check. Proven sufficient by capturing twice on a live server and diffing: identical. The two captures that
are *compared* are stable, and were checked again with a different set of backends. The full transcript
is not, and is not compared: psql aligns a numeric column to its widest value, so a run whose pids are
all three digits lays out differently from one where a pid is four, and notices depend on the server's
history rather than on the code. Stated in capture.sh rather than left to be found.

FOUR BUGS IN THAT CHECK, EACH FOUND BY PLANTING

  - the marker scan required a code fence, so a generated markdown table read as having no content
  - markers were read from the whole file, so CONTRIBUTING.md documenting the marker syntax in a fence
    demanded the placeholder filename in the middle of the page
  - the marker scan took the file as its pattern and the pattern as its file, so every line mentioning
    the file matched. An argument-order mistake that turns a check into noise rather than an error
  - a markdown link label was read as a path, so a link whose label was a bare filename reported a
    missing file that has been there all along

TEST/22 IS NO LONGER VACUOUS

It has been open since it was written: the header said the planted defect never reached the catalog, so
its central assertion had never run against a defective function. It has now, and the reason it had not
is mechanical rather than subtle. Both halves read the INSTALLED catalog, so editing the file changes
nothing until `make install` and a fresh `CREATE EXTENSION`. The earlier attempt skipped that and read
a passing test as evidence that the check was broken.

The defect was one line in lock_tree_command()'s body: `FROM @extschema@.lock_tree_roots()` became
`FROM lock_tree_roots()`, which is precisely the mistake the file exists to notice.

  - `test/22_schema_install.sql` failed tests 8 and 9, and test 9 named the function rather than only
    counting it: `have: lock_tree_command(1)`
  - `scripts/check-schema.sh` reported `1 unqualified sibling calls in lt_check` and then
    `unreachable: SELECT count(*) FROM lt_check.lock_tree_command()`
  - the other twenty files and their 398 assertions passed unchanged

That last line is the point of both files, and it is now measured rather than asserted: in a public
install the defect is invisible, so only a private-schema install exposes it. Both files were restored
and re-verified.

CONTRIBUTING.md now has the plant-reinstall-run-restore recipe, because the step that gets skipped is
the middle one and skipping it produces a false negative that looks like a broken check.

VERIFIED

  - 409 tests pass on PostgreSQL 18, and `make check-schema` end to end
  - 415 documentation checks, up from 203
  - the two compared captures byte-identical across runs, re-checked against a fresh server
  - gitleaks clean on the staged tree and the history
  - no em-dashes and no en-dashes in any document, including the captures

STILL OPEN

The examples that are hand-written stay unverified, and that is now said where a reader will see it
rather than left to be discovered. The capture covers the two blocks that were measurements; making
every transcript in the documentation come from a run would mean changing demo.sql to build exactly the
incident the README illustrates, which is a judgement about which example is worth more than the other.

documentation: the split, by when the reader arrives

The README was 1,270 lines with fifteen sections and served four readers at once. It is now 151 lines
and an entry point, with the argument on the page its reader arrives at for some other reason.

No version number on this one, because there is nothing here to release: not one line of SQL, the
control file, the Makefile or the test suite changed. It goes out under whatever release carries it
next, or on its own.

Three commits, in this order, because the middle one is worth reading on its own:

  - a verbatim move of every section, whole and unedited, into docs/ and CONTRIBUTING.md, so the
    diff reviews as moves
  - a link and anchor check, which found four broken links in INSTALL.md and four in this file
  - the rewrite: page openings, the duplication removed, and the version history moved into here

DOCS ONLY. No SQL, no control file, no Makefile change, no version change to the extension.

WHAT MOVED, AND WHERE A READER LANDS NOW

| Was | Now |
|---|---|
| 15 sections in README.md | README.md, plus docs/incident.md, alerting.md, history.md, after-the-incident.md, reference.md, roadmap.md, design-notes.md and CONTRIBUTING.md |
| Alerting, 315 lines | docs/alerting.md, unchanged apart from an opening and its own `##` structure |
| When the queue is too wide to read, 206 lines | docs/incident.md, which also took the prepared-transaction material |
| Objects and the stability statement | docs/reference.md |
| Development | CONTRIBUTING.md |
| Roadmap | docs/roadmap.md |
| Stability, from 1.0.0 | docs/reference.md |
| Everything said about sampling, pruning and redaction, scattered | docs/history.md |

INSTALL.md did not move. It already served one reader, which is the test the others were measured
against.

THE LINK CHECK, AND THREE BUGS IN THE CHECK

The split is worth automating a check for: sections moved between files, so a link that used to be
`README.md#some-heading` now points at a heading in another file, and nothing in a text diff shows
that the anchor has stopped existing. The changelog had been linking to README anchors for several
releases before the check existed.

Building it turned up three bugs in the check itself. Each was found by planting a defect and
watching the check pass, which is the only way to know a negative check is doing anything:

  - the extractor required a `#`, so every anchorless link went unchecked. A link to a file that does
    not exist passed, provided nobody had added a fragment to it
  - same-file detection tested path == target, which is true for any link with no fragment, so the
    missing file was rewritten to the linking file, which does exist
  - anchors are generated lower-case and the fragment was compared as written, so `#Redaction` missed
    `#redaction` and reported a heading that is plainly there

All fourteen cases are now checked in both directions, with the positive cases proving the check does
not simply fail on everything. Two false alarms of my own are worth recording, because I would have
read them as results: the first two proof runs planted defects into a string that did not exist in the
file, and "passed" could have meant the check was broken or that nothing had been planted. It was the
second.

A FOURTH CHECK, FROM A MISTAKE IN THIS WORK

Writing CONTRIBUTING.md, I named `make lint` twice. There is no such target. It is plausible either way
in review, so lint-docs now checks that every `make` target the docs name exists, anchored to lines
beginning with `make` so that "make sure" is not read as one.

THE SAME FILE HAD TWO INVENTED TEST ROWS

a row for a scenarios file numbered 19, and a catch-all row for a numbered 20, neither of which
exists: the real file at 19 is `test/19_index_usage.sql`, and no file numbered 20 has ever existed. The test table check
caught it, which is the argument for that check, and it caught the second one too.

Written without the `test/` prefix on purpose. The path check reads a backticked path as a claim that
the file exists, and in this sentence that claim is the opposite of the truth, so a bare path here
would be a false failure rather than a false pass.

DUPLICATION AND DATED PROSE

A move like this creates both, so both were dealt with rather than left tidy:

  - "What it looks like" was in the README and in docs/incident.md, which is 51 lines of psql
    transcript in two files on the same reader's path
  - the `statement_timestamp()` scheduling hazard was in two places. It is a fact about scheduling,
    so it is on the history page with the rest of scheduling
  - design-notes.md first restated four arguments that already had a home. It is now an index of
    every design argument and where it is made, plus the three with no page: the redaction pattern,
    the column order and the `search_path` pinning

The rule applied to the prose is that version history lives in this file. Four passages dated
themselves: the 0.15 window bounds, the 0.12 to 0.13 columns, "which took until 0.8 to get right",
and "0.4 keeps a history". Each now states the current behaviour and points here. Where the change
was a migration warning, such as `blocked_sessions_peak` having been one too high per sample, the
warning is kept, because a reader on an old release needs it.

VERIFIED

  - 409 tests pass on PostgreSQL 14, 15, 16, 17, 18 and 19beta4
  - all 17 upgrade paths converge on a fresh install
  - 203 documentation checks, up from 236. Fewer, because the checks that read the README now read
    the page each object and each test is documented on, and one new check covers every page at once
    where two used to cover the README alone
  - gitleaks clean on the staged tree and the history
  - no em-dashes and no en-dashes in any document
  - the version check fires when the README and the control file disagree, in both directions

The first two attempts at the 19beta4 run reported every file as having no plan, which reads exactly
like a failure in the extension. Both were the runner, and the first diagnosis was also wrong.

  - first guess: the container accepts connections while its init scripts are still running, so the
    suite ran against a database that was not finished. Waiting for a query rather than for the port
    did not help, which is what showed the first guess was wrong.
  - the actual cause: the runner mapped that version to image tag 19 rather than 19beta4, so no
    container ever started and pg_prove was reporting against nothing.

Set up by hand, 19beta4 passed throughout, which is what kept the wrong diagnosis looking plausible for
longer than it deserved. A symptom that reads like a product bug is worth assuming is the harness
until the harness has been read line by line. All six versions pass in one sweep.

NOT DONE

The non-public schema test's vacuity is still not proved. `test/22_schema_install.sql` asserts that
`lock_tree_sample()` cannot be reached unqualified from outside a private schema, and the planted
defect never reached the catalog, so the assertion has still never run against a defective function.
Its header says so.

The examples are still hand-maintained, which is item (e) and (f) of the corrections below and still
the reason the corrected figures can drift.

0.16: the README's factual errors, corrected, and two of them made unfixable by omission

The nine errors the review of 0.14 listed in the README, seven of them corrected here. Two were in
the Roadmap, which 1.0.1 rewrote, so they are already gone.

WHAT WAS WRONG, AND HOW IT WAS ESTABLISHED

  a  "log_lock_waits = on ... in postgresql.conf, then restart". Both are reloadable and
     neither needs a restart. Verified on PostgreSQL 18: `pg_settings.context` is `superuser` for
     both, not `postmaster`, and `pending_restart` is false. The README now says
     `SELECT pg_reload_conf()` and shows how to tell the two kinds of setting apart.

  b  `log_min_duration_statement = 0` "so the CONTEXT lines are there too". Not needed, and
     costly: it logs every statement the server runs. A deadlock is logged at ERROR and the DETAIL
     line names both processes with the statement each was running, so the text is already there.
     **Verified on PostgreSQL 16 with default settings** (`log_lock_waits=off`,
     `log_min_duration_statement=-1`): `pg_stat_database.deadlocks` went from 0 to 1 and the log
     entry named both statements. The recipe that works, and the reason it matters:

         begin; update dl ... id=1; select pg_sleep(1); update dl ... id=2; commit;

     in each of two sessions, with the ids swapped and the second starting 0.3s after the first.

     My own three attempts produced a counter of zero and an empty log, and the diagnosis is worth
     recording because it was not a logging difference: the background clients died before they
     reached the lock, so there was never a deadlock to log. Two session-scoped traps account for
     it. A `docker exec -d` does not keep a session alive across calls, so the lock went with the
     holder. And `UPDATE ... WHERE id = 1 SET id = 1` rewrites nothing, so it may never take a row
     lock worth deadlocking over. Both were fixed by holding both sessions inside one shell and by
     making each UPDATE genuinely change the value, and the change that actually mattered was the
     second one.

  c  "`pg_stat_reset_shared('db')` sets it to zero". That function does not accept `'db'` at all.
     Verified on PostgreSQL 18:
         ERROR:  unrecognized reset target: "db"
         HINT:  Target must be "archiver", "bgwriter", "checkpointer", "io",
                "recovery_prefetch", "slru", or "wal".
     `pg_stat_reset()` is the function that resets the current database's counters. And stats are
     also discarded after a crash, which is a second reason `counter_reset` exists; the README said
     only the first.

  d  `pg_stat_database.deadlocks` "present since PostgreSQL 13". Since 9.2. Harmless, and wrong.
     From the review, with the depesz link it cites.

  e  The intro example: the tree shows three waiters under pid 166, and
     `lock_tree_roots()` and `lock_tree_actions()` said it blocks 4. Now 3 in both places. This one
     is verifiable by counting the tree printed directly above the number, which is the only reason
     it is worth trusting a hand-maintained example at all.

  f  The replay example paired an `AccessExclusiveLock` waiter running `SELECT count(*)` with
     `AccessShareLock` waiters running `INSERT INTO audit`. Neither pairing is possible: a SELECT
     takes AccessShareLock and an INSERT takes RowExclusiveLock, and AccessExclusiveLock is DDL
     only. Corrected to match, and the correction is in the Objects table's own vocabulary rather
     than in a hand-maintained list.

  g  The test table stopped at `test/15_history_size.sql` while the text referred to files 16, 17 and 18.
     It was actually seven rows short: 16 through 22 are all absent. Added, each saying what the
     file pins down and why, including the two that exist because a first draft failed
     (`test/19` asserted on query plans and was demanding a worse plan; `test/17`'s expectations
     had been derived from the join under test).

  h  and i  Roadmap items, one of which said "Next" and then "Deliberately not planned" in the
     same entry. 1.0.1 rewrote the section and both are gone.

TWO LINT CHECKS ADDED, AND ONE OF THEM FOUND A REAL GAP IMMEDIATELY

  A test file on disk that the README test table does not mention is now a FAILURE. It was a note,
  and the note had been printing on every run, every day, to nobody: the review of 0.14 found
  files 16 to 18 missing from the table while the script said so quietly. A check that reports a
  real problem at a severity that gets ignored is worse than no check, because it teaches the reader
  that the output is not worth reading.

  And a function in the release that the Objects table does not mention. That one found
  `lock_tree_lines()` on its first run: the shared renderer behind `lock_tree_text()` and
  `lock_tree_text_short()`, present since 0.5, in neither the Objects table nor the stability
  statement. It is now in both, with the signature `pg_get_functiondef` actually reports, which has
  no DEFAULTs on either parameter, unlike the impression its name gives.

NOT DONE, AND IT IS THE INTERESTING ONE

The review's third suggestion was that examples marked as generated should be REGENERATED by
`make demo` / `make scenarios` and COMPARED, so an example cannot drift from real output. That is
the only fix for (e) and (f) that holds, because both are hand-maintained text and a person will
introduce the next one. Everything here corrects two instances; nothing stops a third.

It is not done because it is a real piece of work rather than a check: the examples live in
README.md, `make demo` writes to the terminal, and comparing them means deciding which examples are
meant to be generated, capturing them somewhere, and diffing on every run. `scripts/lint-docs.sh` is the
right place for it and it is a couple of evenings.

Meanwhile (e) and (f) are the two a reader is most likely to be misled by, and both were internal
contradictions or impossible pairings rather than opinion, so they were worth fixing on their own
terms rather than waiting.

Docs only: no SQL, no test and no version change. 409 tests green on PG 14 to 19beta4 and 236 doc
checks, up from 226.

## 1.0.1 (2026-10-05)

1.0.1: the 1.0.0 redaction leaked, and any role could switch it off

A patch release, and all three defects are in the feature 1.0.0 existed to deliver. Nothing moves the
v1.0.0 tag.

Every finding below was reproduced by running the shipped 1.0.0 function and the shipped 1.0.0
privileges, on PostgreSQL 18, rather than by reading them.

H1. THE REDACTION MISSED A REAL SCRAM VERIFIER, AND FOUR PASSWORD SHAPES

A real verifier is

    SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>

and 1.0.0's character class could not get past the 4096:, so the pattern failed and a verifier passed
to a function was stored whole. Both keys intact, in a table anyone with SELECT could read. The
iteration count and the colon between the keys are both load-bearing and 1.0.0's own test fixture had
neither, which is how it survived.

Also stored verbatim, all valid SQL that PostgreSQL accepts:

| Shape | Why 1.0.0 missed it |
|---|---|
| `PASSWORD $$x$$` | The tag class required at least one character, and the empty tag is the commonest dollar quote |
| `PASSWORD 'a literal with a newline'` | Matched to the last quote on the first line, and there is none |
| `PASSWORD 'x` with no closing quote | `pg_stat_activity` cuts the text at `track_activity_query_size`, 1 kB by default. Same failure |
| `PASSWORD U&'x'`, `PASSWORD /*c*/ 'x'`, `PASSWORD'x'` | Only `E?'` straight after whitespace was expected |

1.0.0's release notes said the pattern "cannot under-redact". It could. **Corrected in place in the
1.0.0 entry below**, with the reason, because a changelog is a document a reader believes.

The 1.0.1 pattern replaces from the opening of the literal to the END of the text rather than to the
last quote on the line, because a truncated statement has no closing quote to find. The literal may
open with `'`, `E'`, `U&'` or `$`, and whitespace and comments are allowed between `PASSWORD` and it.

That over-redacts the tail: `PASSWORD 'p', VALID UNTIL '2026-01-01'` loses the VALID UNTIL clause
too. The clauses that can follow a password are VALID UNTIL and IN ROLE, neither of which is what an
incident is diagnosed from, so that is the right side to err on. It is asserted in test/21 so it
cannot later be mistaken for a bug.

Two additions over the review's fix, both because a plausible name is not evidence:
`SCRAM-SHA-256(?:-PLUS)?` for the channel-binding variant, and `i` on the SCRAM and md5 patterns, since
1.0.0 matched only one case of each.

H2. ROWS SAMPLED BEFORE 1.0.0 STILL HELD THEIR PASSWORDS

1.0.0 changed how new rows are written and left every existing row alone. An upgraded database still
held every password its history had ever caught, until pruning removed them. The exposure 1.0.0's notes
describe was still present after the release that claimed to fix it.

1.0.1's update script scrubs them, limited to rows that could match so it does not rewrite the table:

```sql
SELECT count(*) FROM lock_tree_history
 WHERE query ~* '(password|scram-sha-256\$|md5[0-9a-f]{32})';
```

Run that first if the history is large. The scrub is one UPDATE inside the update script, so it is one
transaction holding a lock on the table, and a sampler writing to it waits for the duration.

**A dump taken before 1.0.1, and every physical backup taken before 1.0.1, still contains whatever the
history held.** This release cannot reach into a backup already written.

H3. ANY ROLE COULD SWITCH REDACTION OFF AND READ OTHER SESSIONS' QUERY TEXT

`lock_tree_sample()` is `SECURITY DEFINER` and was executable by `PUBLIC`, and it reads
`lock_tree.history_query` from the **caller's** session. A role holding nothing but `SELECT` on the
history could therefore:

    SET lock_tree.history_query = 'full';
    SELECT lock_tree_sample();

and read another session's blocked statement back out of the table, password included, even though
`pg_stat_activity` showed that same text to it as `<insufficient privilege>`. Reproduced on PostgreSQL
18 with a role that has no `pg_read_all_stats` at all.

1.0.1 revokes `EXECUTE` from `PUBLIC` on `lock_tree_sample()`. That is a behaviour change for anyone
relying on the old grant, and it is the right trade: a `SECURITY DEFINER` function that reads every
session's query text should not be callable by every role that can connect. The grant is not restored
for anyone on upgrade, deliberately, because reinstating it silently would put the hole back for
exactly the roles that had it. INSTALL.md says what the scheduling role needs.

**And the fresh install was missed, which `scripts/check-upgrade.sh` caught.** The revoke went into the update
script and not the release file, so a new install kept the hole this release exists to close. The
upgrade comparison reported the difference as an ACL mismatch on one function, which is exactly what it
is for.

M1. TWO CLAIMS IN THE 1.0.0 TEXT WERE WRONG

  "It cannot under-redact." False, and the reason is H1. Corrected in place in the 1.0.0 entry.

  "Copied into every backup." True of physical backups only. `pg_extension.extconfig` is empty, so
  `pg_dump` does not include the history today. The corrected wording is in the 1.0.0 entry, and the
  point matters beyond the wording: **dump policy was never the control for this exposure.** A base
  backup, a snapshot and a replica copy the table whatever is registered. Redaction on the way in is
  the control, which is why H1 and H2 are the fix and the dump decision is not.

M2. TWO DEFECTS IN scripts/check-upgrade.sh

  `FROM="0.12 0.16"` failed with "no upgrade path drifted on column position, but
  KNOWN_POSITION_DRIFT names...". A partial run can legitimately include no path that predates the
  drift, and the staleness check then failed a run that was entirely correct. The check now runs only
  when `FROM` is unset, and says why when it is skipped.

  `position only:` printed the drift list one item per line, which reads as several findings rather
  than one line of detail.

M3. A BROKEN SPLICE IN INSTALL.md

The grants section read "…and the three formatting helpers. / what is important enough to page someone,
which is not a decision an arbitrary role should make. and become usable once the view is readable."
Half a sentence from one paragraph pasted over the start of the next. Repaired, and `lock_tree_sample()`
removed from the list of PUBLIC-executable functions so the two paragraphs no longer contradict.

THE PG_DUMP DECISION, MADE AND PINNED

Register none of the three tables, and say so. That is what ships today, so it costs no code:

| Table | Dump? | Why |
|---|---|---|
| `lock_tree_history` | No | Grows without bound and holds query text. A restore usually lands on a different server, where its pids and timestamps describe nothing. |
| `lock_tree_alert` | No | Hysteresis keyed to roots that existed on the source. Restored, it would suppress the first real alert on the target. |
| `lock_tree_deadlock` | No | A counter baseline. On the target `pg_stat_database.deadlocks` starts again, so the first sample would always record a `counter_reset`. |

Two pins: three assertions in test/02, and a section in INSTALL.md. Writing the pin nearly went wrong
in a way worth recording, because a review suggested

    SELECT ok((SELECT extconfig FROM pg_extension WHERE extname = 'pg_lock_tree') IS NULL, ...)

which is right, and a companion query against **`pg_extension_config_dump`**, which does not exist as a
relation. It is a FUNCTION that registers a table. A name that reads like a catalog table is not one,
and querying it fails with "relation does not exist".

## A stability statement, and a roadmap that is not stale

Both are new in this release, because 1.0.0 shipped a promise it never made explicit.

**Stability** ([docs/reference.md](docs/reference.md#stability-from-100)) names the functions whose names, arguments and
output column names and order are fixed, and lists what is not: the three formatting helpers, **table
column order**, what `lock_tree_redact()` removes, and `lock_tree_alert`'s columns. Two of those follow
from evidence rather than taste. Column order is not stable because `scripts/check-upgrade.sh` proved it
cannot be, and the statement says so rather than leaving a reader to assume otherwise. Redaction output
is not stable because a patch release widening it is a fix, not a break, and 1.0.1 is the example.

**Roadmap** ([docs/roadmap.md](docs/roadmap.md)) rewritten. The previous one was written at 0.12 and led with
work that shipped in 0.12, and had two items that had gone stale in opposite directions: a
partitioning note whose replacement shipped in 0.11, and a cross-database item written as though it
were next. The new one leads with the two things that are actually next, separates what is not planned
from what is merely unanswered, and records what is done so the section is a record rather than a wish
list.

## Three bugs in this project's own tooling, found while fixing the above

  `scripts/lint-docs.sh` found the newest release script with a pattern requiring EXACTLY two version
    components. The moment the version became 1.0.0 it matched nothing, `ls | grep` yielded an empty
    string, and the linter exited 2 saying a release script was missing, about a file that was sitting
    right there. A linter that goes blind on the project's own version numbering is worse than no
    linter, because every check before it passes first.

  The same linter counted assertions with `grep -c`, which counts LINES, and did not strip `--`
    comments, so a test file documenting its own shape by naming an assertion had that comment counted
    as one. Both were found the same way: a plan of 34 and a count of 33, where the server said 34 ran.
    The count is now of call occurrences with comments stripped, and when call sites still fall short
    of the plan it is a note rather than a failure, because an assertion inside a helper called
    several times legitimately emits more lines than it has call sites. More calls than the plan stays
    a failure: a plan is an upper bound.

  The suppression for detect-secrets took three attempts to place, and every wrong one is a trap worth
    naming. The token it matches is the literal `# pragma: allowlist-secret`. Written as
    `-- pragma:` it is a SQL comment the scanner does not recognise, and the finding stands. Appended
    to the end of the SQL statement BEFORE the semicolon, `#` is not a comment introducer in SQL, so
    psql parsed the pragma as the tail of the expression and the file ran 19 assertions instead of 34:
    a suppression for a scanner changed the code it was scanning. On its own comment line it is
    ignored, because detect-secrets 1.5.0 does not look back a line. What works is one long line
    ending in `;  -- # pragma: allowlist-secret`: a comment to psql, the pragma to the scanner, and
    neither able to affect the other.

  Three files named after test output reached 0.16 and 1.0.0, their filenames being the contents of a
    loop variable in an unquoted shell redirect. They were nearly missed because the first check for
    them used `git ls-files` inside a `find | while read` loop, and git consumed the loop's stdin, so
    the check reported three lines that looked like filenames and were not. .gitignore now excludes
    output-shaped names.

## The v1.0.0 TAG WAS RE-POINTED, AND CLONES THAT FETCHED IT STILL HAVE IT

`git push --tags` ran in the same command as a commit the pre-commit hook rejected, so for a few
minutes the remote `v1.0.0` pointed at 0.16's commit, which does not contain the redaction. A tag
claiming a security fix it did not contain. It was deleted and recreated, minutes old, and `main` was
left at the follow-up commit rather than the tag being moved onto it.

    v1.0.0 now points at badc4d7. The earlier tag pointed at fc92828.

**`git fetch` does not overwrite an existing tag.** If you fetched v1.0.0 while it was wrong:

    git fetch --tags --force origin

and check `git rev-parse v1.0.0^{commit}` gives `badc4d7`. The fix for the cause is in the review's
section 5 and is worth repeating: push a named tag only after checking it, and never chain a
`--tags` push after a commit in a line that does not stop on failure.

## What is not in this release

  A non-public schema install test. The last correctness gap from the 0.14 plan, and the one thing
    `lock_tree_sample()` and `lock_tree_redact()` both pinning `search_path = pg_catalog` makes
    worth having: an unqualified sibling reference is exactly what would break. One matrix case.

  The README split and the nine factual corrections. Untouched in this release, and the README still
    contains them, three of which were reproduced on PostgreSQL 16.

  Whole-window `lock_tree_duration()`. Still the slowest read in the extension, and now the first
    roadmap item, because 0.15 and 0.16 both left it there.

398 tests green on PG 14 to 19beta4, up from 361. All 17 upgrade paths to 1.0.1 match a fresh install,
with the one unfixable difference classified and checked in both directions. test/21 is proven
non-vacuous: 9 failures against the v1.0.0 tag, 34 of 34 here.

## 1.0.0 (2026-10-05)

1.0.0: credentials stop reaching the history, and upgrade paths stop being invisible

Nothing in this release changes a result you would query for. Two of the three things it does are
about things that were wrong in ways no test could see.

THE REDACTION, WHICH IS THE POINT

lock_tree_history keeps the first 300 characters of every blocked session's query. A blocked
`ALTER ROLE app PASSWORD 'hunter2'` is a blocked query. Up to 0.16 it sat in that table, in full,
until it aged out, readable by anyone with SELECT on the history, and copied into every backup of the
database. It is not a secret that leaked by accident; it is the server doing exactly what it was
asked, and storing the result.

lock_tree_sample() now runs the text through lock_tree_redact() first. Redaction happens BEFORE the
300 character truncation, so a password beginning before the cut is still caught rather than being
left as a prefix of itself.

  lock_tree.history_query    redacted   strip credentials            the default
                             none       store NULL
                             full       store the query verbatim

There is no C code in this extension, so the setting is a placeholder GUC with no declared default
and no SHOW ALL entry until something sets it, which is why lock_tree_sample() coalesces it and why
an unrecognised value redacts rather than leaking. Set it per session, or per database with
ALTER DATABASE mydb SET lock_tree.history_query = 'full'.

WHAT IS STRIPPED: the literal after PASSWORD in CREATE/ALTER ROLE, USER or GROUP in all three quoting
styles; SCRAM-SHA-256 verifiers; md5 hashes. Connection URLs carrying a password are deliberately NOT stripped, because
that is a real exposure and also a perfectly ordinary thing to have in an ad-hoc query, and guessing
at your data is not the right default.

Neither occurrence of that example is written out in full here or in the SQL. A documentation example
**CORRECTED IN 1.0.1: the claim below that this ends up "copied into every backup" is true of
PHYSICAL backups only.** `pg_extension.extconfig` is empty, so `pg_dump` does not include
`lock_tree_history` today, and the 1.0.1 changelog records the decision not to register it. A base
backup, a filesystem snapshot and a streaming replica copy the table whatever is registered, so dump
policy was never the control for this exposure; redaction on the way in is, which is why fixing it
was the work and the dump decision was not.

of the form it is easy to write, in a file this project scans for credentials, is a false positive on
every commit, and a suppression added for prose is a suppression that teaches the next reader that
suppressions are for prose.

THE COST, STATED PLAINLY: two statements differing only in a password now group as ONE row in
lock_tree_incidents() and lock_tree_history_statements(), where before they were two. That is
arguably the better answer, since the password is not what distinguishes the incident, but it is a
behaviour change.

Three of the ten redaction cases were real bugs in the first three versions of the regexes, and all
three were found by running them rather than by reading them:

  E'a\'b'        matched as E'a\' leaving a bare b' behind. Inside an E-string the escaped quote is
                 indistinguishable from a terminator to a regular expression. It now matches to the
                 last quote on the line, which over-redacts `PASSWORD 'p', VALID UNTIL '2026-01-01'`.
                 A cosmetic loss.

                 **CORRECTED IN 1.0.1: the sentence here used to end "and it cannot under-redact".
                 That was false.** A real SCRAM verifier, `SCRAM-SHA-256$4096:<salt>$<key>:<key>`, has
                 a colon after the iteration count that this pattern's character class could not get
                 past, and the fixture above had no iteration count, so the test could not have shown
                 it. Four more shapes leaked too. 1.0.1 closes all of them and the claim is left
                 standing as a correction rather than quietly edited out, because the reason it was
                 believed is worth seeing.
  SCRAM          the first pattern ran to the end of the statement and left the bracket dangling; the
                 second stopped after the salt and left the stored key exposed, which is half the
                 credential and still verifies a password attempt. Both segments go now.
  the md5 case   the FIXTURE had 31 hex digits, so the function was right and the test was wrong. A
                 redaction test that passes for the wrong reason is worse than none, and the only way
                 to tell was to count.

UPGRADE PATHS, AND scripts/check-upgrade.sh

Every upgrade path to 1.0.0 now ends in exactly the same objects as a fresh install, and that is
checked rather than asserted. The script was contributed with the review and earned its place
immediately: it found four differences on the first run, and THREE OF THE FOUR WERE THE FRESH INSTALL
BEING WRONG, which is the worse direction, since a fresh install is what most people have.

  lock_tree_history.query_id had no COMMENT ON COLUMN in any release file up to 0.16, though the 0.7
    update script set one. Every fresh install had an uncommented column; every upgraded database had
    a commented one.
  COMMENT ON TABLE lock_tree_history was a version behind on every path predating 0.12.
  lock_tree_summary() had lost three lines of explanatory comment, added in 0.8, on paths that did not
    go through 0.12.
  COMMENT ON FUNCTION lock_tree_notify_resolved() said "give both the same arguments" where the
    release file says "use the same arguments".

None of these is visible from inside one database. Comparing an upgraded install to a fresh one is
the only thing that sees them, which is the whole argument for the script.

The one difference that CANNOT be fixed is column position, and it is now a named, checked exception
rather than an unknown failure. ALTER TABLE ADD COLUMN appends, so root_object, added in 0.8, lands at
the end of lock_tree_alert and lock_tree_history on any database older than 0.8 and displaces what was
declared after it; in lock_tree_history the two late columns were also added in the opposite order to
the release file, so query_id and root_object are transposed as well. Rebuilding lock_tree_history to
reorder it would need twice the disk and hold ACCESS EXCLUSIVE for the length of the copy, which is a
worse outcome than a column order nobody relies on: the interface is the view, which names its
columns.

The exception list is checked in BOTH directions. A path drifting on a column not named in it fails,
and a run where no path drifts on the named ones also fails, because that means the source order
changed and the list has become a lie.

Two bugs in the script itself are worth recording, because both produced confident nonsense. The
position join was keyed on the table name alone, which cross-joins every column of a table against
every other column of it and reported sixteen columns as drifted, among them lock_tree.path, which is
a view column and cannot drift. And the span extractor for the update script did not know about
CREATE INDEX, so the span for lock_tree_redact ran past one and swallowed it, and every upgrade path
died with 'relation lock_tree_history_application_idx already exists'.

WHAT IS NOT IN THIS RELEASE

Four things from the review are not here, and none of them is because they were judged unimportant.

A pgTAP file pinning the redaction. The function itself is verified: ten cases by hand, run against
the real server, three of which found real bugs. The test file reached the point where seventeen
assertions passed and one statement still failed, and it was deleted rather than shipped in that
state. What it cost is worth recording, because every failure was the same trap seen four ways: a
psql \gset substitutes a value UNQUOTED, so a boolean arrives as a bare t, a "char" column arrives as a
bare i, and a function definition arrives as the bare words CREATE OR REPLACE FUNCTION, and SQL reads
each as a column name. The rule that survives all of them is that nothing but a number goes through
\gset. The file should be written that way from the first line.

The pg_dump decision. Extension tables are not dumped unless registered with
pg_extension_config_dump, and no decision has been made or tested here.

The README split into a short README plus docs/, and the nine factual corrections the review lists,
three of which were reproduced on PostgreSQL 16. The README is unchanged in this release and still
contains them.

A non-public schema install test, and the stability statement for the ~25 functions that 1.0 is
supposed to promise. Both are 1.0 business and neither is done.

361 tests green on PG 14 to 19beta4, unchanged in count. All 16 upgrade paths to 1.0.0 match a fresh
install, with the one unfixable difference classified and checked in both directions.

THE SETTING, OBSERVED IN ALL SIX STATES

  (unset)  ALTER ROLE app PASSWORD '<redacted>'
  full     ALTER ROLE app PASSWORD 'secret2'
  none     NULL
  typo     ALTER ROLE app PASSWORD '<redacted>'
  FULL     ALTER ROLE app PASSWORD '<redacted>'
  empty    ALTER ROLE app PASSWORD '<redacted>'

Three of those six are the interesting ones. 'typo' and 'FULL' both redact, so a misspelling and a
wrong case fail in the safe direction, and '' redacts rather than behaving as unset-and-therefore-
verbatim. That is the whole design of the setting: the only direction an unrecognised value is
allowed to fail in is the one that does not store the password.

Checked against the expression lifted out of lock_tree_sample()'s body rather than a reimplementation
of it, so if the function changes, this stops describing what the function does.

AND ONE LINTER BUG THIS FOUND

scripts/lint-docs.sh found the newest release script with the pattern
^pg_lock_tree--[0-9]+\.[0-9]+\.sql$, which requires EXACTLY two version components. The moment the
version became 1.0.0 it matched nothing, `ls | grep` yielded an empty string, and the linter exited 2
saying "no release script matching pg_lock_tree--X.Y.sql found" about a file that was sitting right
there. A linter that goes blind on the project's own version numbering is worse than no linter,
because the checks before it all pass first and the failure arrives as a missing file.

## 0.16 (2026-10-05)

0.16: an index by measurement, query_id on the live view, and the grants a monitoring role needs

Findings 3, 4 and 5 of the review that 0.15 answered part of. No behaviour change anywhere except the
two objects named below, and one column appended.

AN INDEX, CHOSEN BY MEASUREMENT RATHER THAN BY TASTE

Three candidates were tried against the same seven day 1.2 million row fixture, each on its own, whole
window lock_tree_duration() and lock_tree_duration_by_application() before and after:

    no extra index                                    2000 ms   2634 ms
    (application_name, sampled_at) WHERE depth = 0     1651 ms   2002 ms   1888 kB
    (sampled_at)            WHERE depth = 0            1750 ms   2214 ms   1344 kB
    (root_pid, sampled_at)  WHERE depth > 0            1701 ms   2501 ms   9744 kB

The first wins: 17% and 24% for 1.9 MB, which is 0.7% of the table. The last costs five times the
space for no gain on the application figure, which is how you can tell the root-to-waiter join was
never the expensive side. The second is smaller but dominated on both reads.

Partial rather than full, because the query that wants it filters on depth = 0, which is about one row
in twenty. A full index would carry twenty times the entries to serve the same twenty.

The write path was measured too, since this index is on the hot path and lock_tree_sample() inserts a
row per blocked session. One sample of 20 rows took 0.8 ms without the index and 0.7 ms with it, which
is noise: the partial predicate puts one index entry per sample in it rather than twenty.

WHY AN INDEX AT ALL, GIVEN 0.15. 0.15 turned the window bound into an Index Cond, which took the one
hour window to 12 ms and left the whole window read as the only slow path. This is what helps that one.
The remaining cost there is real work over 60,481 instants and 1.2 million rows, and no index removes
it.

query_id ON THE LIVE VIEW

Appending is the only change CREATE OR REPLACE VIEW permits to a view, which is exactly what this is.
Until now query_id was on lock_tree_replay() and not on lock_tree, so the tree in front of you could
not be joined to the history behind you on the one column both are keyed by. 0.14's changelog noted
the asymmetry rather than fixing it.

`NULL` on waiters, always, and that is not an omission: a query blocked on a lock has no query_id for
as long as it is blocked and only gains one when it completes. The root is the opposite. Same rule the
history follows, so the two line up.

Two things about implementing it that cost time. The act CTE has to PROJECT query_id as well as the
final SELECT selecting it, and forgetting that gives `ERROR: column a.query_id does not exist` with a
hint suggesting `a.query`, which is about as close to actively misleading as a helpful message gets.
And `pg_stat_activity.query_id` exists from PostgreSQL 14, which is this extension's floor, so there
is no version guard to write and therefore none.

THE GRANTS A MONITORING ROLE NEEDS, WHICH WERE INCOMPLETE

Found by setting up the documented grants and calling everything. The result was not what the
documentation implied:

  work with only SELECT on lock_tree
      lock_tree, lock_tree_text(), lock_tree_summary(), lock_tree_wide(), lock_tree_roots(),
      lock_tree_actions(), lock_tree_command(), lock_tree_replay_samples, lock_tree_deadlocks(),
      lock_tree_history_size(), lock_tree_notify()

  refused with "permission denied for table lock_tree_history"
      lock_tree_replay(), lock_tree_replay_text(), lock_tree_incidents(),
      lock_tree_sampling_advice(), lock_tree_duration(), lock_tree_duration_by_application(),
      lock_tree_history_statements()

INSTALL.md gave two grants and said that was it. It now gives the third, names all seven, and says
why the error names a table rather than a function.

The extension does not resolve this by making them SECURITY DEFINER, and should not. The history
holds the first 300 characters of blocked queries, which is application data, and a definer function
would hand it to every role with EXECUTE on it, which is PUBLIC by default. If that text is not
something the monitoring role may see, the answer is not to grant it and not to deny it, but to leave
lock_tree_sample() unscheduled so there is no history to read.

ONE INCONSISTENCY, STATED RATHER THAN FIXED

lock_tree_replay_samples is a VIEW over the same table, and a view runs with the DEFINDER's rights in
PostgreSQL, so a role with SELECT on the view reads the table underneath it with no grant at all.
That is a partial leak: it exposes the shape of each sample and the application names and query ids at
the head, but NOT the query text, which is the part worth protecting. It is not changed here because
`security_invoker` on a view needs PostgreSQL 15 and this extension supports 14.

It is now written down rather than left to be discovered by whoever calls it first.

WHAT IS NOT IN THIS RELEASE

A pgTAP file pinning the grant behaviour, which is where most of the effort went and where I stopped.
`test/20` grew to 300 lines and the dblink batching inside it took five attempts to get right, because
each attempt was a new way for the batches to be mismatched: a \gset label swapped, a loop lost, a role
that needed LOGIN, and DROP ROLE refused because a grant still pointed at it. Each failure was real and
each was mine.

Deleting it is the right call rather than shipping it half-working. The substance of finding 5 is the
documentation, which is correct and does not need a test to be true, and the privilege facts it rests
on were established by running them, which is recorded above and in INSTALL.md.

The test worth writing later is much smaller than the one I started: assert the privilege matrix with
has_table_privilege and has_function_privilege rather than executing seventeen statements through
dblink, and execute exactly one query as the role to prove the matrix means what it says.

test/18's set-difference assertion for the columns replay has that lock_tree does not now reads
`sampled_at` rather than `query_id, sampled_at`, which is the point of writing it as a set difference:
it is what noticed the asymmetry. A hardcoded list would have needed editing and might not have been
noticed at all.

Also fixed in the test runner used for these releases, which never reset its exit status between files,
so one failure reported every LATER file as failed too. The count was never wrong, only the list of
blame.

361 tests green on PG 14 to 19beta4, unchanged in count: this release adds objects and documentation
rather than assertions. demo, check-install, check-alert in both modes, and check-deadlock all pass.

## 0.15 (2026-10-05)

0.15: the read side stops reading the whole table

Two performance defects, one correctness defect the first of them exposed, and a benchmark so the
numbers can be re-checked instead of taken on trust.

THE DEFECTS

Fifteen window bounds on a stored column used clock_timestamp(). It is VOLATILE, and the planner
cannot make a volatile expression an index bound, so every one of them silently degraded from a seek
into a filter over the entire index:

    sampled_at >= clock_timestamp()     - interval '1 hour'
      Index Only Scan, Filter, 165740 rows removed,  18.5 ms
    sampled_at >= statement_timestamp() - interval '1 hour'
      Index Only Scan, Index Cond,                      0.777 ms

Same index, same query, same rows. The cost scaled with the size of the WHOLE history rather than
with the window asked for, which is the wrong way round for something a dashboard runs.

statement_timestamp() is STABLE, so it becomes an Index Cond, and it is constant for the statement,
so there is no consistency argument against it either.

Measured on a seven day history of 1.2 million rows, 264 MB:

                                    0.14        0.15
    lock_tree_duration(1ms)         980 ms      78 ms
    lock_tree_duration_by_app(1ms) 1001 ms      75 ms
    lock_tree_history_statements(1ms) 198 ms   0.3 ms
    lock_tree_replay(one sample)     987 ms     0.3 ms

The whole-window figures move much less, 3366 to 2606 ms for lock_tree_duration(), because a seven
day window legitimately touches 60,481 instants and 1.2 million rows. That work is real and no index
removes it. It is still the slowest read path in the extension and it remains the obvious next thing
to look at.

THE THREE clock_timestamp() USES IN THE LIVE VIEW ARE NOT CHANGED

They compute wait_age, xact_age and state_age, which are genuinely per-row instants of now.
Replacing those wholesale would be the obvious and wrong move, and test/19 asserts both halves: that
the pattern appears nowhere in any windowed function, and that it still appears exactly three times
in lock_tree with statement_timestamp() appearing nowhere in it.

lock_tree_replay() found its sample by computing the distance to every row and sorting. 987 ms to
replay one sample out of 1.2 million, against 0.556 ms for two index seeks: max(sampled_at) under the
target, then min(sampled_at) over it, then the nearer of the two. It had been written that way to
get around PostgreSQL refusing to let a SELECT DISTINCT order by an expression outside its select
list, and the way round that restriction was worse than the restriction.

THE CORRECTNESS FIX, WHICH THE ABOVE EXPOSED RATHER THAN CAUSED

lock_tree_duration() and lock_tree_duration_by_application() counted the ROOT among its own waiters,
so blocked_sessions_peak and sessions_total came out one too high per sample. A root row carries its
own pid in root_pid, so the root-to-waiter join matched every root to itself:

    a root with two waiters behind it reported blocked_sessions_peak = 3

Fixed by requiring w.depth > 0 in the join.

It survived two releases because test/17 computed its expected peak with the SAME self-matching
join, so the test agreed with the bug and passed. An expectation derived from the expression under
test is not an expectation. test/19's fixture is built from depth values directly, never from a join,
and it is what caught this on its first run.

FOUR BUGS IN THE UPDATE SCRIPT, NONE OF WHICH A GREEN TEST WOULD HAVE CAUGHT

The 0.14 to 0.15 update replaces nine objects. Getting that list right took four attempts, and every
mistake left the script looking complete:

  span extraction by SUBSTRING rather than by name. 'lock_tree_prune' is a substring of
    'lock_tree_prune_alerts' and 'lock_tree_replay' of 'lock_tree_replay_samples', so the script
    replaced prune_alerts twice and the samples VIEW, and applied NEITHER lock_tree_prune nor the
    replay rewrite.

  slicing the header on the substring 'CREATE OR REPLACE', which also occurs in the header's own
    prose. The comment was cut in half and the server refused with "unterminated /* comment".

  asserting the file ended in a semicolon, which it does not: a span runs to the next CREATE and
    so absorbs the prose comment block introducing that object. Valid SQL, and a wrong assertion.

  and then rebuilding the header from the already-truncated file, which cannot work.

What caught all four was comparing md5(pg_get_functiondef) for every function on an updated 0.14
against a fresh 0.15 install. Identical is the only acceptable answer, and it is now the check.
Install-from-tag would have passed regardless: a fresh install reads pg_lock_tree--0.15.sql and never
looks at the update path.

Also fixed there, and worth writing down: pg_proc holds AGGREGATES as well as functions, and
pg_get_functiondef raises '"array_agg" is an aggregate function' on one. Any query walking pg_proc
without filtering on prokind has to cope with that.

scripts/bench-history.sh

A number in a changelog is a claim nobody can check in eighteen months, so the claims above are now
measurable. It builds a fixture of a stated shape, times every read function, and checks the two
structural facts. It refuses to run without --force because it truncates the history, and says so on
every run rather than relying on you having read the header.

The structural checks were verified NON-VACUOUS: run against the v0.14 tag, both of the checks that
discriminate FAIL, with the old plans printed. One of the three passes on 0.14 as well and is labelled
as not being evidence. The first version of that check grepped for 'Aggregate|max(|min(', which
matches every plan in the extension.

The plan assertions are in the script rather than in a test file, and that is deliberate. The first
draft of test/19 asserted that five query plans used an Index Cond, and it failed CORRECTLY: on a six
hundred row fixture a sequential scan is cheaper and the planner is right to choose it. The
assertion was not detecting the bug, it was demanding a worse plan. Plan shape also depends on table
size and planner version, so it does not belong in a test that has to pass on six PostgreSQL
versions. test/19 asserts the SOURCE, which is deterministic, and test/19 needs no dblink at all.

test/19_index_usage.sql, 15 assertions.
361 tests green on PG 14 to 19beta4; the 0.14 to 0.15 update verified by catalog diff against a fresh
install; the full 0.2 to 0.15 chain; demo, check-install, check-alert in both modes, check-deadlock,
and bench-history on both 0.14 and 0.15.

## 0.14 (2026-10-05)

0.14: replay, so the history can be looked at rather than only queried

Everything in the extension until now answers questions about the present, or about totals over a
window. lock_tree_duration() can say which application cost the most and lock_tree_incidents() can
say when, but none of them can show the SHAPE of an incident that has ended: sixty sessions behind
one idle-in-transaction root at depth three, or five independent roots at once. That shape is what
you remember three days later and cannot get back, because it existed only as one row per session in
lock_tree_history with nothing to render it.

  lock_tree_replay_samples (view)   one row per sample: when, how wide, how deep, who was at the head
  lock_tree_replay(as_of)           the rows at the nearest past sample
  lock_tree_replay_text(as_of, w)   the same, indented, in the live renderer's layout

as_of IS A TARGET, NOT AN EXACT KEY

The sample nearest it is used, and sampled_at is the first column of every row, so what you actually
got is visible rather than assumed. Getting this wrong would silently replay a moment the reader did
not ask for. A target between two samples picks the closer one; NULL means the most recent. test/18
asserts the choice is the NEARER of two, because an assertion that only checks "one sample came
back" would pass if it always picked the latest.

NINE COLUMNS OF lock_tree ARE NOT HERE, and that is the honest part

  path, blocked_by   not reconstructible. The history stores one row per session, not the edge
                     between them, so nothing says which depth-1 session a depth-2 session was
                     actually behind. Anything derived from path goes with it.
  usename, datname, client_addr, wait_event_type, wait_event, xact_age, state_age
                    were never recorded. Adding them now would widen the history for every future
                    sample on every database, and would not retroactively supply the past.

test/18 asserts this list BY NAME against the live view rather than by count, because "which nine"
is the part a reader needs and a count would not say it. The comparison is derived from
pg_attribute for the view and from information_schema.parameters for the function.

TWO COLUMNS ARE NEW, AND ONE OF THEM IS NOT ABOUT REPLAY

sampled_at, so you can see which sample you got. And query_id, which lock_tree does not carry at
all. I wrote the assertion expecting one new column and it reported two, which is how I noticed that
the live view cannot be joined to the history on query_id even though the whole duration family is
keyed on it. Not fixed here: adding query_id to a view that reads pg_stat_activity would mean a
second source for it, and that belongs with whatever else the live view is missing.

WAITING_FOR READS BACK SCHEMA-QUALIFIED, AND THAT IS BETTER

  lock_tree.waiting_for           AccessShareLock on ledger
  lock_tree_history.waiting_for   AccessShareLock on public.ledger

Found by rendering a replay next to the live tree and noticing the difference. lock_tree_sample() is
SECURITY DEFINER SET search_path = pg_catalog, so inside it regclass cannot resolve a relation in
public and the name renders qualified. The live view is read with the caller's search_path, so it
renders unqualified, which is the path-dependent rendering this extension already documents as
cosmetic.

The history's rendering is the stable one: the same lock reads the same way in every row forever,
whatever the reader's search_path was. A replay that said "ledger" in one sample and "public.ledger"
in the next would be worse. Pinned by test/18, which asserts every history row matching a relation
name is qualified.

THE PARAMETER IS NAMED as_of, NOT at

PostgreSQL resolves a bare `at` against the function's own RETURNS TABLE row type rather than
against the argument, and the failure is "missing FROM-clause entry for table lock_tree_replay". A
parameter whose name is not one of the output columns has no such shadowing. as_of also says what
the argument is for.

The nearest-sample CTE also had to lose its DISTINCT: PostgreSQL will not let a SELECT DISTINCT
order by an expression that is not in its select list, and DISTINCT is unnecessary anyway. Ordering
by (distance, instant) and taking one row returns a single instant however many sessions it held.

FOUR MORE OF MY OWN TEST BUGS, ALL FOUND BY THIS FILE FAILING

  has_table on a view. It is a VIEW, so has_view.

  An array \gset variable interpolates as a bare {a,b}, which is not a SQL token, and a joined list
    as a bare "a, b, c". Both now go through quote_literal() in the query, which is the only place
    this can be fixed. And once they are quoted literals, is() still cannot compare them, because two
    untyped strings give "could not determine polymorphic type": both sides need ::text.

  Three boolean \gset variables. psql interpolates a boolean as a bare t, so ok(t::text = 't', ...)
    read that t as a COLUMN. Counted the exceptions instead.

  Timestamps interpolate raw too, so :picked::timestamptz became
    "2026-10-05 00:12:21.625699+00::timestamptz" and was a syntax error at "00".

  RETURNS SETOF text yields a scalar column whose name appears in the header but is not addressable,
    so t.lock_tree_replay_text does not resolve. A positional alias, AS t(line), does.

  information_schema reports a function as lock_tree_replay_33698, OID-disambiguated, not
    lock_tree_replay. Equality on the bare name returned nothing, so the column comparison was 18
    against 1 and reported every column missing. The regex ^lock_tree_replay_[0-9]+$ matches this
    function and not lock_tree_replay_text, which LIKE on the bare name would also have matched.

And one design point the samples view settled: applications in it is FILTERed to root rows, because
a waiter's application_name is not who was blocking anyone. test/18 asserts that separately from the
applications present in the whole replay, since the two are different questions.

test/18_replay.sql, 33 assertions.
347 tests green on PG 14 to 19beta4; all eight scenarios; the 0.13 -> 0.14 update and the full
0.2 -> 0.14 chain with the new test run against the walked-up database; demo, check-install,
check-alert in both modes, and check-deadlock.

## 0.13 (2026-10-05)

0.13: the aggregation a page actually needs

Three columns 0.12 could not get right, and the aggregation that answers the question a page asks.

### The bug: a root's identity and the waits it caused are on different rows

0.12's lock_tree_duration() reported three columns that could not be right. query_id is on the root
row. wait_age is on the waiter's. The 0.12 aggregates grouped by query_id and read wait_age off
those same rows, so:

| | 0.12 returned | why |
|---|---|---|
| longest_wait | always NULL | the rows carrying a query_id carry no wait on them |
| blocked_sessions_peak | always 1 | it counted ROOT rows per query per sample, and there is exactly one root row per query per sample |
| sessions_total | a second copy of samples | that same 1, summed over the instants |

Measured on a root blocking three sessions across three samples: 0.12 reported
blocked_sessions_peak = 1, sessions_total = 3, longest_wait = NULL.

One join fixes all three, the root rows of a sample matched to the waiter rows of the SAME sample on
root_pid and root_object. The object is part of the match for the same reason it is half of
lock_tree_alert's primary key: pid 0 is every prepared transaction at once, so matching on pid alone
would credit one prepared root's waiters to another.

Three columns, three column names, three documented meanings, all unchanged. They now return what
the documentation has always said they return.

### lock_tree_duration_by_application(since interval DEFAULT '7 days')

NOT lock_tree_duration() summed by application, and the difference is the whole point.

A batch job holding the queue for ten minutes will hand the queue from one statement to another
while it does it, because that is what a fixed script does. Say its statement 1 is the root at t0 and
its statement 2 is the root at t1:

    per query         both gaps DISCARDED: neither statement was the root at both ends
    per application   the gap COUNTS: the application was holding the queue at both ends

So summing the per-query figures reports the time an application spent blocking MINUS every
handover. Measured on a six-sample incident with one handover: the per-query sum was 4.028 seconds
where the application had actually held the queue for 15.368. A service that blocked forty sessions
for a quarter of an hour can be reported as having cost two seconds, and nobody notices, because the
number is small and plausible.

That is why the gap arithmetic is done again on (sampled_at, application_name) rather than
aggregating the per-query output. Everything else is identical, including the same conservatism: a
gap where the APPLICATION was not at the far end is discarded, and the interval after the last sample
is never counted.

An empty application_name is reported as its own row rather than filtered. A blocker that never
called SET application_name is one of the findings you are looking for, and dropping the row would
hide exactly the thing worth noticing.

### The two figures are not always ordered the same way

query_id identifies a STATEMENT, not who ran it, so two services running identical text share one
query_id. That inverts the comparison, and the README explains both directions:

  a handover between DIFFERENT statements inside one application: per-application is LARGER, because
    the per-query rule discarded the handover gap

  the SAME statement handed between two applications: per-query is LARGER, because the statement is
    identical on both sides so every gap has it at both ends, while the per-application rule discards
    that gap as attributable to neither service

Neither is wrong. test/17 pins both directions, because a test that only pinned the first would
have let the second look like a bug.

### WHY CREATE OR REPLACE AND NOT DROP

The signature and every column type are unchanged, so CREATE OR REPLACE FUNCTION is permitted: the
restriction is on changing a return type, not on changing a body. It also keeps the OID, which keeps
GRANT EXECUTE ON FUNCTION lock_tree_duration(interval). Verified: a role granted EXECUTE before
ALTER EXTENSION ... UPDATE still has it after. DROP and CREATE would have silently revoked an
operator's grant on a function that did not change shape, which is a worse failure than the bug being
fixed.

Nothing is dropped, no view is re-created and no rewrite lock is taken.

### check-alert.sh --explain now explains a cleared payload

0.12 added the resolution notice but left --explain reading it as an onset, which printed "Run these,
in this order" and pg_terminate_backend on a pid that had already gone. It now dispatches on the
event key and explains the two differently on purpose: an alerting payload is a question and the
output is what to run; a cleared payload is a statement about the past and the useful output is what
the incident WAS, plus five queries for looking it up.

The alerting branch is unchanged apart from one added line reporting the event, so a payload with no
event key at all (everything sent before 0.12) still explains as an onset, which is the only place
in the script where an absent key is read as a present one.

Two bugs in the generated SQL, found by executing it rather than reading it:

  json.dumps emits DOUBLE quotes, which PostgreSQL reads as an identifier, so every query it
    produced was a syntax error waiting to be pasted. Replaced with a sql_str helper that emits
    single quotes and doubles any inside. Verified by running all five generated statements.

  FROM lock_tree_incidents(), unnest(applications) AS u names the TABLE u, not a column u, so
    GROUP BY u failed. The column alias AS u(application) is what makes it a column.

### A test bug that was an arithmetic bug

The 0.12 test asserted sum(gaps) + sum(gaps_excluded) equals a hardcoded instant count. It passed,
for the wrong reason twice: gaps are counted PER QUERY, so a gap where two queries were both rooted
is counted once for each, and the constant happened to be the sum rather than the count. 0.13's test
computes the expectation from the samples instead.

Three more of my own, all found by this file failing:

  count(*) over the function's rows, where sum(gaps) was meant. One row per application, so it is
    always 1.

  Summing EVERY per-query figure and comparing it against ONE application. Different questions.
    Now joined through query_ids so both sides are the same statements.

  A fixture where both applications ran the identical LOCK TABLE app_t2, so they shared a query_id
    and lock_tree_duration() correctly merged them. The fixture now uses three tables, and the shared
    query_id case is pinned deliberately rather than avoided.

And one design point the second of those taught me: a gap is keyed on the application being rooted
at its NEAR end, so a single isolated sample is not a blocker by this measure at all. Two instants
are needed before a root appears. Same rule that discards the trailing interval everywhere else.

### Also

- test/17_duration_by_application.sql, 22 assertions.
- 314 tests total, green on PG 14, 15, 16, 17, 18 and 19beta4.
- scripts/lint-docs.sh needed no change: it already recognised FUNCTION.

## 0.12 (2026-10-05)

Two additions, both about the same thing: turning what the extension already records into something
an operator can act on. A real blocking-time figure instead of a sample count, and a way to find
out that an incident is over.

### `lock_tree_duration(since interval DEFAULT '7 days')`

`lock_tree_history_statements()` reports **session-samples**: one unit per blocked session per
sample. That is a count of observations, and the 0.7 documentation says so plainly. It is not a
duration, and there is a case where being precise about that matters.

The same six-second incident, sampled twice:

| | session-samples | gap-summed time |
|---|---|---|
| 3 samples over 6s | 3 | 00:00:06 |
| plus 6 more over the next 6s | 9 | 00:00:06 |

One figure tracked elapsed time. The other tracked how often anybody looked. So ranking statements
by it means ranking them partly by your cron entry, which is a thing you would have to notice and
then explain to someone.

`lock_tree_duration()` sums the **gaps between sample instants**. While a query was the root at both
`t0` and `t1`, it was the root for the whole of `t0` to `t1`, and both of those are instants at which
it demonstrably held the queue up. That is a measurement rather than an interpolation, which is the
property the sample-count version lacks.

Deliberate choices, all visible in the output:

- **A gap counts only where the query was the root at both ends.** A gap whose far end has a
  different root is discarded rather than apportioned. Nobody observed when the handover happened,
  so any split of it would be invented. `gaps` and `gaps_excluded` report both counts.
- **The interval after the last sample is never counted.** A chain still standing when the sampler
  last ran contributed time nobody measured. This is a lower bound on the truth and it says so,
  rather than presenting a figure whose provenance is unclear.
- **`blocking_seconds` is `numeric`, not `interval`.** A duration in seconds is what a reader
  compares across queries and against a budget, and a fractional second survives.
- **`applications` is an array, not a name.** One query id can be seen under more than one
  application across a week.

`lock_tree_history_statements()` is unchanged and still there. It is the cheaper question, it needs
no gap arithmetic, and for "which query blocks the most sessions" it is the right answer. Both are
worth having; they are not substitutes.

### A hazard, measured rather than only described

While working this out I found that samples inside a single statement are invisible as elapsed time.
`sampled_at` is `statement_timestamp()`, fixed for the duration of a statement, so:

```sql
DO $$ BEGIN FOR i IN 1..4 LOOP PERFORM lock_tree_sample(); PERFORM pg_sleep(1); END LOOP; END $$;
```

writes four samples' worth of rows and records **one** instant. Four seconds of incident, not
traceable. This is not new behaviour: 0.4 fixed a related bug where `clock_timestamp()` capped
`peak_sessions` at 1, and `statement_timestamp()` was the fix. That fix is what a cron entry
depends on and what a `DO` loop defeats.

The rows look healthy unless you count instants rather than rows, so the README now shows both
forms and `test/16_duration_resolved.sql` pins it with the measurement: a `DO` block writes rows,
adds fewer than four instants, and `lock_tree_duration()` does not absorb the loop. The safety
property that matters is that four rows in one instant produce no gap and therefore no invented
duration.

### `lock_tree_notify_resolved(channel, min_blocked, min_depth, min_wait)`

`lock_tree_notify()` says when something starts getting worse and then says nothing. That was
deliberate in 0.6 and it is right for a pager. It is wrong for the person who was woken up at 03:00
and now has no way to find out whether to go back to bed.

This raises one notification per root that **had alerted** and has since left the tree, with `event`
set to `"cleared"` in place of `"alerting"`, then forgets the stored state so the next incident
alerts from the start rather than escalating against a high-water mark from a previous one.

- **A root that never alerted produces nothing.** A resolution notice with no matching alert is
  noise. The function reads the rows it is about to delete, so it cannot report one it did not send.
- **It keys on the same state and the same policy string as `lock_tree_notify()`.** Pass both
  functions the same thresholds or this will resolve alerts that were never sent, which is the one
  way to make it actively misleading.
- **A separate function, not a parameter.** An `alerting`/`cleared` pair on one channel is what a
  consumer wants, but whether an incident ending is worth a message is a property of your rota
  rather than of this extension, and someone who never wants it should not be able to switch it on
  by accident through named notation.
- **Backwards compatible.** A consumer written against 0.6 that ignores unknown fields is
  unaffected.

### One payload change to `lock_tree_notify()`

The onset payload gains one key, `event`, set to `"alerting"`.

It had none before, which was fine until there were two kinds of notification on the same channel
and a consumer had to tell them apart. The alternative was inferring an onset from the **absence** of
a key, which is the sort of contract that breaks silently. It was found by the first run of the
updated [`scripts/check-alert.sh`](scripts/check-alert.sh), which asserted the first payload
said
`"alerting"` and was wrong, because nothing had ever put it there.

The one behaviour change in 0.12. It is additive and safe: JSON consumers read by key, every
documented key keeps its meaning, and a listener that ignores fields it does not recognise is
unaffected. It arrives as `CREATE OR REPLACE FUNCTION`, which is permitted because the restriction
is on changing a return type rather than on changing a body, and this function has no `OUT` list.
In place it takes a lock on one catalog row and nothing else: no table, no view, and none of the
alert state, which is data.

### [`scripts/check-alert.sh`](scripts/check-alert.sh), restructured

Proving the resolution notices meant proving that a `cleared` payload really arrives, and adding
that turned up two things in the existing script.

**The silence check was passing for the wrong reason.** It built the chain in one `psql`
invocation and checked for silence in a later one. A `psql` session that exits takes its dblink
backends with it, so by the time the later invocation ran, the chain was gone,
`lock_tree_notify()`'s own sweep had already deleted the stored alert row, and "0 returned" was
being read from a tree with nothing in it. That also left nothing for
`lock_tree_notify_resolved()` to resolve, which is how a run reported zero cleared roots next to an
assertion demanding one.

**The listener slept through its own notifications.** `NOTIFY` is only delivered at a command
boundary, so the listener's single `pg_sleep(8)` held everything until it returned. That happened to
be long enough for the run and short enough to notice, and would have broken the moment the run got
slower. It now issues one statement per second through `\gexec`.

Both are fixed: one listener, and one session that holds the chain for the whole sequence. The
payload stream is asserted as a sequence, so exactly two payloads arriving, `alerting` then
`cleared`, is itself the silence check seen from the other end. A function that returned 0 while
still sending something is now caught.

Also fixed along the way: teardown disconnects the dblink connections rather than terminating them.
Terminating first kills the backend, and `dblink_disconnect` on a connection whose backend has gone
fails with `connection "ah" not available`, which aborted the script outright.

### `scripts/check-deadlock.sh --deadlock-timeout=INTERVAL`

The increment in `pg_stat_database.deadlocks` lands when the server breaks the cycle, which is
`deadlock_timeout` after the wait began. `scenarios/s6_deadlock.sql` raises it to 15s so the cycle
survives to be photographed, which put the counter and the cycle in two different places. Now the
parameter that separates them is a parameter, so the script proves both halves in one run:

```
$ scripts/check-deadlock.sh --deadlock-timeout=15s
  counter before the deadlock: 0
  deadlock_timeout for the two victim sessions: 15s, wait budget 45s
  both sessions are blocked on each other: that is a real cycle
  the cycle is visible in pg_stat_activity and the counter is still 0
  the counter moved, from 0 to 1
```

The middle line is the useful one. It is the state `s6` photographs, and it is the answer to the
question that sends people to the source: *I can see a deadlock but `deadlocks` has not moved, is
something broken?* Nothing is broken. It moves at `deadlock_timeout` and not before. Omit the
parameter to use the server's default (1s), or pass `2s` to break it promptly. The setting is
applied to the two victim sessions only; `postgresql.conf` is not touched.

### Also

- `test/16_duration_resolved.sql`, 19 assertions.
- 292 tests total, green on PG 14, 15, 16, 17, 18 and 19beta4.
- `scripts/lint-docs.sh` gains checks for both objects. It needed no change to its own matching:
  it already recognised `FUNCTION`, and [`scripts/check-deadlock.sh`](scripts/check-deadlock.sh) already parsed.

Nothing is removed or renamed. Both objects are new, so the update from 0.11 adds nothing and takes
no rewrite lock: `pg_lock_tree--0.11--0.12.sql` is `CREATE FUNCTION` twice.

## 0.11 (2026-10-11)

The two things that were wanted when partitioning `lock_tree_history` was proposed, because
partitioning turned out not to be available.

### Why it is not available, measured rather than assumed

PostgreSQL has no `ALTER TABLE ... SET PARTITIONED BY`. Converting a table means creating a new
partitioned table, copying the rows, and swapping. The swap cannot be done from outside the
extension, because the table is a member:

```
DROP TABLE lock_tree_history
ERROR:  cannot drop table lock_tree_history because extension pg_lock_tree requires it
```

The same restriction that applies to the view. The only place `DROP TABLE` is permitted is **inside
an extension update script**, so the copy would happen unattended during
`ALTER EXTENSION ... UPDATE`, on however many rows the user happens to have, holding whatever locks
that takes, with no way to stop it half way. That is not a change to make on someone's behalf in a
script they did not write, so it is not offered. The README says what to do instead.

### What replaces it

The problem partitioning was meant to solve is real: `lock_tree_prune()` is one `DELETE`, which on a
large table takes a long time, holds its locks for all of it, and leaves the free space behind for
`VACUUM` to find.

**`lock_tree_history_size()`** answers the question partitioning was proposed to answer, without it.
"Is this table going to fill the disk" is a question about a rate, and a rate needs two samples and
the interval between them. It reports rows, samples, `pg_total_relation_size`, the oldest and newest
sample, the observed interval, bytes per day, and `days_to_1gb`, which is the number to alert on.

Three details it does not get wrong:

`pg_total_relation_size` rather than a hand-rolled sum of `pg_relation_size`, because the sum misses
TOAST and the free space map, and the total is what the disk is charged.

The observed interval is `(span) / (gaps)`, not the average of the intervals. Averaging weights a
long gap the same as a short one; dividing the span is the thing that actually has to be divided.

An unsampled database gets `NULL` for every rate column, not a large number invented from no data.
The test asserts all three.

**`lock_tree_prune_batched()`** is a **procedure**, and that is the entire reason it works: only a
procedure can `COMMIT`, and a batched prune that cannot commit between batches still holds
everything. Rows are selected by primary key rather than by `OFFSET`, because `OFFSET` is
`O(rows skipped)` and the tenth batch would walk past everything already deleted.

```sql
CALL lock_tree_prune_batched(interval '7 days', 20000);   -- fine
BEGIN; CALL lock_tree_prune_batched(interval '7 days'); END;   -- ERROR
```

It checks for a transaction block **before deleting anything**, so wrapped in one it fails having
removed nothing, rather than part way through with half the table gone. That ordering is the useful
part; the error PostgreSQL raises is `invalid transaction termination`, which does not say why, so
the `COMMENT ON` and the README both explain it.

`lock_tree_prune()` is unchanged and still there. A batched prune you cannot interrupt is worse than
an unbatched one in some situations, so the procedure is opt-in.

### Two things that could not be done the obvious way

**Checking for a transaction block cannot be wrapped in an exception handler.** The first version
raised `COMMIT` inside a plpgsql block with an `EXCEPTION` clause, to turn the failure into a
readable message. A block with an `EXCEPTION` clause runs in a **subtransaction**, and `COMMIT` is
never permitted in one, so the check failed every time rather than only inside a transaction block.
It refused to work outside a transaction block too. The check is a plain `COMMIT` now, and the error
is explained in prose rather than caught.

**`throws_ok` inside pgTAP reports `0A000`, not `2D000`.** `throws_ok` runs the statement in a
subtransaction, and there the refusal is "EXECUTE of transaction commands is not implemented".
Called inside a real `BEGIN` block at the top level it is `2D000` "invalid transaction
termination". Same refusal, different wording, because a subtransaction and a transaction block are
different things to PostgreSQL. The test asserts the one it actually observes and says why.

### A test bug that was an arithmetic bug

`test/15_history_size.sql` asserts nothing was deleted when the `CALL` is refused. The first version
compared against a hardcoded row count, and was wrong twice: once by forgetting the 60 rows left by
the fixture above it, and once by forgetting a row the setup had already used. The assertions are
now relative to the table at the moment of the check, which is the thing this file is about, so the
test should measure it the same way.

A stray `BEGIN;` with no `COMMIT` in the middle of the file put the whole rest of the psql script
into a transaction block, and the later `CALL` then failed with "invalid transaction termination" for
a reason that had nothing to do with what was being tested. `throws_ok` runs the statement inside its
own subtransaction, which is the right way to check it.

Verified: 273 tests green on PG 14, 15, 16, 17, 18 and 19beta4; all eight scenarios; the 0.10 ->
0.11 upgrade against a populated history and the full `0.2--0.11` chain; the batched prune removing
rows in 6 batches of 7 out of 40 aged rows; demo, check-install, check-alert and check-deadlock.

## 0.10 (2026-10-04)

## 0.10 (2026-10-04)

Deadlocks, and an extension that finally reads its own history.

Two features. One table, one function and one column added; one function's return value gains a side
effect and one function's signature changes. Nothing existing is rewritten and no rewrite lock is
taken.

### Deadlocks: when, and not what

The extension could watch a deadlock happen and had nothing to say about it afterwards.

`pg_stat_database.deadlocks` has been there since PostgreSQL 13, so it is available on every version
supported here. Checked rather than assumed, since the version it was added is the sort of thing
worth being wrong about and the alternative is a function that fails at `CREATE EXTENSION` time on
the oldest version in the matrix.

`lock_tree_sample()` records the counter. `lock_tree_deadlocks()` reports when it moved: the
cumulative value, how far it moved, and the window total.

**It does not name the two statements, and nothing in SQL does.** The participants exist only in the
server log. What this gives is the timestamp, and that is the half that makes the log worth reading:
three deadlocks between 09:00 and 09:15 on a Monday is a deploy or a cron job, not a mystery. The
README has the `log_lock_waits` recipe and says plainly what the counter cannot do.

### Why the counter is sampled into its own table

This is the part worth understanding, and it is not tidiness.

`lock_tree_history` only has rows while something is **blocked**, and PostgreSQL resolves a deadlock
by killing one participant. So by the time the sampler runs, the cycle is over, the tree is empty, and
there is no history row to hang a counter on. Measured:

```
 the counter moved, from 15 to 16
 and nothing is blocked now, so lock_tree_history would record nothing at all
 a sample wrote no history rows, because the tree is empty
 and lock_tree_deadlocks() reports the move: delta = 1
```

A deadlock you did not happen to be looking at is exactly the one worth catching, and putting the
counter on `lock_tree_history` would miss all of them. `lock_tree_deadlock` is therefore one row per
sample, written whether or not anything is blocked.

### Counter resets

The counter can go **backwards**: `pg_stat_reset_shared('db')` sets it to zero. A naive delta is then
negative, which is not a number of anything. So `delta` is floored at zero, `counter_reset` records
that the baseline changed, and `total_in_window` sums only the deltas **after** any reset, so a reset
cannot quietly understate the window.

### Sampling advice now reads the history

`lock_tree_sampling_advice()` sized the interval from the queue at the instant it was called. A cron
entry at 3am on a quiet Sunday therefore recommended the finest interval, for a database that spends
every weekday morning with four hundred sessions waiting. The advice was not wrong about the
instant. It was answering the wrong question: the question is what the table has to carry, and the
table's size is set by the peaks.

It now takes a window, reads the peak out of the history, and uses the **greater** of that and the
live queue, so a queue that started after the last sample is not ignored. Both inputs come back as
columns (`observed_peak`, `live_blocked`) so the advice can be traced back to what it was based on.

The column is `look_back`, not `window`, because `WINDOW` is a reserved word and a column with that
name has to be quoted at every use and in every example that reads it.

### `lock_tree_prune()` clears both tables, and counts only one

It now deletes from `lock_tree_deadlock` as well. Its return value still counts **only** the history
rows, because it has returned a history count since 0.4 and every existing caller reads that number.
At a five second sample interval, counting the deadlock rows too would inflate it by a factor of the
sample rate, and a monitoring job that has been right for six releases should not start reporting
four orders of magnitude more than the table it watches. One call to remember rather than two is
worth the asymmetry. The deadlock rows are still deleted, and the decision is stated in the function
body as well as here.

### Where the end-to-end deadlock test lives, and why not in the suite

`scripts/check-deadlock.sh`, not a test file.

The increment lands when the server breaks the cycle, which is `deadlock_timeout` after the wait
began. Three separate attempts to observe that inside a single psql session all failed, each
differently and each instructive:

1. The deadlock was built from dblink connections belonging to the session that was also sampling.
   The two interfered and the deadlock was never observed at all.
2. Waiting on the counter is circular. The counter only moves once the server has acted, and it acts
   on a timer, so a bounded loop never sees the move and reports that nothing happened.
3. Waiting for the **cycle** first and then for the counter works, but only when the sample is a
   separate process.

`scenarios/s6_deadlock.sql` builds a real deadlock too, and it shows the counter being sampled. But it
raises `deadlock_timeout` to 15s so the cycle survives long enough to be photographed, which means the
increment lands long after that scenario has moved on. So the two live in different places, and the
scenario says so rather than showing an empty table and leaving the reader to guess.

`test/14_deadlocks.sql` covers everything that can be covered deterministically: that a sample on a
quiet tree still records the counter, that a delta is a subtraction and never negative, that a reset
is reported as a reset, and the history-derived advice.

### A fixture bug worth writing down twice

The advice fixture builds a history that peaked at 450 sessions, and the first version of it used
`clock_timestamp()` in the `INSERT ... SELECT`. That is volatile and evaluated **per row**, so all
450 rows got a `sampled_at` a few microseconds apart. The advice groups the history by `sampled_at` to
find the widest sample, and 450 groups of one session has a peak of 1. The fixture described a
database with no queue at all and the test failed for a reason that had nothing to do with the code.

This is the same trap that made `lock_tree_sample()` record a different `sampled_at` per row in 0.4,
which silently capped `peak_sessions` at 1. It is recorded here a second time because it looks like a
harmless choice of clock function and it is not: **any per-row timestamp in this table destroys the
only thing the history is for.**

### Also

- `pg_lock_tree--0.9--0.10.sql` drops and recreates `lock_tree_sampling_advice()`, because
  `CREATE OR REPLACE FUNCTION` refuses a changed OUT list and it returns a table.
- `.forgejo/workflows/test.yml` loads `pg_lock_tree--0.10.sql`.

Verified: 250 tests green on PG 14, 15, 16, 17, 18 and 19beta4; all eight scenarios; the 0.9 -> 0.10
upgrade against a populated history and the full `0.2--0.10` chain; [`scripts/check-deadlock.sh`](scripts/check-deadlock.sh) observing a
real deadlock move the counter with nothing blocked at the sample; demo and check-install.

## 0.9 (2026-10-04)

## 0.9 (2026-10-04)

Alerting learns to escalate on age, and a payload learns to explain itself.

Two changes, both in the alerting added in 0.6 and 0.7. No signature changes anywhere, so nothing is
dropped and the update path is one `ALTER TABLE` plus two `CREATE OR REPLACE FUNCTION`.

### Escalation watched width and depth but not age

Through 0.8 `lock_tree_notify()` escalated on two things: a root blocking more sessions than it
ever had, and a root deeper than it ever had. It did not escalate on **how long anyone had been
waiting**. So a chain that sat at forty blocked sessions while the longest wait went from five
minutes to thirty never notified again.

That is not an edge case, it is the ordinary shape of an incident that is getting worse. Nothing
about it is sudden, so nothing triggers an edge-triggered rule.

### Why the wait escalates by doubling and not by growing

A wait is not an edge, it is a slope. It grows every second, so the obvious comparison, "is the
longest wait longer than it was last time?", is **true on every sample**, and the function would
notify sixty times an hour. That is the exact noise `lock_tree_alert` was introduced to prevent,
reached by a different route.

So the comparison is against **the wait recorded at the last notification**, and fires only once
that wait has doubled:

```
 30s    1m    2m    4m    8m    16m   32m
  |     |     |     |     |      |      |
  +-----+-----+-----+-----+------+------+
```

Seven notifications for a thirty-two minute incident, each saying it is roughly twice as bad as
the last. Seven is deliberate: few enough that nobody learns to filter the channel, many enough
that a thirty-minute queue does not sit at the same reported severity for half an hour. It is the
same reasoning as exponential backoff, applied to whether to wake someone.

**It only applies when `min_wait` is set.** An operator who passes `min_wait => NULL` has said they
do not want to be paged on wait age, and that is honoured even when the wait is enormous. A second
page about a slow queue you did not ask about is how a channel stops being read.

### The bug the test found, twice

**Doubling zero is zero.** `max_waited_at` starts at zero, so `longest_wait >= max_waited_at * 2`
is `longest_wait >= 0`, which is always true. The first measurement of this feature notified on
every single sample: the precise failure mode it was written to prevent. The fix is
`greatest(max_waited_at * 2, min_wait)`, so with nothing recorded the first escalation is the
operator's own threshold.

**`greatest()` ignores NULLs.** PostgreSQL's `greatest` returns the largest *non-null* argument
rather than propagating NULL, so `greatest(longest_wait, want_wait)` with `want_wait` NULL
returned the wait: with `min_wait` switched off, the row quietly recorded a wait for a criterion
that did not exist. It needs a `CASE`, not a NULL-tolerant aggregate. The assertion that found it
was "with `min_wait` off, nothing is recorded", which is the sort of test that looks pedantic until
it is the one that matters.

### [`--explain`](scripts/check-alert.sh), and why it needs no database

An alert arrives as a JSON payload with no instructions attached. The recipient has to know what it
means and what to run, at whatever hour it arrived.

```bash
scripts/check-alert.sh --explain '{"root_pid":0,"root_object":"AccessExclusiveLock on public.ledger", …}'
```

prints what the payload says, what it means, and the queries to run in order. It **needs no database
and no superuser**, which is the point: the first thing you do at 3am should not be something that
can fail because the database is the thing that is broken. `make explain-alert PAYLOAD='…'` is the
same thing.

It branches on `root_pid` rather than on the message text. A session root gets
`pg_terminate_backend` steps; a prepared root gets `ROLLBACK PREPARED` steps and an explicit
statement that `pg_cancel_backend(0)` returns false and warns that pid 0 is not a backend. That
branch is worth being careful about, because the two failures look identical on a dashboard and
need opposite remedies.

It also refuses to guess. A payload that is not JSON is reported as not JSON. JSON without a
`root_pid` is reported as probably not from this extension, which is the right answer for a
listener serving several kinds of message on one channel.

### Tests

`test/11_alert.sql` grows from 30 assertions to 48. The new phase builds a chain that **never gets
wider or deeper** and only ages, which is the isolation that makes the result mean something: with
a queue that is also growing, any notification could have come from any of the three rules. It
asserts onset once, silence, one notification at the doubling, silence again, that the two
high-water marks did not move, and that `min_wait => NULL` suppresses age escalation for as long as
you care to wait.

Two earlier assertions had to be re-scoped rather than fixed: `lock_tree_notify()` sweeps only the
policy it was called with, which is deliberate, so the alert table still holds the default-policy
rows from earlier phases. They now scope by root.

Verified: 221 tests green on PG 14, 15, 16, 17, 18 and 19beta4; [`scripts/check-alert.sh`](scripts/check-alert.sh) in both modes and
`--explain` against a session payload, a prepared payload, non-JSON, and JSON from elsewhere;
demo, scenarios and check-install.

## 0.8 (2026-10-04)

## 0.8 (2026-10-04)

Two bug fixes, no features. Both were found while measuring something else, and one of them is in
the view rather than in anything built on top of it.

### Two prepared transactions were one root

`pg_blocking_pids()` reports the blocker as `0` for every prepared transaction, because a prepared
transaction has no backend. So every prepared root had `root_pid` 0, and every place that grouped
on the pid merged them:

```
 0.7                                     0.8
 root_pid | blocked_sessions             root_pid | root_object                | blocked_sessions
        0 |                  4                   0 | AccessExclusiveLock on ledger  |                2
                                    versus         0 | AccessExclusiveLock on orders  |                2
```

Measured on PG 18 with three prepared transactions and four waiters. The left column is what 0.7
reported: **one root claiming four blocked sessions, held by nothing that exists**. `roots` was 1.
The right side is three roots with their own blast radii.

That is the number an operator acts on, and it was wrong in the one case this extension exists to
be better than the published recursive CTE at, since that CTE reports a prepared transaction as
nothing at all. Being right about a case rather than merely covering it is the whole argument, so
getting it right matters more than the count of features shipped.

**The fix is a new column, `root_object`.** It is what a prepared-transaction root is holding, and
it is `NULL` for a session root because `root_pid` already identifies that one. `root_pid` plus
`root_object` is the root's identity everywhere it matters: the view's walk, `lock_tree_roots()`,
`lock_tree_wide()`, `lock_tree_statements()`, `lock_tree_history`, and `lock_tree_alert`'s primary
key. On the functions it sits immediately after `root_pid` rather than at the end, because the two
are one identity and separating them by eight columns is how a reader ends up believing the pid is
enough.

The column is **always schema-qualified**, which is longer than necessary and deliberate.
`relation::regclass::text` qualifies only when the schema is not in the `search_path`, so the same
lock renders as `z1` in one session and `public.z1` in another. Measured: through the view it was
`z1`, and through `lock_tree_sample()`, which is `SECURITY DEFINER` and so runs with the owner's
`search_path`, it was `public.z1`. A value in a primary key cannot change with the `search_path`,
or an alert fires again for an incident it already reported. `waiting_for` still uses `regclass` and
is still path dependent, which is cosmetic there because nothing keys on it.

**Where the bug actually was, which is not where it looked.** The walk and the aggregates were
correct as written. The merge was in one line of `placed`, which used `SELECT DISTINCT ON (pid)`.
Both prepared roots have `pid` 0, so `DISTINCT ON (pid)` collapsed whichever sorted first, and the
survivor's identity was then used for the whole chain. It is now a `row_number()` partition with
pid 0 exempted, since pid 0 is a placeholder rather than a session.

Also worth stating plainly: **two prepared transactions holding compatible locks on the same
relation are still one root.** PostgreSQL cannot tell them apart either, `pg_blocking_pids()` gives
one `0` for both, so attributing a waiter to one of them would be a guess. Grouping by the object
rather than by the mode is the honest boundary.

### lock_tree_statements() could return two rows for one root

`pg_stat_statements` is not unique on `queryid` in practice. Measured on PG 18: a statement that
had run six times sat in **two** rows, with `calls` of 1 and 5, and the row-for-row join produced
two output rows for one root. Since the function is documented as one row per root, and its purpose
is grouping incidents by statement, a duplicate row is a duplicate incident.

It now aggregates that side in a `LATERAL` subquery: `sum(calls)`, `sum(total_exec_time)`, and the
mean recomputed from the sum rather than an unweighted average of means, which is wrong whenever
the buckets have different call counts, which is the entire reason they are separate.

This one was found because a container's `pg_stat_statements` had accumulated duplicate buckets.
It would have been found by a user sooner or later, and on a real system rather than a test one.

### Tests

`test/13_prepared_roots.sql`, 22 assertions: three prepared transactions, three roots, each waiter
under the root for the object it actually wants, `lock_tree_summary()` counting three where 0.7
counted one, `lock_tree_wide()` reporting one blocked session per root where 0.7 reported the
merged figure, history recording the objects, and alerting firing once per root and then staying
silent. Separate from `test/04_prepared.sql` rather than folded into it, because one prepared
transaction has always worked and the two case is a different failure.

`scenarios/s7_prepared.sql` now builds two more prepared transactions on fresh tables and
deliberately does **not** roll back the first, so all three are prepared at once. It prints the 0.7
figure computed from the same incident rather than quoted from memory.

### Three mechanical facts, all measured rather than assumed

`CREATE OR REPLACE VIEW` **can** append columns, but not drop or reorder them. That is why
`root_object` goes last on the view and second on every function. The view's seventeen existing
columns keep their names, types and positions.

`CREATE OR REPLACE FUNCTION` **cannot** change an OUT list at all: `cannot change return type of
existing function`. So the four functions that gained a column are dropped and recreated.
`DROP FUNCTION` of an extension member inside an update script is allowed, and the replacement is
re-added as a member automatically, so no `ALTER EXTENSION ... DROP` is needed. Both forms were
tried on a throwaway extension before being relied on.

`ALTER TABLE ... ADD COLUMN` with a non-volatile default is metadata-only at 11 and later, so both
new columns apply instantly whatever the size of the table. `lock_tree_history.root_object` has no
default and existing rows stay `NULL`, which is correct: a sample taken before the upgrade has no
recorded object. `lock_tree_alert.root_object` has `DEFAULT ''` because it joins a `NOT NULL`
primary key, and an empty string is the honest answer, since the value was never captured and every
existing row is a session root whose pid identifies it.

### A note on debugging this, since it cost real time

Four things went wrong in the harness and all four produced silence rather than an error, which is
the worst kind of failure:

- A shell loop over `$(docker exec psql -tA -c ...)` processed only the **first** prepared gid
  however it was written, so leftovers accumulated. `\gexec` in one psql session generates and runs
  every command server-side and cannot drop one.
- A fixture that took `BEGIN; PREPARE TRANSACTION` without a `LOCK TABLE` first holds no locks and
  blocks nobody, so the tree was silently empty.
- A scenario section that had `s7_stranded` holding `s7_t` then had a second prepared transaction
  try to lock `s7_t`, which waits forever with no error and no output. It hung rather than failed.
- A test run interrupted midway left a live `psql` that kept re-creating the state being cleaned
  up, so each cleanup appeared not to work.

The last three are all "no lock means no contention means nothing to see", which is the same failure
mode as the original bug: a test that measures nothing passes.

Verified: 203 tests green on PG 14, 15, 16, 17, 18 and 19beta4; all eight scenarios with `s7` now
showing three prepared roots against the published CTE's zero; the 0.7 -> 0.8 upgrade against
populated `lock_tree_history` and `lock_tree_alert` tables, and the full `0.2--0.8` chain; demo,
check-install and check-alert.

## 0.7 (2026-10-04)

Per-query blocking time over the sampled history, and an eighth scenario for the wide case.

Everything from 0.6 is unchanged except `lock_tree_history`, which gains a `query_id` column and
an index. The column is added with `ALTER TABLE ... ADD COLUMN`, which is metadata-only: no rows
are rewritten and no rewrite lock is taken, so the upgrade applies instantly whatever the size of
the history.

### Added

- `lock_tree_history.query_id`: the session's own `pg_stat_statements` query id, recorded per
  sampled row. The index over it is **partial**, because the column is NULL on every waiter row and
  an index over mostly-NULL keys is mostly wasted space.
- `lock_tree_history_statements(since interval DEFAULT '7 days')`: per-query blocking time from
  the samples, worst first. For each root query id: how many blocked sessions it held up across
  all samples, over how many samples, when first and last seen, the deepest chain and longest wait
  under it, when that worst wait happened, and which applications were involved. This is the
  question that gets a fix merged rather than a workaround. `lock_tree_statements()` answers it
  for the chain in front of you; this answers it for the month.
- `scenarios/s8_many_roots.sql`: five blockers at once, 30/18/10/5/3 waiters across them, 71 rows
  of tree reduced to 5 rows by `lock_tree_wide()`. `s4` covers a wide queue behind a *single*
  root, which is the shape the abbreviation work targeted; a queue that is wide *and* has several
  heads is the case the aggregate exists for, and it had no scenario.
- `test/12_history_statements.sql`, 17 assertions.

### The unit is session-samples, and that is not the same as seconds

`blocked_sessions` here counts each blocked session once per sample it was blocked in. A session
blocked for 60 seconds at a 10 second sample interval contributes six, not sixty.

That is deliberate. It is a higher bound on precision, not a lower one on importance: the number
rises in proportion to the sampling rate, so the **ranking** between statements is stable and the
absolute figure is not. What to read is which statement is at the top, not what the top number is.
The test asserts this by dividing `blocked_sessions` by `samples` and checking the result is the
average queue depth rather than a duration.

### Only roots carry a query_id, so this is per blocking query

A query blocked on a lock has no `query_id` for as long as it is blocked, and gains one when it
completes. Same finding as `lock_tree_statements()`, and here it decides what the history can
record: root rows only.

The join is on each row's **own** pid rather than on `root_pid`. Joining on `root_pid` was the
first attempt and it propagated the root's query id down the whole chain, so every waiter looked
like it was running the blocking statement, which is the normal case and would have made the
totals wrong rather than merely incomplete. `test/12_history_statements.sql` pins the property
directly: no waiter row carries a query id, every root row does.

Existing history rows keep a NULL `query_id` and are not backfilled. The value was never
captured, and inventing one from the stored query text would produce a queryid matching nothing in
`pg_stat_statements`.

### Deliberately does not reference pg_stat_statements

`lock_tree_history_statements()` references no optional module at all. The history carries
`query_id` and the totals are pure aggregation over a table this extension owns, so it stays plain
SQL and parses anywhere. Joining the statement text back in is one line for whoever has the module
loaded, and the `COMMENT ON` says so. This is the opposite choice to `lock_tree_statements()`,
which must be plpgsql precisely because it does need the module.

### Bugs found while building the eighth scenario

Five, all in the new scenario, all found by running it:

- Roots were selected with `WHERE app IS NOT NULL`, but every waiter has an `application_name`
  too, so all 71 sessions were selected and the loop tried to take a lock on a waiter's
  connection. Filtering on the table name, which only roots have, is the right test.
- Two `send_query` calls per waiter failed with "another command is already in progress": dblink
  allows one in-flight command per connection. One statement carrying both the `SET` and the
  query, as `s4` does, is the fix.
- The distribution came out 14/13/13/13/13, nearly a tie, which makes the ranking the aggregate
  exists for look like it does nothing. Now 30/18/10/5/3.
- That fix then put all 66 on one root: a `DECLARE`d loop variable named `i` shadowed a record
  field of the same name, so the comparison read NULL and every waiter fell through to the
  `ELSE` branch. Reference the record field explicitly.
- The scenario printed "no coverage block" with all the numbers visible, because the other seven
  scenarios set `\pset border 2` and [`scenarios/run.sh`](scenarios/run.sh) requires the leading pipe to parse the
  row. Absent, the awk matched nothing and the summary reported a missing block rather than a
  missing border setting.

Two more elsewhere: `SELECT h.* FROM lock_tree_history` in `test/07_history.sql` became ambiguous
once the new column collided with `p.pid` from its join, so the columns are now named; and the
sample's `INSERT` needed `query_id` in its column list, since the select list had one more
expression than the targets.

Verified: 181 tests green on PG 14, 15, 16, 17, 18 and 19beta4; all eight scenarios with `s8` at
66 sessions across five roots; the 0.6 -> 0.7 upgrade and the full 0.2 to 0.7 chain; demo,
check-install and check-alert.

## 0.6 (2026-10-04)

Alerting. Everything from 0.5 is unchanged, columns and all. The update path is additive: a table
and three functions, nothing altered, replaced or dropped.

History records what happened and `lock_tree_summary()` says whether anything is happening now.
Neither tells anyone. `lock_tree_notify()` closes that gap by raising a `NOTIFY` when a chain is
bad enough to be worth waking someone for.

Deliberately not included: anything that pages. Wiring a channel to a pager is a policy decision
that belongs to whoever runs the system, and the payload is JSON so that whatever you connect can
parse it without knowing anything about this extension.

### Added

- `lock_tree_notify(channel, min_blocked, min_depth, min_wait)`: raises a `NOTIFY` per notable
  root and returns how many it raised. **Zero is the normal, healthy result**, and it is the value
  worth watching.
- `lock_tree_alert`, a table of what has been alerted on: per channel, per threshold set, per
  root, with high-water marks. This is what makes the function notify once per incident instead of
  once per sample.
- `lock_tree_prune_alerts(older_than interval)`: forgets state orphaned by a restart or a retired
  channel. Not load-bearing; `lock_tree_notify()` maintains the table otherwise.
- `lock_tree_sampling_advice()`: a suggested interval for the sample cron entry, given how many
  sessions are blocked, with the reasoning. The cost of a sample is one row per blocked session,
  so a wide queue argues for a wider interval.
- `test/11_alert.sql`, 30 assertions: onset, silence, escalation, recovery, relapse, thresholds,
  and the refusal. Most of them assert a return of zero, which is the part worth testing.
- [`scripts/check-alert.sh`](scripts/check-alert.sh) and `make check-alert`: builds a chain, notifies, and reads the
  notification back from a **separate listening client**. A script rather than a test file because
  psql prints notifications to stdout and a TAP assertion cannot see stdout, so the delivery path
  needs a real second client.

### The design decision worth knowing about

It does not notify on every sample. A job that did would turn a two-minute incident into twelve
notifications, and everyone would learn within a week that the channel is noise, at which point
the one alert that mattered gets filtered along with the rest. A diagnostic tool that cries wolf
is worse than a silent one, because it costs you the thing the tool was for.

So it notifies on **onset** and on **escalation**, and stays quiet while a chain sits at the same
severity. Escalation is measured against high-water marks rather than the previous sample, so a
queue wobbling between 40 and 12 sessions notifies once rather than twice a minute, and a queue
dropping from 40 to 12 is recognised as getting better rather than re-alerting.

Thresholds are arguments, not settings, and there are no meaningful defaults. At least one must be
on, and all three off is refused with an error rather than quietly given a plausible value. A root
alerts if it meets **at least one** criterion that is switched on, because a queue can be bad in
ways unrelated to each other: a hundred sessions waiting one second is not an incident, and two
sessions waiting an hour is.

### Two design bugs the tests found

**Alert state was keyed by channel and root alone**, so two different alerting policies sharing a
channel cleared each other's state and each re-alerted on every alternate sample. A test that
alternated thresholds saw both roots fire twice when only one had actually got worse. The state is
now keyed by channel, threshold set and root.

**State was never cleaned up for a root that left the tree.** The per-root loop iterates over
`lock_tree_wide()`, and a root whose waiters have all gone has no edges and therefore no row
there: it simply vanishes. So the loop never saw it, never deleted its row, and the table grew
one row per root ever seen, all of them pids that will never be reused. There is now a sweep after
the loop. A test asserting the table empties on recovery is what caught it.

### Requirements, since most people will not know these

Documented at length in the README, because they are the things that make alerting not work:

- `NOTIFY` needs nothing at all. No extension, no `shared_preload_libraries`, no restart.
- **Something has to be listening, or the notification goes nowhere.** PostgreSQL does not queue
  notifications for absent listeners, so a `NOTIFY` raised with no listener is discarded. If your
  listener is down you get no alerts and no record that you got none.
- `lock_tree_alert` must be writable by whoever runs the sampler, and `lock_tree_notify()` is
  deliberately **not** granted to `PUBLIC`: it decides what is important enough to page someone,
  which is not a decision an arbitrary role should make.
- Alerting inherits the sample interval. Alerting every 10 seconds learns in 10 seconds at ten
  times the write cost.

### Also

- `.forgejo/workflows/test.yml` loads `pg_lock_tree--0.6.sql`.
- `scripts/check-install.sh` verifies the three new functions and reports whether
  `lock_tree_alert` is reachable.

Verified: 164 tests green on PG 14, 15, 16, 17, 18 and 19beta4; the 0.5 -> 0.6 upgrade and the
full chain; demo, seven scenarios, check-install, and `scripts/check-alert.sh` delivering a JSON payload to
a real listener.

## 0.5 (2026-10-04)

The wide case, and the cost of the blocking query. Everything from 0.4 is unchanged, columns and
all. The update path is additive, so there is nothing to migrate; PostgreSQL chains
`0.2--0.3--0.4--0.5` itself and `pg_extension_update_paths` confirms it.

### Added

- `lock_tree_wide()`: one row per root rather than one per session, with how many sessions each
  root blocks, the deepest chain under it, the longest wait, the distinct wait events, and what
  they are waiting for. On a 57-row two-root queue that is two rows instead of fifty-seven.
  `lock_tree_text_short()` made a wide queue narrower by abbreviating; that helps at sixty
  sessions and stops helping at six hundred, because the questions an operator actually has
  (which root is worst, how many sessions does it hold up, is anything a chain rather than a flat
  queue) need every line read to be answered.
- `lock_tree_summary()`: one row for the whole queue, for a dashboard cell or an alert
  condition. Returns zeros on a quiet database rather than no rows, so it can be used directly
  without a special case for "nothing is wrong".
- `lock_tree_statements()`: per root, what `pg_stat_statements` already knows about the query
  holding the lock. Normalised text, calls, mean and total time. This is the join that turns
  "pid 4821 holds a lock" into "this statement has run 40,000 times at 180ms mean", and the
  reason two incidents at 09:00 and 14:00 with different pids are recognisable as one problem.
- `test/08_wide.sql` (20 assertions): a 57-row two-root queue, with every number in the wide form
  checked against `lock_tree`. A summary that disagrees with the tree it summarises is worse than
  none, because it looks authoritative.
- `test/09_cost.sql` (6 assertions): the cost claim the README and the SQL header both make, now
  actually tested.
- `test/10_statements.sql` (11 assertions): `lock_tree_statements()` with and without
  `pg_stat_statements` loaded.

### The cost claim, pinned

`pg_blocking_pids()` briefly takes the lock manager's shared state, so the view calls it only
for sessions already waiting on a heavyweight lock. That was asserted in two places and checked
in none, and a refactor dropping the `wait_event_type = 'Lock'` guard would have looked identical
in every other test while getting roughly ten times more expensive on a busy server.

The test measures a **ratio**, not a wall-clock ceiling: a view scan against a plain
`pg_stat_activity` read of comparable size, both timed inside one `DO` block. Absolute timings on
a shared CI runner are noise. Measured five times on an idle container a single view scan varied
between 133 and 174 microseconds, which would make any fixed threshold either flaky or so
generous it caught nothing. The ratio sat between 4.6 and 6.4 across those runs, so the ceiling is
50: loose enough for a loaded machine, tight enough to catch the regression it exists for.

The same file checks the guard's correctness consequence directly, which does not depend on timing
at all: a session is only reported as blocked if it is genuinely waiting on a lock, and a root is
never itself waiting.

### `lock_tree_statements()`: optional in both directions

`pg_stat_statements` needs to be in `shared_preload_libraries` to be readable at all, and its
failure mode is nasty: `CREATE EXTENSION` succeeds and then every read of the view raises
`pg_stat_statements must be loaded via "shared_preload_libraries"`.

A SQL function naming `pg_stat_statements` directly therefore fails at `CREATE EXTENSION` time on
a server without it, which would make an optional feature mandatory. This one is `plpgsql`, with
the join built as text and run through `EXECUTE` behind a `to_regclass` check. Without the
module it still reports every root and how much each blocks, with the statement columns empty, so
a dashboard querying it needs only one code path.

**It cannot enrich the waiters, and this was measured rather than assumed.** A query blocked on
a lock has a `NULL` `query_id` for as long as it is blocked and only gains one when it completes,
so the waiter side of the join is empty during exactly the moment anybody would want it. The root
is the opposite and carries a `query_id` throughout. That is fortunate rather than lucky, since
the root is the session anyone acts on. `test/10_statements.sql` asserts the limitation so it
cannot quietly become a claim the function cannot keep.

### Test harness

`pg_stat_statements` is now preloaded in the matrix images alongside `pg_cron`, so
`test/10_statements.sql` runs rather than skips on all six versions. Neither module is a runtime
dependency of the extension: it needs no `shared_preload_libraries`, and seven of the ten test
files run without either.

### Fixed

Nine bugs, all found by running things. Six in the new tests, two in the linter, one in the
demo:

- `test/08_wide.sql` compared an aggregate inside `WHERE`, which SQL forbids. Moved to `HAVING`.
- `sum()` over `bigint` returns `numeric`, and pgTAP's `is()` has no numeric/bigint overload.
- The wide test's teardown waited for the tree to empty without rolling the roots back first.
  The waiters were blocked on locks the roots held, so the wait simply timed out after ten
  seconds and the "quiet database" assertions measured a queue that was still stuck.
- A loop variable named `n` shadowed the `n` column of the dblink name table.
- `test/10_statements.sql` interpolated a `\gset` boolean into a dollar-quoted `DO` body. psql
  does not interpolate inside dollar quotes, so the block was a syntax error.
- The new images preload `pg_stat_statements` but do not create the extension, since it is
  per-database. The test skipped on all six versions and reported success. It now creates it when
  the library is loaded, and gates on `to_regclass` afterwards, which is the state a user who
  followed the documentation is in.
- `scripts/lint-docs.sh` rejected a correct conditional test file: it compared `skip(N)` against
  `plan(N)`, which only holds when `\if` wraps the whole file. When `\if` wraps part of it the
  arithmetic is `skip(N) == plan - unconditional`. Four further bugs in that same fix: an `\if`
  anchor that never matched because psql meta-commands carry arguments, an over-escaped grep
  pattern, an `if`/`fi` imbalance that made the whole script unparseable, and a check that ended
  up comparing against nothing at all.
- The demo's new history section sampled while the deadlock section's cycle was still running, so
  "nothing is blocked" reported two rows and contradicted itself.

Verified: 134 tests green on PG 14, 15, 16, 17, 18 and 19beta4 from cold-pulled registry images;
the 0.4 -> 0.5 upgrade and the 0.2 -> 0.3 -> 0.4 -> 0.5 chain; demo, all seven scenarios and
check-install.

## 0.4 (2026-10-04)

Adds history. Everything from 0.3 is unchanged: the view's columns and every function's
signature and output are byte-identical, and the update path is purely additive, so there is
nothing to migrate. `ALTER EXTENSION pg_lock_tree UPDATE` moves an existing installation in
place; verified from clean 0.2 and 0.3 installs, and PostgreSQL chains `0.2--0.3--0.4` for you.

The motivation is the one limit nothing here could work around. Every other object reports the
present, which is exactly what you cannot read at the moment an incident is noticed: by then
`pg_stat_activity` has moved on and the tree is empty. History is opt-in and starts empty.

### Added

- `lock_tree_history`, a table of sampled trees, one row per session per sample so the shape of
  the chain survives. Indexed on `sampled_at` and on `(pid, sampled_at DESC)`, since an unindexed
  history table is one nobody can afford to query once it holds a day of samples.
- `lock_tree_sample()`: takes one snapshot, returns the number of rows written. **0** when
  nothing is blocked, rather than a row recording that nothing was blocked, so an idle server
  costs one `SELECT` and no storage.
- `lock_tree_incidents(max_gap interval DEFAULT '5 minutes')`: the history grouped into
  incidents, each with when it ran, peak sessions blocked, deepest chain, longest wait, and the
  root pids and application names involved. `peak_sessions` is a high-water mark, not a sum: a
  session seen at four samples was not four sessions.
- `lock_tree_prune(older_than interval)`: deletes history older than the given age and returns
  how many. The table only ever grows, one row per blocked session per sample, so this is not
  optional in practice.
- `test/07_history.sql`, 24 assertions: the sample, the rows outliving the incident, the
  segmentation at two thresholds, and pruning at both extremes. It calls `lock_tree_sample()`
  directly rather than scheduling it, so the history logic is tested without depending on
  `pg_cron`. What it does not re-test is whether a scheduler can reach any of it, which
  `test/06_cron.sql` already covers.

### Notes

- `lock_tree_sample()` is `SECURITY DEFINER` so the scheduled job's role needs no `INSERT`
  grant. It takes no arguments and inserts a fixed column list, so there is nothing to steer.
- `sampled_at` is `statement_timestamp()`, which took two attempts to get right and is worth
  recording. `clock_timestamp()` is volatile, so it is evaluated once per **row**: the sessions
  of one sample land microseconds apart, grouping by `sampled_at` yields one group per session
  instead of one per sample, and `peak_sessions` silently becomes 1 in every incident ever
  recorded. `now()` fails the other way, being the transaction timestamp, collapsing everything
  written in one transaction to a single instant. `statement_timestamp()` is stable for the one
  statement that takes the sample and moves between samples.
- Because `lock_tree_sample()` pins `search_path` to `pg_catalog`, a relation name in the history
  can be schema-qualified where the same relation read from your session is not: `regclass`
  renders with or without the schema depending on whether the schema is visible. Pinning is the
  safe choice and the qualification is the better of the two for a record that outlives the
  session which created it, but it is worth knowing before grepping history for a bare table
  name.
- Pruning uses `DELETE`, not `TRUNCATE`, since `TRUNCATE` would take rows you meant to keep.
- `pg_cron` remains a convenience, not a requirement. Any scheduler works, including a host cron
  job calling `psql`, and the extension still needs no `shared_preload_libraries`.

### Fixed

Four bugs, all in the new test file and all found by running it rather than reading it:

- The fixture inserted one row per timestamp, so every sample looked like a single session and
  `peak_sessions` read 1 throughout. Each sample now carries all three depths at one instant,
  which is the point: rows sharing an instant are one observation of one tree.
- Both prune calls ran in one quiet block before the assertion that the rows had survived, so
  "the rows are still there" was checked against an already-emptied table.
- The pruning window was one second, which removed the 13 backdated rows but not the 2 written
  seconds earlier by the live sample. The window has to be older than the newest row, and the
  newest row is always the one just taken, so it is now zero seconds.
- The cleanup terminated pids unconditionally, warning `PID N is not a PostgreSQL backend
  process` twice per run for a session already terminated deliberately. Harmless, and not worth
  leaving: two warnings per run teaches people to ignore warnings, and then a real one goes
  unnoticed.
- `scripts/lint-docs.sh` failed on `lock_tree_history`, because it only looked for `FUNCTION`
  and `VIEW` definitions when checking that a documented object exists. A table is as much a
  documented object as a function. Found by running the linter, which is what it is for.

Verified: 97 tests green on PG 14, 15, 16, 17, 18 and 19beta4 from the registry images; the
0.3 -> 0.4 and 0.2 -> 0.3 -> 0.4 update paths; demo, all seven scenarios and check-install.

## 0.3 (2026-10-04)

The action block, split in two, and two bugs found while checking it. The `lock_tree` view is
untouched: same columns, same values, same semantics, still full and unabbreviated, so anything
selecting from it or grepping for `AccessExclusiveLock` keeps working.
`ALTER EXTENSION pg_lock_tree UPDATE` moves an existing installation in place; verified from a
clean 0.2 install.

### Fixed

- **A prepared transaction was given advice that could not work.** `lock_tree_roots()` returned
  the generic `pg_cancel_backend(0)` for the pid-0 root, but pid 0 is not a backend:
  `SELECT pg_cancel_backend(0)` returns false and warns `PID 0 is not a PostgreSQL backend
  process`. This was the one case where the queue is genuinely stuck and the operator has no
  other signal, so it is the worst possible place to hand back a no-op. It now says
  `ROLLBACK PREPARED`, and points at `pg_prepared_xacts` for the gid, which this extension
  cannot see. `scenarios/s7_prepared.sql` now exercises the action block, which it previously
  did not, which is why this survived 0.1 and 0.2.
- **`lock_tree_actions()` promised a copy-and-paste command and was not one.** Every line began
  with `--`, so pasting one did nothing at all and still exited 0; extracting just the fragment
  gave `syntax error at or near "pg_terminate_backend"`, since a bare call is not a statement.
  The trailing `;` announced runnability on a line that was inert.
- **`lock_tree_command()` never suggests terminating the session asking the question.** A
  monitoring session can itself be a root blocker; `root_pid <> pg_backend_pid()` now guards it.

### Added

- `lock_tree_command()`: one complete, runnable statement per root blocker, in one column and
  nothing else, so it pastes cleanly, `\copy`s cleanly, or runs all at once with psql's
  `SELECT command FROM lock_tree_command() \gexec`. Always the least destructive step that can
  work: `pg_terminate_backend()` for an idle-in-transaction blocker, since cancelling one could
  not achieve anything, and `pg_cancel_backend()` for anything else, leaving escalation to a
  terminate as the operator's decision. Prepared transactions and your own session produce no
  row, and `lock_tree_roots()` explains both.
- `test/06_cron.sql`: builds a live three-session chain and samples it with a `pg_cron` job,
  asserting the sampled rows outlive the incident. This is the feasibility check for scheduled
  history, not history itself: no retention policy, no threshold alerting. It skips itself
  where `pg_cron` is absent rather than failing.

### Changed

- `lock_tree_actions()` keeps its signature but now returns prose: no runnable statements, no
  semicolons, every line a comment, and a line pointing at `lock_tree_command()`. **This is a
  breaking change for anything parsing its output**, deliberately: the old text claimed to be
  executable and was not.
- `SET lock_tree.actions = off` suppresses `lock_tree_actions()` entirely, for anyone who would
  rather read the roots as the columns `lock_tree_roots()` already gives them. A pure-SQL
  extension can read and test a placeholder GUC without declaring it; `off`, `false`, `no` and
  `0` all switch it off.
- The version guard now says what a backport would cost rather than just refusing. On 13 and
  earlier the extension refuses to install, and the error states that `pg_locks.waitstart` is the
  only blocker and that everything else works on 9.6+. Verified by patching out the three
  `waitstart` references and running the real thing on 13: the tree, roots, depths, paths and
  `blocked_by` were all correct, with only wait age empty.
- `.forgejo/workflows/test.yml` loads `pg_lock_tree--0.3.sql`, and its note on why there is no
  `command:` override now covers `pg_cron` as well as `max_prepared_transactions`.
- `scripts/check-install.sh` verifies `lock_tree_command()` and `lock_tree_lines()` exist and
  are callable, and reports whether `pg_cron` is preloaded, so a skip in `test/06_cron.sql` is
  explained rather than mysterious.
- `scripts/lint-docs.sh` (`make lint-docs`, `make check`) and `.forgejo/workflows/lint.yml`:
  checks the documentation's factual claims against the code, since docs rot silently and
  nothing else would notice. Version agreement across `pg_lock_tree.control`, `README.md` and
  `CHANGELOG.md`; every object the docs name is defined in the release SQL; every SQL file is
  installed by the Makefile; every file and test the docs link to exists; each test's `plan()`
  matches its assertions and each `skip()` agrees with its plan; no em-dashes or en-dashes.
  Needs no database, so it runs as its own CI job rather than inside the test matrix.

### Not changed

`pg_lock_tree` still needs no `shared_preload_libraries`. `pg_cron` is a dependency of the test
harness, preloaded in the `pg-test` images so `test/06_cron.sql` has something to schedule. The
other five test files run and pass without it.

## 0.2 (2026-10-04)

Rendering and ergonomics only. The `lock_tree` view's columns, values and semantics are
unchanged and still carry full, unabbreviated names, so anything selecting from the view or
grepping for `AccessExclusiveLock` keeps working. `ALTER EXTENSION pg_lock_tree UPDATE` moves an
existing installation in place; verified from a clean 0.1 install.

### Added

- `lock_tree_text_short(query_width int DEFAULT 100)`: the same tree with abbreviated lock
  modes and session states. Measured at **17% narrower** on a 61-session incident, and the
  default query width is larger precisely because the abbreviations gave the room back.
- `lock_tree_actions()`: one command per root blocker, ordered by how many sessions each
  unblocks, each carrying its blast radius (`blocks N session(s), chain depth D`) on the same
  line. **Deliberately separate from the tree:** with a hundred sessions stuck the tree is
  already a wall of text, and a command on every line would double it. Superseded in **0.3**,
  which found the command was not actually pasteable; see the 0.3 entry.
- `lock_tree_age(interval)`: `4s`, `1m30s`, `2h05m`. Applies to both text forms.
- `lock_tree_mode_short(text)`, `lock_tree_state_short(text)`: `AX`, `idle-in-tx`. Values not
  in the tables pass through unchanged rather than being guessed at.
- `scenarios/`: seven incidents built with `dblink`, each queried both by this extension and
  by the published recursive CTE, with both outputs captured.
- `test/05_formatting.sql`: pins the exact output of the helpers above, since the scenario
  suite derives its width measurements from them.

### Changed

- `lock_tree_text()` output layout. The root line is now `pid  state  age  app  query` rather
  than `pid  [state, xact age]  app (user@db)  query`; waiter lines carry a compact wait age and
  the lock mode without the word "for". Same signature, same defaults, and the per-line
  suggestion moved out to `lock_tree_actions()`.
- `Makefile` now installs update scripts. Listing `pg_lock_tree--0.1--0.2.sql` in `DATA` does
  not work. PGXS copies `DATA` by name and an update path is found by a different convention, so
  so there is an explicit `install-upgrades` target.
- `.forgejo/workflows/test.yml` loads the then-current `pg_lock_tree--0.2.sql`.

### Scenario results

| scenario | waiting | published CTE | pg_lock_tree |
|---|---|---|---|
| 1 nightly batch | 4 | 4 | 4 |
| 2 three chains | 4 | 4 | 4 |
| 3 row locks | 2 | 2 | 2 |
| 4 wide queue | 60 | 60 | 60 |
| 5 advisory locks | 2 | 2 | 2 |
| 6 deadlock | 2 | 2 | 2 |
| 7 prepared transaction | 2 | **0** | 2 |

Coverage ties almost everywhere, and the suite reports that rather than overclaiming. The real
differences are that the published form times out when run verbatim (`s1`, `s4`), returns 40
rows for a 2-session deadlock (`s6`), and cannot see a blocker that has no `pg_locks.pid`
(`s7`).

## 0.1 (2026-10-03)

First release. Pure SQL, PostgreSQL 14+.

### Added

- `lock_tree` view: every session in a lock-wait chain, with `root_pid`, `depth`, `path`,
  `blocked_by`, `state`, `waiting_for`, `wait_age`, `xact_age`, `state_age` and `query`.
- `lock_tree_roots()`: head-of-line blockers only, ordered by how many sessions each one
  blocks, with `blocked_sessions`, `max_depth`, `longest_wait` and a `suggested_action`.
- `lock_tree_text(query_width int DEFAULT 60)`: the tree as indented text for psql.
- A session blocked by several blockers is placed on its deepest chain, so the queue order
  reads top to bottom rather than fanning out.
- Prepared transactions appear as a root at pid `0`.
- Relations locked in another database are shown by OID, since names only resolve in the
  current database.
- 31 pgTAP tests across four files, run against PG 14 to 19 by `scripts/matrix.sh` and CI.

### Fixed since the first draft

- **A wait-for cycle no longer empties the tree.** Root finding required a blocker that was
  not itself blocked. In a deadlock every session in the cycle is blocked, so the component
  matched nothing and `lock_tree` returned no rows, precisely when an operator most wants
  output. The walk is now seeded from every blocker and each session in a rootless cycle is
  reported as its own depth-0 root. `test/03_deadlock.sql` builds a real two-session cycle
  and covers this.
- **The documented monitoring grants were incomplete.** `GRANT pg_read_all_stats` alone still
  failed with `permission denied for view lock_tree`; `GRANT SELECT ON lock_tree` is also
  required. `test/02_permissions.sql` pins both halves.

### Notes

- `pg_blocking_pids()` briefly takes the lock manager's shared state, so the view calls it
  only for sessions already waiting on a heavyweight lock. Sample every few seconds at most,
  never in a tight loop.
- Behaviour that needs `max_prepared_transactions > 0` (the prepared-transaction path) is
  covered by `test/04_prepared.sql`; the shared `pg-dev-infra` compose file sets it.