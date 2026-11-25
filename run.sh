#!/usr/bin/env bash
# Run the experiment: reset both envs, launch one agent per env in parallel on the same
# task, collect plans/metrics/leak audit, and prepare a BLIND packet (plans as A/B).
# Metrics are written to summary.md but not printed: score the blind packet first, then
# run ./unblind.sh to reveal which plan was which and see the metrics.
#
# Usage: ./run.sh [--model M] [--mode plan|implement] [--runs N] [--task FILE] [--timeout MIN] [--budget USD]
#   defaults come from experiment.env (model=claude-haiku-5-5, mode=plan, runs=1, task=task/prompt.txt)
source "$(dirname "$0")/lib/common.sh"

while [ $# -gt 0 ]; do case "$1" in
  --model) MODEL=$2; shift 2;;
  --mode) MODE=$2; shift 2;;
  --runs) RUNS_PER_EXPERIMENT=$2; shift 2;;
  --task) TASK_FILE=$2; shift 2; case "$TASK_FILE" in /*) ;; *) TASK_FILE="$PWD/$TASK_FILE";; esac;;
  --timeout) TIMEOUT_MIN=$2; shift 2;;
  --budget) MAX_BUDGET_USD=$2; shift 2;;
  -h|--help) sed -n '2,9p' "$0"; exit 0;;
  *) die "unknown arg: $1";; esac; done
case "$MODE" in plan|implement) ;; *) die "--mode must be plan or implement";; esac
[[ "$RUNS_PER_EXPERIMENT" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer"

require_setup
load_auth
[ -s "$TASK_FILE" ] || die "task file missing or empty: $TASK_FILE"
TASK="$(cat "$TASK_FILE")"

RUN="$RUNS/$(date +%Y%m%d-%H%M%S)-${MODEL//[^A-Za-z0-9.-]/_}-$MODE"
acquire_lock "$RUN"
mkdir -p "$RUN"
printf '%s\n' "$TASK" > "$RUN/task.txt"
python3 -I - "$RUN/meta.json" <<EOF
import json, sys
json.dump({
  "model": "$MODEL", "mode": "$MODE", "repeats": $RUNS_PER_EXPERIMENT,
  "task_file": "${TASK_FILE#"$HARNESS/"}",
  "conditions": "$CONDITIONS".split(), "context_paths": "$CONTEXT_PATHS",
  "design": "all-vs-none",
  "source_ref": "$SOURCE_REF", "source_sha": "$(git -C "$SOURCE_WORKSPACE" rev-parse "$SOURCE_REF")",
  "timeout_min": $TIMEOUT_MIN, "budget_usd": $MAX_BUDGET_USD,
  "started": "$(date +%Y-%m-%dT%H:%M:%S%z)",
}, open(sys.argv[1], "w"), indent=2)
EOF
ln -sfn "$(basename "$RUN")" "$RUNS/latest"

echo "================================ TASK ================================"
printf '%s\n' "$TASK"
echo "======================================================================"
log "task file:  ${TASK_FILE#"$HARNESS/"}"
log "run:        $RUN"
log "model:      $MODEL   mode: $MODE   repeats: $RUNS_PER_EXPERIMENT"
log "conditions: $CONDITIONS"
log "design:     without = no context at all; with = pack + repos' own agent docs"
[ "$MODE" = implement ] && warn "implement mode: agents may edit their env and run shell commands."

before="$(user_state_fingerprint)"

for r in $(seq 1 "$RUNS_PER_EXPERIMENT"); do
  log "repeat $r/$RUNS_PER_EXPERIMENT: resetting envs to baseline"
  reset_envs
  for c in $CONDITIONS; do fresh_home "$c"; done
  echo "$RUN/r$r" > "$ENV_OWNER"
  for c in $CONDITIONS; do
    (
      adir="$RUN/r$r/$c"; tdir="$adir/turns/1"
      run_agent "$c" "$adir" "$tdir" "$MODE" "$TASK"
      capture_changes "$c" "$tdir"
      py turn --trace "$tdir/trace.jsonl" --agent-dir "$adir" --env-root "$(env_root "$c")" \
        --cfg-dir "$(env_home "$c")" --lab-root "$LAB_ROOT" \
        --harness "$HARNESS" --source "$SOURCE_WORKSPACE" --mode "$MODE" --out "$tdir"
    ) &
    log "  launched agent '$c' (pid $!)"
  done
  wait
done

after="$(user_state_fingerprint)"
if [ "$before" = "$after" ]; then
  echo "UNCHANGED — ~/.claude/settings.json, ~/.claude/CLAUDE.md and ~/.claude/projects were not touched by the agents." > "$RUN/user-state-check.txt"
else
  { echo "CHANGED — investigate!"; diff <(echo "$before") <(echo "$after"); } > "$RUN/user-state-check.txt"
fi
python3 -I -c "import json,sys,datetime; p=sys.argv[1]; d=json.load(open(p)); d['finished']=datetime.datetime.now().astimezone().isoformat(timespec='seconds'); json.dump(d,open(p,'w'),indent=2)" "$RUN/meta.json"

py summary "$RUN" --quiet
echo
py blind "$RUN"
echo
ok "Done. Results: $RUN"
log "Next: score runs/$(basename "$RUN")/blind/*/{A,B}.md with rubric.md, then ./unblind.sh"
