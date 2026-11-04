---
name: acme-style
description: Acme's code style rules for Python, TypeScript and shell. Use when writing or changing code in an Acme repository.
---

# Acme style

- **Python**: format with `ruff format`, lint with `ruff check`, type hints on every public
  function. No bare `except:`.
- **TypeScript**: `strict` on, no `any` without a comment saying why, `prettier` defaults.
- **Shell**: `set -euo pipefail` at the top, quote every expansion, `shellcheck` clean.
- **Names**: say what a thing is, not how it is built. `invoice_total`, not `calc_result2`.
- **Comments** explain why, not what. Delete commented-out code.

When unsure, ask the `acme-docs` MCP server (`standard` tool) for the rule by topic.
