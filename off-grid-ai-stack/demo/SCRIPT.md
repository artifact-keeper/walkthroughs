# Demo script: the off-grid AI stack

A 2 to 3 minute video. Every terminal beat is an asciicast in [`casts/`](casts/), recorded by
[`record.sh`](record.sh) (each command printed after a prompt by [`beat.sh`](beat.sh), pauses
longer than 1.2 s cut to 1.2 s by [`rec.py`](rec.py)). Every screenshot is in
[`../../docs/off-grid-ai-stack/images/`](../../docs/off-grid-ai-stack/images/). All assets
come from one full-size run (Qwen2.5-1.5B) from a fresh clone at `de0597c`, on the CI images of
Artifact Keeper `main` at `88f23c51`, left up and disconnected on `grace` for live capture. It is
a third run from that clone, after the two reference runs; its numbers differ slightly from the
[results](../../docs/off-grid-ai-stack/results.md) (for example its ledger had 22 connections at
the cut, the reference run 24).

Play a cast with `asciinema play casts/<name>.cast`, or embed it with asciinema-player. To
record them again: `demo/record.sh` (it starts with `make clean`, runs the whole walkthrough
and `make gates`, records the five beats and takes the screenshots).

| # | Beat | Asset (length) | Voiceover | Command on screen |
|---|---|---|---|---|
| 1 | Cold open | [`s01-repositories.png`](../../docs/off-grid-ai-stack/images/s01-repositories.png) | "One Artifact Keeper instance serves a whole AI stack: the model, its container images, every Python and npm package, the MCP servers and the agent's plugin." | none |
| 2 | Seed | [`a-seed.cast`](casts/a-seed.cast) (13 s) | "While the site is still connected, one command pulls everything on the manifest through the registry: images by digest, the model at a commit, one public MCP server by name and version." | `make seed` |
| 3 | Vet | [`s02-hf-models.png`](../../docs/off-grid-ai-stack/images/s02-hf-models.png), then [`s08-scan-pickle.png`](../../docs/off-grid-ai-stack/images/s08-scan-pickle.png) | "The model goes into a vetted repository that scans every file. A truncated GGUF and a pickle that calls os.system are quarantined; the model is served." | `make vet` (not recorded) |
| 4 | What the agent may run | [`s03-mcp-gallery.png`](../../docs/off-grid-ai-stack/images/s03-mcp-gallery.png), then [`s06-mcp-server-security.png`](../../docs/off-grid-ai-stack/images/s06-mcp-server-security.png) | "Two MCP servers are approved: Acme's own, hosted, and one from the official registry. The agent starts only what this registry lists, at the listed version." | none |
| 5 | Disconnect | [`b-disconnect.cast`](casts/b-disconnect.cast) (33 s) | "The cut: upstream jobs paused, every Remote cache-only, and the whole stack recreated on a network with no default route and no NAT." | `make disconnect` |
| 6 | The agent, offline | [`c-agent.cast`](casts/c-agent.cast) (10 s) | "On the disconnected site, a local 1.5B model calls the inventory tool and answers: 42 units of OG-1138 in the north warehouse, with the tool's reference." | `make agent` |
| 7 | Fails safely | [`e-fails-safely.cast`](casts/e-fails-safely.cast) (9 s) | "What was not vetted is refused. What was not seeded is a 404 in milliseconds, and a request to seed or sync on the site is a 409." | `gates/g02-vet.sh \| grep -E "truncated\|pickle\|GGUF"`, then `gates/g06-fails-safely.sh` |
| 8 | Zero egress | [`d-zero-egress.cast`](casts/d-zero-egress.cast) (12 s), then [`s09-audit-upstream-fetched.png`](../../docs/off-grid-ai-stack/images/s09-audit-upstream-fetched.png) | "No container has a route out. The egress ledger and the audit log saw nothing leave after the cut. The control proves they would: we open one hole, the attempt shows up in both, we seal it." | `gates/g07-zero-egress.sh` |
| 9 | Close | the gate summary from [results](../../docs/off-grid-ai-stack/results.md), or [`s11-plugins-central.png`](../../docs/off-grid-ai-stack/images/s11-plugins-central.png) | "73 checks, 73 passes, from an empty registry in about eleven minutes. Everything is in the walkthrough, and `make all` reproduces it." | `make gates` |

Running time: the five casts are 77 s together (13.4 + 32.8 + 9.8 + 8.9 + 11.6 s); with about
8 s on each of the seven screenshots, the video is about 2 min 15 s.

Notes for the edit:

- Beat 5's cast spends most of its 33 s on compose recreating the containers; speed it up or cut
  to the end, where every container is listed on `ak-offgrid-site`.
- Beat 6: hold on the two `llm-turn` lines and the `tool-call` line
  (`stock_level`, `{"sku": "OG-1138", "warehouse": "north"}`, `"units": 42`).
- Beat 8: hold on `ledger: 22 connections at the disconnect, 23 now; opened since then: 1, of
  them outside control windows: 0` and on the three `control:` lines. The one connection
  since the cut is the control of the first gate run on that stack, inside its recorded
  window; the audit log screenshot shows the same attempt at 5:46:11. Say so if you show the
  number.
- Do not claim more than the walkthrough does: "nothing leaves" is shown for this lab's
  containers on this lab's network, and the model scanner reads file structure, not model
  behaviour.
