# bluera-claude-planner

Cross-AI plan review system — uses OpenAI Codex to review Claude Code plans before implementation begins.

## What's Inside

### [`codex-plan-reviewer/`](./codex-plan-reviewer/)

A Claude Code plugin that hooks into `ExitPlanMode`. When Claude finishes writing a plan, the hook sends it to Codex for review. Codex either approves the plan or returns specific feedback, keeping Claude in plan mode until the plan passes review.

Features:
- Persistent Codex sessions via `codex exec resume` — Codex remembers prior reviews
- Configurable model and reasoning effort via `settings.json`
- Editable prompt templates in `prompts/`
- Silent graceful degradation — never blocks the user on errors

## Quick Start

```bash
# 1. Load the plugin
claude --plugin-dir ./codex-plan-reviewer

# 2. Initialize a Codex reviewer session
./codex-plan-reviewer/scripts/init-session.sh

# 3. Use plan mode as normal — Codex reviews automatically
```

See [`codex-plan-reviewer/README.md`](./codex-plan-reviewer/README.md) for full documentation.

## Requirements

- [Claude Code](https://claude.ai/claude-code)
- [Codex CLI](https://github.com/openai/codex) (authenticated)
- `jq`
