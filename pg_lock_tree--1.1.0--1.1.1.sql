/* pg_lock_tree--1.1.0--1.1.1.sql
 *
 * Deliberately empty, and that is the whole point of it.
 *
 * 1.1.1 changed no SQL. Everything in it is documentation and release tooling: seven cross-references
 * that resolved to files which do not exist beside the document containing them, one SQL example
 * calling a function with an argument type it has never accepted since 0.14, and two new checks in
 * the tooling.
 *
 * This script exists anyway, for two reasons, and the first is the important one.
 *
 * WITHOUT IT, upgrading loses your history. Measured on a database carrying one sampled row:
 *
 *   ALTER EXTENSION pg_lock_tree UPDATE      from 1.0.2 to 1.1.0:  1 row before, 1 row after
 *   DROP EXTENSION then CREATE EXTENSION:                            1 row before, 0 rows after
 *
 * There is no other way to move an extension forward in PostgreSQL. If no update path exists, the
 * only route is to drop it, and dropping it takes lock_tree_history, lock_tree_alert and
 * lock_tree_deadlock with it. So a release with nothing to install still ships an update path, and
 * that is a deliberate trade: one empty file per release, against losing the record of every incident
 * sampled so far.
 *
 * The second reason is that PostgreSQL names the script it runs by the two versions it moves between.
 * With no pg_lock_tree--1.1.0--1.1.1.sql in the extension directory, ALTER EXTENSION ... UPDATE on a
 * 1.1.0 database fails with "no update path from version 1.1.0 to version 1.1.1", which is a worse
 * outcome than an empty file.
 *
 * Nothing below this comment, on purpose. If a future release does change SQL, it deletes this file
 * and writes a real one in its place.
 */