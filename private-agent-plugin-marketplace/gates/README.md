# gates

`run-all.sh [g01 ...]` runs the gates and prints one line per check: `PASS`, `FAIL`,
`BLOCKED(account)` when the check needs a signed-in agent account (the line says what to run
after logging in; G4's runs instead when `CLAUDE_CODE_OAUTH_TOKEN` is set), or `BLOCKED(Fn)` when it needs an Artifact Keeper fix the running backend
does not have (`Fn` is in the walkthrough's findings). Checks assert on status codes, exit
codes and documents, never on message text. Results accumulate in `../out/gates/results.tsv`,
logs in `../out/gates/gNN.log`, durations in `../out/gates/timings.tsv`.

| Gate | Script |
|---|---|
| G1 Auth: 401 / 200 / 403 matrix, cross-repository token, public repository, no credential in a committed file | `g01-auth.sh` |
| G2 Publish rules: 409 on overwrite, 400 for each ambiguous upload, none indexed | `g02-publish-rules.sh` |
| G3 Index contract: Claude Code rules, sha256 of the bytes, membership and latest per harness, ETag and 304, cache headers | `g03-index-contract.sh` |
| G4 Claude Code end to end: settings route, install, the cache equals the zip; with `CLAUDE_CODE_OAUTH_TOKEN`, a signed-in session loads the plugin's command, agent, skills and hook and runs the command | `g04-claude-code.sh` |
| G5 Tampering: a mirror with a changed zip under the genuine sha256; ak and Claude Code refuse | `g05-tampering.sh` |
| G6 Immutability after delete: fall back, 409 for new bytes, 201 for identical bytes | `g06-immutability.sh` |
| G7 Scan gate: block_unscanned hides and refuses until the scan completes | `g07-scan-gate.sh` |
| G8 ak harness installs: locations, plugin-info.json, behind / current / ahead, uninstall | `g08-cli-harnesses.sh` |
| G9 Generic upload: neither indexed nor served by the format | `g09-generic-upload.sh` |
| G10 Token hygiene: the path token redacted in the Caddy and backend logs; where Claude Code stores it | `g10-token-hygiene.sh` |

`mkzip.py` builds deterministic fixture zips (fixed timestamps, sorted entries), including
entries `zip` will not write (`../escape.md`, a symbolic link). Gates G2, G3, G6, G7, G8 and G9
work in scratch repositories (`agent-plugins-gate-gN`) that they delete and recreate on every
run; G1, G3, G4, G5 and G10 read the walkthrough's own repositories and the homes `make
consume-claude` left in `out/homes/`, so run `make all` first. G5 serves its tampered mirror
from `registry/out/mirror/`, which Caddy publishes as `https://mirror.internal`.
