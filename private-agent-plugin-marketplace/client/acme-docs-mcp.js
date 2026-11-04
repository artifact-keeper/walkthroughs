#!/usr/bin/env node
// acme-docs-mcp: a tiny stdio MCP server (newline-delimited JSON-RPC 2.0) with one tool,
// `standard`, that returns Acme's rule for a topic. The acme-standards plugin's mcp.json
// starts it. It has no dependencies and makes no network calls.
"use strict";
const RULES = {
  python: "ruff format, ruff check, type hints on public functions, no bare except.",
  typescript: "strict mode, no unexplained any, prettier defaults.",
  shell: "set -euo pipefail, quote every expansion, shellcheck clean.",
  dependencies: "internal registry only, pinned in a lockfile, an owner per new dependency.",
  secrets: "from the secret store at runtime; never in the repository, an image or a log.",
};
const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const reply = (id, result) => send({ jsonrpc: "2.0", id, result });
function handle(req) {
  const { id, method, params } = req;
  if (method === "initialize") {
    return reply(id, {
      protocolVersion: (params && params.protocolVersion) || "2025-06-18",
      capabilities: { tools: {} },
      serverInfo: { name: "acme-docs", version: "1.0.0" },
    });
  }
  if (method === "tools/list") {
    return reply(id, { tools: [{
      name: "standard",
      description: "Acme's engineering rule for a topic: " + Object.keys(RULES).join(", "),
      inputSchema: { type: "object", properties: { topic: { type: "string" } }, required: ["topic"] },
    }] });
  }
  if (method === "tools/call") {
    const topic = String((params && params.arguments && params.arguments.topic) || "").toLowerCase();
    const text = RULES[topic] || "No rule for '" + topic + "'. Topics: " + Object.keys(RULES).join(", ");
    return reply(id, { content: [{ type: "text", text }] });
  }
  if (id !== undefined) send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found" } });
}
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    try { handle(JSON.parse(line)); } catch (e) { /* ignore malformed input */ }
  }
});
