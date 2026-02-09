#!/bin/bash
# Codex Plan Reviewer Hook
# PreToolUse hook on ExitPlanMode - sends plan to Codex for review
#
# Uses persistent sessions (codex exec resume) when CODEX_SESSION_ID is set,
# falls back to stateless codex exec otherwise.
#
# Exit codes:
# 0 = allow (approved, or graceful degradation on errors)
# 2 = block with feedback (revisions needed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${PLUGIN_DIR}/state"
HISTORY_FILE="${STATE_DIR}/review-history.md"
SETTINGS_FILE="${PLUGIN_DIR}/settings.json"
SESSION_FILE="${STATE_DIR}/session.json"
REVIEW_PROMPT_FILE="${PLUGIN_DIR}/prompts/review.md"

# --- Guard clauses ---

# Bypass if env var set
[[ "${SKIP_CODEX_REVIEW:-}" == "1" ]] && exit 0

# Require jq and codex (silent degradation — use init-session.sh to diagnose)
command -v jq &>/dev/null || exit 0
command -v codex &>/dev/null || exit 0

# --- Load settings ---

CODEX_MODEL="gpt-5.3-codex"
CODEX_REASONING_EFFORT="xhigh"
CODEX_SESSION_ID=""

if [[ -f "$SETTINGS_FILE" ]]; then
  CODEX_MODEL=$(jq -r '.model // "gpt-5.3-codex"' "$SETTINGS_FILE")
  CODEX_REASONING_EFFORT=$(jq -r '.reasoningEffort // "xhigh"' "$SETTINGS_FILE")
fi

if [[ -f "$SESSION_FILE" ]]; then
  CODEX_SESSION_ID=$(jq -r '.sessionId // ""' "$SESSION_FILE")
fi

# --- Read hook input ---

INPUT=$(cat 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$(pwd)"

# --- Find the plan file ---

# shellcheck disable=SC2012
PLAN_FILE=$(ls -t ~/.claude/plans/*.md 2>/dev/null | head -1) || true
if [[ -z "$PLAN_FILE" ]] || [[ ! -f "$PLAN_FILE" ]]; then
  exit 0
fi

PLAN_CONTENT=$(cat "$PLAN_FILE")
[[ -z "$PLAN_CONTENT" ]] && exit 0

# --- Build review prompt ---

if [[ -f "$REVIEW_PROMPT_FILE" ]]; then
  REVIEW_TEMPLATE=$(cat "$REVIEW_PROMPT_FILE")
  REVIEW_PROMPT="${REVIEW_TEMPLATE//\{\{PLAN_CONTENT\}\}/$PLAN_CONTENT}"
else
  # Fallback if prompt file is missing
  REVIEW_PROMPT="Review the following implementation plan:

---
${PLAN_CONTENT}
---

Start your response with APPROVED or REVISIONS_NEEDED."
fi

# --- Call Codex ---

RESPONSE=""

if [[ -n "$CODEX_SESSION_ID" ]]; then
  # Persistent session: resume existing conversation
  if RESPONSE=$(codex exec resume \
    "$CODEX_SESSION_ID" \
    "$REVIEW_PROMPT" \
    -m "$CODEX_MODEL" \
    -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
    2>/dev/null); then
    : # success
  else
    CODEX_SESSION_ID=""  # resume failed, fall back to stateless
  fi
fi

if [[ -z "$CODEX_SESSION_ID" ]] && [[ -z "$RESPONSE" ]]; then
  # Stateless fallback: fresh codex exec
  if RESPONSE=$(codex exec \
    -s read-only \
    -m "$CODEX_MODEL" \
    -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
    -C "$PROJECT_DIR" \
    "$REVIEW_PROMPT" 2>/dev/null); then
    : # success
  else
    exit 0
  fi
fi

[[ -z "$RESPONSE" ]] && exit 0

# --- Log to review history ---

mkdir -p "$STATE_DIR"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PLAN_BASENAME=$(basename "$PLAN_FILE")

{
  echo ""
  echo "## Review ${TIMESTAMP}"
  echo "Plan: ${PLAN_BASENAME}"
  echo "Session: ${CODEX_SESSION_ID:-stateless}"
  echo "Response:"
  echo "$RESPONSE" | head -50
} >> "$HISTORY_FILE"

# --- Parse verdict ---

FIRST_LINE=$(echo "$RESPONSE" | head -1)

if echo "$FIRST_LINE" | grep -qi "APPROVED"; then
  exit 0
fi

# Default: treat as revisions needed
FEEDBACK="[CODEX PLAN REVIEW - REVISIONS NEEDED]

${RESPONSE}

---
Revise the plan to address the issues above, then call ExitPlanMode again."

jq -n \
  --arg ctx "$FEEDBACK" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "additionalContext": $ctx
    }
  }'

exit 2
