# bluera-claude-planner

A Claude Code plugin that uses OpenAI's Codex CLI as an automated plan reviewer. When Claude finishes writing a plan and calls `ExitPlanMode`, this hook intercepts the call, sends the plan to Codex for review, and blocks plan mode exit until Codex approves. Claude auto-revises based on feedback and resubmits.

## Prerequisites

- [Claude Code](https://claude.ai/claude-code)
- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- `jq`

## Quick Start

```bash
# 1. Install the plugin (via marketplace or local)
claude --plugin-dir .

# 2. Enable for this project
/bluera-claude-planner:toggle

# 3. Initialize a persistent Codex session (optional, improves context)
./scripts/init-session.sh

# 4. Use plan mode as normal — Codex reviews automatically
```

## Per-Project Enablement

The planner is **disabled by default** and must be enabled per-project. This prevents the hook from running in unrelated projects.

Projects opt in by creating `.claude/bluera-claude-planner.json` in the project root:

```json
{"enabled": true}
```

The easiest way is the slash command:

```
/bluera-claude-planner:toggle
```

Missing file, missing `enabled` field, or `enabled: false` all mean disabled.

## Configuration

Configuration uses a two-tier precedence model:

1. **Plugin defaults** in `settings.json` (shipped with the plugin)
2. **Per-project overrides** in `.claude/bluera-claude-planner.json` (in your project root)

### Plugin defaults (`settings.json`)

| Key | Default | Description |
|-----|---------|-------------|
| `model` | `gpt-5.3-codex` | Model for Codex to use |
| `reasoningEffort` | `xhigh` | Reasoning effort: `low`, `medium`, `high`, `xhigh` |
| `initPrompt` | *(system prompt)* | Sent once when creating a session |
| `reviewPrompt` | *(review template)* | Sent per review. `{{PLAN_CONTENT}}` is replaced with the plan. Requests structured feedback with severity tags and a plan diff. |
| `maxReviewRounds` | `10` | Max review iterations before auto-approving to prevent infinite loops |

### Per-project overrides (`.claude/bluera-claude-planner.json`)

| Key | Description |
|-----|-------------|
| `enabled` | `true` to enable reviews for this project |
| `model` | Override the Codex model |
| `reasoningEffort` | Override reasoning effort |
| `maxReviewRounds` | Override max rounds |

### Bypass

Set `SKIP_CODEX_REVIEW=1` as an environment variable to bypass for a single session.

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
Check .claude/bluera-claude-planner.json → enabled?
       │ NO (or missing) → exit 0 (pass through)
       │ YES ↓
       ▼
Read plan from ~/.claude/plans/
       │
       ▼
Load reviewPrompt, substitute {{PLAN_CONTENT}}
       │
       ▼
┌─ CODEX_SESSION_ID set? ──────────────────────────┐
│ YES: codex exec resume <id> "prompt" -m <model>  │
│ NO:  codex exec -s read-only -m <model> "prompt"  │
└───────────────────────────────────────────────────┘
       │
       ├── APPROVED → reset round counter → exit 0 → plan mode exits
       │
       └── REVISIONS_NEEDED → increment round counter
              │
              ├── round > maxReviewRounds → auto-approve (logged)
              │
              └── exit 2 + additionalContext (round N/max)
                     → Claude sees feedback, revises, retries
```

## Architecture

```
bluera-claude-planner/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── hooks/
│   ├── hooks.json               # PreToolUse on ExitPlanMode (180s timeout)
│   └── review-plan.sh           # Core hook script
├── scripts/
│   └── init-session.sh          # Create/reset Codex session
├── skills/
│   └── toggle/
│       └── SKILL.md             # /bluera-claude-planner:toggle slash command
├── tests/
│   └── test-review-plan-hook.sh # Hook tests (12 cases, runs in CI)
├── state/                       # Runtime state (gitignored)
│   ├── session.json             # Session ID and metadata
│   ├── review-history.md        # Audit log of all reviews
│   └── .review-round-*          # Per-plan round counters
├── settings.json                # Plugin defaults (model, prompts, maxReviewRounds)
└── .github/workflows/
    ├── ci.yml                   # shellcheck + syntax + tests (npm test)
    ├── auto-release.yml         # Tags after CI passes
    ├── release.yml              # GitHub release on tag
    └── update-marketplace.yml   # Syncs version to bluera-marketplace
```

Per-project config (in your project root, not part of the plugin):
```
your-project/
└── .claude/
    └── bluera-claude-planner.json  # {"enabled": true} to opt in
```

## Error Handling

Failures are always permissive — a broken reviewer never blocks the user.

| Scenario | Behavior |
|---|---|
| `codex` not installed | Allow |
| `jq` not installed | Allow |
| Codex times out (>180s) | Allow |
| Session resume fails | Falls back to stateless `codex exec` |
| No plan file found | Allow |
| Network failure | Allow |
| Unparseable response | Allow |
| Max review rounds exceeded | Auto-approve (logged to review history) |
| Corrupted round/config file | Graceful fallback to defaults |
| No project config file | Allow (hook is a no-op) |
