#!/bin/bash
# Initialize a persistent Codex reviewer session
# Creates a session with the init prompt and stores the session ID in state/session.json
#
# Usage: ./init-session.sh [project-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS_FILE="${PLUGIN_DIR}/settings.json"
STATE_DIR="${PLUGIN_DIR}/state"
SESSION_FILE="${STATE_DIR}/session.json"
INIT_PROMPT_FILE="${PLUGIN_DIR}/prompts/init.md"

# --- Load settings ---

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install: brew install jq" >&2
  exit 1
fi

CODEX_MODEL="gpt-5.3-codex"
CODEX_REASONING_EFFORT="xhigh"

if [[ -f "$SETTINGS_FILE" ]]; then
  CODEX_MODEL=$(jq -r '.model // "gpt-5.3-codex"' "$SETTINGS_FILE")
  CODEX_REASONING_EFFORT=$(jq -r '.reasoningEffort // "xhigh"' "$SETTINGS_FILE")
fi

PROJECT_DIR="${1:-$(pwd)}"

# --- Prerequisite checks ---

echo "=== Codex Plan Reviewer - Init Session ==="
echo ""

if ! command -v codex &>/dev/null; then
  echo "  ERROR: codex CLI not found"
  echo "  Install: https://github.com/openai/codex"
  exit 1
fi
echo "  codex: $(codex --version 2>/dev/null || echo 'installed')"

echo "  jq:    installed"
echo "  model: ${CODEX_MODEL}"
echo "  reasoning: ${CODEX_REASONING_EFFORT}"
echo "  project: ${PROJECT_DIR}"
echo ""

# --- Read init prompt ---

if [[ ! -f "$INIT_PROMPT_FILE" ]]; then
  echo "ERROR: ${INIT_PROMPT_FILE} not found" >&2
  exit 1
fi

INIT_PROMPT=$(cat "$INIT_PROMPT_FILE")

# --- Show existing session ---

EXISTING_SESSION=""
if [[ -f "$SESSION_FILE" ]]; then
  EXISTING_SESSION=$(jq -r '.sessionId // ""' "$SESSION_FILE")
fi

if [[ -n "$EXISTING_SESSION" ]]; then
  echo "  Existing session: ${EXISTING_SESSION}"
  read -p "  Create new session? (overwrites existing) [y/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "  Keeping existing session."
    exit 0
  fi
fi

# --- Create Codex session ---

echo "  Creating session..."

JSON_OUTPUT=$(codex exec \
  --json \
  -s read-only \
  -m "$CODEX_MODEL" \
  -c "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\"" \
  -C "$PROJECT_DIR" \
  "$INIT_PROMPT" 2>/dev/null) || true

if [[ -z "$JSON_OUTPUT" ]]; then
  echo "ERROR: codex exec returned no output" >&2
  exit 1
fi

# Extract thread_id from first JSON line
THREAD_ID=$(echo "$JSON_OUTPUT" | head -1 | jq -r '.thread_id // empty')

if [[ -z "$THREAD_ID" ]]; then
  echo "ERROR: Could not extract thread_id from codex output" >&2
  echo "First line: $(echo "$JSON_OUTPUT" | head -1)" >&2
  exit 1
fi

# Extract agent response
AGENT_RESPONSE=$(echo "$JSON_OUTPUT" | jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text' 2>/dev/null | head -5)

# --- Write session to state ---

mkdir -p "$STATE_DIR"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg sid "$THREAD_ID" \
  --arg ts "$TIMESTAMP" \
  --arg model "$CODEX_MODEL" \
  '{sessionId: $sid, createdAt: $ts, model: $model}' > "$SESSION_FILE"

echo ""
echo "  Session ID: ${THREAD_ID}"
echo "  Saved to:   ${SESSION_FILE}"
echo ""
if [[ -n "$AGENT_RESPONSE" ]]; then
  echo "  Codex says: ${AGENT_RESPONSE}"
  echo ""
fi
echo "Done. The hook will now use this session for plan reviews."
