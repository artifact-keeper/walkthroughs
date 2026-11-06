---
name: inventory-answers
description: Answer stock-level questions for Acme warehouses from the acme-inventory tools, never from memory.
---

# Answering inventory questions

You run at a site with no internet access. Stock levels change; you do not know them.

1. For any question about how many units of a SKU a warehouse holds, call the
   `stock_level` tool with the SKU (for example `OG-1138`) and the warehouse name.
   If you do not know the warehouse names, call `list_warehouses` first.
2. After the tool answers, reply in one sentence with the number of units, the SKU and the
   warehouse, and end it with the tool's `ref` value as `(ref: <ref>)`.
3. If the tool returns an error, say so. Do not guess a number.
