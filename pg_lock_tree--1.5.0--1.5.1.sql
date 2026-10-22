/* pg_lock_tree--1.5.0--1.5.1.sql
 *
 * 1.5.1 rewrites lock_tree_history_size()'s sample count as one GROUP BY pass. count(DISTINCT
 * sampled_at) was 5.0 s of a 6.3 s call at 63M rows; the GROUP BY form measured 2.95 s. No row
 * type, name or grant changes.
 */
\echo Use "ALTER EXTENSION pg_lock_tree UPDATE TO '1.5.1'" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.lock_tree_history_size()
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
  WITH grouped AS (
    -- One row per sample instant. This replaces count(DISTINCT sampled_at), which measured 5.0 s of
    -- a 6.3 s call at 63M rows. The GROUP BY form measured 2.95 s on the same data; both scan the
    -- table once, but the hash aggregate is cheaper than the DISTINCT sort. sum(n) gives the row
    -- count from the same pass, so the function still reads the history once.
    SELECT sampled_at, count(*)::bigint AS n
      FROM @extschema@.lock_tree_history
     GROUP BY sampled_at
  ),
  facts AS (
    SELECT coalesce(sum(n), 0)::bigint AS n_rows,
           count(*)::bigint            AS n_samples,
           min(sampled_at)             AS lo,
           max(sampled_at)             AS hi
    FROM grouped
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

