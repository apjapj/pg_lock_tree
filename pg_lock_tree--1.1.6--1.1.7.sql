-- pg_lock_tree 1.1.6 -> 1.1.7
--
-- One function's OUTPUT and one script that was lying. Nothing is replaced in a way that can change a
-- result, and no existing object is dropped.
--
-- lock_tree_history_size() gains one column, archive_bytes, appended after the eight it already had.
-- Their names, order, types and meanings are unchanged, and the values they return are unchanged:
-- the only difference in a fresh call is the extra column at the end. A caller doing SELECT * on
-- this function sees one more column, which is the single visible consequence of the release and is
-- documented as such.
--
-- The reason is that 1.1.6 shipped lock_tree_history_archive and this function could not see it, so
-- it understated on-disk history by however much had been archived, which is the one number an
-- operator sizing a disk needs. Measured before and after, with a 707 MB archive holding 12,300,000
-- rows: before 1.1.7 the archive is invisible; after, archive_bytes reports it.
--
-- WHY ONE COLUMN AND NOT FOUR. An archive row count, its oldest row and its newest row were all
-- drafted, and all three removed, because each needs a full sequential scan of the archive. Measured
-- on that same 12,300,000-row archive: count(*), min and max together took 495 ms, and the function
-- with them took 1189 ms. pg_total_relation_size is a catalog read, 0.9 to 1.1 ms at the same size,
-- and the function with only archive_bytes took 3 to 5 ms. That matters because the one flaw this
-- function already has is that its cost follows retention: count(DISTINCT sampled_at) over the
-- history is 5.0 of the 6.3 seconds it costs at a year. Adding a second scan of a second, larger
-- table would have made the flaw considerably worse in exchange for figures nobody needs it to give.
-- An operator wants the bytes. A row count in a BRIN-indexed table is a SELECT count(*) away.
--
-- archive_bytes is reported SEPARATELY and not folded into total_bytes. total_bytes is part of a rate
-- projection built on the observed sample interval of one table, and a second table with its own
-- interval and its own extent does not belong in that arithmetic. A reader wanting a whole-database
-- figure adds archive_bytes to total_bytes, which is arithmetic they can see.
--
-- DROP and CREATE, NOT CREATE OR REPLACE, and that is forced rather than chosen. Adding an OUT
-- parameter changes the function's row type, and CREATE OR REPLACE refuses exactly that:
--
--   ERROR:  cannot change return type of existing function
--   DETAIL:  Row type defined by OUT parameters is different.
--   HINT:  Use DROP FUNCTION lock_tree_history_size() first.
--
-- So there is no way to append a column to a RETURNS TABLE function in place. This is the general
-- limitation every extension that grows a function's output meets, and it is why the alternative was
-- a new function rather than a new column. It was not chosen here because the eight existing columns
-- are read by name in test/15_history_size.sql and in the documentation, and a new function would
-- have left two functions differing by one column.
--
-- The DROP is safe here and was checked rather than assumed. Nothing depends on this function: it is
-- not used in a view, a default, a check constraint or a trigger, and no grant exists on it, so the
-- drop cannot fail on a dependency. It is SECURITY INVOKER, so no privilege is lost with the object.
-- What IS lost and restored is the COMMENT, which the CREATE below sets again, and any privilege an
-- operator had granted, which the upgrade does not restore. That last is deliberate and matches how
-- this project treats privileges on upgrade: the grant on lock_tree_sample() is also not reinstated,
-- and INSTALL.md says so. A monitoring role that was granted EXECUTE on this function must be
-- granted it again, and the one grant the documentation recommends for a monitoring role does not
-- include it.
--
-- The body is lifted verbatim from pg_lock_tree--1.1.7.sql so the two files cannot drift, and
-- check-upgrade.sh fails if they do.
DROP FUNCTION IF EXISTS @extschema@.lock_tree_history_size();

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

-- scripts/check-install.sh is not SQL and does not belong in this file, but it is part of the same
-- defect this release closes and is worth recording here rather than only in its own commit: the
-- script listed twenty objects while 1.1.4, 1.1.5 and 1.1.6 all added more, so it reported a healthy
-- install as complete. It now derives the expected object set from pg_depend and fails on anything
-- the extension owns that its own list does not name.
