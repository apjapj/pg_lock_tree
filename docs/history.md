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
about keeping them separate. Everything below was measured on PostgreSQL 18 against the standard
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

### Reading is bounded by the window, not by the retention

Five of the six history read functions take a `since`, so how much they cost depends on how much you
ask for rather than how much you keep:

| retain | `duration()` at the 7-day window | `by_application()` at the 7-day window | `incidents()` |
|---|---|---|---|
| 7 days | 1.6 s | 2.2 s | 0.2 s |
| 90 days | 1.6 s | 2.2 s | **3.0 s** |
| 365 days | 1.6 s | 2.2 s | **12 s** |

The first two columns do not move, because they read the window you name. The third does, and until
**1.1.0** there was nothing you could do about it: `lock_tree_incidents()` was the only history read
function with no window parameter, so its cost followed your retention. It now takes one:

```sql
SELECT * FROM lock_tree_incidents(since => interval '30 days');
```

Its default is `NULL`, meaning the whole retained history, which is what it did in every earlier
release. An existing call changes nothing. Measured on the fixture: no argument 2477 ms,
`since => '1 day'` 315 ms, `since => '6 hours'` 124 ms.

What asking for the **whole retained window** costs instead, which is the thing to avoid:

| retain | `duration()` | `by_application()` | `incidents()` |
|---|---|---|---|
| 30 days | 6.7 s | 9.7 s | 30 s |
| 90 days | 20.2 s | 29.1 s | 91 s |
| 365 days | 82.0 s | 118 s | 364 s |

Per row, measured rather than assumed: `duration()` 1.30 us, `by_application()` 1.87 us, and
`incidents()` **1.95 us as a caller uses it**. That last figure is worth stating carefully, because
`SELECT count(*) FROM lock_tree_incidents()` is ten times cheaper at 0.20 us. The three array columns
are per-session aggregates that `count(*)` lets the planner drop entirely, so if you have ever timed
this function with `count(*)` you have a number a tenth of the real one.

### What to actually do

1. **Keep as long as you need. Ask for less than you keep.** Pass an explicit `since` to every read
   function and do not rely on the 7-day default once you hold more than a week.
2. **Size the interval from `lock_tree_sampling_advice()` rather than from habit.** It has three
   bands, and the 30 second one exists for a wide queue. At 30 seconds instead of 10 a year of
   retention is 9.4 GB rather than 28 GB, and the queries above are correspondingly cheaper because
   there are fewer samples to read.
3. **Prune on a schedule, with the batched procedure.** See below.
4. **Budget the disk at the high-water mark, not at your current retention.** See below.
5. **If a year is genuinely the goal, stop storing query text for old samples.** A row would go from
   410 to 93 bytes and a year from 28 GB to 6.4 GB. This is a trade rather than an optimisation: you
   give up being able to see what statement was running months ago. It is the only change that
   decouples storage from the length of a query.

### Two operational facts that are easy to be surprised by

**Plain `VACUUM` does not shrink the file.** After `SELECT lock_tree_prune(interval '1 day')` removed
six of seven days, and after a plain `VACUUM`, the heap file was still 187 MB while holding one day
of data. The space is reusable, and the file stays at its high-water mark until `VACUUM FULL`, which
rewrites the table under `ACCESS EXCLUSIVE`. So size the disk for the largest retention you intend to
run, not the one you are running now.

**Keep autovacuum ahead of the sample rate.** The history is appended to continuously, and an
index-only scan on it can only skip the heap where the visibility map is set. Measured on the
fixture: with the table vacuumed, a covering scan reported `Heap Fetches: 0` and took 31.2 ms. After
8,640 new rows were appended and not yet vacuumed, the same scan reported `Heap Fetches: 29719` and
took 55.1 ms. It recovers on the next vacuum. This is worth watching on a busy table because the
benefit is invisible until it degrades.

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
