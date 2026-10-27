#!/usr/bin/env node
// Internal MCP server: exposes a read-only ticket queue over stdio. Walkthrough fixture.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const TICKETS = [
  { id: 101, status: "open", title: "Rotate the CI publishing token" },
  { id: 102, status: "open", title: "Review held package versions" },
  { id: 103, status: "closed", title: "Pin MCP servers by version" },
];

const server = new McpServer({ name: "acme-tickets", version: "1.0.0" });

server.tool("list_tickets", "List tickets, optionally by status", { status: z.enum(["open", "closed"]).optional() }, async ({ status }) => ({
  content: [{ type: "text", text: JSON.stringify(TICKETS.filter((t) => !status || t.status === status)) }],
}));

await server.connect(new StdioServerTransport());
