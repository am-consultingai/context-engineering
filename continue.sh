#!/usr/bin/env bash
# Send the SAME follow-up message to both agents of the latest run (resuming their
# sessions), so you can steer the experiment turn by turn and keep it fair.
#
# Usage: ./continue.sh [--mode plan|implement] "message"
#   --mode   defaults to the run's mode. Use implement to let agents edit + run commands.
# Only the run whose state the envs currently hold can be continued (see envs/.owner).
source "$(dirname "$0")/lib/common.sh"

MODE_OVERRIDE=""
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE_OVERRIDE=$2; shift 2;;
  -h|--help) sed -n '2,8p' "$0"; exit 0;;
  --) shift; break;;
  -*) die "unknown arg: $1";;
  *) break;; esac; done
MSG="${*:-}"
[ -n "$MSG" ] || die "usage: ./continue.sh [--mode plan|implement] \"message\""

require_setup
load_auth
[ -f "$ENV_OWNER" ] || die "No run to continue (envs were reset). Start one with ./run.sh."
REP="$(cat "$ENV_OWNER")"; RUN="$(dirname "$REP")"
[ -f "$RUN/meta.json" ] || die "run folder missing: $RUN"
MODEL="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["model"])' "$RUN/meta.json")"
MODE="${MODE_OVERRIDE:-$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["mode"])' "$RUN/meta.json")}"
case "$MODE" in plan|implement) ;; *) die "--mode must be plan or implement";; esac

acquire_lock "$RUN"
log "continuing $REP  (model $MODEL, mode $MODE)"
log "message to BOTH agents: $MSG"
before="$(user_state_fingerprint)"

for c in $CONDITIONS; do
  adir="$REP/$c"
  [ -s "$adir/session_id" ] || die "no session id for '$c' in $adir"
  last="$(ls "$adir/turns" | sort -n | tail -1)"; k=$((last + 1))
  (
    tdir="$adir/turns/$k"
    run_agent "$c" "$adir" "$tdir" "$MODE" "$MSG" "$(cat "$adir/session_id")"
    capture_changes "$c" "$tdir"
    py turn --trace "$tdir/trace.jsonl" --agent-dir "$adir" --env-root "$ENVS/$c" \
      --harness "$HARNESS" --source "$SOURCE_WORKSPACE" --mode "$MODE" --out "$tdir"
  ) &
  log "  agent '$c' turn $k (pid $!)"
done
wait

after="$(user_state_fingerprint)"
[ "$before" = "$after" ] || { echo "CHANGED during continue — investigate!" >> "$RUN/user-state-check.txt"; warn "your ~/.claude state changed!"; }
echo
py summary "$RUN"
