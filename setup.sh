#!/usr/bin/env bash
# One-time setup: build the two agent environments and render agent settings.
#
#   envs/without/  = workspace overlay files + the 4 Saleor repos at their pinned commits
#   envs/with/     = exactly the same, PLUS the Claude context files (CLAUDE.md, arch/, .claude/)
#
# Reads SOURCE_WORKSPACE (never writes to it). Idempotent: re-running skips what's built.
#
# Usage: ./setup.sh [--rebuild] [--verify]
#   --rebuild   wipe and rebuild both envs from scratch
#   --verify    after building, run a tiny smoke test per agent (needs credentials; ~1 cent)
source "$(dirname "$0")/lib/common.sh"

REBUILD=0; VERIFY=0
for a in "$@"; do case "$a" in
  --rebuild) REBUILD=1;; --verify) VERIFY=1;;
  -h|--help) sed -n '2,14p' "$0"; exit 0;;
  *) die "unknown arg: $a";; esac; done

# ---- preflight ------------------------------------------------------------------------
for b in claude git python3 tar timeout; do command -v "$b" >/dev/null || die "missing tool: $b"; done
[ -d "$SOURCE_WORKSPACE/.git" ] || die "SOURCE_WORKSPACE is not a git repo: $SOURCE_WORKSPACE"
git -C "$SOURCE_WORKSPACE" rev-parse -q --verify "$SOURCE_REF^{commit}" >/dev/null || die "no ref $SOURCE_REF in source"
mkdir -p "$GEN" "$RUNS" "$AUTH"; chmod 700 "$AUTH"
[ -f "$ACTIVE" ] && kill -0 "$(head -1 "$ACTIVE")" 2>/dev/null && die "An experiment is running; stop it first."

log "Source: $SOURCE_WORKSPACE @ $SOURCE_REF ($(git -C "$SOURCE_WORKSPACE" rev-parse --short "$SOURCE_REF"))"
git -C "$SOURCE_WORKSPACE" show "$SOURCE_REF:children.lock" > "$GEN/children.lock" \
  || die "children.lock not found at $SOURCE_REF"
log "Pinned repos:"; children | sed 's/^/    /'

# ---- build one env --------------------------------------------------------------------
build_overlay() {
  local cond=$1 root="$ENVS/$1"
  if git -C "$root" rev-parse -q --verify baseline >/dev/null 2>&1; then ok "$cond: overlay already built"; return; fi
  mkdir -p "$root"
  git -C "$SOURCE_WORKSPACE" archive "$SOURCE_REF" | tar -x -C "$root"
  ( cd "$root" && shopt -s nullglob && for p in $EXCLUDE_PATHS; do rm -rf -- $p; done )
  if [ "$cond" = without ]; then ( cd "$root" && for p in $CONTEXT_PATHS; do rm -rf -- "$p"; done ); fi
  git -C "$root" init -q -b main
  git -C "$root" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$root" -c user.name=Workspace -c user.email=workspace@localhost -c commit.gpgsign=false \
    commit -q -m "Workspace baseline"
  git -C "$root" tag baseline
  ok "$cond: overlay built ($(git -C "$root" ls-files | wc -l) files)"
}

clone_child() {
  local cond=$1 name=$2 sha=$3 dst="$ENVS/$1/$2"
  if [ "$(git -C "$dst" rev-parse -q --verify 'baseline^{commit}' 2>/dev/null || true)" = "$sha" ]; then
    ok "$cond/$name: already at ${sha:0:10}"; return; fi
  [ -d "$SOURCE_WORKSPACE/$name/.git" ] || die "source repo missing: $SOURCE_WORKSPACE/$name"
  rm -rf "$dst"; git init -q -b main "$dst"
  # Shallow fetch of exactly the pinned commit; no remote is recorded, so nothing points back.
  git -C "$dst" fetch -q --depth 1 \
    --upload-pack="git -c uploadpack.allowAnySHA1InWant=true upload-pack" \
    "file://$SOURCE_WORKSPACE/$name" "$sha"
  git -C "$dst" reset -q --hard FETCH_HEAD
  git -C "$dst" tag baseline
  ok "$cond/$name: cloned at ${sha:0:10}"
}

if [ "$REBUILD" = 1 ]; then
  for c in $CONDITIONS; do log "Wiping envs/$c"; rm -rf "${ENVS:?}/$c"; done
  rm -f "$ENV_OWNER"
fi
for c in $CONDITIONS; do
  log "Building envs/$c"
  build_overlay "$c"
  while read -r name sha; do clone_child "$c" "$name" "$sha"; done < <(children)
done

# ---- render agent settings --------------------------------------------------------------
for c in $CONDITIONS; do
  other=""; for o in $CONDITIONS; do [ "$o" != "$c" ] && other="$o"; done
  python3 -I - "$HARNESS/agent-config/settings.template.json" "$GEN/settings-$c.json" \
    "$HARNESS" "$(dirname "$HARNESS")" "$SOURCE_WORKSPACE" "$HOME" "$ENVS/$other" <<'EOF'
import json, sys
src, dst, harness, parent, source, home, other = sys.argv[1:]
t = open(src).read()
for k, v in {"HARNESS": harness, "PARENT": parent, "SOURCE": source, "HOME": home, "OTHER_ENV": other}.items():
    t = t.replace("{{%s}}" % k, v)
d = json.loads(t); d.pop("$comment", None)
json.dump(d, open(dst, "w"), indent=2)
EOF
  ok "rendered agent-config/generated/settings-$c.json"
done

# ---- verify the envs differ ONLY by the context files ------------------------------------
log "Verifying the only difference between envs is: $CONTEXT_PATHS"
excl=(-x .git); while read -r name _; do excl+=(-x "$name"); done < <(children)
diffs="$(diff -rq "${excl[@]}" "$ENVS/without" "$ENVS/with" | sed "s#$ENVS/##g" || true)"
expected=""; for p in $CONTEXT_PATHS; do expected+="Only in with: $p"$'\n'; done
if [ "$(sort <<<"$diffs")" != "$(sort <<<"${expected%$'\n'}")" ]; then
  printf '%s\n' "$diffs" >&2; die "envs differ in unexpected ways (see above)"
fi
while read -r name sha; do
  for c in $CONDITIONS; do
    [ "$(git -C "$ENVS/$c/$name" rev-parse HEAD)" = "$sha" ] || die "$c/$name not at $sha"
  done
done < <(children)
ok "overlay diff = context files only; all repos at pinned commits in both envs"

# No leftover experiment hints in the overlay files of either env.
hints='plan_with|plan_without|plan_comparison|DEMO-RUNBOOK|EXPERIMENT\.md|no-setup|reset-children|children\.lock|demo take'
for c in $CONDITIONS; do
  if hits="$(cd "$ENVS/$c" && git grep -n -I -E "$hints" -- . 2>/dev/null)"; then
    printf '%s\n' "$hits" >&2; die "experiment hints found in envs/$c overlay"
  fi
done
ok "no experiment hints in either env's overlay"

for c in $CONDITIONS; do reset_env "$c"; done
rm -f "$ENV_OWNER"
ok "both envs clean at baseline"

# ---- credentials --------------------------------------------------------------------------
if [ -s "$AUTH/oauth-token" ] || [ -s "$AUTH/api-key" ]; then
  ok "agent credentials present in $AUTH"
else
  warn "No agent credentials yet. In a separate terminal run:  cd $HARNESS && ./setup-token.sh"
  [ "$VERIFY" = 1 ] && die "cannot --verify without credentials"
fi

# ---- smoke test: each agent sees exactly its own context ---------------------------------
if [ "$VERIFY" = 1 ]; then
  load_auth
  before="$(user_state_fingerprint)"
  q='Answer from your current context only, without using any tools. Do you have project instructions loaded from a CLAUDE.md file? If yes, reply with exactly the first line of those instructions. If no, reply with exactly: NONE'
  vdir="$RUNS/_verify"; rm -rf "$vdir"
  for c in $CONDITIONS; do
    MODEL=haiku TIMEOUT_MIN=3 MAX_BUDGET_USD=1 run_agent "$c" "$vdir/$c" "$vdir/$c/turn" plan "$q" &
  done
  wait
  fail=0
  for c in $CONDITIONS; do
    ans="$(py result-text "$vdir/$c/turn/trace.jsonl" | tr -d '\r' | sed '/^$/d' | head -1)"
    if [ "$c" = with ]; then
      exp="$(head -1 "$ENVS/with/CLAUDE.md")"; [ "$ans" = "$exp" ] || { warn "with: expected '$exp', got '$ans'"; fail=1; }
    else
      [ "$ans" = NONE ] || { warn "$c: expected 'NONE', got '$ans'"; fail=1; }
    fi
    ok "smoke $c → $ans"
  done
  [ "$(user_state_fingerprint)" = "$before" ] || { warn "your ~/.claude state changed during the smoke test!"; fail=1; }
  [ "$fail" = 0 ] || { warn "stderr: $(cat "$vdir"/*/turn/stderr.log 2>/dev/null | grep -v connectors | head -5)"; die "smoke test failed"; }
  rm -rf "$vdir"
  ok "smoke test passed: agents are isolated and see only their own env's context"
fi

ok "Setup complete."
