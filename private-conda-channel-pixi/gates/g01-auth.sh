#!/usr/bin/env bash
# G1 Auth: `pixi auth login ak.internal --token` and RATTLER_AUTH_FILE both work;
# pixi.toml / pixi.lock carry no credentials; a token in the URL is accepted
# (conda /t/<token>/ layouts) while the docs use the header form.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G1
CH=https://ak.internal/conda/conda-internal

# 1. RATTLER_AUTH_FILE
out=$(in_client "$NET" consumer pixi search -p linux-64 -c "$CH" acme-core 2>&1); echo "$out" | grep -E 'acme-core|Version|Error' | head -5
if grep -q 'acme-core' <<<"$out" && ! grep -qi 'error' <<<"$out"; then pass $G "RATTLER_AUTH_FILE (consumer token) reads $CH"
else fail $G "RATTLER_AUTH_FILE" "$(tail -2 <<<"$out")"; fi

# 2. pixi auth login (credential store in the container's home), no auth file
out=$(podman run --rm --network "$NET" -e T="$(tok consumer)" "$CLIENT" sh -c \
  'pixi auth login ak.internal --token "$T" >/dev/null 2>&1 && ls ~/.rattler 2>/dev/null; pixi search -p linux-64 -c '"$CH"' acme-core 2>&1' 2>&1)
echo "$out" | grep -vE '^ WARN' | head -6
if grep -q 'acme-core' <<<"$out" && ! grep -qi 'error' <<<"$out"; then pass $G "pixi auth login ak.internal --token, then pixi search"
else fail $G "pixi auth login" "$(tail -2 <<<"$out")"; fi

# 3. without credentials the channel is closed
out=$(in_client "$NET" - pixi search -p linux-64 -c "$CH" acme-core 2>&1); echo "$out" | grep -iE 'error|401|unauth' | head -3
if grep -qiE '401|unauthori' <<<"$out"; then pass $G "no credentials -> 401"; else fail $G "no credentials" "$(tail -1 <<<"$out")"; fi

# 4. no credentials in manifests or locks
leak=0
for f in "$ROOT"/project*/pixi.toml "$ROOT"/project*/pixi.lock; do
  [[ -f "$f" ]] || continue
  for t in "$TOKENS"/*.token; do grep -qF "$(<"$t")" "$f" && { echo "token $(basename "$t") found in $f"; leak=1; }; done
  grep -nE '://[^/@ ]+:[^/@ ]+@|/t/[A-Za-z0-9_-]{8,}/|BearerToken|password' "$f" && { echo "credential-like string in $f"; leak=1; }
done
((leak)) && fail $G "no credentials in pixi.toml / pixi.lock" "see log" || pass $G "no credentials in pixi.toml / pixi.lock (grep for every token, userinfo, /t/<token>/)"

# 5. header in the access log (Caddy redacts the value; presence and scheme are what matter)
t0=$(date +%s); in_client "$NET" consumer pixi search -p linux-64 -c "$CH" acme-core >/dev/null 2>&1
access_since "$t0" | grep conda-internal | head -3
if access_since "$t0" | grep conda-internal | awk -F'\t' '$4 != "-"' | grep -q .; then pass $G "requests carry an Authorization header (access log)"
else fail $G "Authorization header in access log" "none seen"; fi

# 6. token in the URL
c=$(http GET "https://ak.internal:${HTTPS_PORT}/conda/t/$(tok consumer)/conda-internal/noarch/repodata.json" -)
echo "GET /conda/t/<token>/conda-internal/noarch/repodata.json -> $c"
[[ $c == 200 ]] && pass $G "token in URL, Artifact Keeper layout /conda/t/<token>/<repo>/" || fail $G "token in URL /conda/t/<token>/" "HTTP $c"
c=$(http GET "https://ak.internal:${HTTPS_PORT}/t/$(tok consumer)/conda/conda-internal/noarch/repodata.json" -)
echo "GET /t/<token>/conda/conda-internal/noarch/repodata.json -> $c $(head -c 120 "$SP_TMP/body")"
if [[ $c == 200 ]]; then pass $G "token in URL, rattler layout /t/<token>/conda/<repo>/"
else blocked F11 $G "token in URL, rattler layout /t/<token>/conda/<repo>/" "HTTP $c"; fi
