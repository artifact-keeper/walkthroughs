#!/usr/bin/env python3
"""The lab's bridge from Artifact Keeper's plugins Remote to pi. This is a step of this
walkthrough, not a pi feature: pi reads MCP servers from ~/.pi/agent/mcp.json and skills from
paths, but it has no plugin marketplace client.

    bridge.py [PLUGIN] [--servers NAME,...]

1. GET {AK}/agentplugins/{PLUGINS_REPO}/{PLUGIN}/index.json, download the newest version's
   zip, and refuse it unless its SHA-256 equals the index's. Unzip it into
   ~/.pi/agent/plugins/{PLUGIN}/{version}/.
2. Check every MCP server of the plugin's mcp.json against the MCP registry
   ({AK}/mcp/{MCP_REPO}/v0.1/servers), the same check agent.py makes: the Python distribution
   that provides the server's command must be listed there at the installed version.
3. Write ~/.pi/agent/mcp.json with the listed servers named in --servers (default
   acme-inventory), each with "exposure": "direct", so pi declares their tools to the model
   as ordinary tools. pi's default, codemode, has the model write scripts that look tools up,
   which a 1.5B model does not manage.

The skill (skills/*/SKILL.md) is left where the zip put it; flows/pi.sh hands it to pi with
--append-system-prompt. Prints one JSON report on stdout. The registry calls are agent.py's
(/opt/agent/agent.py in this image), so the two clients apply one rule.
"""
import argparse
import hashlib
import io
import json
import pathlib
import sys
import time
import zipfile

sys.path.insert(0, "/opt/agent")
import agent  # noqa: E402  (AK, PLUGINS_REPO, MCP_REPO, get, norm, registry_packages, distribution_of)

agent.T0 = time.monotonic()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plugin", nargs="?", default="offgrid-ops")
    ap.add_argument("--servers", default="acme-inventory")
    a = ap.parse_args()
    want = set(a.servers.split(","))
    report = {"ok": False, "plugin": {}, "servers": [], "mcp_json": None, "skill": None}

    idx = agent.get(f"{agent.AK}/agentplugins/{agent.PLUGINS_REPO}/{a.plugin}/index.json")
    v = next(x for x in idx["versions"] if x["version"] == idx["latest"])
    blob = agent.get(v["url"], binary=True)
    sha = hashlib.sha256(blob).hexdigest()
    report["plugin"] = {"name": a.plugin, "version": v["version"], "url": v["url"], "sha256": sha,
                        "index_sha256": v["sha256"], "verified": sha == v["sha256"]}
    if sha != v["sha256"]:
        report["error"] = f"SHA-256 {sha} is not the index's {v['sha256']}; refused"
        print(json.dumps(report)); return 1
    dest = pathlib.Path.home() / ".pi" / "agent" / "plugins" / a.plugin / v["version"]
    dest.mkdir(parents=True, exist_ok=True)
    zf = zipfile.ZipFile(io.BytesIO(blob))
    zf.extractall(dest)
    report["plugin"].update(dir=str(dest), files=sorted(zf.namelist()))

    servers = json.loads((dest / "mcp.json").read_text())["mcpServers"]
    reg = agent.registry_packages()
    conf = {}
    for name, spec in servers.items():
        dist, ver = agent.distribution_of(spec["command"], spec.get("args", []))
        listed = reg.get(("pypi", agent.norm(dist or ""), ver))
        use = bool(listed) and name in want
        report["servers"].append({"server": name, "command": spec["command"], "distribution": dist,
                                  "version": ver, "registry_name": listed, "configured": use})
        if use:
            conf[name] = {**spec, "exposure": "direct"}
    out = pathlib.Path.home() / ".pi" / "agent" / "mcp.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"mcpServers": conf}, indent=2) + "\n")
    report["mcp_json"] = {"path": str(out), "mcpServers": conf}
    skill = next(dest.glob("skills/*/SKILL.md"), None)
    report["skill"] = str(skill) if skill else None
    report["ok"] = bool(conf) and skill is not None
    print(json.dumps(report))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
