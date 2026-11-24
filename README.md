# Context-engineering experiment

A/B test: the same task, the same model, two identical copies of the Saleor workspace.
The only difference is the Claude context (`CLAUDE.md`, `arch/`, `.claude/`).

## Use it
```bash
cd ~/projects/learning/salesforce/context-engineering
claude                      # then: "run the experiment"  (or "... with sonnet", "... 3 times")
```
The session prints the task, runs both agents in parallel, and summarizes the comparison.
Follow up with "continue both agents: …", "show me what the with agent did", "stop", "reset".

## One-time setup
```bash
./setup-token.sh            # in your own terminal: agent credentials → ~/.config/context-engineering/ (never ~/.claude, never in the repo)
./setup.sh --verify         # builds envs/{without,with}, checks they differ only by the context, smoke-tests isolation
```

## Scripts
| script | does |
|---|---|
| `setup.sh [--rebuild] [--verify]` | build the two envs from `SOURCE_WORKSPACE` (read-only), render agent settings |
| `run.sh [--model M] [--runs N] [--mode plan\|implement]` | reset envs, run both agents, collect plans/metrics/leak audit |
| `continue.sh [--mode …] "msg"` | same follow-up to both agents (resumes their sessions) |
| `stop.sh` / `reset-envs.sh` | stop agents / reset envs to baseline |

Configuration: `experiment.env`. Comparison rubric: `rubric.md`. Results: `runs/<timestamp>-<model>-<mode>/`.

## Presentation
`presentation/` holds the "Context engineering (fundamentals)" deck (Vite + React).
```bash
cd presentation && npm install && npm run dev     # local preview
```
It is published to GitHub Pages from the **`presentation`** branch by
`.github/workflows/deploy-presentation.yml` (push to that branch → build → deploy).
