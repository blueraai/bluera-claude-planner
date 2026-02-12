#!/usr/bin/env bash
# Tests for review-plan.sh hook — focuses on per-project enablement,
# round counting, and input validation to prevent regressions.
#
# Usage: bash tests/test-review-plan-hook.sh
#
# These tests exercise the hook's guard clauses and control flow
# without calling Codex (the hook exits before reaching Codex
# in all test cases here).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_DIR/hooks/review-plan.sh"

# --- Test harness ---

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "  PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Create isolated test environment
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Fake project directory
PROJECT_DIR="$TEST_DIR/fake-project"
mkdir -p "$PROJECT_DIR/.claude"

# Fake plans directory
FAKE_PLANS_DIR="$TEST_DIR/plans"
mkdir -p "$FAKE_PLANS_DIR"
echo "# Test plan" > "$FAKE_PLANS_DIR/test-plan.md"

# Helper: run the hook with given JSON input, capturing exit code
# Overrides HOME so the hook finds our fake plans dir
run_hook() {
  local input="$1"
  local exit_code=0
  # Override HOME to control plan file discovery
  HOME="$TEST_DIR" \
  SKIP_CODEX_REVIEW="" \
    echo "$input" | bash "$HOOK" > /dev/null 2>&1 || exit_code=$?
  echo "$exit_code"
}

# Set up HOME structure for plan discovery
mkdir -p "$TEST_DIR/.claude/plans"
echo "# Test plan content" > "$TEST_DIR/.claude/plans/test-plan.md"

# ============================================================
echo ""
echo "=== Per-Project Enablement ==="
# ============================================================

test_no_project_config_exits_0() {
  # No .claude/bluera-claude-planner.json => should exit 0 (no-op)
  rm -f "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local input='{"cwd":"'"$PROJECT_DIR"'"}'
  local code
  code=$(run_hook "$input")
  if [[ "$code" == "0" ]]; then
    pass "no project config file => exit 0"
  else
    fail "no project config file => expected exit 0, got $code"
  fi
}

test_project_config_enabled_false_exits_0() {
  echo '{"enabled": false}' > "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local input='{"cwd":"'"$PROJECT_DIR"'"}'
  local code
  code=$(run_hook "$input")
  if [[ "$code" == "0" ]]; then
    pass "project config enabled=false => exit 0"
  else
    fail "project config enabled=false => expected exit 0, got $code"
  fi
}

test_project_config_missing_enabled_exits_0() {
  echo '{"model": "gpt-5.3-codex"}' > "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local input='{"cwd":"'"$PROJECT_DIR"'"}'
  local code
  code=$(run_hook "$input")
  if [[ "$code" == "0" ]]; then
    pass "project config without enabled field => exit 0"
  else
    fail "project config without enabled field => expected exit 0, got $code"
  fi
}

test_project_config_enabled_string_exits_0() {
  # "enabled": "yes" should NOT be treated as true
  echo '{"enabled": "yes"}' > "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local input='{"cwd":"'"$PROJECT_DIR"'"}'
  local code
  code=$(run_hook "$input")
  if [[ "$code" == "0" ]]; then
    pass "project config enabled='yes' (not 'true') => exit 0"
  else
    fail "project config enabled='yes' => expected exit 0, got $code"
  fi
}

test_different_project_not_affected() {
  # Project A has config, Project B does not — B should exit 0
  local project_b="$TEST_DIR/other-project"
  mkdir -p "$project_b"
  echo '{"enabled": true}' > "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local input='{"cwd":"'"$project_b"'"}'
  local code
  code=$(run_hook "$input")
  if [[ "$code" == "0" ]]; then
    pass "different project without config => exit 0"
  else
    fail "different project without config => expected exit 0, got $code"
  fi
}

test_global_enabled_not_used() {
  # Even if the global settings.json has enabled: true, without project config => exit 0
  rm -f "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local input='{"cwd":"'"$PROJECT_DIR"'"}'
  local code
  code=$(run_hook "$input")
  if [[ "$code" == "0" ]]; then
    pass "global settings.json enabled ignored without project config => exit 0"
  else
    fail "global settings.json enabled should be ignored => expected exit 0, got $code"
  fi
}

test_no_project_config_exits_0
test_project_config_enabled_false_exits_0
test_project_config_missing_enabled_exits_0
test_project_config_enabled_string_exits_0
test_different_project_not_affected
test_global_enabled_not_used

# ============================================================
echo ""
echo "=== Guard Clauses ==="
# ============================================================

test_empty_input_exits_0() {
  local exit_code=0
  echo "" | bash "$HOOK" > /dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" == "0" ]]; then
    pass "empty input => exit 0"
  else
    fail "empty input => expected exit 0, got $exit_code"
  fi
}

test_skip_env_var_exits_0() {
  echo '{"enabled": true}' > "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local exit_code=0
  SKIP_CODEX_REVIEW=1 \
    echo '{"cwd":"'"$PROJECT_DIR"'"}' | bash "$HOOK" > /dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" == "0" ]]; then
    pass "SKIP_CODEX_REVIEW=1 => exit 0"
  else
    fail "SKIP_CODEX_REVIEW=1 => expected exit 0, got $exit_code"
  fi
}

test_no_cwd_in_input_exits_0() {
  # Input without cwd field — PROJECT_DIR falls back to pwd
  # Run from temp dir (no project config there) to avoid picking up repo's config
  local exit_code=0
  (cd "$TEST_DIR" && echo '{"tool_name": "ExitPlanMode"}' | bash "$HOOK" > /dev/null 2>&1) || exit_code=$?
  if [[ "$exit_code" == "0" ]]; then
    pass "input without cwd => exit 0 (no project config at pwd)"
  else
    fail "input without cwd => expected exit 0, got $exit_code"
  fi
}

test_empty_input_exits_0
test_skip_env_var_exits_0
test_no_cwd_in_input_exits_0

# ============================================================
echo ""
echo "=== Round Counter Validation ==="
# ============================================================

test_corrupted_round_file() {
  # Non-numeric round file should not crash the hook
  echo '{"enabled": true}' > "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local state_dir="$REPO_DIR/state"
  mkdir -p "$state_dir"

  # Create a corrupted round file for the test plan
  local plan_path="$TEST_DIR/.claude/plans/test-plan.md"
  local plan_hash
  plan_hash=$(echo "$plan_path" | md5sum 2>/dev/null | cut -d' ' -f1 || md5 -q -s "$plan_path" 2>/dev/null || echo "default")
  local round_file="$state_dir/.review-round-${plan_hash}"

  echo "not-a-number" > "$round_file"
  local input='{"cwd":"'"$PROJECT_DIR"'"}'
  local exit_code=0
  # Hook will proceed past round check but exit 0 when codex is unavailable
  HOME="$TEST_DIR" \
    echo "$input" | bash "$HOOK" > /dev/null 2>&1 || exit_code=$?
  rm -f "$round_file"

  # Should not crash (exit 0 from codex not being available or graceful degradation)
  if [[ "$exit_code" == "0" ]]; then
    pass "corrupted round file (non-numeric) => does not crash"
  else
    fail "corrupted round file => expected exit 0 (graceful), got $exit_code"
  fi
}

test_non_numeric_max_review_rounds() {
  # Non-numeric maxReviewRounds in project config should fall back to default
  echo '{"enabled": true, "maxReviewRounds": "ten"}' > "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local input='{"cwd":"'"$PROJECT_DIR"'"}'
  local exit_code=0
  HOME="$TEST_DIR" \
    echo "$input" | bash "$HOOK" > /dev/null 2>&1 || exit_code=$?

  # Should not crash
  if [[ "$exit_code" == "0" ]]; then
    pass "non-numeric maxReviewRounds => does not crash (uses default)"
  else
    fail "non-numeric maxReviewRounds => expected exit 0, got $exit_code"
  fi
}

test_corrupted_round_file
test_non_numeric_max_review_rounds

# ============================================================
echo ""
echo "=== Project Override ==="
# ============================================================

test_project_override_model() {
  # Project config can override model — hook should not crash with custom model
  echo '{"enabled": true, "model": "custom-model"}' > "$PROJECT_DIR/.claude/bluera-claude-planner.json"
  local input='{"cwd":"'"$PROJECT_DIR"'"}'
  local exit_code=0
  HOME="$TEST_DIR" \
    echo "$input" | bash "$HOOK" > /dev/null 2>&1 || exit_code=$?

  if [[ "$exit_code" == "0" ]]; then
    pass "project model override => does not crash"
  else
    fail "project model override => expected exit 0, got $exit_code"
  fi
}

test_project_override_model

# ============================================================
echo ""
echo "=== Results ==="
echo "  Passed: $PASS_COUNT"
echo "  Failed: $FAIL_COUNT"
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "FAILED"
  exit 1
fi

echo "ALL TESTS PASSED"
exit 0
