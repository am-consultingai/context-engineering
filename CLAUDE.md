# Context-engineering experiment harness

You are the **main session** that steers an A/B experiment: does giving Claude a
prepared context (a `CLAUDE.md`, `arch/` maps, `.claude/` commands + agents) produce
better work on a multi-repo codebase than the bare repos?

Two **agents** (headless `claude -p` processes, default model Haiku) get the *same task*
in two otherwise identical environments:

| condition | contents |
|---|---|
| `without` | **no context at all**: Saleor workspace overlay + 4 repos at pinned commits, with the repos' own agent docs (`AGENTS.md`/`CLAUDE.md`/`WARP.md`, `.claude/`, `skills/`, Cursor rules; `UPSTREAM_AGENT_DOCS`) removed |
| `guided` (default) | **all context + usage guidance**: the repos as pinned (their agent docs included, with doc fixes), **plus** the workspace pack `CLAUDE.md`, `arch/`, `.claude/`, plus `agent-config/guidance.md` appended to the pack `CLAUDE.md` |
| `with` (optional) | same as `guided` without the guidance block; enable with `CONDITIONS="without with guided"` |

Default `CONDITIONS="without guided"`; report only these two unless the user asks for `with`.
`setup.sh` downloads the Saleor workspace (pinned `SOURCE_REF`) and the four pinned Saleor repos into
`~/.cache/context-engineering/` when `SOURCE_WORKSPACE` isn't set, so a fresh clone works out of the box.

**Doc fix** (`FLAWED_UPSTREAM_DOCS` in `experiment.env`): upstream docs with known
factual errors are removed from `with`/`guided` too, and the pack (fixed in the Saleor-workspace repo at
`SOURCE_REF`) has corrected replacements (`arch/saleor-graphql-conventions.md`, `arch/schema-change-workflow.md`,
fixed `arch/saleor.md`). Currently: `saleor/saleor/graphql/AGENTS.md` (wrong schema command). Runs
before `20261125-164856` used the unfixed docs; don't pool them with later runs.
`agent-config/upstream-doc-fixes/<repo>.patch` (`UPSTREAM_DOC_PATCHES`) corrects individual false claims in
the upstream docs `with`/`guided` keep, and the `arch/` maps were corrected in the Saleor-workspace repo itself
(found by a doc-vs-code audit on 2026-11-25; each fix was checked against the code). Setup fails if a
patch touches anything outside `UPSTREAM_AGENT_DOCS`. Runs from before that audit used the unaudited docs.

The envs live **outside this harness** at `$LAB_ROOT/<random label>/saleor-workspace`
(`LAB_ROOT` in `experiment.env`), so nothing in an agent's paths reveals the experiment
or its condition. The label→condition map is `agent-config/generated/labels.env`.
Each agent runs with `env -i`, a private `CLAUDE_CONFIG_DIR` (`$LAB_ROOT/<label>/home`,
archived to `runs/` after each turn), forced settings, no MCP, no web, and is denied the
harness, the other env, and the real workspace. The user's `~/.claude` is never touched.

## What the user says → what you do

| User says | Do |
|---|---|
| "set up" / "set up the experiment" | `./setup.sh`. If it reports missing credentials, ask the user to run `./setup-token.sh` **in their own terminal** (never paste tokens into chat), then `./setup.sh --verify`. |
| "run the experiment" [with <model>] [N times] [with the guided prompt] | 1. Print the task file verbatim in your reply (`task/prompt.txt`, or `task/prompt-guided.txt` if asked). 2. Run `./run.sh [--model M] [--runs N] [--task task/prompt-guided.txt]` **in the background** and wait. 3. Compare **blind** (below). |
| "continue both agents: <message>" / "approve and implement" | `./continue.sh [--mode implement] "<message>"` in the background, then compare the new turn blind. Send the user's words **verbatim**; same message to both. |
| "stop" | `./stop.sh` |
| "reset" | `./reset-envs.sh` |
| "show the last results" | `./unblind.sh` output + `runs/latest/report.md`. |
| "compare run X with run Y" | Read both runs' `summary.json` / `report.md`; compare. |
| "show me what <with/without> did" | Walk `runs/latest/r1/<condition>/turns/<k>/trace.jsonl`: first actions, files read, wrong turns. |
| "change the task to …" | Edit `task/prompt.txt` (show the diff). Applies to the next run. |
| "set the default model to …" | Edit `MODEL=` in `experiment.env`. |

## Comparing a run — blind first, then unblind
1. **Blind scoring.** `run.sh` ends by printing blind packets: `runs/<run>/blind/<rep>-turn<k>/A.md` and `B.md`
   (the two plans, random order). Before you know which is which, read ONLY those and score
   them with **`rubric.md`** (sections A–E). Fact-check claims against either env's code
   (both are identical; read-only: Read/Grep only, never edit envs or run git there).
   Do **not** read `summary.*`, `r*/`, `blind/*/.key.json` or `labels.env` before step 2.
   Write the scorecard (A vs B) to `runs/<run>/blind-scores.md`.
2. **Unblind.** Run `./unblind.sh` (prints A/B → condition and the metrics in `summary.md`).
   Add rubric section F (process metrics, leak audit) now.
3. **Report.** Write `runs/<run>/report.md` with conditions named, and print: verdict, scorecard
   table, key differences, caveats. Say explicitly that scoring was done blind. If the plan text
   itself gave away its condition (e.g. it cites `arch/`), mention it as a caveat.
4. If any agent's leak audit is **FAIL**, say so first: that result is invalid.
   **WARN** = look at the finding and say whether it matters.

## Rules
- **Never help the agents.** Don't put your own knowledge, the rubric, or hints into follow-ups.
  Follow-ups are the user's words, sent identically to both agents.
- **Implement mode** (`--mode implement`) lets agents edit their env and run shell commands
  (not OS-sandboxed). Confirm with the user before the first use in a session. Envs have no
  `node_modules` and no running Docker stack, so builds/codegen against the live API will fail
  unless the user sets those up.
- Don't edit the envs by hand, and never write to the source workspace
  (`SOURCE_WORKSPACE` in `experiment.env`). Rebuild envs with `./setup.sh --rebuild`.
- One run at a time (`runs/.active` lock). A new run or `reset` resets both envs, so only the
  latest run can be continued.
- Model aliases: `haiku`, `sonnet`, `opus`, or a full model id. Default is in `experiment.env`.
  For Haiku, use the full id (`claude-haiku-5-5`): in plan mode the `haiku` alias silently runs Sonnet.
  Every `*-haiku-plan*` run made with the alias actually ran on Sonnet 5.5; `summary.md` shows a
  **MODEL MISMATCH** banner and a "model that ran" row for these (and flags any future mismatch).
- Optional third condition `guided` = `with` + `agent-config/guidance.md` appended to the env's copy
  of the pack `CLAUDE.md` (use maps first; read each repo's `AGENTS.md`). Enable with
  `CONDITIONS="without with guided"` for both `./setup.sh` and `./run.sh`; blind packets become A/B/C.
- Runs before `20261124-123047` used other designs (upstream docs in both envs, or in neither).
  Don't pool them with all-vs-none runs.
- Tasks: `task/prompt.txt` is the natural request (default). `task/prompt-guided.txt` also lists
  the traps to look for, which tends to equalize the two conditions — say so if it's used.

## Layout
`setup.sh` (one-time) · `setup-token.sh` (one-time, interactive) · `run.sh` · `continue.sh` ·
`unblind.sh` · `stop.sh` · `reset-envs.sh` · `lib/` (common.sh, analyze.py) · `agent-config/`
(settings template + generated settings/labels) · `task/` · `rubric.md` ·
`runs/<timestamp>-<model>-<mode>/{task.txt,meta.json,blind/,blind-scores.md,summary.md,report.md,r<N>/<condition>/{claude-config,session_id,turns/<k>/{trace.jsonl,plan.md,response.md,metrics.json,audit.json,changes.patch}}}`.
