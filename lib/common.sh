# Shared helpers for the experiment scripts. Source, don't execute.
set -euo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="$HARNESS/runs"
# Agent credentials live outside the repo (never committed). Override with CE_AUTH_DIR.
AUTH="${CE_AUTH_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/context-engineering}"
GEN="$HARNESS/agent-config/generated"
LIB="$HARNESS/lib"
ACTIVE="$RUNS/.active"          # lock file while a run/continue is in progress
ENV_OWNER="$RUNS/.owner"        # which run/repeat the envs' current state belongs to
LABELS="$GEN/labels.env"        # condition -> neutral env label (never shown to agents)

# shellcheck source=/dev/null
source "$HARNESS/experiment.env"
case "$TASK_FILE" in /*) ;; *) TASK_FILE="$HARNESS/$TASK_FILE";; esac

# ---- env locations: neutral paths outside the harness ---------------------------------
# env_label <cond>  -> random hex label   env_dir <cond> -> $LAB_ROOT/<label>
# env_root <cond>   -> the workspace the agent works in (cwd)
# env_home <cond>   -> the agent's private CLAUDE_CONFIG_DIR for the current run
env_label() {
  [ -f "$LABELS" ] || die "labels missing; run ./setup.sh"
  local v; v="$(grep -E "^$1=" "$LABELS" | cut -d= -f2)"; [ -n "$v" ] || die "no label for '$1'"
  printf '%s' "$v"
}
env_dir()  { printf '%s/%s' "$LAB_ROOT" "$(env_label "$1")"; }
env_root() { printf '%s/saleor-workspace' "$(env_dir "$1")"; }
env_home() { printf '%s/home' "$(env_dir "$1")"; }

log()  { printf '▸ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

py() { python3 -I "$LIB/analyze.py" "$@"; }

# children.lock captured at setup time: "<name> <sha> <branch>" per line.
children() { grep -v '^[[:space:]]*#' "$GEN/children.lock" | awk 'NF>=2 {print $1, $2}'; }

require_setup() {
  [ -f "$GEN/children.lock" ] || die "Not set up yet. Run ./setup.sh first."
  for c in $CONDITIONS; do
    [ -f "$GEN/settings-$c.json" ] || die "Missing $GEN/settings-$c.json. Run ./setup.sh."
    git -C "$(env_root "$c")" rev-parse -q --verify baseline >/dev/null 2>&1 || die "env '$c' not built. Run ./setup.sh."
  done
}

# ---- auth: contained, never touches ~/.claude ------------------------------------------
AUTH_ENV=()
load_auth() {
  if [ -s "$AUTH/oauth-token" ]; then
    AUTH_ENV=("CLAUDE_CODE_OAUTH_TOKEN=$(tr -d '[:space:]' < "$AUTH/oauth-token")")
  elif [ -s "$AUTH/api-key" ]; then
    AUTH_ENV=("ANTHROPIC_API_KEY=$(tr -d '[:space:]' < "$AUTH/api-key")")
  else
    die "No agent credentials. Run ./setup-token.sh in a terminal (one time)."
  fi
}

# Minimal PATH for agents: system dirs + wherever the needed tools live. Nothing else inherited.
agent_path() {
  local p="/usr/local/bin:/usr/bin:/bin" b d
  for b in claude git python3 node pnpm npm npx uv docker; do
    d="$(command -v "$b" 2>/dev/null || true)"; [ -n "$d" ] || continue
    d="$(dirname "$d")"; case ":$p:" in *":$d:"*) ;; *) p="$d:$p";; esac
  done
  printf '%s' "$p"
}

# timeout_cmd: prefix that kills a turn after TIMEOUT_MIN minutes (TERM, then KILL 30 s later).
# GNU `timeout` on Linux/WSL, Homebrew's `gtimeout` on macOS if present, else an inline Python
# equivalent (python3 is required anyway). Absolute paths: it runs under `env -i`.
timeout_cmd() {
  local t; t="$(command -v timeout || command -v gtimeout || true)"
  if [ -n "$t" ]; then TIMEOUT_CMD=("$t" --kill-after=30 "${TIMEOUT_MIN}m"); return; fi
  TIMEOUT_CMD=("$(command -v python3)" -c 'import subprocess,sys
ka,t=int(sys.argv[1]),int(sys.argv[2]); p=subprocess.Popen(sys.argv[3:])
try: sys.exit(p.wait(timeout=t))
except subprocess.TimeoutExpired:
    p.terminate()
    try: p.wait(timeout=ka)
    except subprocess.TimeoutExpired: p.kill(); p.wait()
    sys.exit(124)' 30 "$((TIMEOUT_MIN * 60))")
}

# run_agent <cond> <agent_dir> <turn_dir> <mode> <prompt> [resume_session_id]
# Runs one headless claude turn in env_root <cond>, config in env_home <cond> (neutral path).
# After the turn, the config dir is archived to <agent_dir>/claude-config for analysis.
# Start a fresh agent (new run/repeat) with: fresh_home <cond>.
run_agent() {
  local cond=$1 adir=$2 out=$3 mode=$4 prompt=$5 sid=${6:-}
  local cfg; cfg="$(env_home "$cond")"; local pm=plan extra=(); timeout_cmd
  if [ "$mode" = implement ]; then pm=acceptEdits; extra+=(--allowedTools Bash Edit Write); fi
  [ -n "$sid" ] && extra+=(--resume "$sid")
  mkdir -p "$cfg" "$out"
  printf '%s\n' "$prompt" > "$out/prompt.txt"
  date +%s > "$out/started_at"
  set +e
  ( cd "$(env_root "$cond")" && env -i \
      HOME="$HOME" USER="${USER:-agent}" LANG="${LANG:-C.UTF-8}" TERM=dumb PATH="$(agent_path)" \
      CLAUDE_CONFIG_DIR="$cfg" DISABLE_AUTOUPDATER=1 ${AUTH_ENV[@]+"${AUTH_ENV[@]}"} \
      "${TIMEOUT_CMD[@]}" \
      claude -p "$prompt" \
        --model "$MODEL" --permission-mode "$pm" \
        --settings "$GEN/settings-$cond.json" --setting-sources project --strict-mcp-config \
        --max-budget-usd "$MAX_BUDGET_USD" \
        --output-format stream-json --verbose ${extra[@]+"${extra[@]}"} \
      > "$out/trace.jsonl" 2> "$out/stderr.log" )
  echo $? > "$out/exit_code"
  set -e
  date +%s > "$out/ended_at"
  rm -rf "$adir/claude-config"; cp -a "$cfg" "$adir/claude-config"
}

# Wipe an agent's private config so the next turn starts a brand-new session.
fresh_home() { local h; h="$(env_home "$1")"; case "$h" in "$LAB_ROOT"/*) rm -rf "$h";; esac; mkdir -p "$h"; }

# Record what the agent changed (should be nothing in plan mode).
capture_changes() {
  local cond=$1 out=$2 root r name; root="$(env_root "$1")"
  : > "$out/changes.patch"
  for r in "$root" $(children | awk -v R="$root" '{print R"/"$1}'); do
    name="${r#"$root"}"; name="${name#/}"; name="${name:-<overlay>}"
    if [ -n "$(git -C "$r" status --porcelain 2>/dev/null)" ] || \
       [ "$(git -C "$r" rev-parse HEAD)" != "$(git -C "$r" rev-parse baseline)" ]; then
      { echo "### $name"; git -C "$r" status --short; git -C "$r" diff baseline; echo; } >> "$out/changes.patch"
    fi
  done
}

# Reset one env (overlay + children) to its baseline. Only ever touches $LAB_ROOT/<label>.
reset_env() {
  local root r b; root="$(env_root "$1")"
  case "$root" in "$LAB_ROOT"/*/saleor-workspace) ;; *) die "refusing to reset outside $LAB_ROOT";; esac
  for r in "$root" $(children | awk -v R="$root" '{print R"/"$1}'); do
    git -C "$r" checkout -q -f main
    git -C "$r" reset -q --hard baseline
    git -C "$r" clean -q -fd
    for b in $(git -C "$r" for-each-ref --format='%(refname:short)' refs/heads | grep -vx main || true); do
      git -C "$r" branch -q -D "$b"
    done
    git -C "$r" stash clear 2>/dev/null || true
    [ -z "$(git -C "$r" status --porcelain)" ] || die "reset failed for $r"
  done
}
reset_envs() { local c; for c in $CONDITIONS; do reset_env "$c"; done; }

# Fingerprint of the user's own Claude state, to prove the experiment didn't touch it.
user_state_fingerprint() {
  {
    for f in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md"; do
      [ -f "$f" ] && sha256sum "$f" || echo "absent $f"
    done
    ls -d "$HOME"/.claude/projects/*saleor-ws* "$HOME"/.claude/projects/*context-engineering-envs* 2>/dev/null \
      || echo "no-agent-project-dirs"
  }
}

acquire_lock() {
  if [ -f "$ACTIVE" ] && kill -0 "$(head -1 "$ACTIVE")" 2>/dev/null; then
    die "Another experiment is running (pid $(head -1 "$ACTIVE")). Use ./stop.sh to stop it."
  fi
  printf '%s\n%s\n' "$$" "$1" > "$ACTIVE"
  trap 'rm -f "$ACTIVE"' EXIT
}

# Written by setup: env layout marker + each condition's child-repo baseline commits.
BUILD_INFO="$GEN/build.env"
