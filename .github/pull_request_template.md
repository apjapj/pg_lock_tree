<!--
Kept short for the same reason as the issue template: a long form gets filled in with "N/A" and tells
us nothing. What we cannot work out for ourselves is what you were trying to do and what you expected,
so those are the only required fields.
-->

**What this changes, and why**

<!-- One or two sentences. Link the issue if there is one. -->

**How it was verified**

<!--
Say what you ran and what it printed. If you changed a check, say you saw it fail before the change
and pass after: CONTRIBUTING.md's "Proving a check fails" has the method, and a check that was never
seen to fail is not evidence that it can.
-->

- [ ] `make lint` passes
- [ ] the tests pass on 14 and 18
- [ ] if a file was hand-copied into a container, the `md5sum` of the destination was compared with the
      source, per [CONTRIBUTING.md](https://github.com/apjapj/pg_lock_tree/blob/main/CONTRIBUTING.md#proving-a-check-fails)
- [ ] if this changes user-visible text, `CHANGELOG.md` has an entry and the version was incremented

<!--
Tick what applies and leave the rest. An unticked box is not a problem; a ticked box that was never run
is, because it reads as evidence that nothing broke and we will not re-check it.
-->

**Anything a reviewer should know before reading the diff**

<!-- Breaking change, a lock taken during a test, a scenario that skips itself here and why. -->