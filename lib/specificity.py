#!/usr/bin/env python3
"""Plan specificity: how concretely is a plan grounded in the real codebase?

Counts the concrete references in each plan and checks them against the env's code:
  paths     `saleor/graphql/query_cost_map.py`  -> exists in a repo (or the overlay)?
  line refs `sorters.py:163`                    -> the file exists and has that many lines?
  symbols   `product_qs_select_for_update`      -> appears (whole word) in the code?
  commands  `uv run poe build-schema`           -> a real pnpm script / poe task / manage.py command?
Unresolved paths/symbols are usually NEW things the plan proposes, so they're reported but not
scored. Unresolved commands are almost always mistakes (plans rarely invent scripts).

Also, if task/keys/<task>.terms exists: RULE COVERAGE = how many of the task's house rules
(answer-key markers like `call_event`, `ADDED_IN_324`, `COST_MAP`) the plan mentions. This is the
automatic, repeatable counterpart of blind scoring: it counts mentions, not whether they're right.

Only run this on UNBLINDED runs (it reads r*/<condition>/turns/<k>/plan.md).

Usage: lib/specificity.py <run_dir> [<run_dir> ...] [--json]
"""
import json, os, re, subprocess, sys
from functools import lru_cache
from pathlib import Path

HARNESS = Path(__file__).resolve().parent.parent
REPOS = ["saleor", "saleor-dashboard", "storefront", "saleor-platform"]
EXT = r"(?:py|pyi|ts|tsx|js|cjs|mjs|jsx|md|graphql|json|ya?ml|toml|txt|cfg|ini|sh|css|html|lock|env|example|template)"


def lab_roots():
    env = subprocess.run(["bash", "-c", f"source {HARNESS}/experiment.env; echo $LAB_ROOT"],
                         capture_output=True, text=True).stdout.strip()
    return sorted(Path(env).glob("*/saleor-workspace"))


@lru_cache(None)
def index():
    """Union over all envs (code is identical; docs differ): files, line counts, scripts."""
    files, roots = {}, lab_roots()
    for root in roots:
        for p in root.iterdir():  # overlay files (CLAUDE.md, arch/, dev/, ...)
            if p.name in REPOS or p.name == ".git":
                continue
            for f in ([p] if p.is_file() else p.rglob("*")):
                if f.is_file():
                    files.setdefault(str(f.relative_to(root)), f)
        for repo in REPOS:
            r = root / repo
            if not (r / ".git").exists():
                continue
            out = subprocess.run(["git", "-C", str(r), "ls-files"], capture_output=True, text=True).stdout
            for rel in out.splitlines():
                files.setdefault(f"{repo}/{rel}", r / rel)
    scripts = set()
    for root in roots:
        for repo in ("saleor-dashboard", "storefront"):
            pj = root / repo / "package.json"
            if pj.exists():
                scripts |= set(json.load(open(pj)).get("scripts", {}))
        pp = root / "saleor" / "pyproject.toml"
        if pp.exists():
            scripts |= {f"poe:{m}" for m in re.findall(r"^([\w-]+)\.(?:cmd|sequence|help|shell)\s*=", pp.read_text(), re.M)}
            scripts |= {f"poe:{m}" for m in re.findall(r"^\[tool\.poe\.tasks\.([\w-]+)\]", pp.read_text(), re.M)}
        for cmd in (root / "saleor").glob("saleor/**/management/commands/*.py"):
            scripts.add(f"manage:{cmd.stem}")
    django = {"migrate", "makemigrations", "shell", "runserver", "test", "showmigrations", "sqlmigrate",
              "createsuperuser", "collectstatic", "check", "dbshell", "loaddata", "dumpdata"}
    scripts |= {f"manage:{c}" for c in django}
    return files, scripts, roots


def resolve_path(p):
    """Exact path from the workspace root, or a unique-enough suffix match (`graphql/product/sorters.py`)."""
    files, _, _ = index()
    p = p.strip().lstrip("./").rstrip("/")
    if p in files:
        return p
    for repo in REPOS:  # relative to a repo root, or to saleor's inner package
        for pre in (f"{repo}/", "saleor/saleor/"):
            if pre + p in files:
                return pre + p
    if "/" in p:
        hits = [f for f in files if f.endswith("/" + p)]
        if hits:
            return hits[0]
    is_dir = any(f.startswith(p + "/") or f"/{p}/" in f for f in files) if "/" in p else False
    return p + "/" if is_dir else None


def line_count(rel):
    try:
        with open(index()[0][rel], "rb") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0


CMD_RE = re.compile(
    r"\b(?:pnpm(?:\s+run)?\s+(?P<pnpm>[\w:.-]+)"
    r"|(?:uv\s+run\s+)?poe\s+(?P<poe>[\w-]+)"
    r"|(?:python\s+|\./)?manage\.py\s+(?P<manage>[\w-]+))")
PNPM_BUILTIN = {"i", "install", "add", "remove", "exec", "dlx", "why", "update", "up", "store", "run", "-r", "--filter",
                "audit", "outdated", "list", "ls", "init", "link", "prune", "rebuild", "x", "env"}


def symbols_present(tokens):
    """Whole-word fixed-string search of all tokens in every repo, one git grep per repo."""
    if not tokens:
        return set()
    _, _, roots = index()
    found, pat = set(), "\n".join(sorted(tokens))
    root = next((r for r in roots if (r / "saleor" / ".git").exists()), None)
    for repo in REPOS:
        r = root / repo if root else None
        if not r or not (r / ".git").exists():
            continue
        out = subprocess.run(["git", "-C", str(r), "grep", "-h", "-o", "-w", "-F", "-I", "-f", "-"],
                             input=pat, capture_output=True, text=True).stdout
        found |= set(out.splitlines())
    return found


def analyze(text):
    files, scripts, _ = index()
    code = re.findall(r"`([^`\n]+)`", text)
    blocks = re.findall(r"```[^\n]*\n(.*?)```", text, re.S)
    paths, lines_ok, lines_bad, syms, cmds_ok, cmds_bad, new_paths = set(), set(), set(), set(), set(), set(), set()
    path_re = re.compile(rf"(?<![\w@])((?:[\w.\-\[\]()]+/)*[\w.\-\[\]]+\.{EXT})(?::(\d+)(?:[-–](\d+))?)?\b")
    for chunk in code + blocks + [text]:
        for m in path_re.finditer(chunk):
            p, ln = m.group(1), m.group(2)
            if p.startswith(("http", "www.")) or p.count(".") > 3 and "/" not in p:
                continue
            rp = resolve_path(p)
            if rp:
                paths.add(rp)
                if ln:
                    (lines_ok if int(ln) <= line_count(rp) else lines_bad).add(f"{rp}:{ln}")
            elif "/" in p:
                new_paths.add(p)
    for chunk in code + blocks:
        for m in CMD_RE.finditer(chunk):
            if m.group("pnpm"):
                s = m.group("pnpm")
                if s in PNPM_BUILTIN or s.startswith("-"):
                    continue
                (cmds_ok if s in scripts else cmds_bad).add(f"pnpm {s}")
            elif m.group("poe"):
                s = m.group("poe")
                (cmds_ok if f"poe:{s}" in scripts else cmds_bad).add(f"poe {s}")
            elif m.group("manage"):
                s = m.group("manage")
                (cmds_ok if f"manage:{s}" in scripts else cmds_bad).add(f"manage.py {s}")
    sym_re = re.compile(r"^[A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*(?:\(\))?$")
    cand = set()
    for c in code:
        c = c.strip()
        if not sym_re.match(c) or "/" in c:
            continue
        for part in c.rstrip("()").split("."):
            if len(part) >= 4 and ("_" in part.strip("_") or re.search(r"[a-z][A-Z]|[A-Z]{2,}[a-z]|^[A-Z][a-z]+[A-Z]", part)):
                cand.add(part)
    present = symbols_present(cand)
    syms = cand & present
    return {
        "plan_lines": text.count("\n") + 1,
        "paths_real": len(paths), "line_refs_ok": len(lines_ok), "line_refs_bad": sorted(lines_bad),
        "symbols_real": len(syms), "commands_ok": len(cmds_ok), "commands_bad": sorted(cmds_bad),
        "new_or_unresolved_paths": len(new_paths), "symbols_new_or_unresolved": len(cand - present),
        "grounded_refs": len(paths) + len(lines_ok) + len(syms) + len(cmds_ok),
    }


def load_terms(run):
    try:
        task = Path(json.load(open(run / "meta.json"))["task_file"]).stem.replace("prompt-", "")
    except Exception:
        return None, []
    f = HARNESS / "task" / "keys" / f"{task}.terms"
    if not f.exists():
        return task, []
    rules = []
    for line in f.read_text().splitlines():
        if line.strip() and not line.startswith("#") and "\t" in line:
            label, rx = line.split("\t", 1)
            rules.append((label, re.compile(rx, re.I)))
    return task, rules


def main(argv):
    as_json = "--json" in argv
    runs = [Path(a) for a in argv if a != "--json"]
    rows = []
    for run in runs:
        task, rules = load_terms(run)
        for plan in sorted(run.glob("r*/*/turns/*/plan.md")):
            cond, text = plan.parts[-4], plan.read_text(errors="replace")
            hit = [l for l, rx in rules if rx.search(text)]
            rows.append({"run": run.name, "task": task, "rep": plan.parts[-5], "turn": plan.parts[-2], "condition": cond,
                         "rules_covered": f"{len(hit)}/{len(rules)}" if rules else "-",
                         "rules_missed": [l for l, _ in rules if l not in hit],
                         **analyze(text)})
    if as_json:
        print(json.dumps(rows, indent=2)); return
    hdr = ["task", "condition", "rules_covered", "plan_lines", "grounded_refs", "paths_real", "line_refs_ok", "symbols_real",
           "commands_ok", "commands_bad", "line_refs_bad"]
    print("| " + " | ".join(hdr) + " |"); print("|" + "---|" * len(hdr))
    for r in rows:
        print("| " + " | ".join(str(len(r[h]) if isinstance(r[h], list) and h in ("commands_bad", "line_refs_bad") and not r[h] else
                                    ", ".join(r[h]) if isinstance(r[h], list) else r[h]) for h in hdr) + " |")


if __name__ == "__main__":
    main(sys.argv[1:])
