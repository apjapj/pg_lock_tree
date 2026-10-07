-- pg_lock_tree 1.1.5 -> 1.1.6
--
-- A cold tier. Two objects: a table and a procedure. Nothing existing is replaced, so this script
-- creates rather than replaces, and it cannot change any result any shipped function returns.
--
--   lock_tree_history_archive   same columns as lock_tree_history, indexed by BRIN and no b-trees
--   lock_tree_archive()         move history older than an age into it, in committed batches
--
-- Deliberately NOT added: any change to the existing read functions. The obvious design is to teach
-- lock_tree_incidents(), lock_tree_duration() and the rest to read hot and archive together, and it
-- was measured and rejected. A UNION ALL of the two tables as the inner side of the root-to-waiter
-- join turns a Nested Loop Semi Join with an index probe, 96 ms on the 90-day fixture's shape, into
-- a HashAggregate over a sequential scan of both tables, 924 ms on the same data, because the planner
-- stops choosing the probe once the inner side is a multi-way Append. That is the same failure that
-- sank monthly partitioning, documented in docs/roadmap.md. An EMPTY archive still costs about 50%
-- on a plain count, so installations that never archive would pay for a feature they do not use.
--
-- It also could not be done as a view. The sampler INSERTs into this table on every run, and
-- PostgreSQL refuses with "cannot insert into view" for any view containing UNION, so a boundary-
-- spanning read would have to be inlined into every read function body. Dedicated archive functions
-- are the only shape that works.
--
-- What this does NOT give you: a way to read across the boundary. No shipped function reads the
-- archive, so a since window silently stops at the edge of the hot table rather than erroring.
-- Querying the archive is SQL of your own, which is a deliberate trade rather than an oversight.
--
-- Costs, all measured on a 365-day fixture of 63,072,020 rows and 14 GB, are in
-- docs/history.md under "Retiring old history". The short version: the whole year in one statement
-- took 298 s and roughly doubled peak disk, a week at a time takes 1.8 s, and deleting from the hot
-- table does NOT return the disk either way, because a file stays at its high-water mark until
-- TRUNCATE on an empty table. This release does not truncate anything.

-- The archive table. Same columns as lock_tree_history on purpose, so a row copied across is still
-- the same fact and a researcher can write ordinary SQL against either.
--
-- Created empty on every install rather than on demand: a few pages, no schema privilege needed at
-- archive time, and the table is documented rather than appearing the first time a job runs.
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

-- BRIN and nothing else, which is the point of the table being separate. sampled_at is append-only
-- so it correlates with physical order: measured correlation 1.000000 on the 63M-row fixture, where
-- this index came out at 1336 kB against 475 MB for a b-tree on the same column. Four b-trees on the
-- same 1,209,600 rows cost 170 MB, so dropping them is worth about a quarter of the archived table.
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

-- The move. A procedure rather than a function for the same reason lock_tree_prune_batched() is one:
-- only a procedure called outside a transaction block may COMMIT, and batching without committing
-- between batches still holds everything in one transaction.
--
-- The batch is captured by ctid and both the INSERT and the DELETE use that captured set. The obvious
-- version, and the one written first, is INSERT ... SELECT ... LIMIT n followed by a DELETE with its
-- own LIMIT n, and it does not work. Measured on the 62-row test fixture with batch_size 7 against
-- 20-row ties, it wrote 34 rows into the archive from 21 eligible ones, thirteen of them duplicates,
-- and then looped forever, killed after 179 seconds. The two statements take independent LIMIT
-- batches, sampled_at is not unique because twenty sessions share one sample, and the rows the INSERT
-- has just written are still in the source for the DELETE's subquery to select, so the eligible count
-- never falls and the EXIT is never reached. Capturing one ctid set for both is what makes it
-- converge, and the correct version preserves 62 rows in, 62 rows across the two tables, out.
--
-- lock_tree_redact() is re-applied on the way across, and that is a security decision rather than a
-- copy detail. lock_tree_sample() redacts on the way IN under whatever lock_tree.history_query said
-- at the time, so a row sampled while that was 'full' carries a verbatim query, and copying it into
-- a table kept for years would preserve indefinitely whatever the policy was on the day it was
-- captured. Re-applying costs one IMMUTABLE call per row on a 1.8 s job and makes the archive
-- strictly safer than its source.
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
  'read function reads the archive.';
