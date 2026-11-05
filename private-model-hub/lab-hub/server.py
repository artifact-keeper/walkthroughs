"""Lab Hub: a small, deterministic stand-in for huggingface.co.

It serves the parts of the Hub HTTP API that huggingface_hub uses to download a model:

  GET       /api/models/<org>/<name>[/revision/<rev>]         model info (siblings, sha)
  GET       /api/models/<org>/<name>/tree/<rev>[/<path>]      file tree (?recursive, ?cursor)
  GET       /api/models/<org>/<name>/xet-read-token/<rev>     a fake Xet token (never needed)
  HEAD/GET  /<org>/<name>/resolve/<rev>/<path>                a file: small files inline,
                                                              large ("LFS") files as a 302 to
                                                              http://cdn.lab:8080/cdn/<sha256>
  HEAD/GET  /cdn/<sha256>                                     the "CDN", with Range support

Like the real Hub it sends X-Repo-Commit, ETag, X-Linked-Etag and X-Linked-Size, lists
xetHash / xetEnabled in its metadata, and gates one model behind a bearer token
(LAB_HUB_TOKEN). Every model is generated here from a fixed seed, so every run serves the
same bytes and the same commit shas:

  acme-lab/tiny-st                       a tiny BERT sentence-transformers model (32 dims)
  acme-lab/gated-llm                     gated: needs "Authorization: Bearer $LAB_HUB_TOKEN"
  sentence-transformer/all-MiniLM-L6-v2  a lookalike of sentence-transformers/... (no "s")
  acme-lab/never-seeded                  a model no step ever pulls (step 7's unseeded model)
  evil-org/backdoor                      a pytorch_model.bin pickle whose __reduce__ calls
                                         os.system("echo ...") (never unpickled here)

Each request is logged to stdout as one JSON line, with a fingerprint of the bearer token it
carried (sha256, first 16 hex characters), never the token itself.

Standard library only. Usage: python3 -I server.py [port]   (default 8080)
"""

import hashlib
import json
import os
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlsplit

CDN = os.environ.get("LAB_CDN_URL", "http://cdn.lab:8080")
TOKEN = os.environ.get("LAB_HUB_TOKEN", "")
LFS_MIN = 10 * 1024  # files at least this big are "LFS" files, served through the CDN
TREE_PAGE = int(os.environ.get("LAB_TREE_PAGE", "1000"))
LAST_MODIFIED = "2026-11-01T00:00:00.000Z"

WORDS = (
    "the a an and or of to in on for with is are was be model models registry artifact keeper "
    "hugging face hub download cache offline private gated proxy local remote virtual token "
    "scan hold release quarantine policy allow deny filter mirror network air gap tiny bert "
    "sentence vector embedding search query document hello world lab test acme internal"
).split()
VOCAB = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]"] + WORDS + list("abcdefghijklmnopqrstuvwxyz") \
    + ["##" + c for c in "abcdefghijklmnopqrstuvwxyz"] + ["##s", "##ed", "##ing"]


# --- deterministic tiny BERT --------------------------------------------------------------

def _floats(seed: int, n: int, scale: float = 0.02):
    x = seed & 0xFFFFFFFF
    out = []
    for _ in range(n):
        x = (1664525 * x + 1013904223) & 0xFFFFFFFF
        out.append(((x / 0xFFFFFFFF) * 2.0 - 1.0) * scale)
    return out


def safetensors(tensors) -> bytes:
    """tensors: list of (name, shape, values). Writes the safetensors format (F32)."""
    header, blobs, off = {"__metadata__": {"format": "pt"}}, [], 0
    for name, shape, values in tensors:
        data = struct.pack("<%df" % len(values), *values)
        header[name] = {"dtype": "F32", "shape": list(shape), "data_offsets": [off, off + len(data)]}
        blobs.append(data)
        off += len(data)
    h = json.dumps(header, separators=(",", ":")).encode()
    h += b" " * (-len(h) % 8)
    return struct.pack("<Q", len(h)) + h + b"".join(blobs)


def tiny_bert(seed: int, hidden=32, inter=64, positions=64):
    v, h, i = len(VOCAB), hidden, inter
    t = []
    k = [seed]

    def rnd(name, *shape):
        n = 1
        for s in shape:
            n *= s
        k[0] += 1
        t.append((name, shape, _floats(k[0] * 7919, n)))

    def ln(name):
        t.append((name + ".weight", (h,), [1.0] * h))
        t.append((name + ".bias", (h,), [0.0] * h))

    rnd("embeddings.word_embeddings.weight", v, h)
    rnd("embeddings.position_embeddings.weight", positions, h)
    rnd("embeddings.token_type_embeddings.weight", 2, h)
    ln("embeddings.LayerNorm")
    p = "encoder.layer.0."
    for m in ("query", "key", "value"):
        rnd(p + "attention.self.%s.weight" % m, h, h)
        rnd(p + "attention.self.%s.bias" % m, h)
    rnd(p + "attention.output.dense.weight", h, h)
    rnd(p + "attention.output.dense.bias", h)
    ln(p + "attention.output.LayerNorm")
    rnd(p + "intermediate.dense.weight", i, h)
    rnd(p + "intermediate.dense.bias", i)
    rnd(p + "output.dense.weight", h, i)
    rnd(p + "output.dense.bias", h)
    ln(p + "output.LayerNorm")
    rnd("pooler.dense.weight", h, h)
    rnd("pooler.dense.bias", h)
    config = {
        "architectures": ["BertModel"], "model_type": "bert", "vocab_size": v, "hidden_size": h,
        "num_hidden_layers": 1, "num_attention_heads": 2, "intermediate_size": i,
        "hidden_act": "gelu", "hidden_dropout_prob": 0.0, "attention_probs_dropout_prob": 0.0,
        "max_position_embeddings": positions, "type_vocab_size": 2, "initializer_range": 0.02,
        "layer_norm_eps": 1e-12, "pad_token_id": 0, "torch_dtype": "float32",
    }
    return config, safetensors(t)


def js(obj) -> bytes:
    return (json.dumps(obj, indent=2, sort_keys=True) + "\n").encode()


def tokenizer_files():
    return {
        "vocab.txt": ("\n".join(VOCAB) + "\n").encode(),
        "tokenizer_config.json": js({"tokenizer_class": "BertTokenizer", "do_lower_case": True,
                                     "model_max_length": 64, "unk_token": "[UNK]", "sep_token": "[SEP]",
                                     "pad_token": "[PAD]", "cls_token": "[CLS]", "mask_token": "[MASK]"}),
        "special_tokens_map.json": js({"unk_token": "[UNK]", "sep_token": "[SEP]", "pad_token": "[PAD]",
                                       "cls_token": "[CLS]", "mask_token": "[MASK]"}),
    }


def sentence_model(seed: int, card: str):
    config, weights = tiny_bert(seed)
    files = {
        ".gitattributes": b"*.safetensors filter=lfs diff=lfs merge=lfs -text\n*.bin filter=lfs diff=lfs merge=lfs -text\n",
        "README.md": card.encode(),
        "config.json": js(config),
        "model.safetensors": weights,
        "modules.json": js([
            {"idx": 0, "name": "0", "path": "", "type": "sentence_transformers.models.Transformer"},
            {"idx": 1, "name": "1", "path": "1_Pooling", "type": "sentence_transformers.models.Pooling"},
        ]),
        "sentence_bert_config.json": js({"max_seq_length": 64, "do_lower_case": False}),
        "1_Pooling/config.json": js({"word_embedding_dimension": config["hidden_size"],
                                     "pooling_mode_cls_token": False, "pooling_mode_mean_tokens": True,
                                     "pooling_mode_max_tokens": False,
                                     "pooling_mode_mean_sqrt_len_tokens": False}),
    }
    files.update(tokenizer_files())
    return files


def card(title: str, tags=("sentence-transformers", "feature-extraction")) -> str:
    return "---\nlibrary_name: sentence-transformers\npipeline_tag: sentence-similarity\ntags:\n" + \
        "".join("- %s\n" % t for t in tags) + "---\n\n# %s\n\nA lab fixture: random weights, 32 dimensions.\n" % title


# A pickle (protocol 2) whose load would call posix.system("echo ..."): the classic
# malicious-checkpoint shape. Built as bytes; nothing here ever unpickles it.
_cmd = b"echo lab-pickle-payload"
PICKLE = b"\x80\x02cposix\nsystem\nq\x00X" + struct.pack("<I", len(_cmd)) + _cmd + b"q\x01\x85q\x02Rq\x03."

MODELS = {
    "acme-lab/tiny-st": {"files": sentence_model(1, card("acme-lab/tiny-st")), "gated": False},
    "acme-lab/gated-llm": {"files": sentence_model(2, card("acme-lab/gated-llm (gated)")), "gated": True},
    "sentence-transformer/all-MiniLM-L6-v2": {
        "files": sentence_model(3, card("sentence-transformer/all-MiniLM-L6-v2 (a lookalike)")), "gated": False},
    "acme-lab/never-seeded": {"files": sentence_model(4, card("acme-lab/never-seeded")), "gated": False},
    "evil-org/backdoor": {"files": {"config.json": js({"model_type": "bert"}), "pytorch_model.bin": PICKLE,
                                    "README.md": b"# evil-org/backdoor\n"}, "gated": False},
}


def git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


for mid, m in MODELS.items():
    entries = {}
    for path, data in m["files"].items():
        e = {"path": path, "size": len(data), "oid": git_blob_sha(data),
             "sha256": hashlib.sha256(data).hexdigest(), "data": data}
        e["lfs"] = len(data) >= LFS_MIN or path.endswith((".safetensors", ".bin"))
        # A stand-in for the Hub's Xet content hash (what clients must never be told about).
        e["xet"] = hashlib.sha256(b"xet:" + data).hexdigest()
        entries[path] = e
    m["entries"] = entries
    m["sha"] = hashlib.sha1(json.dumps(sorted((p, e["oid"]) for p, e in entries.items())).encode()
                            + mid.encode()).hexdigest()
BLOBS = {e["sha256"]: e["data"] for m in MODELS.values() for e in m["entries"].values()}


def fingerprint(auth: str):
    if not auth:
        return None
    tok = auth.split(" ", 1)[1] if " " in auth else auth
    return hashlib.sha256(tok.encode()).hexdigest()[:16]


class Hub(BaseHTTPRequestHandler):
    server_version = "lab-hub/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # replaced by one JSON line per request in _done
        pass

    def _done(self, status, extra=None):
        rec = {"t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "m": self.command,
               "path": self.path, "status": status, "auth": fingerprint(self.headers.get("Authorization", ""))}
        if self.headers.get("Range"):
            rec["range"] = self.headers["Range"]
        if extra:
            rec.update(extra)
        print(json.dumps(rec), flush=True)

    def _send(self, status, body=b"", headers=None, ctype="application/json"):
        self.send_response(status)
        hdrs = {"Content-Type": ctype, "Content-Length": str(len(body))}
        hdrs.update(headers or {})
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self._done(status)

    def _error(self, status, code, msg):
        self._send(status, js({"error": msg}), {"X-Error-Code": code, "X-Error-Message": msg})

    def _model(self, mid):
        m = MODELS.get(mid)
        if m is None:
            self._error(404, "RepoNotFound", "Repository not found")
            return None
        if m["gated"]:
            auth = self.headers.get("Authorization", "")
            if not auth:
                self._error(401, "GatedRepo", "Access to model %s is restricted. You must have access to it "
                            "and be authenticated to access it." % mid)
                return None
            if not TOKEN or auth != "Bearer " + TOKEN:
                self._error(403, "GatedRepo", "Access to model %s is restricted and you are not in the "
                            "authorized list." % mid)
                return None
        return m

    def _rev_ok(self, m, rev):
        if rev in ("main", m["sha"]):
            return True
        self._error(404, "RevisionNotFound", "Invalid rev id: %s" % rev)
        return False

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlsplit(self.path)
        q = parse_qs(url.query)
        parts = [unquote(p) for p in url.path.split("/") if p]
        if parts == ["_lab", "health"]:
            return self._send(200, js({"ok": True, "models": sorted(MODELS)}))
        if parts == ["_lab", "models"]:
            return self._send(200, js({k: m["sha"] for k, m in MODELS.items()}))
        if len(parts) == 2 and parts[0] == "cdn":
            return self._cdn(parts[1])
        if len(parts) >= 3 and parts[0] == "api" and parts[1] == "models":
            mid = "/".join(parts[2:4])
            rest = parts[4:]
            m = self._model(mid)
            if m is None:
                return
            if not rest or (rest[0] == "revision" and len(rest) == 2):
                rev = rest[1] if rest else "main"
                if not self._rev_ok(m, rev):
                    return
                return self._send(200, js(self._info(mid, m)))
            if rest[0] == "tree" and len(rest) >= 2:
                if not self._rev_ok(m, rest[1]):
                    return
                return self._tree(mid, m, "/".join(rest[2:]), q)
            if rest[0] == "xet-read-token" and len(rest) == 2:
                return self._send(200, js({"accessToken": "lab-xet-token", "casUrl": CDN + "/xet",
                                           "exp": int(time.time()) + 3600}))
            return self._error(404, "EntryNotFound", "Not found")
        if len(parts) >= 5 and parts[2] == "resolve":
            mid = "/".join(parts[:2])
            m = self._model(mid)
            if m is None:
                return
            if not self._rev_ok(m, parts[3]):
                return
            return self._resolve(mid, m, "/".join(parts[4:]))
        self._error(404, "EntryNotFound", "Not found")

    def _info(self, mid, m):
        return {
            "_id": hashlib.md5(mid.encode()).hexdigest()[:24], "id": mid, "modelId": mid,
            "author": mid.split("/")[0], "sha": m["sha"], "lastModified": LAST_MODIFIED,
            "createdAt": LAST_MODIFIED, "private": False, "gated": "manual" if m["gated"] else False,
            "disabled": False, "downloads": 0, "likes": 0, "library_name": "sentence-transformers",
            "pipeline_tag": "sentence-similarity", "tags": ["sentence-transformers", "safetensors", "bert"],
            "xetEnabled": True,
            "siblings": [{"rfilename": p, "xetHash": e["xet"]} if e["lfs"] else {"rfilename": p}
                         for p, e in sorted(m["entries"].items())],
        }

    def _tree(self, mid, m, path, q):
        recursive = q.get("recursive", ["false"])[0].lower() in ("1", "true")
        prefix = path.strip("/") + "/" if path.strip("/") else ""
        files, dirs = [], set()
        for p, e in sorted(m["entries"].items()):
            if not p.startswith(prefix):
                continue
            rel = p[len(prefix):]
            if "/" in rel and not recursive:
                dirs.add(prefix + rel.split("/")[0])
                continue
            if "/" in rel:
                segs = rel.split("/")[:-1]
                for k in range(1, len(segs) + 1):
                    dirs.add(prefix + "/".join(segs[:k]))
            item = {"type": "file", "oid": e["oid"], "size": e["size"], "path": p}
            if e["lfs"]:
                item["lfs"] = {"oid": e["sha256"], "size": e["size"], "pointerSize": 134}
                item["xetHash"] = e["xet"]
            files.append(item)
        if prefix and not files and not dirs:
            return self._error(404, "EntryNotFound", "%s does not exist" % path)
        items = [{"type": "directory", "oid": hashlib.sha1(d.encode()).hexdigest(), "size": 0, "path": d}
                 for d in sorted(dirs)] + files
        start = int(q.get("cursor", ["0"])[0] or 0)
        page = items[start:start + TREE_PAGE]
        headers = {}
        if start + TREE_PAGE < len(items):
            nq = dict((k, v[0]) for k, v in q.items())
            nq["cursor"] = str(start + TREE_PAGE)
            nxt = "http://%s%s?%s" % (self.headers.get("Host", "lab"), url_path(self.path),
                                      "&".join("%s=%s" % (k, quote(v)) for k, v in nq.items()))
            headers["Link"] = '<%s>; rel="next"' % nxt
        self._send(200, js(page), headers)

    def _resolve(self, mid, m, path):
        e = m["entries"].get(path)
        if e is None:
            return self._error(404, "EntryNotFound", "%s does not exist" % path)
        common = {"X-Repo-Commit": m["sha"], "Accept-Ranges": "bytes"}
        if e["lfs"]:
            loc = "%s/cdn/%s" % (CDN, e["sha256"])
            common.update({"Location": loc, "ETag": '"%s"' % e["oid"], "X-Linked-Etag": '"%s"' % e["sha256"],
                           "X-Linked-Size": str(e["size"]), "X-Xet-Hash": e["xet"],
                           "Link": '<%s/api/models/%s/xet-read-token/%s>; rel="xet-auth"' % (
                               "http://" + self.headers.get("Host", "lab"), mid, m["sha"])})
            return self._send(302, b"", common, "text/plain")
        common["ETag"] = '"%s"' % e["oid"]
        self._send_bytes(e["data"], common)

    def _cdn(self, sha):
        data = BLOBS.get(sha)
        if data is None:
            return self._error(404, "EntryNotFound", "no such object")
        self._send_bytes(data, {"ETag": '"%s"' % sha, "Accept-Ranges": "bytes"})

    def _send_bytes(self, data, headers):
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes=") and self.command == "GET":
            a, _, b = rng[6:].split(",")[0].partition("-")
            try:
                if a == "":
                    start, end = max(0, len(data) - int(b)), len(data) - 1
                else:
                    start, end = int(a), (int(b) if b else len(data) - 1)
            except ValueError:
                start, end = 0, -1
            end = min(end, len(data) - 1)
            if start > end:
                return self._send(416, b"", {"Content-Range": "bytes */%d" % len(data)}, "text/plain")
            headers = dict(headers, **{"Content-Range": "bytes %d-%d/%d" % (start, end, len(data))})
            return self._send(206, data[start:end + 1], headers, "application/octet-stream")
        self._send(200, data, headers, "application/octet-stream")


def url_path(p):
    return urlsplit(p).path


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    srv = ThreadingHTTPServer(("0.0.0.0", port), Hub)
    print(json.dumps({"lab-hub on": port, "models": {k: m["sha"] for k, m in MODELS.items()},
                      "gated_token_set": bool(TOKEN)}), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
