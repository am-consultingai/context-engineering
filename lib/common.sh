# Shared helpers for the experiment scripts. Source, don't execute.
set -euo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVS="$HARNESS/envs"
RUNS="$HARNESS/runs"
# Agent credentials live outside the repo (never committed). Override with CE_AUTH_DIR.
AUTH="${CE_AUTH_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/context-engineering}"
GEN="$HARNESS/agent-config/generated"
LIB="$HARNESS/lib"
ACTIVE="$RUNS/.active"          # lock file while a run/continue is in progress
ENV_OWNER="$ENVS/.owner"        # which run/repeat the envs' current state belongs to

# shellcheck source=/dev/null
source "$HARNESS/experiment.env"

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
    git -C "$ENVS/$c" rev-parse -q --verify baseline >/dev/null 2>&1 || die "env '$c' not built. Run ./setup.sh."
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

# run_agent <cond> <agent_dir> <turn_dir> <mode> <prompt> [resume_session_id]
# Runs one headless claude turn inside envs/<cond> with a private config dir.
run_agent() {
  local cond=$1 adir=$2 out=$3 mode=$4 prompt=$5 sid=${6:-}
  local cfg="$adir/claude-config" pm=plan extra=()
  if [ "$mode" = implement ]; then pm=acceptEdits; extra+=(--allowedTools Bash Edit Write); fi
  [ -n "$sid" ] && extra+=(--resume "$sid")
  mkdir -p "$cfg" "$out"
  printf '%s\n' "$prompt" > "$out/prompt.txt"
  date +%s > "$out/started_at"
  set +e
  ( cd "$ENVS/$cond" && env -i \
      HOME="$HOME" USER="${USER:-agent}" LANG="${LANG:-C.UTF-8}" TERM=dumb PATH="$(agent_path)" \
      CLAUDE_CONFIG_DIR="$cfg" DISABLE_AUTOUPDATER=1 "${AUTH_ENV[@]}" \
      timeout --kill-after=30 "${TIMEOUT_MIN}m" \
      claude -p "$prompt" \
        --model "$MODEL" --permission-mode "$pm" \
        --settings "$GEN/settings-$cond.json" --setting-sources project --strict-mcp-config \
        --max-budget-usd "$MAX_BUDGET_USD" \
        --output-format stream-json --verbose "${extra[@]}" \
      > "$out/trace.jsonl" 2> "$out/stderr.log" )
  echo $? > "$out/exit_code"
  set -e
  date +%s > "$out/ended_at"
}

# Record what the agent changed (should be nothing in plan mode).
capture_changes() {
  local cond=$1 out=$2 root="$ENVS/$1" r name
  : > "$out/changes.patch"
  for r in "$root" $(children | awk -v R="$root" '{print R"/"$1}'); do
    name="${r#"$root"}"; name="${name#/}"; name="${name:-<overlay>}"
    if [ -n "$(git -C "$r" status --porcelain 2>/dev/null)" ] || \
       [ "$(git -C "$r" rev-parse HEAD)" != "$(git -C "$r" rev-parse baseline)" ]; then
      { echo "### $name"; git -C "$r" status --short; git -C "$r" diff baseline; echo; } >> "$out/changes.patch"
    fi
  done
}

# Reset one env (overlay + children) to its baseline. Only ever touches envs/<cond>.
reset_env() {
  local root="$ENVS/$1" r b
  case "$root" in "$ENVS"/*) ;; *) die "refusing to reset outside $ENVS";; esac
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
    ls -d "$HOME"/.claude/projects/*context-engineering-envs* 2>/dev/null || echo "no-agent-project-dirs"
  }
}

acquire_lock() {
  if [ -f "$ACTIVE" ] && kill -0 "$(head -1 "$ACTIVE")" 2>/dev/null; then
    die "Another experiment is running (pid $(head -1 "$ACTIVE")). Use ./stop.sh to stop it."
  fi
  printf '%s\n%s\n' "$$" "$1" > "$ACTIVE"
  trap 'rm -f "$ACTIVE"' EXIT
}
