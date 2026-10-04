/* pg_lock_tree--0.10--0.11.sql
 *
 * The two things that were wanted when partitioning lock_tree_history was proposed, because
 * partitioning turned out not to be available.
 *
 *   lock_tree_history_size()      what the history costs, and what it will cost at this rate
 *   lock_tree_prune_batched()     the same prune in committed batches, as a PROCEDURE
 *
 * It is not available, and that was measured rather than assumed. PostgreSQL has no
 * ALTER TABLE ... SET PARTITIONED BY: conversion means creating a new partitioned table, copying,
 * and swapping. The swap cannot be done from outside the extension, because the table is a member:
 *
 *   DROP TABLE lock_tree_history
 *   ERROR:  cannot drop table lock_tree_history because extension pg_lock_tree requires it
 *
 * The same restriction that applies to the view. The only place DROP TABLE is permitted is inside
 * an extension update script, so the copy would happen unattended during ALTER EXTENSION ...
 * UPDATE, on however many rows the user happens to have, holding whatever locks that takes. That
 * is not a change to make on someone's behalf in a script they did not write, so it is not offered.
 *
 * Both objects are new, so nothing existing is rewritten and no rewrite lock is taken.
 * lock_tree_prune() is untouched.
 */

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
  days_to_1gb      numeric
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
         END
  FROM rated r
  CROSS JOIN sized sz
$$;

COMMENT ON FUNCTION @extschema@.lock_tree_history_size() IS
  'What the sampled history costs and what it will cost at the rate it is already being written: '
  'row and sample counts, total bytes including TOAST and free space map, the oldest and newest '
  'sample, the observed sample interval, bytes per day, and the days until the table reaches a '
  'gigabyte. Everything is measured from the table, so an unsampled database gets zeros and a NULL '
  'rate rather than a confident number with nothing behind it. Use it to decide when to prune, or '
  'whether the sample interval is wrong.';


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
             WHERE c.sampled_at < clock_timestamp() - older_than
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
   WHERE sampled_at < clock_timestamp() - older_than;

  RAISE NOTICE 'lock_tree_prune_batched: removed % history rows older than %', total, older_than;
END
$proc$;

COMMENT ON PROCEDURE @extschema@.lock_tree_prune_batched(interval, integer) IS
  'Prune lock_tree_history in committed batches of batch_size, so no single lock is held for the '
  'whole operation and a long prune can be watched or interrupted without stopping writers. '
  'Removes the deadlock samples too. A procedure, not a function, because only a procedure called '
  'outside a transaction block may COMMIT, and batching without committing between batches still '
  'holds everything. Cannot be called from inside a transaction block. Returns nothing to the '
  'client; the row count is raised as a notice.';
