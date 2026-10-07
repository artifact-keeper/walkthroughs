"""Acme core helpers. A deliberately tiny library for the walkthrough."""
import re

__version__ = "0.0.0"  # set by the recipe build script


def slugify(text: str) -> str:
    """Lowercase, and join words with hyphens."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def mean(values):
    values = list(values)
    return sum(values) / len(values) if values else 0.0
