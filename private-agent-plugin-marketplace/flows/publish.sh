#!/usr/bin/env bash
# Publish the three plugins to agent-plugins as CI would, with the ci token:
#   acme-review, acme-release-notes   ak agent plugins publish <dir> --repo agent-plugins
#   acme-standards                    a zip built with `zip` and sent with plain curl -T
# and acme-release-notes to agent-plugins-public (public-ci token). A version that is
# already published is skipped (versions are immutable). Then waits until the scan policy
# lets each version through, and prints the Claude Code commands.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ak_publish() { # repo token plugin
  local repo=$1 token=$2 p=$3
  say "ak agent plugins publish /plugins/$p --repo $repo"
  if published "$repo" "$p" 1.0.0; then echo "  $p 1.0.0 is already in $repo (versions are immutable): skipped"; return; fi
  "$RUN" -t "$token" -- ak agent plugins publish "/plugins/$p" --repo "$repo" | tee "$FOUT/publish-$repo-$p.txt"
}

say "dry run: what ak would upload for acme-review"
"$RUN" -t ci -- ak agent plugins publish /plugins/acme-review --repo "$REPO" --dry-run

ak_publish "$REPO" ci acme-review
ak_publish "$REPO" ci acme-release-notes

say "curl -T: acme-standards, the zip built with zip"
if published "$REPO" acme-standards 1.0.0; then echo "  acme-standards 1.0.0 is already in $REPO: skipped"; else
  "$RUN" -t ci -- bash -c '
    set -euo pipefail
    cd /plugins/acme-standards && zip -qrX /tmp/acme-standards-1.0.0.zip .
    sha=$(sha256sum /tmp/acme-standards-1.0.0.zip | cut -d" " -f1)
    echo "\$ curl -T acme-standards-1.0.0.zip -H \"Authorization: Bearer \$AK_TOKEN\" -H \"X-Checksum-Sha256: $sha\" \\"
    echo "    https://ak.internal/agentplugins/agent-plugins/acme-standards/1.0.0/acme-standards-1.0.0.zip"
    curl -sS -T /tmp/acme-standards-1.0.0.zip -H "Authorization: Bearer $AK_TOKEN" -H "X-Checksum-Sha256: $sha" \
      -o /tmp/resp.json -w "HTTP %{http_code}\n" \
      https://ak.internal/agentplugins/agent-plugins/acme-standards/1.0.0/acme-standards-1.0.0.zip
    jq . /tmp/resp.json' | tee "$FOUT/publish-$REPO-acme-standards.txt"
fi

ak_publish "$PUBLIC_REPO" public-ci acme-release-notes

say "waiting for the scans (policy agent-plugins-release: block_unscanned)"
for p in acme-review acme-release-notes acme-standards; do wait_listed "$REPO" "$p" 1.0.0; done
wait_listed "$PUBLIC_REPO" acme-release-notes 1.0.0 60

say "Point Claude Code at the repository"
mp=$(akcurl -fsS -H "Authorization: Bearer $(tok developer)" "$U/agentplugins/$REPO/claude-marketplace.json" | jq -r .name)
cat <<EOT
  public:   claude plugin marketplace add https://ak.internal/agentplugins/$PUBLIC_REPO/claude-marketplace.json
  private:  claude plugin marketplace add https://ak.internal/agentplugins/t/<read-token>/$REPO/claude-marketplace.json
            (or extraKnownMarketplaces with an Authorization header: make consume-claude)
  then:     claude plugin install acme-review@$mp
EOT
