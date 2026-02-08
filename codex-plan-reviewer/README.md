# codex-plan-reviewer

A Claude Code plugin that uses OpenAI's Codex CLI as an automated plan reviewer. When Claude finishes writing a plan and calls `ExitPlanMode`, this hook intercepts the call, sends the plan to Codex for review, and blocks plan mode exit until Codex approves. Claude auto-revises based on feedback and resubmits.

## Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- `jq`

## Installation

```bash
claude --plugin-dir ./codex-plan-reviewer
```

## Usage

Use Claude Code in plan mode as normal. The hook fires automatically when Claude calls `ExitPlanMode`:

```
Claude: [writes plan, calls ExitPlanMode]
         ──── "Codex reviewing plan..." (30-60s) ────
Codex:  REVISIONS_NEEDED
        1. No session expiry strategy
        2. Missing CSRF protection
Claude: [auto-revises plan, calls ExitPlanMode again]
         ──── "Codex reviewing plan..." (30-60s) ────
Codex:  APPROVED
Claude: [exits plan mode, begins implementation]
```

### Bypass

Skip Codex review for a session:

```bash
SKIP_CODEX_REVIEW=1 claude --plugin-dir ./codex-plan-reviewer
```

### Init / Reset

Check prerequisites and optionally clear review history:

```bash
./codex-plan-reviewer/scripts/init-reviewer.sh
```

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
Build prompt: system prompt + review history + plan
       │
       ▼
codex exec -s read-only -C <project>
       │
       ├── APPROVED → exit 0 → plan mode exits
       │
       └── REVISIONS_NEEDED → exit 2 + additionalContext
              → Claude sees feedback, revises, retries
```

The hook calls `codex exec -s read-only` (sandboxed, non-interactive). Codex evaluates the plan against four criteria: goal achievement, edge case coverage, implementation specificity, and test/verification coverage.

## Architecture

```
codex-plan-reviewer/
├── .claude-plugin/
│   └── plugin.json          # Plugin manifest
├── hooks/
│   ├── hooks.json           # PreToolUse on ExitPlanMode (180s timeout)
│   └── review-plan.sh       # Core hook script
├── scripts/
│   └── init-reviewer.sh     # Setup / reset tool
├── state/
│   ├── .gitkeep
│   └── review-history.md    # Accumulated reviews (gitignored)
└── .gitignore
```

### Review History

Each review is appended to `state/review-history.md`. This file persists across Claude Code sessions, giving Codex context about prior reviews (e.g., "you fixed issue 1 but not issue 2"). The last 50 lines are included in each prompt.

```markdown
## Review 2026-02-07T17:06:28Z
Plan: test-plan.md
Response:
REVISIONS_NEEDED
1. Missing rollback strategy...

## Review 2026-02-07T17:07:10Z
Plan: test-plan.md
Response:
APPROVED
All issues addressed.
```

## Error Handling

Failures are always permissive - a broken reviewer never blocks the user.

| Scenario | Behavior |
|---|---|
| `codex` not installed | Allow (warn on stderr) |
| `jq` not installed | Allow |
| Codex times out (>180s) | Allow |
| No plan file found | Allow |
| Network failure | Allow |
| Unparseable response | Allow |
