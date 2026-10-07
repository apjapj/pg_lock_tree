# history: reading it after the fact

**For: whoever schedules the sample and lives with what it writes.** How often to run it, how much it
will store, what it will refuse to store, and how to throw it away.

```
-- schedule this
SELECT lock_tree_sample();

-- is the interval I chose the wrong one?
SELECT * FROM lock_tree_sampling_advice();

-- how big has it got?
SELECT * FROM lock_tree_history_size();

-- throw away everything older than a day
SELECT lock_tree_prune(interval '1 day');
```

`lock_tree_sample()` is the only thing that writes the history and the only one you have to schedule.
Everything else reads it. Without a schedule the history is empty and every function here returns
nothing, which is the right answer for an unsampled database rather than an error.

Then, once there is a history to read:
[docs/after-the-incident.md](after-the-incident.md).

## One hazard worth knowing before you schedule anything

The samples must be **separate statements**. `sampled_at` is `statement_timestamp()`, which is fixed
for the duration of a statement, so a loop of samples inside a single `DO` block collapses onto one
instant:

```sql
-- WRONG: four samples, one instant, four seconds of incident invisible to the history
DO $$ BEGIN FOR i IN 1..4 LOOP PERFORM lock_tree_sample(); PERFORM pg_sleep(1); END LOOP; END $$;

-- RIGHT: four samples, four instants, and lock_tree_duration() can sum the gaps
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample();
```

The rows are written either way, so the history looks healthy unless you count instants rather than
rows. A `cron` entry has no such problem, since each run is its own statement.
`test/16_duration_resolved.sql` pins this down with the measurement rather than only describing it.

## Redaction

`lock_tree_history` keeps the first 300 characters of every blocked session's query. A blocked
`ALTER ROLE app PASSWORD '...'` is a blocked query, and it was stored in full until 1.0.0. From 1.0.0
`lock_tree_sample()` strips password literals, SCRAM verifiers and md5 hashes on the way in, and
**redaction is the default**.

| `lock_tree.history_query` | Stored |
|---|---|
| unset, or anything unrecognised | redacted. An unknown value redacts rather than leaks, which is the only direction it is allowed to fail in |
| `redacted` | credentials stripped |
| `full` | the query verbatim |
| `none` | `NULL` |

```sql
-- per session
SET lock_tree.history_query = 'full';

-- per database, which is how you would normally do it
ALTER DATABASE mydb SET lock_tree.history_query = 'full';
```

There is no C code in this extension, so the setting is a placeholder GUC with no declared default
and no `SHOW ALL` entry until something sets it. That is why `lock_tree_sample()` coalesces it rather
than reading it directly.

**What it strips:** the literal after `PASSWORD` in `CREATE`/`ALTER ROLE`, `USER` or `GROUP`, in all
three quoting styles; `SCRAM-SHA-256` verifiers including the real
`SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>` form; md5 hashes.

**What it does not strip:** connection URLs carrying a password, and ordinary DML. A URL with a
password in it is a real exposure and also a perfectly ordinary thing to have in an ad-hoc query, so
redacting it by default would be a guess about your data.

**The cost, stated plainly:** two statements differing only in a password group as ONE row in
`lock_tree_incidents()` and `lock_tree_history_statements()`, where before they were two. That is
usually the better answer, since the password is not what distinguishes the incident.

**A dump taken before 1.0.1 still contains whatever the history held.** Upgrading scrubs the live
table; it cannot reach into a backup already written.

## Sizing it

`lock_tree_history` grows by one row per **blocked session** per sample, with nothing to stop it.

```
 lock_tree_history_size():  rows, oldest, newest, bytes, rows/day, days to 1 GB
 lock_tree_sampling_advice():  a suggested interval, given the current rate
```

Neither says when the read side becomes the problem rather than the write side. That is a judgement
and [docs/roadmap.md](roadmap.md) lists it as an open question rather than pretending it is answered.

## Holding more than a few weeks

The default window of every read function is 7 days, and on a big database that is not always long
enough to be useful. **Retention and query window are two separate decisions**, and this section is
about keeping them separate. Everything below was measured on PostgreSQL 18, against the standard
fixture: 1,209,620 rows, 60,481 samples, seven days sampled every 10 seconds with 20 blocked sessions.

### What a row costs

| query text stored | bytes per row, heap |
|---|---|
| 300 characters, which is what production stores | 409.6 |
| 100 characters | 190.5 |
| `NULL` | 93.2 |

The query text is **316 of those 410 bytes, 77% of the row**. Add about 68 bytes of index overhead and
a row costs roughly 478 bytes with indexes. The published fixture figure of 266 MB for seven days is
optimistic against real data by about two times, because the fixture stores 34-character queries.

At a 10 second interval with 20 blocked sessions that is 172,800 rows a day:

| retain | rows | on disk, at 478 bytes a row |
|---|---|---|
| 7 days | 1,209,600 | 0.5 GB |
| 30 days | 5,184,000 | 2.3 GB |
| 90 days | 15,552,000 | 6.9 GB |
| 365 days | 63,072,000 | 28 GB |

Storage is not the constraint. Query time is.

The 365-day row of that table is what production-shaped query text costs. **The 365-day fixture
measured 14 GB**, roughly half, for the same 63,072,020 rows, because the fixture stores
34-character queries rather than 300-character ones. Both numbers are right and they are not the
same measurement: budget from the table, which assumes what your server actually stores, and expect
the fixture to land near half of it.

### Reading is bounded by the window, not by the retention

Five of the six history read functions take a `since`, so how much they cost depends on how much you
ask for rather than how much you keep. The first four rows were measured in 1.1.2. The last was a
projection until 1.1.5, when it was measured on a real 365-day fixture, and **the projection was
pessimistic**:

| retain | rows | `duration()` at the 7-day window | `by_application()` at the 7-day window | `incidents()`, whole history |
|---|---|---|---|---|
| 7 days | 1,209,620 | 2.0 s | 2.3 s | 1.8 s |
| 30 days | 5,184,020 | 2.6 s | 3.6 s | 9.1 s |
| 90 days | 15,552,020 | 2.5 s | **7.4 s** | **25.6 s** |
| 365 days | 63,072,020 | 2.2 s (2.1 s) | **30.3 s** (**1.9 s**) | **110.5 s** (**89.0 s**) |

The bracketed figures are measured, on 63,072,020 rows and 3,153,601 samples, PostgreSQL 18, every
page all-visible. The year is **not** the expensive case this table used to imply. A seven-day window
at a year of retention costs 1.9 s, which is less than the 2.3 s that the same window cost at a week
of retention in 1.1.2, because 1.1.5 fixed the cause. Read the last row as a measurement, not as a
warning.

The projection was pessimistic because it was made before the fix, and it extrapolated the 1.1.2
trend that 1.1.5 removed. That is the general hazard with this table: a per-retention figure
measured before a fix that changes per-retention behaviour will keep predicting the old shape after
the fix lands, and the only way to find out is to build the fixture.

Fixture for every row of this table and the ones below: [`scripts/bench-history.sh`](../scripts/bench-history.sh)
`--days=7|30|90|365`, one sample every 10 seconds, 20 blocked sessions per sample, vacuumed (every page
all-visible) before timing, PostgreSQL 18, `shared_buffers` 128 MB, `work_mem` 4 MB. The fixture has one
root pid, five application names and a `NULL` `root_object` on every row, so its arrays are short; a
real history's are longer, and the cost of building them grows with the distinct values rather than
the rows. `duration()` and `by_application()` are single runs; `incidents()` is the best of three.

`duration()` does not move, because it reads the window you name. **`by_application()` did**, from
2.3 s at a week of retention to 30 s at a year, while asking about the same seven days. That was
measured in 1.1.2 and the cause was not understood until 1.1.5, which fixes it. **Confirmed at a
year:** 1.9 s measured, so the growth is gone rather than merely reduced.

**The cause, and the fix.** Both functions join root rows to waiter rows on `sampled_at`, and both
bounded only the root side. PostgreSQL does not carry a `>=` bound on `r.sampled_at` across the
equality `w.sampled_at = r.sampled_at`, so whether the waiter side stayed inside the window depended
on which join the planner chose. A nested loop probes it and reads about 19 rows per root. A merge
join, a hash join or a sequential scan reads every `depth > 0` row in the table. `duration()` was
handed the first and `by_application()` the second, which is why the two disagreed despite
identical SQL, and why the cost tracked retention rather than the window you asked about.

From 1.1.5 both state the bound on the waiter side. It cannot change the result, since the join
equates `sampled_at` and the root side is bounded. Measured on the 7-day window, old and new
alternating on one fixture, best of three:

| fixture | function | 1.1.4 | 1.1.5 | waiter rows read |
|---|---|---|---|---|
| PG18, 90 days | `duration()` | 2480 ms | 2511 ms | 19 either way |
| PG18, 90 days | `by_application()` | 6989 ms | **2155 ms** | 14,774,419 to **1,143,439** |
| PG14, 30 days | `duration()` | 2265 ms | 2335 ms | 19 either way |
| PG14, 30 days | `by_application()` | 3417 ms | **2397 ms** | 4,924,819 to **1,148,854** |

`duration()` is bounded as well although its plan does not change on a healthy fixture, because that
is not guaranteed: on PG14 with unusable statistics it fell back to a sequential scan over every
waiter row, 7,917 ms against 2,806 ms with the bound.

**The `by_application()` column in the table above is a 1.1.2 measurement of 1.1.2 behaviour, and
should now be read as pre-fix.** Those figures were taken on PostgreSQL 18, where the fixture
vacuums successfully, so the tooling fault below did not affect them, and they remain a fair record
of what 1.1.2 did. What has changed is that 30 s at a year is no longer a property of the function:
it was a property of one plan on one version. **The 365-day fixture has since been built and run,
and the expectation held:** 1.9 s, so `by_application()` now behaves like `duration()` does. The
measurement is in [A year of history, measured](#a-year-of-history-measured) below.

### A year of history, measured

The 365-day fixture: 63,072,020 rows, 3,153,601 samples, 14 GB on disk, one sample every 10 seconds
with 20 blocked sessions. Everything below was run against it, PostgreSQL 18, and is worth having in
one place because several things people ask about at that size are not what they expect.

| | |
|---|---|
| `duration()` at the 7-day window | 2.1 s |
| `duration_by_application()` at the 7-day window | 1.9 s |
| `incidents()`, whole history, no window | 89.0 s |
| `history_statements()`, whole history | 470 ms |
| `duration()` at a 1-millisecond window | 0.4 ms |
| `history_size()` | **6.3 s** |
| `lock_tree_notify()` | 6 to 24 ms |

**The live path does not care how much history you keep.** `lock_tree_notify()` is the function an
alerting cron calls, and it reads `lock_tree_wide()`, which reads `pg_locks`, plus `lock_tree_alert`.
It never reads `lock_tree_history`. Measured on 63M rows it takes single-digit milliseconds, the
same as on an empty table. That is a property of the shape rather than of the size: the sampler is
live-tree only and the history table is written by it but never read by it. So archiving old history
cannot slow down alerting, and you do not need to choose between keeping a year and alerting on it.

**`history_size()` is the one function that got slow, and it is the one you would call to find that
out.** It costs 6.3 s at a year, of which 5.0 s is `count(DISTINCT sampled_at)` over 63M rows. It is
also, by construction, unable to tell you that your disk is wasted: it reports
`pg_total_relation_size`, which is the file's high-water mark, so a table holding one week of rows in
a file sized for a year reports the year's size. If you are sizing a disk, size it from the table
above, not from this function.

**Two narrow-window figures are worth trusting.** A one-millisecond window matches no sample at all
and both duration functions return in 0.4 ms, which is what proves the window became an index
condition rather than a filter over a whole index scan. If you ever see a narrow window take as long
as a wide one, that is the regression to look for.

### What a year does not tell you to do

The measured year is **cheaper to read than a week was in 1.1.2**, so the case for tiering, archiving
or partitioning the history rests on disk and on operational tidiness, not on read speed. What was
measured about moving rows out, on this fixture, is in [Retiring old history](#retiring-old-history).

### A fault in this harness, found while fixing the above

`scripts/bench-history.sh` ran `VACUUM (ANALYZE)` with its output discarded and never checked the
result. The parallel index phase allocates a shared memory segment sized to `maintenance_work_mem`,
and Docker's default `/dev/shm` is 64 MB. On PG14 in `pg-test:14` that is a 67,145,216 byte request
against 64 MB, so the vacuum failed outright:

```
ERROR:  could not resize shared memory segment "/PostgreSQL.573425660" to 67145216 bytes:
        No space left on device
```

The script carried on and printed timings for an unvacuumed, unanalysed table: 9.0 s where 2.3 s was
the truth, and 1.2 s for a 1 ms window that should be free. It now uses
`VACUUM (ANALYZE, PARALLEL 0)` and refuses to report any timing if the vacuum fails, printing the
underlying error and exiting non-zero.

The figures in this file predate that fault and are PostgreSQL 18, where the vacuum succeeds, so they
are unaffected. Stated rather than assumed. The general lesson is the one this project keeps meeting:
a check that cannot report its own broken state is worse than no check, because a silent failure
reads as a pass. That fault is also part of why the 1.1.5 investigation was hard: an early
measurement of 4,924,819 waiter rows was dismissed as unreproducible when the fixture beneath it had
never been vacuumed, and the real explanation turned out to be plan dependence on a second version.
`lock_tree_incidents()` moves too, and until **1.1.0** there was nothing you could do about it: it was
the only history read function with no window parameter, so its cost followed your retention rather
than the question you asked. It now takes one:

```sql
SELECT * FROM lock_tree_incidents(since => interval '30 days');
```

Its default is `NULL`, meaning the whole retained history, which is what it did in every earlier
release. An existing call changes nothing. Measured on the 7-day fixture in 1.1.2, best of three: no
argument 1785 ms, `since => '1 day'` 250 ms, `since => '6 hours'` 106 ms.

### `incidents()` in 1.1.2

1.1.2 changed how `lock_tree_incidents()` builds its three arrays, and nothing about what it returns.
`array_agg(DISTINCT x ORDER BY x)` sorted every row in the incident's range to produce a handful of
values, and with the default `work_mem` that sort went to disk once per array. It now takes the
`DISTINCT` first, as a hash aggregate, and sorts only the distinct values. Same fixture as above, the
1.1.1 body and the 1.1.2 body alternated in one session, best of three, `EXPLAIN (ANALYZE, TIMING OFF)`:

| retain | 1.1.1 | 1.1.2 | change | temp written, 1.1.1 | temp written, 1.1.2 |
|---|---|---|---|---|---|
| 7 days | 2.11 s | 1.79 s | -15% | 26 MB | 0 |
| 30 days | 11.41 s | 9.06 s | -21% | 220 MB | 0 |
| 90 days | 32.94 s | 25.57 s | -22% | 658 MB | 0 |
| 365 days | 159.11 s | 110.48 s | -31% | 4.25 GB | 350 MB |

The 350 MB left at a year is not the arrays. It is the sort of 3,153,601 per-sample rows into
incidents, which the arrays never touched, and on this fixture the array subplans write nothing to
disk at any retention. The gain grows with retention because the spill it removed grew faster than
the rows did. Output was compared row for row between the two bodies on this fixture, at four
`max_gap` values from 5 seconds (60,481 incidents) to 1 day and five `since` values, and on a small
fixture with `NULL` application names, `NULL` and empty-string root objects and pid 0 roots, at eight
`max_gap` and eight `since` values: identical in every case, text and set.

### The whole retained window

What asking for the **whole retained window** costs, which is the thing to avoid:

| retain | rows | `duration()` | `by_application()` | `incidents()` |
|---|---|---|---|---|
| 7 days | 1,209,620 | 1.8 s | 2.1 s | 1.8 s |
| 30 days | 5,184,020 | 7.9 s | 9.1 s | 9.1 s |
| 90 days | 15,552,020 | 23.6 s | 27.2 s | 25.6 s |
| 365 days | 63,072,020 | 95.9 s | 110.4 s | 110.5 s |

The `incidents()` column is **measured** at each retention, from the table above. The other two are
still projections: the measured per-row cost multiplied by the row count, with per-row costs taken on
the 7-day fixture, cold `shared_buffers`, best of three, `SELECT *` because that is how a caller uses
these functions:

    lock_tree_duration()                1843.1 ms over 1,209,620 rows   1.52 us per row
    lock_tree_duration_by_application() 2110.8 ms                    1.75 us per row
    lock_tree_incidents()               1878.8 ms                    1.55 us per row  (1.1.1: 2188.1 ms, 1.81 us)

A projection is a straight line, and `incidents()` was not one. Its 1.1.1 per-row cost rose from 1.74
us at a week to 2.52 us at a year, so the 132.5 s this page projected for a year of 1.1.1 was 17%
light against the 159.1 s measured. The 90-day projection, 32.7 s, held: 32.9 s measured. Read the
two projected columns with that in mind at a year.

**The 365-day row of this table is now measurable, and only the `incidents()` column was kept
projected on purpose.** The whole-window reads were not run at a year, because nobody should ask
that question: the answer is a table scan of everything you kept, it grows linearly, and the useful
response is to pass a `since`. What was measured at a year, and what matters, is the bounded query,
which is in [A year of history, measured](#a-year-of-history-measured) above and costs 1.9 to 2.1 s
for a seven-day window. So read the 365-day row as the shape of the mistake, not as a number to
plan around.

**The `incidents()` figures in the 1.1.0 release were wrong, by about 2.8 times too pessimistic.**
They read 91 s at 90 days and 364 s at a year. The error was arithmetic on a correct measurement:
1.95 us per row was taken with all three array columns present, and then multiplied by three again
when projecting, as though the per-row figure had covered one array rather than all of them.
Correcting it matters, because the number was discouraging exactly the case it was written to inform.

`incidents()` is worth stating carefully for a different reason. `SELECT count(*)` on it is ten times
cheaper, at 0.20 us per row, because `count(*)` lets the planner drop all three array columns. If you
have ever timed this function with `count(*)` you have a number a tenth of the real one, which is what
made it look like the slowest thing in the extension before 1.1.0 corrected the benchmark.

### What to actually do

1. **Keep as long as you need. Ask for less than you keep.** Pass an explicit `since` to every read
   function and do not rely on the 7-day default once you hold more than a week.
2. **Size the interval from `lock_tree_sampling_advice()` rather than from habit.** It has three
   bands, and the 30 second one exists for a wide queue. At 30 seconds instead of 10 a year of
   retention is 9.4 GB rather than 28 GB, and the queries above are correspondingly cheaper because
   there are fewer samples to read.
3. **Prune on a schedule, with the batched procedure.** See below.
4. **Budget the disk at the high-water mark, not at your current retention.** Nothing returns the
   space except `TRUNCATE` on an empty table. See below, where this is measured on a 63M-row table.
   **Unless you archive on a cadence**, which removes the trap rather than paying it: a table pruned
   on a fixed cycle never exceeds its window plus one cycle, so its high-water mark is its steady
   state and the file never grows past it. The tax falls on installations that grew their retention
   and then cut it. See [Move data on a cadence](#move-data-on-a-cadence-and-the-cost-collapses).
5. **If a year is genuinely the goal, stop storing query text for old samples.** A row would go from
   410 to 93 bytes and a year from 28 GB to 6.4 GB. This is a trade rather than an optimisation: you
   give up being able to see what statement was running months ago. It is the only change that
   decouples storage from the length of a query.
6. **Know that keeping a year does not cost you read speed.** Measured on 63M rows, a seven-day
   window costs 1.9 to 2.1 s, less than the same window cost at a week of retention in 1.1.2. Do not
   shorten your retention to make queries fast; that trade is no longer on the table.

### Two operational facts that are easy to be surprised by

**Plain `VACUUM` does not shrink the file, and neither does deleting almost everything.** After
`SELECT lock_tree_prune(interval '1 day')` removed six of seven days, and after a plain `VACUUM`, the
heap file was still 187 MB while holding one day of data. The space is reusable, and the file stays at
its high-water mark until `VACUUM FULL`, which rewrites the table under `ACCESS EXCLUSIVE`. So size
the disk for the largest retention you intend to run, not the one you are running now.

This was re-measured on the 365-day fixture, where the effect is stark and where it is worth knowing
before you plan around it. One day of rows was moved out and the rest deleted, then the table
vacuumed:

| | heap file | live rows |
|---|---|---|
| after the delete | 9740 MB | 62,899,220 |
| after a plain `VACUUM` | 9740 MB | 62,899,220 |
| after `VACUUM FULL` | **9714 MB** | 62,899,220 |

`VACUUM FULL` held `ACCESS EXCLUSIVE` for **260 seconds** on a table with 63M live rows, and
reclaimed 26 MB, because 62.9M rows genuinely need that space. Reclaiming disk is not a function of
how much you deleted; it is a function of how little you kept. **Only `TRUNCATE` returns space, and
only when the table is genuinely empty.**

Two consequences, and the second is the useful one. If you keep a long retention and then shorten
it, you are left holding the peak forever, so size the disk for the largest retention you intend to
run. But if you prune **on a fixed cadence**, you never reach that state: the table grows to your
window plus one cycle and is pruned back, so the high-water mark is the steady state and the file
never exceeds it. No `TRUNCATE` is needed, because the table is never emptied. The escape hatches
above, a coarser interval or a shorter retention, remain available.

**Keep autovacuum ahead of the sample rate.** The history is appended to continuously, and an
index-only scan on it can only skip the heap where the visibility map is set. Measured on the
fixture: with the table vacuumed, a covering scan reported `Heap Fetches: 0` and took 31.2 ms. After
8,640 new rows were appended and not yet vacuumed, the same scan reported `Heap Fetches: 29719` and
took 55.1 ms. It recovers on the next vacuum. This is worth watching on a busy table because the
benefit is invisible until it degrades.

## Retiring old history

Everything in this section was measured on the 365-day fixture. It is here because the natural
instinct, keep the last week hot and move the rest somewhere cold, turns out to be expensive in a
way that is not obvious until you have measured it. **None of this is built in.** The extension ships
the two prune forms above and nothing else; the rest is what you would do by hand, with the costs
written down so you do not have to discover them.

### Moving rows into an archive table costs five minutes and doubles your peak disk

Copying everything older than seven days, 61,862,400 rows, into a plain table in the same database:

```
INSERT INTO archive SELECT * FROM lock_tree_history
 WHERE sampled_at < (SELECT max(sampled_at) FROM lock_tree_history) - interval '7 days';
```

took **298 seconds**. Every one of those rows is written twice, and the original is deleted
afterwards, so for the duration of the copy the database holds both. On this fixture the archive
reached 9556 MB while the original still measured 9714 MB. Peak disk is roughly double, and the
window is minutes long, not seconds.

Do it in batches if you do it at all, the same reason `lock_tree_prune_batched()` is a procedure. The
unbatched copy above is the shape of the mistake, not the recommendation.

### But the archive does not give the disk back

This is the part that inverts the plan. Having moved the bulk out, the hot table still measured
9740 MB, and a plain `VACUUM` left it at 9740 MB. The rows are marked reusable and the file is
unchanged, because of the `VACUUM` behaviour above. So an archive built by deleting from the hot
table leaves you holding a full year on disk **and** a full year in the archive, which is strictly
worse than having never archived, unless you were going to export the archive off the cluster anyway.

If the plan is to move old history out of the cluster entirely, then exporting is the right shape
and the archive table is just a staging area you should drop once the export lands. If the plan is to
keep it queryable in place, you pay double disk for it and you still have the hot table at its
high-water mark.

### Move data on a cadence, and the cost collapses

The 298 seconds above is what a **once-off, whole-table** move costs. It is not what a scheduled job
costs, and treating it as the number to plan against is the mistake. Measured on a week's worth of
rows at the fixture's rate, 1,209,600 rows, into a table carrying only a BRIN index:

| move | rows | time | peak disk penalty |
|---|---|---|---|
| the whole year at once | 61,862,400 | 298 s | the entire archive, roughly 9.5 GB |
| one week at a time | 1,209,600 | **1.8 s** | one week, 124 MB |

A weekly job moves a year of history for about two seconds of copying per run, and the transient
disk cost is bounded by one week rather than by the whole archive. Nothing about the copy is
unusual at that size; it is an ordinary bulk insert.

**And a steady cadence removes the high-water-mark problem entirely, without a `TRUNCATE`.** This is
the part worth taking away, because the paragraphs above make it sound unavoidable. The trap is not
"a table that has held a lot of data stays big". It is **growing your retention and then shrinking
it**: the file was sized for the peak, the peak has passed, and the space is reusable but not
returned. A table on a steady weekly cycle never experiences that. It grows to your window plus one
cycle, is pruned back to your window, and repeats, so **the high-water mark is the steady state and
the file never grows past it**. No `TRUNCATE`, no `VACUUM FULL`, no `ACCESS EXCLUSIVE` rewrite.

What you get for a year, keeping 30 days hot and archiving weekly:

| | today | weekly cadence |
|---|---|---|
| hot table | 28.1 GB, 365 days, 4 indexes | **2.8 GB, 37 days, 4 indexes** |
| archive | none | 28.1 GB, 328 days, BRIN only |
| total | 28.1 GB | 30.9 GB |

Production-shaped query text, at the 478 bytes a row measured above. Two things to read out of that.
**The hot table is ten times smaller**, which is the part that matters on a busy server, since a
2.8 GB table competing for `shared_buffers` is a different proposition from a 28 GB one and whole-window
reads get proportionally cheaper. And **total disk is roughly a wash**, 30.9 GB against 28.1 GB,
because the archive carries only a BRIN index and so pays almost none of the 68 bytes a row of index
overhead: on the same 1,209,600 rows, four indexes cost 170 MB and BRIN alone costs 124 MB.

The archive figure above is the projection for a BRIN-indexed archive and the 170 MB against 124 MB
is measured; the 28.1 GB is the table above multiplied by 328/365. Treat the total as a wash to
within a few percent rather than as a figure.

So this is not a disk saving. It is a **hot-set** saving, bought for two seconds a week.

### The cost that a cadence does not remove

The shipped read functions read `lock_tree_history` and nothing else. **Archived rows are invisible
to them**, so `lock_tree_incidents(since => interval '90 days')` against a 30-day hot window returns
90 days of incidents truncated to 30, silently, because the function cannot see rows that are not
there. That is the one thing a cadence does not fix, and it is the reason none of this is built in.

If you want a year queryable, the archive has to be reachable by something. Either you accept
hand-written SQL for anything crossing the boundary, or the extension grows a way to read across
both. That is a real API decision rather than a tuning knob, and it is worth making deliberately
rather than discovering it the first time a quarterly report comes back short.

### If you do keep an archive table, index it with BRIN and nothing else

`sampled_at` is append-only, so it is perfectly correlated with physical order. Measured on the
fixture, the correlation between `sampled_at` and the row's block number is **1.000000**, which is
the best case BRIN exists for.

| index on the same 63M rows | size |
|---|---|
| b-tree on `sampled_at` | 475 MB |
| BRIN on `sampled_at`, `pages_per_range = 32` | **1336 kB** |

That is 356 times smaller, and it is not merely small, it works. With the b-tree indexes disabled so
BRIN had to serve the query, a 30-day range read 102,389 buffers out of a 63M-row table, and the
archived day answered `count(*)` in 21 ms and a per-day trend in 47 ms.

```sql
CREATE TABLE archive (LIKE lock_tree_history);
CREATE INDEX archive_brin ON archive USING brin (sampled_at) WITH (pages_per_range = 32);
```

Two things to know about an archive table. **Do not make it `UNLOGGED`** even though it is
second-tier, because research data that vanishes on a crash is not research data. And **the read
functions will not see it**: every history read function reads `lock_tree_history` and nothing else,
so a question spanning the archive boundary needs SQL of your own. That is a real cost, and it is the
reason this is not built in.

### What this leaves as the actual answer

At a year of retention the read side is 1.9 to 2.1 s for a seven-day window, which is not a
performance problem. Retention is a **disk budget** problem, and the levers, in order of how much
they cost you:

1. Sample less often. `lock_tree_sampling_advice()` will tell you the interval your queue width
   supports, and 30 seconds instead of 10 is a third of the rows.
2. Prune on a schedule with the batched procedure.
3. Budget the disk at the high-water mark, because nothing else returns it.
4. Only then consider exporting, and accept the double disk and the hand-written queries that come
   with it.

Partitioning is the shape that would fix the retention side properly, and it was measured and
rejected. The measurements are in [the roadmap](roadmap.md#considered-and-not-planned), including why
it makes the read side worse.

## Pruning it

Two forms, and the difference is what happens to the write path.

| | |
|---|---|
| `lock_tree_prune(older_than)` | one statement, one transaction, one big lock. Returns rows deleted from the **history**, not across both tables |
| `lock_tree_prune_batched(older_than, batch_size)` | a **procedure**, because only a procedure can `COMMIT` between batches. For a table big enough that one transaction would be a problem |

```sql
-- small table, or a job with time to spare
SELECT lock_tree_prune(interval '1 day');

-- large table: commits every batch_size rows, so the lock is released in pieces
CALL lock_tree_prune_batched(interval '1 day', 10000);
```

Put the `CALL` on its own line. Inside `BEGIN`/`COMMIT` it is refused, and it checks for that
**before deleting anything**. See
[Why the history is not partitioned](roadmap.md#considered-and-not-planned).

Pruning clears the deadlock table too, since the two are read together.

Pruning does not return the disk to the operating system. A plain `VACUUM` marks the space reusable
and leaves the file at its high-water mark; only `VACUUM FULL` truncates it, under an `ACCESS
EXCLUSIVE` lock that blocks every write to the history for as long as it takes. On a table this size
that is a decision, not a routine step. The figures are in
[Holding more than a few weeks](#holding-more-than-a-few-weeks).

## Backups

None of the three tables is registered for `pg_dump`, and that is a decision rather than an
oversight, with the reasoning and the opt-in in
[INSTALL.md](../INSTALL.md#backups-and-restores). The short version: a **physical** backup, a base
backup, a snapshot and a replica all copy the history whatever is registered, so redaction above is
the control that keeps credentials out of them, not the dump setting.
