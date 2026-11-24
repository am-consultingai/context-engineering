#!/usr/bin/env bash
# Stop a running experiment (both agents) and reset the envs to baseline.
# Usage: ./stop.sh [--no-reset]
source "$(dirname "$0")/lib/common.sh"
RESET=1; [ "${1:-}" = "--no-reset" ] && RESET=0

if [ -f "$ACTIVE" ]; then
  pid="$(head -1 "$ACTIVE")"; run="$(sed -n 2p "$ACTIVE")"
  log "stopping run $run (pid $pid)"
  kill "$pid" 2>/dev/null || true
else
  log "no active run recorded"
fi
# Agents are identified by the generated settings file only they use.
if pkill -f -- "--settings $GEN/settings-" 2>/dev/null; then ok "agent processes stopped"; else log "no agent processes running"; fi
sleep 1
rm -f "$ACTIVE"
if [ "$RESET" = 1 ]; then reset_envs; rm -f "$ENV_OWNER"; ok "envs reset to baseline"; fi
