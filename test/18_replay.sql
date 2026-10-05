-- test/18_replay.sql: the tree an incident HAD, not only how long it lasted.
--
-- Everything else in the extension answers questions about the present, or about totals over a
-- window. lock_tree_duration() can say which application cost the most and lock_tree_incidents() can
-- say when, but neither can show the SHAPE: sessions behind one idle-in-transaction root at depth
-- three, or several independent roots at once. That shape is the thing you remember three days
-- later and cannot get back.
--
-- Three objects:
--
--   lock_tree_replay_samples (view)  which samples exist and what shape each had
--   lock_tree_replay(as_of)          the rows at the nearest past sample
--   lock_tree_replay_text(as_of, w)  the same, indented, in the live renderer's layout
--
-- The column list is what the history RECORDED, and the interesting part of this file is the column
-- list it does NOT have. Nine columns of lock_tree are absent and cannot be supplied, and pretending
-- otherwise would be the easy way to make this look more capable than it is.
--
-- Needs superuser, dblink, and max_prepared_transactions untouched.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS dblink;
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lock_tree')
     AND to_regclass('lock_tree') IS NULL THEN
    CREATE EXTENSION pg_lock_tree;
  END IF;
END
$ext$;

TRUNCATE lock_tree_history;

DROP TABLE IF EXISTS rp_demo;
CREATE TABLE rp_demo (id int);

SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['rp_root','rp_mid','rp_w1','rp_w2','rp_w3']) AS n;
CREATE TEMP TABLE rp_pids AS
SELECT s.n, (SELECT p FROM dblink(s.n, 'SELECT pg_backend_pid()') AS t(p int)) AS pid
FROM unnest(ARRAY['rp_root','rp_mid','rp_w1','rp_w2','rp_w3']) AS s(n);

-- A root that is idle in transaction, plus a waiter of its own, so depth goes past 1 and the
-- indentation has something to indent. Three sessions at the far end, from two applications, so
-- depth-2 is not a single chain either.
SELECT dblink_exec('rp_root','BEGIN');
SELECT dblink_exec('rp_root','SET application_name = ''nightly_batch''');
SELECT dblink_exec('rp_root','LOCK TABLE rp_demo IN ACCESS EXCLUSIVE MODE');
SELECT dblink_exec('rp_mid','BEGIN');
SELECT dblink_exec('rp_mid','SET application_name = ''nightly_batch''');
SELECT dblink_send_query('rp_mid','LOCK TABLE rp_demo IN ACCESS EXCLUSIVE MODE');
DO $w$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN (SELECT count(*) FROM pg_stat_activity
              WHERE wait_event_type = 'Lock' AND application_name = 'nightly_batch') = 2;
  PERFORM pg_sleep(0.1);
END LOOP; END $w$;
SELECT dblink_send_query('rp_w1','SET application_name = ''api''; SELECT count(*) FROM rp_demo');
SELECT dblink_send_query('rp_w2','SET application_name = ''api''; SELECT count(*) FROM rp_demo');
SELECT dblink_send_query('rp_w3','SET application_name = ''reporting''; SELECT count(*) FROM rp_demo');
DO $w2$ BEGIN FOR i IN 1..200 LOOP
  EXIT WHEN (SELECT count(*) FROM pg_stat_activity
              WHERE wait_event_type = 'Lock'
                AND application_name IN ('api', 'reporting')) = 3;
  PERFORM pg_sleep(0.1);
END LOOP; END $w2$;

-- Each sample its own statement, for the reason 0.12 documented: statement_timestamp() is fixed for
-- the statement, so a loop would collapse them onto one instant.
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(1);
SELECT lock_tree_sample(); SELECT pg_sleep(2);
SELECT lock_tree_sample();

\o
\set QUIET 0

SELECT plan(33);

SELECT has_view('lock_tree_replay_samples', 'lock_tree_replay_samples exists as a VIEW');

SELECT has_function('lock_tree_replay', ARRAY['timestamptz'],
                    'lock_tree_replay(timestamptz) exists');

SELECT has_function('lock_tree_replay_text', ARRAY['timestamptz', 'integer'],
                    'lock_tree_replay_text(timestamptz, integer) exists');

-- ------------------------------------------------------------ which samples exist

\set QUIET 1
\o /dev/null
SELECT count(*) AS n_samples FROM lock_tree_replay_samples \gset
SELECT (SELECT count(*) FROM lock_tree_replay_samples) AS n_sample_rows,
       (SELECT count(*) FROM lock_tree_history)         AS n_history_rows \gset
SELECT max(sessions_blocked) AS peak, max(max_depth) AS depth, max(roots) AS roots
  FROM lock_tree_replay_samples \gset
SELECT quote_literal((SELECT array_agg(DISTINCT u ORDER BY u)::text
          FROM lock_tree_replay_samples, unnest(applications) AS u)) AS head_apps \gset
SELECT quote_literal((SELECT array_agg(DISTINCT application_name ORDER BY application_name)::text
          FROM lock_tree_replay())) AS every_app \gset
SELECT (SELECT count(*) FROM lock_tree_history
          WHERE depth > 0 AND waiting_for LIKE '%rp_demo%'
            AND waiting_for NOT LIKE '%public.rp_demo%') AS unqualified \gset
SELECT (SELECT count(*) FROM lock_tree_replay_samples WHERE query_ids IS NOT NULL) AS with_qids \gset
\o
\set QUIET 0

SELECT is(:n_samples::int, 4,
          'four samples, which the history itself does not tell you: it holds one row per session');

SELECT ok(:n_sample_rows::int < :n_history_rows::int,
          'and the samples view has FEWER rows than the history (' || :n_sample_rows || ' against ' ||
          :n_history_rows || '), which is the whole reason it has to exist: the history holds one '
          || 'row per session, so its row count is a count of observations rather than of moments');

SELECT is(:roots::int, 1, 'one root at every sample');

SELECT is(:peak::int, 4, 'four sessions blocked behind it at the worst sample');

SELECT is(:depth::int, 2, 'the chain reached depth two, so the indentation is exercised');

SELECT is(:head_apps::text, '{nightly_batch}'::text,
          'the samples view reports only the application AT THE HEAD, because a waiter''s '
          || 'application_name is not who was blocking anyone');

SELECT is(:every_app::text, '{api,nightly_batch,reporting}'::text,
          'while the replay itself carries every application in the tree, head and waiters alike, '
          || 'so the two are different questions and only one of them is answered by the summary');

SELECT ok(:with_qids::int = 4,
          'every sample records a query_id at the head, since the root row carries one');

-- ------------------------------------------------------------------- the tree itself

\set QUIET 1
\o /dev/null
SELECT count(*) AS replay_rows FROM lock_tree_replay() \gset
SELECT count(DISTINCT sampled_at) AS replay_instants FROM lock_tree_replay() \gset
SELECT count(*) AS text_lines FROM lock_tree_replay_text() \gset
SELECT count(*) AS at_root FROM lock_tree_replay() WHERE depth = 0 \gset
SELECT count(*) AS at_depth2 FROM lock_tree_replay() WHERE depth = 2 \gset
SELECT (SELECT count(*) FROM lock_tree_replay()
          WHERE depth = 0 AND root_object IS NOT NULL)      AS root_obj_set \gset
SELECT (SELECT count(*) FROM lock_tree_replay()
          WHERE depth = 0 AND query_id IS NOT NULL)         AS root_qids \gset
SELECT (SELECT count(*) FROM lock_tree_replay()
          WHERE depth = 0 AND wait_age IS NOT NULL)         AS root_waits \gset
SELECT count(*) AS lines_with_box FROM lock_tree_replay_text() AS t(line)
 WHERE t.line LIKE '%└─%' \gset
SELECT count(*) AS indent_two FROM lock_tree_replay_text() AS t(line)
 WHERE t.line LIKE '%  └─%' \gset
SELECT count(*) AS indent_one FROM lock_tree_replay_text() AS t(line)
 WHERE t.line LIKE '└─%' \gset
SELECT (SELECT count(*) FROM lock_tree_replay() WHERE state IS NULL) AS null_states \gset
\o
\set QUIET 0

SELECT is(:replay_instants::int, 1,
          'a replay with no target returns exactly ONE sample, not the whole history');

SELECT is(:replay_rows::int, :peak::int + 1,
          'and that sample holds the root plus every session behind it, ' || :replay_rows || ' rows');

SELECT is(:text_lines::int, :replay_rows::int, 'one rendered line per row, as the live renderer does');

SELECT is(:at_root::int, 1, 'one depth-0 row');

SELECT is(:at_depth2::int, 3, 'three sessions at depth two, which is what made it a chain');

SELECT is(:root_obj_set::int, 0,
          'and the session root has a NULL root_object, as the live view has it');

SELECT is(:root_qids::int, :at_root::int, 'while the root row does carry the query_id');

SELECT is(:root_waits::int, 0,
          'and wait_age is NULL on the root, because a root is not waiting for anything. This is why '
          || 'reading wait_age off the root row, which 0.12 did, could never work');

SELECT is(:lines_with_box::int, 4, 'four waiter lines, each drawn with the box character');

SELECT is(:indent_one::int, 1, 'one of them at depth one, indented by nothing');

SELECT is(:indent_two::int, 3, 'and three at depth two, indented by two spaces per level');

SELECT is(:null_states::int, 0, 'every row carries a state, so the tree is not a list of pids');

-- --------------------------------------------------- waiting_for is qualified, on purpose

SELECT is(:unqualified::int, 0,
          'waiting_for in the history is SCHEMA-QUALIFIED (public.rp_demo) where lock_tree renders it '
          || 'unqualified. lock_tree_sample() is SECURITY DEFINER SET search_path = pg_catalog, so '
          || 'regclass cannot resolve unqualified there. Measured, and it is the stable rendering: '
          || 'the same lock reads the same way in every row whatever the reader''s search_path');

-- ------------------------------------------------------ the nearest sample, and which one

\set QUIET 1
\o /dev/null
-- A target BETWEEN two samples, half a second from the earlier and well away from the later.
WITH ordered AS (
  SELECT sampled_at,
         row_number() OVER (ORDER BY sampled_at) AS n,
         lead(sampled_at) OVER (ORDER BY sampled_at) AS nxt
    FROM lock_tree_replay_samples
)
SELECT (SELECT count(DISTINCT sampled_at) FROM lock_tree_replay(mid))       AS picked_instants,
       quote_literal((SELECT min(sampled_at) FROM lock_tree_replay(mid))::text) AS picked,
       quote_literal((SELECT sampled_at FROM ordered WHERE n = 2)::text)      AS earlier,
       quote_literal((SELECT sampled_at FROM ordered WHERE n = 3)::text)      AS later
  FROM (SELECT (earlier + (later - earlier) / 4) AS mid
          FROM (SELECT sampled_at AS earlier,
                       lead(sampled_at) OVER (ORDER BY sampled_at) AS later
                  FROM lock_tree_replay_samples
                 ORDER BY sampled_at
                 OFFSET 1 LIMIT 1) q) w \gset
-- The quoted value is spliced back in as a literal, so it needs its own quoting removed first.
SELECT quote_literal(:earlier) AS earlier_lit \gset
SELECT count(*) AS first_sample_rows FROM lock_tree_replay(:earlier_lit::text::timestamptz) \gset
SELECT count(*) AS null_target_rows FROM lock_tree_replay(NULL::timestamptz) \gset
\o
\set QUIET 0

SELECT is(:picked_instants::int, 1, 'a target between two samples still returns exactly one sample');

SELECT is(:picked::text, :earlier::text,
          'and it is the NEARER of the two, not the later one. Getting this wrong would silently '
          || 'replay a moment the reader did not ask for, which is why sampled_at is in every row');

SELECT is(:first_sample_rows::int, :replay_rows::int,
          'asking for an earlier sample by its own timestamp returns the same shape, because every '
          || 'sample of this incident held the same five sessions');

SELECT is(:null_target_rows::int, :replay_rows::int,
          'and an explicit NULL means the most recent sample, which is what the default does');

-- ------------------------------------------ the columns that are NOT here, and why

\set QUIET 1
\o /dev/null
-- The nine absent columns are asserted BY NAME against the live view, not by count, because a count
-- would not say which are missing and which are the part a reader needs.
--
-- information_schema.parameters with parameter_mode = 'OUT', and neither of the two obvious
-- alternatives. pg_get_function_result is a TYPE list, so recovering names from it by splitting on
-- commas breaks on any type containing one and yields 'timestamp with time zone' rather than
-- sampled_at anyway. proargnames does carry names but includes the IN parameter first, so it would
-- report as_of as one of the output columns.
CREATE TEMP TABLE live_cols AS
SELECT a.attname
  FROM pg_attribute a
 WHERE a.attrelid = 'lock_tree'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
-- The column is specific_name and not specific_function, and the value is OID-DISAMBIGUATED:
-- information_schema reports this one as lock_tree_replay_33698, not lock_tree_replay. So equality
-- on the bare name returns nothing, which is what made the first version of this compare 18 columns
-- against one. A regex anchored on digits after the name matches this function and not
-- lock_tree_replay_text, which a LIKE on the bare name would also have matched.
CREATE TEMP TABLE replay_cols AS
SELECT parameter_name AS attname
  FROM information_schema.parameters
 WHERE specific_schema = current_schema()
   AND specific_name ~ '^lock_tree_replay_[0-9]+$'
   AND parameter_mode = 'OUT';
SELECT coalesce(quote_literal(string_agg(c, ', ' ORDER BY c)), '''(none)''') AS absent FROM (
  SELECT attname AS c FROM live_cols
  EXCEPT SELECT attname FROM replay_cols) q \gset
SELECT coalesce(quote_literal(string_agg(c, ', ' ORDER BY c)), '''(none)''') AS present_new FROM (
  SELECT attname AS c FROM replay_cols
  EXCEPT SELECT attname FROM live_cols) q \gset
\o
\set QUIET 0

SELECT is(:absent::text,
          'blocked_by, client_addr, datname, path, state_age, usename, wait_event, wait_event_type, xact_age',
          'the nine columns lock_tree has and lock_tree_replay does not, named rather than counted: '
          || 'path and blocked_by because the history stores one row per session rather than the '
          || 'edge between them, and the rest because they were never recorded. Supplying them would '
          || 'mean widening the history for every future sample on every database, and it would not '
          || 'retroactively supply the past'::text);

-- One, since 0.16. It was two until then, and the second is the reason this assertion is a set
-- difference and not a constant: query_id was on replay and not on lock_tree, so the live tree could
-- not be joined to the history on the column the whole duration family is keyed by. 0.16 appended it
-- to the view, which is the only change CREATE OR REPLACE VIEW permits.
SELECT is(:present_new::text, 'sampled_at'::text,
          'the one column replay has that lock_tree does not, and it is there so you can see which '
          || 'sample you actually got. The other was query_id until 0.16 appended it to the view, so '
          || 'that this is a set difference rather than a constant is the point: it is what caught '
          || 'the asymmetry'::text);

-- ------------------------------------------------------------------ empty history

\set QUIET 1
\o /dev/null
TRUNCATE lock_tree_history;
SELECT count(*) AS empty_samples FROM lock_tree_replay_samples \gset
SELECT count(*) AS empty_replay FROM lock_tree_replay() \gset
SELECT count(*) AS empty_text FROM lock_tree_replay_text() \gset
\o
\set QUIET 0

SELECT is(:empty_samples::int, 0, 'an empty history gives no samples to replay');

SELECT is(:empty_replay::int, 0, 'and replay returns no rows rather than raising');

SELECT is(:empty_text::int, 0, 'and the renderer returns no lines rather than raising');

SELECT * FROM finish();

\set QUIET 1
\o /dev/null
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE application_name IN ('nightly_batch', 'api', 'reporting');
DO $bye$ DECLARE c text; BEGIN
  FOR c IN SELECT n FROM (VALUES ('rp_root'), ('rp_mid'),
                          ('rp_w1'), ('rp_w2'), ('rp_w3')) AS t(n) LOOP
    BEGIN PERFORM dblink_disconnect(c); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $bye$;
TRUNCATE lock_tree_history;
DROP TABLE rp_demo;
\o
\set QUIET 0