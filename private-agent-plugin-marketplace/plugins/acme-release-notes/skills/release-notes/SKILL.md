---
name: release-notes
description: Draft release notes for an Acme service from the merged pull requests since the last tag. Use when the user asks for release notes, a changelog entry or a "what changed" summary.
---

# Acme release notes

1. List the merged changes since the last tag (`git log --merges <last-tag>..HEAD` or the
   pull requests the user names).
2. Group them under **Added**, **Changed**, **Fixed** and **Security**. Drop internal-only
   changes (CI, refactors with no behaviour change).
3. One bullet per change, user-facing language, starting with what the user can now do or no
   longer suffers from, ending with the ticket in parentheses.
4. Put anything that needs action from the reader (a migration, a changed default) first, under
   **Before you upgrade**.
