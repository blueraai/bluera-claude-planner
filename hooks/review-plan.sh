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

# --- Guard clauses ---

# Bypass if env var set
[[ "${SKIP_CODEX_REVIEW:-}" == "1" ]] && exit 0

# Require jq and codex (silent degradation — use init-session.sh to diagnose)
command -v jq &>/dev/null || exit 0
command -v codex &>/dev/null || exit 0

# --- Read hook input (needed early for project-scoped checks) ---

INPUT=$(cat 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$(pwd)"

# --- Per-project opt-in ---
# Only run if the project has explicitly enabled the planner.
# Projects opt in by creating .claude/bluera-claude-planner.json with {"enabled": true}

PROJECT_CONFIG="${PROJECT_DIR}/.claude/bluera-claude-planner.json"
if [[ ! -f "$PROJECT_CONFIG" ]]; then
  exit 0
fi
PROJECT_ENABLED=$(jq -r '.enabled // false' "$PROJECT_CONFIG" 2>/dev/null)
[[ "$PROJECT_ENABLED" != "true" ]] && exit 0

# --- Load settings (defaults from plugin, overrides from project) ---

CODEX_MODEL="gpt-5.3-codex"
CODEX_REASONING_EFFORT="xhigh"
CODEX_SESSION_ID=""
REVIEW_TEMPLATE=""
MAX_REVIEW_ROUNDS=10

# Plugin defaults
if [[ -f "$SETTINGS_FILE" ]]; then
  CODEX_MODEL=$(jq -r '.model // "gpt-5.3-codex"' "$SETTINGS_FILE")
  CODEX_REASONING_EFFORT=$(jq -r '.reasoningEffort // "xhigh"' "$SETTINGS_FILE")
  REVIEW_TEMPLATE=$(jq -r '.reviewPrompt // ""' "$SETTINGS_FILE")
  RAW_MAX=$(jq -r '.maxReviewRounds // 10' "$SETTINGS_FILE")
  [[ "$RAW_MAX" =~ ^[0-9]+$ ]] && MAX_REVIEW_ROUNDS="$RAW_MAX"
fi

# Project overrides (model, reasoningEffort, maxReviewRounds)
PROJ_MODEL=$(jq -r '.model // empty' "$PROJECT_CONFIG" 2>/dev/null)
[[ -n "$PROJ_MODEL" ]] && CODEX_MODEL="$PROJ_MODEL"
PROJ_EFFORT=$(jq -r '.reasoningEffort // empty' "$PROJECT_CONFIG" 2>/dev/null)
[[ -n "$PROJ_EFFORT" ]] && CODEX_REASONING_EFFORT="$PROJ_EFFORT"
PROJ_MAX=$(jq -r '.maxReviewRounds // empty' "$PROJECT_CONFIG" 2>/dev/null)
[[ "$PROJ_MAX" =~ ^[0-9]+$ ]] && MAX_REVIEW_ROUNDS="$PROJ_MAX"

if [[ -f "$SESSION_FILE" ]]; then
  CODEX_SESSION_ID=$(jq -r '.sessionId // ""' "$SESSION_FILE")
fi

# --- Find the plan file ---

# shellcheck disable=SC2012
PLAN_FILE=$(ls -t ~/.claude/plans/*.md 2>/dev/null | head -1) || true
if [[ -z "$PLAN_FILE" ]] || [[ ! -f "$PLAN_FILE" ]]; then
  exit 0
fi

PLAN_CONTENT=$(cat "$PLAN_FILE")
[[ -z "$PLAN_CONTENT" ]] && exit 0

# --- Round counter (prevent infinite loops) ---

mkdir -p "$STATE_DIR"
PLAN_HASH=$(echo "$PLAN_FILE" | md5sum 2>/dev/null | cut -d' ' -f1 || md5 -q -s "$PLAN_FILE" 2>/dev/null || echo "default")
ROUND_FILE="${STATE_DIR}/.review-round-${PLAN_HASH}"

CURRENT_ROUND=0
if [[ -f "$ROUND_FILE" ]]; then
  RAW_ROUND=$(cat "$ROUND_FILE")
  [[ "$RAW_ROUND" =~ ^[0-9]+$ ]] && CURRENT_ROUND="$RAW_ROUND"
fi

# --- Build review prompt ---

if [[ -z "$REVIEW_TEMPLATE" ]]; then
  REVIEW_TEMPLATE="Review the following implementation plan:\n\n---\n{{PLAN_CONTENT}}\n---\n\nStart your response with APPROVED or REVISIONS_NEEDED."
fi

# Substitute plan content into template
REVIEW_PROMPT="${REVIEW_TEMPLATE//\{\{PLAN_CONTENT\}\}/$PLAN_CONTENT}"

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
  rm -f "$ROUND_FILE"
  exit 0
fi

# --- Increment round only on REVISIONS_NEEDED ---

CURRENT_ROUND=$(( CURRENT_ROUND + 1 ))
echo "$CURRENT_ROUND" > "$ROUND_FILE"

if [[ "$CURRENT_ROUND" -gt "$MAX_REVIEW_ROUNDS" ]]; then
  # Auto-approve to prevent infinite loop — log for traceability
  {
    echo ""
    echo "## Auto-approved ${TIMESTAMP}"
    echo "Plan: ${PLAN_BASENAME}"
    echo "Reason: max review rounds (${MAX_REVIEW_ROUNDS}) exceeded"
  } >> "$HISTORY_FILE"
  rm -f "$ROUND_FILE"
  exit 0
fi

# Default: treat as revisions needed
FEEDBACK="[CODEX PLAN REVIEW - REVISIONS NEEDED] (round ${CURRENT_ROUND}/${MAX_REVIEW_ROUNDS})

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
