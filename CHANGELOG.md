# Changelog

All notable changes to `pg_lock_tree` are recorded here. Versions follow the extension's
`default_version` in `pg_lock_tree.control`; `CREATE EXTENSION pg_lock_tree VERSION '0.7'`
selects a release.

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