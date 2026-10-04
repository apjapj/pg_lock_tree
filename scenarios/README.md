# Scenario suite

Seven incidents, each built for real with `dblink`, then queried two ways:

1. **`pg_lock_tree`**, installed as an extension
2. **the published recursive CTE**, the `pg_blocking_pids()` lock-tree query that circulates
   as a PostgreSQL wiki entry and in a dozen blog posts, inlined in
   [`01_standard_query.sql`](01_standard_query.sql)

Same incident, same data, same moment. Both outputs are captured so they can be compared
without re-running anything.

```bash
make scenarios                      # all eight, output to scenarios/out/
./scenarios/run.sh s6 s7            # just those two
```

Needs a superuser connection and `dblink`. Every scenario cleans up after itself, and each
asserts its own shape before reporting, since a chain that silently failed to form is the main way
these could have produced flattering nonsense.

## The scenarios

| | scenario | what it is | where it should matter |
|---|---|---|---|
| 1 | `s1_nightly_batch` | one idle transaction, four waiters | the reference case; everything handles it |
| 2 | `s2_three_chains` | three unrelated incidents at once | separating interleaved queues |
| 3 | `s3_row_locks` | two `UPDATE`s on one row | a wait with **no relation** in `pg_locks` |
| 4 | `s4_wide_queue` | 60 sessions behind one culprit | whether the answer is readable at scale |
| 5 | `s5_mixed_locks` | two advisory locks, no relation | waits with nothing to name |
| 6 | `s6_deadlock` | two sessions blocked by each other | a cycle, which is not a queue |
| 7 | `s7_prepared` | a prepared transaction holding locks | a blocker that is **not a session** |
| 8 | `s8_many_roots` | five idle transactions, 30/18/10/5/3 waiters | a queue that is wide **and** has several heads |

## Results

Coverage: sessions genuinely waiting, and how many of them each approach reported.

| scenario | waiting | published CTE | pg_lock_tree |
|---|---|---|---|
| 1 nightly batch | 4 | 4 | 4 |
| 2 three chains | 4 | 4 | 4 |
| 3 row locks | 2 | 2 | 2 |
| 4 wide queue | 60 | 60 | 60 |
| 5 advisory locks | 2 | 2 | 2 |
| 6 deadlock | 2 | 2 | 2 |
| 7 prepared transaction | 2 | **0** | 2 |
| 8 many roots | 66 | 66 | 66 |

**Read that honestly: on plain coverage the two tie almost everywhere.** The differences are
not in finding sessions. They are these:

- **Scenario 7, the one that matters most.** A prepared transaction has no backend and no
  `pg_locks.pid`. The published query finds **nothing**. The waiters appear with no blocker at
  all, so the answer to "what is holding this?" is an empty set. `pg_lock_tree` attributes them
  to pid 0 and names the state.
- **Scenario 1: the published form times out.** Run verbatim it never returns. See below.
- **Scenario 6: 40 rows versus 2.** Both find the two sessions, but the published recursion has
  no cycle guard, so it walks the loop until a depth cap stops it and reports the same pid pair
  at depths 1 to 20 in both directions.
- **Scenarios 2, 3, 5: same coverage, more attribution.** Roots named by
  `application_name`, the blast radius per root, and a command to run, none of which the
  published query produces.
- **Scenario 4: readability.** Measured, not asserted: see below.

## The published query has a performance bug

Run verbatim, part 1 of `01_standard_query.sql` times out. Five blocked sessions is enough.
The published form omits `blocking_locks.granted`, so every ungranted lock joins with every
lock of the same identity, *including other waiters*. Each recursion level multiplies that, and
the row count grows geometrically with chain depth.

Part 2 adds the one missing line (`AND blocking_locks.granted`) and it works. That is what the
suite reports as "the published CTE" column. That is a fair comparison, since nobody should be
judged on a version they would not actually run, but the first attempt timing out is a real thing
that happens to people.

## Measured, not asserted

Scenario 4 renders the same 61-session tree both ways and reports the widths:

| | average line width |
|---|---|
| full names, default width | 111 |
| full names, roomier query column | 116 |
| abbreviated modes and states | 96 |

**17% narrower**, from `AccessExclusiveLock` → `AX` and `idle in transaction` → `idle-in-tx`.
That is a real saving and it is also modest; the compact interval (`1m30s`, not `00:01:30`)
helps more and applies to the unabbreviated form too, so it does not show up in that
comparison. The view itself is unchanged and always carries full names, so anything grepping
`AccessExclusiveLock` still works. Abbreviation is opt-in, in the text functions only.

## Why the coverage metric is the way it is

A session counts as reported if it appears in the output **and** is genuinely waiting.

Deliberately not "rows where `depth > 0`". In a deadlock both sessions are roots, so a
depth-based count scores `pg_lock_tree` at zero for correctly reporting both of them. That
number would be false, not flattering, and it was the first thing this suite produced.