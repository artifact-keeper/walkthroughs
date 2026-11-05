#!/usr/bin/env python3
"""The off-grid agent: a small tool-using agent that gets everything from Artifact Keeper.

    agent.py [--question Q] [--plugin NAME] [--model-servers NAME,...] [--max-turns N]

What it does, in order, and what it records (one JSON document on stdout, the last line):

1. Installs its plugin from the marketplace: GET {AK}/agentplugins/{PLUGINS_REPO}/{name}/index.json,
   downloads the newest version's zip and refuses it unless its SHA-256 equals the index's.
2. Reads the plugin's mcp.json (the MCP servers to start) and its skill (the instruction).
3. Checks every server against the MCP registry, {AK}/mcp/{MCP_REPO}/v0.1/servers: the Python
   distribution that provides the server's command (a console script, or `python -m module`)
   must be listed there as a pypi package at the installed version. A server the registry
   does not list is not started.
4. Starts the allowed servers over stdio (the `mcp` package) and lists their tools.
5. Asks the local model (llama-server's OpenAI-compatible API, the `openai` package) the
   question, with the tools of --model-servers, and runs the tool calls it makes.

Environment: AK_URL (https://ak.internal), AK_TOKEN (a read token), LLM_URL
(http://ak-offgrid-llama:8080/v1), PLUGINS_REPO (plugins), MCP_REPO (mcp-all). The CA of
ak.internal is in the image's trust store. Nothing here reaches anything but those two hosts.
"""
import argparse
import asyncio
import contextlib
import hashlib
import importlib.metadata as md
import io
import json
import os
import pathlib
import re
import sys
import time
import urllib.request
import zipfile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from openai import OpenAI

AK = os.environ.get("AK_URL", "https://ak.internal").rstrip("/")
TOKEN = os.environ.get("AK_TOKEN", "")
LLM = os.environ.get("LLM_URL", "http://ak-offgrid-llama:8080/v1")
PLUGINS_REPO = os.environ.get("PLUGINS_REPO", "plugins")
MCP_REPO = os.environ.get("MCP_REPO", "mcp-all")
HOME = pathlib.Path.home()
REPORT = {"ok": False, "steps": []}


def step(what, **kw):
    REPORT["steps"].append({"step": what, "t": round(time.monotonic() - T0, 2), **kw})
    print(f"[{time.monotonic() - T0:6.1f}s] {what}: " + json.dumps(kw)[:300], file=sys.stderr, flush=True)


def get(url, binary=False):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"} if TOKEN else {})
    with urllib.request.urlopen(req, timeout=60) as r:
        body = r.read()
    return body if binary else json.loads(body)


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def install_plugin(name):
    idx = get(f"{AK}/agentplugins/{PLUGINS_REPO}/{name}/index.json")
    v = next(x for x in idx["versions"] if x["version"] == idx["latest"])
    blob = get(v["url"], binary=True)
    sha = hashlib.sha256(blob).hexdigest()
    verified = sha == v["sha256"]
    step("plugin", name=name, version=v["version"], url=v["url"], sha256=sha, index_sha256=v["sha256"], verified=verified)
    if not verified:
        raise SystemExit(f"plugin {name} {v['version']}: SHA-256 {sha} is not the index's {v['sha256']}; refusing it")
    dest = HOME / ".agent" / "plugins" / name / v["version"]
    dest.mkdir(parents=True, exist_ok=True)
    zipfile.ZipFile(io.BytesIO(blob)).extractall(dest)
    return dest, v["version"], sha


def registry_packages():
    """Every (registryType, identifier, version) -> server name the MCP registry serves."""
    out, cursor = {}, None
    for _ in range(50):
        q = "limit=100" + (f"&cursor={urllib.request.quote(cursor)}" if cursor else "")
        doc = get(f"{AK}/mcp/{MCP_REPO}/v0.1/servers?{q}")
        for e in doc.get("servers", []):
            s = e.get("server", e)
            for p in s.get("packages") or []:
                out[(p.get("registryType"), norm(p.get("identifier", "")), p.get("version"))] = s["name"]
        cursor = (doc.get("metadata") or {}).get("nextCursor")
        if not cursor:
            break
    return out


def distribution_of(command, args):
    """The installed distribution that provides an MCP server command."""
    if pathlib.Path(command).name.startswith("python") and len(args) >= 2 and args[0] == "-m":
        top = args[1].split(".")[0]
        dists = md.packages_distributions().get(top) or []
        return (dists[0], md.version(dists[0])) if dists else (None, None)
    for ep in md.entry_points(group="console_scripts"):
        if ep.name == pathlib.Path(command).name:
            return ep.dist.name, ep.dist.version
    return None, None


def tool_schema(t):
    # mcp 2.x names it input_schema (1.x: inputSchema)
    schema = getattr(t, "input_schema", None) or getattr(t, "inputSchema", None) or {"type": "object", "properties": {}}
    return {"type": "function", "function": {"name": t.name, "description": t.description or "", "parameters": schema}}


def tool_text(result):
    parts = []
    for c in result.content:
        parts.append(getattr(c, "text", None) or json.dumps(c.model_dump()))
    return "\n".join(parts)


async def run(a):
    pdir, pver, psha = install_plugin(a.plugin)
    servers = json.loads((pdir / "mcp.json").read_text())["mcpServers"]
    skill = next(pdir.glob("skills/*/SKILL.md")).read_text()
    skill_body = skill.split("---", 2)[2].strip() if skill.startswith("---") else skill
    reg = registry_packages()
    step("registry", repo=MCP_REPO, packages=len(reg))

    sessions, tools_by_server = {}, {}
    async with contextlib.AsyncExitStack() as stack:
        for name, spec in servers.items():
            cmd, args = spec["command"], spec.get("args", [])
            dist, ver = distribution_of(cmd, args)
            listed = reg.get(("pypi", norm(dist or ""), ver))
            info = {"server": name, "command": cmd, "args": args, "distribution": dist, "version": ver, "registry_name": listed}
            if not listed:
                step("mcp-refused", **info, reason="not listed in the MCP registry at this version")
                continue
            params = StdioServerParameters(command=cmd, args=args, env={**os.environ})
            r, w = await stack.enter_async_context(stdio_client(params))
            s = await stack.enter_async_context(ClientSession(r, w))
            await s.initialize()
            tools = (await s.list_tools()).tools
            sessions[name], tools_by_server[name] = s, tools
            step("mcp-started", **info, tools=[t.name for t in tools])

        if "sqlite" in sessions:  # the public server: one direct call, no model involved
            res = await sessions["sqlite"].call_tool("get_sqlite_version", {})
            REPORT["sqlite_check"] = tool_text(res)[:200]
            step("sqlite-check", result=REPORT["sqlite_check"])

        model_servers = [s for s in a.model_servers.split(",") if s in sessions]
        tools = [tool_schema(t) for s in model_servers for t in tools_by_server[s]]
        owner = {t.name: s for s in model_servers for t in tools_by_server[s]}
        client = OpenAI(base_url=LLM, api_key="none", timeout=600)
        models = [m.id for m in client.models.list().data]
        step("llm", url=LLM, models=models, tools=[t["function"]["name"] for t in tools])
        msgs = [{"role": "system", "content": skill_body}, {"role": "user", "content": a.question}]
        calls = []
        for turn in range(a.max_turns):
            t1 = time.monotonic()
            resp = client.chat.completions.create(model=models[0], messages=msgs, tools=tools or None, temperature=0)
            m = resp.choices[0].message
            step("llm-turn", turn=turn, seconds=round(time.monotonic() - t1, 1),
                 tool_calls=[c.function.name for c in (m.tool_calls or [])], content=(m.content or "")[:200])
            msgs.append(m.model_dump(exclude_none=True))
            if not m.tool_calls:
                REPORT["answer"] = m.content or ""
                break
            for c in m.tool_calls:
                try:
                    args = json.loads(c.function.arguments or "{}")
                except json.JSONDecodeError:
                    args = {}
                srv = owner.get(c.function.name)
                text = tool_text(await sessions[srv].call_tool(c.function.name, args)) if srv else f"unknown tool {c.function.name}"
                calls.append({"tool": c.function.name, "server": srv, "arguments": args, "result": text[:500]})
                step("tool-call", tool=c.function.name, arguments=args, result=text[:200])
                msgs.append({"role": "tool", "tool_call_id": c.id, "content": text})
        REPORT.update(plugin={"name": a.plugin, "version": pver, "sha256": psha},
                      servers={k: [t.name for t in v] for k, v in tools_by_server.items()},
                      tool_calls=calls, model=models[0])
        REPORT["ok"] = bool(REPORT.get("answer")) and bool(calls)


def main():
    global T0
    ap = argparse.ArgumentParser()
    ap.add_argument("--question", default="How many units of SKU OG-1138 are in the north warehouse?")
    ap.add_argument("--plugin", default="offgrid-ops")
    ap.add_argument("--model-servers", default="acme-inventory")
    ap.add_argument("--max-turns", type=int, default=6)
    a = ap.parse_args()
    T0 = time.monotonic()
    try:
        asyncio.run(run(a))
    except SystemExit as e:
        REPORT["error"] = str(e)
    except Exception as e:  # report, do not hide: the gate reads .error
        REPORT["error"] = f"{type(e).__name__}: {e}"
    REPORT["seconds"] = round(time.monotonic() - T0, 1)
    print(json.dumps(REPORT))
    sys.exit(0 if REPORT["ok"] else 1)


if __name__ == "__main__":
    main()
