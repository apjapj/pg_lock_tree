/* pg_lock_tree--1.1.8.sql
 *
 * 1.1.8 adds the read side of the cold tier: lock_tree_archive_find(), which searches the archive
 * and nothing else, and is the first shipped function to read lock_tree_history_archive. 1.1.6
 * shipped that table write-only.
 *
 * 1.1.7 closes two gaps 1.1.6 left open, and changes one function's OUTPUT rather than its values.
 * lock_tree_history_size() gains four columns reporting the archive; the eight it already had keep
 * their names, order, types and meaning, and the four are appended after them, so no existing caller
 * breaks. scripts/check-install.sh is fixed, not extended: it listed twenty objects while 1.1.4,
 * 1.1.5 and 1.1.6 added more, so it reported a healthy install as complete.
 *
 * 1.1.6 adds a cold tier: lock_tree_history_archive, indexed by BRIN and nothing else, and
 * lock_tree_archive() to move history into it in committed batches. It changes no existing function
 * and no existing result. See pg_lock_tree--1.1.5--1.1.6.sql for why the read functions were
 * deliberately left alone, which is the interesting part of this release.
 *
 * 1.1.5 bounds the waiter side of the root-to-waiter join in lock_tree_duration() and
 * lock_tree_duration_by_application(). Their output is identical for every argument, at every
 * window; what changes is how many rows they read. PostgreSQL does not carry a >= bound on the
 * root side across the equality on sampled_at, so the waiter side stayed inside the window only
 * when the planner picked a nested loop and probed it. It did not always. On PG18 with a 90-day
 * fixture, by_application() read 14,774,419 waiter rows to answer a 7-day question, 7,035 ms.
 * On PG14 with a 30-day fixture it read 4,924,819, 3,449 ms. With the bound, 1,148,664 and
 * 2,136 ms on the first, 1,148,835 and 2,377 ms on the second.
 *
 * 1.1.4 added lock_tree_deadlock_participants(), which names both participants of a deadlock for
 * the samples that caught one. It is a function and not a column on lock_tree_history, because
 * a column would be empty in nearly every row and an empty column on the hot table reads as
 * 'no deadlock happened'.
 *
 * Readable lock-wait trees for PostgreSQL 14+.
 *   lock_tree              view: every session in a blocking chain, root first
 *   lock_tree_roots()      the head-of-line blockers, with how many sessions wait on each
 *   lock_tree_text()       the same tree as indented text, for psql during an incident
 *   lock_tree_text_short() the same, with abbreviations, for when the queue is wide
 *   lock_tree_actions()    a written description of each blocker, with its blast radius
 *   lock_tree_command()    one runnable statement per blocker, for psql's \gexec
 *   lock_tree_history      table: sampled snapshots, for incidents that have already cleared
 *   lock_tree_sample()     take one snapshot. Call this on a schedule.
 *   lock_tree_incidents()  segment the history into incidents
 *   lock_tree_prune()      drop history older than a given age
 *   lock_tree_wide()       one row per root, for when the tree itself is too wide to read
 *   lock_tree_summary()    one row for the whole queue: sessions blocked, roots, deepest chain
 *   lock_tree_statements() per root: what pg_stat_statements knows about the blocking query
 *   lock_tree_notify()     raise a NOTIFY when a chain is bad enough to be worth waking someone
 *   lock_tree_alert()      table: what has already been alerted on, so it happens once
 *   lock_tree_sampling_advice()  a defensible sampling interval for the current load
 *   lock_tree_history_statements() per-query blocking time, from the sampled history
 *   root_object                what a prepared-transaction root is holding, since pid 0 is not
 *                              enough to tell two of them apart
 *   lock_tree_alert.max_waited_at  the longest wait at the last notification, so an incident that
 *                              is not growing wider still gets escalated as it ages
 *   lock_tree_deadlock       table: pg_stat_database.deadlocks sampled on its own beat, because
 *                             the counter moves whether or not anything is blocked
 *   lock_tree_deadlocks()    when deadlocks happened, which pg_stat_database cannot say
 *   lock_tree_deadlock_participants()  both participants, for the samples that caught one
 *   lock_tree_history_size() what the history costs and what it will cost tomorrow
 *   lock_tree_prune_batched()  prune in committed batches, so a large prune is not one long lock
 *   lock_tree_duration()     per-query BLOCKING TIME in seconds, which is not a sample count
 *   lock_tree_duration_by_application()  the same per application, which is not the same figure
 *   lock_tree_replay()      the tree as it was at a past sample, reconstructed from the history
 *   lock_tree_replay_samples (view)  one row per sample, for finding one worth replaying
 *   lock_tree_notify(resolved)  a "cleared" notification when a notified incident ends, so on-call
 *                             is not left wondering whether it is over yet
 *   lock_tree_history_archive  table: old history, moved out on a schedule so the hot table stays
 *                             small. A BRIN index and no b-trees; see the note on it.
 *   lock_tree_archive()       move history older than an age into the archive, in committed
 *                             batches, re-redacting the query text on the way across
 *
 * Only sessions waiting on a heavyweight lock (wait_event_type = 'Lock') are passed
 * to pg_blocking_pids(), because each call briefly takes the lock manager's shared
 * state. Sample this view every few seconds at most; never in a tight loop.
 *
 * A deadlock is reported as one depth-0 root per session in the cycle. There is no head
 * of the queue to point at, so lock_tree_roots() lists every session involved.
 *
 * 1.0.1 fixes the 1.0.0 redaction, scrubs the rows 1.0.0 left behind, and stops any role from
 * switching redaction off for itself.
 *
 * Three defects, all found by a review of 1.0.0 that ran the shipped function rather than reading
 * it, and all three in the feature 1.0.0 existed to deliver.
 *
 * 1.0.0's lock_tree_redact() missed a real SCRAM verifier passed to a function, which is
 *     SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey> and not the shape its own test fixture used.
 *     It also missed PASSWORD $$x$$, a password containing a newline, a statement cut off by
 *     track_activity_query_size before its closing quote, and U&'x' or a comment before the literal.
 *     The 1.0.0 notes claimed the pattern "cannot under-redact". It could.
 *
 * 1.0.0's update script changed how NEW rows are written and never touched the ones already there,
 *     so every password the history had ever caught sat in it until pruned. 1.0.1 scrubs them.
 *
 * 1.0.0's lock_tree_sample() is SECURITY DEFINER, executable by PUBLIC, and reads the redaction
 *     setting from the CALLER's session. Any role could therefore set the setting to full, call the
 *     sampler, and read another session's query text back out of the history, including a password.
 *     Reproduced on PostgreSQL 18 with a role holding only SELECT on the history. 1.0.1 revokes
 *     EXECUTE from PUBLIC.
 *
 * 1.0.0 stops the history from holding credentials.
 *
 * lock_tree_history keeps the first 300 characters of every blocked session's query. A blocked
 * `ALTER ROLE app PASSWORD '...'` is a blocked query, and before 1.0.0 it sat in that table in full
 * until it aged out, readable by anyone with SELECT on the history and copied into every backup.
 * lock_tree_sample() now runs the text through lock_tree_redact() first, and the default is to
 * redact. Redaction happens BEFORE the 300 character truncation, so a password beginning before the
 * cut is still caught.
 *
 * The setting is lock_tree.history_query, with three values, and an unrecognised one redacts rather
 * than leaks. Set it to 'full' to store the query verbatim, or 'none' to store NULL.
 *
 * 1.0 also fixes the four convergence defects that scripts/check-upgrade.sh found by comparing every
 * upgrade path against a fresh install. Three of the four were the FRESH install being wrong, which
 * is the worse direction: a fresh install had no comment on lock_tree_history.query_id, and every
 * upgraded database had one.
 *
 * 0.16 finishes what 0.15 started on the read side, closes a gap between the live tree and the
 * history, and documents the grants a monitoring role actually needs.
 *
 * An index, chosen by measurement rather than by taste. Three candidates were tried against the same
 * fixture and only one was kept:
 *
 *   no extra index                                    2000 ms   2634 ms
 *   (application_name, sampled_at) WHERE depth = 0     1651 ms   2002 ms   1888 kB
 *   (sampled_at)            WHERE depth = 0            1750 ms   2214 ms   1344 kB
 *   (root_pid, sampled_at)  WHERE depth > 0            1701 ms   2501 ms   9744 kB
 *
 * 17% and 24% on the whole-window duration reads for 0.7% of the table, and no measurable cost on
 * the write path because the partial predicate means one index entry per sample rather than twenty.
 *
 * query_id is now on the live view. Until 0.16 it was on lock_tree_replay() and not on lock_tree, so
 * the tree in front of you could not be joined to the history behind you on the one column both are
 * keyed by. Appending a column is the only change CREATE OR REPLACE VIEW permits, and that is exactly
 * what this is.
 *
 * The documented grants were incomplete. Eleven functions read lock_tree_history, and a monitoring
 * role set up exactly as INSTALL.md described could call none of them, while lock_tree_replay_samples
 * worked with no grant at all because a view runs with the definer's rights. That inconsistency is
 * now documented rather than left to be discovered, and test/20 pins it.
 *
 * 0.15 makes the read side stop reading the whole table, and stops replay doing it too.
 *
 * Fifteen window bounds on a stored column used clock_timestamp(). It is VOLATILE, and the planner
 * cannot make a volatile expression an index bound, so every one of them degraded from a seek into
 * a filter over the entire index. Measured on a seven day history of 1.2 million rows, 264 MB:
 *
 *     sampled_at >= clock_timestamp()     - interval '1 hour'
 *       Index Only Scan, Filter, 165740 rows removed,  18.5 ms
 *     sampled_at >= statement_timestamp() - interval '1 hour'
 *       Index Only Scan, Index Cond,                      0.777 ms
 *
 * The cost scaled with the size of the WHOLE history rather than with the window asked for, which
 * is the wrong way round for something a dashboard runs. statement_timestamp() is STABLE, so it
 * becomes an Index Cond, and it is constant for the statement, so there is no consistency argument
 * against it either.
 *
 * The three clock_timestamp() uses inside the live view are DELIBERATELY NOT CHANGED. They compute
 * wait_age, xact_age and state_age, which are genuinely per-row instants of "now", and replacing
 * those wholesale would be the obvious and wrong move.
 *
 * lock_tree_replay() found its sample by computing the distance to every row and sorting, which
 * cost 987 ms to replay a single sample out of 1.2 million. Two index seeks do it in 0.556 ms.
 *
 * Measured with scripts/bench-history.sh, which exists so the numbers above can be re-checked
 * instead of taken on trust.
 *
 * 0.14 lets you look at the tree an incident HAD, not only at how long it lasted.
 *
 * Everything above answers questions about the present or about totals. Once the queue has cleared,
 * lock_tree_duration() can say which application cost the most and lock_tree_incidents() can say when,
 * but neither can show you the SHAPE: sixty sessions behind one idle-in-transaction root at depth 3,
 * or five independent roots at once. That shape is the thing you remember three days later and cannot
 * get back, because it existed only in lock_tree_history and nothing rendered it.
 *
 * lock_tree_replay(at) renders it. The nearest sample to `at`, from the history, as the columns that
 * were recorded, in the same shape and the same indentation as the live tree.
 *
 * Nine columns of the live view are NOT here, and that is the honest part: path, blocked_by, usename,
 * datname, client_addr, wait_event_type, wait_event, xact_age and state_age were never recorded.
 * path in particular cannot be reconstructed, because the history stores one row per session and not
 * the edge between them, so there is no way to know which depth-1 session a depth-2 session was
 * actually behind. Inventing one would be worse than omitting it, so it is omitted.
 *
 * 0.13 fixes three columns 0.12 could not get right, and adds the aggregation a page actually
 * needs.
 *
 * A root's IDENTITY and the waits it CAUSED are on different rows. query_id is on the root row,
 * wait_age is on the waiter's, so the 0.12 aggregates, which grouped by query_id and read wait_age
 * off those same rows, could only ever be wrong:
 *
 *   longest_wait            always NULL, because the rows with a query_id have no wait on them
 *   blocked_sessions_peak   always 1, because there is one root row per query per sample
 *   sessions_total          that same 1 summed, so it repeated the sample count
 *
 * All three come out of one join: the root rows of a sample matched to the waiter rows of the SAME
 * sample on root_pid and root_object. Measured on a root blocking three sessions across three
 * samples, 0.12 reported blocked_sessions_peak = 1, sessions_total = 3 and longest_wait = NULL.
 *
 * lock_tree_duration_by_application() is not lock_tree_duration() summed by application, and the
 * difference is the whole point. Where an application hands the queue from one statement to another,
 * which is what a connection pool does, the per-query figures discard every gap that straddles the
 * handover and the per-application figure counts all of them. Summing the per-query numbers would
 * report near zero for an application that blocked forty sessions for ten minutes.
 *
 * 0.12 fixes the metric rather than the reporting. lock_tree_history_statements() counts blocked
 * SESSIONS PER SAMPLE, which is not a duration: sample twice as often over the same incident and it
 * doubles. Measured on a six second incident, three samples then six more:
 *
 *                    session-samples   gap-summed time
 *   3 samples / 6s            3          00:00:06
 *   + 6 more   / 6s           9          00:00:06
 *
 * One number tracked elapsed time and the other tracked observations. Ranking statements by a figure
 * that moves when you change your cron entry is ranking them by your cron entry.
 *
 *   slow_batch  4.226s over 5 samples        quick_batch  1.015s over 2 samples
 *
 * And on-call never learns an incident ended. lock_tree_notify() says when something starts getting
 * worse and stays silent afterwards, which was deliberate in 0.6 and is right for the pager. It is
 * wrong for the person who was woken up and now has no way to find out whether to go back to bed.
 * A resolution argument, off by default, sends one 'cleared' notification per root that had
 * notified and has since stopped. Default off, because whether an incident ending is worth a message
 * is a property of your rota and not of this extension.
 *
 * The gap sum is also a measurement rather than an interpolation: each gap is bounded by two
 * instants at which this query WAS the root, so the statement demonstrably held the queue up for
 * the whole of it. A gap where the root changed is discarded, not guessed at.
 *
 * lock_tree_history_statements() is unchanged and still there. It is the cheaper question, it needs
 * no gap arithmetic, and for "which query blocks the most sessions" it is the right answer.
 *
 * 0.11 adds the two things that were wanted when partitioning lock_tree_history was first
 * proposed, because partitioning turned out not to be available and the problem it was meant to
 * solve is real.
 *
 * It is not available, and that was measured rather than assumed. PostgreSQL has no ALTER TABLE ...
 * SET PARTITIONED BY: conversion means creating a new partitioned table, copying, and swapping. And
 * the swap cannot be done from outside the extension, because lock_tree_history is a member:
 *
 *   DROP TABLE lock_tree_history
 *   ERROR:  cannot drop table lock_tree_history because extension pg_lock_tree requires it
 *
 * The same restriction that applies to the view. The only place DROP TABLE is permitted is inside an
 * extension update script, which means the copy would happen unattended during
 * ALTER EXTENSION ... UPDATE, on however many rows the user happens to have, holding whatever locks
 * that takes. That is not a change to make on someone's behalf in a script they did not write, so
 * it is not offered. The README says what to do instead.
 *
 * What replaces it addresses the actual problem, which is that lock_tree_prune() is one big DELETE:
 * it takes a long time, holds its locks for all of it, and bloats the table behind itself. So:
 *
 *   lock_tree_history_size()   what the history costs now, and what it will cost at this rate
 *   lock_tree_prune_batched()  the same prune in committed batches, so no single lock is held for
 *                              the whole of it
 *
 * lock_tree_prune() is unchanged and still there. A batched prune that cannot be interrupted is
 * worse than an unbatched one in some situations, and the procedure is opt-in.
 *
 * 0.10 adds deadlocks, and makes the sampling advice look at history rather than at the instant.
 *
 * Deadlocks were the largest thing this extension could see happening and said nothing about. The
 * counter has been in pg_stat_database since 13, so it is available on every version supported
 * here, verified rather than assumed. It names no participants: the two processes and their
 * statements exist only in the server log, and pretending otherwise would be worse than saying so.
 * What this release gives is the timing, which is the half that makes the log worth reading.
 *
 * The counter lives in its own one-row-per-sample table rather than in lock_tree_history, and that
 * is not tidiness. lock_tree_history only has rows while something is blocked, so a deadlock between
 * two samples, or one that cleared before the next tick, would leave no row and no trace. The whole
 * point is to notice deadlocks that did not happen to be visible when the sampler looked.
 *
 * Sampling advice now reads the history instead of the instant. A server sampled at 3am on a quiet
 * Sunday was quiet by accident; the interesting question is what happened during the busy hour, and
 * the history is where that is written down.
 *
 * 0.9 closed a gap in the alerting added in 0.6: escalation watched how many sessions a root
 * blocked and how deep the chain was, but not how long anyone had been waiting. A chain that sat
 * at forty blocked sessions while the longest wait went from five minutes to thirty never notified
 * again, which is not an edge case but the ordinary shape of an incident that is getting worse.
 *
 * The fix is one column and one comparison, and the interesting part is what it is NOT. A wait
 * grows continuously, so "is the longest wait longer than last time" is true on every sample and
 * would notify sixty times an hour, which is exactly the noise 0.6 was built to avoid. So the
 * comparison is against the wait recorded at the last notification and escalates only once the
 * wait has DOUBLEDE: notify at thirty seconds, then a minute, two, four, eight. Seven
 * notifications for a thirty-two minute incident, each one saying it is about twice as bad as the
 * last. That is the same reasoning as exponential backoff, applied to whether to wake someone.
 *
 * It is gated on min_wait being set, because someone who passes min_wait => NULL has said they do
 * not want to be paged on wait age, and a second page for a slow queue they did not ask about is
 * exactly the behaviour that trains people to ignore a channel.
 *
 * Alerting is the missing half of history: history records what happened, but nothing tells
 * anyone it is happening now. lock_tree_notify() raises a NOTIFY on a channel when a chain is
 * bad enough by thresholds you choose, and lock_tree_alert remembers what has been alerted on
 * so the same incident notifies once rather than on every sample.
 *
 * The thresholds are arguments rather than settings, deliberately. A false alarm from a
 * diagnostic tool is worse than no alarm, so the numbers belong to whoever is on call rather than
 * to a default buried in the extension. NULL disables a criterion.
 *
 * lock_tree_text_short() made a wide queue narrower by abbreviating. That helps at sixty
 * sessions and stops helping at six hundred: the shape is still sixty or six hundred lines,
 * and the question "which of my five blockers is the worst one" still needs every line
 * read to be answered. lock_tree_wide() aggregates to one row per root instead, and
 * lock_tree_summary() to a single row for the whole queue.
 *
 * History remains opt-in and stays empty until you schedule lock_tree_sample(). Nothing here
 * runs by itself, and the extension still needs no shared_preload_libraries: pg_cron is one
 * convenient way to schedule the sample, not a requirement of it.
 *
 * One change from 1.0.1, and it is a sentence rather than a behaviour. The reason
 * lock_tree_sampling_advice() returns for a quiet database said "so sample rarely" while
 * returning 00:00:05, the finest interval it offers. Nothing was blocked, so the interval was
 * right and the wording contradicted it. The wording now says what the 5 seconds buys. No
 * signature, column, grant or return value changes; pg_lock_tree--1.0.1--1.0.2.sql is the
 * whole upgrade.
 *
 * Two changes from 1.0.2, both measured before they were written and neither a change to what
 * any function returns for the arguments it already accepted.
 *
 * 1. lock_tree_incidents() takes a window. It was the only history function that could not be
 *    bounded in time, so its cost followed how much history was retained rather than how much
 *    of it was being asked about, and there was no way to ask it about less. The parameter goes
 *    after max_gap so positional callers are unaffected, and defaults to NULL so an existing
 *    call returns exactly what it returned before.
 *
 *    Corrected in 1.1.3. This note previously read "Measured at 1.95 us per row as a caller
 *    uses it, which is 1.2 seconds per million rows: a month of history is about 30
 *    seconds", and that projection was wrong by about 2.8 times. The per-row measurement was
 *    sound but had been taken with all three array columns present and then multiplied by
 *    three again when projecting, as though it covered one column rather than all of them.
 *
 *    The corrected figure is 1.55 us per row as a caller uses it, which is 1.55 seconds per
 *    million rows: a month of history is about 9 seconds, a year about 110. Measured cold,
 *    best of three, on the fixture scripts/bench-history.sh builds with one sample every
 *    10 seconds and 20 blocked sessions per sample. The full table, for all three history
 *    functions at four retention levels, is in docs/history.md.
 *
 *    Left uncorrected it was discouraging in exactly the case it was written to inform: it
 *    put a month of history at half a minute when it is nearer a tenth of one. Note also that
 *    SELECT count(*) on this function is about eight times cheaper, at 0.20 us per row,
 *    because the planner drops all three array columns. If you have timed this function with
 *    count(*) you have measured something the documentation never claimed.
 *
 * 2. lock_tree_history_application_idx gains INCLUDE (query_id). See the index for the numbers.
 *
 * Everything else is byte-identical to 1.0.2.
 *
 * 1.1.1 changed no SQL; it was documentation and release tooling.
 *
 * One change from 1.1.1. lock_tree_incidents() took the DISTINCT inside array_agg, which sorts every
 * row in the incident's range to emit a handful of values, and on the standard seven-day fixture that
 * sort spilled to disk three times, once per array column. It now takes the DISTINCT in a subquery
 * first, which the planner satisfies with a hash aggregate, and sorts only the distinct values. Same
 * rows, same arrays, same NULL handling; measured in the release notes. Everything else is
 * byte-identical to 1.1.1.
 *
 * 1.1.3 changed no SQL. It corrects the projection in item 1 above, which contradicted
 * docs/history.md inside the same release, and it adds the test that pins the NULL asymmetry
 * between the applications and root_objects array columns of lock_tree_incidents(). That
 * asymmetry was described in the 1.1.2 notes and asserted nowhere, so it could have changed
 * without anything noticing. test/07_history.sql now asserts it in both directions: filtering
 * NULL out of applications fails the suite, and so does keeping NULL in root_objects.
 * Everything else is byte-identical to 1.1.2.
 */

\echo Use "CREATE EXTENSION pg_lock_tree" to load this file. \quit

DO $check$
BEGIN
  IF current_setting('server_version_num')::int < 140000 THEN
    -- Stated at the length someone hitting it will actually want, because "unsupported" on
    -- its own tells them nothing about whether it is worth patching.
    RAISE EXCEPTION
      'pg_lock_tree needs PostgreSQL 14 or later. It reports wait age from pg_locks.waitstart, '
      'which PostgreSQL added in 14; every other query here works on 9.6 and later, so on an '
      'older server this would run with wait_age and longest_wait reporting NULL. This build '
      'refuses rather than handing back columns that are quietly empty.';
  END IF;
END
$check$;

CREATE VIEW @extschema@.lock_tree AS
WITH RECURSIVE
act AS (
  SELECT a.pid,
         a.usename::text           AS usename,
         a.datname::text           AS datname,
         a.application_name,
         a.client_addr,
         a.state,
         a.wait_event_type,
         a.wait_event,
         a.xact_start,
         a.state_change,
         a.query,
         -- Appended in 0.16 so the final SELECT can carry it. pg_stat_activity has carried query_id
         -- since PostgreSQL 14, which is this extension's floor, so there is no version guard to
         -- write here and therefore none.
         a.query_id,
         CASE WHEN a.wait_event_type = 'Lock'
              THEN pg_blocking_pids(a.pid)
              ELSE '{}'::int[] END AS blocked_by
  FROM pg_stat_activity a
  WHERE a.pid IS NOT NULL
),
prep AS (                       -- what prepared transactions are holding
  -- pg_locks reports a prepared transaction's locks with pid NULL and granted true. That is the
  -- only handle there is on it: there is no gid to join to, and pg_blocking_pids() has already
  -- flattened every prepared blocker to 0. So the lock itself is the identity.
  --
  -- Grouped by the lock OBJECT, locktype plus everything that says which thing is locked, and not
  -- by the mode. Two prepared transactions holding different modes on one relation are one root,
  -- because a waiter wanting an AccessExclusiveLock on it cannot be attributed to either of them
  -- and PostgreSQL itself does not distinguish them. Grouping by mode would report two roots and
  -- count the same waiter against both.
  SELECT min(mode) AS mode, locktype, database, relation, page, tuple,
         classid, objid, objsubid, virtualxid, transactionid
  FROM pg_locks
  WHERE pid IS NULL AND granted
  GROUP BY 2,3,4,5,6,7,8,9,10,11
),
prep_edge AS (                  -- waiters blocked by a prepared transaction, and what they want
  SELECT DISTINCT w.pid AS blocked, p.*
  FROM act a
  JOIN pg_locks w ON w.pid = a.pid AND NOT w.granted
  JOIN prep p
    ON  p.locktype       =  w.locktype
    AND p.database    IS NOT DISTINCT FROM  w.database
    AND p.relation    IS NOT DISTINCT FROM  w.relation
    AND p.page        IS NOT DISTINCT FROM  w.page
    AND p.tuple       IS NOT DISTINCT FROM  w.tuple
    AND p.classid     IS NOT DISTINCT FROM  w.classid
    AND p.objid       IS NOT DISTINCT FROM  w.objid
    AND p.objsubid    IS NOT DISTINCT FROM  w.objsubid
    AND p.virtualxid  IS NOT DISTINCT FROM  w.virtualxid
    AND p.transactionid IS NOT DISTINCT FROM w.transactionid
  WHERE a.blocked_by = ARRAY[0]::int[]
),
edge AS (                       -- one row per (blocked, blocker) pair, with the object if any
  -- A session blocker. The object is NULL because root_pid already identifies it.
  SELECT a.pid AS blocked, b AS blocker, NULL::text AS object
  FROM act a, unnest(a.blocked_by) AS b
  WHERE b <> 0
  UNION ALL
  -- A prepared blocker, attributed to the object it holds.
  -- Always schema-qualified, deliberately. relation::regclass::text would be shorter, but it
  -- qualifies only when the schema is not in the search_path, so the same lock renders as "z1" in
  -- one session and "public.z1" in another. root_object is half of lock_tree_alert's primary key,
  -- and a value that changes with search_path would make an alert fire again for an incident it
  -- had already reported. An identity has to be stable; the cost is one extra word in the output.
  -- waiting_for in this view still uses regclass and is still path dependent, which is cosmetic
  -- there because nothing keys on it.
  SELECT pe.blocked, 0, coalesce(
           CASE
             WHEN pe.relation IS NOT NULL
                  AND pe.database = (SELECT oid FROM pg_database WHERE datname = current_database())
               THEN pe.mode || ' on ' || coalesce(
                      (SELECT n.nspname || '.' || c.relname
                         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                        WHERE c.oid = pe.relation),
                      pe.relation::text)
             WHEN pe.relation IS NOT NULL
               THEN pe.mode || ' on relation ' || pe.relation || ' in database ' || pe.database
             ELSE pe.mode || ' on ' || pe.locktype
           END, 'a prepared transaction')
  FROM prep_edge pe
  UNION ALL
  -- A waiter blocked by a prepared transaction whose held lock could not be matched: the relation
  -- was dropped, or it belongs to a database whose regclass cannot resolve here. Without this
  -- branch the waiter would have no edge at all and would vanish from the tree, which is a much
  -- worse failure than being reported with a root nobody can tell apart.
  SELECT a.pid, 0, NULL::text
  FROM act a
  WHERE a.blocked_by = ARRAY[0]::int[]
    AND NOT EXISTS (SELECT 1 FROM prep_edge pe WHERE pe.blocked = a.pid)
),
seed AS (                       -- every blocker can head a chain...
  -- DISTINCT over the pair, not the pid. A prepared blocker is (0, <object>), so two prepared
  -- transactions holding different objects are two seeds, which is the whole point of the fix.
  SELECT DISTINCT e.blocker AS pid, e.object
  FROM edge e
),
root AS (                       -- ...but only an unblocked blocker is a real head of the queue;
  SELECT s.pid, s.object        -- pid 0 is not in pg_stat_activity, so a prepared transaction
  FROM seed s                   -- (which holds its locks until COMMIT PREPARED) qualifies here
  LEFT JOIN act a ON a.pid = s.pid
  WHERE a.pid IS NULL OR cardinality(a.blocked_by) = 0
),
walk AS (
  -- Seeding from every blocker, not just the unblocked ones, means a component with no
  -- unblocked blocker at all (a deadlock: everybody in it waits on somebody else in it)
  -- is still reported, as one depth-0 root per member, instead of vanishing. Rooting from
  -- the unblocked blockers alone would drop the whole component, because the cycle has no
  -- head. `rooted` records whether this chain descends from a real head of the queue.
  SELECT s.pid, s.pid AS root_pid, s.object AS root_object, 0 AS depth, ARRAY[s.pid] AS path,
         (r.pid IS NOT NULL) AS rooted
  FROM seed s
  LEFT JOIN root r ON r.pid = s.pid AND r.object IS NOT DISTINCT FROM s.object
  UNION ALL
  SELECT e.blocked, w.root_pid, w.root_object, w.depth + 1, w.path || e.blocked, w.rooted
  FROM walk w
  JOIN edge e ON e.blocker = w.pid
  -- A prepared chain may only pick up the waiters of its own prepared root, matched on the object,
  -- or every prepared chain would pick up every prepared waiter's chain. A session chain takes the
  -- objectless edges, which are all of the session edges.
  WHERE ((w.root_object IS NULL     AND e.object IS NULL)
      OR (w.root_object IS NOT NULL AND e.object = w.root_object))
    AND e.blocked <> ALL (w.path)          -- guard against transient wait-for cycles
),
ranked AS (                    -- rank the chains each session appears in
  SELECT w.*,
         row_number() OVER (PARTITION BY w.pid
                            ORDER BY w.rooted DESC, (w.root_pid = w.pid) DESC,
                                     w.depth DESC, w.path) AS rn
  FROM walk w
),
placed AS (                     -- a waiter can sit behind several blockers: keep its deepest chain
  SELECT pid, root_pid, root_object, depth, path
  FROM ranked
  -- One row per session: a waiter behind several blockers lands in its deepest chain and nowhere
  -- else. The exception is pid 0, which is not a session. Every prepared-transaction root shares
  -- it, because pg_blocking_pids() reports them all as 0, so partitioning on pid alone collapsed
  -- them into whichever sorted first, and the merged root claimed the sum of their wait counts.
  -- That was the bug this column exists to fix, and it was in this line rather than in the walk.
  --
  -- pid 0 only ever appears at depth 0, since edge.blocked comes from pg_stat_activity and those
  -- pids are never 0, so exempting it cannot duplicate a real session.
  WHERE rn = 1 OR pid = 0
),
waiting AS (                    -- a backend waits for at most one heavyweight lock at a time
  SELECT DISTINCT ON (l.pid)
         l.pid,
         l.mode,
         l.locktype,
         l.waitstart,
         CASE
           WHEN l.relation IS NULL THEN NULL
           WHEN l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
             THEN l.relation::regclass::text
           ELSE 'relation ' || l.relation || ' in database ' || l.database   -- regclass only resolves in this database
         END AS relation
  FROM pg_locks l
  WHERE NOT l.granted
  ORDER BY l.pid, l.waitstart NULLS LAST
)
SELECT p.root_pid,
       p.depth,
       p.path,
       p.pid,
       coalesce(a.blocked_by, '{}'::int[])                                 AS blocked_by,
       coalesce(a.state, CASE WHEN p.pid = 0
                              THEN 'prepared transaction (see pg_prepared_xacts)'
                              ELSE 'exited' END)                           AS state,
       a.usename,
       a.datname,
       a.application_name,
       a.client_addr,
       a.wait_event_type,
       a.wait_event,
       CASE WHEN w.pid IS NULL THEN NULL
            ELSE w.mode || ' on ' || coalesce(w.relation, w.locktype) END   AS waiting_for,
       date_trunc('second', clock_timestamp() - w.waitstart)               AS wait_age,
       date_trunc('second', clock_timestamp() - a.xact_start)              AS xact_age,
       date_trunc('second', clock_timestamp() - a.state_change)            AS state_age,
       a.query,
       -- Appended in 0.8, and NULL for a session root on purpose: root_pid identifies that one
       -- already, and leaving the column NULL there says so rather than padding it. For a
       -- prepared-transaction root this is the lock it is holding, which is the only thing that
       -- tells two of them apart.
       p.root_object,
      -- Appended in 0.16, and for the same reason as root_object: appending is the only change a
      -- view may make to itself, since CREATE OR REPLACE VIEW cannot drop or reorder a column.
      --
      -- Without it the live tree cannot be joined to lock_tree_history on query_id, and query_id is
      -- what the whole duration family is keyed on, so the two halves of the extension could not be
      -- tied together in one query. lock_tree_replay() has carried this since 0.14 and its changelog
      -- entry noted the asymmetry rather than fixing it.
      --
      -- NULL for a waiter, always, and that is not an omission: a query blocked on a lock has no
      -- query_id for as long as it is blocked and only gains one when it completes. The root is the
      -- opposite and always has one. Same rule the history follows, so the two line up.
       a.query_id
FROM placed p
LEFT JOIN act a   ON a.pid = p.pid
LEFT JOIN waiting w ON w.pid = p.pid
ORDER BY p.root_pid, p.root_object NULLS FIRST, p.path;

COMMENT ON VIEW @extschema@.lock_tree IS
  'Sessions in lock-wait chains. depth 0 = root blocker; path = chain from the root. '
  'Names are unabbreviated; see lock_tree_text_short() for a compact rendering. '
  'Needs pg_read_all_stats (or superuser) to see other users'' queries.';


CREATE FUNCTION @extschema@.lock_tree_roots()
RETURNS TABLE (
  root_pid          int,
  -- Beside root_pid, which is the only place it can go: the two are one identity, and a session
  -- root has this NULL while a prepared-transaction root has the lock it is holding.
  root_object       text,
  state             text,
  usename           text,
  datname           text,
  application_name  text,
  xact_age          interval,
  state_age         interval,
  blocked_sessions  bigint,
  max_depth         int,
  longest_wait      interval,
  query             text,
  suggested_action  text
)
LANGUAGE sql STABLE
AS $$
  SELECT r.pid,
         r.root_object,
         r.state,
         r.usename,
         r.datname,
         r.application_name,
         r.xact_age,
         r.state_age,
         count(t.pid) FILTER (WHERE t.depth > 0),
         max(t.depth),
         max(t.wait_age),
         r.query,
         CASE
           -- pid 0 is a prepared transaction. It has no backend, so cancel and terminate are
           -- both no-ops on it: pg_cancel_backend(0) returns false and warns that PID 0 is
           -- not a PostgreSQL backend process. The only thing that clears it is ROLLBACK
           -- PREPARED, and the gid is not reachable from here, so name the catalog instead.
           WHEN r.pid = 0
             THEN 'Prepared transaction holding '
                  || coalesce(r.root_object, 'an unidentified object')
                  || ': it has no backend, so cancelling or terminating it does nothing. Run '
                  || 'SELECT gid FROM pg_prepared_xacts, then ROLLBACK PREPARED ''<gid''.'
           -- Never hand the operator a command that kills the session they are typing in.
           WHEN r.pid = pg_backend_pid()
             THEN 'This is your own session, so there is nothing to terminate. Re-run from '
                  || 'another connection.'
           WHEN r.state LIKE 'idle in transaction%'
             THEN format('Idle in an open transaction. SELECT pg_terminate_backend(%s);', r.pid)
           ELSE format('Try SELECT pg_cancel_backend(%s); then pg_terminate_backend(%s) if it does not clear.',
                       r.pid, r.pid)
         END
  -- Both sides of the join carry root_object, because it is part of the root's identity. Joining
  -- on pid alone put every prepared root against every prepared waiter, so two of them summed
  -- into one row claiming the combined wait count.
  FROM @extschema@.lock_tree r
  JOIN @extschema@.lock_tree t
    ON t.root_pid = r.pid AND t.root_object IS NOT DISTINCT FROM r.root_object
  WHERE r.depth = 0
  GROUP BY r.pid, r.state, r.usename, r.datname, r.application_name,
           r.xact_age, r.state_age, r.query, r.root_object
  ORDER BY count(t.pid) DESC, r.pid, r.root_object
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_roots() IS
  'Head-of-line blockers, most sessions blocked first, with a suggested next step.';


--------------------------------------------------------------------------------
-- formatting helpers
--------------------------------------------------------------------------------

-- 00:01:30 -> 1m30s. An eight-character timestamp eats a third of a tree line and tells
-- you less than "1m30s" does at a glance, especially when the interesting question is
-- "is this three seconds or three minutes".
CREATE FUNCTION @extschema@.lock_tree_age(i interval)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
           WHEN i IS NULL THEN '-'
           WHEN i < interval '1 minute' THEN format('%ss', trunc(extract(epoch FROM i))::int)
           WHEN i < interval '1 hour'   THEN format('%sm%ss',
                                              trunc(extract(epoch FROM i)::numeric / 60)::int,
                                              trunc(extract(epoch FROM i)::int)::int % 60)
           ELSE format('%sh%sm', trunc(extract(epoch FROM i)::numeric / 3600)::int,
                                        trunc(extract(epoch FROM i)::numeric / 60)::int % 60)
         END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_age(interval) IS
  'Compact interval rendering: 4s, 1m30s, 2h05m. Null becomes ''-''.';


-- The conventional abbreviations for the table-level lock modes, so a wide tree does not
-- spend 19 characters per line repeating "AccessExclusiveLock". Advisory and internal
-- locktypes have no standard short form, so they pass through unchanged.
CREATE FUNCTION @extschema@.lock_tree_mode_short(mode text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE mode
           WHEN 'AccessShareLock'           THEN 'AS'
           WHEN 'RowShareLock'              THEN 'RS'
           WHEN 'RowExclusiveLock'          THEN 'RX'
           WHEN 'ShareUpdateExclusiveLock'  THEN 'SUE'
           WHEN 'ShareLock'                 THEN 'S'
           WHEN 'ShareRowExclusiveLock'     THEN 'SRX'
           WHEN 'ExclusiveLock'             THEN 'E'
           WHEN 'AccessExclusiveLock'       THEN 'AX'
           ELSE mode
         END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_mode_short(text) IS
  'Abbreviate a lock mode (AX for AccessExclusiveLock). Unknown modes pass through.';


CREATE FUNCTION @extschema@.lock_tree_state_short(s text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE s
           WHEN 'idle in transaction (aborted)' THEN 'idle-in-tx (abort)'
           WHEN 'idle in transaction'           THEN 'idle-in-tx'
           ELSE s
         END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_state_short(text) IS
  'Abbreviate a session state (idle-in-tx for idle in transaction). Other states unchanged.';


-- The one renderer both text functions use. `short` switches on the abbreviations above.
-- The suggestion is deliberately NOT part of a tree line: with dozens of blocked sessions
-- the tree is already wide, and a ready-made command on every line buries the structure.
-- lock_tree_actions() emits those commands separately, once per root.
CREATE FUNCTION @extschema@.lock_tree_lines(query_width int, short boolean)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  SELECT CASE WHEN depth = 0
           -- A prepared-transaction root is pid 0, which says nothing on its own and repeats on
           -- every prepared root. The object is what distinguishes them, so it goes beside the pid
           -- in parentheses rather than in a column of its own, which would reflow every other
           -- line of the output.
           THEN format('%s%s  %s  %s  %s  %s',
                       pid,
                       CASE WHEN root_object IS NULL THEN ''
                            ELSE format(' (%s)', root_object) END,
                       CASE WHEN short THEN @extschema@.lock_tree_state_short(state) ELSE state END,
                       @extschema@.lock_tree_age(xact_age),
                       coalesce(nullif(application_name, ''), coalesce(usename, '?')),
                       left(regexp_replace(coalesce(query, ''), '\s+', ' ', 'g'), query_width))
           ELSE format('%s%s  %s  %s  %s  %s',
                       repeat('  ', depth - 1) || '└─',
                       pid,
                       @extschema@.lock_tree_age(wait_age),
                       CASE WHEN short
                            THEN coalesce(@extschema@.lock_tree_mode_short(split_part(waiting_for, ' ', 1)), '?')
                                  || ' ' || coalesce(split_part(waiting_for, ' on ', 2), '')
                            ELSE 'for ' || coalesce(waiting_for, wait_event) END,
                       coalesce(wait_event, '-'),
                       left(regexp_replace(coalesce(query, ''), '\s+', ' ', 'g'), query_width))
         END
  FROM @extschema@.lock_tree
  ORDER BY root_pid, path
$$;


COMMENT ON FUNCTION @extschema@.lock_tree_lines(int, boolean) IS
  'The renderer behind lock_tree_text() and lock_tree_text_short(). Exposed so the width '
  'comparison in scenarios/s4 can attribute the saving to each abbreviation separately.';


CREATE FUNCTION @extschema@.lock_tree_text(query_width int DEFAULT 60)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$ SELECT @extschema@.lock_tree_lines(query_width, false) $$;

COMMENT ON FUNCTION @extschema@.lock_tree_text(int) IS
  'The lock tree as indented text lines, for reading in psql. Full unabbreviated names.';


CREATE FUNCTION @extschema@.lock_tree_text_short(query_width int DEFAULT 100)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$ SELECT @extschema@.lock_tree_lines(query_width, true) $$;

COMMENT ON FUNCTION @extschema@.lock_tree_text_short(int) IS
  'As lock_tree_text(), but with abbreviated lock modes (AX), session states (idle-in-tx) '
  'and compact intervals (1m30s). Meant for a wide queue where every column counts; the '
  'default query_width is larger because the abbreviations gave the room back.';


--------------------------------------------------------------------------------
-- actions: a description, and separately the statements to run
--------------------------------------------------------------------------------

-- Two functions, one job each, and deliberately not combined.
--
-- 0.2 returned a single block that carried a command fragment inside a SQL comment. That was
-- a false promise in both directions: every line began with "--", so pasting a line did
-- nothing at all and still exited 0, while extracting just the fragment gave
-- "syntax error at or near pg_terminate_backend", because a bare function call is not a
-- statement. A trailing semicolon told the reader the line was runnable when it was inert.
--
-- The fix is not to add "SELECT" and make the block executable. A block of real statements
-- means a paste runs every root at once, unreviewed, which is the accident this was avoiding
-- in the first place. So: description here, statements over there, and nothing that looks like
-- one while being the other.

-- The description. Never imitates code, so a semicolon here would be a lie about runnability.
-- SET lock_tree.actions = off turns the whole thing off for a session, for anyone who reads
-- the tree and wants the roots as columns (lock_tree_roots()) rather than as prose. This is a
-- placeholder GUC: a pure-SQL extension can read and test one without declaring it, and
-- current_setting() returns NULL until something sets it. RESET leaves an empty string
-- rather than NULL, hence the nullif().
CREATE FUNCTION @extschema@.lock_tree_actions()
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  WITH r AS (
    SELECT root_pid, state, application_name, usename,
           blocked_sessions, max_depth, longest_wait
    FROM @extschema@.lock_tree_roots()
  ), numbered AS (
    SELECT row_number() OVER (ORDER BY blocked_sessions DESC, root_pid) AS n, r.*
    FROM r
  ), lines AS (
    -- sort 0 = header, 1..n = one description per root, 2..3 = footer, so it reads top to
    -- bottom. The column is named `body` throughout: `line` is a reserved word in SQL and
    -- cannot be used as a column alias here.
    SELECT 0 AS ord, 0 AS seq,
           format('-- %s root blocker(s). Most sessions unblocked first.', count(*)) AS body
    FROM numbered
    UNION ALL
    SELECT 1, n,
           format('-- %s. %s: %s, blocks %s session(s), chain depth %s%s',
                  n,
                  coalesce(nullif(application_name, ''),
                           coalesce(nullif(usename, ''), 'pid ' || root_pid)),
                  CASE WHEN root_pid = 0
                       THEN 'prepared transaction, no backend to act on'
                       ELSE state END,
                  blocked_sessions,
                  max_depth,
                  CASE WHEN longest_wait IS NOT NULL
                       THEN format(', longest wait %s', @extschema@.lock_tree_age(longest_wait))
                       ELSE '' END)
    FROM numbered
    UNION ALL
    SELECT 2, 0,
           '-- Descriptions, not commands. Every line here is a comment. For statements you '
           || 'can run: SELECT command FROM lock_tree_command().'
    WHERE EXISTS (SELECT 1 FROM numbered)
    UNION ALL
    SELECT 3, 0,
           '-- Terminating a session rolls back its transaction. Re-run the tree afterwards.'
    WHERE EXISTS (SELECT 1 FROM numbered)
  ), filtered AS (
    -- No output row may be NULL: psql renders NULL as an empty line, which would put gaps in
    -- the middle of the block. Only the first header row survives.
    SELECT row_number() OVER (ORDER BY ord, seq) AS final,
           CASE WHEN ord = 0 AND row_number() OVER (ORDER BY ord, seq) > 1
                THEN NULL ELSE body END AS body
    FROM lines
  )
  SELECT coalesce(body, '')
  FROM filtered
  WHERE body IS NOT NULL
    AND lower(coalesce(nullif(current_setting('lock_tree.actions', true), ''), 'on'))
        NOT IN ('off', 'false', 'no', '0')
  ORDER BY final
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_actions() IS
  'A written description of each root blocker and its blast radius, ordered by how many '
  'sessions each one unblocks. Every line is a SQL comment: this describes, it does not run. '
  'Use lock_tree_command() for statements you can execute. SET lock_tree.actions = off '
  'suppresses it entirely, for anyone who prefers the columns in lock_tree_roots().';


-- The statements. One column, one runnable statement per row, no prose and no comments, so it
-- is equally usable four ways: read it and type one line, hand it to \gexec, \copy it to a
-- file, or feed it to another tool.
--
-- Always the least destructive step that can work. An idle-in-transaction blocker is not doing
-- anything a cancel could interrupt, so cancelling it would achieve nothing and terminate is
-- the real remedy. Anything else gets pg_cancel_backend() first, and promoting that to a
-- terminate stays a decision the operator makes, with lock_tree_roots() spelling out both.
--
-- Two kinds of root produce no row, on purpose:
--   pid 0, a prepared transaction. It has no backend to act on, and the statement that would
--     clear it (ROLLBACK PREPARED) needs a gid this extension cannot see. Silently emitting
--     pg_cancel_backend(0) would look like a fix and do nothing.
--   your own pid. An operator must not be handed the means to disconnect themselves mid-query.
-- lock_tree_roots() covers both cases in suggested_action, and lock_tree_actions() says so.
CREATE FUNCTION @extschema@.lock_tree_command()
RETURNS TABLE (command text)
LANGUAGE sql STABLE
AS $$
  SELECT format('SELECT %s(%s);',
                CASE WHEN state LIKE 'idle in transaction%'
                     THEN 'pg_terminate_backend' ELSE 'pg_cancel_backend' END,
                root_pid)
  FROM @extschema@.lock_tree_roots()
  WHERE root_pid <> 0
    AND root_pid <> pg_backend_pid()
  ORDER BY blocked_sessions DESC, root_pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_command() IS
  'One executable statement per root blocker, ordered by how many sessions each unblocks: '
  'pg_terminate_backend() for an idle-in-transaction blocker, pg_cancel_backend() for anything '
  'else. Intended for psql: SELECT command FROM lock_tree_command() \gexec. Excludes '
  'prepared transactions, which have no backend, and your own session.';


--------------------------------------------------------------------------------
-- deadlocks
--------------------------------------------------------------------------------

-- pg_stat_database.deadlocks, sampled. It is a cumulative counter with no attribution: it says how
-- many deadlocks this database has had, and nothing at all about which two statements caused them.
-- That is not a gap this extension can close from SQL, because the participants exist only in the
-- server log. What it CAN close is the timing, and timing is what turns a log line into an
-- investigation.
--
-- One row per sample, written whether or not anything is blocked. Deliberately NOT a column on
-- lock_tree_history: that table has rows only while something is blocked, so a deadlock that
-- happened between two samples, or one that cleared before the next tick, would leave nothing
-- behind. Sampling the counter on its own beat is the only way to catch those.
--
-- The table grows by one row per sample, which at a five second interval is 17,000 a day and about
-- 8 MB a month. lock_tree_prune() clears it along with the history, so there is one thing to
-- remember rather than two.
CREATE TABLE @extschema@.lock_tree_deadlock (
  sampled_at     timestamptz NOT NULL DEFAULT statement_timestamp(),
  deadlocks      bigint      NOT NULL,
  -- deadlocks minus the previous sample, floored at zero. Computed once, at insert, and stored, so
  -- that reading the timeline later does not depend on which rows happen to still be present.
  -- Flooring matters because the counter can go BACKWARDS: pg_stat_reset_shared('db') sets it to
  -- zero, and a negative delta in the report would be nonsense.
  delta          bigint      NOT NULL DEFAULT 0,
  -- Set when the counter went backwards, which means the next delta is measured from a new baseline
  -- and the total across the window is not the sum of the deltas. Without this the report would
  -- quietly understate.
  counter_reset  boolean     NOT NULL DEFAULT false,
  PRIMARY KEY (sampled_at)
);

COMMENT ON TABLE @extschema@.lock_tree_deadlock IS
  'pg_stat_database.deadlocks sampled on its own beat, whether or not anything is blocked. Read it '
  'with lock_tree_deadlocks(). It names no participants: the two statements involved are in the '
  'server log, so use the timing here to find the right log entry. Prune it with '
  'lock_tree_prune(), which clears it together with the history.';


-- When deadlocks happened.
--
-- Returns one row per sample at which the counter moved, with how far it moved. The useful output
-- is "three deadlocks, all between 09:00 and 09:15, all on a Monday", which is the shape that
-- points at a deploy or a cron job. The total over the window is on every row so a query does not
-- need a second pass for it.
--
-- Does NOT name the statements, because nothing in SQL does. The recipe for getting them is in the
-- README: enable log_lock_waits, and correlate the DETAIL line against the timestamp column here.
CREATE FUNCTION @extschema@.lock_tree_deadlocks(since interval DEFAULT interval '7 days')
RETURNS TABLE (
  sampled_at    timestamptz,
  deadlocks     bigint,
  delta         bigint,
  counter_reset boolean,
  total_in_window bigint,
  samples_in_window bigint
)
LANGUAGE sql STABLE
AS $$
  -- The window is applied once, in the base, rather than to the returned rows. Applying it after
  -- would let a delta computed against a row outside the window leak in, which is exactly the sort
  -- of off-by-one-window that makes a number wrong without looking wrong.
  WITH base AS (
    SELECT d.sampled_at, d.deadlocks, d.delta, d.counter_reset
    FROM @extschema@.lock_tree_deadlock d
    WHERE d.sampled_at >= statement_timestamp() - since
  ),
  totals AS (
    SELECT sum(delta) FILTER (WHERE NOT counter_reset) AS total,
           count(*)                                     AS samples
    FROM base
  )
  SELECT b.sampled_at,
         b.deadlocks,
         b.delta,
         b.counter_reset,
         t.total,
         t.samples
  FROM base b
  CROSS JOIN totals t
  -- Only the samples where the counter moved. A row per sample is a row per sample, and the rows
  -- where nothing happened are the ones nobody wants.
  WHERE b.delta > 0 OR b.counter_reset
  ORDER BY b.sampled_at
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_deadlocks(interval) IS
  'When pg_stat_database.deadlocks moved, one row per sample where it moved: the cumulative '
  'counter, how far it moved, whether the counter was reset since, and the total across the window. '
  'Names no participants, because nothing in SQL does; the two statements are in the server log and '
  'the timestamp here is how you find the right entry. Empty means no deadlocks were sampled, which '
  'is not quite the same as none happening: one between two samples is invisible, since the counter '
  'can only be read at the instants you read it.';

--------------------------------------------------------------------------------
-- the wide case: aggregate instead of enumerate
--------------------------------------------------------------------------------

-- A tree of one row per session is the right shape for understanding one incident and the
-- wrong shape for a database with six of them. When sixty sessions are queued behind five
-- roots, the questions an operator actually has are: which root is worst, how many sessions
-- does each one hold up, and is any of them a long chain rather than a flat queue. All three
-- are answerable from one row per root, and none of them require reading sixty lines.
--
-- This is the same aggregate as
--   SELECT root_pid, count(*) FILTER (WHERE depth > 0), max(depth), max(wait_age)
--   FROM lock_tree GROUP BY root_pid
-- given columns, ordering and a text rendering consistent with the rest of the extension.
CREATE FUNCTION @extschema@.lock_tree_wide()
RETURNS TABLE (
  root_pid          int,
  -- Beside root_pid rather than last, because the two are the root's identity and belong next to
  -- each other: root_pid alone is not enough for a prepared transaction, and a reader who has to
  -- scroll to the end of the row to learn that is the reader who draws the wrong conclusion.
  root_object       text,
  application_name  text,
  state             text,
  blocked_sessions  bigint,
  max_depth         int,
  longest_wait      interval,
  wait_events       text[],
  first_waiting_for text
)
LANGUAGE sql STABLE
AS $$
  -- Aggregate over lock_tree directly rather than joining lock_tree to itself: the root row is
  -- already in there at depth 0, and self-joining to find it is the join that goes wrong the
  -- first time someone edits this.
  SELECT t.root_pid,
         t.root_object,
         max(coalesce(nullif(t.application_name, ''), t.usename)) AS application_name,
         -- Every row of a chain carries the same root, so the root's own state is what the
         -- depth-0 row says. Taking max() over all of them would report a waiter's state, so
         -- read it from the depth-0 row instead.
         max(t.state) FILTER (WHERE t.depth = 0)                  AS state,
         count(*) FILTER (WHERE t.depth > 0)                      AS blocked_sessions,
         max(t.depth)                                              AS max_depth,
         max(t.wait_age)                                           AS longest_wait,
         -- Distinct, because sixty rows of the same wait event is one fact, not sixty.
         array_agg(DISTINCT coalesce(t.wait_event, '?'))          AS wait_events,
         -- What the waiters are after, abbreviated: the mode is the same on all of them in
         -- the common case, and the point here is which lock, not which of forty sessions.
         left(min(coalesce(t.waiting_for, '')) FILTER (WHERE t.waiting_for IS NOT NULL), 60)
                                                                    AS first_waiting_for
  FROM @extschema@.lock_tree t
  -- Grouped by the pair, not the pid. Two prepared transactions are both pid 0, so grouping on
  -- pid alone merged them and reported one root whose blocked_sessions was the sum of two
  -- blockers each holding half as much. That is the number an operator acts on.
  GROUP BY t.root_pid, t.root_object
  ORDER BY count(*) FILTER (WHERE t.depth > 0) DESC, max(t.wait_age) DESC NULLS LAST,
           t.root_pid, t.root_object
$$;


-- ------------------------------------------------------------------ 1.1.4
-- Both participants of a deadlock, for the samples that caught one.
--
-- lock_tree_deadlocks() says WHEN the pg_stat_database counter moved and deliberately names nobody,
-- because a counter carries no attribution. The participants are recoverable, but only from the
-- history, and only for the samples that landed while the cycle still existed: PostgreSQL resolves a
-- deadlock by killing one participant, so the window is the deadlock_timeout before it does that.
--
-- The shape is unique to a deadlock. An ordinary root holds its lock and waits on nothing, so
-- waiting_for IS NULL on it. A row at depth 0 with waiting_for set is a root that is itself waiting,
-- which is a cycle and nothing else. Measured on the standard fixture: zero of 60,481 depth-0 rows
-- have waiting_for set.
--
-- This is a FUNCTION and not a column on lock_tree_history, which is the design decision the
-- roadmap left open. A column would be empty in nearly every row, because populating it needs a
-- sample inside the deadlock_timeout window, and an empty column on the hot table invites exactly
-- the misreading that no deadlock happened. A read function costs no storage, changes no schema, and
-- puts the caveat in a COMMENT that a reader meets at the point of use.
--
-- partner_pids names the other side of the same cycle, so one call returns both participants rather
-- than making the reader join the sample to itself.
CREATE FUNCTION @extschema@.lock_tree_deadlock_participants(
  since interval DEFAULT interval '7 days')
RETURNS TABLE (
  sampled_at       timestamptz,
  pid              integer,
  root_pid         integer,
  state            text,
  application_name text,
  wait_age         interval,
  waiting_for      text,
  query            text,
  partner_pids     integer[]
)
LANGUAGE sql STABLE
AS $$
  SELECT h.sampled_at,
         h.pid,
         h.root_pid,
         h.state,
         h.application_name,
         h.wait_age,
         h.waiting_for,
         h.query,
         (SELECT array_agg(p.pid ORDER BY p.pid)
            FROM @extschema@.lock_tree_history p
           WHERE p.sampled_at = h.sampled_at
             AND p.depth = 0
             AND p.waiting_for IS NOT NULL
             AND p.pid <> h.pid)
  FROM @extschema@.lock_tree_history h
  WHERE h.depth = 0
    AND h.waiting_for IS NOT NULL
    AND h.sampled_at >= statement_timestamp() - since
  ORDER BY h.sampled_at, h.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_deadlock_participants(interval) IS
  'Both participants of any deadlock the history happened to catch, one row per participant per '
  'sample, with partner_pids naming the other side. Empty is the normal case and does NOT mean no '
  'deadlock happened: this only has rows for samples taken while the cycle still existed, which is '
  'the deadlock_timeout before the server breaks it. With the default 1s deadlock_timeout and a 10 '
  'second sample interval, roughly one deadlock in ten is caught. lock_tree_deadlocks() is the '
  'counter that moves whether or not anyone was looking, and is how you find the ones this misses. '
  'Do not raise deadlock_timeout to catch more: it is also how long every real lock wait goes '
  'unexamined. The server log names both statements in every case; this is second-hand from the '
  'tree, so it can be wrong in the case that matters.';

COMMENT ON FUNCTION @extschema@.lock_tree_wide() IS
  'One row per root blocker instead of one per session: how many sessions each root blocks, '
  'the deepest chain under it, the longest wait, and what they are all waiting for. Use this '
  'rather than lock_tree_text_short() when the queue is wide enough that reading every line '
  'is the problem.';


-- One row for the whole queue. For a dashboard cell, an alert condition, or deciding whether
-- to look at all: is anything blocked, how much, and how bad is the worst of it.
CREATE FUNCTION @extschema@.lock_tree_summary()
RETURNS TABLE (
  blocked_sessions  bigint,
  roots             bigint,
  max_depth         int,
  longest_wait      interval,
  oldest_xact_age   interval
)
LANGUAGE sql STABLE
AS $$
  -- counts depth-0 rows, so this depends on the view having exactly one depth-0 row per root.
  -- That held until 0.8, when a prepared root stopped being merged with its peers and started
  -- being one row each: two prepared transactions went from roots = 1 to roots = 2, which is the
  -- correct answer and the reason for the change.
  SELECT count(*) FILTER (WHERE depth > 0),
         count(*) FILTER (WHERE depth = 0),
         coalesce(max(depth), 0),
         max(wait_age),
         -- The oldest open transaction among the roots, which is the number that says "this
         -- has been going for an hour", as distinct from "these have been waiting an hour".
         max(xact_age) FILTER (WHERE depth = 0)
  FROM @extschema@.lock_tree
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_summary() IS
  'One row for the whole lock tree: sessions blocked, roots blocking them, the deepest chain, '
  'the longest wait, and the oldest root transaction. Returns one row of zeros on a quiet '
  'database rather than no rows, so it can be used directly in a dashboard or an alert test.';


--------------------------------------------------------------------------------
-- what pg_stat_statements already knows about the blocking query
--------------------------------------------------------------------------------

-- The other half of lock_tree_wide(): this one says which *kind* of statement is doing the
-- blocking, and what it normally costs, rather than which pid happens to hold the lock this
-- time. Two incidents at 09:00 and at 14:00 have different pids and the same queryid, and it
-- is the queryid that says they are the same problem.
--
-- pg_stat_statements is optional and the function degrades rather than failing. It also needs
-- shared_preload_libraries = pg_stat_statements to be readable at all, and the extension must
-- keep working where it is not loaded, so availability is tested per call rather than assumed.
--
-- One thing this cannot do, found by measuring rather than reasoning: it cannot enrich the
-- WAITERS. A query blocked on a lock has query_id NULL for as long as it is blocked, and only
-- gains one when it completes. So the waiter side of this join is empty during the one moment
-- anybody would want it. The root is the opposite, carrying a query_id throughout. That is
-- fortunate rather than lucky, since the root is the session anyone acts on: knowing the cost
-- of the query holding the lock is the useful half. Stated here because "why is this column
-- null for everything I am blocked on" is otherwise a puzzle.
CREATE FUNCTION @extschema@.lock_tree_statements()
RETURNS TABLE (
  root_pid         int,
  root_object      text,
  application_name text,
  state            text,
  blocked_sessions bigint,
  query_id         bigint,
  statement        text,
  calls            bigint,
  total_exec_time  double precision,
  mean_exec_time   double precision,
  rows_returned    bigint
)
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  -- The join is built as text and run with EXECUTE, which is the only way to reference a
  -- relation that may not exist. A SQL function naming pg_stat_statements directly fails at
  -- CREATE EXTENSION time on a server without it, which would make this optional feature
  -- mandatory. to_regclass decides which query to run; there is no parse to defer here,
  -- because the string is only parsed when executed.
  have_pgss boolean := to_regclass('pg_stat_statements') IS NOT NULL;
BEGIN
  IF NOT have_pgss THEN
    -- No pg_stat_statements loaded: report the roots anyway, with the statement columns empty.
    -- A caller asking "which queries are blocking me" should still learn which roots exist and
    -- how much each one blocks. The feature is missing, not the queue.
    RETURN QUERY
      SELECT w.root_pid, w.root_object, w.application_name, w.state, w.blocked_sessions,
             NULL::bigint, NULL::text, NULL::bigint,
             NULL::double precision, NULL::double precision, NULL::bigint
      FROM @extschema@.lock_tree_wide() w
      ORDER BY w.blocked_sessions DESC, w.root_pid, w.root_object;
    RETURN;
  END IF;

  -- The pg_stat_statements side is aggregated in a LATERAL subquery rather than joined
  -- row-for-row, because queryid is not unique there in practice. Measured on PG 18: one
  -- statement that had run six times sat in two rows, with calls of 1 and 5, and the row-for-row
  -- join produced two output rows for one root. Since this function is documented as one row per
  -- root, and its caller groups incidents by it, a duplicate row is a duplicate incident.
  --
  -- Summing is the right reduction rather than picking a row: the buckets are the same statement,
  -- and the total cost of a statement is what the reader wants. The mean is recomputed from the
  -- sum, not averaged across buckets, because an unweighted mean of means is wrong whenever the
  -- buckets have different call counts, which is the entire reason they are separate.
  RETURN QUERY EXECUTE
    'SELECT w.root_pid, w.root_object, w.application_name, w.state, w.blocked_sessions,
            a.query_id,
            agg.statement,
            agg.calls,
            agg.total_exec_time,
            agg.mean_exec_time,
            agg.rows
     FROM @extschema@.lock_tree_wide() w
     LEFT JOIN pg_stat_activity a ON a.pid = w.root_pid
     LEFT JOIN LATERAL (
       SELECT left(min(s.query), 120) AS statement,
              sum(s.calls)::bigint    AS calls,
              sum(s.total_exec_time) AS total_exec_time,
              sum(s.mean_exec_time * s.calls) / NULLIF(sum(s.calls), 0) AS mean_exec_time,
              max(s.rows)             AS rows
       FROM pg_stat_statements s
       WHERE s.queryid = a.query_id
     ) agg ON true
     ORDER BY w.blocked_sessions DESC, w.root_pid, w.root_object';
END
$fn$;

COMMENT ON FUNCTION @extschema@.lock_tree_statements() IS
  'One row per root blocker, joined to pg_stat_statements for the cost of the query holding '
  'the lock: its normalised text, how many times it has run, and its mean and total time. '
  'Groups incidents by query rather than by pid, so the same statement blocking at 09:00 and '
  'at 14:00 is recognisable as one problem. Needs pg_stat_statements in '
  'shared_preload_libraries; without it the statement columns are empty and the roots are '
  'still reported. Cannot enrich waiters: a query blocked on a lock has no query_id until it '
  'completes, so only the blocker side of the join is populated.';


--------------------------------------------------------------------------------
-- alerting: turning "something is wrong" into "someone was told"
--------------------------------------------------------------------------------

-- Everything so far reports to whoever is already looking. History reports to whoever looks
-- later. Neither tells anyone that something is happening now, which is the moment alerting
-- exists for.
--
-- The design problem is not raising a notification, it is raising the RIGHT number of them. A
-- job that notifies on every sample turns a two-minute incident into twelve notifications and
-- trains everyone to ignore the channel, which is worse than having none: the one alert that
-- mattered gets filtered along with the noise. So lock_tree_notify() notifies on onset and on
-- escalation, and stays quiet while a chain sits at the same severity. lock_tree_alert is what
-- makes that possible.
--
-- NOTIFY rather than anything heavier, deliberately. It needs no extra process, no table to
-- drain, and no polling: any client can LISTEN, and it is transactional, so a rolled-back
-- sample never notifies. The payload is JSON on one channel prefixed with the channel name, so a
-- listener can serve several kinds of alert from one subscription and route on the payload.

-- What has already been alerted on, per channel and per root. Small by construction: one row per
-- root that is currently notable, and rows are removed as soon as the root is gone, so the table
-- holds the size of the current queue rather than its history.
--
-- max_blocked_at and max_depth_at are the high-water marks, not the latest values. That is what
-- makes an escalation distinguishable from a recovery: a root that drops from 40 sessions to 12
-- is getting better and must not re-notify, while one that goes from 12 to 40 is getting worse
-- and must.
CREATE TABLE @extschema@.lock_tree_alert (
  channel          text        NOT NULL,
  policy           text        NOT NULL,
  root_pid         int         NOT NULL,
  -- Part of the primary key from 0.8. It was not in 0.7, and that was a live bug: every prepared
  -- transaction is root_pid 0, so two of them shared one row and their wait counts compared
  -- against each other. NOT NULL with a default so the ALTER below can add it to existing rows
  -- without a rewrite: metadata-only on PostgreSQL 11 and later, and the value was never
  -- captured anyway, so '' is the honest answer rather than NULL.
  root_object      text        NOT NULL DEFAULT '',
  application_name text,
  first_seen       timestamptz NOT NULL,
  last_notified    timestamptz,
  notify_count     int         NOT NULL DEFAULT 0,
  max_blocked_at   bigint      NOT NULL DEFAULT 0,
  max_depth_at     int         NOT NULL DEFAULT 0,
  -- The longest wait as at the last notification, and only ever written when a notification is
  -- raised. That is what distinguishes it from a plain high-water mark: a wait grows every
  -- second, so recording it every sample would make "has it grown" permanently true and the
  -- function would notify on every sample again, undoing the whole design.
  --
  -- Escalation compares the current longest wait against twice this value, so the sequence a
  -- worsening incident produces is 30s, 1m, 2m, 4m, 8m: geometric, a handful of notifications for
  -- an hour of waiting rather than one per sample.
  max_waited_at    interval    NOT NULL DEFAULT interval '0',
  PRIMARY KEY (channel, policy, root_pid, root_object)
);

CREATE INDEX lock_tree_alert_last_notified_idx
  ON @extschema@.lock_tree_alert (last_notified);

COMMENT ON TABLE @extschema@.lock_tree_alert IS
  'What lock_tree_notify() has already alerted on, per channel, per threshold set, per root. '
  'Rows are removed when the root leaves the tree, so a chain that returns alerts again. The '
  'policy column holds the thresholds the row was written under: two different alerting policies '
  'sharing a channel would otherwise clear each other''s state, and each would re-alert on '
  'every alternate sample. Not history: lock_tree_history is that. Prune with '
  'lock_tree_prune_alerts(). root_object is empty for a session root, whose pid already '
  'identifies it, and names the lock held for a prepared-transaction root. The three max_* '
  'columns are high-water marks recorded at the last notification, not the latest sample, which '
  'is what makes a recovery distinguishable from an escalation.';



-- Notify when a root is notable, and only then. Returns how many notifications were raised,
-- which is the number worth watching: zero on every ordinary sample, one per onset or
-- escalation, and it stays at zero for as long as an incident sits at the same severity.
--
-- Thresholds, and how they combine:
--
--   A root is notable if it meets AT LEAST ONE of the criteria that are set. NULL, or 0 for
--   min_blocked, switches a criterion off. With all three set, a chain alerts if it blocks at
--   least min_blocked sessions, OR is min_deep, OR has anyone waiting min_wait. That is the
--   useful shape: a queue can be bad in ways unrelated to each other, and an operator paging on
--   "deep OR slow" rather than "deep AND slow" will not miss the incident that was both.
--
--   At least one criterion must be set. All three off means "alert on every root", which is not
--   what anyone wants from an alerting function, so it is rejected rather than quietly given a
--   default.
--
-- What this deliberately does not do:
--   - page anything. It raises a NOTIFY on a PostgreSQL channel. Wiring that to a pager is the
--     deployment's business, and the payload is JSON so that whatever it is can parse it.
--   - choose your thresholds. They are arguments. No default is right for everyone, and a
--     default nobody reads is a default nobody trusts.
--   - keep state indefinitely. Rows go when a root does, which is the normal case.
--
-- A row-at-a-time loop rather than nested upserts with a RETURNING clause. The row count is one
-- per root blocker, which is a handful, and the logic here is control flow: compare, decide,
-- write, notify. Written as a loop it reads in the order it happens, and it was the first version
-- that was correct. The alternative spelled the same decision in three nested CTEs and referred
-- to a column that did not exist.
CREATE FUNCTION @extschema@.lock_tree_notify(
  channel      text     DEFAULT 'lock_tree',
  min_blocked  integer  DEFAULT 1,
  min_depth    integer  DEFAULT 2,
  min_wait     interval DEFAULT '30 seconds'
)
RETURNS bigint
LANGUAGE plpgsql
AS $fn$
DECLARE
  r           record;
  prior       record;
  fired       bigint := 0;
  -- Per-root, not the call's total. Testing `fired > 0` here would mean that once any root had
  -- notified, every later root in the same loop also notified, including ones that should stay
  -- quiet, which is the noise this whole design exists to avoid.
  root_fired  boolean := false;
  -- The thresholds, rendered as one string and used as part of the state key. Two different
  -- alerting policies sharing a channel would otherwise clear each other's state, so each would
  -- re-alert on every alternate sample. Found by a test that alternated thresholds and saw both
  -- roots fire twice where one of them had not actually got worse.
  -- Named pol rather than policy: a plpgsql variable sharing a column's name is ambiguous in
  -- every query that mentions the column, and qualifying it in expressions is not enough,
  -- because there is no valid qualified-assignment form to disambiguate the assignment.
  pol         text;
  -- Normalised thresholds: a criterion set to zero or negative is the same as switching it off,
  -- which is what someone means by passing 0.
  want_blocked integer := CASE WHEN min_blocked IS NULL OR min_blocked < 1 THEN NULL
                               ELSE min_blocked END;
  want_depth   integer := CASE WHEN min_depth   IS NULL OR min_depth   < 1 THEN NULL
                               ELSE min_depth END;
  want_wait    interval := CASE WHEN min_wait IS NULL OR min_wait < interval '0' THEN NULL
                               ELSE min_wait END;
BEGIN
  pol := format('blocked>=%s depth>=%s wait>=%s',
                   coalesce(want_blocked::text, 'off'),
                   coalesce(want_depth::text,   'off'),
                   coalesce(want_wait::text,    'off'));

  IF want_blocked IS NULL AND want_depth IS NULL AND want_wait IS NULL THEN
    RAISE EXCEPTION
      'lock_tree_notify() needs at least one threshold: pass min_blocked, min_depth or '
      'min_wait. Passing NULL switches one criterion off, but all three off means alerting on '
      'every root, which is almost certainly not what you want.';
  END IF;

  FOR r IN
    SELECT w.root_pid, w.root_object, w.application_name, w.blocked_sessions, w.max_depth,
           w.longest_wait, w.first_waiting_for,
           (want_blocked IS NOT NULL AND w.blocked_sessions >= want_blocked)
           OR (want_depth   IS NOT NULL AND w.max_depth       >= want_depth)
           OR (want_wait    IS NOT NULL AND w.longest_wait    >= want_wait) AS notable
    FROM @extschema@.lock_tree_wide() w
  LOOP
    IF NOT r.notable THEN
      -- Below every threshold. It stays below until it stops being in the tree at all, which
      -- the sweep after the loop takes care of, so nothing to do here.
      root_fired := false;
      CONTINUE;
    END IF;

    SELECT * INTO prior FROM @extschema@.lock_tree_alert a
     WHERE a.channel = lock_tree_notify.channel
       AND a.policy  = pol
       AND a.root_pid = r.root_pid
       AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');

    IF NOT FOUND THEN
      -- First time this root has been notable on this channel. That is the onset, and the one
      -- case that is always worth telling someone about.
      INSERT INTO @extschema@.lock_tree_alert
        (channel, policy, root_pid, root_object, application_name, first_seen, last_notified,
         notify_count, max_blocked_at, max_depth_at, max_waited_at)
      VALUES (lock_tree_notify.channel, pol, r.root_pid, coalesce(r.root_object, ''),
              r.application_name,
              statement_timestamp(), statement_timestamp(), 1,
              r.blocked_sessions, r.max_depth,
              -- A CASE rather than greatest(coalesce(r.longest_wait, 0), want_wait), because
              -- greatest() IGNORES null arguments in PostgreSQL rather than propagating them. With
              -- min_wait off, want_wait is NULL, so greatest(3s, NULL) is 3s and the row quietly
              -- records a wait for a criterion that does not exist. Found by the test that asserts
              -- nothing is recorded when min_wait => NULL, which it was not.
              CASE WHEN want_wait IS NOT NULL
                   THEN greatest(coalesce(r.longest_wait, interval '0'), want_wait)
                   ELSE interval '0' END);
      fired := fired + 1;
      root_fired := true;
    ELSIF r.blocked_sessions > prior.max_blocked_at
       OR r.max_depth > prior.max_depth_at
       -- The greatest(), not a bare comparison, and that is the whole subtlety. If max_waited_at
       -- is still zero the doubling target is zero, and "wait >= 0" is true on every sample: the
       -- function would notify sixty times an hour, which is the failure lock_tree_alert exists to
       -- prevent. Zero happens whenever the wait was under a second at onset, because the view
       -- truncates wait_age to whole seconds. Falling back to want_wait means the first escalation
       -- is the operator's own threshold, which is the only sensible answer when there is no
       -- recorded wait to double.
       OR (want_wait IS NOT NULL AND r.longest_wait IS NOT NULL
           AND r.longest_wait >= greatest(prior.max_waited_at * 2, want_wait)) THEN
      -- Escalation, on any of three ways of getting worse.
      --
      -- Width and depth are compared against high-water marks rather than the previous sample, so a
      -- chain that wobbles between 40 and 12 sessions notifies once, not twice a minute.
      --
      -- Age is compared against twice the wait recorded at the last notification, NOT against the
      -- previous sample. A wait grows continuously, so the previous-sample comparison is true
      -- every time and would notify on every sample, which is the noise lock_tree_alert exists to
      -- prevent. Doubling gives 30s, 1m, 2m, 4m, 8m, and it is gated on min_wait being set: an
      -- operator who passed min_wait => NULL asked not to be paged on wait age, and a second page
      -- about a slow queue is how a channel gets ignored.
      UPDATE @extschema@.lock_tree_alert a
         SET last_notified  = statement_timestamp(),
             notify_count   = notify_count + 1,
             max_blocked_at = greatest(max_blocked_at, r.blocked_sessions),
             max_depth_at   = greatest(max_depth_at, r.max_depth),
             -- greatest() against want_wait as well, so a root whose wait was under a second at
             -- onset stores the threshold rather than zero. Otherwise the next comparison would
             -- double zero and fire on every sample.
             -- greatest() ignores NULLs rather than propagating them, so want_wait has to be
             -- handled by the CASE rather than passed through to it.
             max_waited_at  = CASE WHEN want_wait IS NOT NULL AND r.longest_wait IS NOT NULL
                                   THEN greatest(max_waited_at, r.longest_wait, want_wait)
                                   ELSE max_waited_at END,
             root_object    = coalesce(r.root_object, ''),
             application_name = r.application_name
       WHERE a.channel = lock_tree_notify.channel
         AND a.policy  = pol
         AND a.root_pid = r.root_pid
         AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');
      fired := fired + 1;
      root_fired := true;
    ELSE
      -- Notable but unchanged. Stay quiet: this is the case that turns an alerting function into
      -- noise, and the whole reason lock_tree_alert exists.
      UPDATE @extschema@.lock_tree_alert a
         SET application_name = r.application_name
       WHERE a.channel = lock_tree_notify.channel
         AND a.policy  = pol
         AND a.root_pid = r.root_pid
         AND a.root_object IS NOT DISTINCT FROM coalesce(r.root_object, '');
    END IF;

    IF root_fired THEN
      PERFORM pg_notify(lock_tree_notify.channel, json_build_object(
        'channel',           lock_tree_notify.channel,
        -- Added in 0.12. There was no event key before, and adding one is what lets a consumer
        -- branch on a single field to tell an onset from a resolution, rather than inferring it
        -- from the absence of a key. It is additive: JSON consumers read by key, so a listener
        -- written against 0.6 that ignores fields it does not recognise is unaffected.
        'event',             'alerting',
        'root_pid',          r.root_pid,
        -- null in the payload for a session root, a lock name for a prepared one. A listener
        -- keying on application_name, which is what the documentation recommends, is unaffected;
        -- this is there so a listener that has two prepared roots can tell them apart.
        'root_object',       r.root_object,
        'application_name',  r.application_name,
        'blocked_sessions',  r.blocked_sessions,
        'max_depth',         r.max_depth,
        'longest_wait',      @extschema@.lock_tree_age(r.longest_wait),
        'waiting_for',       r.first_waiting_for
      )::text);
    END IF;
  END LOOP;

  -- Sweep away state for roots that are no longer in the tree at all. This cannot live in the
  -- loop above, because the loop iterates over lock_tree_wide(), and a root whose waiters have
  -- all gone has no edges and therefore no row there: it simply vanishes. Without this sweep the
  -- table grows one row per root ever seen, forever, and every one of them is a pid that will
  -- never be reused. Found by a test asserting the table empties on recovery, which it did not.
  DELETE FROM @extschema@.lock_tree_alert a
   WHERE a.channel = lock_tree_notify.channel
     AND a.policy  = pol
     -- Matched on the pair, not the pid. With the pid alone this sweep deleted a prepared
     -- transaction's state as soon as ANY prepared root was present, because pid 0 matched.
     AND NOT EXISTS (SELECT 1 FROM @extschema@.lock_tree t
                      WHERE t.root_pid = a.root_pid
                        AND coalesce(t.root_object, '') = a.root_object);

  RETURN fired;
END
$fn$;

COMMENT ON FUNCTION @extschema@.lock_tree_notify(text, integer, integer, interval) IS
  'Raise a NOTIFY on a channel when a root blocker is notable, and remember it so the same '
  'incident notifies once rather than on every sample. A root is notable if it meets AT LEAST '
  'ONE of min_blocked, min_depth or min_wait; NULL or 0 switches one off, and at least one '
  'must be set. Once notable, it notifies on onset and then on any of three escalations: more '
  'sessions blocked than ever before, deeper than ever before, or a longest wait that has '
  'doubled since the last notification. The doubling is deliberate: a wait grows continuously, so '
  'comparing it to the previous sample is true every time and would notify on every sample. Age '
  'escalation only applies when min_wait is set, because min_wait => NULL means do not page me on '
  'wait age. Returns how many notifications were raised, so zero is the normal result and the '
  'one worth watching. Payloads are JSON. Wire the channel to a pager yourself: this raises '
  'NOTIFY and nothing more.';


-- Forget alert state that no longer refers to a live session.
--
-- lock_tree_notify() deletes a root's row as soon as that root stops being notable, which is
-- the normal case and needs no help. This is for the abnormal ones: a server that was rebooted
-- mid-incident keeps rows for pids that no longer exist, and a channel name that has been
-- retired keeps rows under it. Small either way, since the table is the size of the current
-- queue, so calling this from the same cron entry as the sample is enough.
CREATE FUNCTION @extschema@.lock_tree_prune_alerts(older_than interval DEFAULT interval '1 day')
RETURNS bigint
LANGUAGE sql
AS $$
  WITH gone AS (
    DELETE FROM @extschema@.lock_tree_alert
    WHERE last_notified IS NOT NULL
      AND last_notified < statement_timestamp() - older_than
    RETURNING 1
  )
  SELECT count(*) FROM gone
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_prune_alerts(interval) IS
  'Delete alert state last notified on more than the given age ago; returns how many. Only '
  'needed for alert state orphaned by a restart or a retired channel: lock_tree_notify() '
  'already forgets a root as soon as it stops being notable.';


-- How often to sample, given how busy things currently are.
--
-- The history sample is a cron entry, and a cron entry needs a number. Most people pick one by
-- feel and then either pay for it or miss incidents. The honest answer is that it depends on how
-- wide the queue gets, and this says what that is.
--
-- The reasoning, briefly: a queue changes on the scale of seconds, so a sample interval much
-- above a minute will miss short incidents entirely, while an interval far below a few seconds
-- writes the same state repeatedly and grows the table for nothing. The cost of a sample is one
-- row per blocked session, so the interval that matters is the one that keeps a wide queue from
-- dominating the table.
CREATE FUNCTION @extschema@.lock_tree_sampling_advice(
  since interval DEFAULT interval '7 days'
)
RETURNS TABLE (
  blocked_sessions bigint,
  roots            bigint,
  suggested_every  interval,
  reason           text,
  observed_peak    bigint,
  live_blocked     bigint,
  look_back        interval
)
LANGUAGE sql STABLE
AS $$
  -- Read from the history, not from the instant, which is the whole change in 0.10.
  --
  -- Through 0.9 this reported advice from whatever happened to be true at the moment it was called.
  -- A cron entry on a quiet Sunday at 3am therefore saw zero sessions blocked and recommended the
  -- finest interval, on a database that spends every weekday morning with four hundred of them
  -- waiting. The advice was not wrong about the instant; it was answering the wrong question. The
  -- question is what the table has to carry, and the table's size is set by the peaks.
  --
  -- max(observed_peak, live_blocked) rather than observed_peak alone: the peak cannot know about a
  -- queue that started after the last sample, and telling someone to widen their interval while
  -- their queue is growing is exactly the wrong advice at the wrong moment.
  WITH seen AS (
    SELECT coalesce(max(per_sample.sessions), 0) AS peak
    FROM (
      SELECT count(*)::bigint AS sessions
      FROM @extschema@.lock_tree_history h
      WHERE h.sampled_at >= statement_timestamp() - since
      GROUP BY h.sampled_at
    ) per_sample
  )
  SELECT greatest(seen.peak, s.blocked_sessions),
         s.roots,
         -- Three bands, chosen on cost rather than taste. Under 10 sessions a sample is cheap
         -- and detail is worth having. Under 100 it is 10 times the storage and a 10 second
         -- interval still catches everything that lasts longer than a query. Past that the
         -- table is the dominant cost and 30 seconds is enough to characterise an incident.
         CASE WHEN greatest(seen.peak, s.blocked_sessions) < 10  THEN interval '5 seconds'
              WHEN greatest(seen.peak, s.blocked_sessions) < 100 THEN interval '10 seconds'
              ELSE interval '30 seconds' END,
         CASE WHEN greatest(seen.peak, s.blocked_sessions) = 0
         THEN 'nothing blocked now and nothing in the window: a sample writes nothing here, so 5 seconds'
              || ' costs one cheap query and still catches the next incident in detail'
              WHEN seen.peak > s.blocked_sessions
              THEN 'quiet now, but ' || seen.peak || ' sessions were waiting at the peak in this window, so sized for that rather than for now'
              WHEN greatest(seen.peak, s.blocked_sessions) < 10
              THEN 'few sessions blocked: cheap to sample finely, so keep the detail'
              WHEN greatest(seen.peak, s.blocked_sessions) < 100
              THEN 'a busy queue: 10 seconds catches anything that lasts, at a tenth the storage'
              ELSE 'a wide queue: each sample writes a row per blocked session, so widen the interval'
         END,
         seen.peak,
         s.blocked_sessions,
         -- Named look_back rather than window: WINDOW is a reserved word, so a column called window
         -- has to be quoted at every use and in every example that reads it.
         since
  FROM @extschema@.lock_tree_summary() s
  CROSS JOIN seen
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_sampling_advice(interval) IS
  'A suggested interval for lock_tree_sample(), and why. Sized on the widest queue seen in the '
  'window rather than on the queue at this instant. The reason for a quiet database was reworded in '
  '1.0.2: it said "so sample rarely" while returning 00:00:05, the finest interval offered. The '
  'interval was always correct; the wording was not.';


--------------------------------------------------------------------------------
-- history: what the tree looked like while you were not looking
--------------------------------------------------------------------------------

-- Everything above describes the present. That is a real limit: an incident is usually
-- discovered after it has ended, by a slow query, a timeout, or a user reporting that
-- "it was hanging earlier". By then pg_stat_activity has moved on and the tree is empty.
-- This is the part that closes that gap: sample on a schedule, keep it, and segment the
-- result into incidents you can read later.
--
-- Nothing here runs by itself. lock_tree_sample() takes exactly one snapshot and is the
-- only thing that writes. Until you schedule it, the table stays empty and this extension
-- behaves exactly as 0.3 did.
--
-- The extension still needs no shared_preload_libraries. pg_cron is a convenient scheduler
-- and nothing more: any scheduler works, including a cron job on the database host calling
-- psql. If you do use pg_cron, see INSTALL.md, because it needs preloading and that is a
-- server change rather than an extension one.

-- sampled_at is statement_timestamp(), and getting that right took two attempts worth
-- recording. clock_timestamp() is volatile and is therefore evaluated once per ROW, so the
-- two sessions in a two-session chain landed microseconds apart. Grouping by sampled_at
-- then yields one group per session instead of one per sample, which silently reduces
-- peak_sessions to 1 for every incident ever recorded. now() has the opposite problem: it
-- is the transaction timestamp, so every row across every sample in one transaction shares
-- an instant and the whole thing collapses to one point. statement_timestamp() is stable
-- for the duration of the one statement that takes the sample, and moves between samples,
-- which is exactly the grain the grouping below needs.
--
-- The table holds one row per session per sample, not one row per sample: the shape of the
-- chain is the thing worth keeping, and a single row per sample would throw away depth,
-- path and wait age. query is truncated to 300 characters because the history of a wide
-- queue is mostly the same few long queries repeated, and unbounded text turns a sampling
-- table into a disk problem.
CREATE TABLE @extschema@.lock_tree_history (
  sampled_at       timestamptz NOT NULL,
  root_pid         int         NOT NULL,   -- 0 for a prepared transaction
  depth            int         NOT NULL,
  pid              int         NOT NULL,
  state            text,
  waiting_for      text,
  wait_age         interval,
  application_name text,
  query            text,
  -- What a prepared-transaction root is holding. NULL for a session root, because root_pid
  -- identifies that one already. Added in 0.8: two prepared transactions both have root_pid 0, so
  -- without this the history recorded one merged root for two of them.
  root_object      text,
  -- The root's pg_stat_statements query_id, so per-query blocking time can be totalled from the
  -- history. NULL for a root that has no query_id, which includes every waiter row: a query
  -- blocked on a lock has no query_id until it completes. Deliberately NULL rather than
  -- The COMMENT ON COLUMN for this is below, next to COMMENT ON TABLE, and it was MISSING from
  -- every release file up to and including 0.16 even though the 0.7 update script set it. A fresh
  -- install therefore had an uncommented column and every upgraded database had a commented one.
  -- scripts/check-upgrade.sh found it by comparing a fresh install against an upgraded one, which
  -- is the only way to see it: nothing is wrong with either state in isolation.
  -- inheriting the root's value, because a waiter and its root running different statements is
  -- the normal case and conflating them would make the totals wrong rather than merely incomplete.
  query_id         bigint
);

-- One index for the common question, "what happened between 09:00 and 10:00", and one for
-- "what has this session been doing", which is how you find the pid that caused the whole
-- thing after it has gone. Both are created here rather than left to the user: an
-- unindexed history table is one nobody can afford to query once it has a day of samples.
CREATE INDEX lock_tree_history_sampled_at_idx
  ON @extschema@.lock_tree_history (sampled_at);
CREATE INDEX lock_tree_history_pid_idx
  ON @extschema@.lock_tree_history (pid, sampled_at DESC);
-- Per-query accounting reads by query_id over a time range, which this index serves directly.
-- Partial, because query_id is NULL for every waiter row and an index over mostly-NULL keys is
-- mostly useless space.
CREATE INDEX lock_tree_history_query_id_idx
  ON @extschema@.lock_tree_history (query_id, sampled_at DESC)
  WHERE query_id IS NOT NULL;
-- Partial, on the root rows only, and the leading column is the one the by-application function
-- groups by.
--
-- Chosen by measurement rather than by taste. Three candidates were tried against the same seven day
-- 1.2 million row fixture, each on its own, whole-window lock_tree_duration() and
-- lock_tree_duration_by_application() before and after:
--
--   no extra index                                       2000 ms    2634 ms
--   (application_name, sampled_at) WHERE depth = 0        1651 ms    2002 ms   1888 kB
--   (sampled_at)            WHERE depth = 0               1750 ms    2214 ms   1344 kB
--   (root_pid, sampled_at)  WHERE depth > 0               1701 ms    2501 ms   9744 kB
--
-- The first wins: 17% and 24% for 1.9 MB, which is 0.7% of the table. The last costs five times the
-- space for no gain on the application figure, because the root-to-waiter join was never the
-- expensive side. The second is smaller but dominated on both reads, and the leading column is worth
-- more than the bytes it saves.
--
-- Partial rather than full because the query that wants it filters on depth = 0, which is about one
-- row in twenty here. A full index on (application_name, sampled_at) would carry twenty times the
-- entries to serve the same twenty.
--
-- The write cost was measured too, because this index is on the hot path: lock_tree_sample() inserts
-- one row per blocked session, and a fourth index is four times the work per sample. One sample of 20
-- rows took 0.8 ms without it and 0.7 ms with it, which is noise. The partial predicate is why: only
-- the root row of each sample qualifies, so there is one index entry per sample rather than twenty.
--
-- The 1 hour window was already 12 ms before this index existed, thanks to 0.15 turning the window
-- bound into an Index Cond. What is left slow is the whole-window read, and that is what this helps.
-- ---------------------------------------------------------------------------------------------
-- ---------------------------------------------------------------------------------------------
-- lock_tree_redact(q): strip credentials out of query text before it is stored.
--
-- WHY THIS EXISTS. lock_tree_history keeps the first 300 characters of every blocked session's
-- query. A blocked `ALTER ROLE app PASSWORD 'hunter2'` is a blocked query. It sat in that table, in
-- full, until it aged out, readable by anyone with SELECT on the history and copied into every
-- physical backup of the database.
--
-- 1.0.1 CHANGES THIS FUNCTION, because 1.0.0's did not catch the credential shape that matters
-- most. Every case below was reproduced on PostgreSQL 18 against the 1.0.0 function, and every one
-- was stored verbatim. The 1.0.0 release notes claimed the pattern "cannot under-redact". It could,
-- and the test that would have shown it was not committed.
--
--   1. A real SCRAM verifier passed to a function, which is what a reset tool produces:
--          SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>
--      1.0.0's class was [A-Za-z0-9+/=]+\$ and stopped at 4096, so the whole pattern failed. The
--      iteration count and the colon between the two keys are both load-bearing. Its test fixture had
--      no 4096: prefix, which is why the bug survived.
--   2. PASSWORD $$x$$. The tag class required a non-empty tag; the empty tag is the commonest form.
--   3. PASSWORD 'a literal containing a newline'. 1.0.0 matched to the last quote on the first line.
--   4. PASSWORD 'x with no closing quote, because pg_stat_activity cuts the text at
--      track_activity_query_size (1 kB by default). Same failure as the newline case.
--   5. PASSWORD U&'x', PASSWORD /*c*/ 'x', and PASSWORD'x' with no space. 1.0.0 expected E?'
--      immediately after whitespace.
--
-- WHAT CHANGED
--
--   After PASSWORD, plus any whitespace and any comments, this replaces from the opening of the
--   literal to the END OF THE TEXT rather than to the last quote on the line. The literal may open
--   with ', E', U&' or $, and a truncated statement has no closing delimiter at all, which is why
--   the end of the text is the terminator.
--
--   That over-redacts the tail of the statement: `PASSWORD 'p', VALID UNTIL '2026-01-01'` loses the
--   VALID UNTIL clause too. The clauses that can follow a password are VALID UNTIL and IN ROLE, and
--   neither is what an incident is diagnosed from, so that is the right side to err on. It is a
--   deliberate trade and it is asserted in test/21 so it cannot be mistaken for a bug later.
--
-- STILL DELIBERATELY NOT STRIPPED, because over-eager redaction makes the history useless for the
-- job it exists to do, which is telling you which statement is holding the queue up:
--
--   ordinary DML, including string literals that merely look like credentials
--   connection URLs carrying a password. A real exposure, and also a perfectly ordinary thing to
--     have in an ad-hoc query, so redacting it by default would be a guess about your data.
--   a parameter placeholder, so `PASSWORD $1` is redacted. Cheap and in the safe direction.
--
-- STILL UNTOUCHED, and asserted: PASSWORD NULL, SET password = 'x' (the = blocks it), and
-- old_password 'x' (\m will not match after an underscore, which is a word character).
--
-- IMMUTABLE and PARALLEL SAFE, both true: it is regexp_replace over its own argument and depends on
-- nothing else. search_path is pinned because lock_tree_sample(), which calls it, is SECURITY
-- DEFINER, and an unqualified name in anything reachable by PUBLIC is an invitation.
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION @extschema@.lock_tree_redact(q text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $redact$
  SELECT nullif(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          q,
          -- \m so that old_password and my_password do not match: \m only fires where the preceding
          -- character is not a word character, and _ is one. 1.0.0 had no anchor at all and so
          -- redacted old_password, which the review noted as a regression from the intended set.
          --
          -- (?:\s|/\*[\s\S]*?\*/)* for whitespace and comments, so PASSWORD/*c*/'x' and PASSWORD'x'
          -- are both caught. The comment alternative is non-greedy so it stops at the first */.
          --
          -- (?:[EU]&?)? for E', U&' and the bare form. It is optional and greedy, and the following
          -- alternative is what forces the backtrack: for U&'x' the E-only reading leaves & where a
          -- quote is required, so the & is taken.
          --
          -- [\s\S]* rather than . to the END of the text, which is what catches a newline inside the
          -- literal and a statement cut off by track_activity_query_size before its closing quote.
          '(\mPASSWORD(?:\s|/\*[\s\S]*?\*/)*)(?:[EU]&?)?(?:''|\$)[\s\S]*',
          '\1''<redacted>''',
          'i'),
        -- A SCRAM verifier. Two additions over 1.0.0 and both were found by testing rather than by
        -- reading:
        --
        --   :  in the class, for the iteration count and for the separator between the two keys.
        --       Without it the pattern cannot get past 4096 and a verifier passed to a function is
        --       stored whole. This is the single most important character in the pattern.
        --   (?:-PLUS)? for the channel-binding variant. PostgreSQL does not store that form, so it
        --       costs nothing, and a verifier in hand is a verifier someone may pass to something.
        --
        -- i, because 1.0.0 matched only the exact case. Still cannot swallow a quote, a bracket or
        -- a space, so it stops at the closing delimiter of the literal it sits in.
        'SCRAM-SHA-256(?:-PLUS)?\$[A-Za-z0-9+/=:$]+',
        'SCRAM-SHA-256$<redacted>',
        'gi'),
      -- An md5 verifier: 'md5' followed by 32 hex digits with no separator. Case-insensitive hex,
      -- since 1.0.0's [0-9a-f] alone missed an uppercase hash.
      'md5[0-9a-fA-F]{32}',
      'md5<redacted>',
      'g'),
    '');
$redact$;

COMMENT ON FUNCTION @extschema@.lock_tree_redact(text) IS
  'Strip password literals, SCRAM verifiers and md5 hashes from query text before it is stored. '
  'Applied by lock_tree_sample() unless lock_tree.history_query says otherwise. Handles the real '
  'SCRAM form SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>, including one passed as a function '
  'argument rather than assigned to a role. Redacting to the end of the statement also removes any '
  'clause following the password, which is deliberate. Two statements differing only in a password '
  'group as one row afterwards, which is usually what you want.';

-- INCLUDE (query_id) added in 1.1.0. lock_tree_duration_by_application() aggregates DISTINCT query_id
-- per application, and without this column in the leaf that step is a bitmap heap scan fetching
-- 24,133 pages to answer a question the index already holds. With it: an Index Only Scan, Heap
-- Fetches 0, 300 buffers, and 117.0 -> 31.2 ms for the step. The whole function goes 2249 -> 2146 ms
-- cold, so this is a 4% win on a two-second function and not the fix for that function.
--
-- The column is INCLUDEd rather than a key column on purpose: it is filtered on but never ranged or
-- sorted, so putting it in the key would widen every internal node as well as every leaf.
CREATE INDEX lock_tree_history_application_idx
  ON @extschema@.lock_tree_history (application_name, sampled_at) INCLUDE (query_id)
  WHERE depth = 0;

COMMENT ON INDEX @extschema@.lock_tree_history_application_idx IS
  'Partial index on the root rows, keyed on application_name, for lock_tree_duration_by_application() '
  'and lock_tree_duration(). Measured against two alternatives; see the release notes.';

COMMENT ON COLUMN @extschema@.lock_tree_history.query_id IS
  'The root''s pg_stat_statements query_id, NULL on waiter rows. A query blocked on a lock has no '
  'query_id until it completes, so only roots carry one; see lock_tree_history_statements().';

COMMENT ON TABLE @extschema@.lock_tree_history IS
  'Sampled lock-wait trees, one row per session per sample. Empty until lock_tree_sample() '
  'is scheduled. Prune it with lock_tree_prune(); it grows by (sessions blocked) rows per sample. '
  'query_id is the ROOT''s pg_stat_statements query_id and is NULL on waiter rows, since a '
  'blocked query has no query_id until it completes; see lock_tree_history_statements().';


-- The cold tier. Same columns as lock_tree_history, on purpose: a row copied across is still the
-- same fact, and a researcher can write ordinary SQL against either table without translating.
--
-- Created empty on every install rather than on demand. An empty table with an empty BRIN index is
-- a few pages, it makes lock_tree_archive() an ordinary batched move with no DDL and therefore no
-- schema privilege, and it means the table is documented and predictable rather than appearing the
-- first time somebody runs a job. The alternative, a function that creates it, would have to be
-- SECURITY DEFINER to be usable by an operator who lacks CREATE on the schema, which is a large
-- privilege to hand a function whose job is to move rows.
--
-- Deliberately NOT registered with pg_dump, on the same reasoning as lock_tree_history and for the
-- same reason: it describes pids and timestamps that mean nothing on the server a restore lands on.
-- A physical backup or a streaming replica will still copy it, which is the argument for
-- re-redacting on the way in rather than trusting the policy in force when each row was sampled.
CREATE TABLE @extschema@.lock_tree_history_archive (
  sampled_at       timestamptz NOT NULL,
  root_pid         int         NOT NULL,
  depth            int         NOT NULL,
  pid              int         NOT NULL,
  state            text,
  waiting_for      text,
  wait_age         interval,
  application_name text,
  query            text,
  root_object      text,
  query_id         bigint
);

-- BRIN and nothing else, which is the whole point of the table being separate.
--
-- sampled_at is append-only, so it is very nearly perfectly correlated with physical order, which is
-- the case BRIN exists for. Measured on a 365-day fixture of 63,072,020 rows and 14 GB: the
-- correlation between sampled_at and a row's block number is 1.000000, and this index came out at
-- 1336 kB where a b-tree on the same column is 475 MB. It still serves a range query: with the
-- b-tree indexes disabled, a 30-day BRIN bitmap scan read 102,389 buffers out of the whole table.
--
-- Four b-trees on the same 1,209,600 rows cost 170 MB, so the index alone is worth about a quarter
-- of the archived table. That is the reason the cold tier is a separate table rather than an old
-- partition of the hot one: it is what makes keeping a year affordable at all.
CREATE INDEX lock_tree_history_archive_brin_idx
  ON @extschema@.lock_tree_history_archive USING brin (sampled_at)
  WITH (pages_per_range = 32);

COMMENT ON TABLE @extschema@.lock_tree_history_archive IS
  'History older than what you keep hot, moved here by lock_tree_archive(). Same columns as '
  'lock_tree_history. Indexed by BRIN on sampled_at and nothing else, which is correct for an '
  'append-only column and is what keeps a year of archive small. NOT read by any shipped function: '
  'lock_tree_incidents(), lock_tree_duration() and the rest read lock_tree_history only, so a since '
  'window silently stops at the archive boundary. Query it with SQL of your own.';

COMMENT ON INDEX @extschema@.lock_tree_history_archive_brin_idx IS
  'BRIN on sampled_at, the only index on the archive. sampled_at is append-only so it correlates '
  'with physical order; measured correlation 1.000000 on a 63M-row fixture.';


-- Take one snapshot. Returns how many rows it wrote, which is 0 on a quiet database: this
-- writes nothing rather than a row saying nothing happened, so an idle server costs one
-- cheap SELECT and no storage at all.
--
-- SECURITY DEFINER so the scheduled job's role needs no INSERT grant on the table. It is a
-- SECURITY DEFINER function that inserts a fixed column list from lock_tree and takes no
-- arguments, so there is nothing for a caller to steer.
CREATE FUNCTION @extschema@.lock_tree_sample()
RETURNS bigint
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  -- The CTE is what makes the return type work. A bare INSERT cannot be the body of a
  -- function returning bigint: SQL requires INSERT ... RETURNING, and RETURNING on a
  -- snapshot of a quiet database yields no rows at all, so the function would return zero
  -- rows rather than 0. Counting inside the CTE gives a row with 0 in it.
  --
  -- search_path is pinned because an unqualified table name cannot resolve under
  -- pg_catalog alone, so @extschema@.lock_tree_history below is qualified explicitly. Both
  -- details were found by trying it rather than by reasoning about it.
  -- Two independent inserts, and BOTH run even though only one is counted. A data-modifying CTE is
  -- executed exactly once whether or not anything selects from it, which is the property that lets
  -- the deadlock sample be written here without changing what this function returns.
  WITH observed AS (
    SELECT d.deadlocks
    FROM pg_stat_database d
    WHERE d.datname = current_database()
  ),
  previous AS (
    SELECT p.deadlocks
    FROM @extschema@.lock_tree_deadlock p
    ORDER BY p.sampled_at DESC
    LIMIT 1
  ),
  recorded AS (
    INSERT INTO @extschema@.lock_tree_deadlock
      (sampled_at, deadlocks, delta, counter_reset)
    SELECT statement_timestamp(),
           o.deadlocks,
           -- Floored, because pg_stat_reset_shared('db') sets the counter to zero and a negative
           -- delta would be nonsense. counter_reset records that it happened so the report can say
           -- the window total is not the sum of the deltas.
           greatest(o.deadlocks - coalesce(p.deadlocks, o.deadlocks), 0),
           p.deadlocks IS NOT NULL AND o.deadlocks < p.deadlocks
    FROM observed o
    LEFT JOIN previous p ON true
    ON CONFLICT (sampled_at) DO UPDATE
      SET deadlocks     = EXCLUDED.deadlocks,
          delta         = EXCLUDED.delta,
          counter_reset = EXCLUDED.counter_reset
    RETURNING 1
  ),
  written AS (
    INSERT INTO @extschema@.lock_tree_history
      (sampled_at, root_pid, depth, pid, state, waiting_for,
       wait_age, application_name, query, root_object, query_id)
    SELECT statement_timestamp(), lt.root_pid, lt.depth, lt.pid, lt.state, lt.waiting_for,
           lt.wait_age, lt.application_name,
           -- Redacted BEFORE truncation, not after, so that a password starting before character
           -- 300 is caught even though the text is cut there. Truncating first would leave a
           -- partial credential in the table for the length of a sample interval times the
           -- retention, which is the whole problem this fixes.
           --
           -- The setting has three values and the default is the safe one:
           --
           --   redacted   strip credentials                     (the default, and the fallback for
           --                                                         any value it does not recognise)
           --   none       store NULL
           --   full       store the query verbatim
           --
           -- A misspelling therefore redacts rather than leaks, which is the only direction an
           -- unrecognised value is allowed to fail in. Set it per session with
           --
           --   SET lock_tree.history_query = 'full';
           --
           -- or per database, which is how you would normally do it:
           --
           --   ALTER DATABASE mydb SET lock_tree.history_query = 'full';
           --
           -- There is no C code in this extension, so the setting is a placeholder GUC rather than
           -- a declared one, and it has no SHOW ALL entry until something sets it. That is why
           -- coalesce() rather than a bare current_setting(): an unset placeholder reads as NULL,
           -- and NULL must mean the safe default rather than an error or a leak.
           CASE coalesce(nullif(current_setting('lock_tree.history_query', true), ''), 'redacted')
             WHEN 'none'  THEN NULL
             WHEN 'full'  THEN left(coalesce(lt.query, ''), 300)
             ELSE left(@extschema@.lock_tree_redact(coalesce(lt.query, '')), 300)
           END,
           lt.root_object,
           -- Each row's OWN query_id, which is why the join is on pid rather than on root_pid.
           -- Joining on root_pid propagates the root's query_id down the whole chain, so every
           -- waiter looks like it was running the blocking statement, which is the normal case
           -- and would make the per-query totals wrong rather than merely incomplete.
           --
           -- What this means in practice: a query blocked on a lock has a NULL query_id for as
           -- long as it is blocked, so only depth-0 rows carry one. Same finding as
           -- lock_tree_statements(), and it is why this is per blocking query.
           ra.query_id
    FROM @extschema@.lock_tree lt
    -- A plain left join rather than a LATERAL subquery, because it is hashed once over the
    -- distinct pids instead of being evaluated per row. root_pid 0 is a prepared transaction,
    -- which is in no session at all and so matches nothing, which is correct.
    --
    -- The view is aliased as lt because pg_stat_activity also has a pid column, and with both in
    -- scope every unqualified pid in the select list is ambiguous.
    LEFT JOIN pg_stat_activity ra ON ra.pid = lt.pid
    RETURNING 1
  )
  SELECT count(*) FROM written
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_sample() IS
  'Take one snapshot of the current lock tree into lock_tree_history. Returns the number of '
  'rows written, which is 0 when nothing is blocked. Schedule it; nothing calls it for you.';

-- PUBLIC loses the right to sample. This has to be in the release file as well as the update
-- script, and check-upgrade.sh is what caught the omission: the upgrade path revoked and the fresh
-- install did not, so every new install would have kept the hole this release exists to close.
--
-- The grant is not restored for anyone, deliberately. A role that had it could read every session's
-- query text through it, because the function is SECURITY DEFINER, and reinstating that silently
-- would put the hole back. INSTALL.md tells the scheduling role what to grant.
REVOKE EXECUTE ON FUNCTION @extschema@.lock_tree_sample() FROM PUBLIC;



-- Drop history older than a given age, returning how many rows went.
--
-- This exists because the table grows without bound otherwise: rows are only ever added,
-- and a wide queue at one sample a minute is 60 rows a minute for every session in it.
-- Pruning is a policy choice, so it is a parameter and not a scheduled job. A sensible
-- starting point is a day, or a week if you are chasing a rare one.
--
-- DELETE rather than TRUNCATE because TRUNCATE would take the whole table including rows
-- you wanted to keep.
CREATE FUNCTION @extschema@.lock_tree_prune(older_than interval)
RETURNS bigint
LANGUAGE sql
AS $$
  -- RETURNING 1 for the same reason as above: without it the CTE cannot be counted.
  --
  -- The deadlock samples are pruned by the same call, and the return value deliberately counts only
  -- the HISTORY rows. That is the number every existing caller reads, and it is the number that
  -- tells you whether the table you care about shrank. Including the deadlock rows would change the
  -- meaning of a function that has returned a history count since 0.4, and at a five second sample
  -- interval it would inflate the figure by a factor of the sample rate for no benefit. One call to
  -- remember rather than two is worth the asymmetry, and this comment is where that lives.
  WITH pruned AS (
    DELETE FROM @extschema@.lock_tree_history
    WHERE sampled_at < statement_timestamp() - older_than
    RETURNING 1
  ),
  -- Not counted, but not optional either: a deadlock sample that is never pruned grows by one row
  -- per sample forever, and an unpruned table is how a diagnostic tool becomes an outage.
  dropped AS (
    DELETE FROM @extschema@.lock_tree_deadlock
    WHERE sampled_at < statement_timestamp() - older_than
    RETURNING 1
  )
  SELECT count(*) FROM pruned
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_prune(interval) IS
  'Delete lock_tree_history rows older than the given age; returns how many. Call it on the '
  'same schedule as the sample. The table grows by one row per blocked session per sample '
  'otherwise, with nothing to stop it.';


-- The question this whole section exists to answer: "it was hanging earlier, what was it?"
--
-- An incident is a run of samples with no gap longer than max_gap between them. The default
-- of five minutes suits a sample every ten seconds or so, and is a parameter because the
-- right answer depends on how often you sample: too small and one incident splits into
-- several, too large and two incidents merge into one.
--
-- peak_sessions is the high-water mark of sessions blocked at any sample, not the sum, since
-- a session counted at four samples was not four sessions.
-- since added in 1.1.0, and it goes AFTER max_gap on purpose. Both test/07 and
-- docs/after-the-incident.md call this positionally, so a new first parameter would reinterpret
-- their argument: lock_tree_incidents(interval '7 days') would become a window rather than a gap.
--
-- The default is NULL, meaning no bound, which is exactly what the function did before 1.1.0. A
-- default of '7 days' would match its neighbours and be wrong here: it would compile every existing
-- call site and then quietly return fewer incidents than it used to on any database holding more
-- than a week, which is a behaviour change wearing an additive change's clothes.
CREATE FUNCTION @extschema@.lock_tree_incidents(
  max_gap interval DEFAULT interval '5 minutes',
  since    interval DEFAULT NULL
)
RETURNS TABLE (
  incident      bigint,
  started_at    timestamptz,
  ended_at      timestamptz,
  samples       bigint,
  peak_sessions bigint,
  peak_depth    int,
  longest_wait  interval,
  roots         int[],
  applications  text[],
  -- Added in 0.8. The roots array cannot express two prepared transactions, which are both pid 0,
  -- so it showed one entry for two incidents. This names what each was holding.
  root_objects  text[]
)
LANGUAGE sql STABLE
AS $$
  -- Collapse the per-session rows to one row per sample first, so "how many sessions were
  -- blocked at 14:20" is stored rather than re-derived by counting rows per timestamp in
  -- the outer aggregate.
  WITH per_sample AS (
    SELECT sampled_at,
           count(*)::bigint AS sessions,
           max(depth)::int  AS depth,
           max(wait_age)    AS wait_age
    FROM @extschema@.lock_tree_history
    -- coalesce, not "since IS NULL OR sampled_at >= ...". The OR form cannot become an Index Cond,
    -- so it would make even a call with no arguments scan the whole index. This keeps the form the
    -- planner can seek with, and a NULL since becomes -infinity, which every row passes.
    WHERE sampled_at >= coalesce(statement_timestamp() - since, '-infinity'::timestamptz)
    GROUP BY sampled_at
  ),
  stamped AS (
    SELECT ps.*,
           lag(sampled_at) OVER (ORDER BY sampled_at) AS prev
    FROM per_sample ps
  ),
  marked AS (
    SELECT s.*,
           -- A running sum of "a gap this big starts a new incident", so each sample is
           -- labelled with the incident it belongs to and the labels are then grouped.
           sum(CASE WHEN prev IS NULL OR sampled_at - prev > max_gap THEN 1 ELSE 0 END)
             OVER (ORDER BY sampled_at) AS incident
    FROM stamped s
  )
  SELECT m.incident::bigint,
         min(m.sampled_at),
         max(m.sampled_at),
         count(*)::bigint,
         max(m.sessions)::bigint,
         max(m.depth)::int,
         max(m.wait_age),
         -- Roots and applications are per-session facts, so they come from the raw rows
         -- rather than from per_sample. An array of per-sample arrays is not a shape anyone
         -- wants to read. Scoped to the incident's own time range, and indexed on sampled_at.
         --
         -- The DISTINCT is taken in a subquery before the array is built, not inside array_agg
         -- (1.1.2). array_agg(DISTINCT x ORDER BY x) sorts every row in the incident's range to
         -- emit a handful of values, and on a seven-day history that sort spilled to disk once per
         -- column. A bare DISTINCT is a hash aggregate, and only the distinct values are sorted.
         -- The result is the same, NULLs included: DISTINCT keeps one NULL and array_agg keeps it,
         -- sorted last, exactly as array_agg(DISTINCT ...) did. applications has always carried a
         -- NULL element when a session had no application_name, and still does.
         (SELECT array_agg(d.root_pid ORDER BY d.root_pid)
            FROM (SELECT DISTINCT h.root_pid
                    FROM @extschema@.lock_tree_history h
                   WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)) d),
         (SELECT array_agg(d.application_name ORDER BY d.application_name)
            FROM (SELECT DISTINCT h.application_name
                    FROM @extschema@.lock_tree_history h
                   WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)) d),
         -- Nulls excluded rather than rendered as empty strings: an empty element in this array
         -- would be indistinguishable from a prepared root whose object could not be resolved,
         -- and neither is worth a slot.
         (SELECT array_agg(d.root_object ORDER BY d.root_object)
            FROM (SELECT DISTINCT h.root_object
                    FROM @extschema@.lock_tree_history h
                   WHERE h.sampled_at BETWEEN min(m.sampled_at) AND max(m.sampled_at)
                     AND h.root_object IS NOT NULL) d)
  FROM marked m
  GROUP BY m.incident
  ORDER BY min(m.sampled_at)
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_incidents(interval, interval) IS
  'The sampled history grouped into incidents: runs of samples with no gap longer than '
  'max_gap (default 5 minutes). For each, when it ran, how many sessions were blocked at '
  'the worst, the deepest chain, the longest wait, and which root pids and application names '
  'were involved. Empty history returns no rows rather than an error. since (added 1.1.0) bounds '
  'the window and defaults to NULL, meaning all retained history, which is what this did before.';



--------------------------------------------------------------------------------
-- what the history costs
--------------------------------------------------------------------------------

-- The question partitioning was proposed to answer, answered without it.
--
-- "Is this table going to fill the disk" is a question about a RATE, and a rate needs two samples
-- and the interval between them. This reports both, and projects from them. Everything is measured
-- from the table itself rather than assumed, so a database that has never been sampled gets zeros
-- and says so rather than a confident number with nothing behind it.
--
-- pg_total_relation_size is used deliberately over summing the parts: it accounts for the TOAST
-- table and the free space map, which a hand-rolled sum of pg_relation_size silently misses. The
-- number is what the disk is charged, so that is the number to report.
CREATE FUNCTION @extschema@.lock_tree_history_size()
RETURNS TABLE (
  rows             bigint,
  samples          bigint,
  total_bytes      bigint,
  oldest           timestamptz,
  newest           timestamptz,
  observed_every   interval,
  bytes_per_day    bigint,
  days_to_1gb      numeric,
  -- Added in 1.1.7, and APPENDED deliberately. The eight columns above are read by name in
  -- test/15_history_size.sql and by anyone who copied the documented output, so their names, order,
  -- types and meanings are unchanged and the new ones go after. A caller doing SELECT * on this
  -- function gets four extra columns, which is the one visible consequence: the project already
  -- documents SELECT * on the tables as outside the contract, and this is the first function to
  -- extend its output rather than change it.
  -- ONE column, not four, and the reduction was measured rather than preferred. archive_bytes alone
  -- fixes what 1.1.6 got wrong, which is that this function could not see the archive at all and so
  -- understated on-disk history by whatever had been moved out. An archive row count, its oldest row
  -- and its newest row were all drafted and all removed: count(*), min and max each need a full
  -- sequential scan of the archive, 495 ms at 12,300,000 rows and growing linearly, where
  -- pg_total_relation_size is a catalog read measuring 0.9 to 1.1 ms at the same size. That would
  -- have re-introduced into this function exactly the flaw it already has, namely that its cost
  -- follows retention, and for figures nobody needs it to give: an operator sizing a disk needs the
  -- bytes, and a row count in a BRIN-indexed table is a `SELECT count(*)` away whenever it is wanted.
  archive_bytes     bigint
)
LANGUAGE sql STABLE
AS $$
  WITH facts AS (
    SELECT count(*)::bigint                        AS n_rows,
           count(DISTINCT sampled_at)::bigint       AS n_samples,
           min(sampled_at)                          AS lo,
           max(sampled_at)                          AS hi
    FROM @extschema@.lock_tree_history
  ),
  -- The archive's size, and nothing else. Added in 1.1.7 because 1.1.6 shipped an archive this
  -- function could not see, so it understated on-disk history by however much had been moved out,
  -- which is the exact number an operator sizing a disk needs.
  --
  -- pg_total_relation_size is a catalog read, measured at 0.9 to 1.1 ms against a 707 MB archive and
  -- 1.2 ms against the hot table, so it does not grow with the table the way anything derived from
  -- the rows does. That is why this is the only archive figure, and why the draft that also reported
  -- rows, oldest and newest was cut: those need a sequential scan, 495 ms at 12,300,000 rows.
  arch_sized AS (
    SELECT pg_total_relation_size('@extschema@.lock_tree_history_archive')::bigint AS a_bytes
  ),
  sized AS (
    SELECT pg_total_relation_size('@extschema@.lock_tree_history')::bigint AS bytes
  ),
  -- The mean gap between consecutive samples, which is the sample interval the operator actually
  -- chose rather than the one they believe they chose. Computed as (span) / (gaps) rather than by
  -- averaging intervals, because averaging intervals weights a long gap the same as a short one and
  -- the span is the thing that has to be divided.
  rated AS (
    SELECT CASE WHEN f.n_samples > 1
                THEN (f.hi - f.lo) / (f.n_samples - 1)
                ELSE NULL END AS every,
           f.*
    FROM facts f
  )
  SELECT r.n_rows,
         r.n_samples,
         sz.bytes,
         r.lo,
         r.hi,
         r.every,
         -- bytes per day, from the observed rate. A single sample gives NULL rather than infinity,
         -- because there is no rate to report and a large number would be a guess.
         CASE WHEN r.every IS NULL OR r.every <= interval '0' THEN NULL
              ELSE (sz.bytes::numeric / greatest(extract(epoch FROM r.every), 1)
                    * 86400)::bigint
         END,
         -- days until the table reaches a gigabyte, which is the number to put in a monitoring
         -- alert. NULL when the rate is unknown, for the same reason.
         CASE WHEN r.every IS NULL OR r.every <= interval '0' THEN NULL
              ELSE round((1073741824::numeric - sz.bytes)
                         / greatest((sz.bytes::numeric
                                     / greatest(extract(epoch FROM r.every), 1) * 86400), 1), 1)
       END,
         -- The archive's bytes, NOT folded into the ones above. Adding them into total_bytes was
         -- rejected: that column is part of a rate projection built on the observed sample interval
         -- of ONE table, and a second table with its own interval and its own extent does not belong
         -- in that arithmetic. A reader wanting the whole total adds archive_bytes to total_bytes,
         -- which is arithmetic they can see rather than a number they have to trust.
         az.a_bytes
  FROM rated r
  CROSS JOIN sized sz
    CROSS JOIN arch_sized az
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_history_size() IS
  'What the sampled history costs and what it will cost at the rate it is already being written: '
  'row and sample counts, total bytes including TOAST and free space map, the oldest and newest '
  'sample, the observed sample interval, bytes per day, and the days until the table reaches a '
  'gigabyte. Everything is measured from the table, so an unsampled database gets zeros and a NULL '
  'rate rather than a confident number with nothing behind it. Use it to decide when to prune, or '
  'whether the sample interval is wrong. '
  ''
  'archive_bytes, added in 1.1.7, is the size of lock_tree_history_archive, which 1.1.6 added and'
  'this function could not see, so before 1.1.7 it understated on-disk history by however much had'
  'been moved out. It is reported separately and NOT added into total_bytes, because that column'
  'is part of a rate projection built on the sample interval of ONE table and a second table with'
  'its own interval does not belong in that arithmetic. Add the two yourself for a whole-database'
  'figure: total_bytes + archive_bytes.'
  ''
  'It is the only archive figure, and the reduction was measured. An archive row count, oldest and'
  'newest were all drafted and removed: each needs a full sequential scan of the archive, 495 ms'
  'at 12,300,000 rows, where pg_total_relation_size is a catalog read at 0.9 to 1.1 ms. Adding'
  'them would have given this function a second cost that follows retention, which is the one flaw'
  'it already has.';


-- Prune in committed batches.
--
-- lock_tree_prune() is one DELETE: it is simple, it is fast, and on a large table it holds its locks
-- for the whole of it and leaves the free space behind for VACUUM to find. This is the same delete
-- in slices, with a COMMIT between them, so no single lock is held for the length of the whole
-- operation and a long prune can be watched, or interrupted, without stopping writers.
--
-- A procedure rather than a function, and that is the entire reason it works: only a procedure
-- called outside a transaction block may COMMIT, and a batched prune that cannot commit between
-- batches is a batched prune that still holds everything.
--
--   CALL lock_tree_prune_batched(interval '7 days');
--
-- Returns nothing, so the count is not available. That is not an oversight: a CALL cannot return
-- anything to the client, and the count is available afterwards as the row count of the table.
-- Returns the count through GET DIAGNOSTICS into a notice instead, so a batched run in a script
-- still says what it did.
CREATE PROCEDURE @extschema@.lock_tree_prune_batched(
  older_than interval,
  batch_size integer DEFAULT 10000
)
LANGUAGE plpgsql
AS $proc$
DECLARE
  total bigint := 0;
  took  bigint;
  n     integer;
BEGIN
  IF batch_size IS NULL OR batch_size < 1 THEN
    RAISE EXCEPTION
      'lock_tree_prune_batched() needs batch_size >= 1, got %', coalesce(batch_size::text, 'NULL');
  END IF;

  -- Check for a transaction block before deleting anything.
  --
  -- PostgreSQL exposes no way to ask, so the only way to find out is to COMMIT and see. Doing that
  -- here rather than at the first batch means that calling this inside BEGIN/COMMIT fails having
  -- deleted NOTHING, rather than failing part-way through with half the table gone.
  --
  -- No exception handler around it, deliberately. A plpgsql block with an EXCEPTION clause runs in
  -- a subtransaction, and a COMMIT is never allowed in one, so the check would fail every time
  -- rather than only inside a transaction block. That was the first version, and it refused to work
  -- outside a transaction block too.
  --
  -- The error PostgreSQL raises here is "invalid transaction termination", which does not say why.
  -- The COMMENT ON this procedure says what it means, and the README shows the working call.
  COMMIT;

  LOOP
    -- One batch, chosen by primary key rather than by OFFSET. OFFSET is O(rows skipped), so the
    -- tenth batch walks past every row already deleted and the last one is quadratic in the number
    -- of batches. The index on sampled_at makes this a bounded range scan instead.
    DELETE FROM @extschema@.lock_tree_history h
     WHERE h.ctid IN (
             SELECT c.ctid
             FROM @extschema@.lock_tree_history c
             WHERE c.sampled_at < statement_timestamp() - older_than
             LIMIT batch_size
           );
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
    EXIT WHEN n = 0;
    COMMIT;
  END LOOP;

  -- The deadlock samples too, for the same reason lock_tree_prune() does them. Deleted in one
  -- statement rather than in batches, because there is one row per sample rather than one per
  -- blocked session, so it is already a thousand times smaller.
  DELETE FROM @extschema@.lock_tree_deadlock
   WHERE sampled_at < statement_timestamp() - older_than;

  RAISE NOTICE 'lock_tree_prune_batched: removed % history rows older than %', total, older_than;
END
$proc$;

-- Move old history into the cold tier, in committed batches, so a large move is not one long
-- transaction and does not double your peak disk in a single statement.
--
--   CALL lock_tree_archive(interval '30 days');
--
-- A procedure rather than a function, for the same reason lock_tree_prune_batched() is: only a
-- procedure called outside a transaction block may COMMIT, and batching without committing between
-- batches still holds everything. It also refuses to run inside BEGIN/COMMIT before touching a row,
-- for the same reason and by the same means, which is the COMMIT-and-see trick that needs no
-- exception handler because a handler would put the COMMIT in a subtransaction where it is refused.
--
-- The reason to batch rather than use one INSERT ... SELECT is measured. Moving a whole 365-day
-- history, 61,862,400 rows, in one statement took 298 seconds and roughly doubled peak disk while it
-- ran, because every row exists in both tables until the source rows are deleted. The same move a
-- week at a time, 1,209,600 rows, takes 1.8 seconds. So the cost of archiving is a function of the
-- batch, not of the year, and this procedure exists to keep the batch small.
--
-- Re-redacting on the way across is a security decision, not a copy detail. lock_tree_sample()
-- applies lock_tree_redact() on the way IN, under whatever lock_tree.history_query said at the time,
-- so a row sampled while that was 'full' carries a verbatim query. Copying it to a table that is
-- meant to be kept for years would then preserve, indefinitely, whatever the policy was on the day
-- it was captured, which is not the policy anybody is running now. Applying the function again on the
-- move costs one call per row on a 1.8 second job and makes the archive strictly safer than its
-- source: a row archived under a lax policy stops being one.
--
-- NOT a snapshot of the table, and not transactional across batches. A crash midway leaves rows in
-- both tables, which is harmless because the archive is read by nothing shipped and a repeated call
-- moves whatever is left. There is no unique constraint to make the second pass fail, and failing
-- would be the wrong behaviour: the rows are identical and duplicating them would be the actual
-- problem, so the procedure moves only what is still in the hot table.
-- Search the archive. The first shipped function that reads lock_tree_history_archive, and the
-- other half of what 1.1.6 shipped as a write-only table.
--
-- It searches ONLY the archive. It does not span hot and cold, and that is a decision with a
-- measurement behind it rather than a shortcut. Teaching the existing read functions to span both
-- was tried in 1.1.6 and measured: with the archive as a UNION ALL on the inner side of the
-- root-to-waiter join, the planner stops choosing the index probe and a Nested Loop Semi Join at
-- 96 ms becomes a HashAggregate over a sequential scan of both tables at 924 ms, and an EMPTY
-- archive still costs 50%, so installations that never archive would pay for a feature they do not
-- use. Nothing here is a join, so that specific penalty does not apply, but the reasoning transfers:
-- a function that reads two tables is two queries to reason about, and the boundary is where a caller
-- is most likely to get a silently short answer.
--
-- The window is REQUIRED, and that is measured rather than stylistic. On a fixture of 10,160,640
-- archived rows spanning 16 days:
--
--   1-day window     1.6 ms     Bitmap Heap Scan on the BRIN index
--   7-day window     1.5 ms     Bitmap Heap Scan on the BRIN index
--   14-day window    1.4 ms     Bitmap Heap Scan on the BRIN index
--   no window        did not finish in 10 minutes
--
-- The bounded cases are flat because the BRIN prunes the other ranges away, which is the entire
-- reason the archive is BRIN-indexed. The unbounded case is a sequential scan plus a hash aggregate
-- over ten million rows, and it is the same work an unbounded lock_tree_incidents() does on the hot
-- table, which is why that function's own default is NULL and this one's is not. Requiring a bound
-- turns a query that hangs into one that is refused, and the error says what the bound buys.
--
-- plpgsql, not sql, and that is forced by the guard. See lock_tree_archive_since_guard() below for
-- what went wrong with the SQL version and why a plan shape cannot express this check.
CREATE FUNCTION @extschema@.lock_tree_archive_find(
  since        interval,
  until        interval DEFAULT NULL,
  waiting_like text     DEFAULT NULL,
  application  text     DEFAULT NULL,
  min_wait     interval DEFAULT NULL,
  limit_rows   integer  DEFAULT 200
)
RETURNS TABLE (
  sampled_at    timestamptz,
  samples       bigint,
  peak_sessions int,
  longest_wait  interval,
  total_wait    interval,
  applications  text[],
  queries       text[]
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  -- The check, first, before the query is assembled. It raises rather than returning a flag, so a
  -- caller that passes NULL gets an error naming the measurement rather than an empty answer.
  PERFORM @extschema@.lock_tree_archive_since_guard(since);

  -- One row per sample instant inside the window, and only samples that matched. Counting rows per
  -- timestamp is what a reader wants from an archive: how wide the queue got and for how long, not
  -- one row per blocked session per sample, which is the grain the history is stored at and which
  -- nobody wants to read directly.
  --
  -- The window is applied to sampled_at in both directions. until is optional and defaults to the
  -- present, which is a sensible thing for it to mean and is bounded; since is not optional because
  -- unbounded is the failure the guard exists to stop.
  --
  -- The LIKE on waiting_for is the one thing this does that no shipped function does, because "what
  -- contended" is not something the live tree can answer and is the main reason to keep an archive.
  -- A sequential scan is the right plan for it: BRIN cannot help a pattern match, and on the archive
  -- there is no hot path to protect. The exact-match filters on application_name and the window on
  -- sampled_at are all things the BRIN or an index can serve, so the planner chooses.
  RETURN QUERY
  WITH matched AS (
    SELECT a.sampled_at, a.pid, a.wait_age, a.application_name, a.query
    FROM @extschema@.lock_tree_history_archive a
    WHERE a.sampled_at >= statement_timestamp() - since
      AND a.sampled_at < coalesce(statement_timestamp() - until, statement_timestamp())
      -- NULL passes, so a caller who does not care about the lock tag does not have to name one.
      -- ILIKE rather than LIKE because a lock tag is a relation name and nobody types its case.
      AND (waiting_like IS NULL OR a.waiting_for ILIKE '%' || waiting_like || '%')
      AND (application IS NULL OR a.application_name = application)
      -- A null wait_age on a root row is not a short wait, it is an unrecorded one, so the
      -- comparison is explicit rather than relying on NULL ordering.
      AND (min_wait IS NULL
           OR (a.wait_age IS NOT NULL AND a.wait_age >= min_wait))
  ),
  per_sample AS (
    SELECT m.sampled_at,
           count(*)::int                          AS peak_sessions,
           max(m.wait_age)                        AS longest_wait,
           sum(coalesce(m.wait_age, interval '0')) AS total_wait,
           -- NULL elements excluded rather than rendered as empty: an empty application name in
           -- this array would be indistinguishable from a session that set one to the empty string,
           -- and lock_tree_duration_by_application() reports the empty case as its own row for the
           -- same reason.
           array_agg(DISTINCT m.application_name) FILTER (WHERE m.application_name IS NOT NULL)
                                                    AS applications,
           -- The distinct statements rather than one per session, because a sample of twelve waiters
           -- on the same SELECT is one statement that happened twelve times.
           array_agg(DISTINCT m.query) FILTER (WHERE m.query IS NOT NULL AND m.query <> '')
                                                    AS queries
    FROM matched m
    GROUP BY m.sampled_at
  )
  SELECT p.sampled_at,
         1::bigint   AS samples,
         p.peak_sessions,
         p.longest_wait,
         p.total_wait,
         p.applications,
         p.queries
  FROM per_sample p
  -- Newest first, and capped. A caller searching an archive is looking for when something happened,
  -- not for a census, and an uncapped result from a year of history is a result nobody reads.
  -- The cap is applied OUTSIDE the aggregation, so the per-sample figures are not silently wrong:
  -- only the number of instants returned is limited.
  ORDER BY p.sampled_at DESC
  LIMIT greatest(coalesce(limit_rows, 200), 1);
END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_archive_find(interval, interval, text, text, interval, integer) IS
  'Search lock_tree_history_archive, and ONLY the archive: a since window is required, and until defaults to now. One row per sample instant that matched, newest first, capped at limit_rows which defaults to 200, so a search over a year of history returns something readable. Filters: waiting_like matches anywhere in the lock tag and is case-insensitive, application is an exact application_name, min_wait drops samples whose wait was below it. All filters are optional and a NULL filter matches everything. The bound is required and that is measured rather than stylistic: on 10,160,640 archived rows spanning 16 days a 7-day window returns in 1.5 ms using the BRIN index, and an unbounded query over the same rows did not finish in 10 minutes. This is the only shipped function that reads the archive. It does not read the hot table, so a window that reaches into the last few days returns only what was already archived: use lock_tree_incidents() or lock_tree_replay() for the hot end and combine the two yourself. waiting_for is NULL on root rows, so a search for a lock tag finds the waiters and not the blockers holding them.';

-- The argument check, as a function of its own because it needs to RAISE and lock_tree_archive_find()
-- is the caller. Its only purpose is to be called by that function; calling it directly does nothing
-- useful.
--
-- VOLATILE, and that is load-bearing rather than sloppy. It was written STABLE first, on the
-- reasoning that it only inspects its argument, and the guard then SILENTLY DID NOT FIRE. A STABLE
-- function whose result feeds nothing but a filter is inlined and dropped by the planner: EXPLAIN
-- showed a plan with no call to it at all. Rewritten VOLATILE the call appeared in the plan and
-- STILL did not fire, because it sat below the calling function's own LIMIT, and a query that
-- returns no rows never reaches the node beneath it. The plan showed the call present and
-- unreachable, which is the worst of both: visible in EXPLAIN, absent in behaviour.
--
-- VOLATILE is the guarantee the planner must honour, so it is not constant-folded, not hoisted above
-- the scan, and not reordered past the point where it matters. The cost is that it is never skipped,
-- which is the entire intent: it is an argument check, not a computation.
CREATE FUNCTION @extschema@.lock_tree_archive_since_guard(since interval)
RETURNS boolean
LANGUAGE plpgsql VOLATILE
AS $$
BEGIN
  IF since IS NULL THEN
    RAISE EXCEPTION
      'lock_tree_archive_find() needs a since window. Measured on 10,160,640 archived rows spanning 16 days: a 7-day window returns in 1.5 ms using the BRIN index, and an unbounded query over the same rows did not finish in 10 minutes. Pass a since, or write the query yourself against lock_tree_history_archive, which is a plain table and will scan it.'
      USING ERRCODE = '22023';
  END IF;
  RETURN true;
END
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_archive_since_guard(interval) IS
  'Refuses a NULL window for lock_tree_archive_find(), which needs a bound and cannot enforce one from a SQL body: a guard joined into the query is below its LIMIT and is never reached. Not useful on its own, call lock_tree_archive_find() instead.';

-- REVOKE, matching lock_tree_sample() and for the same reason. The guard raises, so a role that can
-- reach it can be told what the table is for by calling it, which is harmless; but the convention
-- here is that a function this project considers part of its own machinery is not PUBLIC, and an
-- operator granting EXECUTE on one of these is granting it without having read the argument list.
--
-- Deliberately NOT revoking lock_tree_archive(), the PROCEDURE, even though the sibling functions
-- are revoked. That one is called by an operator's scheduled job and has to be callable by whoever
-- runs it, and lock_tree_prune_batched() is PUBLIC for the same reason. The distinction is who calls
-- it: a function nobody is meant to call by accident is revoked, and a procedure an operator
-- schedules is not.
REVOKE EXECUTE ON FUNCTION @extschema@.lock_tree_archive_find(interval, interval, text, text, interval, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.lock_tree_archive_since_guard(interval) FROM PUBLIC;

CREATE PROCEDURE @extschema@.lock_tree_archive(
  older_than interval,
  batch_size integer DEFAULT 10000
)
LANGUAGE plpgsql
AS $proc$
DECLARE
  cutoff   timestamptz;
  total    bigint := 0;
  n        integer;
  batch    tid[];
BEGIN
  IF older_than IS NULL THEN
    RAISE EXCEPTION 'lock_tree_archive() needs older_than, got NULL';
  END IF;
  IF batch_size IS NULL OR batch_size < 1 THEN
    RAISE EXCEPTION
      'lock_tree_archive() needs batch_size >= 1, got %', coalesce(batch_size::text, 'NULL');
  END IF;

  -- No exception handler, deliberately: a plpgsql block with an EXCEPTION clause runs in a
  -- subtransaction and COMMIT is never allowed in one, so this would fail every time rather than
  -- only inside a transaction block. That was the first version of lock_tree_prune_batched() and it
  -- refused to work outside a transaction block too.
  COMMIT;

  -- Frozen once, outside the loop. statement_timestamp() moves as the batches commit, so a cutoff
  -- recomputed per batch would drift and the last batches would move a slightly different set than
  -- the first. These functions do not agree with themselves across two calls for the same reason,
  -- and here the drift would be written to disk rather than merely printed.
  cutoff := statement_timestamp() - older_than;

  LOOP
    -- One batch, chosen by the sampled_at index and then captured by ctid, so that the INSERT and
    -- the DELETE below act on provably the SAME rows.
    --
    -- The obvious version of this loop, and it is the version that was written first, is
    --
    --   INSERT INTO archive SELECT ... WHERE sampled_at < cutoff ORDER BY sampled_at LIMIT batch_size;
    --   DELETE FROM history  WHERE ctid IN (SELECT ctid ... ORDER BY sampled_at LIMIT batch_size);
    --
    -- and it does not work. Measured on the 62-row test fixture with batch_size 7, against 20-row
    -- ties, it produced 34 rows in the archive from 21 that were eligible: thirteen duplicates. Then
    -- it looped forever, because the DELETE's subquery kept selecting rows that the INSERT had
    -- already taken, so the count of eligible rows never fell and the EXIT was never reached. It was
    -- killed after 179 seconds having moved a table of 21 rows, and it would have run until someone
    -- noticed, growing the archive on every pass.
    --
    -- The reason is that the two statements do not see the same rows, and neither is wrong on its
    -- own. The INSERT and the DELETE take independent LIMIT batches, sampled_at is not unique
    -- because twenty sessions share one sample, and rows inserted by this loop are still present in
    -- the source for the DELETE's subquery to find. Ordering by sampled_at does not help, because the
    -- rows inside a tie are in no defined order.
    --
    -- Capturing the ctids once and using that one set for both statements is what makes the pair
    -- converge: the INSERT copies exactly what the DELETE then removes, so the eligible count falls
    -- by batch_size every pass and the loop terminates. It is also why this is not one statement.
    --
    -- ctid is the row identity because the table has no primary key. It is stable between the
    -- capture and the delete because nothing commits in between and nothing here updates or moves a
    -- row, so the only hazard, a concurrent VACUUM FULL relocating rows, needs ACCESS EXCLUSIVE and
    -- cannot have it while this transaction holds the rows it named.
    --
    -- The whole array is captured rather than a page of it because the DELETE has to remove exactly
    -- what was inserted, and because the alternative, two independent LIMIT batches, both duplicates
    -- rows and never converges. The reasoning and the measurement are above.
    SELECT array_agg(c.ctid) INTO batch
    FROM (
      SELECT ctid
      FROM @extschema@.lock_tree_history
      WHERE sampled_at < cutoff
      ORDER BY sampled_at
      LIMIT batch_size
    ) c;

    EXIT WHEN batch IS NULL;

    -- lock_tree_redact() on the query column is the re-redaction described above. It is IMMUTABLE, so
    -- this costs nothing beyond the call, and the NULL test keeps a NULL query NULL rather than
    -- turning it into an empty string, which matters because lock_tree.history_query = 'none' stores
    -- NULL and an empty string would read as a query that was genuinely blank.
    INSERT INTO @extschema@.lock_tree_history_archive (
      sampled_at, root_pid, depth, pid, state, waiting_for, wait_age,
      application_name, query, root_object, query_id
    )
    SELECT h.sampled_at, h.root_pid, h.depth, h.pid, h.state, h.waiting_for, h.wait_age,
           h.application_name,
           CASE WHEN h.query IS NULL THEN NULL ELSE @extschema@.lock_tree_redact(h.query) END,
           h.root_object, h.query_id
    FROM @extschema@.lock_tree_history h
    WHERE h.ctid = ANY(batch);

    DELETE FROM @extschema@.lock_tree_history h
     WHERE h.ctid = ANY(batch);
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;

    COMMIT;
  END LOOP;

  RAISE NOTICE
    'lock_tree_archive: moved % history rows older than % into lock_tree_history_archive',
    total, older_than;
END
$proc$;

COMMENT ON PROCEDURE @extschema@.lock_tree_archive(interval, integer) IS
  'Move history older than an age into lock_tree_history_archive, in committed batches of '
  'batch_size, so no single transaction holds everything and no single statement doubles your peak '
  'disk. Re-applies lock_tree_redact() to the query text as rows cross, so the archive cannot '
  'preserve a laxer redaction policy than the one you run now. A procedure, not a function, because '
  'only a procedure called outside a transaction block may COMMIT. Put the CALL on its own line: '
  'inside BEGIN/COMMIT it is refused, and it checks for that before moving anything. No shipped '
  'read function reads the archive. '
  ''
  'The grants, because the error names the table and not the missing privilege. This procedure is '
  'SECURITY INVOKER and needs, measured one at a time: SELECT and DELETE on lock_tree_history, '
  'SELECT and INSERT on lock_tree_history_archive, and EXECUTE here. The monitoring grants for '
  'reading the history are not enough and none of them carry over. See INSTALL.md, Grants for the '
  'archive. DELETE is the wide one: a role that can call this can destroy history, so it belongs '
  'to a maintenance role rather than a monitoring one. '
  ''
  'Two things this deliberately does not do, since both would otherwise be discovered by their '
  'absence: it does not prune the archive, which only shrinks if you delete from it yourself, and '
  'lock_tree_history_size() does not count it, so that function understates your on-disk history '
  'by however much you have archived.';

COMMENT ON PROCEDURE @extschema@.lock_tree_prune_batched(interval, integer) IS
  'Prune lock_tree_history in committed batches of batch_size, so no single lock is held for the '
  'whole operation and a long prune can be watched or interrupted without stopping writers. '
  'Removes the deadlock samples too. A procedure, not a function, because only a procedure called '
  'outside a transaction block may COMMIT, and batching without committing between batches still '
  'holds everything. Cannot be called from inside a transaction block. Returns nothing to the '
  'client; the row count is raised as a notice.';


--------------------------------------------------------------------------------
-- knowing when it is over
--------------------------------------------------------------------------------

-- One extra notification per root that HAD notified and has since stopped. Not a new event type on
-- the same meaning: the payload carries 'cleared' in place of 'alerting', so a listener written
-- against 0.6 that ignores unknown payloads is unaffected, and one that switches on the field gets
-- the pair it needs.
--
-- Off by default, deliberately. A resolution notice is a second page, and whether an incident ending
-- is worth waking someone is a property of the rota rather than of the extension. Someone who wants
-- the pager to stay quiet and the dashboard to be exact sets it off; someone whose incident channel
-- is a shared room turns it on and the room learns it is safe.
--
-- A notification that is not accompanied by one saying it started is noise, so the sweep only
-- reports a root it had previously stored. That is the `fired` CTE's whole job: it reads the rows
-- about to be deleted, so a root never alerted is never 'cleared'.
CREATE FUNCTION @extschema@.lock_tree_notify_resolved(
  channel      text     DEFAULT 'lock_tree',
  min_blocked  integer  DEFAULT 1,
  min_depth    integer  DEFAULT 2,
  min_wait     interval DEFAULT '30 seconds'
)
RETURNS bigint
LANGUAGE plpgsql
AS $fn$
DECLARE
  gone record;
  n    bigint := 0;
BEGIN
  -- The same policy key construction as lock_tree_notify(), so the two read and write the same
  -- rows. If they disagreed, this would report resolutions for alerts that were never sent.
  FOR gone IN
    SELECT a.root_pid, a.root_object, a.application_name, a.max_blocked_at, a.notify_count
    FROM @extschema@.lock_tree_alert a
    LEFT JOIN @extschema@.lock_tree t
      ON t.root_pid = a.root_pid
     AND coalesce(t.root_object, '') = a.root_object
    WHERE a.channel = lock_tree_notify_resolved.channel
      AND a.policy  = format('blocked>=%s depth>=%s wait>=%s',
                             coalesce(CASE WHEN min_blocked IS NULL OR min_blocked < 1 THEN NULL
                                          ELSE min_blocked END::text, 'off'),
                             coalesce(CASE WHEN min_depth   IS NULL OR min_depth   < 1 THEN NULL
                                          ELSE min_depth   END::text, 'off'),
                             coalesce(CASE WHEN min_wait IS NULL OR min_wait < interval '0' THEN NULL
                                          ELSE min_wait END::text, 'off'))
      -- Not in the tree any more. The LEFT JOIN plus the NULL test rather than NOT EXISTS, so one
      -- root cannot be reported twice by two different trees.
      AND t.root_pid IS NULL
  LOOP
    PERFORM pg_notify(lock_tree_notify_resolved.channel, json_build_object(
      'event',            'cleared',
      'channel',          lock_tree_notify_resolved.channel,
      'root_pid',         gone.root_pid,
      'root_object',      nullif(gone.root_object, ''),
      'application_name', gone.application_name,
      -- What it was, so the reader knows whether it was ever serious. notify_count is the number of
      -- escalations, which is the closest thing to a severity the state table keeps.
      'blocked_at_most',  gone.max_blocked_at,
      'notified_count',   gone.notify_count
    )::text);
    n := n + 1;
  END LOOP;

  -- Then forget it, exactly as lock_tree_notify() would have. Leaving the row would mean the next
  -- incident starts already alerted, and the onset notification would never be sent.
  DELETE FROM @extschema@.lock_tree_alert a
   WHERE a.channel = lock_tree_notify_resolved.channel
     AND a.policy  = format('blocked>=%s depth>=%s wait>=%s',
                            coalesce(CASE WHEN min_blocked IS NULL OR min_blocked < 1 THEN NULL
                                         ELSE min_blocked END::text, 'off'),
                            coalesce(CASE WHEN min_depth   IS NULL OR min_depth   < 1 THEN NULL
                                         ELSE min_depth   END::text, 'off'),
                            coalesce(CASE WHEN min_wait IS NULL OR min_wait < interval '0' THEN NULL
                                         ELSE min_wait END::text, 'off'))
     AND NOT EXISTS (SELECT 1 FROM @extschema@.lock_tree t
                      WHERE t.root_pid = a.root_pid
                        AND coalesce(t.root_object, '') = a.root_object);

  RETURN n;
END
$fn$;

COMMENT ON FUNCTION @extschema@.lock_tree_notify_resolved(text, integer, integer, interval) IS
  'Raise one NOTIFY per root that had previously alerted and has now left the tree, with event = '
  '''cleared'', and forget the stored state so the next incident alerts again. Takes the same '
  'thresholds as lock_tree_notify() and keys on the same state, so the two read and write the same '
  'rows: use the same arguments on both or this reports resolutions for alerts that were never '
  'sent. A root that never alerted produces nothing. Returns how many it sent.';


--------------------------------------------------------------------------------
-- per-query blocking TIME
--------------------------------------------------------------------------------

-- The figure that gets a fix merged, rather than the figure that gets a workaround.
--
-- lock_tree_history_statements() reports session-samples: one unit per blocked session per sample.
-- That is a count of OBSERVATIONS and it is honest about what it is, but it is not a duration, and
-- the 0.7 documentation says so. This is the duration.
--
-- How a duration can be recovered from samples at all. Each row records an INSTANT and nothing else,
-- so no single row has duration in it. Duration comes from the gaps BETWEEN instants: while this
-- query was the root at both t0 and t1, it was the root for the whole of t0 to t1. Summing those
-- gaps is a measurement, not an interpolation, because both endpoints are moments at which the
-- query demonstrably held the queue up.
--
-- The gap that matters is the one between consecutive sample instants, and only where the query was
-- the root at BOTH ends. A gap where the root changed is discarded rather than apportioned: nobody
-- observed when the handover happened, so any split would be invented. That makes this figure a
-- lower bound on the truth, stated rather than hidden.
--
-- Also not counted: the interval after the LAST sample, and before the first. A chain still standing
-- when the sampler last ran contributed time nobody measured. samples and gaps_excluded report both
-- so a reader can see how much was left out.
--
-- blocked_sessions_peak and longest_wait are carried over from the same aggregation, because a
-- query can block four sessions briefly or one session for an hour, and the duration alone does not
-- say which.
CREATE FUNCTION @extschema@.lock_tree_duration(since interval DEFAULT interval '7 days')
RETURNS TABLE (
  query_id             bigint,
  blocking_seconds     numeric,
  samples              bigint,
  gaps                 bigint,
  gaps_excluded        bigint,
  blocked_sessions_peak bigint,
  sessions_total       bigint,
  longest_wait         interval,
  first_blocked_at     timestamptz,
  last_blocked_at      timestamptz,
  applications         text[]
)
LANGUAGE sql STABLE
AS $$
-- The window is applied to the INSTANTS first, before any gap is formed. Applying it afterwards
  -- would compute a gap from a sample outside the window and then discard the gap for having one
  -- endpoint out of range, which silently drops the boundary sample the reader asked about.
  WITH kept AS (
    SELECT DISTINCT h.sampled_at
    FROM @extschema@.lock_tree_history h
    WHERE h.sampled_at >= statement_timestamp() - since
  ),
  spans AS (
    SELECT sampled_at AS from_at,
           lead(sampled_at) OVER (ORDER BY sampled_at) AS to_at
    FROM kept
  ),
  -- The root query_ids present at each instant, as one row per (instant, query_id). Forming this once
  -- and joining on both ends is what keeps this linear in the number of samples: the first draft
  -- cross-joined spans against the query list and then tested both endpoints with EXISTS inside the
  -- projection, which is O(gaps x queries) probes over a table that grows all day.
  rooted AS (
    SELECT DISTINCT h.sampled_at, h.query_id
    FROM @extschema@.lock_tree_history h
    WHERE h.query_id IS NOT NULL
      AND h.depth = 0
      AND h.sampled_at >= statement_timestamp() - since
  ),
  gaps AS (
    SELECT r.query_id,
           s.from_at,
           s.to_at,
           s.to_at - s.from_at AS span,
           -- The join to the second copy of `rooted` is what enforces "root at both ends", and a gap
           -- whose far end has a different root is DISCARDED rather than apportioned: nobody observed
           -- when the handover happened, so any split of that gap would be invented.
           (t.query_id IS NOT NULL) AS held_both_ends
    FROM spans s
    JOIN rooted r      ON r.sampled_at = s.from_at
    LEFT JOIN rooted t ON t.sampled_at = s.to_at AND t.query_id = r.query_id
    WHERE s.to_at IS NOT NULL
  ),
  totals AS (
    SELECT query_id,
           -- sum() over interval works, but the result is an interval, and a duration in seconds is
           -- what a reader compares across queries and against a budget. Kept as numeric so a
           -- fractional second survives rather than being rounded away.
           sum(span) FILTER (WHERE held_both_ends)     AS held,
           count(*) FILTER (WHERE held_both_ends)     AS n_held,
           count(*) FILTER (WHERE NOT held_both_ends) AS n_dropped
    FROM gaps
    GROUP BY query_id
  ),
  -- Fixed in 0.13. A root's IDENTITY and the waits it CAUSED are on different rows: query_id is on
  -- the root row, wait_age is on the waiter's. 0.12 grouped by query_id and took max(wait_age) from
  -- the same rows, which is always NULL, because the rows carrying the query_id have no wait on them.
  -- So blocked_sessions_peak was always 1, since there is exactly one root row per query per sample,
  -- sessions_total was that same 1 summed, and longest_wait was NULL. Three columns, one mistake.
  --
  -- This is the join that answers all three: the root rows of a sample, matched to the waiter rows
  -- of the SAME sample by root_pid and root_object. The object is part of the match for the same
  -- reason it is half of lock_tree_alert's primary key: pid 0 is every prepared transaction at once,
  -- so matching on pid alone would attribute one prepared root's waiters to another.
  root_wait AS (
    SELECT r.query_id,
           r.sampled_at,
           max(w.wait_age) AS wait_at,
           count(w.pid)    AS waiters_at
    FROM @extschema@.lock_tree_history r
    JOIN @extschema@.lock_tree_history w
      ON w.sampled_at = r.sampled_at
     AND w.root_pid  = r.root_pid
     AND coalesce(w.root_object, '') = coalesce(r.root_object, '')
     -- AND w.depth > 0, and that clause is a bug fixed in 0.15 rather than a style choice. A root row
     -- carries its own pid in root_pid, so the join above matched every root to ITSELF and
     -- count(w.pid) counted the blocker among its own blocked. Measured: a root with two waiters
     -- behind it reported blocked_sessions_peak = 3.
     --
     -- It survived because test/17 computed its expected peak with the same self-matching join, so the
     -- test agreed with the bug and passed. An expectation derived from the expression under test is
     -- not an expectation. test/19's fixture is built from depth values directly and is what caught
     -- it.
     AND w.depth > 0
    -- 1.1.5: the waiter side is bounded explicitly. PostgreSQL does not carry a >= bound on
    -- r.sampled_at across the equality w.sampled_at = r.sampled_at, so before this the waiter
    -- side stayed inside the window only if the planner happened to pick a nested loop and probe
    -- it. That is a property of the chosen join, not of the SQL, and it varied with version and
    -- fixture: on PG18 with a 90-day fixture this function read 14,774,419 waiter rows for a
    -- 7-day question, and on PG14 with a 30-day one it read 4,924,819, both with only a Filter and
    -- no index bound. lock_tree_duration() has the same join and got a nested loop on both, so it
    -- read 19 rows per probe, which is why the two disagreed despite identical SQL.
    --
    -- It cannot change which rows match: w.sampled_at = r.sampled_at and r.sampled_at is already
    -- bounded, so an unbounded w can only change how much has to be read. Stating the bound makes
    -- the bounded plan the only one available, rather than leaving the cost to the planner.
    -- Applied to lock_tree_duration() as well, whose plan is fast today and need not stay that way: on PG14 with
    -- broken statistics it degraded to a sequential scan over every waiter row, 7,917 ms against
    -- 2,806 ms with the bound.
    AND w.sampled_at >= statement_timestamp() - since
    WHERE r.depth = 0
      AND r.query_id IS NOT NULL

      AND r.sampled_at >= statement_timestamp() - since
    GROUP BY r.query_id, r.sampled_at
  ),
  -- One row per query_id. Grouped here rather than in root_wait so that the peak can be a maximum
  -- OF the per-sample counts; a peak cannot be recovered from a total.
  per_query AS (
    SELECT query_id,
           max(waiters_at) AS sessions_peak,
           sum(waiters_at) AS sessions_total,
           max(wait_at)    AS longest_wait,
           count(*)        AS samples,
           min(sampled_at) AS first_at,
           max(sampled_at) AS last_at
    FROM root_wait
    GROUP BY query_id
  ),
  apps AS (
    -- NULL application_names excluded rather than collected: a depth-0 row for a session with no
    -- application_name would put a null in the array, which is indistinguishable from a gap in the
    -- data.
    SELECT query_id,
           array_agg(DISTINCT application_name ORDER BY application_name) AS names
    FROM @extschema@.lock_tree_history
    WHERE query_id IS NOT NULL
      AND application_name IS NOT NULL
      AND sampled_at >= statement_timestamp() - since
    GROUP BY query_id
  )
  SELECT t.query_id,
         round(extract(epoch FROM coalesce(t.held, interval '0'))::numeric, 3),
         p.samples,
         t.n_held,
         t.n_dropped,
         p.sessions_peak,
         p.sessions_total,
         p.longest_wait,
         p.first_at,
         p.last_at,
         a.names
  FROM totals t
  JOIN per_query p ON p.query_id = t.query_id
  LEFT JOIN apps a ON a.query_id = t.query_id
  -- Worst first, and by duration rather than by sample count, which is the entire difference.
  ORDER BY coalesce(t.held, interval '0') DESC, p.sessions_peak DESC
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_duration(interval) IS
  'Per-query blocking TIME over the sampled history, worst first: for each root query id, the '
  'elapsed time during which it was the thing holding the queue up. Unlike '
  'lock_tree_history_statements(), which counts blocked sessions per sample and therefore doubles '
  'if you sample twice as often over the same incident, this does not move with the sample rate. '
  'Also reports samples seen, gaps counted, gaps discarded, the peak and total number of sessions '
  'this query blocked, the longest single wait it caused, when it was first and last seen, and the '
  'applications it was seen under. A gap counts only where the query was the root at both ends, '
  'and the interval after the last sample is never counted, so this is a lower bound rather than an '
  'estimate. Needs a sampled history, and the samples must be separate statements: a loop of '
  'lock_tree_sample() inside one DO block collapses onto a single sampled_at and records no elapsed '
  'time at all.';


--------------------------------------------------------------------------------
-- blocking TIME per application
--------------------------------------------------------------------------------

-- The number a page actually gets: which application cost the most blocking time.
--
-- NOT lock_tree_duration() grouped by application afterwards, and the difference is not cosmetic. The
-- two disagree whenever an application hands the queue from one statement to another, which is the
-- ordinary case for a connection pool or a batch job running a fixed script.
--
-- Say an app's query 1 is the root at t0 and its query 2 is the root at t1.
--
--   per query      both gaps are DISCARDED: neither query was the root at both ends.
--   per application the gap COUNTS: the application was holding the queue up at both ends, and
--                  from where the application is concerned nothing changed.
--
-- Summing lock_tree_duration() by application would report near zero for an application that spent
-- ten minutes blocking forty sessions, because every individual gap straddled a statement boundary.
-- That is not a rounding error, it is the answer being wrong in the direction that matters.
--
-- So the gap arithmetic is done again on (sampled_at, application_name). Everything else is the same
-- arithmetic as lock_tree_duration(), including the same conservatism: a gap where the APPLICATION
-- was not the root at the far end is discarded rather than apportioned, and the interval after the
-- last sample is never counted.
--
-- An empty application_name is a category of its own and is reported, not filtered. A session that
-- never called SET application_name is one of the findings you are looking for, and hiding it behind
-- a NULL or dropping the row would hide exactly the thing worth noticing.
CREATE FUNCTION @extschema@.lock_tree_duration_by_application(since interval DEFAULT interval '7 days')
RETURNS TABLE (
  application_name      text,
  blocking_seconds      numeric,
  samples               bigint,
  gaps                  bigint,
  gaps_excluded         bigint,
  blocked_sessions_peak bigint,
  sessions_total        bigint,
  longest_wait          interval,
  first_blocked_at      timestamptz,
  last_blocked_at       timestamptz,
  query_ids             bigint[]
)
LANGUAGE sql STABLE
AS $$
  WITH kept AS (
    SELECT DISTINCT h.sampled_at
    FROM @extschema@.lock_tree_history h
    WHERE h.sampled_at >= statement_timestamp() - since
  ),
  spans AS (
    SELECT sampled_at AS from_at,
           lead(sampled_at) OVER (ORDER BY sampled_at) AS to_at
    FROM kept
  ),
  -- DISTINCT on the application, not on the query. Two concurrent roots of one application at one
  -- instant are one row, so a gap in which it held both is counted once, which is what "this
  -- application held the queue up this long" has to mean. Counted per root it would double, and the
  -- figure would move with however many concurrent sessions the application happened to use.
  rooted AS (
    SELECT DISTINCT h.sampled_at, h.application_name
    FROM @extschema@.lock_tree_history h
    WHERE h.depth = 0
      AND h.application_name IS NOT NULL
      AND h.sampled_at >= statement_timestamp() - since
  ),
  gaps AS (
    SELECT r.application_name,
           s.from_at,
           s.to_at,
           s.to_at - s.from_at AS span,
           (t.application_name IS NOT NULL) AS held_both_ends
    FROM spans s
    JOIN rooted r      ON r.sampled_at = s.from_at
    LEFT JOIN rooted t ON t.sampled_at = s.to_at AND t.application_name = r.application_name
    WHERE s.to_at IS NOT NULL
  ),
  totals AS (
    SELECT application_name,
           sum(span) FILTER (WHERE held_both_ends)     AS held,
           count(*) FILTER (WHERE held_both_ends)     AS n_held,
           count(*) FILTER (WHERE NOT held_both_ends) AS n_dropped
    FROM gaps
    GROUP BY application_name
  ),
  -- The same root-to-waiter join lock_tree_duration() uses, grouped by application.
  root_wait AS (
    SELECT r.application_name,
           r.sampled_at,
           max(w.wait_age) AS wait_at,
           count(w.pid)    AS waiters_at
    FROM @extschema@.lock_tree_history r
    JOIN @extschema@.lock_tree_history w
      ON w.sampled_at = r.sampled_at
     AND w.root_pid  = r.root_pid
     AND coalesce(w.root_object, '') = coalesce(r.root_object, '')
     -- AND w.depth > 0, and that clause is a bug fixed in 0.15 rather than a style choice. A root row
     -- carries its own pid in root_pid, so the join above matched every root to ITSELF and
     -- count(w.pid) counted the blocker among its own blocked. Measured: a root with two waiters
     -- behind it reported blocked_sessions_peak = 3.
     --
     -- It survived because test/17 computed its expected peak with the same self-matching join, so the
     -- test agreed with the bug and passed. An expectation derived from the expression under test is
     -- not an expectation. test/19's fixture is built from depth values directly and is what caught
     -- it.
     AND w.depth > 0
    -- 1.1.5: the waiter side is bounded explicitly. PostgreSQL does not carry a >= bound on
    -- r.sampled_at across the equality w.sampled_at = r.sampled_at, so before this the waiter
    -- side stayed inside the window only if the planner happened to pick a nested loop and probe
    -- it. That is a property of the chosen join, not of the SQL, and it varied with version and
    -- fixture: on PG18 with a 90-day fixture this function read 14,774,419 waiter rows for a
    -- 7-day question, and on PG14 with a 30-day one it read 4,924,819, both with only a Filter and
    -- no index bound. lock_tree_duration() has the same join and got a nested loop on both, so it
    -- read 19 rows per probe, which is why the two disagreed despite identical SQL.
    --
    -- It cannot change which rows match: w.sampled_at = r.sampled_at and r.sampled_at is already
    -- bounded, so an unbounded w can only change how much has to be read. Stating the bound makes
    -- the bounded plan the only one available, rather than leaving the cost to the planner.
    -- Applied to lock_tree_duration_by_application() as well, whose plan is fast today and need not stay that way: on PG14 with
    -- broken statistics it degraded to a sequential scan over every waiter row, 7,917 ms against
    -- 2,806 ms with the bound.
    AND w.sampled_at >= statement_timestamp() - since
    WHERE r.depth = 0
      AND r.application_name IS NOT NULL

      AND r.sampled_at >= statement_timestamp() - since
    GROUP BY r.application_name, r.sampled_at
  ),
  per_app AS (
    SELECT application_name,
           max(waiters_at) AS sessions_peak,
           sum(waiters_at) AS sessions_total,
           max(wait_at)    AS longest_wait,
           count(*)        AS samples,
           min(sampled_at) AS first_at,
           max(sampled_at) AS last_at
    FROM root_wait
    GROUP BY application_name
  ),
  -- Which statements it was the root for. query_id IS NOT NULL because a blocked query has no
  -- query_id, and a NULL in this array is indistinguishable from a gap in the data.
  qids AS (
    SELECT application_name,
           array_agg(DISTINCT query_id ORDER BY query_id) AS ids
    FROM @extschema@.lock_tree_history
    WHERE depth = 0
      AND query_id IS NOT NULL
      AND application_name IS NOT NULL
      AND sampled_at >= statement_timestamp() - since
    GROUP BY application_name
  )
  SELECT t.application_name,
         round(extract(epoch FROM coalesce(t.held, interval '0'))::numeric, 3),
         p.samples,
         t.n_held,
         t.n_dropped,
         p.sessions_peak,
         p.sessions_total,
         p.longest_wait,
         p.first_at,
         p.last_at,
         q.ids
  FROM totals t
  JOIN per_app p ON p.application_name = t.application_name
  LEFT JOIN qids q ON q.application_name = t.application_name
  ORDER BY coalesce(t.held, interval '0') DESC, p.sessions_peak DESC
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_duration_by_application(interval) IS
  'Per-APPLICATION blocking TIME over the sampled history, worst first: for each application_name, '
  'the elapsed time during which it was the thing holding the queue up, with the statements it was '
  'root for. Same gap arithmetic and same conservatism as lock_tree_duration(), but keyed on the '
  'application rather than the statement, and the two are not the same figure: a gap in which an '
  'application handed the queue from one statement to another is counted HERE and discarded by '
  'lock_tree_duration(), so summing the per-query figures by application would understate an '
  'application whose statements take turns blocking. Reports peak and total sessions blocked, the '
  'longest single wait caused, and when the application was first and last seen. An empty '
  'application_name is reported as its own row: a blocker that never set one is a finding. Needs a '
  'sampled history whose samples are separate statements.';

--------------------------------------------------------------------------------
-- per-query blocking time
--------------------------------------------------------------------------------

-- The question that gets a fix merged rather than a workaround. lock_tree_statements() answers
-- it for the chain in front of you; this answers it for the month, from samples already taken.
--
-- "Blocking time" rather than "wait time" because it is the number that maps to a fix. A
-- statement that runs for 900ms and holds nothing up is slow. A statement that runs for 40ms and
-- holds sixty sessions up is the one to fix, and only the blocking figure shows that.
--
-- The unit is the session-sample: one blocked session observed at one sample. That is not the
-- same as wall-clock time, and the difference matters. A session blocked for 60 seconds sampled
-- every 10 seconds contributes six, not sixty. This is deliberate and it is a HIGHER bound on
-- precision, not a lower one on importance: it counts each blocked session once per sample in
-- which it was blocked, so shortening the sample interval increases it proportionally and the
-- ranking between statements is stable while the absolute figure is not. last_seen_at and
-- times_seen let you sanity-check which regime a row is in.
--
-- Only roots carry a query_id, so this is per BLOCKING query rather than per blocked query. That
-- is the useful direction: the question is what to fix, and the blocker is what you can change.
CREATE FUNCTION @extschema@.lock_tree_history_statements(
  since interval DEFAULT interval '7 days'
)
RETURNS TABLE (
  query_id         bigint,
  blocked_sessions bigint,
  samples          bigint,
  first_blocked_at timestamptz,
  last_blocked_at  timestamptz,
  deepest_chain    int,
  longest_wait     interval,
  longest_wait_at  timestamptz,
  applications     text[]
)
LANGUAGE sql STABLE
AS $$
  -- No reference to pg_stat_statements here, deliberately. A SQL function naming a relation that
  -- may not exist fails at CREATE EXTENSION time, which is why lock_tree_statements() is plpgsql
  -- with a guarded dynamic query. This one does not need that machinery: the history carries
  -- query_id, and the totals are pure aggregation over a table this extension owns. Joining the
  -- text back in is one line for whoever has the module loaded, shown in the comment below.
  SELECT h.query_id,
         count(*) FILTER (WHERE h.depth = 0)     AS blocked_sessions,
         count(DISTINCT h.sampled_at)              AS samples,
         min(h.sampled_at) FILTER (WHERE h.depth = 0),
         max(h.sampled_at) FILTER (WHERE h.depth = 0),
         max(h.depth),
         max(h.wait_age),
         -- When the worst wait was observed, which is what turns "3m12s" into "at 09:14, during
         -- the month-end run". The wait age alone says how bad, not when to go looking.
         (array_agg(h.sampled_at ORDER BY h.wait_age DESC NULLS LAST))[1],
         array_agg(DISTINCT h.application_name ORDER BY h.application_name)
  FROM @extschema@.lock_tree_history h
  WHERE h.query_id IS NOT NULL
    AND h.sampled_at >= statement_timestamp() - since
  GROUP BY h.query_id
  -- Worst first: the statement to fix is at the top, which is the only ordering anyone wants.
  ORDER BY count(*) FILTER (WHERE h.depth = 0) DESC, max(h.wait_age) DESC NULLS LAST
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_history_statements(interval) IS
  'Per-query blocking time from the sampled history, worst first: for each root query id, how '
  'many blocked sessions it held up across all samples, over how many samples, when first and '
  'last seen, the deepest chain and longest wait under it, when that worst wait happened, and '
  'which applications were involved. The figure counts a blocked session once per sample it was '
  'blocked in, so it rises with the sampling rate; the ranking between statements is what to '
  'read. Needs a sampled history: it answers about the past, not about now. To add the statement '
  'text, join pg_stat_statements on query_id yourself; this function does not reference it, so it '
  'works whether or not that module is loaded.';


--------------------------------------------------------------------------------
-- which samples exist, and what shape each had
--------------------------------------------------------------------------------

-- You cannot ask to replay a sample you do not know about, and the sample instants are the one thing
-- the history does not tell you by looking at it: every row is a session, so a table with 900 rows
-- might be 900 sessions in one sample or 30 sessions in 30 samples. This is the one row per sample.
CREATE VIEW @extschema@.lock_tree_replay_samples AS
SELECT h.sampled_at,
       count(*) FILTER (WHERE h.depth = 0) AS roots,
       count(*) FILTER (WHERE h.depth > 0) AS sessions_blocked,
       max(h.depth)                       AS max_depth,
       max(h.wait_age)                    AS longest_wait,
       -- FILTER rather than a WHERE on a second aggregate, so one pass over the table gives every
       -- column. array_agg on root rows only: a waiter's application is not who was blocking.
       array_agg(DISTINCT h.application_name ORDER BY h.application_name)
         FILTER (WHERE h.depth = 0)      AS applications,
       -- Which statement was at the head, where it was recorded. query_id is on root rows only.
       array_agg(DISTINCT h.query_id ORDER BY h.query_id)
         FILTER (WHERE h.depth = 0 AND h.query_id IS NOT NULL) AS query_ids
FROM @extschema@.lock_tree_history h
GROUP BY h.sampled_at;

COMMENT ON VIEW @extschema@.lock_tree_replay_samples IS
  'One row per sample in lock_tree_history: when it was taken, how many roots were blocking, how '
  'many sessions were behind them, how deep the worst chain went, the longest single wait, and the '
  'applications and query ids at the head. This is how you find out which samples exist, since '
  'the history itself holds one row per session rather than one per sample. Order by sampled_at '
  'DESC to start from the most recent.';


--------------------------------------------------------------------------------
-- the tree as it was
--------------------------------------------------------------------------------

-- The live view reads pg_stat_activity. This reads the history, so it can answer for a moment that
-- has passed.
--
-- `at` is a TARGET, not an exact key. The sample nearest it is used, and which one that was is the
-- first column of every row, so you always see what you actually got rather than having to trust
-- that you got what you asked for. Ties go to the earlier sample, which is arbitrary but at least
-- consistent.
--
-- The column list is what the history recorded, in the live view's order where they overlap. Nine
-- columns of lock_tree are absent and cannot be supplied:
--
--   path              not reconstructible. The history has one row per session per sample, not the
--                     edge between them, so there is no way to know which depth-1 session a depth-2
--                     session was actually behind. Anything derived from it, blocked_by included,
--                     goes with it.
--   usename, datname, client_addr, wait_event_type, wait_event, xact_age, state_age
--                     simply were not recorded. Adding them means a wider history for every future
--                     sample on every database, for figures nobody has asked for yet.
--
-- ONE COLUMN READS BACK DIFFERENTLY FROM THE LIVE VIEW, and that is a good thing.
--
-- lock_tree_sample() is SECURITY DEFINER SET search_path = pg_catalog. Inside it regclass cannot
-- resolve a relation in public, so the relation name renders QUALIFIED. The live lock_tree is read
-- with the caller's search_path, so the same lock renders unqualified there:
--
--   lock_tree.waiting_for          AccessShareLock on ledger
--   lock_tree_history.waiting_for   AccessShareLock on public.ledger
--
-- Measured, not inferred. The live view's rendering is the path-dependent one this extension
-- already documents as cosmetic, because nothing keys on it. The history's is stable: the same lock
-- renders the same way in every row forever, whatever the reader's search_path was. A replay that
-- said "ledger" in one sample and "public.ledger" in the next would be worse.
--
-- A gap in the column list is a gap in the data, not a formatting choice, and this function says so
-- rather than padding with NULLs that would be indistinguishable from a session which genuinely had
-- no client address.
CREATE FUNCTION @extschema@.lock_tree_replay(as_of timestamptz DEFAULT NULL)
RETURNS TABLE (
  sampled_at       timestamptz,
  root_pid         int,
  root_object      text,
  depth            int,
  pid              int,
  state            text,
  waiting_for      text,
  wait_age         interval,
  application_name text,
  query            text,
  query_id         bigint
)
LANGUAGE sql STABLE
AS $$
  -- The parameter is named as_of and not at because PostgreSQL resolves a bare `at` against the
  -- function's own RETURNS TABLE row type rather than against the argument, and the failure is
  -- "missing FROM-clause entry for table lock_tree_replay". A parameter whose name is not one of the
  -- output columns has no such shadowing.
  --
  -- The distance is computed in its own CTE so the ordering can use it, because PostgreSQL refuses
  -- to let a SELECT DISTINCT order by an expression that is not in its select list. DISTINCT is
  -- unnecessary anyway: ordering by (distance, instant) and taking one row returns a single instant
  -- however many sessions happened to be in it.
  --
  -- coalesce(as_of, clock_timestamp()) is what makes NULL mean "the most recent sample": with no
  -- target, the nearest sample to now is the latest one at or before it.
  -- Two index seeks, not one scan.
  --
  -- The nearest sample to as_of is either the latest one at or before it or the earliest one after
  -- it, and each of those is a single seek on lock_tree_history_sampled_at_idx. The first version
  -- computed the distance for every row and sorted, which is what a window function over the whole
  -- history costs: 987 ms to replay one sample out of 1.2 million rows, against 0.556 ms for
  -- max(sampled_at) under the same index. It was written that way to get around PostgreSQL refusing
  -- to let a SELECT DISTINCT order by an expression outside its select list, and the way round that
  -- restriction was worse than the restriction.
  --
  -- statement_timestamp() and not clock_timestamp() here for the same reason as everywhere else:
  -- this one is a column predicate, and a volatile bound would turn both seeks back into filters.
  -- With as_of NULL it means "up to the start of this statement", which is the most recent sample
  -- for any history written by a sampler.
  WITH target AS (
    SELECT c.sampled_at
    FROM (
      (SELECT max(h.sampled_at) AS sampled_at
         FROM @extschema@.lock_tree_history h
        WHERE h.sampled_at <= coalesce(as_of, statement_timestamp()))
      UNION ALL
      (SELECT min(h.sampled_at)
         FROM @extschema@.lock_tree_history h
        WHERE h.sampled_at > coalesce(as_of, statement_timestamp()))
    ) c
    -- Ties go to the earlier sample. Arbitrary, but at least consistent, and asserted in test/18.
    ORDER BY abs(extract(epoch FROM (c.sampled_at - coalesce(as_of, statement_timestamp())))),
             c.sampled_at
    LIMIT 1
  )
  SELECT h.sampled_at,
         h.root_pid,
         h.root_object,
         h.depth,
         h.pid,
         h.state,
         h.waiting_for,
         h.wait_age,
         h.application_name,
         h.query,
         h.query_id
  FROM @extschema@.lock_tree_history h
  JOIN target t USING (sampled_at)
  -- Same ordering as the live view, minus path. depth then pid stands in for the path order, which
  -- is the same ordering whenever the tree is well formed and is stable when it is not.
  ORDER BY h.root_pid, h.root_object NULLS FIRST, h.depth, h.pid
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_replay(timestamptz) IS
  'The lock tree as it was at a past sample, reconstructed from lock_tree_history. Takes a target '
  'timestamp and uses the sample NEAREST to it, reporting which one in the sampled_at column of every '
  'row; NULL means the most recent. Returns the columns the history recorded: sampled_at, root_pid, '
  'root_object, depth, pid, state, waiting_for, wait_age, application_name, query and query_id. '
  'Nine columns of lock_tree are absent and cannot be supplied, path and blocked_by because the '
  'history stores one row per session rather than the edge between them, and usename, datname, '
  'client_addr, wait_event_type, wait_event, xact_age and state_age because they were never '
  'recorded. waiting_for reads back SCHEMA-QUALIFIED where the live view does not, because '
  'lock_tree_sample() runs with search_path = pg_catalog and regclass cannot resolve unqualified '
  'there. That is deliberate: the live rendering is the path-dependent one, and the history''s is '
  'stable across every sample. See lock_tree_replay_samples for what samples exist.';


--------------------------------------------------------------------------------
-- the same, as something to read
--------------------------------------------------------------------------------

-- Prose during an incident is what lock_tree_text() is for. This is the 3am version of it: the
-- incident is over, you are reading about it, and you want the shape rather than a query.
--
-- Same layout as the live renderer, with the columns the history has. The root line carries its
-- application and query, and each waiter line carries how long it had been waiting, what it wanted,
-- and its own query. The live version also prints xact_age on the root, which is often the most
-- telling number in the whole tree, and replay cannot because it was not recorded.
CREATE FUNCTION @extschema@.lock_tree_replay_text(as_of timestamptz DEFAULT NULL, query_width int DEFAULT 60)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  SELECT CASE WHEN r.depth = 0
           THEN format('%s%s  %s  %s  %s',
                       r.pid,
                       CASE WHEN r.root_object IS NULL THEN ''
                            ELSE format(' (%s)', r.root_object) END,
                       r.state,
                       -- '(none set)' rather than an empty column, because an unlabelled blocker is a
                       -- finding and a blank between two spaces does not look like one.
                       coalesce(nullif(r.application_name, ''), '(none set)'),
                       left(regexp_replace(coalesce(r.query, ''), '\s+', ' ', 'g'), query_width))
           ELSE format('%s%s  %s  %s  %s',
                       repeat('  ', r.depth - 1) || '└─',
                       r.pid,
                       @extschema@.lock_tree_age(r.wait_age),
                       'for ' || coalesce(r.waiting_for, '(not recorded)'),
                       left(regexp_replace(coalesce(r.query, ''), '\s+', ' ', 'g'), query_width))
         END
  FROM @extschema@.lock_tree_replay(as_of) r
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_replay_text(timestamptz, int) IS
  'lock_tree_replay() rendered as indented text, in the same layout as lock_tree_text(): a root line '
  'with its application and query, then each waiter indented by depth with its wait, what it wanted '
  'and its query. Takes the same target timestamp as lock_tree_replay(), so NULL means the most '
  'recent sample. The live renderer also prints the root''s xact_age, which is often the most telling '
  'number in the tree; replay cannot, because xact_age was not recorded.';
