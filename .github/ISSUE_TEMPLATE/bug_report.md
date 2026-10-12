---
name: Bug report
about: Something here does not do what the documentation says it does
title: ''
labels: ''
# `labels` is empty because the labels this repository uses are created in GitHub's
# settings rather than in the repository, and this file must not name a label that
# does not exist. Checked 2026-10-12: without this front matter GitHub did not
# register the file as a template at all, so the chooser offered nothing but a blank
# issue.
---
# Bug report

<!--
Short on purpose. Everything here is something only you can supply, and everything below the fold is
something we can work out from the repository. If a field does not apply, say so rather than deleting
it: "not applicable" is an answer, a missing field is a question we will have to ask back.

Do not report a security problem here. SECURITY.md says where to send those, and they need to stay off
a public issue tracker.
-->

**What you expected**

<!-- One or two sentences. What did you think would happen? -->

**What happened**

<!-- What did you see instead? -->

**Version**

<!-- The `default_version` in pg_lock_tree.control, or the tag you installed. -->

**PostgreSQL version and platform**

<!-- `SELECT version();` is enough. Managed instances are worth naming: RDS, Aurora and other hosted
    platforms differ from a self-managed server in ways that matter for locks. -->

**Output of `SELECT * FROM lock_tree_text()`**

<!--
This is the one field that usually answers the question on its own, and it is safe to paste: the text
form is built for a human to read and is what the tool would show an operator. Run it as the role you
would use, not as a superuser, so we see what you actually see.
-->