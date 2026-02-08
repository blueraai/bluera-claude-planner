#!/bin/bash
# Initialize a persistent Codex reviewer session
# Creates a session with the init prompt and stores the session ID in .env
#
# Usage: ./init-session.sh [project-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${PLUGIN_DIR}/.env"
INIT_PROMPT_FILE="${PLUGIN_DIR}/prompts/init.md"

# --- Load .env ---

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "${PLUGIN_DIR}/.env.example" ]]; then
    cp "${PLUGIN_DIR}/.env.example" "$ENV_FILE"
    echo "Created .env from .env.example"
  else
    echo "ERROR: No .env or .env.example found" >&2
    exit 1
  fi
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

PROJECT_DIR="${1:-$(pwd)}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.3-codex}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"

# --- Prerequisite checks ---

echo "=== Codex Plan Reviewer - Init Session ==="
echo ""

if ! command -v codex &>/dev/null; then
  echo "  ERROR: codex CLI not found"
  echo "  Install: https://github.com/openai/codex"
  exit 1
fi
echo "  codex: $(codex --version 2>/dev/null || echo 'installed')"

if ! command -v jq &>/dev/null; then
  echo "  ERROR: jq not found"
  echo "  Install: brew install jq"
  exit 1
fi
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

if [[ -n "${CODEX_SESSION_ID:-}" ]]; then
  echo "  Existing session: ${CODEX_SESSION_ID}"
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

# --- Write session ID to .env ---

if grep -q '^CODEX_SESSION_ID=' "$ENV_FILE"; then
  # Update existing line
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/^CODEX_SESSION_ID=.*/CODEX_SESSION_ID=${THREAD_ID}/" "$ENV_FILE"
  else
    sed -i "s/^CODEX_SESSION_ID=.*/CODEX_SESSION_ID=${THREAD_ID}/" "$ENV_FILE"
  fi
else
  echo "CODEX_SESSION_ID=${THREAD_ID}" >> "$ENV_FILE"
fi

echo ""
echo "  Session ID: ${THREAD_ID}"
echo "  Saved to:   ${ENV_FILE}"
echo ""
if [[ -n "$AGENT_RESPONSE" ]]; then
  echo "  Codex says: ${AGENT_RESPONSE}"
  echo ""
fi
echo "Done. The hook will now use this session for plan reviews."
