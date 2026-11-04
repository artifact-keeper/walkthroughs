#!/usr/bin/env node
// Acme tickets: an internal MCP server over stdio (newline-delimited JSON-RPC 2.0),
// with no dependencies, so the walkthrough installs exactly one package from the registry.
// Tools: list_tickets (optionally by status) and get_ticket. Read only.
'use strict';
const readline = require('readline');
const { version } = require('../package.json');

const TICKETS = [
  { id: 101, status: 'open', title: 'Rotate the CI publishing token' },
  { id: 102, status: 'open', title: 'Review held MCP server versions' },
  { id: 103, status: 'closed', title: 'Pin MCP servers by version' },
];
const SUPPORTED = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const READ_ONLY = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const TOOLS = [
  {
    name: 'list_tickets',
    description: 'List tickets in the Acme queue, optionally only open or closed ones.',
    inputSchema: { type: 'object', properties: { status: { type: 'string', enum: ['open', 'closed'] } } },
    annotations: READ_ONLY,
  },
  {
    name: 'get_ticket',
    description: 'Get one ticket by its number.',
    inputSchema: { type: 'object', properties: { id: { type: 'integer' } }, required: ['id'] },
    annotations: READ_ONLY,
  },
];

const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');
const result = (id, value) => send({ jsonrpc: '2.0', id, result: value });
const error = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });
const text = (value) => ({ content: [{ type: 'text', text: JSON.stringify(value) }], isError: false });

function handle(msg) {
  if (!msg || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') {
    if (msg && msg.id !== undefined) error(msg.id, -32600, 'Invalid Request');
    return;
  }
  const p = msg.params || {};
  switch (msg.method) {
    case 'initialize':
      return result(msg.id, {
        protocolVersion: SUPPORTED.includes(p.protocolVersion) ? p.protocolVersion : SUPPORTED[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'acme-tickets', version },
      });
    case 'notifications/initialized':
    case 'notifications/cancelled':
      return;
    case 'ping':
      return result(msg.id, {});
    case 'tools/list':
      return result(msg.id, { tools: TOOLS });
    case 'tools/call': {
      const a = p.arguments || {};
      if (p.name === 'list_tickets') return result(msg.id, text(TICKETS.filter((t) => !a.status || t.status === a.status)));
      if (p.name === 'get_ticket') return result(msg.id, text(TICKETS.find((t) => t.id === a.id) || null));
      return error(msg.id, -32602, 'Unknown tool: ' + String(p.name));
    }
    default:
      if (msg.id !== undefined) error(msg.id, -32601, 'Method not found: ' + msg.method);
  }
}

readline.createInterface({ input: process.stdin, terminal: false }).on('line', (line) => {
  if (!line.trim()) return;
  try { handle(JSON.parse(line)); } catch (e) { send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); }
}).on('close', () => process.exit(0));
