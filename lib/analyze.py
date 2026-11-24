#!/usr/bin/env python3
"""Trace analysis for the context-engineering experiment.

Subcommands:
  result-text <trace.jsonl>
      Print the agent's final answer text.
  turn --trace T --agent-dir A --env-root E --harness H --source S --mode M --out O
      Write plan.md, response.md, metrics.json, audit.json for one agent turn.
  summary <run_dir>
      Write <run_dir>/summary.md + summary.json (metrics side by side, audit) and print it.
"""
import argparse
import glob
import json
import os
import re
import statistics
import sys

HIDDEN_NAMES = ["plan_with", "plan_without", "plan_comparison", "DEMO-RUNBOOK",
                "EXPERIMENT.md", "reset-children", "children.lock", "no-setup"]


def load_events(path):
    events = []
    if not os.path.exists(path):
        return events
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return events


def tool_uses(events):
    """Yield (tool_use_block, is_subagent) for every tool call, incl. inside subagents."""
    for e in events:
        if e.get("type") != "assistant":
            continue
        for c in (e.get("message") or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                yield c, bool(e.get("parent_tool_use_id"))


def results(events):
    return [e for e in events if e.get("type") == "result"]


def final_text(events):
    rs = results(events)
    for r in reversed(rs):
        if r.get("result"):
            return r["result"]
    # fall back to the last assistant text block
    for e in reversed(events):
        if e.get("type") == "assistant" and not e.get("parent_tool_use_id"):
            texts = [c.get("text", "") for c in (e.get("message") or {}).get("content") or []
                     if isinstance(c, dict) and c.get("type") == "text"]
            if any(texts):
                return "\n".join(texts)
    return ""


def summarize_input(name, inp):
    for k in ("file_path", "command", "pattern", "path", "description", "query", "url"):
        if k in inp and inp[k]:
            return f"{name}: {str(inp[k])[:160]}"
    return f"{name}: {json.dumps(inp)[:160]}"


# ------------------------------------------------------------------ audit
PATH_RE = re.compile(r"(?:~|/home/[^/\s\"'`]+)(?:/[^\s\"'`;|&)<>,]*)?")


def audit(events, env_root, agent_dir, harness, source, home, mode, changes_path):
    findings = []

    def add(level, tool, detail):
        findings.append({"level": level, "tool": tool, "detail": detail[:300]})

    allowed = [env_root.rstrip("/"), agent_dir.rstrip("/")]
    for tu, _ in tool_uses(events):
        name = tu.get("name", "?")
        blob = json.dumps(tu.get("input", {}), ensure_ascii=False)
        for hn in HIDDEN_NAMES:
            if hn in blob:
                add("FAIL", name, f"references hidden experiment file/name '{hn}': {blob}")
        if source in blob or "Saleor-workspace" in blob:
            add("FAIL", name, f"references the real source workspace: {blob}")
        for m in PATH_RE.findall(blob):
            p = m.replace("~", home, 1) if m.startswith("~") else m
            p = p.rstrip("/.")
            if any(p == a or p.startswith(a + "/") for a in allowed):
                continue
            if p.startswith(home + "/.claude") or p == home + "/.claude.json":
                add("FAIL", name, f"touches the user's Claude config: {m}")
            elif p.startswith(harness):
                add("FAIL", name, f"reaches into harness files outside its own env: {m}")
            elif p in (home, home + "/.local/bin") or p.startswith(home + "/.local/bin/") \
                    or p.startswith(home + "/.cache") or p.startswith(home + "/.npm") \
                    or p.startswith(home + "/.gitconfig"):
                continue
            else:
                add("WARN", name, f"path outside its env: {m}")
        if name == "Bash":
            cmd = (tu.get("input") or {}).get("command", "")
            if re.search(r"(^|[\s;&|(])cd\s+\.\.(/\.\.)*\s*($|[;&|)])", cmd) or "../../" in cmd:
                add("WARN", name, f"climbs above the working dir: {cmd}")
    if mode == "plan" and changes_path and os.path.exists(changes_path) and os.path.getsize(changes_path) > 0:
        add("WARN", "-", "plan-mode agent left changes in its env (see changes.patch)")
    # de-duplicate
    seen, uniq = set(), []
    for f in findings:
        k = (f["level"], f["detail"])
        if k not in seen:
            seen.add(k)
            uniq.append(f)
    status = "FAIL" if any(f["level"] == "FAIL" for f in uniq) else \
             "WARN" if uniq else "PASS"
    return {"status": status, "findings": uniq}


# ------------------------------------------------------------------ turn
def cmd_turn(a):
    events = load_events(a.trace)
    out = a.out
    os.makedirs(out, exist_ok=True)
    init = next((e for e in events if e.get("type") == "system" and e.get("subtype") == "init"), {})
    rs = results(events)

    def read_int(fn):
        try:
            return int(open(os.path.join(out, fn)).read().strip())
        except Exception:
            return None

    started, ended = read_int("started_at"), read_int("ended_at")
    exit_code = read_int("exit_code")

    by_tool, sub_calls, top_calls = {}, 0, 0
    actions, files_read = [], []
    context_reads = 0
    for tu, is_sub in tool_uses(events):
        n = tu.get("name", "?")
        by_tool[n] = by_tool.get(n, 0) + 1
        inp = tu.get("input") or {}
        if is_sub:
            sub_calls += 1
        else:
            top_calls += 1
            actions.append(summarize_input(n, inp))
        if n == "Read" and inp.get("file_path"):
            files_read.append(os.path.relpath(inp["file_path"], a.env_root)
                              if inp["file_path"].startswith(a.env_root) else inp["file_path"])
        blob = json.dumps(inp)
        if re.search(r"(^|[\s\"/])(arch/|CLAUDE\.md)", blob):
            context_reads += 1

    text = final_text(events)
    with open(os.path.join(out, "response.md"), "w") as f:
        f.write(text)

    # Plan: newest plan file written in this turn inside the agent's private config, else the answer.
    plan_src, plan = "response", text
    plans = sorted(glob.glob(os.path.join(a.agent_dir, "claude-config", "plans", "*.md")),
                   key=os.path.getmtime)
    if plans and (started is None or os.path.getmtime(plans[-1]) >= started - 1):
        plan, plan_src = open(plans[-1], errors="replace").read(), os.path.basename(plans[-1])
    with open(os.path.join(out, "plan.md"), "w") as f:
        f.write(plan)

    session_id = init.get("session_id") or next((r.get("session_id") for r in rs if r.get("session_id")), None)
    metrics = {
        "model": init.get("model"),
        "session_id": session_id,
        "exit_code": exit_code,
        "is_error": any(r.get("is_error") for r in rs) or not rs,
        "error_text": next((r.get("result") for r in rs if r.get("is_error")), None),
        "wall_seconds": (ended - started) if started and ended else None,
        "api_turns": sum(r.get("num_turns") or 0 for r in rs),
        "cost_usd": round(max([r.get("total_cost_usd") or 0 for r in rs] or [0]), 4),
        "tool_calls": top_calls,
        "subagent_tool_calls": sub_calls,
        "subagents_spawned": by_tool.get("Agent", 0) + by_tool.get("Task", 0),
        "tools_by_name": dict(sorted(by_tool.items(), key=lambda kv: -kv[1])),
        "context_file_touches": context_reads,
        "files_read": files_read,
        "first_actions": actions[:8],
        "plan_source": plan_src,
        "plan_lines": plan.count("\n") + (1 if plan else 0),
        "loaded_slash_commands": init.get("slash_commands"),
        "loaded_agents": init.get("agents"),
    }
    with open(os.path.join(out, "metrics.json"), "w") as f:
        json.dump(metrics, f, indent=2)
    if session_id:
        with open(os.path.join(a.agent_dir, "session_id"), "w") as f:
            f.write(session_id + "\n")

    au = audit(events, a.env_root, a.agent_dir, a.harness, a.source, os.path.expanduser("~"),
               a.mode, os.path.join(out, "changes.patch"))
    with open(os.path.join(out, "audit.json"), "w") as f:
        json.dump(au, f, indent=2)
    print(f"{os.path.basename(a.agent_dir)}: {metrics['tool_calls']} tool calls, "
          f"{metrics['wall_seconds']}s, ${metrics['cost_usd']}, audit {au['status']}"
          + (f", ERROR: {metrics['error_text']}" if metrics["is_error"] else ""))


# ------------------------------------------------------------------ summary
def cmd_summary(a):
    run = a.run_dir.rstrip("/")
    meta = json.load(open(os.path.join(run, "meta.json")))
    conds = meta["conditions"]
    rows = {}  # (repeat, turn) -> cond -> metrics/audit
    for mpath in sorted(glob.glob(os.path.join(run, "r*", "*", "turns", "*", "metrics.json"))):
        parts = mpath.split(os.sep)
        rep, cond, turn = parts[-5], parts[-4], parts[-2]
        m = json.load(open(mpath))
        au = json.load(open(os.path.join(os.path.dirname(mpath), "audit.json")))
        rows.setdefault((rep, int(turn)), {})[cond] = {"m": m, "a": au, "dir": os.path.dirname(mpath)}

    L = []
    L.append(f"# Experiment run `{os.path.basename(run)}`\n")
    L.append(f"- model: **{meta['model']}**, mode: **{meta['mode']}**, repeats: {meta['repeats']}")
    L.append(f"- conditions: {', '.join(conds)} (only difference: {meta['context_paths']})")
    L.append(f"- source: `{meta['source_ref']}` @ {meta['source_sha'][:10]}\n")

    def fmt(v):
        if v is None:
            return "—"
        if isinstance(v, float):
            return f"{v:.3f}"
        return str(v)

    fields = [("wall_seconds", "wall time (s)"), ("tool_calls", "tool calls"),
              ("subagents_spawned", "subagents spawned"), ("subagent_tool_calls", "subagent tool calls"),
              ("context_file_touches", "touches of CLAUDE.md/arch"), ("api_turns", "API turns"),
              ("cost_usd", "est. API-equivalent cost (USD; not billed on a subscription)"), ("plan_lines", "plan length (lines)")]
    agg = {c: {k: [] for k, _ in fields} for c in conds}
    for (rep, turn) in sorted(rows):
        r = rows[(rep, turn)]
        L.append(f"## {rep} · turn {turn}\n")
        L.append("| metric | " + " | ".join(conds) + " |")
        L.append("|---|" + "---|" * len(conds))
        for k, label in fields:
            L.append(f"| {label} | " + " | ".join(fmt(r.get(c, {}).get("m", {}).get(k)) for c in conds) + " |")
            if turn == 1:
                for c in conds:
                    v = r.get(c, {}).get("m", {}).get(k)
                    if isinstance(v, (int, float)):
                        agg[c][k].append(v)
        L.append("| errors | " + " | ".join(
            ("ERROR: " + str(r[c]["m"].get("error_text"))[:60]) if c in r and r[c]["m"].get("is_error") else "none"
            for c in conds) + " |")
        L.append("| leak audit | " + " | ".join(r[c]["a"]["status"] if c in r else "—" for c in conds) + " |")
        L.append("")
        for c in conds:
            if c not in r:
                continue
            L.append(f"**{c}** — first actions:")
            for act in r[c]["m"]["first_actions"][:6]:
                L.append(f"  - `{act.replace('`', '')[:140]}`")
            for f in r[c]["a"]["findings"][:8]:
                L.append(f"  - audit {f['level']}: {f['detail'][:200]}")
            L.append(f"  - plan: `{os.path.relpath(os.path.join(r[c]['dir'], 'plan.md'), run)}`")
        L.append("")

    if meta["repeats"] > 1:
        L.append("## Averages across repeats (turn 1)\n")
        L.append("| metric | " + " | ".join(conds) + " |")
        L.append("|---|" + "---|" * len(conds))
        for k, label in fields:
            L.append(f"| {label} | " + " | ".join(
                fmt(round(statistics.mean(agg[c][k]), 3)) if agg[c][k] else "—" for c in conds) + " |")
        L.append("")

    us = os.path.join(run, "user-state-check.txt")
    if os.path.exists(us):
        L.append("## Your own Claude config\n")
        L.append(open(us).read().strip() + "\n")

    text = "\n".join(L)
    open(os.path.join(run, "summary.md"), "w").write(text)
    json.dump({f"{k[0]}/turn{k[1]}": {c: {"metrics": v["m"], "audit": v["a"]} for c, v in r.items()}
               for k, r in rows.items()}, open(os.path.join(run, "summary.json"), "w"), indent=2)
    print(text)


def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("result-text"); s.add_argument("trace")
    t = sp.add_parser("turn")
    for k in ("trace", "agent-dir", "env-root", "harness", "source", "mode", "out"):
        t.add_argument("--" + k, required=True)
    s2 = sp.add_parser("summary"); s2.add_argument("run_dir")
    a = p.parse_args()
    if a.cmd == "result-text":
        print(final_text(load_events(a.trace)))
    elif a.cmd == "turn":
        cmd_turn(a)
    elif a.cmd == "summary":
        cmd_summary(a)


if __name__ == "__main__":
    sys.exit(main())
