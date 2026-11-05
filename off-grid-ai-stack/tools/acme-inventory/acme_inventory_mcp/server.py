"""acme-inventory-mcp: read-only stock levels from Acme's (made-up) warehouse system.

A stdio MCP server with two tools. The data is fixed so that the walkthrough's gate can check
that an answer came from the tool and not from the model: every reply carries a `ref`, a
value the model cannot guess.
"""
from mcp.server.mcpserver import MCPServer

WAREHOUSES = {
    "north": {"OG-1138": 42, "OG-2187": 7, "OG-0451": 0},
    "south": {"OG-1138": 13, "OG-2187": 120, "OG-0451": 5},
}
REF = "inv-7f3a9c"

mcp = MCPServer("acme-inventory")


@mcp.tool()
def list_warehouses() -> list[str]:
    """List the warehouses whose stock levels this server can report."""
    return sorted(WAREHOUSES)


@mcp.tool()
def stock_level(sku: str, warehouse: str) -> dict:
    """Return how many units of a SKU (for example OG-1138) a warehouse holds."""
    w = WAREHOUSES.get(warehouse.strip().lower())
    if w is None:
        return {"error": f"unknown warehouse {warehouse!r}", "warehouses": sorted(WAREHOUSES)}
    sku = sku.strip().upper()
    if sku not in w:
        return {"error": f"unknown sku {sku!r}", "warehouse": warehouse}
    return {"sku": sku, "warehouse": warehouse.lower(), "units": w[sku], "ref": REF}


def main() -> None:
    mcp.run()  # stdio


if __name__ == "__main__":
    main()
