#!/usr/bin/env python3
"""Build acme_inventory_mcp-1.0.0-py3-none-any.whl with the standard library only.

A pure-Python wheel is a zip with the package and a .dist-info directory. Entries are stored
uncompressed (deflate output differs between zlib builds), and every entry gets a
fixed timestamp and mode, in sorted order, so the wheel's SHA-256 is the same on every machine
and can be pinned in agent/requirements-internal.txt.

    build_wheel.py OUT_DIR
"""
import base64, hashlib, pathlib, sys, zipfile

NAME, VERSION = "acme_inventory_mcp", "1.0.0"
DIST = f"{NAME}-{VERSION}.dist-info"
HERE = pathlib.Path(__file__).resolve().parent
METADATA = f"""Metadata-Version: 2.1
Name: acme-inventory-mcp
Version: {VERSION}
Summary: Acme's internal inventory MCP server (stdio)
Requires-Python: >=3.10
Requires-Dist: mcp>=2.0
"""
WHEEL = "Wheel-Version: 1.0\nGenerator: build_wheel.py\nRoot-Is-Purelib: true\nTag: py3-none-any\n"
ENTRY = "[console_scripts]\nacme-inventory-mcp = acme_inventory_mcp.server:main\n"


def digest(b):
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(b).digest()).rstrip(b"=").decode()


def main(out):
    files = {f"{NAME}/{p.name}": p.read_bytes() for p in sorted((HERE / NAME).glob("*.py"))}
    files[f"{DIST}/METADATA"] = METADATA.encode()
    files[f"{DIST}/WHEEL"] = WHEEL.encode()
    files[f"{DIST}/entry_points.txt"] = ENTRY.encode()
    record = "".join(f"{n},{digest(b)},{len(b)}\n" for n, b in files.items()) + f"{DIST}/RECORD,,\n"
    files[f"{DIST}/RECORD"] = record.encode()
    path = pathlib.Path(out) / f"{NAME}-{VERSION}-py3-none-any.whl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        for n, b in files.items():
            zi = zipfile.ZipInfo(n, date_time=(2026, 11, 1, 0, 0, 0))
            zi.external_attr = 0o644 << 16
            zi.compress_type = zipfile.ZIP_STORED
            z.writestr(zi, b)
    print(path, hashlib.sha256(path.read_bytes()).hexdigest())


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
