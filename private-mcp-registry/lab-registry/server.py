"""A small, read-only MCP registry (API v0.1, also /v0) that stands in for
registry.modelcontextprotocol.io in the walkthrough, so the curation steps are
the same on every run.

It serves the entries in a directory (one file per server version, in the
upstream list envelope's entry shape: {"server": {...}, "_meta":
{"io.modelcontextprotocol.registry/official": {"status", "publishedAt",
"updatedAt"}}}), re-read on every request, so a script changes the upstream by
editing a file. Standard library only. Usage: python -I server.py DIR PORT

  GET /v0.1/servers               cursor, limit (1..100, default 30), search,
                                  version=latest, updated_since (implies
                                  include_deleted), include_deleted
  GET /v0.1/servers/{name}/versions
  GET /v0.1/servers/{name}/versions/{version|latest}
  GET /v0.1/health

Everything else is 404 (unknown path) or 405 (not a GET). One log line per
request on stdout.
"""

import base64
import http.server
import json
import re
import sys
import urllib.parse
from datetime import datetime
from pathlib import Path

OFFICIAL = "io.modelcontextprotocol.registry/official"
SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?")
DIR = Path(sys.argv[1])
PORT = int(sys.argv[2])


def ts(text):
    try:
        return datetime.fromisoformat((text or "").replace("Z", "+00:00"))
    except ValueError:
        return None


def vkey(version):
    m = SEMVER.match(version or "")
    if not m:
        return (0, 0, 0, 0)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), 0 if m.group(4) else 1)


def entries():
    out = []
    for path in sorted(DIR.glob("*.json")):
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        meta = dict((doc.get("_meta") or {}).get(OFFICIAL) or {})
        meta.setdefault("status", "active")
        out.append({"server": doc["server"], "official": meta})
    latest = {}
    for e in out:
        if e["official"]["status"] == "deleted":
            continue
        n = e["server"]["name"]
        if n not in latest or vkey(e["server"]["version"]) > vkey(latest[n]):
            latest[n] = e["server"]["version"]
    for e in out:
        e["official"]["isLatest"] = latest.get(e["server"]["name"]) == e["server"]["version"]
    out.sort(key=lambda e: (e["server"]["name"], e["server"]["version"]))
    return out


def envelope(e):
    return {"server": e["server"], "_meta": {OFFICIAL: e["official"]}}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stdout.write("lab-registry %s\n" % (fmt % args))
        sys.stdout.flush()

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.answer(405, {"title": "Method Not Allowed", "status": 405})

    do_PUT = do_PATCH = do_DELETE = do_POST

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(url.query))
        path = re.sub(r"^/v0(\.1)?", "", url.path)
        if not re.match(r"^/v0(\.1)?/", url.path + "/"):
            return self.answer(404, {"title": "Not Found", "status": 404})
        if path == "/health":
            return self.answer(200, {"status": "ok"})
        if path == "/servers":
            return self.list_servers(q)
        m = re.match(r"^/servers/(.+)/versions(?:/([^/]+))?$", path)
        if m:
            return self.versions(urllib.parse.unquote(m.group(1)), m.group(2), q)
        return self.answer(404, {"title": "Not Found", "status": 404})

    def list_servers(self, q):
        try:
            limit = int(q.get("limit", "30"))
        except ValueError:
            return self.answer(400, {"title": "Bad Request", "status": 400})
        if limit < 1:
            return self.answer(400, {"title": "Bad Request", "status": 400})
        limit = min(limit, 100)
        since = ts(q.get("updated_since"))
        deleted = q.get("include_deleted") == "true" or since is not None
        rows = entries()
        if not deleted:
            rows = [e for e in rows if e["official"]["status"] != "deleted"]
        if since is not None:
            rows = [e for e in rows if (ts(e["official"].get("updatedAt")) or since) > since]
        if q.get("version") == "latest":
            rows = [e for e in rows if e["official"]["isLatest"]]
        if q.get("search"):
            rows = [e for e in rows if q["search"].lower() in e["server"]["name"].lower()]
        start = 0
        if q.get("cursor"):
            try:
                start = int(base64.urlsafe_b64decode(q["cursor"] + "==").decode())
            except ValueError:
                return self.answer(400, {"title": "Bad Request", "status": 400})
        page = rows[start:start + limit]
        meta = {"count": len(page)}
        if start + limit < len(rows):
            meta["nextCursor"] = base64.urlsafe_b64encode(str(start + limit).encode()).decode().rstrip("=")
        return self.answer(200, {"servers": [envelope(e) for e in page], "metadata": meta})

    def versions(self, name, version, q):
        deleted = q.get("include_deleted") == "true"
        rows = [e for e in entries() if e["server"]["name"] == name
                and (deleted or e["official"]["status"] != "deleted")]
        if version is None:
            if not rows:
                return self.answer(404, {"title": "Not Found", "status": 404})
            return self.answer(200, {"servers": [envelope(e) for e in rows], "metadata": {"count": len(rows)}})
        version = urllib.parse.unquote(version)
        for e in rows:
            if (version == "latest" and e["official"]["isLatest"]) or e["server"]["version"] == version:
                return self.answer(200, envelope(e))
        return self.answer(404, {"title": "Not Found", "status": 404})


if __name__ == "__main__":
    print("lab-registry on :%d serving %s" % (PORT, DIR), flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
