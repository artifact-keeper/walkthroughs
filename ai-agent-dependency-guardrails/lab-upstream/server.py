"""Lab upstream: a tiny PyPI index and npm registry with publish times we control.

It stands in for "the public internet" in the tests that must be deterministic:
  - a package whose newest release was published minutes ago (cooldown, gate G4)
  - a public package that reuses an internal name at a higher version (name squat, gate G5)

Every package is generated here and is harmless: a module or index.js that prints a line.
Publish times are relative to server start, so a restart makes the "fresh" release fresh again.
Standard library only. Usage: python3 server.py [port]   (default 8080)
"""

import base64
import hashlib
import io
import json
import sys
import tarfile
import time
import zipfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

START = time.time()
DAY = 86400

# (name, version, seconds before server start it was "published")
PYPI = [
    ("lab-agent-sdk", "1.0.0", 60 * DAY),
    ("lab-agent-sdk", "1.1.0", 10 * 60),  # fresh: inside any cooldown
    ("acme-agent-tools", "99.0.0", 400 * DAY),  # reuses the internal name
]
NPM = [
    ("lab-mcp-weather", "2.0.0", 60 * DAY),
    ("lab-mcp-weather", "2.1.0", 10 * 60),  # fresh
    ("@acme/tickets-mcp", "99.0.0", 400 * DAY),  # reuses the internal name
]


def iso(age: float) -> str:
    return datetime.fromtimestamp(START - age, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def norm(name: str) -> str:
    return name.lower().replace("_", "-").replace(".", "-")


def wheel(name: str, version: str) -> tuple[str, bytes]:
    mod = name.replace("-", "_")
    dist = f"{mod}-{version}.dist-info"
    files = {
        f"{mod}/__init__.py": f'print("{name} {version} from the lab upstream")\n',
        f"{dist}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\nSummary: lab upstream fixture\n",
        f"{dist}/WHEEL": "Wheel-Version: 1.0\nGenerator: lab-upstream\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    }
    record = []
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for path, text in files.items():
            data = text.encode()
            info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            z.writestr(info, data)
            digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            record.append(f"{path},sha256={digest},{len(data)}")
        record.append(f"{dist}/RECORD,,")
        z.writestr(zipfile.ZipInfo(f"{dist}/RECORD", date_time=(2026, 1, 1, 0, 0, 0)), "\n".join(record) + "\n")
    return f"{mod}-{version}-py3-none-any.whl", buf.getvalue()


def npm_tarball(name: str, version: str) -> bytes:
    files = {
        "package/package.json": json.dumps({"name": name, "version": version, "main": "index.js", "license": "MIT"}),
        "package/index.js": f'console.log("{name} {version} from the lab upstream");\n',
    }
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for path, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(path)
            info.size, info.mtime, info.mode = len(data), 1767225600, 0o644
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


FILES: dict[str, bytes] = {}
SIMPLE: dict[str, list[dict]] = {}
for name, version, age in PYPI:
    fname, data = wheel(name, version)
    FILES[f"/files/{fname}"] = data
    SIMPLE.setdefault(norm(name), []).append(
        {"name": name, "version": version, "filename": fname, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "age": age}
    )

PACKUMENTS: dict[str, dict] = {}
for name, version, age in NPM:
    data = npm_tarball(name, version)
    base = name.split("/")[-1]
    path = f"/{name}/-/{base}-{version}.tgz"
    FILES[path] = data
    p = PACKUMENTS.setdefault(name, {"name": name, "versions": {}, "time": {}, "dist-tags": {}})
    p["versions"][version] = {
        "name": name,
        "version": version,
        "main": "index.js",
        "license": "MIT",
        "dist": {
            "tarball": f"__BASE__{path}",
            "shasum": hashlib.sha1(data).hexdigest(),
            "integrity": "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode(),
        },
    }
    p["time"][version] = iso(age)
for p in PACKUMENTS.values():
    newest = max(p["time"], key=lambda v: p["time"][v])
    p["dist-tags"]["latest"] = newest
    p["time"]["created"] = min(p["time"].values())
    p["time"]["modified"] = p["time"][newest]


class Handler(BaseHTTPRequestHandler):
    server_version = "lab-upstream/1"

    def send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(self.path.split("?")[0])
        base = f"http://{self.headers.get('Host', 'localhost')}"
        if path in FILES:
            ctype = "application/octet-stream" if path.endswith(".whl") else "application/gzip"
            return self.send(200, FILES[path], ctype)
        parts = [p for p in path.split("/") if p]
        # PyPI simple index (PEP 503 HTML, PEP 691 JSON) and JSON API
        if len(parts) == 2 and parts[0] == "simple" and norm(parts[1]) in SIMPLE:
            rels = SIMPLE[norm(parts[1])]
            if "application/vnd.pypi.simple.v1+json" in self.headers.get("Accept", ""):
                body = {
                    "meta": {"api-version": "1.1"},
                    "name": norm(parts[1]),
                    "versions": [r["version"] for r in rels],
                    "files": [
                        {"filename": r["filename"], "url": f"{base}/files/{r['filename']}", "hashes": {"sha256": r["sha256"]},
                         "size": r["size"], "upload-time": iso(r["age"])}
                        for r in rels
                    ],
                }
                return self.send(200, json.dumps(body).encode(), "application/vnd.pypi.simple.v1+json")
            links = "".join(f'<a href="{base}/files/{r["filename"]}#sha256={r["sha256"]}">{r["filename"]}</a>\n' for r in rels)
            return self.send(200, f"<!DOCTYPE html><html><body>\n{links}</body></html>\n".encode(), "text/html")
        if len(parts) == 1 and parts[0] == "simple":
            links = "".join(f'<a href="/simple/{n}/">{n}</a>\n' for n in SIMPLE)
            return self.send(200, f"<!DOCTYPE html><html><body>\n{links}</body></html>\n".encode(), "text/html")
        if len(parts) in (2, 3) and parts[0] == "pypi" and parts[-1] == "json" and norm(parts[1]) in SIMPLE:
            rels = SIMPLE[norm(parts[1])]
            want = parts[2] if len(parts) == 3 and parts[2] != "json" else None
            releases = {
                r["version"]: [{"filename": r["filename"], "url": f"{base}/files/{r['filename']}", "digests": {"sha256": r["sha256"]},
                                "size": r["size"], "upload_time": iso(r["age"])[:19], "upload_time_iso_8601": iso(r["age"]),
                                "packagetype": "bdist_wheel", "yanked": False}]
                for r in rels
            }
            latest = max(rels, key=lambda r: -r["age"])["version"]
            info = {"name": rels[0]["name"], "version": want or latest, "summary": "lab upstream fixture"}
            body = {"info": info, "releases": releases, "urls": releases[want or latest]}
            return self.send(200, json.dumps(body).encode(), "application/json")
        # npm registry: packument at /<name> or /@scope/<name>
        name = path.lstrip("/")
        if name in PACKUMENTS:
            return self.send(200, json.dumps(PACKUMENTS[name]).replace("__BASE__", base).encode(), "application/json")
        return self.send(404, b'{"error":"not found"}', "application/json")

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("lab-upstream %s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"lab-upstream on :{port}: pypi {sorted(SIMPLE)}, npm {sorted(PACKUMENTS)}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
