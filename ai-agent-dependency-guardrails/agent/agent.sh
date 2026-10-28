#!/usr/bin/env bash
# Replay the scripted agent session (agent/plan.toml); see agent/agent.py.
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/agent.py" "$@"
