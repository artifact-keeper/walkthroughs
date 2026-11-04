"""Demo agent service: start the internal tickets MCP server and list its tools.

No model is called; the point is that every dependency (Python and npm) installed and runs.
"""

import asyncio
import importlib.metadata as md

from acme_agent_tools import ticket_summary
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SERVER = StdioServerParameters(command="node_modules/.bin/tickets-mcp", args=[])


async def main() -> None:
    print("anthropic", md.version("anthropic"), "| mcp", md.version("mcp"), "| acme-agent-tools", md.version("acme-agent-tools"))
    async with stdio_client(SERVER) as (read, write), ClientSession(read, write) as session:
        await session.initialize()
        tools = await session.list_tools()
        print("MCP tools:", ", ".join(t.name for t in tools.tools))
        result = await session.call_tool("list_tickets", {"status": "open"})
        import json

        for ticket in json.loads(result.content[0].text):
            print(" ", ticket_summary(ticket))


if __name__ == "__main__":
    asyncio.run(main())
