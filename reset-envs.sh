#!/usr/bin/env bash
# Reset both envs (overlay + all child repos) to their baseline. Touches only envs/.
# Usage: ./reset-envs.sh
source "$(dirname "$0")/lib/common.sh"
require_setup
if [ -f "$ACTIVE" ] && kill -0 "$(head -1 "$ACTIVE")" 2>/dev/null; then die "an experiment is running; use ./stop.sh"; fi
reset_envs
rm -f "$ENV_OWNER"
ok "envs reset to baseline: $CONDITIONS"
