#!/usr/bin/env bash
# One-time setup: build the two agent environments and render agent settings.
#
#   without = NO context: workspace overlay + the 4 Saleor repos at their pinned commits, with
#             the repos' own agent docs (UPSTREAM_AGENT_DOCS) removed and no context pack
#   guided  = ALL context: the repos as pinned with their own agent docs (minus the
#             FLAWED_UPSTREAM_DOCS, with UPSTREAM_DOC_PATCHES applied) PLUS the workspace context
#             pack (CLAUDE.md, arch/, .claude/) PLUS agent-config/guidance.md in CLAUDE.md
#   with    = (optional) guided without the guidance block
#
# Each env lives at $LAB_ROOT/<random label>/saleor-workspace (outside this harness, neutral
# names) so nothing in an agent's paths reveals the experiment or its condition. The
# label->condition map is in agent-config/generated/labels.env.
#
# Downloads the Saleor workspace + pinned repos into a cache on first run (or reads a local
# SOURCE_WORKSPACE you point it at, never writing to it). Idempotent: re-running skips what's built.
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
for b in claude git python3 tar od diff comm; do command -v "$b" >/dev/null || die "missing tool: $b"; done

# ---- source workspace -------------------------------------------------------------------
# Download (into the managed cache) whatever is missing: the workspace at SOURCE_REF and each
# child repo's pinned commit. Never touches a user-provided SOURCE_WORKSPACE.
fetch_commit() {  # <dir> <url> <ref>: shallow-fetch exactly <ref> into <dir> (created if needed)
  mkdir -p "$1"; [ -d "$1/.git" ] || git -C "$1" init -q
  git -C "$1" fetch -q --depth 1 "$2" "$3" || die "could not download $3 from $2"
  git -C "$1" rev-parse -q --verify "$3^{commit}" >/dev/null 2>&1 || git -C "$1" branch -f "$3" FETCH_HEAD
}
if [ "$SOURCE_WORKSPACE" = "$MANAGED_SOURCE" ]; then
  if ! git -C "$SOURCE_WORKSPACE" rev-parse -q --verify "$SOURCE_REF^{commit}" >/dev/null 2>&1; then
    log "Downloading the Saleor workspace ($SOURCE_REPO_URL @ ${SOURCE_REF:0:10}) into $SOURCE_WORKSPACE"
    fetch_commit "$SOURCE_WORKSPACE" "$SOURCE_REPO_URL" "$SOURCE_REF"
  fi
  while read -r name sha; do
    git -C "$SOURCE_WORKSPACE/$name" cat-file -e "$sha^{commit}" 2>/dev/null && continue
    log "Downloading $name @ ${sha:0:10} (shallow; may take a minute)"
    fetch_commit "$SOURCE_WORKSPACE/$name" "$CHILD_REPO_URL_BASE/$name.git" "$sha"
  done < <(git -C "$SOURCE_WORKSPACE" show "$SOURCE_REF:children.lock" | grep -v '^[[:space:]]*#' | awk 'NF>=2 {print $1, $2}')
fi
[ -d "$SOURCE_WORKSPACE/.git" ] || die "SOURCE_WORKSPACE is not a git repo: $SOURCE_WORKSPACE (unset it to let setup download the workspace)"
git -C "$SOURCE_WORKSPACE" rev-parse -q --verify "$SOURCE_REF^{commit}" >/dev/null || die "no ref $SOURCE_REF in $SOURCE_WORKSPACE (unset SOURCE_WORKSPACE to let setup download it)"
mkdir -p "$GEN" "$RUNS" "$AUTH"; chmod 700 "$AUTH"
[ -f "$ACTIVE" ] && kill -0 "$(head -1 "$ACTIVE")" 2>/dev/null && die "An experiment is running; stop it first."

log "Source: $SOURCE_WORKSPACE @ $SOURCE_REF ($(git -C "$SOURCE_WORKSPACE" rev-parse --short "$SOURCE_REF"))"
git -C "$SOURCE_WORKSPACE" show "$SOURCE_REF:children.lock" > "$GEN/children.lock" \
  || die "children.lock not found at $SOURCE_REF"
log "Pinned repos:"; children | sed 's/^/    /'

# Layout id: envs built from a different source commit / doc fixes / guidance must be rebuilt.
# (git hash-object = a portable content hash; sha1sum isn't on macOS.)
docfix_hash="$( { cat "$HARNESS/$UPSTREAM_DOC_PATCHES"/*.patch "$HARNESS/agent-config/guidance.md" 2>/dev/null || true; } | git hash-object --stdin | cut -c1-12)"
LAYOUT="all-vs-none;src=${SOURCE_REF:0:12};flawed=${FLAWED_UPSTREAM_DOCS// /,};docfix=$docfix_hash"
for e in $FLAWED_UPSTREAM_DOCS; do
  [[ " $UPSTREAM_AGENT_DOCS " == *" $e "* ]] || die "FLAWED_UPSTREAM_DOCS entry '$e' is not in UPSTREAM_AGENT_DOCS"
done

# ---- neutral labels -------------------------------------------------------------------
if [ "$REBUILD" = 1 ] && [ -f "$LABELS" ]; then
  # Every env in the label file, including conditions no longer in CONDITIONS (no orphans left behind).
  for c in $(cut -d= -f1 "$LABELS" | sort -u) $CONDITIONS; do
    d="$(env_dir "$c" 2>/dev/null || true)"; [ -n "$d" ] || continue
    case "$d" in "$LAB_ROOT"/?*) [ -e "$d" ] && { log "Wiping env '$c'"; rm -rf "$d"; };; esac
  done
  rm -f "$LABELS" "$ENV_OWNER" "$BUILD_INFO"
fi
# Envs built by an older harness version (different layout) must be rebuilt, not patched.
if [ -f "$LABELS" ] && ! grep -qx "LAYOUT=$LAYOUT" "$BUILD_INFO" 2>/dev/null; then
  die "envs were built by an older harness version; run: ./setup.sh --rebuild"
fi
log "Conditions: $CONDITIONS. 'without' = code only (no pack, repos' own agent docs removed); 'with'/'guided' = pack + repos' own docs, with doc fixes applied ('guided' also gets agent-config/guidance.md)"
[ -f "$LABELS" ] || : > "$LABELS"
for c in $CONDITIONS; do
  grep -q "^$c=" "$LABELS" && continue
  while :; do l="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"; grep -q "=$l$" "$LABELS" || break; done
  echo "$c=$l" >> "$LABELS"; ok "assigned neutral env label for '$c' (agent-config/generated/labels.env)"
done
mkdir -p "$LAB_ROOT"

# Migrate envs built by an older version of this harness (inside ./envs) instead of re-cloning.
if [ -d "$HARNESS/envs" ]; then
  for c in $CONDITIONS; do
    if [ -d "$HARNESS/envs/$c" ] && [ ! -e "$(env_root "$c")" ]; then
      mkdir -p "$(env_dir "$c")"; mv "$HARNESS/envs/$c" "$(env_root "$c")"; ok "moved old envs/$c under $LAB_ROOT"
    fi
  done
  rm -f "$HARNESS/envs/.owner"; rmdir "$HARNESS/envs" 2>/dev/null || warn "old $HARNESS/envs not empty; left in place"
fi

# ---- build one env --------------------------------------------------------------------
build_overlay() {
  local cond=$1 root; root="$(env_root "$1")"
  if git -C "$root" rev-parse -q --verify baseline >/dev/null 2>&1; then ok "$cond: overlay already built"; return; fi
  mkdir -p "$root"
  git -C "$SOURCE_WORKSPACE" archive "$SOURCE_REF" | tar -x -C "$root"
  ( cd "$root" && shopt -s nullglob && for p in $EXCLUDE_PATHS; do rm -rf -- $p; done )
  if [ "$cond" = without ]; then ( cd "$root" && for p in $CONTEXT_PATHS; do rm -rf -- "$p"; done ); fi
  # 'guided' = 'with' + a usage-guidance block appended to the env's copy of the pack CLAUDE.md.
  if [ "$cond" = guided ]; then cat "$HARNESS/agent-config/guidance.md" >> "$root/CLAUDE.md"; fi
  git -C "$root" init -q -b main
  git -C "$root" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$root" -c user.name=Workspace -c user.email=workspace@localhost -c commit.gpgsign=false \
    commit -q -m "Workspace baseline"
  git -C "$root" tag baseline
  ok "$cond: overlay built ($(git -C "$root" ls-files | wc -l) files)"
}

# Which upstream agent docs setup strips from this condition's child repos: all of them for
# 'without'; only the known-flawed ones (FLAWED_UPSTREAM_DOCS) for the context conditions.
strip_entries() { if [ "$1" = without ]; then printf '%s' "$UPSTREAM_AGENT_DOCS"; else printf '%s' "$FLAWED_UPSTREAM_DOCS"; fi; }
# Line-level fixes for the upstream docs a context condition keeps: UPSTREAM_DOC_PATCHES/<repo>.patch.
doc_patch() { [ "$1" != without ] && [ -n "$UPSTREAM_DOC_PATCHES" ] && [ -f "$HARNESS/$UPSTREAM_DOC_PATCHES/$2.patch" ] && printf '%s' "$HARNESS/$UPSTREAM_DOC_PATCHES/$2.patch" || true; }
strips_in() { [ -n "$(strip_entries "$1")" ] || { [ "$1" != without ] && [ -n "$UPSTREAM_DOC_PATCHES" ] && ls "$HARNESS/$UPSTREAM_DOC_PATCHES"/*.patch >/dev/null 2>&1; }; }
# The commit a condition's child repo baseline must be at: the pinned sha, or (when stripped)
# the rewritten single commit recorded in $BUILD_INFO when it was built.
built_sha() { grep -E "^BASELINE_${1}_${2//-/_}=" "$BUILD_INFO" 2>/dev/null | cut -d= -f2 || true; }
expected_sha() { if strips_in "$1"; then built_sha "$1" "$2"; else printf '%s' "$3"; fi; }

# Delete this repo's entries from the given doc list and rewrite it as ONE root commit of the
# remaining tree (same author/date/message as the pinned commit), so the docs can't be
# recovered from git (no parent commit, no leftover objects). Deterministic -> both envs
# end up with the identical sha. Verifies exactly the listed paths were removed.
strip_child() {
  local dst=$1 name=$2 entries=$3 patch=${4:-} e p f ok_f paths=() before after
  for e in $entries; do
    [ "${e%%:*}" = "$name" ] || continue; p="${e#*:}"
    [ -e "$dst/$p" ] || [ -L "$dst/$p" ] || die "UPSTREAM_AGENT_DOCS: '$name:$p' not found at the pinned commit"
    paths+=("$p")
  done
  [ -n "$patch" ] && [ ! -f "$patch" ] && patch=""
  [ "${#paths[@]}" -gt 0 ] || [ -n "$patch" ] || return 0
  before="$(git -C "$dst" ls-files | sort)"
  local an ae ad cn ce cd msg tree new tmp="$dst.strip"
  IFS=$'\x1f' read -r an ae ad cn ce cd < <(git -C "$dst" log -1 --format='%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI')
  msg="$(git -C "$dst" log -1 --format=%B)"
  # Plumbing on the index: reuses the upstream blobs byte-for-byte (no eol renormalization).
  [ "${#paths[@]}" -eq 0 ] || git -C "$dst" rm -r -q --cached -- "${paths[@]}"
  # Line-level doc fixes (UPSTREAM_DOC_PATCHES/<repo>.patch). The verification below fails if a
  # patch touches anything outside UPSTREAM_AGENT_DOCS.
  if [ -n "$patch" ]; then git -C "$dst" apply --cached "$patch" || die "$name: $patch does not apply"; fi
  tree="$(git -C "$dst" write-tree)"
  new="$(GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
         GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" GIT_COMMITTER_DATE="$cd" \
         git -C "$dst" commit-tree "$tree" <<<"$msg")"
  # Fresh repo holding only the new root commit's objects (nothing of the original survives).
  rm -rf "$tmp"; git init -q -b main "$tmp"
  git -C "$tmp" fetch -q --upload-pack="git -c uploadpack.allowAnySHA1InWant=true upload-pack" "file://$dst" "$new"
  git -C "$tmp" reset -q --hard "$new"
  rm -rf "$dst"; mv "$tmp" "$dst"
  after="$(git -C "$dst" ls-files | sort)"
  [ -z "$(comm -13 <(echo "$before") <(echo "$after"))" ] || die "$name: strip added files?!"
  while read -r f; do
    [ -n "$f" ] || continue; ok_f=0
    for p in ${paths[@]+"${paths[@]}"}; do [ "$f" = "$p" ] || [[ "$f" == "$p"/* ]] && ok_f=1; done
    [ "$ok_f" = 1 ] || die "$name: strip removed an unlisted file: $f"
  done < <(comm -23 <(echo "$before") <(echo "$after"))
  for p in ${paths[@]+"${paths[@]}"}; do [ ! -e "$dst/$p" ] && [ ! -L "$dst/$p" ] || die "$name: $p still on disk"; done
  [ -z "$patch" ] || ok "  $name: applied doc fixes ($(git -C "$dst" apply --numstat "$patch" 2>/dev/null | wc -l) files, ${patch##*/})"
  [ "${#paths[@]}" -eq 0 ] || ok "  $name: stripped $(comm -23 <(echo "$before") <(echo "$after") | wc -l) upstream agent-doc files (${paths[*]})"
}

clone_child() {
  local cond=$1 name=$2 sha=$3 dst want; dst="$(env_root "$1")/$2"; want="$(expected_sha "$cond" "$name" "$sha")"
  if [ -n "$want" ] && [ "$(git -C "$dst" rev-parse -q --verify 'baseline^{commit}' 2>/dev/null || true)" = "$want" ]; then
    ok "$cond/$name: already at ${want:0:10}"; return; fi
  git -C "$SOURCE_WORKSPACE/$name" cat-file -e "$sha^{commit}" 2>/dev/null \
    || die "pinned commit $sha of $name not in $SOURCE_WORKSPACE/$name (unset SOURCE_WORKSPACE to let setup download it)"
  rm -rf "$dst"; git init -q -b main "$dst"
  # Shallow fetch of exactly the pinned commit; no remote is recorded, so nothing points back.
  git -C "$dst" fetch -q --depth 1 \
    --upload-pack="git -c uploadpack.allowAnySHA1InWant=true upload-pack" \
    "file://$SOURCE_WORKSPACE/$name" "$sha"
  git -C "$dst" reset -q --hard FETCH_HEAD
  if strips_in "$cond"; then strip_child "$dst" "$name" "$(strip_entries "$cond")" "$(doc_patch "$cond" "$name")"; fi
  git -C "$dst" tag baseline
  ok "$cond/$name: cloned at ${sha:0:10}$([ "$(git -C "$dst" rev-parse HEAD)" != "$sha" ] && echo " (stripped → $(git -C "$dst" rev-parse --short HEAD))" || true)"
}

for c in $CONDITIONS; do
  log "Building env '$c' under $LAB_ROOT"
  build_overlay "$c"
  while read -r name sha; do clone_child "$c" "$name" "$sha"; done < <(children)
done

# Record the env layout and each condition's
# child-repo baselines. The verification below checks what those baselines contain.
if [ ! -f "$BUILD_INFO" ]; then
  { echo "LAYOUT=$LAYOUT"
    for c in $CONDITIONS; do
      while read -r name _; do echo "BASELINE_${c}_${name//-/_}=$(git -C "$(env_root "$c")/$name" rev-parse HEAD)"; done < <(children)
    done
  } > "$BUILD_INFO"
  ok "recorded build info (agent-config/generated/build.env)"
fi

# ---- render agent settings --------------------------------------------------------------
for c in $CONDITIONS; do
  others=""; for o in $CONDITIONS; do [ "$o" != "$c" ] && others+="$(env_dir "$o"):"; done
  python3 -I - "$HARNESS/agent-config/settings.template.json" "$GEN/settings-$c.json" \
    "$HARNESS" "$(dirname "$HARNESS")" "$SOURCE_WORKSPACE" "$HOME" "${others%:}" "$LAB_ROOT" "$AUTH" <<'EOF'
import json, sys
src, dst, harness, parent, source, home, others, lab, auth = sys.argv[1:]
t = open(src).read()
for k, v in {"HARNESS": harness, "PARENT": parent, "SOURCE": source, "HOME": home,
             "LAB": lab, "AUTH": auth}.items():
    t = t.replace("{{%s}}" % k, v)
d = json.loads(t); d.pop("$comment", None)
deny = []
for rule in d["permissions"]["deny"]:  # one copy of each OTHER_ENV rule per other env
    deny += [rule.replace("{{OTHER_ENV}}", o) for o in others.split(":")] if "{{OTHER_ENV}}" in rule else [rule]
d["permissions"]["deny"] = deny
json.dump(d, open(dst, "w"), indent=2)
EOF
  ok "rendered agent-config/generated/settings-$c.json"
done

# ---- verify the envs differ ONLY by the context files ------------------------------------
log "Verifying the envs differ only by context: pack ($CONTEXT_PATHS) + the repos' own agent docs"
excl=(-x .git); while read -r name _; do excl+=(-x "$name"); done < <(children)
[[ " $CONDITIONS " == *" without "* ]] || die "CONDITIONS must include 'without' (the baseline)"
# Every context condition = 'without' + exactly the CONTEXT_PATHS (overlay level).
for c in $CONDITIONS; do
  [ "$c" = without ] && continue
  diffs="$(diff -rq "${excl[@]}" "$(env_root without)" "$(env_root "$c")" \
    | sed -e "s#$(env_root without)#without#g" -e "s#$(env_root "$c")#$c#g" || true)"
  expected=""; for p in $CONTEXT_PATHS; do expected+="Only in $c: $p"$'\n'; done
  if [ "$(sort <<<"$diffs")" != "$(sort <<<"${expected%$'\n'}")" ]; then
    printf '%s\n' "$diffs" >&2; die "'$c' differs from 'without' in unexpected ways (see above)"
  fi
done
# Child repos: each condition must be at its recorded baseline; once the UPSTREAM_AGENT_DOCS
# paths are ignored, every condition's tree must be byte-identical (same paths, modes, blobs);
# a non-stripped condition must equal the pinned upstream commit exactly.
while read -r name sha; do
  for c in $CONDITIONS; do
    want="$(expected_sha "$c" "$name" "$sha")"; [ -n "$want" ] || die "no recorded baseline for $c/$name; rebuild"
    [ "$(git -C "$(env_root "$c")/$name" rev-parse HEAD)" = "$want" ] || die "$c/$name not at $want"
    if ! strips_in "$c"; then
      [ "$(git -C "$(env_root "$c")/$name" rev-parse 'HEAD^{tree}')" = "$(git -C "$SOURCE_WORKSPACE/$name" rev-parse "$sha^{tree}")" ] \
        || die "$c/$name tree differs from pinned upstream $sha"
    fi
  done
  python3 -I - "$name" "$UPSTREAM_AGENT_DOCS" $(for c in $CONDITIONS; do printf '%s ' "$(env_root "$c")/$name"; done) <<'PY' || die "$name: child repos differ beyond the upstream agent docs"
import subprocess, sys
name, entries, repos = sys.argv[1], sys.argv[2].split(), sys.argv[3:]
paths = [e.split(":", 1)[1] for e in entries if e.split(":", 1)[0] == name]
def is_doc(f): return any(f == p or f.startswith(p + "/") for p in paths)
trees = []
for r in repos:
    out = subprocess.run(["git", "-C", r, "ls-tree", "-r", "--full-tree", "HEAD"], capture_output=True, text=True, check=True).stdout
    trees.append({l.split("\t", 1)[1]: l.split("\t", 1)[0] for l in out.splitlines() if not is_doc(l.split("\t", 1)[1])})
sys.exit(0 if all(t == trees[0] for t in trees) else 1)
PY
done < <(children)
if [[ " $CONDITIONS " == *" guided "* ]]; then
  # guided's CLAUDE.md must end with exactly the guidance block.
  python3 -I -c 'import sys; c=open(sys.argv[1]).read(); g=open(sys.argv[2]).read(); sys.exit(0 if c.endswith(g) else 1)' \
    "$(env_root guided)/CLAUDE.md" "$HARNESS/agent-config/guidance.md" || die "guided CLAUDE.md does not end with agent-config/guidance.md"
  ok "guided CLAUDE.md = pack CLAUDE.md + guidance block"
fi
if [[ " $CONDITIONS " == *" guided "* && " $CONDITIONS " == *" with "* ]]; then
  gd="$(diff -rq "${excl[@]}" "$(env_root with)" "$(env_root guided)" | sed -e "s#$(env_root with)#with#g" -e "s#$(env_root guided)#guided#g" || true)"
  [ "$gd" = "Files with/CLAUDE.md and guided/CLAUDE.md differ" ] || { printf '%s\n' "$gd" >&2; die "guided env differs from 'with' beyond CLAUDE.md"; }
  ok "guided = with + guidance block in CLAUDE.md (nothing else differs)"
fi
ok "overlay diff = context files only; child repos identical apart from the upstream agent docs"

# Agent-doc files inside the child repos. A stripped condition must have none.
docs_re='(^|/)(AGENTS|CLAUDE|WARP|GEMINI)\.md$|(^|/)\.claude/|(^|/)\.cursor/|(^|/)\.cursorrules$|copilot-instructions\.md$|(^|/)\.windsurf|(^|/)SKILL\.md$'
for c in $CONDITIONS; do
  found="$(while read -r name _; do git -C "$(env_root "$c")/$name" ls-files | grep -E "$docs_re" | sed "s#^#$name/#"; done < <(children) || true)"
  if [ "$c" = without ]; then
    [ -z "$found" ] || { printf '%s\n' "$found" >&2; die "$c: upstream agent docs still present (add them to UPSTREAM_AGENT_DOCS)"; }
    ok "$c: no upstream agent docs in child repos"
  else
    log "$c: $(printf '%s' "$found" | grep -c . || true) upstream agent-doc files kept in child repos"
  fi
done
# A stripped condition must also have no agent context anywhere (overlay included).
for c in $CONDITIONS; do
  if [ "$c" = without ]; then
    hits="$(cd "$(env_root "$c")" && find . -path ./node_modules -prune -o \( -iname 'CLAUDE.md' -o -iname 'CLAUDE.local.md' -o -iname 'AGENTS.md' -o -iname 'WARP.md' -o -iname 'GEMINI.md' -o -iname 'SKILL.md' -o -name '.claude' -o -name '.cursor' -o -name '.cursorrules' -o -name 'arch' \) -print)"
    [ -z "$hits" ] || { printf '%s\n' "$hits" >&2; die "$c: agent context files found on disk"; }
    ok "$c: no agent context files anywhere on disk"
  fi
done

# No leftover experiment hints in the overlay files of either env.
hints='plan_with|plan_without|plan_comparison|DEMO-RUNBOOK|EXPERIMENT\.md|no-setup|reset-children|children\.lock|demo take'
for c in $CONDITIONS; do
  if hits="$(cd "$(env_root "$c")" && git grep -n -I -E "$hints" -- . 2>/dev/null)"; then
    printf '%s\n' "$hits" >&2; die "experiment hints found in the '$c' env overlay"
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
    fresh_home "$c"
    MODEL=haiku TIMEOUT_MIN=3 MAX_BUDGET_USD=1 run_agent "$c" "$vdir/$c" "$vdir/$c/turn" plan "$q" &
  done
  wait
  fail=0
  for c in $CONDITIONS; do
    ans="$(py result-text "$vdir/$c/turn/trace.jsonl" | tr -d '\r' | sed '/^$/d' | head -1)"
    if [ "$c" != without ]; then
      exp="$(head -1 "$(env_root "$c")/CLAUDE.md")"; [ "$ans" = "$exp" ] || { warn "$c: expected '$exp', got '$ans'"; fail=1; }
    else
      [ "$ans" = NONE ] || { warn "$c: expected 'NONE', got '$ans'"; fail=1; }
    fi
    ok "smoke $c → $ans"
  done
  [ "$(user_state_fingerprint)" = "$before" ] || { warn "your ~/.claude state changed during the smoke test!"; fail=1; }
  [ "$fail" = 0 ] || { warn "stderr: $(cat "$vdir"/*/turn/stderr.log 2>/dev/null | grep -v connectors | head -5)"; die "smoke test failed"; }
  rm -rf "$vdir"; for c in $CONDITIONS; do fresh_home "$c"; done
  ok "smoke test passed: agents are isolated and see only their own env's context"
fi

ok "Setup complete."
