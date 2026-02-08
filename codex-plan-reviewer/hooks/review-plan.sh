#!/bin/bash
# Codex Plan Reviewer Hook
# PreToolUse hook on ExitPlanMode - sends plan to Codex for review
#
# Exit codes:
# 0 = allow (approved, or graceful degradation on errors)
# 2 = block with feedback (revisions needed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${PLUGIN_DIR}/state"
HISTORY_FILE="${STATE_DIR}/review-history.md"

# --- Guard clauses ---

# Bypass if env var set
[[ "${SKIP_CODEX_REVIEW:-}" == "1" ]] && exit 0

# Require jq
if ! command -v jq &>/dev/null; then
  echo "codex-plan-reviewer: jq not found, skipping review" >&2
  exit 0
fi

# Require codex
if ! command -v codex &>/dev/null; then
  echo "codex-plan-reviewer: codex CLI not found, skipping review" >&2
  exit 0
fi

# --- Read hook input ---

INPUT=$(cat 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$(pwd)"

# --- Find the plan file ---

PLAN_FILE=$(ls -t ~/.claude/plans/*.md 2>/dev/null | head -1) || true
if [[ -z "$PLAN_FILE" ]] || [[ ! -f "$PLAN_FILE" ]]; then
  echo "codex-plan-reviewer: no plan file found, skipping review" >&2
  exit 0
fi

PLAN_CONTENT=$(cat "$PLAN_FILE")
if [[ -z "$PLAN_CONTENT" ]]; then
  echo "codex-plan-reviewer: plan file is empty, skipping review" >&2
  exit 0
fi

# --- Build review history context ---

mkdir -p "$STATE_DIR"

REVIEW_HISTORY=""
if [[ -f "$HISTORY_FILE" ]]; then
  # Include last 50 lines of history to stay within context limits
  REVIEW_HISTORY=$(tail -50 "$HISTORY_FILE")
fi

# --- Build the prompt ---

SYSTEM_PROMPT='You are a senior software architect reviewing an implementation plan created by another AI coding assistant (Claude Code).

Evaluate:
1. Will this plan achieve the stated goals?
2. Are there missing edge cases or error handling gaps?
3. Is the plan specific enough to implement without ambiguity?
4. Does it account for testing and verification?

Response format:
- If acceptable: Start with "APPROVED" on its own line, then any minor notes
- If needs work: Start with "REVISIONS_NEEDED" on its own line, then numbered specific issues that must be addressed

Be concise. Focus on substantive issues, not style preferences.'

FULL_PROMPT="${SYSTEM_PROMPT}

---

PROJECT DIRECTORY: ${PROJECT_DIR}"

if [[ -n "$REVIEW_HISTORY" ]]; then
  FULL_PROMPT="${FULL_PROMPT}

PRIOR REVIEW HISTORY (for context on what was previously reviewed/flagged):
${REVIEW_HISTORY}"
fi

FULL_PROMPT="${FULL_PROMPT}

---

PLAN TO REVIEW:

${PLAN_CONTENT}

---

Review this plan now. Start your response with APPROVED or REVISIONS_NEEDED."

# --- Call Codex ---

RESPONSE=""
if RESPONSE=$(codex exec \
  -s read-only \
  -C "$PROJECT_DIR" \
  "$FULL_PROMPT" 2>/dev/null); then
  : # success
else
  echo "codex-plan-reviewer: codex exec failed (exit $?), allowing plan through" >&2
  exit 0
fi

if [[ -z "$RESPONSE" ]]; then
  echo "codex-plan-reviewer: empty response from codex, allowing plan through" >&2
  exit 0
fi

# --- Log to review history ---

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PLAN_BASENAME=$(basename "$PLAN_FILE")

{
  echo ""
  echo "## Review ${TIMESTAMP}"
  echo "Plan: ${PLAN_BASENAME}"
  # Extract just the first line (verdict) and first ~10 lines of feedback
  echo "Response:"
  echo "$RESPONSE" | head -15
} >> "$HISTORY_FILE"

# --- Parse verdict ---

FIRST_LINE=$(echo "$RESPONSE" | head -1)

if echo "$FIRST_LINE" | grep -qi "APPROVED"; then
  # Plan approved - allow ExitPlanMode
  exit 0
fi

# Default: treat as revisions needed (including REVISIONS_NEEDED or unparseable)
# Build feedback message for Claude
FEEDBACK="[CODEX PLAN REVIEW - REVISIONS NEEDED]

${RESPONSE}

---
Revise the plan to address the issues above, then call ExitPlanMode again."

# Output hook JSON with additionalContext and block ExitPlanMode
jq -n \
  --arg ctx "$FEEDBACK" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "additionalContext": $ctx
    }
  }'

exit 2
