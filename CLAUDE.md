# Context-engineering experiment harness

You are the **main session** that steers an A/B experiment: does giving Claude a
prepared context (a `CLAUDE.md`, `arch/` maps, `.claude/` commands + agents) produce
better work on a multi-repo codebase than the bare repos?

Two **agents** (headless `claude -p` processes, default model Haiku) get the *same task*
in two otherwise identical environments:

| env | contents |
|---|---|
| `envs/without/` | Saleor workspace overlay + 4 repos at pinned commits |
| `envs/with/` | identical, **plus** `CLAUDE.md`, `arch/`, `.claude/` |

Each agent runs with `env -i`, its own empty `CLAUDE_CONFIG_DIR` under `runs/`, forced
settings (`agent-config/generated/settings-<env>.json`), no MCP, no web, and is denied
reading this harness and the real workspace. The user's `~/.claude` is never touched.

## What the user says → what you do

| User says | Do |
|---|---|
| "set up" / "set up the experiment" | `./setup.sh`. If it reports missing credentials, ask the user to run `./setup-token.sh` **in their own terminal** (interactive; never paste tokens into chat), then `./setup.sh --verify`. |
| "run the experiment" [with <model>] [N times] | 1. Print the task: show `task/prompt.txt` verbatim in your reply. 2. Run `./run.sh [--model M] [--runs N]` **in the background** and wait for it. 3. Compare (below). |
| "continue both agents: <message>" / "approve and implement" | `./continue.sh [--mode implement] "<message>"` in the background, then compare the new turn. Send the user's words **verbatim**; same message to both. |
| "stop" | `./stop.sh` |
| "reset" | `./reset-envs.sh` |
| "show the last results" | Read `runs/latest/summary.md` (+ `report.md` if present) and summarize. |
| "compare run X with run Y" | Read both runs' `summary.json` / `report.md`; compare. |
| "show me what <with/without> did" | Walk `runs/latest/r1/<env>/turns/<k>/trace.jsonl`: first actions, files read, wrong turns. |
| "change the task to …" | Edit `task/prompt.txt` (show the diff). Applies to the next run. |
| "set the default model to …" | Edit `MODEL=` in `experiment.env`. |

## Comparing a run
1. Read `runs/<run>/summary.md`, then each agent's `plan.md` (and `response.md`) for the turn.
2. Score both with **`rubric.md`**. Fact-check claims against `envs/without/` (read-only:
   Read/Grep only, never edit envs, never run git commands that change them).
3. Write the result to `runs/<run>/report.md` (append a section per turn for continued runs)
   and print: verdict, scorecard table, key differences, caveats.
4. If any agent's leak audit is **FAIL**, say so first: that result is invalid.
   **WARN** = look at the finding and say whether it matters.

## Rules
- **Never help the agents.** Don't put your own knowledge, the rubric, or hints into follow-ups.
  Follow-ups are the user's words, sent identically to both agents.
- **Implement mode** (`--mode implement`) lets agents edit their env and run shell commands
  (not OS-sandboxed). Confirm with the user before the first use in a session. Envs have no
  `node_modules` and no running Docker stack, so builds/codegen against the live API will fail
  unless the user sets those up.
- Don't edit `envs/` by hand, and never write to the source workspace
  (`SOURCE_WORKSPACE` in `experiment.env`). Rebuild envs with `./setup.sh --rebuild`.
- One run at a time (`runs/.active` lock). A new run or `reset` resets both envs, so only the
  latest run can be continued.
- Model aliases: `haiku`, `sonnet`, `opus`, or a full model id. Default is in `experiment.env`.

## Layout
`setup.sh` (one-time) · `setup-token.sh` (one-time, interactive) · `run.sh` · `continue.sh` ·
`stop.sh` · `reset-envs.sh` · `lib/` (common.sh, analyze.py) · `agent-config/` (settings template +
generated) · `task/prompt.txt` · `rubric.md` · `envs/` · `runs/<timestamp>-<model>-<mode>/r<N>/<env>/{claude-config,turns/<k>/{trace.jsonl,plan.md,response.md,metrics.json,audit.json,changes.patch}}`.
