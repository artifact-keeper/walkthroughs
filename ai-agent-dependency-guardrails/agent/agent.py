"""Replay the scripted agent session (agent/plan.toml) in the sandbox and record what happened.

Each step runs in a fresh scratch copy of app/ (lockfiles and sources, no .venv or
node_modules), through sandbox/run.sh: the agent's network, image and read-only token.
Writes agent/out/<NN>-<id>.txt (command, output, probe, verdict) and agent/out/summary.json,
and prints one line per step. Exit status 1 if any step did not behave as the plan expects.
`agent.sh --only ID [ID...]` replays just those steps (transcripts kept, summary untouched).
Standard library only (tomllib: Python 3.11+).
"""

import json
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "agent" / "out"
RUN = ROOT / "sandbox" / "run.sh"

# A direct request from inside the sandbox, to show the registry's own answer: uv and npm
# report "403 Forbidden" or "451" but not the JSON body that says why.
PROBE = r"""
import base64, os, sys, urllib.request
url = "https://ak.internal/" + ("npm/" if sys.argv[1].startswith("npm") else "pypi/") + sys.argv[1]
req = urllib.request.Request(url, headers={"Authorization": "Bearer " + os.environ["AK_TOKEN"]})
try:
    r = urllib.request.urlopen(req, timeout=60)
    print(f"GET {url}\n{r.status} {r.reason}\n{r.read(300).decode(errors='replace')}")
except urllib.error.HTTPError as e:
    print(f"GET {url}\n{e.code} {e.reason}\n{e.read(600).decode(errors='replace')}")
"""


def sandbox(work: Path, argv: list[str]) -> tuple[int, str]:
    p = subprocess.run([str(RUN), "-w", str(work), "--", *argv], capture_output=True, text=True, timeout=600)
    return p.returncode, (p.stdout + p.stderr).strip()


def scratch_app() -> Path:
    work = Path(tempfile.mkdtemp(prefix="agent-step-"))
    for name in ("pyproject.toml", "uv.lock", "package.json", "package-lock.json", "main.py"):
        shutil.copy2(ROOT / "app" / name, work / name)
    return work


def main() -> int:
    plan = tomllib.loads((ROOT / "agent" / "plan.toml").read_text())["step"]
    only = sys.argv[2:] if sys.argv[1:2] == ["--only"] else []  # agent.sh --only ID [ID...]
    if not only:
        shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    results, failed = [], 0
    for n, step in enumerate(plan, 1):
        if only and step["id"] not in only:
            continue
        if step.get("setup"):
            subprocess.run(step["setup"], shell=True, cwd=ROOT, check=True, capture_output=True)
        work = scratch_app()
        try:
            code, output = sandbox(work, ["sh", "-c", step["cmd"]])
            probe = sandbox(work, ["python3", "-c", PROBE, step["probe"]])[1] if step.get("probe") else ""
        finally:
            shutil.rmtree(work, ignore_errors=True)
        refused = code != 0
        matched = step.get("match", "") in output + "\n" + probe
        ok = (refused if step["expect"] == "refused" else not refused) and matched
        failed += not ok
        verdict = ("PASS" if ok else "FAIL") + f" (expected {step['expect']}, exit {code}" + (f", '{step['match']}' {'found' if matched else 'missing'})" if step.get("match") else ")")
        (OUT / f"{n:02d}-{step['id']}.txt").write_text(
            f"# {step['title']}\n# {step['why']}\n\n$ {step['cmd']}\n{output}\n\nexit {code}\n"
            + (f"\n# what the registry said\n{probe}\n" if probe else "")
            + f"\n{verdict}\n"
        )
        results.append({"n": n, "id": step["id"], "title": step["title"], "expect": step["expect"], "exit": code, "pass": ok, "probe": probe})
        print(f"{'PASS' if ok else 'FAIL'}  {n:2d} {step['id']:<18} {step['title']}")
    if only:
        return 1 if failed else 0
    (OUT / "summary.json").write_text(json.dumps(results, indent=2))
    print(f"agent: {len(plan) - failed}/{len(plan)} steps behaved as expected; transcripts in {OUT}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
