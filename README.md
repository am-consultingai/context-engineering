# Context-engineering experiment

Does a prepared context make Claude plan better, and cheaper, on a real multi-repo codebase?

Two headless Claude agents get **the same task** in two copies of a Saleor workspace (backend,
dashboard, storefront, docker setup) at the **same pinned commits**:

| condition | what the agent gets |
|---|---|
| `without` | the code only: no workspace pack, and the repos' own agent docs (`AGENTS.md`, `CLAUDE.md`, `.claude/`, …) removed |
| `guided` | the code + the context: the workspace pack (`CLAUDE.md`, `arch/` maps, `.claude/`), the repos' own agent docs, and a short usage guide (`agent-config/guidance.md`) |

Plans are scored **blind** (A/B, random order), then unblinded. The headline metrics are
**poor design decisions** (house rules from the task's answer key that the plan doesn't address)
and **tokens/cost**.

## Requirements
- Linux, Windows via WSL 2, or macOS (Intel or Apple silicon). Uses only standard tools:
  `bash` (macOS's stock 3.2 is fine), `git`, `python3` (3.9+), `tar`, `diff`; no Homebrew packages
  needed. Native Windows (without WSL) is not supported.
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on your `PATH`) and a Claude
  subscription or API key
- About 500 MB of disk space and network access to github.com (first setup only)

## Quick start
```bash
git clone https://github.com/am-consultingai/context-engineering.git
cd context-engineering
./setup-token.sh       # once, in your own terminal: agent credentials → ~/.config/context-engineering/
./setup.sh --verify    # downloads the workspace + pinned repos, builds the envs, smoke-tests them (~1 cent)
claude                 # then say: "run the experiment"
```
`setup.sh` downloads everything it needs (the public
[Saleor-workspace](https://github.com/am-consultingai/Saleor-workspace) repo at a pinned commit, and the
four Saleor repos at the commits pinned in its `children.lock`) into
`~/.cache/context-engineering/`. The agent environments are built under `~/.local/share/saleor-ws/`
with neutral folder names, so nothing in an agent's paths reveals the experiment. Your own
`~/.claude` is never touched. To build from an existing local checkout of the workspace instead,
`export SOURCE_WORKSPACE=<path>` (it is only read).

## Running tasks
In a `claude` session in this folder, say for example:
- "run the experiment" (default task `task/prompt.txt`)
- "run the experiment with task/prompt-playbook.txt 3 times"
- "show the last results", "stop", "reset"

Or call the scripts directly: `./run.sh --task task/prompt-reviews.txt --runs 3`, then score the
blind packets in `runs/<run>/blind/`, then `./unblind.sh`.

Tasks are in `task/prompt-*.txt`; their answer keys (written before any run) are in `task/keys/`.
`lib/specificity.py <run_dir>` counts each plan's poor design decisions (`task/keys/<task>.terms`)
and its concrete, code-verified references. Results go to `runs/` (local only, not committed).

## Scripts
| script | does |
|---|---|
| `setup-token.sh` | one-time, interactive: store agent credentials outside the repo |
| `setup.sh [--rebuild] [--verify]` | download sources, build the envs, apply the doc fixes, verify the envs differ only by the context, render agent settings |
| `run.sh [--task FILE] [--runs N] [--model M] [--mode plan\|implement]` | reset envs, run all agents in parallel, collect plans/metrics/leak audit, write blind packets |
| `unblind.sh [run]` | after blind scoring: reveal which plan is which, print the metrics |
| `continue.sh [--mode …] "msg"` | send the same follow-up to every agent (resumes their sessions) |
| `stop.sh` / `reset-envs.sh` | stop the agents / reset the envs to baseline |

Configuration (model, conditions, pinned commits, timeouts): `experiment.env`. Rubric: `rubric.md`.
Rules for the steering session: `CLAUDE.md`.

### Doc fixes
Some of the upstream docs contain claims that are false at the pinned commits (e.g. a schema
command that doesn't exist, "React 17" where the code uses React 18). The workspace pack itself was
audited and fixed in the Saleor-workspace repo (the pinned `SOURCE_REF`). For the Saleor repos'
own agent docs, which we don't own, `setup.sh` applies `agent-config/upstream-doc-fixes/` in the
context envs and removes `saleor/saleor/graphql/AGENTS.md` in favor of the pack's corrected
`arch/saleor-graphql-conventions.md`. Setup refuses any patch that touches non-doc files.

## Presentation
`presentation/` holds the "Context engineering (fundamentals)" deck (Vite + React).
```bash
cd presentation && npm install && npm run dev     # local preview
```
It is published to GitHub Pages from the **`presentation`** branch by
`.github/workflows/deploy-presentation.yml` (push to that branch → build → deploy).
