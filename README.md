# bluera-claude-planner

A Claude Code plugin that uses OpenAI's Codex CLI as an automated plan reviewer. When Claude finishes writing a plan and calls `ExitPlanMode`, this hook intercepts the call, sends the plan to Codex for review, and blocks plan mode exit until Codex approves. Claude auto-revises based on feedback and resubmits.

## Prerequisites

- [Claude Code](https://claude.ai/claude-code)
- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- `jq`

## Quick Start

```bash
# 1. Install the plugin
claude --plugin-dir .

# 2. Initialize a persistent Codex session
./scripts/init-session.sh

# 3. Use plan mode as normal — Codex reviews automatically
```

## Settings

All configuration lives in `settings.json`:

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Enable/disable plan review |
| `model` | `gpt-5.3-codex` | Model for Codex to use |
| `reasoningEffort` | `xhigh` | Reasoning effort: `low`, `medium`, `high`, `xhigh` |
| `initPrompt` | *(system prompt)* | Sent once when creating a session |
| `reviewPrompt` | *(review template)* | Sent per review. `{{PLAN_CONTENT}}` is replaced with the plan. |

### Toggle

Use the slash command to quickly enable/disable:

```
/bluera-claude-planner:toggle
```

Or set `SKIP_CODEX_REVIEW=1` as an environment variable to bypass for a single session.

## Session Management

### Initialize a session

```bash
./scripts/init-session.sh [project-dir]
```

This creates a Codex session using the `initPrompt` from `settings.json`, which tells Codex to familiarize itself with the project. The session ID is saved to `state/session.json`.

Codex sessions persist in `~/.codex/sessions/` and survive process restarts. Each review call resumes the same session, so Codex remembers prior reviews and can track whether its feedback was addressed.

### Reset

Run `init-session.sh` again to create a fresh session. It will prompt before overwriting.

## How It Works

```
ExitPlanMode called
       │
       ▼
PreToolUse hook fires
       │
       ▼
Check settings.json → enabled?
       │ NO → exit 0 (pass through)
       │ YES ↓
       ▼
Read plan from ~/.claude/plans/
       │
       ▼
Load reviewPrompt from settings.json, substitute {{PLAN_CONTENT}}
       │
       ▼
┌─ CODEX_SESSION_ID set? ──────────────────────────┐
│ YES: codex exec resume <id> "prompt" -m <model>  │
│ NO:  codex exec -s read-only -m <model> "prompt"  │
└───────────────────────────────────────────────────┘
       │
       ├── APPROVED → exit 0 → plan mode exits
       │
       └── REVISIONS_NEEDED → exit 2 + additionalContext
              → Claude sees feedback, revises, retries
```

## Architecture

```
bluera-claude-planner/
├── .claude-plugin/
│   └── plugin.json          # Plugin manifest
├── hooks/
│   ├── hooks.json           # PreToolUse on ExitPlanMode (180s timeout)
│   └── review-plan.sh       # Core hook script
├── scripts/
│   └── init-session.sh      # Create/reset Codex session
├── skills/
│   └── toggle/
│       └── SKILL.md         # /bluera-claude-planner:toggle slash command
├── state/
│   ├── session.json         # Session ID and metadata (gitignored)
│   └── review-history.md    # Audit log of all reviews (gitignored)
└── settings.json            # Configuration, prompts, and enabled state
```

## Error Handling

Failures are always permissive — a broken reviewer never blocks the user.

| Scenario | Behavior |
|---|---|
| `codex` not installed | Allow (warn on stderr) |
| `jq` not installed | Allow |
| Codex times out (>180s) | Allow |
| Session resume fails | Falls back to stateless `codex exec` |
| No plan file found | Allow |
| Network failure | Allow |
| Unparseable response | Allow |
