-- test/05_formatting.sql — the 0.2 rendering and action helpers.
--
-- These are pure functions over known inputs, so no dblink and no blocked sessions: the point
-- is to pin the exact output, because the scenario suite measures widths from it.
--
-- Superuser not needed for this file beyond the usual extension setup, but the suite as a
-- whole assumes it.

\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pgtap;
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree')
     AND to_regclass('lock_tree') IS NULL THEN
    CREATE EXTENSION pg_lock_tree;
  END IF;
END
$ext$;
\o
\unset QUIET

SELECT plan(21);

-- ------------------------------------------------------------------ lock_tree_age(interval)

SELECT is(lock_tree_age(NULL), '-', 'a null interval renders as a dash');
SELECT is(lock_tree_age(interval '0.4 seconds'), '0s', 'sub-second truncates to 0s, not 00:00:00');
SELECT is(lock_tree_age(interval '4 seconds'), '4s', 'seconds stay compact');
SELECT is(lock_tree_age(interval '59 seconds'), '59s', 'just under a minute stays in seconds');
SELECT is(lock_tree_age(interval '60 seconds'), '1m0s', 'a minute rolls over to minutes');
SELECT is(lock_tree_age(interval '90 seconds'), '1m30s', 'minutes and seconds, not 00:01:30');
SELECT is(lock_tree_age(interval '3600 seconds'), '1h0m', 'an hour rolls over to hours');
SELECT is(lock_tree_age(interval '7500 seconds'), '2h5m', 'hours and minutes');

-- the whole point is that this is shorter than the interval it renders
SELECT ok(length(lock_tree_age(interval '7500 seconds')) < length('02:05:00'::interval::text),
          'a rendered interval is shorter than its ::text form');

-- --------------------------------------------------------- lock_tree_mode_short / state_short

SELECT is(lock_tree_mode_short('AccessExclusiveLock'), 'AX', 'AccessExclusiveLock -> AX');
SELECT is(lock_tree_mode_short('AccessShareLock'), 'AS', 'AccessShareLock -> AS');
SELECT is(lock_tree_mode_short('RowShareLock'), 'RS', 'RowShareLock -> RS');
SELECT is(lock_tree_mode_short('RowExclusiveLock'), 'RX', 'RowExclusiveLock -> RX');
SELECT is(lock_tree_mode_short('ShareUpdateExclusiveLock'), 'SUE', 'ShareUpdateExclusiveLock -> SUE');
SELECT is(lock_tree_mode_short('ShareLock'), 'S', 'ShareLock -> S');
SELECT is(lock_tree_mode_short('ShareRowExclusiveLock'), 'SRX', 'ShareRowExclusiveLock -> SRX');
SELECT is(lock_tree_mode_short('ExclusiveLock'), 'E', 'ExclusiveLock -> E');
SELECT is(lock_tree_mode_short('transactionid'), 'transactionid',
          'an unknown locktype is passed through unchanged, never guessed at');

SELECT is(lock_tree_state_short('idle in transaction'), 'idle-in-tx',
          'idle in transaction -> idle-in-tx');
SELECT is(lock_tree_state_short('idle in transaction (aborted)'), 'idle-in-tx (abort)',
          'the aborted variant is abbreviated but still distinguishable');
SELECT is(lock_tree_state_short('active'), 'active', 'other states are left alone');

SELECT * FROM finish();