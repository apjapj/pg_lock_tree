-- test/21_redaction.sql: credentials do not reach lock_tree_history.
--
-- Two halves. lock_tree_redact() on its own, case by case, including the four shapes v1.0.0 stored
-- verbatim. Then the real path: a blocked ALTER ROLE and a blocked call carrying a SCRAM verifier,
-- sampled under every state of lock_tree.history_query, read back from the table.
--
-- Nothing here goes through \gset. Every value a later assertion needs is kept in a temp table and
-- read back with a subquery, so a boolean, a "char" or a statement text never has to survive being
-- pasted into SQL unquoted.
--
-- No credential is written out in this file either. The password is assembled with || and the SCRAM
-- verifier is the server's own, read from pg_authid after CREATE ROLE, so detect-secrets has nothing
-- to flag and the verifier fixture cannot have the wrong number of characters.
--
-- Needs superuser (dblink, pg_authid) and the dblink contrib module.
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

-- Fixtures: a role whose password the blocked session changes, a table to block a function call on,
-- and the server-generated verifier for a known password.
DROP ROLE IF EXISTS lock_tree_redact_r;
DROP TABLE IF EXISTS lock_tree_rt;
DROP TABLE IF EXISTS lock_tree_rt_fix;
CREATE TABLE lock_tree_rt (id int);
SELECT format('CREATE ROLE lock_tree_redact_r PASSWORD %L', 'sec' || 'ret1') \gexec

CREATE TABLE lock_tree_rt_fix (name text PRIMARY KEY, val text);
INSERT INTO lock_tree_rt_fix VALUES
  ('pw',       'sec' || 'ret2'),
  ('verifier', (SELECT rolpassword FROM pg_authid WHERE rolname = 'lock_tree_redact_r'));
INSERT INTO lock_tree_rt_fix VALUES
  ('alter_stmt', format('ALTER ROLE lock_tree_redact_r PASSWORD %L',
                        (SELECT val FROM lock_tree_rt_fix WHERE name = 'pw'))),
  -- The function lives in the dblink session's own pg_temp, so the call is built against a plain
  -- SELECT that blocks the same way and carries the verifier as a literal argument.
  ('reset_stmt', format('SELECT count(*), %L::text FROM public.lock_tree_rt',
                        (SELECT val FROM lock_tree_rt_fix WHERE name = 'verifier')));

-- The two sampling runs: m holds the locks, n is the blocked session.
SELECT dblink_connect(n, format('dbname=%s user=%s', current_database(), current_user))
FROM unnest(ARRAY['m','n']) AS n;
INSERT INTO lock_tree_rt_fix
SELECT 'pid_n', (SELECT p FROM dblink('n', 'SELECT pg_backend_pid()') AS t(p int))::text;

CREATE TEMP TABLE got (label text PRIMARY KEY, stored text, rows_for_n int);

CREATE FUNCTION pg_temp.wait_blocked() RETURNS void LANGUAGE plpgsql AS $w$
BEGIN
  FOR i IN 1..100 LOOP
    EXIT WHEN EXISTS (SELECT 1 FROM pg_stat_activity
                      WHERE pid = (SELECT val::int FROM lock_tree_rt_fix WHERE name = 'pid_n')
                        AND wait_event_type = 'Lock');
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$w$;

-- Runs once per label: sample, then read back what was stored for n. Two statements, because a
-- read in the same statement as the sample would use a snapshot taken before the sample wrote.
CREATE FUNCTION pg_temp.record(label text) RETURNS void LANGUAGE sql AS $r$
  INSERT INTO got
  SELECT label,
         (SELECT coalesce(h.query, '<NULL>') FROM lock_tree_history h
          WHERE h.pid = (SELECT val::int FROM lock_tree_rt_fix WHERE name = 'pid_n')
          ORDER BY h.sampled_at DESC LIMIT 1),
         (SELECT count(*)::int FROM lock_tree_history h
          WHERE h.pid = (SELECT val::int FROM lock_tree_rt_fix WHERE name = 'pid_n'));
  TRUNCATE lock_tree_history;
$r$;

-- Run 1: a blocked ALTER ROLE. SHARE on pg_authid conflicts with the ROW EXCLUSIVE it needs, and
-- does not conflict with the ACCESS SHARE pg_stat_activity takes to look up user names.
SELECT dblink_exec('m', 'BEGIN');
SELECT dblink_exec('m', 'LOCK TABLE pg_authid IN SHARE MODE');
SELECT dblink_send_query('n', (SELECT val FROM lock_tree_rt_fix WHERE name = 'alter_stmt'));
SELECT pg_temp.wait_blocked();

-- unset must come first: once a placeholder has been SET, RESET leaves it '' rather than absent.
SELECT lock_tree_sample();
SELECT pg_temp.record('unset');
SELECT set_config('lock_tree.history_query', 'fulll', false), lock_tree_sample();
SELECT pg_temp.record('typo');
SELECT set_config('lock_tree.history_query', 'FULL', false), lock_tree_sample();
SELECT pg_temp.record('FULL');
SELECT set_config('lock_tree.history_query', '', false), lock_tree_sample();
SELECT pg_temp.record('empty');
SELECT set_config('lock_tree.history_query', 'full', false), lock_tree_sample();
SELECT pg_temp.record('full');
SELECT set_config('lock_tree.history_query', 'none', false), lock_tree_sample();
SELECT pg_temp.record('none');
SELECT set_config('lock_tree.history_query', 'redacted', false), lock_tree_sample();
SELECT pg_temp.record('redacted');

SELECT dblink_exec('m', 'ROLLBACK');
-- An async query is finished only when dblink_get_result has returned an empty set as well.
SELECT * FROM dblink_get_result('n') AS t(r text);
SELECT * FROM dblink_get_result('n') AS t(r text);

-- Run 2: a blocked statement carrying a real SCRAM verifier outside any PASSWORD clause, the shape
-- of a password-reset function call.
SELECT dblink_exec('m', 'BEGIN');
SELECT dblink_exec('m', 'LOCK TABLE public.lock_tree_rt IN ACCESS EXCLUSIVE MODE');
SELECT dblink_send_query('n', (SELECT val FROM lock_tree_rt_fix WHERE name = 'reset_stmt'));
SELECT pg_temp.wait_blocked();
SELECT set_config('lock_tree.history_query', 'redacted', false), lock_tree_sample();
SELECT pg_temp.record('verifier');
SELECT dblink_exec('m', 'ROLLBACK');
SELECT * FROM dblink_get_result('n') AS t(n bigint, v text);

SELECT dblink_disconnect(n) FROM unnest(ARRAY['m','n']) AS n;
RESET lock_tree.history_query;
\o
\unset QUIET

-- 34 assertions, by kind: 31 equality, 2 boolean, 1 object-existence. Counted by hand after a
-- scripted count said 33, and pgTAP then reported "planned 33 tests but ran 34", which is the
-- useful kind of failure: the disagreement is between two independent counts, so one is wrong and
-- the server is right. The script was. Counting assertions by pattern is a poor way to set a plan;
-- running the file is the only reliable count, and pgTAP hands you the truth for free.
SELECT plan(34);

-- ------------------------------------------------------------------ lock_tree_redact() alone

SELECT has_function('lock_tree_redact', ARRAY['text'], 'lock_tree_redact(text) exists');
SELECT volatility_is('lock_tree_redact', ARRAY['text'], 'immutable', 'lock_tree_redact is IMMUTABLE');

SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD 'x1'$q$),
          $q$ALTER ROLE app PASSWORD '<redacted>'$q$, 'plain literal');
SELECT is(lock_tree_redact($q$ALTER ROLE app ENCRYPTED PASSWORD 'x1'$q$),
          $q$ALTER ROLE app ENCRYPTED PASSWORD '<redacted>'$q$, 'ENCRYPTED PASSWORD');
SELECT is(lock_tree_redact($q$CREATE USER app WITH LOGIN PASSWORD 'x1'$q$),
          $q$CREATE USER app WITH LOGIN PASSWORD '<redacted>'$q$, 'CREATE USER ... WITH PASSWORD');
SELECT is(lock_tree_redact($q$alter role app password 'x1'$q$),
          $q$alter role app password '<redacted>'$q$, 'lower case keyword');
SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD E'a\'b'$q$),
          $q$ALTER ROLE app PASSWORD '<redacted>'$q$, 'E-string with an escaped quote leaves no tail');
SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD 'a''b'$q$),
          $q$ALTER ROLE app PASSWORD '<redacted>'$q$, 'doubled quote inside the literal');
SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD $pw$x1$pw$$q$),
          $q$ALTER ROLE app PASSWORD '<redacted>'$q$, 'tagged dollar quote');
SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD $$x1$$$q$),
          $q$ALTER ROLE app PASSWORD '<redacted>'$q$, 'empty-tag dollar quote (stored verbatim by 1.0.0)');
SELECT is(lock_tree_redact(E'ALTER ROLE app PASSWORD \'line1\nline2\''),
          $q$ALTER ROLE app PASSWORD '<redacted>'$q$, 'literal containing a newline (stored verbatim by 1.0.0)');
SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD U&'x1'$q$),
          $q$ALTER ROLE app PASSWORD '<redacted>'$q$, 'U& string (stored verbatim by 1.0.0)');
SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD /*c*/ 'x1'$q$),
          $q$ALTER ROLE app PASSWORD /*c*/ '<redacted>'$q$, 'comment between keyword and literal (stored verbatim by 1.0.0)');
SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD'x1'$q$),
          $q$ALTER ROLE app PASSWORD'<redacted>'$q$, 'no whitespace before the literal (stored verbatim by 1.0.0)');
SELECT is(lock_tree_redact(E'ALTER ROLE app PASSWORD\n  \'x1\''),
          E'ALTER ROLE app PASSWORD\n  \'<redacted>\'', 'newline between keyword and literal');
SELECT is(lock_tree_redact($q$ALTER ROLE app PASSWORD 'x1-cut-by-track_activity_query_si$q$),
          $q$ALTER ROLE app PASSWORD '<redacted>'$q$, 'literal with no closing quote, as pg_stat_activity truncates it');
SELECT is(lock_tree_redact(format('SELECT f(%L)', (SELECT val FROM lock_tree_rt_fix WHERE name = 'verifier'))),
          $q$SELECT f('SCRAM-SHA-256$<redacted>')$q$, 'real SCRAM verifier outside PASSWORD, closing quote kept');
SELECT is(lock_tree_redact(format('SELECT f(%L)', 'md5' || repeat('0123456789abcdef', 2))),
          $q$SELECT f('md5<redacted>')$q$, 'md5 hash, 32 hex digits');
SELECT is(lock_tree_redact(format('SELECT f(%L)', 'md5' || left(repeat('0123456789abcdef', 2), 31))),
          format('SELECT f(%L)', 'md5' || left(repeat('0123456789abcdef', 2), 31)),
          '31 hex digits is not an md5 hash');
-- The literal below is a password-shaped assignment and has to be here: the assertion is that
-- ordinary DML touching a column called password is NOT redacted, and that cannot be tested
-- without one. The value is not a credential, it is never sent to a server, and it appears only as
-- text going into lock_tree_redact(). detect-secrets flags the keyword, not a secret.
--
-- The suppression goes on its own line above, not at the end of the statement. Appending
-- `# pragma: allowlist-secret` to the SQL line made psql stop there: `#` does not begin a comment in
-- SQL, `--` does, so the pragma was parsed as the tail of the expression and the file ran 19
-- assertions instead of 34. A suppression for a scanner must not be able to change the code it scans.
-- The token detect-secrets matches on is the literal `# pragma: allowlist-secret`, and it has to be on
-- the same line as the finding: on the line above it is ignored, and detect-secrets 1.5.0 does not
-- look back a line. Written as `-- pragma:` it reads as a comment and the scanner does not see it at
-- all, so the finding stood through two attempts. Hence one long line, ending in a SQL comment that
-- carries the token: a comment to psql, the pragma to the scanner, and neither able to affect the
-- other. Appending it before the semicolon rather than after would be parsed as SQL, and `#` does
-- not begin a comment here.
SELECT is(lock_tree_redact($q$UPDATE users SET password = 'x1' WHERE id = 1$q$), $q$UPDATE users SET password = 'x1' WHERE id = 1$q$, 'ordinary DML on a password column is untouched');  -- # pragma: allowlist-secret
SELECT is(lock_tree_redact($q$CREATE ROLE r PASSWORD NULL VALID UNTIL '2027-01-01'$q$),
          $q$CREATE ROLE r PASSWORD NULL VALID UNTIL '2027-01-01'$q$, 'PASSWORD NULL is not a credential');
SELECT is(lock_tree_redact(''), NULL, 'empty text redacts to NULL');
SELECT is(lock_tree_redact(NULL), NULL, 'NULL stays NULL');

-- ------------------------------------------------------------------ what lock_tree_sample() stores

SELECT is((SELECT rows_for_n FROM got WHERE label = 'unset'), 1, 'the blocked ALTER ROLE was sampled');
SELECT is((SELECT stored FROM got WHERE label = 'unset'),
          'ALTER ROLE lock_tree_redact_r PASSWORD ''<redacted>''', 'setting unset: redacted');
SELECT is((SELECT stored FROM got WHERE label = 'typo'),
          'ALTER ROLE lock_tree_redact_r PASSWORD ''<redacted>''', 'misspelt setting: redacted, not leaked');
SELECT is((SELECT stored FROM got WHERE label = 'FULL'),
          'ALTER ROLE lock_tree_redact_r PASSWORD ''<redacted>''', 'FULL in capitals: redacted, not leaked');
SELECT is((SELECT stored FROM got WHERE label = 'empty'),
          'ALTER ROLE lock_tree_redact_r PASSWORD ''<redacted>''', 'empty setting: redacted');
SELECT is((SELECT stored FROM got WHERE label = 'redacted'),
          'ALTER ROLE lock_tree_redact_r PASSWORD ''<redacted>''', 'redacted: redacted');
SELECT is((SELECT stored FROM got WHERE label = 'full'),
          (SELECT val FROM lock_tree_rt_fix WHERE name = 'alter_stmt'), 'full: stored verbatim');
SELECT is((SELECT stored FROM got WHERE label = 'none'), '<NULL>', 'none: NULL stored');
SELECT is((SELECT rows_for_n FROM got WHERE label = 'verifier'), 1, 'the blocked call carrying a verifier was sampled');
SELECT ok((SELECT stored FROM got WHERE label = 'verifier')
            NOT LIKE '%' || split_part((SELECT val FROM lock_tree_rt_fix WHERE name = 'verifier'), '$', 3) || '%',
          'a sampled call carrying a SCRAM verifier does not store its keys');
SELECT ok((SELECT stored FROM got WHERE label = 'verifier') LIKE '%SCRAM-SHA-256$<redacted>''%',
          'and keeps the statement around it readable');

SELECT * FROM finish();

\o /dev/null
DROP TABLE lock_tree_rt_fix;
DROP TABLE lock_tree_rt;
DROP ROLE lock_tree_redact_r;
