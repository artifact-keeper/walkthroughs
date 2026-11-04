---
name: acme-secure-defaults
description: Secure defaults every Acme service starts from. Use when adding an endpoint, a dependency, a secret, or a network call.
---

# Acme secure defaults

1. Dependencies come from the internal registry only, pinned in a lockfile.
2. Secrets come from the secret store at runtime, never from the repository or an image layer.
3. Every endpoint is authenticated unless the design review says otherwise, in writing.
4. Outbound calls go through the egress proxy with an allowlist; no direct internet.
5. Log the request ID and the caller, never tokens, passwords or customer data.
