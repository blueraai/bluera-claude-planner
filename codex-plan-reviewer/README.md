# codex-plan-reviewer

A Claude Code plugin that uses OpenAI's Codex CLI as an automated plan reviewer. When Claude finishes writing a plan and calls `ExitPlanMode`, this hook intercepts the call, sends the plan to Codex for review, and blocks plan mode exit until Codex approves. Claude auto-revises based on feedback and resubmits.

## Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- `jq`

## Quick Start

```bash
# 1. Install the plugin
claude --plugin-dir ./codex-plan-reviewer

# 2. Initialize a persistent Codex session
./codex-plan-reviewer/scripts/init-session.sh

# 3. Use Claude Code in plan mode — reviews happen automatically
```

## Settings

Edit `settings.json` to configure:

```json
{
  "model": "gpt-5.3-codex",
  "reasoningEffort": "xhigh"
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `model` | `gpt-5.3-codex` | Model for Codex to use |
| `reasoningEffort` | `xhigh` | Reasoning effort: `low`, `medium`, `high`, `xhigh` |

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

This creates a Codex session using `prompts/init.md`, which tells Codex to familiarize itself with the project. The session ID is saved to `state/session.json`.

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
│   ├── session.json         # Session ID and metadata (gitignored)
│   └── review-history.md    # Audit log of all reviews (gitignored)
├── settings.json            # User-editable configuration
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
