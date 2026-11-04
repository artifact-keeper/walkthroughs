#!/usr/bin/env python3
"""Nightly end-to-end runner for the Artifact Keeper walkthroughs.

    ak_e2e.py run        one night: check out, run every walkthrough x version, diff, report
    ak_e2e.py report     redo the diff and the issue report for the latest night (no runs)

For each walkthrough and each Artifact Keeper version (the latest release and :dev), in
sequence: make clean, make all, make gates, make clean, each with a hard timeout. Verdicts
are PASS, FAIL or BLOCKED(reason); infrastructure problems are BLOCKED, never FAIL.

Everything is configured through the environment (see e2e/README.md and config.example.env).
Standard library only; Python 3.11+.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOME = Path.home()
E = os.environ.get

REPO = E("E2E_REPO", "artifact-keeper/walkthroughs")
REPO_URL = E("E2E_REPO_URL", f"https://github.com/{REPO}.git")
E2E_HOME = Path(E("E2E_HOME", str(HOME / "ak-e2e")))
RUNS = E2E_HOME / "runs"
TOOLS = E2E_HOME / "bin"   # host tools the runner's operator installed for the walkthroughs (e.g. cosign)
SECRETS_DIR = Path(E("E2E_SECRETS_DIR", str(HOME / ".config/ak-e2e")))
REPORT_MODE = E("E2E_REPORT", "dry-run")            # dry-run | github
VERSIONS = E("E2E_VERSIONS", "release dev").split()  # tracks, in run order
EXTRA_REFS = E("E2E_EXTRA_REFS", "").split()         # branches to test besides main and e2e-labelled PRs
PR_LABEL = E("E2E_PR_LABEL", "e2e")
ONLY = set(E("E2E_ONLY", "").split())                # limit to these walkthrough slugs (testing)
ONLY_RUNS = set(E("E2E_ONLY_RUNS", "").split())      # limit to slug@track pairs (testing)
PATCH_DIR = E("E2E_PATCH_DIR")                       # <dir>/<ref-slug>.patch applied after checkout (testing)
KEEP_WORK = E("E2E_KEEP_WORK") == "1"
KEEP_NIGHTS = int(E("E2E_KEEP_NIGHTS", "30"))
SLOW_FACTOR = float(E("E2E_SLOW_FACTOR", "2"))
SLOW_FLOOR_S = int(E("E2E_SLOW_FLOOR_S", "60"))      # ignore slowdowns on steps shorter than this
GHCR = "ghcr.io/artifact-keeper"
IMAGES = {"backend": "artifact-keeper-backend", "web": "artifact-keeper-web"}
RELEASE_SOURCES = {"backend": "artifact-keeper/artifact-keeper", "web": "artifact-keeper/artifact-keeper-web"}
NPM_REGISTRY = "https://registry.npmjs.org/"
TITLE_PREFIX = "[e2e]"

# Log patterns that mean "the host or the network failed", not the walkthrough. Checked only
# on the tail of a failed step's log.
INFRA_PATTERNS = [
    (r"no space left on device|disk quota exceeded", "disk"),
    (r"toomanyrequests|rate limit(ed)? exceeded|429 Too Many Requests", "registry-pull"),
    (r"manifest unknown|error pulling image|initializing source .*: (pinging|reading manifest)|"
     r"Error: (copying|writing) blob|unable to pull", "registry-pull"),
    (r"Could not resolve host|Temporary failure in name resolution|TLS handshake timeout|"
     r"network is unreachable|dial tcp .*: i/o timeout", "network"),
    (r"address already in use|is already in use by (container|another)|name is already in use|"
     r"subnet .* overlaps|networks? .* overlap", "conflict"),
    # a host tool the walkthrough expects is not installed (bash exit 127)
    (r": command not found|: No such file or directory\s*\n.*Error 127|\] Error 127", "host"),
]

STD_LINE = re.compile(r"^\s*(PASS|FAIL|BLOCKED(?:\([^)]*\))?)\s+(G\d+[a-z]?)\s+(.+?)\s*$")
ALT_LINE = re.compile(r"^\s*(G\d+[a-z]?)\s+(PASS|FAIL|BLOCKED(?:\([^)]*\))?|NOT RUN)\s+(.+?)\s*$")


# --------------------------------------------------------------------------- helpers
def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str) -> None:
    print(f"[{dt.datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    return subprocess.run(cmd, **kw)


def out(cmd: list[str], **kw) -> str:
    r = sh(cmd, **kw)
    return r.stdout.strip() if r.returncode == 0 else ""


def vtuple(v: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3]) or (0,)


def slugify(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", s).strip("-")


def load_secrets() -> tuple[dict, list[str]]:
    """~/.config/ak-e2e/<name> (mode 600) -> {ENV_NAME: value}. File name: lower-case env
    name with dashes (CLAUDE_CODE_OAUTH_TOKEN -> claude-code-oauth-token)."""
    secrets, warnings = {}, []
    if not SECRETS_DIR.is_dir():
        return secrets, warnings
    if SECRETS_DIR.stat().st_mode & 0o077:
        warnings.append(f"{SECRETS_DIR} is readable by others; secrets ignored (chmod 700)")
        return secrets, warnings
    for f in sorted(SECRETS_DIR.iterdir()):
        if not f.is_file() or f.suffix in (".env", ".example") or f.name.startswith("."):
            continue
        if f.stat().st_mode & 0o077:
            warnings.append(f"{f} is not mode 600; ignored")
            continue
        val = f.read_text().strip()
        if val:
            secrets[f.name.upper().replace("-", "_")] = val
    return secrets, warnings


def http_json(url: str, token: str | None = None, method: str = "GET", body: dict | None = None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "ak-e2e")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if body:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"null")


def registry_digest(repo: str, tag: str) -> str | None:
    """Index (or manifest) digest of ghcr.io/artifact-keeper/<repo>:<tag>, anonymously."""
    try:
        tok = http_json(f"https://ghcr.io/token?scope=repository:artifact-keeper/{repo}:pull")["token"]
        req = urllib.request.Request(f"https://ghcr.io/v2/artifact-keeper/{repo}/manifests/{tag}", method="HEAD")
        req.add_header("Authorization", f"Bearer {tok}")
        req.add_header("Accept", ",".join([
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.v2+json"]))
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.headers.get("Docker-Content-Digest")
    except Exception:
        return None


def free_gb(path: Path) -> int:
    path.mkdir(parents=True, exist_ok=True)
    return shutil.disk_usage(path).free // 2**30


def podman_graphroot() -> Path:
    return Path(out(["podman", "info", "--format", "{{.Store.GraphRoot}}"]) or HOME)


# --------------------------------------------------------------------------- host state
def host_state() -> dict:
    """Containers, volumes, networks (with subnets) and listening ports on this host."""
    containers = []
    for line in out(["podman", "ps", "-a", "--format", "{{.Names}}\t{{.CreatedAt}}"]).splitlines():
        name, _, created = line.partition("\t")
        containers.append({"name": name, "created": created})
    volumes = []
    raw = out(["podman", "volume", "ls", "--format", "json"])
    for v in json.loads(raw or "[]"):
        volumes.append({"name": v.get("Name"), "created": v.get("CreatedAt", "")})
    networks = []
    raw = out(["podman", "network", "ls", "--format", "json"])
    for n in json.loads(raw or "[]"):
        subnets = [s.get("subnet") for s in (n.get("subnets") or []) if s.get("subnet")]
        networks.append({"name": n.get("name"), "subnets": subnets, "created": n.get("created", "")})
    ports = set()
    for line in out(["ss", "-Hltn"]).splitlines():
        cols = line.split()
        if len(cols) >= 4:
            m = re.search(r":(\d+)$", cols[3])
            if m:
                ports.add(int(m.group(1)))
    return {"containers": containers, "volumes": volumes, "networks": networks, "ports": ports}


def stack_resources(cfg: dict, hs: dict) -> dict:
    """The resources on this host that match a walkthrough's names."""
    cre = [re.compile(p) for p in cfg.get("containers", [])]
    vre = [re.compile(p) for p in cfg.get("volumes", [])]
    nets = set(cfg.get("networks", []))
    return {
        "containers": [c for c in hs["containers"] if any(r.search(c["name"]) for r in cre)],
        "volumes": [v for v in hs["volumes"] if any(r.search(v["name"]) for r in vre)],
        "networks": [n for n in hs["networks"] if n["name"] in nets],
    }


def conflicts(cfg: dict) -> list[str]:
    hs = host_state()
    found = []
    res = stack_resources(cfg, hs)
    for kind in ("containers", "volumes", "networks"):
        names = [x["name"] for x in res[kind]]
        if names:
            found.append(f"{kind}: {' '.join(names[:6])}{' ...' if len(names) > 6 else ''}")
    busy = sorted(p for p in cfg.get("ports", []) if p in hs["ports"])
    if busy:
        found.append("ports in use: " + " ".join(map(str, busy)))
    own = set(cfg.get("networks", []))
    for want in cfg.get("subnets", []):
        w = ipaddress.ip_network(want)
        for n in hs["networks"]:
            if n["name"] in own:
                continue
            for s in n["subnets"]:
                try:
                    if w.overlaps(ipaddress.ip_network(s)):
                        found.append(f"subnet {want} overlaps network {n['name']} ({s})")
                except ValueError:
                    pass
    return found


def parse_created(s: str) -> dt.datetime | None:
    """podman timestamps: '2026-11-04 15:28:53.123 +0000 UTC' or RFC 3339."""
    if not s:
        return None
    s = re.sub(r"\s+[A-Z]{2,5}$", "", s.strip())
    m = re.match(r"(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d)(?:\.\d+)?\s*(Z|[+-]\d\d:?\d\d)?", s)
    if not m:
        return None
    tz = m.group(3) or "+0000"
    tz = "+0000" if tz == "Z" else tz.replace(":", "")
    try:
        return dt.datetime.strptime(f"{m.group(1)} {m.group(2)} {tz}", "%Y-%m-%d %H:%M:%S %z")
    except ValueError:
        return None


def leftovers(cfg: dict, since: dt.datetime) -> dict:
    """Resources still present after the last make clean. Remove only those created after
    `since` (this run made them: the conflict check found none before it started)."""
    res = stack_resources(cfg, host_state())
    report = {"found": {k: [x["name"] for x in v] for k, v in res.items() if v}, "removed": [], "kept": []}
    order = [("containers", ["podman", "rm", "-f"]), ("volumes", ["podman", "volume", "rm", "-f"]),
             ("networks", ["podman", "network", "rm", "-f"])]
    for kind, cmd in order:
        for x in res[kind]:
            c = parse_created(x.get("created", ""))
            if c and c >= since - dt.timedelta(seconds=5):
                ok = sh(cmd + [x["name"]]).returncode == 0
                report["removed" if ok else "kept"].append(f"{kind[:-1]} {x['name']}")
            else:
                report["kept"].append(f"{kind[:-1]} {x['name']} (not created by this run)")
    return report


# --------------------------------------------------------------------------- sources
class Night:
    def __init__(self) -> None:
        self.date = dt.date.today().isoformat()
        RUNS.mkdir(parents=True, exist_ok=True)
        d, n = RUNS / self.date, 1
        while d.exists():
            n += 1
            d = RUNS / f"{self.date}.{n}"
        self.dir = d
        self.logs = d / "logs"
        self.src = d / "src"
        self.work = d / "work"
        for p in (self.logs, self.src, self.work):
            p.mkdir(parents=True)
        self.summary: dict = {"night": d.name, "started": now(), "host": os.uname().nodename,
                              "runner": runner_version(), "report_mode": REPORT_MODE,
                              "sources": [], "versions": {}, "results": [], "warnings": [], "self_checks": {}}

    def save(self) -> None:
        tmp = self.dir / "summary.json.tmp"
        tmp.write_text(json.dumps(self.summary, indent=2, sort_keys=False) + "\n")
        tmp.replace(self.dir / "summary.json")


def runner_version() -> str:
    h = hashlib.sha256()
    for f in sorted(HERE.glob("*.py")) + sorted(HERE.glob("*.toml")):
        h.update(f.read_bytes())
    return h.hexdigest()[:12]


def git(args: list[str], cwd: Path, check: bool = True) -> str:
    r = sh(["git", *args], cwd=cwd)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def labelled_prs(token: str | None) -> list[dict]:
    try:
        items = http_json(f"https://api.github.com/repos/{REPO}/issues?state=open&labels={PR_LABEL}&per_page=100", token)
    except Exception as e:  # label may not exist yet: that is "no PRs", not an error
        log(f"labelled PRs: {e}")
        return []
    return [{"number": i["number"], "title": i["title"]} for i in items if "pull_request" in i]


def fetch_sources(night: Night, token: str | None) -> list[dict]:
    """Clone the repo once; one ref per source: main, e2e-labelled PRs, E2E_EXTRA_REFS."""
    repo = night.src / "repo"
    sh(["git", "clone", "--quiet", "--no-checkout", REPO_URL, str(repo)], check=True)
    refs = [{"ref": "main", "fetch": "refs/heads/main", "kind": "main"}]
    for pr in labelled_prs(token):
        refs.append({"ref": f"pr-{pr['number']}", "fetch": f"refs/pull/{pr['number']}/head", "kind": "pr",
                     "title": pr["title"]})
    for b in EXTRA_REFS:
        if b != "main" and not any(r["ref"] == b for r in refs):
            refs.append({"ref": b, "fetch": f"refs/heads/{b}", "kind": "branch"})
    sources = []
    for r in refs:
        local = f"refs/e2e/{slugify(r['ref'])}"
        res = sh(["git", "fetch", "--quiet", "origin", f"+{r['fetch']}:{local}"], cwd=repo)
        if res.returncode != 0:
            night.summary["warnings"].append(f"cannot fetch {r['ref']}: {res.stderr.strip()[:200]}")
            continue
        r["sha"] = git(["rev-parse", local], repo)
        r["local"] = local
        sources.append(r)
    return sources


def walkthroughs_in(repo: Path, sha: str) -> list[str]:
    names = git(["ls-tree", "-d", "--name-only", sha], repo).split()
    found = []
    for n in names:
        if n.startswith(".") or n in ("docs", "includes", "e2e"):
            continue
        if sh(["git", "cat-file", "-e", f"{sha}:{n}/Makefile"], cwd=repo).returncode == 0:
            found.append(n)
    return found


def plan_runs(night: Night, sources: list[dict], registry: dict) -> list[dict]:
    """(walkthrough, ref) pairs: everything on main; from other refs, the walkthroughs that are
    new or whose non-Markdown files differ from main."""
    repo = night.src / "repo"
    main = next((s for s in sources if s["ref"] == "main"), None)
    on_main = set(walkthroughs_in(repo, main["sha"])) if main else set()
    plan = []
    for s in sources:
        wts = walkthroughs_in(repo, s["sha"])
        if s["ref"] != "main":
            changed = set()
            for f in git(["diff", "--name-only", f"{main['sha']}...{s['sha']}"], repo).split() if main else []:
                if not f.endswith(".md") and "/" in f:
                    changed.add(f.split("/", 1)[0])
            wts = [w for w in wts if w not in on_main or w in changed]
        s["walkthroughs"] = wts
        for w in wts:
            if ONLY and w not in ONLY:
                continue
            plan.append({"slug": w, "source": s, "cfg": {**registry.get("defaults", {}),
                                                         **registry.get("walkthrough", {}).get(w, {})},
                         "registered": w in registry.get("walkthrough", {})})
    return plan


# --------------------------------------------------------------------------- versions
def resolve_versions(night: Night, token: str | None) -> dict:
    """track -> {backend:{tag,image,digest}, web:{...}, label}. release = latest GitHub release
    of artifact-keeper (backend) and artifact-keeper-web (web)."""
    versions = {}
    for track in VERSIONS:
        v = {"track": track}
        for comp, repo in IMAGES.items():
            override = E(f"E2E_{track.upper()}_{comp.upper()}_TAG")
            if override:
                tag = override
            elif track == "release":
                try:
                    tag = http_json(f"https://api.github.com/repos/{RELEASE_SOURCES[comp]}/releases/latest",
                                    token)["tag_name"].lstrip("v")
                except Exception as e:
                    v["error"] = f"cannot read the latest {comp} release: {e}"
                    continue
            else:
                tag = track
            digest = registry_digest(repo, tag)
            v[comp] = {"tag": tag, "repo": f"{GHCR}/{repo}", "digest": digest}
            if not digest:
                v["error"] = f"{GHCR}/{repo}:{tag} not found or registry unreachable"
        v["label"] = f"{track} (backend {v.get('backend', {}).get('tag', '?')}, web {v.get('web', {}).get('tag', '?')})"
        versions[track] = v
    return versions


def pull_images(v: dict, logf: Path) -> tuple[bool, str]:
    """Pull backend and web by digest; record the local image IDs."""
    with logf.open("a") as fh:
        for comp in IMAGES:
            img = v[comp]
            ref = f"{img['repo']}@{img['digest']}"
            fh.write(f"$ podman pull {ref}\n")
            fh.flush()
            r = subprocess.run(["podman", "pull", ref], stdout=fh, stderr=subprocess.STDOUT, timeout=1800)
            if r.returncode != 0:
                return False, f"podman pull {img['repo']}:{img['tag']} failed"
            img["image_id"] = out(["podman", "image", "inspect", ref, "--format", "{{.Id}}"])
            img["revision"] = out(["podman", "image", "inspect", ref, "--format",
                                   '{{index .Labels "org.opencontainers.image.revision"}}'])
    return True, ""


# --------------------------------------------------------------------------- steps
def run_step(target: str, cwd: Path, env: dict, timeout: int, logf: Path) -> dict:
    t0 = time.monotonic()
    started = now()
    with logf.open("w") as fh:
        fh.write(f"# make {target} in {cwd} (timeout {timeout}s, started {started})\n")
        fh.flush()
        p = subprocess.Popen(["make", target], cwd=cwd, env=env, stdout=fh, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        timed_out = False
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
            rc = -1
            fh.write(f"\n# e2e: TIMEOUT after {timeout}s, process group killed\n")
    return {"step": target, "rc": rc, "seconds": round(time.monotonic() - t0, 1), "timed_out": timed_out,
            "started": started, "log": str(logf.relative_to(logf.parents[2]))}


def infra_reason(logf: Path) -> str | None:
    try:
        tail = logf.read_text(errors="replace").splitlines()[-200:]
    except OSError:
        return None
    text = "\n".join(tail)
    for pat, reason in INFRA_PATTERNS:
        if re.search(pat, text, re.I):
            return reason
    return None


def parse_gates(wt: Path, gates_log: Path, since: str) -> list[dict]:
    """Per-check verdicts. Prefer out/gates/results.tsv (ts, status, gate, check, why); else the
    standard lines in the log ("STATUS Gn check[: why]"), or "Gn STATUS title" lines."""
    checks: dict[tuple, dict] = {}
    tsv = wt / "out/gates/results.tsv"
    if tsv.is_file():
        for line in tsv.read_text(errors="replace").splitlines():
            cols = line.split("\t")
            if len(cols) >= 4 and cols[0] >= since[:19]:
                c = {"gate": cols[2], "check": cols[3], "status": norm_status(cols[1]),
                     "why": cols[4] if len(cols) > 4 else ""}
                checks[(c["gate"], c["check"])] = c
    if not checks:
        for line in gates_log.read_text(errors="replace").splitlines():
            m = STD_LINE.match(line)
            if m:
                status, gate, rest = m.groups()
                check, why = (rest.split(": ", 1) + [""])[:2] if status != "PASS" else (rest, "")
            else:
                m = ALT_LINE.match(line)
                if not m:
                    continue
                gate, status, check = m.groups()
                why = ""
            c = {"gate": gate, "check": check, "status": norm_status(status), "why": why}
            checks[(gate, check)] = c
    return list(checks.values())


def norm_status(s: str) -> str:
    s = s.strip()
    if s == "NOT RUN":
        return "BLOCKED(not-run)"
    return s


def stack_digests(cfg: dict) -> list[dict]:
    """Images of the running stack (after make all): container, image name, digest."""
    res = stack_resources(cfg, host_state())
    rows = []
    for c in res["containers"]:
        info = out(["podman", "inspect", c["name"], "--format", "{{.ImageName}}\t{{.Image}}"])
        if not info:
            continue
        name, iid = (info.split("\t") + [""])[:2]
        digests = out(["podman", "image", "inspect", iid, "--format", "{{join .RepoDigests \" \"}}"]).split()
        rows.append({"container": c["name"], "image": name, "image_id": iid[:19],
                     "digest": next((d.split("@", 1)[1] for d in digests if "@" in d), "")})
    return rows


def host_requirements(cfg: dict) -> list[str]:
    missing = []
    for req in cfg.get("requires", []):
        if req == "kvm":
            if not (os.access("/dev/kvm", os.R_OK | os.W_OK)):
                missing.append("kvm (/dev/kvm not read-write for this user)")
        elif req.startswith("tool:"):
            if not shutil.which(req[5:]):
                missing.append(req[5:])
    return missing


def make_targets(wt: Path) -> set[str]:
    r = sh(["make", "-qp"], cwd=wt)
    return set(re.findall(r"^([A-Za-z0-9_.-]+):", r.stdout, re.M))


def walkthrough_env(cfg: dict, v: dict, secrets: dict, npmrc: Path) -> tuple[dict, list[str]]:
    env = {k: val for k, val in os.environ.items() if not k.startswith("E2E_") and k not in secrets
           and k not in ("GH_TOKEN", "GITHUB_TOKEN", "MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
    env["PATH"] = os.environ["PATH"]
    for comp, var in (("backend", "BACKEND"), ("web", "WEB")):
        img = v[comp]
        env[f"AK_{var}_IMAGE"] = f"{img['repo']}:{img['tag']}@{img['digest']}"
        env[f"AK_{var}_TAG"] = img["tag"]
    env["AK_E2E"] = "1"
    env["npm_config_registry"] = NPM_REGISTRY
    env["NPM_CONFIG_USERCONFIG"] = str(npmrc)   # never the user's ~/.npmrc
    missing = []
    for name in cfg.get("secrets", []):
        if name in secrets:
            env[name] = secrets[name]
        else:
            missing.append(name)
    return env, missing


def run_one(night: Night, item: dict, track: str, v: dict, secrets: dict, npmrc: Path) -> dict:
    slug, src, cfg = item["slug"], item["source"], item["cfg"]
    key = f"{slug}@{track}" + ("" if src["ref"] == "main" else f"@{src['ref']}")
    res = {"key": key, "walkthrough": slug, "ref": src["ref"], "sha": src["sha"][:12], "track": track,
           "version": v.get("label"), "verdict": None, "reason": "", "steps": [], "checks": [],
           "digests": {c: v.get(c, {}).get("digest") for c in IMAGES}, "stack_images": [],
           "secrets_missing": [], "leftovers": None, "patched": None, "started": now()}
    ldir = night.logs / slugify(key)
    ldir.mkdir(parents=True, exist_ok=True)

    def blocked(reason: str) -> dict:
        res["verdict"], res["reason"] = f"BLOCKED({reason.split(':')[0]})", reason
        res["finished"] = now()
        log(f"{key}: {res['verdict']} {reason}")
        return res

    if not item["registered"]:
        return blocked("unregistered: no entry in e2e/walkthroughs.toml")
    if v.get("error"):
        return blocked(f"registry-pull: {v['error']}")
    if track == "release" and cfg.get("min_ak") and vtuple(v["backend"]["tag"]) < vtuple(cfg["min_ak"]):
        return blocked(f"min-version: needs Artifact Keeper >= {cfg['min_ak']}, release is {v['backend']['tag']}")
    c = conflicts(cfg)
    if c:
        return blocked("conflict: " + "; ".join(c))
    miss = host_requirements(cfg)
    if miss:
        return blocked("host: missing " + ", ".join(miss))
    need = int(cfg.get("disk_gb", 40))
    have = min(free_gb(podman_graphroot()), free_gb(night.dir))
    if have < need:
        return blocked(f"disk: {have} GB free, needs {need} GB")

    # fresh checkout of this ref for this run
    repo = night.src / "repo"
    wroot = night.work / slugify(key)
    git(["worktree", "add", "--quiet", "--detach", str(wroot), src["sha"]], repo)
    if PATCH_DIR:
        p = Path(PATCH_DIR) / f"{slugify(src['ref'])}.patch"
        if p.is_file():
            r = sh(["git", "apply", "--whitespace=nowarn", str(p)], cwd=wroot)
            if r.returncode != 0:
                return blocked(f"patch: {p.name} does not apply: {r.stderr.strip()[:200]}")
            res["patched"] = {"file": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()[:16]}
    wt = wroot / slug

    targets = make_targets(wt)
    missing_t = [t for t in ("all", "gates", "clean") if t not in targets]
    if missing_t:
        return blocked("contract: Makefile has no " + ", ".join(missing_t) + " target")

    ok, why = pull_images(v, ldir / "pull.log")
    if not ok:
        return blocked(f"registry-pull: {why}")
    for comp in IMAGES:
        res["digests"][comp] = v[comp]["digest"]
        res.setdefault("image_ids", {})[comp] = v[comp].get("image_id", "")[:19]
        res.setdefault("revisions", {})[comp] = v[comp].get("revision", "")

    env, res["secrets_missing"] = walkthrough_env(cfg, v, secrets, npmrc)
    t_start = dt.datetime.now(dt.timezone.utc)

    if cfg.get("preflight") and cfg["preflight"] in targets:
        st = run_step(cfg["preflight"], wt, env, 300, ldir / "0-preflight.log")
        res["steps"].append(st)
        if st["rc"] != 0:
            bad = [l.strip() for l in (ldir / "0-preflight.log").read_text(errors="replace").splitlines()
                   if re.match(r"\s*FAIL\b", l)]
            return blocked("preflight: " + ("; ".join(bad[:4]) or f"make {cfg['preflight']} exited {st['rc']}"))

    plan = [("clean", "1-clean", cfg["timeout_clean"]), ("all", "2-all", cfg["timeout_all"]),
            ("gates", "3-gates", cfg["timeout_gates"])]
    failed_step = None
    for target, name, tmo in plan:
        log(f"{key}: make {target}")
        st = run_step(target, wt, env, int(tmo), ldir / f"{name}.log")
        res["steps"].append(st)
        if target == "all" and st["rc"] == 0:
            res["stack_images"] = stack_digests(cfg)
        if target == "gates":
            res["checks"] = parse_gates(wt, ldir / f"{name}.log", st["started"])
            if (wt / "out/gates").is_dir():
                shutil.copytree(wt / "out/gates", ldir / "gates", dirs_exist_ok=True,
                                ignore=shutil.ignore_patterns("tmp", "homes"))
        if st["rc"] != 0 and target != "gates":
            failed_step = st
            break
    # always clean up, even after a failure
    log(f"{key}: make clean")
    st = run_step("clean", wt, env, int(cfg["timeout_clean"]), ldir / "4-clean.log")
    res["steps"].append(st)
    res["leftovers"] = leftovers(cfg, t_start)

    gates = next((s for s in res["steps"] if s["step"] == "gates"), None)
    fails = [c for c in res["checks"] if c["status"] == "FAIL"]
    if failed_step:
        infra = infra_reason(night.dir / failed_step["log"])
        what = "timed out" if failed_step["timed_out"] else f"exited {failed_step['rc']}"
        if infra:
            res["verdict"], res["reason"] = f"BLOCKED({infra})", f"make {failed_step['step']} {what} ({infra} problem in the log)"
        else:
            res["verdict"], res["reason"] = "FAIL", f"make {failed_step['step']} {what}"
    elif fails:
        res["verdict"] = "FAIL"
        res["reason"] = f"{len(fails)} check(s) FAIL: " + ", ".join(f"{c['gate']} {c['check']}" for c in fails[:5])
    elif gates and gates["timed_out"]:
        res["verdict"], res["reason"] = "FAIL", "make gates timed out"
    elif gates and not res["checks"]:
        infra = infra_reason(night.dir / gates["log"]) if gates["rc"] else None
        res["verdict"] = f"BLOCKED({infra})" if infra else "FAIL"
        res["reason"] = f"make gates exited {gates['rc']} and printed no verdict lines"
    elif gates and gates["rc"] != 0:
        res["verdict"], res["reason"] = "FAIL", f"make gates exited {gates['rc']} with no FAIL check"
    elif st["rc"] != 0:
        res["verdict"], res["reason"] = "FAIL", f"final make clean exited {st['rc']}"
    else:
        res["verdict"] = "PASS"
        nb = [c for c in res["checks"] if c["status"].startswith("BLOCKED")]
        res["reason"] = f"{len(res['checks']) - len(nb)} checks PASS" + (f", {len(nb)} BLOCKED" if nb else "")
    res["finished"] = now()
    log(f"{key}: {res['verdict']} {res['reason']}")
    if not KEEP_WORK:
        sh(["git", "worktree", "remove", "--force", str(wroot)], cwd=repo)
        if wroot.exists():  # files written by containers as another uid: remove through podman
            sh(["podman", "unshare", "rm", "-rf", str(wroot)])
    return res


# --------------------------------------------------------------------------- diff & self-checks
def previous_nights(before: str) -> list[Path]:
    """Earlier nights with a summary.json, newest first."""
    nights = [d for d in RUNS.iterdir() if d.is_dir() and d.name < before and (d / "summary.json").is_file()]
    return sorted(nights, key=lambda d: d.name, reverse=True)


def load(d: Path) -> dict:
    try:
        return json.loads((d / "summary.json").read_text())
    except Exception:
        return {}


def decisive_history(prev: list[Path], key: str, limit: int = 14) -> str | None:
    """The latest PASS or FAIL for a key in earlier nights (BLOCKED nights are skipped)."""
    for d in prev[:limit]:
        for r in load(d).get("results", []):
            if r["key"] == key and r["verdict"] in ("PASS", "FAIL"):
                return r["verdict"]
    return None


def diff_nights(cur: dict, prev: list[Path]) -> dict:
    base = load(prev[0]) if prev else {}
    bres = {r["key"]: r for r in base.get("results", [])}
    d = {"baseline": base.get("night"), "new_fail": [], "new_pass": [], "still_fail": [], "slower": [],
         "digests_moved": [], "verdict_changes": []}
    for r in cur["results"]:
        k = r["key"]
        before = decisive_history(prev, k)
        b = bres.get(k)
        if b and b["verdict"] != r["verdict"]:
            d["verdict_changes"].append({"key": k, "from": b["verdict"], "to": r["verdict"]})
        if r["verdict"] == "FAIL":
            (d["still_fail"] if before == "FAIL" else d["new_fail"]).append(k)
        if r["verdict"] == "PASS" and before == "FAIL":
            d["new_pass"].append(k)
        if b:
            bsteps = {s["step"] + ("#2" if i and s["step"] == "clean" else ""): s
                      for i, s in enumerate(b.get("steps", []))}
            for i, s in enumerate(r.get("steps", [])):
                sk = s["step"] + ("#2" if i and s["step"] == "clean" else "")
                bs = bsteps.get(sk)
                if bs and bs["rc"] == 0 and s["rc"] == 0 and bs["seconds"] >= 1 and \
                        s["seconds"] >= SLOW_FLOOR_S and s["seconds"] > SLOW_FACTOR * bs["seconds"]:
                    d["slower"].append({"key": k, "step": sk, "seconds": s["seconds"], "baseline": bs["seconds"]})
            for comp, dig in (r.get("digests") or {}).items():
                bd = (b.get("digests") or {}).get(comp)
                if dig and bd and dig != bd:
                    d["digests_moved"].append({"key": k, "image": comp, "from": bd, "to": dig})
            bimg = {x["container"]: x["digest"] for x in b.get("stack_images", [])}
            for x in r.get("stack_images", []):
                if x["container"] in bimg and bimg[x["container"]] and x["digest"] and bimg[x["container"]] != x["digest"]:
                    d["digests_moved"].append({"key": k, "image": x["image"], "from": bimg[x["container"]], "to": x["digest"]})
    return d


def self_checks(night: Night, prev: list[Path]) -> dict:
    sc = {"missed_nights": [], "empty_nights": []}
    today = dt.date.fromisoformat(night.date)
    dated = [d for d in RUNS.iterdir() if d.is_dir() and d.name < night.dir.name]
    if dated:
        last = max(dt.date.fromisoformat(d.name[:10]) for d in dated)
        gap = (today - last).days
        sc["missed_nights"] = [(last + dt.timedelta(days=i)).isoformat() for i in range(1, gap)]
        for d in sorted(dated, key=lambda d: d.name, reverse=True)[:1]:
            s = load(d)
            if not s or not s.get("results") or not s.get("finished"):
                sc["empty_nights"].append(d.name)
    return sc


# --------------------------------------------------------------------------- reporting
def issue_title(r: dict) -> str:
    ref = "" if r["ref"] == "main" else f" ({r['ref']})"
    return f"{TITLE_PREFIX} {r['walkthrough']} fails on {r['track']}{ref}"


def issue_body(night: Night, r: dict) -> str:
    fails = [c for c in r["checks"] if c["status"] == "FAIL"]
    lines = [
        f"The nightly end-to-end run on `{night.summary['host']}` ({night.dir.name}) failed for "
        f"**{r['walkthrough']}** against Artifact Keeper **{r['version']}**.",
        "",
        ("A failure on the release only means the published walkthrough no longer works as written."
         if r["track"] == "release" else
         "A failure on `:dev` only is an early warning: the next release may break this walkthrough."),
        "",
        f"- Walkthrough source: `{r['ref']}` at {r['sha']}",
        f"- Verdict: {r['verdict']}: {r['reason']}",
        f"- Backend `{r['digests'].get('backend')}` (revision {r.get('revisions', {}).get('backend', '?')})",
        f"- Web `{r['digests'].get('web')}` (revision {r.get('revisions', {}).get('web', '?')})",
        "",
        "| Step | Exit | Seconds |", "|---|---|---|",
    ]
    for s in r["steps"]:
        lines.append(f"| make {s['step']} | {'timeout' if s['timed_out'] else s['rc']} | {s['seconds']:.0f} |")
    if fails:
        lines += ["", "Failed checks:", ""]
        lines += [f"- `{c['gate']}` {c['check']}{': ' + c['why'] if c['why'] else ''}" for c in fails]
    failing = next((s for s in r["steps"] if s["rc"] != 0), None)
    if failing:
        text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", (night.dir / failing["log"]).read_text(errors="replace"))
        tail = text.splitlines()[-40:]
        lines += ["", f"Last lines of `make {failing['step']}`:", "", "```", *tail, "```"]
    lines += ["", f"Logs on the runner host: `{night.dir}/{Path(failing['log']).parent if failing else 'logs'}`.",
              "This issue is closed automatically when the walkthrough passes again."]
    return "\n".join(lines)


class Reporter:
    """Opens one issue per walkthrough+version on a new FAIL, comments and closes it on PASS.
    E2E_REPORT=dry-run (default) prints what it would post; E2E_REPORT=github posts it."""

    def __init__(self, night: Night, secrets: dict, force_dry_run: bool = False):
        self.night = night
        self.token = secrets.get("GH_TOKEN")
        self.real = REPORT_MODE == "github" and not force_dry_run
        self.out: list[str] = []
        self.actions: list[dict] = []
        self.open_issues = None
        if self.real and not self.token:
            self.out.append("E2E_REPORT=github but ~/.config/ak-e2e/gh-token is missing: reporting is BLOCKED(secret); dry run instead")
            self.real = False

    def find_open(self, title: str) -> dict | None:
        if self.open_issues is None:
            self.open_issues = []
            try:
                for page in range(1, 6):
                    items = http_json(f"https://api.github.com/repos/{REPO}/issues?state=open&per_page=100&page={page}",
                                      self.token)
                    self.open_issues += [i for i in items if "pull_request" not in i
                                         and i["title"].startswith(TITLE_PREFIX)]
                    if len(items) < 100:
                        break
            except Exception as e:
                self.out.append(f"(could not list open issues: {e})")
        return next((i for i in self.open_issues if i["title"] == title), None)

    def act(self, kind: str, title: str, body: str, number: int | None = None) -> None:
        self.actions.append({"action": kind, "title": title, "number": number, "body": body})
        if not self.real:
            hdr = {"open": "WOULD OPEN ISSUE", "close": f"WOULD COMMENT ON AND CLOSE #{number or '?'}",
                   "comment": f"WOULD COMMENT ON #{number or '?'}"}[kind]
            self.out += ["", "=" * 78, f"[dry-run] {hdr} in {REPO}", f"Title: {title}", "-" * 78, body]
            return
        api = f"https://api.github.com/repos/{REPO}/issues"
        if kind == "open":
            i = http_json(api, self.token, "POST", {"title": title, "body": body})
            self.out.append(f"opened #{i['number']}: {title}")
        else:
            http_json(f"{api}/{number}/comments", self.token, "POST", {"body": body})
            if kind == "close":
                http_json(f"{api}/{number}", self.token, "PATCH", {"state": "closed", "state_reason": "completed"})
            self.out.append(f"{kind} #{number}: {title}")

    def run(self, diff: dict, sc: dict) -> None:
        results = {r["key"]: r for r in self.night.summary["results"]}
        # Open only on a new FAIL (the last PASS/FAIL verdict before tonight was not FAIL), and
        # not when an issue with the same title is already open. A FAIL that persists stays quiet.
        for k in diff["new_fail"]:
            r = results[k]
            title = issue_title(r)
            if self.find_open(title):
                continue
            self.act("open", title, issue_body(self.night, r))
        # Close on PASS: in github mode whenever the issue is open; in a dry run when the
        # previous PASS/FAIL verdict was FAIL.
        for r in results.values():
            if r["verdict"] != "PASS":
                continue
            title = issue_title(r)
            existing = self.find_open(title)
            if existing or (not self.real and r["key"] in diff["new_pass"]):
                body = (f"Passes again in the nightly run {self.night.dir.name} against {r['version']} "
                        f"(walkthrough {r['ref']} at {r['sha']}): {r['reason']}. Closing.")
                self.act("close", title, body, existing["number"] if existing else None)
        problems = []
        if sc.get("missed_nights"):
            problems.append(f"no run on {', '.join(sc['missed_nights'])}")
        if sc.get("empty_nights"):
            problems.append(f"the previous night ({', '.join(sc['empty_nights'])}) has no results or did not finish")
        if sc.get("secret_leaks"):
            problems.append(f"a secret appeared in {len(sc['secret_leaks'])} log file(s) (redacted)")
        if not self.night.summary["results"]:
            problems.append("this night ran no walkthroughs")
        title = f"{TITLE_PREFIX} nightly runner health"
        existing = self.find_open(title)
        if problems:
            body = f"Night {self.night.dir.name} on {self.night.summary['host']}:\n\n" + "\n".join(f"- {p}" for p in problems)
            if existing:
                self.act("comment", title, body, existing["number"])
            else:
                self.act("open", title, body)
        elif existing:
            self.act("close", title, f"Night {self.night.dir.name} ran and finished normally. Closing.", existing["number"])
        if not self.actions:
            self.out.append("quiet night: nothing to report")


def redact_logs(night: Night, secrets: dict) -> list[str]:
    """grep the night's files for every secret value; redact in place; return the files."""
    leaks = []
    vals = [v for v in secrets.values() if len(v) >= 8]
    if not vals:
        return leaks
    for f in night.dir.rglob("*"):
        if not f.is_file() or f.is_symlink() or "work" in f.relative_to(night.dir).parts[:1]:
            continue
        try:
            data = f.read_bytes()
        except OSError:
            continue
        hit = False
        for v in vals:
            if v.encode() in data:
                data, hit = data.replace(v.encode(), b"<redacted>"), True
        if hit:
            f.write_bytes(data)
            leaks.append(str(f.relative_to(night.dir)))
    return leaks


def write_report(night: Night, diff: dict, reporter: Reporter) -> str:
    s = night.summary
    lines = [f"Artifact Keeper walkthroughs, nightly e2e: {s['night']} on {s['host']}", ""]
    for t, v in s["versions"].items():
        lines.append(f"  {t:8} {v.get('label')}  backend {(v.get('backend') or {}).get('digest', '?')}")
    lines += ["", f"  {'walkthrough@version[@ref]':58} {'verdict':22} {'time':>7}  reason"]
    for r in s["results"]:
        secs = sum(st["seconds"] for st in r["steps"])
        lines.append(f"  {r['key']:58} {r['verdict']:22} {secs / 60:6.1f}m  {r['reason'][:110]}")
    lines += ["", f"Compared with {diff['baseline'] or 'nothing (first night)'}:"]
    for k in ("new_fail", "new_pass", "still_fail"):
        if diff[k]:
            lines.append(f"  {k.replace('_', ' ')}: {', '.join(diff[k])}")
    for x in diff["slower"]:
        lines.append(f"  slower: {x['key']} make {x['step']} {x['seconds']:.0f}s (baseline {x['baseline']:.0f}s)")
    for x in diff["digests_moved"]:
        lines.append(f"  digest moved: {x['key']} {x['image']} {x['from'][:19]} -> {x['to'][:19]}")
    sc = s["self_checks"]
    for name in ("missed_nights", "empty_nights", "secret_leaks"):
        if sc.get(name):
            lines.append(f"  self-check {name.replace('_', ' ')}: {sc[name]}")
    for r in s["results"]:
        lo = r.get("leftovers") or {}
        if lo.get("found"):
            lines.append(f"  leftovers after make clean ({r['key']}): {lo['found']}; removed {len(lo['removed'])}, kept {lo['kept']}")
    for w in s["warnings"]:
        lines.append(f"  warning: {w}")
    lines += ["", f"Issue reporting ({'github' if reporter.real else 'dry-run'}):", *reporter.out]
    text = "\n".join(lines) + "\n"
    (night.dir / "report.txt").write_text(text)
    return text


# --------------------------------------------------------------------------- main
def run_night() -> int:
    E2E_HOME.mkdir(parents=True, exist_ok=True)
    os.environ["PATH"] = os.pathsep.join([str(TOOLS), f"{HOME}/.local/bin", "/usr/local/bin", "/usr/bin", "/bin",
                                          "/snap/bin", os.environ.get("PATH", "")])
    lock = open(E2E_HOME / ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another ak-e2e run holds the lock; exiting")
        return 3
    secrets, warns = load_secrets()
    registry = tomllib.loads((HERE / "walkthroughs.toml").read_text())
    night = Night()
    log(f"night {night.dir}")
    night.summary["warnings"] += warns
    npmrc = night.dir / "npmrc"
    npmrc.write_text(f"registry={NPM_REGISTRY}\n")
    prev = previous_nights(night.dir.name)
    night.summary["self_checks"] = self_checks(night, prev)
    night.save()
    token = secrets.get("GH_TOKEN")
    try:
        night.summary["versions"] = versions = resolve_versions(night, token)
        sources = fetch_sources(night, token)
        night.summary["sources"] = [{k: s[k] for k in ("ref", "kind", "sha") if k in s} for s in sources]
        plan = plan_runs(night, sources, registry)
        for s, src in zip(night.summary["sources"], sources):
            s["walkthroughs"] = src.get("walkthroughs", [])
        night.save()
        log("plan: " + ", ".join(f"{p['slug']}@{p['source']['ref']}" for p in plan))
        for item in plan:
            for track in VERSIONS:
                if ONLY_RUNS and f"{item['slug']}@{track}" not in ONLY_RUNS:
                    continue
                try:
                    r = run_one(night, item, track, versions[track], secrets, npmrc)
                except Exception as e:  # the runner's own bug: report it, keep going
                    r = {"key": f"{item['slug']}@{track}", "walkthrough": item["slug"], "ref": item["source"]["ref"],
                         "sha": item["source"]["sha"][:12], "track": track, "version": versions[track].get("label"),
                         "verdict": "BLOCKED(runner)", "reason": f"runner error: {e!r}", "steps": [], "checks": [],
                         "digests": {}, "stack_images": []}
                    log(f"runner error on {item['slug']}@{track}: {e!r}")
                night.summary["results"].append(r)
                night.save()
    except Exception as e:
        night.summary["warnings"].append(f"night aborted: {e!r}")
        log(f"night aborted: {e!r}")
    night.summary["finished"] = now()
    night.summary["self_checks"]["secret_leaks"] = redact_logs(night, secrets)
    diff = diff_nights(night.summary, prev)
    night.summary["diff"] = diff
    reporter = Reporter(night, secrets)
    try:
        reporter.run(diff, night.summary["self_checks"])
    except Exception as e:
        reporter.out.append(f"reporting failed: {e!r}")
    night.summary["issue_actions"] = [{k: a[k] for k in ("action", "title", "number")} for a in reporter.actions]
    night.save()
    print(write_report(night, diff, reporter))
    if reporter.actions and not reporter.real:
        (night.dir / "issues-dry-run.md").write_text("\n".join(reporter.out) + "\n")
    if not KEEP_WORK:
        sh(["podman", "unshare", "rm", "-rf", str(night.work)])
        sh(["git", "worktree", "prune"], cwd=night.src / "repo")
    prune_old_nights()
    return 0


def prune_old_nights() -> None:
    nights = sorted((d for d in RUNS.iterdir() if d.is_dir()), key=lambda d: d.name)
    for d in nights[:-KEEP_NIGHTS] if len(nights) > KEEP_NIGHTS else []:
        sh(["podman", "unshare", "rm", "-rf", str(d)])


def report_only() -> int:
    nights = sorted((d for d in RUNS.iterdir() if (d / "summary.json").is_file()), key=lambda d: d.name)
    if not nights:
        print("no nights yet")
        return 1
    secrets, _ = load_secrets()
    night = Night.__new__(Night)
    night.dir, night.summary = nights[-1], load(nights[-1])
    night.date = night.dir.name[:10]
    prev = previous_nights(night.dir.name)
    diff = diff_nights(night.summary, prev)
    reporter = Reporter(night, secrets, force_dry_run=True)   # re-reporting never posts
    reporter.run(diff, night.summary.get("self_checks", {}))
    print(write_report(night, diff, reporter))
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "run":
        sys.exit(run_night())
    if cmd == "report":
        sys.exit(report_only())
    print(__doc__)
    sys.exit(2)
