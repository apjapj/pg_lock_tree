# alerting: being told, without being told about nothing

**For: whoever wires a pager to a NOTIFY channel.** Thresholds, what escalates, what the payload
contains, and how to tell that the alerting itself is working.

```
-- schedule this, and expect NOTIFY on the lock_tree channel
SELECT lock_tree_notify();

-- the other half: an event when a root stops being worth waking someone for
SELECT lock_tree_notify_resolved();
```

Everything above is for someone who is already looking. This is for when nobody is.

`lock_tree_notify()` raises a `NOTIFY` when a lock chain is bad enough to be worth waking
someone for. It does **not** page anyone, and understanding why is the first thing worth
understanding about it.

## What this does and does not do

It raises a `NOTIFY` on a PostgreSQL channel. That is all. Turning that channel into a page is
the deployment's job, and the reason is that paging is a policy decision: what pages you, where
it goes, who gets woken at 3am, and what happens when the pager is down are all choices that
belong to whoever runs the system. The payload is JSON so that whatever you connect can parse it
without knowing anything about this extension.

The usual way to connect it is `LISTEN` from a script, or a `LISTEN`/`NOTIFY` bridge shipped with
PostgreSQL that forwards to another channel. There is no opinion here about which.

## Why it does not notify on every sample

This is the design decision that matters, and getting it wrong makes alerting worse than not
having it.

If you call `lock_tree_notify()` on every sample and it notifies whenever anything is blocked,
then a two-minute incident with a ten-second sample produces twelve notifications. Everyone
learns within a week that the `lock_tree` channel is noise, and the one alert that mattered gets
filtered along with the rest. **A diagnostic tool that cries wolf is worse than a silent one**,
because it costs you the one thing the tool was for.

So the function keeps state in `lock_tree_alert` and notifies only on:

| | when it notifies |
|---|---|
| **Onset** | a root becomes notable and has not been notable before on this channel |
| **Escalation: wider** | a root already known is now blocking *more* sessions than it ever has |
| **Escalation: deeper** | it is *deeper* than it ever has |
| **Escalation: older** | its longest wait has *doubled* since the last notification |

and stays quiet while a chain sits at the same severity. A queue wobbling between 40 and 12
sessions notifies once, not twice a minute.

State is compared against high-water marks, not the previous sample, which is what makes
"escalation" and "recovery" distinguishable. A root dropping from 40 to 12 sessions is getting
better and must not re-notify.

When a root stops being notable its state is forgotten, so the same chain returning later alerts
again. That is what makes a *second* incident visible rather than suppressed as already-seen.

## Why the wait escalates by doubling and not by growing

Wider and deeper are **edges**: something happened, and the comparison says so. A wait is not an
edge, it is a slope. It grows every second, so asking "is the longest wait longer than last time?"
is true on every single sample, and the function would notify sixty times an hour. That is the
exact failure `lock_tree_alert` exists to prevent, reached by a different route.

So the age comparison is against **the wait recorded at the last notification**, and it fires only
once the wait has doubled. A chain that never gets wider or deeper, and simply ages, produces:

<!-- illustrative: written by hand. It is a timeline the thresholds produce, drawn out; no sample prints it. -->

```
 30s    1m    2m    4m    8m    16m   32m
  |     |     |     |     |      |      |
  +-----+-----+-----+-----+------+------+
```

Seven notifications for a thirty-two minute incident, each one saying it is roughly twice as bad as
the last. Seven is the point: few enough that nobody learns to filter the channel, many enough
that a thirty-minute queue does not sit at the same reported severity for half an hour.

**Age escalation only applies when `min_wait` is set.** If you pass `min_wait => NULL` you have
said you do not want to be paged on wait age, and that switch is honoured even when the wait is
enormous. A second page about a slow queue you did not ask about is how a channel stops being read.

One detail that matters if you read the code: the doubling falls back to `min_wait` when no wait
has been recorded yet, because the view truncates `wait_age` to whole seconds and a wait under a
second reads as zero. Comparing against twice zero is true forever. That was a real bug, found by
the assertion that nothing is recorded when `min_wait` is off.

## Choosing thresholds

This is the part people get wrong, so the thresholds are arguments rather than settings and there
are no meaningful defaults. A default nobody reads is a default nobody trusts.

```sql
lock_tree_notify(
  channel      text     DEFAULT 'lock_tree',
  min_blocked  integer  DEFAULT 1,        -- NULL or 0 switches this off
  min_depth    integer  DEFAULT 2,        -- NULL or 0 switches this off
  min_wait     interval DEFAULT '30 seconds'  -- NULL switches this off
) RETURNS bigint
```

**A root alerts if it meets AT LEAST ONE criterion that is switched on.** With all three at their
defaults, a chain alerts if it blocks one session, **or** is two deep, **or** has someone waiting
30 seconds.

That is deliberate. A queue can be bad in ways that have nothing to do with each other: a hundred
sessions waiting one second is not an incident, and two sessions waiting an hour is. An operator
paging on "deep **or** slow" will not miss the incident that is both, and an operator paging on
"deep **and** slow" will sit through both of the others.

At least one criterion must be on. All three off means "alert on every root", which is rejected
with an error rather than quietly given a plausible default.

What the defaults are *for*: they are a starting point for a database you have not watched yet,
and they will be wrong for any specific database within a week. The intended sequence is:

1. Leave the defaults and schedule it. Read what it reports.
2. Note which criteria actually fired. Most databases will only ever trip `min_depth`.
3. Set the other two to NULL and raise the one that matters.

```sql
-- only care about long waits, on a busy server where shallow queues are normal
SELECT lock_tree_notify('lock_tree', min_blocked => NULL, min_depth => NULL,
                        min_wait => interval '2 minutes');
```

`NULL` means "do not consider this". `0` is the same thing for the two integer criteria, since
"at least 0 sessions blocked" is every root.

## What the return value is for

It returns how many notifications it raised. **Zero is the normal, healthy result**, and it is the
value worth watching. A sampler that logs it will show you exactly when your alerting is doing
something:

```sql
SELECT now(), lock_tree_notify() AS alerts;
```

If that column is zero forever, either nothing is wrong or your thresholds are too high to ever
fire. Both are worth knowing, and neither is visible from a silent channel alone.

## Scheduling it

The natural home is the same cron entry as the sample, because both need to run on the same beat:

```sql
SELECT cron.schedule('lock_tree_sample', '10 seconds',
                     $$SELECT lock_tree_sample(); SELECT lock_tree_notify();$$);
```

One statement can do both, which also means the alert reflects the instant the sample was taken
rather than a slightly later one.

## The payload

```json
{"tool":"pg_lock_tree","subject":"pid 179","sampled_at":"2026-10-09T14:22:31+01:00",
 "channel":"lock_tree","event":"alerting","root_pid":179,
 "application_name":"nightly_reconciliation",
 "blocked_sessions":40,"max_depth":2,"longest_wait":"3m12s",
 "waiting_for":"AccessShareLock on ledger"}
```

Every key is always present, `null` excepted where there is genuinely nothing to say.

**There is no size check in this extension.** An earlier version of this paragraph said the server
enforces an 8000-byte payload limit, which was true of the server and false of this code: there is no
`octet_length` or equivalent anywhere in `pg_lock_tree--1.1.12.sql`, so nothing here measures the
payload before sending it. What is true is that PostgreSQL **refuses** an oversized `NOTIFY` rather
than truncating it, measured on 18.6: a payload of exactly 8000 bytes is accepted, and the failure
comes at 8003 bytes with a 2-character channel, because the bound is on the whole message with the
channel included. Past that the statement raises `payload string too long`, and because the notify is
a PL/pgSQL sweep over `lock_tree_alert`, that exception aborts the sweep and returns an error to the
caller rather than dropping one message quietly.

The payload as shipped is 334 bytes, and 4,624 in a deliberately absurd worst case with 4,000-character
names, so there is a wide margin. The margin is arithmetic, not a guarantee, and it is the reason a
future key should be argued for on its own merits rather than added because the payload is small
enough to absorb it.

`tool`, `subject` and `sampled_at` are **new in 1.1.11**, and they come from a shared contract
across the [pg_incident_watch](https://github.com/apjapj/pg_incident_watch) family of extensions,
which two more tools will join. The contract is written as ALERTS.md in that project, which is not in
this repository; what matters here is what
the three keys are for and why this extension sends them.

`tool` is `pg_lock_tree`, always. Until 1.1.11 the only thing saying which extension sent a message
was the channel name, which works right up until you run more than one of these extensions and then a
listener has to hard-code the mapping somewhere outside the payload.

`subject` is the alert's identity: the prepared transaction's lock name where there is one, and
`pid N` otherwise. It is stable for as long as the incident lasts, so it is the thing to pair an
escalation with its onset, and a clearing with both. **Prefer it to `root_pid`** for the same reason
`application_name` is preferred below, and for one more: when the root is a prepared transaction
there is no session to name and the pid alone cannot tell two of them apart.

`sampled_at` is when the payload was formed. There is no sampled instant behind it. An alert is about
the live tree, not about a history row, so this is the statement's own timestamp and nothing more.

**This extension does not send an `escalated` event.** The contract defines one and lets a tool omit
it, which this one does: it sends `alerting` for both an onset and an escalation, and says so here
rather than claiming a distinction it does not make. Sending `escalated` is a behaviour change and is
not in 1.1.11.

`event` itself is **new in 0.12**, and was the only change to this payload until 1.1.11. It exists
because 0.12 adds a second kind of notification on the same channel, and a consumer needs one field
to branch on rather than inferring which kind it got from the presence or absence of some other key.
It is additive: JSON consumers read by key, so a listener written before 0.12 that ignores fields it
does not recognise is unaffected. The same is true of the three keys above, and that is this
project's rule for this payload: keys are added, never removed or renamed.

`application_name` is the one to key on rather than `root_pid`. A pid identifies one session for
as long as that session lives, which is the wrong key for correlating a page with a log or a
dashboard across restarts and reconnects.

## Knowing when it is over

`lock_tree_notify()` says when something starts getting worse and then says nothing, which is
right for a pager and wrong for the person who was woken up. `lock_tree_notify_resolved()` closes
that gap:

```sql
SELECT lock_tree_notify_resolved('lock_tree', 10, 3, '30 seconds');
```

It raises one notification per root that **had alerted** and has since left the tree, with
`event` set to `"cleared"`, then forgets the stored state so the same root blocking again alerts
from the start rather than escalating against a high-water mark from a previous incident. A root
that never alerted produces nothing, because a resolution notice with no matching alert is noise.

```json
{"tool":"pg_lock_tree","subject":"pid 179","sampled_at":"2026-10-09T14:33:02+01:00",
 "event":"cleared","channel":"lock_tree","root_pid":179,"root_object":null,
 "application_name":"nightly_reconciliation","blocked_at_most":40,"notified_count":2}
```

`blocked_at_most` and `notified_count` are there so a reader can judge what it was: a cleared root
that had blocked forty sessions and escalated twice is a different thing from one that briefly
blocked two.

It is a separate function rather than a parameter on `lock_tree_notify()` on purpose. An
`alerting`/`cleared` pair on the same channel is what a consumer wants, but whether an incident
ending is worth waking someone is a property of your rota rather than of this extension, and
someone who never wants it should not be able to switch it on by accident through named notation.
Run it from the same cron entry as `lock_tree_notify()`, and pass **the same thresholds**, because
the two key on the same state and a mismatch means resolving alerts that were never sent.

A consumer written before 0.12 that ignores unknown fields is unaffected. One that switches on
`event` gets the pair it needs.

## `lock_tree_alert`, and why you should not need to look at it

One row per notable root per channel per threshold set, holding the high-water marks. It is the
size of the current queue, not of its history, and `lock_tree_notify()` maintains it. You should
never need to touch it.

`lock_tree_prune_alerts()` exists for state orphaned by a restart or a retired channel name, and
is worth calling from the same cron entry as the sample if you care. It is not load-bearing.

## Checking it works

Two ways, and they check different things. Both are in [`scripts/check-alert.sh`](../scripts/check-alert.sh), which takes the flags below.

```bash
scripts/check-alert.sh              # builds a chain, notifies, and reads the notification back
scripts/check-alert.sh --explain    # the same, then explains the payload it received
scripts/check-alert.sh --explain '{"root_pid":0,...}'
```

That verifies the delivery path end to end, which no assertion can: `psql` prints notifications to
stdout and a TAP test cannot see stdout, so the stream is checked by a real second client. It also
asserts the payload **sequence**, which is how the silence check can be trusted: exactly two
payloads arrive, `alerting` then `cleared`, so a function that returned 0 while still sending
something would be caught.

`test/11_alert.sql` verifies the decisions, which is the part worth unit-testing: onset fires once,
an unchanged chain stays silent, escalation fires on width and on depth, age escalates only on a
doubling, recovery then relapse fires again, thresholds behave, and all three disabled is an error.
`test/16_duration_resolved.sql` covers the resolution notices: nothing on a quiet database, one
per cleared root, none while the incident is still standing, and the state forgotten afterwards.

## What to do when one arrives

`--explain` takes the payload and prints what it means, the queries to run in order, and what not
to do. It needs **no database**, which is the point: the first thing you do at 3am should be
something that cannot fail because the database is the thing that is broken.

```console
$ scripts/check-alert.sh --explain '{"root_pid":0,
    "root_object":"AccessExclusiveLock on public.ledger","application_name":"",
    "blocked_sessions":12,"max_depth":1,"longest_wait":"9m05s",
    "waiting_for":"AccessShareLock on public.ledger"}'

  What it means
  -------------
  The blocker is a PREPARED TRANSACTION. It has no backend, no session and no
  application_name, which is why the root pid is 0 and the name is empty.
  Nothing you can do to a session will clear this. pg_cancel_backend(0) returns
  false and warns that pid 0 is not a backend; pg_terminate_backend(0) likewise.
  The only remedy is ROLLBACK PREPARED, and you need the gid.

  Run these, in this order
  ------------------------
  SELECT gid, prepared, owner FROM pg_prepared_xacts;
    -- pick the gid whose prepared time is close to the incident, then:
  ROLLBACK PREPARED '<gid>';
  -- the lock it holds is: AccessExclusiveLock on public.ledger
```

It branches on `root_pid` rather than on the message text, so a session root gets
`pg_terminate_backend` steps and a prepared root gets `ROLLBACK PREPARED` steps. That branch is
worth being careful about: the two failures look identical on a dashboard and need opposite
remedies.

`make explain-alert PAYLOAD='…'` is the same thing if you prefer make. A payload that is not JSON,
or is JSON from something else on the same channel, is reported as such rather than guessed at.

## Choosing an interval

`lock_tree_sampling_advice()` answers "how often should I be sampling", which is a question about
cost rather than taste. The cost of a sample is one row per blocked session, so a wide queue
argues for a wider interval:

```sql
SELECT * FROM lock_tree_sampling_advice();
```

It is sized on the **widest queue in the window**, not on the queue at the instant. That is the
whole point, and getting it wrong is easy: a cron entry that runs at 3am on a quiet Sunday would
otherwise recommend the finest interval for a database that spends every weekday morning with four
hundred sessions waiting. The advice was not wrong about the instant; it was answering the wrong
question.

<!-- illustrative: written by hand, then checked against lock_tree_sampling_advice() on PG18: one historical sample of 450 sessions with nothing blocked now, and an empty history. Reasons wrapped. The second row is 1.0.2's wording; 1.0.1 said "so sample rarely" beside 00:00:05, the finest interval the function ever returns. One line, because the classification check looks four lines up. -->

```
 blocked_sessions | roots | suggested_every |              reason              | observed_peak | live_blocked
------------------+-------+-----------------+----------------------------------+---------------+--------------
              450 |     0 | 00:00:30        | quiet now, but 450 sessions were |           450 |            0
                  |       |                 | waiting at the peak in this      |               |
                  |       |                 | window, so sized for that rather |               |
                  |       |                 | than for now                     |               |
                0 |     0 | 00:00:05        | nothing blocked now and nothing  |             0 |            0
                  |       |                 | in the window: a sample writes   |               |
                  |       |                 | nothing here, so 5 seconds costs |               |
                  |       |                 | one cheap query and still        |               |
                  |       |                 | catches the next incident in     |               |
                  |       |                 | detail                           |               |
```

`observed_peak` and `live_blocked` are both returned, and the figure used is the greater of the two,
so a queue that started after the last sample is not ignored and the advice can be traced back to
what it was based on.

## Requirements, plainly

- **`NOTIFY` needs nothing.** No extension, no `shared_preload_libraries`, no restart. If
  `lock_tree_notify()` works at all, `NOTIFY` works at all.
- **Something has to be listening** or the notification is delivered to nobody. PostgreSQL does
  not queue notifications for absent listeners, so a `NOTIFY` raised while nothing is listening is
  simply discarded. This matters for the sampler: if your listener is down, you get no alerts and
  no record that you got none.
- **`lock_tree_alert` needs write access, and the grant is four privileges.** This was documented here
  as "must be writable", which is one word for `SELECT, INSERT, UPDATE, DELETE`. The grant and what was
  measured about it are in [INSTALL.md](../INSTALL.md#grants). No minimum is quoted: every subset tried
  was accepted on one run and refused on the next with the same grants, so which are needed appears to
  depend on what the channel has already recorded. The function is not `SECURITY DEFINER`,
  deliberately: it is a decision about what is important enough to tell someone, and a role that can set
  thresholds is a role that can page people.- **The sampler needs to run as often as you want to know.** Alerting inherits the sample
  interval. Sampling every minute means learning about a minute-long queue a minute late, which is
  usually fine, and sampling every ten seconds means learning in ten seconds at ten times the
  write cost.
