#!/usr/bin/env bash
# Install the nightly runner for this user: the runner in ~/ak-e2e/runner, the systemd user
# units in ~/.config/systemd/user, a config in ~/.config/ak-e2e/config.env (if none yet).
# Does NOT enable the timer: see e2e/README.md ("Enable the timer").
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${E2E_HOME:-$HOME/ak-e2e}/runner"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ak-e2e"
mkdir -p "$RUNNER" "$UNITS"
install -m 755 "$HERE/ak_e2e.py" "$RUNNER/ak_e2e.py"
install -m 644 "$HERE/walkthroughs.toml" "$HERE/README.md" "$RUNNER/"
install -m 644 "$HERE/systemd/ak-e2e.service" "$HERE/systemd/ak-e2e.timer" "$UNITS/"
install -d -m 700 "$CONF"
[[ -f "$CONF/config.env" ]] || install -m 600 "$HERE/config.example.env" "$CONF/config.env"
systemctl --user daemon-reload
echo "installed: $RUNNER, $UNITS/ak-e2e.{service,timer}, $CONF/config.env"
echo "timer: $(systemctl --user is-enabled ak-e2e.timer 2>/dev/null || true) (enable with: systemctl --user enable --now ak-e2e.timer)"
