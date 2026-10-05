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

## Backups

None of the three tables is registered for `pg_dump`, and that is a decision rather than an
oversight, with the reasoning and the opt-in in
[INSTALL.md](../INSTALL.md#backups-and-restores). The short version: a **physical** backup, a base
backup, a snapshot and a replica all copy the history whatever is registered, so redaction above is
the control that keeps credentials out of them, not the dump setting.
