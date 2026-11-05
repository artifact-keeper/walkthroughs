"""What a model consumer runs, as small commands with JSON output (used by flows/ and gates/).

  hfcheck download  REPO FILE [--revision REV]   hf_hub_download: path, sha256, snapshot commit
  hfcheck snapshot  REPO [--revision REV] [--allow GLOB ...]
                                                 snapshot_download: snapshot dir, commit, files
  hfcheck encode    REPO                         SentenceTransformer(REPO).encode on CPU
  hfcheck automodel REPO                         AutoTokenizer + AutoModel.from_pretrained, one
                                                 forward pass
  hfcheck save      REPO DIR                     load REPO with sentence-transformers and save it
                                                 to DIR (stands in for a training job's output)

The server is HF_ENDPOINT and the credential HF_TOKEN (an Artifact Keeper token), as for any
huggingface_hub program; client/run.sh sets both. One JSON object goes to stdout; on an error it
is {"ok": false, "error": <exception class>, "status": <HTTP status if any>, "msg": ...} and the
exit status is 1. --timeout SECS (before the command) gives up after SECS with error "Timeout".
Every result carries "seconds", the time the command took.
"""
import argparse
import hashlib
import json
import os
import signal
import sys
import time


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def snapshot_commit(path):
    parts = path.split(os.sep)
    return parts[parts.index("snapshots") + 1] if "snapshots" in parts else None


class Expired(BaseException):
    """Raised by the --timeout alarm. A BaseException, so library code that retries on
    Exception (huggingface_hub, transformers) cannot swallow it."""


def main():
    ap = argparse.ArgumentParser(prog="hfcheck")
    ap.add_argument("--timeout", type=int, default=0)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("download"); d.add_argument("repo"); d.add_argument("file"); d.add_argument("--revision")
    s = sub.add_parser("snapshot"); s.add_argument("repo"); s.add_argument("--revision")
    s.add_argument("--allow", action="append")
    e = sub.add_parser("encode"); e.add_argument("repo")
    a = sub.add_parser("automodel"); a.add_argument("repo")
    v = sub.add_parser("save"); v.add_argument("repo"); v.add_argument("dir")
    args = ap.parse_args()
    out = {"ok": True, "cmd": args.cmd, "endpoint": os.environ.get("HF_ENDPOINT")}
    t0 = time.monotonic()

    def expired(*_):
        raise Expired("gave up after %d s" % args.timeout)

    if args.timeout:
        signal.signal(signal.SIGALRM, expired)
        signal.alarm(args.timeout)
    try:
        if args.cmd == "download":
            from huggingface_hub import hf_hub_download
            p = hf_hub_download(args.repo, args.file, revision=args.revision)
            out.update(path=p, sha256=sha256(p), size=os.path.getsize(p), commit=snapshot_commit(p))
        elif args.cmd == "snapshot":
            from huggingface_hub import snapshot_download
            p = snapshot_download(args.repo, revision=args.revision, allow_patterns=args.allow)
            files = sorted(os.path.relpath(os.path.join(r, f), p) for r, _, fs in os.walk(p) for f in fs)
            out.update(path=p, commit=os.path.basename(p.rstrip("/")), files=files)
        elif args.cmd == "encode":
            from sentence_transformers import SentenceTransformer
            m = SentenceTransformer(args.repo, device="cpu")
            v = m.encode(["a private model hub", "an air-gapped network"])
            out.update(shape=list(v.shape), first=[round(float(x), 6) for x in v[0][:4]])
        elif args.cmd == "automodel":
            import torch
            from transformers import AutoModel, AutoTokenizer
            tok = AutoTokenizer.from_pretrained(args.repo)
            model = AutoModel.from_pretrained(args.repo)
            with torch.no_grad():
                h = model(**tok("hello world", return_tensors="pt")).last_hidden_state
            out.update(tokenizer=type(tok).__name__, model=type(model).__name__, hidden=list(h.shape))
        elif args.cmd == "save":
            from sentence_transformers import SentenceTransformer
            SentenceTransformer(args.repo, device="cpu").save(args.dir)
            files = sorted(os.path.relpath(os.path.join(r, f), args.dir) for r, _, fs in os.walk(args.dir) for f in fs)
            out.update(dir=args.dir, files=files)
    except (Exception, Expired) as exc:  # report, do not hide: the gates assert on these fields
        resp = getattr(exc, "response", None)
        out = {"ok": False, "cmd": args.cmd, "error": "Timeout" if isinstance(exc, Expired) else type(exc).__name__,
               "status": getattr(resp, "status_code", None), "msg": (str(exc).splitlines() or [""])[0][:300]}
    out["seconds"] = round(time.monotonic() - t0, 1)
    print(json.dumps(out))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
