#!/usr/bin/env node
// A minimal MCP client for the walkthrough: start a stdio server, initialize, list its tools
// and call one, then print one JSON object with what it saw.
//   mcp-call TOOL ARGS-JSON -- command [args...]
// Example: mcp-call list_tickets '{"status":"open"}' -- npx -y @acme/tickets-mcp@1.0.0
// TOOL "-" calls nothing and prints the full tools/list result as `toolList`.
'use strict';
const { spawn } = require('child_process');
const sep = process.argv.indexOf('--');
if (sep < 4) { console.error('usage: mcp-call TOOL ARGS-JSON -- command [args...]'); process.exit(2); }
const [tool, argsJson] = process.argv.slice(2, sep);
const [cmd, ...cmdArgs] = process.argv.slice(sep + 1);
const child = spawn(cmd, cmdArgs, { stdio: ['pipe', 'pipe', 'inherit'] });
const pending = new Map();
let buf = '', id = 0;
child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  }
});
const request = (method, params) => new Promise((resolve) => {
  const n = ++id; pending.set(n, resolve);
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: n, method, params }) + '\n');
});
const timer = setTimeout(() => { console.error('mcp-call: no answer within 120 s'); process.exit(1); }, 120000);
(async () => {
  const init = await request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'mcp-call', version: '1' } });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const tools = await request('tools/list', {});
  const list = (tools.result && tools.result.tools) || [];
  if (tool === '-') {
    console.log(JSON.stringify({ serverInfo: init.result && init.result.serverInfo, toolList: list }));
  } else {
    const call = await request('tools/call', { name: tool, arguments: JSON.parse(argsJson) });
    console.log(JSON.stringify({ serverInfo: init.result && init.result.serverInfo, tools: list.map((t) => t.name), call: call.result || call.error }));
  }
  clearTimeout(timer); child.kill(); process.exit(0);
})();
