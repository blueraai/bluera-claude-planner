# codex-plan-reviewer

A Claude Code plugin that uses OpenAI's Codex CLI as an automated plan reviewer. When Claude finishes writing a plan and calls `ExitPlanMode`, this hook intercepts the call, sends the plan to Codex for review, and blocks plan mode exit until Codex approves. Claude auto-revises based on feedback and resubmits.

## Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- `jq`

## Quick Start

```bash
# 1. Install the plugin
claude --plugin-dir ./codex-plan-reviewer

# 2. Configure
cp codex-plan-reviewer/.env.example codex-plan-reviewer/.env

# 3. Initialize a persistent Codex session
./codex-plan-reviewer/scripts/init-session.sh

# 4. Use Claude Code in plan mode — reviews happen automatically
```

## Configuration

Copy `.env.example` to `.env` and edit:

```env
# Model for Codex to use
CODEX_MODEL=gpt-5.3-codex

# Reasoning effort: low, medium, high, xhigh
CODEX_REASONING_EFFORT=xhigh

# Session ID (written by init-session.sh — do not edit manually)
CODEX_SESSION_ID=
```

### Bypass

Skip review for a session:

```bash
SKIP_CODEX_REVIEW=1 claude --plugin-dir ./codex-plan-reviewer
```

## Session Management

### Initialize a session

```bash
./codex-plan-reviewer/scripts/init-session.sh [project-dir]
```

This creates a Codex session using `prompts/init.md`, which tells Codex to familiarize itself with the project. The session ID is saved to `.env`.

Codex sessions persist in `~/.codex/sessions/` and survive process restarts. Each review call resumes the same session, so Codex remembers prior reviews and can track whether its feedback was addressed.

### Reset

Run `init-session.sh` again to create a fresh session. It will prompt before overwriting.

## Prompt Customization

Edit the prompt files in `prompts/` to change Codex's behavior:

| File | Purpose |
|------|---------|
| `prompts/init.md` | Sent once when creating a session. Tells Codex its role and how to review. |
| `prompts/review.md` | Sent for each review. `{{PLAN_CONTENT}}` is replaced with the plan. |

## How It Works

```
ExitPlanMode called
       │
       ▼
PreToolUse hook fires
       │
       ▼
Read plan from ~/.claude/plans/
       │
       ▼
Load prompts/review.md, substitute {{PLAN_CONTENT}}
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
codex-plan-reviewer/
├── .claude-plugin/
│   └── plugin.json          # Plugin manifest
├── hooks/
│   ├── hooks.json           # PreToolUse on ExitPlanMode (180s timeout)
│   └── review-plan.sh       # Core hook script
├── prompts/
│   ├── init.md              # Session initialization prompt
│   └── review.md            # Review prompt template
├── scripts/
│   └── init-session.sh      # Create/reset Codex session
├── state/
│   └── review-history.md    # Audit log of all reviews (gitignored)
├── .env.example             # Config template
├── .env                     # Local config (gitignored)
└── .gitignore
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
