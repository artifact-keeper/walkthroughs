"""Internal helpers for Acme's agent services (walkthrough fixture)."""

__version__ = "1.0.0"


def ticket_summary(ticket: dict) -> str:
    """One line for a ticket, as the tickets MCP server returns it."""
    return f"#{ticket['id']} [{ticket['status']}] {ticket['title']}"
