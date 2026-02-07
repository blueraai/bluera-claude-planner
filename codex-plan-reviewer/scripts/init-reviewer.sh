#!/bin/bash
# Initialize or reset the Codex plan reviewer
# Usage: ./init-reviewer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${PLUGIN_DIR}/state"
HISTORY_FILE="${STATE_DIR}/review-history.md"

echo "=== Codex Plan Reviewer - Init ==="
echo ""

# Check codex
if command -v codex &>/dev/null; then
  CODEX_VERSION=$(codex --version 2>/dev/null || echo "unknown")
  echo "  codex: installed (${CODEX_VERSION})"
else
  echo "  codex: NOT FOUND"
  echo "  Install: https://github.com/openai/codex"
  exit 1
fi

# Check jq
if command -v jq &>/dev/null; then
  echo "  jq:    installed"
else
  echo "  jq:    NOT FOUND"
  echo "  Install: brew install jq"
  exit 1
fi

# Create/reset state
mkdir -p "$STATE_DIR"

if [[ -f "$HISTORY_FILE" ]]; then
  LINES=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
  echo ""
  echo "  Review history: ${LINES} lines"
  read -p "  Reset review history? [y/N] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f "$HISTORY_FILE"
    echo "  History cleared."
  else
    echo "  History preserved."
  fi
else
  echo ""
  echo "  Review history: empty (fresh start)"
fi

echo ""
echo "  Plugin dir: ${PLUGIN_DIR}"
echo "  State dir:  ${STATE_DIR}"
echo ""
echo "  Usage: claude --plugin-dir ${PLUGIN_DIR}"
echo "  Bypass: SKIP_CODEX_REVIEW=1 claude ..."
echo ""
echo "Ready."
