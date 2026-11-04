---
description: Print the Acme pre-merge checklist for the current change
---

Print this checklist, then go through it for the current working tree and mark each item
`[x]` or `[ ]` with one line of evidence:

- [ ] The ticket is linked in the description
- [ ] No secrets, tokens or customer data in the diff or the logs it adds
- [ ] New dependencies have an owner and come from the internal registry
- [ ] Tests fail without the change and pass with it
- [ ] Migrations are reversible
