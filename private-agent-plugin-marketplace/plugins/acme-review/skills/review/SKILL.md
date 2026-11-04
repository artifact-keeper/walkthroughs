---
name: review
description: Review a change the way Acme reviewers do. Use when the user asks for a code review, a second opinion on a diff, or whether a change is ready to merge.
---

# Acme code review

Review the change in this order and stop at the first section that fails:

1. **Does it do what the ticket says?** Read the ticket or PR description first. Name any
   behaviour the change adds that nobody asked for.
2. **Is it safe?** Secrets in code or logs, user input reaching a shell, SQL or a file path,
   new network calls, new dependencies (each needs an owner and a reason).
3. **Is it tested?** A test that fails without the change. Coverage of the error path, not only
   the happy path.
4. **Can someone else run it?** Configuration documented, migrations reversible, feature flags
   named in the description.

Write the review as a list of findings, most severe first, each with the file and line, what is
wrong, and what to do instead. End with one line: `ready`, `ready after nits`, or `not ready`.
