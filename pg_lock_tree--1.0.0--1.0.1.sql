/* pg_lock_tree--1.0.0--1.0.1.sql
 *
 * A patch release. Three defects in 1.0.0's redaction, all found by running the shipped function
 * rather than reading it.
 *
 *   lock_tree_redact(text)     replaced: real SCRAM verifiers, and four PASSWORD shapes
 *   lock_tree_history          one-off scrub of rows written before 1.0.0
 *   EXECUTE on lock_tree_sample  revoked from PUBLIC
 *
 * H1. THE REDACTION LEAKED, IN THE SHAPE THAT MATTERS MOST
 *
 * A real SCRAM verifier is
 *
 *     SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>
 *
 * and 1.0.0's character class could not get past the 4096:, so the pattern failed and a verifier
 * passed to a function was stored whole. Its own test fixture had no iteration count, which is how
 * that survived. The fix also closes PASSWORD $$x$$, a password containing a newline, a statement
 * cut off by track_activity_query_size before its closing quote, and U&'x' or a comment between
 * PASSWORD and the literal.
 *
 * The new pattern replaces to the END of the statement rather than to the last quote on the line,
 * because a truncated statement has no closing quote to find. That also removes any clause
 * following the password, such as VALID UNTIL, which is a deliberate trade and is asserted in
 * test/21.
 *
 * H2. ROWS SAMPLED BEFORE 1.0.0 STILL HELD THEIR PASSWORDS
 *
 * 1.0.0 changed how new rows are written and left every existing row alone, so an upgraded database
 * still held every password the history had ever caught, until pruning removed them. The scrub
 * below is limited to rows that could match, so it does not rewrite the whole table.
 *
 * It is one UPDATE in the update script, which means one transaction. On a large history that is a
 * long transaction holding a lock on the table, and a sampler writing to it waits. Estimate before
 * upgrading a big one:
 *
 *     SELECT count(*) FROM lock_tree_history
 *      WHERE query ~* '(password|scram-sha-256\$|md5[0-9a-f]{32})';
 *
 * A DUMP TAKEN BEFORE UPGRADING, AND EVERY PHYSICAL BACKUP TAKEN BEFORE UPGRADING, STILL CONTAINS
 * THE ORIGINALS. This release cannot reach into them.
 *
 * H3. ANY ROLE COULD SWITCH REDACTION OFF AND READ OTHER SESSIONS' QUERY TEXT
 *
 * lock_tree_sample() is SECURITY DEFINER and was executable by PUBLIC, and it reads
 * lock_tree.history_query from the caller's session. A role with nothing but SELECT on the history
 * could therefore:
 *
 *     SET lock_tree.history_query = 'full';
 *     SELECT lock_tree_sample();
 *
 * and read another session's blocked statement back out of the table, password and all, even
 * though pg_stat_activity showed that same text as <insufficient privilege> to it. Reproduced on
 * PostgreSQL 18.
 *
 * Revoking EXECUTE makes the database's setting decide, which is what the documentation already
 * implied. The role that schedules the sample needs it granted explicitly; INSTALL.md now says so
 * next to the other grants.
 *
 * This is a behaviour change for anyone who was relying on PUBLIC EXECUTE, which is a real cost of
 * the fix. It is the right one: a SECURITY DEFINER function that reads every session's query text
 * should not be callable by every role that can connect.
 *
 * No table is dropped, no column is dropped, no signature changes, and no existing grant on any
 * other object is revoked.
 */

-- H3. PUBLIC loses the right to sample.
--
-- The grant is not restored on upgrade for anyone, deliberately: a role that had it was able to read
-- every session's query text through it, and reinstating that silently would put back the hole the
-- revoke closes. INSTALL.md tells the scheduling role what to grant.
REVOKE EXECUTE ON FUNCTION @extschema@.lock_tree_sample() FROM PUBLIC;


CREATE OR REPLACE FUNCTION @extschema@.lock_tree_redact(q text)
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



-- H2. One-off scrub of rows written before 1.0.0.
--
-- The predicate is deliberately narrow. A WHERE that matched nothing would still be a full scan of
-- the table and would still take a row lock on every row the UPDATE has to examine, so it is
-- limited to rows that could possibly contain something: the literal word password, a SCRAM
-- verifier, or an md5 hash. On a history with no credentials in it, which is the normal case after
-- 1.0.0 has been running, this matches nothing and costs one sequential scan.
--
-- left(..., 300) because the column is documented as holding the first 300 characters, and a row
-- written by an older version was not cut at 300 before redaction, so redaction can only make it
-- shorter. Applying the cut keeps the column's contract true of every row in the table.
--
-- The verifier shape and the five PASSWORD shapes that 1.0.0 missed are all covered by 'password'
-- or by 'scram-sha-256', so the predicate does not have to enumerate them. A row whose only
-- credential was a bare md5 hash with no surrounding words is caught by the md5 branch.
UPDATE @extschema@.lock_tree_history
   SET query = left(@extschema@.lock_tree_redact(query), 300)
 WHERE query ~* '(password|scram-sha-256\$|md5[0-9a-f]{32})';
