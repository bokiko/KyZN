#!/usr/bin/env bash
# kyzn/tests/selftest.sh — Comprehensive self-test suite
# Usage: kyzn selftest [--quick|--full|--stress]
set -euo pipefail

# Portable symlink resolution (readlink -f doesn't exist on macOS)
_resolve() {
    local f="$1"; local d=0
    while [[ -L "$f" ]]; do
        (( d++ > 20 )) && break
        local dir; dir="$(cd "$(dirname "$f")" && pwd)"
        f="$(readlink "$f")"; [[ "$f" != /* ]] && f="$dir/$f"
    done
    echo "$f"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve "${BASH_SOURCE[0]}")")" && pwd)"
KYZN_ROOT="$(dirname "$SCRIPT_DIR")"
source "$KYZN_ROOT/lib/core.sh"

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILURES=()

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$1: $2"); echo -e "  ${RED}✗${RESET} $1 — $2"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); echo -e "  ${DIM}⊘${RESET} $1 — skipped ($2)"; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "output does not contain '$needle'"
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "output should not contain '$needle'"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        pass "$label"
    else
        fail "$label" "file not found: $path"
    fi
}

assert_exit_code() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "exit code $actual (expected $expected)"
    fi
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------
SANDBOX=""

create_sandbox() {
    local type="${1:-generic}"
    SANDBOX=$(mktemp -d)
    cd "$SANDBOX"
    git init -q
    git commit --allow-empty -m "init" -q

    case "$type" in
        node)
            echo '{"name":"test-project","scripts":{"test":"echo ok","build":"echo ok"}}' > package.json
            echo '{}' > tsconfig.json
            mkdir -p src tests
            echo 'console.log("hello")' > src/index.js
            ;;
        python)
            cat > pyproject.toml <<'TOML'
[project]
name = "test-project"
version = "0.1.0"
TOML
            mkdir -p tests
            echo 'def test_ok(): assert True' > tests/test_basic.py
            ;;
        rust)
            mkdir -p src
            echo '[package]' > Cargo.toml
            echo 'name = "test-project"' >> Cargo.toml
            echo 'version = "0.1.0"' >> Cargo.toml
            echo 'fn main() {}' > src/main.rs
            ;;
        go)
            echo 'module test-project' > go.mod
            echo 'go 1.21' >> go.mod
            echo 'package main' > main.go
            ;;
        generic)
            mkdir -p scripts tests
            echo '#!/bin/bash' > scripts/run.sh
            chmod +x scripts/run.sh
            echo 'echo test' > tests/test.sh
            ;;
    esac

    # Add CI dir for detection
    mkdir -p .github/workflows
    echo 'name: ci' > .github/workflows/ci.yml

    git add -A && git commit -q -m "scaffold $type project"
}

cleanup_sandbox() {
    cd "$KYZN_ROOT"
    if [[ -n "$SANDBOX" && -d "$SANDBOX" ]]; then
        rm -rf "$SANDBOX"
    fi
    SANDBOX=""
}

# ---------------------------------------------------------------------------
# Test suites
# ---------------------------------------------------------------------------

test_core() {
    log_header "1. Core library tests"

    # generate_run_id
    local rid
    rid=$(generate_run_id)
    assert_contains "run_id has date" "$rid" "$(date +%Y%m%d)"
    [[ ${#rid} -ge 20 ]] && pass "run_id length >= 20" || fail "run_id length" "got ${#rid}"

    # Two run IDs should be different
    local rid2
    rid2=$(generate_run_id)
    if [[ "$rid" != "$rid2" ]]; then
        pass "run_id uniqueness"
    else
        fail "run_id uniqueness" "two calls returned same ID"
    fi

    # truncate_str
    local short
    short=$(truncate_str "hello world" 5)
    assert_eq "truncate short" "he..." "$short"

    local noop
    noop=$(truncate_str "hi" 10)
    assert_eq "truncate noop" "hi" "$noop"

    # timestamp
    local ts
    ts=$(timestamp)
    assert_contains "timestamp ISO format" "$ts" "T"
    assert_contains "timestamp ends with Z" "$ts" "Z"
}

test_prompt_stderr() {
    log_header "2. Prompt functions output to stderr"

    # prompt_choice should only send the choice number to stdout
    local result
    result=$(echo "2" | prompt_choice "Pick one" "Option A" "Option B" 2>/dev/null)
    assert_eq "prompt_choice returns number" "2" "$result"
    assert_not_contains "prompt_choice no menu in stdout" "$result" "Option"

    # prompt_input should only send the value to stdout
    result=$(echo "myval" | prompt_input "Enter" "default" 2>/dev/null)
    assert_eq "prompt_input returns value" "myval" "$result"

    # prompt_input with default
    result=$(echo "" | prompt_input "Enter" "fallback" 2>/dev/null)
    assert_eq "prompt_input default" "fallback" "$result"

    # prompt_choice default (empty input)
    result=$(echo "" | prompt_choice "Pick" "A" "B" 2>/dev/null)
    assert_eq "prompt_choice default is 1" "1" "$result"
}

test_detect() {
    log_header "3. Project type detection"

    source "$KYZN_ROOT/lib/detect.sh"

    # Node detection
    create_sandbox node
    detect_project_type
    assert_eq "detect node" "node" "$KYZN_PROJECT_TYPE"
    detect_project_features
    [[ "$KYZN_HAS_TYPESCRIPT" == "true" ]] && pass "detect typescript" || fail "detect typescript" "not detected"
    [[ "$KYZN_HAS_TESTS" == "true" ]] && pass "detect tests dir" || fail "detect tests dir" "not detected"
    [[ "$KYZN_HAS_CI" == "true" ]] && pass "detect CI" || fail "detect CI" "not detected"
    cleanup_sandbox

    # Python detection
    create_sandbox python
    detect_project_type
    assert_eq "detect python" "python" "$KYZN_PROJECT_TYPE"
    cleanup_sandbox

    # Go detection
    create_sandbox go
    detect_project_type
    assert_eq "detect go" "go" "$KYZN_PROJECT_TYPE"
    cleanup_sandbox

    # Rust detection
    create_sandbox rust
    detect_project_type
    assert_eq "detect rust" "rust" "$KYZN_PROJECT_TYPE"
    cleanup_sandbox

    # Generic fallback
    create_sandbox generic
    detect_project_type
    assert_eq "detect generic" "generic" "$KYZN_PROJECT_TYPE"
    cleanup_sandbox
}

test_config() {
    log_header "4. Config read/write"

    create_sandbox generic

    # No config yet
    if ! has_config; then pass "no config initially"; else fail "no config" "config exists"; fi

    # Write config — ensure dir and seed file exist for yq -i
    ensure_kyzn_dirs
    echo '{}' > "$KYZN_CONFIG"
    config_set_str '.project.name' 'test-proj'
    config_set '.preferences.budget' '5.00'

    # Read it back
    local name
    name=$(config_get '.project.name' '')
    assert_eq "config read name" "test-proj" "$name"

    local budget
    budget=$(config_get '.preferences.budget' '')
    assert_eq "config read budget" "5.00" "$budget"

    # Default for missing key
    local missing
    missing=$(config_get '.nonexistent.key' 'default_val')
    assert_eq "config default" "default_val" "$missing"

    cleanup_sandbox
}

test_interview_config() {
    log_header "5. Interview generates clean config"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/interview.sh"

    create_sandbox node

    # Simulate interview with piped input (all defaults)
    echo -e "1\n1\n2.50\n1\n1" | run_interview 2>/dev/null

    assert_file_exists "config created" "$KYZN_CONFIG"

    # Verify values are clean (no menu text)
    local mode
    mode=$(config_get '.preferences.mode' '')
    assert_eq "config mode is clean" "deep" "$mode"

    # Trust now lives in local.yaml (not config.yaml) — verify it's there
    local trust
    trust=$(local_config_get '.trust' '')
    assert_eq "local trust is clean" "guardian" "$trust"

    local on_fail
    on_fail=$(config_get '.preferences.on_build_fail' '')
    assert_eq "config on_fail is clean" "report" "$on_fail"

    # Verify no prompt text leaked into config
    local raw
    raw=$(cat "$KYZN_CONFIG")
    assert_not_contains "no menu text in config" "$raw" "How aggressive"
    assert_not_contains "no choice prompt in config" "$raw" "Choice ["
    assert_not_contains "no option text in config" "$raw" "recommended"

    cleanup_sandbox
}

test_measure() {
    log_header "6. Measurement system"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/measure.sh"

    create_sandbox generic

    detect_project_type
    run_measurements "$KYZN_PROJECT_TYPE" 2>/dev/null

    # Health score should be computed
    [[ -n "${KYZN_HEALTH_SCORE:-}" ]] && pass "health score computed" || fail "health score" "not set"
    (( KYZN_HEALTH_SCORE >= 0 && KYZN_HEALTH_SCORE <= 100 )) && pass "health score in range" || fail "health score range" "$KYZN_HEALTH_SCORE"

    # Measurements file should exist
    [[ -f "${KYZN_MEASUREMENTS_FILE:-}" ]] && pass "measurements file created" || fail "measurements file" "not found"

    # File should be valid JSON
    if jq . "$KYZN_MEASUREMENTS_FILE" &>/dev/null; then
        pass "measurements valid JSON"
    else
        fail "measurements JSON" "invalid JSON"
    fi

    # Category scores should exist
    [[ -n "${KYZN_CATEGORY_SCORES:-}" ]] && pass "category scores set" || fail "category scores" "not set"

    cleanup_sandbox
}

test_allowlist() {
    log_header "7. Allowlist generation"

    source "$KYZN_ROOT/lib/allowlist.sh"

    # Node allowlist
    local node_list
    node_list=$(build_allowlist "node")
    assert_contains "node has npm" "$node_list" "npm"
    assert_contains "node has Read" "$node_list" "Read"

    # Python allowlist
    local py_list
    py_list=$(build_allowlist "python")
    assert_contains "python has pytest" "$py_list" "pytest"
    assert_contains "python has ruff" "$py_list" "ruff"

    # Generic allowlist
    local gen_list
    gen_list=$(build_allowlist "generic")
    assert_not_contains "generic no npm" "$gen_list" "npm"
    assert_contains "generic has Read" "$gen_list" "Read"
}

test_report_arithmetic() {
    log_header "8. Report arithmetic (regression test)"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/measure.sh"
    source "$KYZN_ROOT/lib/report.sh"

    # Create fake measurement files with float scores
    local tmpdir
    tmpdir=$(mktemp -d)

    cat > "$tmpdir/before.json" <<'JSON'
[
  {"category": "security", "score": 10, "max_score": 10},
  {"category": "performance", "score": 7, "max_score": 10},
  {"category": "quality", "score": 8, "max_score": 10}
]
JSON

    cat > "$tmpdir/after.json" <<'JSON'
[
  {"category": "security", "score": 10, "max_score": 10},
  {"category": "performance", "score": 9, "max_score": 10},
  {"category": "quality", "score": 8, "max_score": 10}
]
JSON

    # generate_category_comparison should not crash
    local result
    result=$(generate_category_comparison "$tmpdir/before.json" "$tmpdir/after.json" 2>&1) || true
    assert_not_contains "no syntax error" "$result" "syntax error"
    assert_contains "has security row" "$result" "security"

    rm -rf "$tmpdir"
}

test_branch_uniqueness() {
    log_header "9. Branch name uniqueness"

    # Simulate two run IDs with same date and focus
    local run1="20260318-120000-aabbccdd"
    local run2="20260318-120001-eeff0011"

    local suffix1="${run1##*-}"
    local suffix2="${run2##*-}"

    local branch1="kyzn/20260318-performance-${suffix1}"
    local branch2="kyzn/20260318-performance-${suffix2}"

    if [[ "$branch1" != "$branch2" ]]; then
        pass "branch names are unique"
    else
        fail "branch uniqueness" "both are $branch1"
    fi
}

test_claude_json_parsing() {
    log_header "10. Claude CLI JSON field parsing"

    # Simulate claude JSON output
    local fake_json='{
        "total_cost_usd": 1.234,
        "session_id": "sess-abc",
        "stop_reason": "end_turn",
        "result": "done"
    }'

    local cost session_id stop_reason
    cost=$(echo "$fake_json" | jq -r '.total_cost_usd // "unknown"')
    session_id=$(echo "$fake_json" | jq -r '.session_id // "none"')
    stop_reason=$(echo "$fake_json" | jq -r '.stop_reason // "unknown"')

    assert_eq "parse cost" "1.234" "$cost"
    assert_eq "parse session_id" "sess-abc" "$session_id"
    assert_eq "parse stop_reason" "end_turn" "$stop_reason"

    # Old wrong paths should fail gracefully
    local old_cost
    old_cost=$(echo "$fake_json" | jq -r '.metadata.cost // "unknown"')
    assert_eq "old path falls back" "unknown" "$old_cost"
}

test_symlink_resolution() {
    log_header "11. Symlink resolution"

    # Check that kyzn script uses portable _kyzn_resolve (not readlink -f)
    local kyzn_script="$KYZN_ROOT/kyzn"
    local content
    content=$(cat "$kyzn_script")
    assert_contains "uses _kyzn_resolve" "$content" '_kyzn_resolve'
}

test_doctor() {
    log_header "12. Doctor command"

    local output
    output=$("$KYZN_ROOT/kyzn" doctor 2>&1) || true

    assert_contains "doctor checks git" "$output" "git"
    assert_contains "doctor checks jq" "$output" "jq"
    assert_contains "doctor checks yq" "$output" "yq"
    assert_contains "doctor checks claude" "$output" "claude"
    assert_contains "doctor checks gh" "$output" "gh"
}

test_version() {
    log_header "13. Version command"

    local output
    output=$("$KYZN_ROOT/kyzn" version 2>&1)
    assert_contains "version output" "$output" "kyzn v"
}

test_help() {
    log_header "14. Help command"

    local output
    output=$("$KYZN_ROOT/kyzn" help 2>&1)
    assert_contains "help shows improve" "$output" "improve"
    assert_contains "help shows measure" "$output" "measure"
    assert_contains "help shows init" "$output" "init"
}

test_unknown_command() {
    log_header "15. Unknown command handling"

    local exit_code=0
    local output
    output=$("$KYZN_ROOT/kyzn" notarealcommand 2>&1) || exit_code=$?
    assert_eq "unknown cmd exits 1" "1" "$exit_code"
    assert_contains "unknown cmd message" "$output" "Unknown command"
}

# ---------------------------------------------------------------------------
# v0.2.0 feature tests (always run)
# ---------------------------------------------------------------------------

test_rust_workspace_detection() {
    log_header "16. Rust workspace detection"

    source "$KYZN_ROOT/lib/detect.sh"

    # Standard Cargo.toml at root
    create_sandbox rust
    detect_project_type
    assert_eq "detect root Cargo.toml" "rust" "$KYZN_PROJECT_TYPE"
    cleanup_sandbox

    # Workspace: Cargo.toml only in subdirectory (one level deep)
    SANDBOX=$(mktemp -d)
    cd "$SANDBOX"
    git init -q
    git commit --allow-empty -m "init" -q
    mkdir -p mylib
    echo '[package]' > mylib/Cargo.toml
    echo 'name = "mylib"' >> mylib/Cargo.toml
    git add -A && git commit -q -m "rust workspace"
    detect_project_type
    assert_eq "detect workspace Cargo.toml" "rust" "$KYZN_PROJECT_TYPE"
    cleanup_sandbox
}

test_configurable_model() {
    log_header "17. Configurable model in config"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/interview.sh"

    create_sandbox node

    # Run interview with defaults
    echo -e "1\n1\n2.50\n1\n1" | run_interview 2>/dev/null

    # Config should have model field
    local model
    model=$(config_get '.preferences.model' '')
    assert_eq "config has model" "sonnet" "$model"

    cleanup_sandbox
}

test_deep_mode_constraints() {
    log_header "18. Deep mode prompt strength"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/prompt.sh"

    create_sandbox generic
    detect_project_type

    # Create a fake measurements file
    local tmpfile
    tmpfile=$(mktemp)
    echo '[]' > "$tmpfile"
    KYZN_HEALTH_SCORE=50

    local prompt
    prompt=$(assemble_prompt "$tmpfile" "deep" "auto" "generic")

    assert_contains "deep has CRITICAL" "$prompt" "CRITICAL CONSTRAINTS"
    assert_contains "deep forbids UI text" "$prompt" "Do NOT change UI text"
    assert_contains "deep requires named bug" "$prompt" "can't name the bug"

    rm -f "$tmpfile"
    cleanup_sandbox
}

test_score_regression_gate() {
    log_header "19. Score regression gate logic"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/measure.sh"

    # Create two measurement files: baseline better than after
    local tmpdir
    tmpdir=$(mktemp -d)

    cat > "$tmpdir/baseline.json" <<'JSON'
[
  {"category": "security", "score": 9, "max_score": 10},
  {"category": "quality", "score": 8, "max_score": 10}
]
JSON

    cat > "$tmpdir/after.json" <<'JSON'
[
  {"category": "security", "score": 7, "max_score": 10},
  {"category": "quality", "score": 6, "max_score": 10}
]
JSON

    # Compute scores
    compute_health_score "$tmpdir/baseline.json"
    local baseline_score="$KYZN_HEALTH_SCORE"

    compute_health_score "$tmpdir/after.json"
    local after_score="$KYZN_HEALTH_SCORE"

    if (( after_score < baseline_score )); then
        pass "score regression detected ($baseline_score → $after_score)"
    else
        fail "score regression" "expected after < baseline, got $after_score >= $baseline_score"
    fi

    rm -rf "$tmpdir"
}

test_branch_cleanup_in_failure() {
    log_header "20. handle_build_failure cleans up branch"

    source "$KYZN_ROOT/lib/execute.sh"

    create_sandbox generic

    # Create a branch and stay on it (simulating kyzn mid-run)
    git checkout -b kyzn/test-cleanup-branch 2>/dev/null

    # Verify branch exists and we're on it
    git branch | grep -q "kyzn/test-cleanup-branch" && pass "test branch created" || fail "test branch" "not created"

    # Simulate failure handler (discard strategy) — checkout - goes back to master, then deletes branch
    local KYZN_CLAUDE_COST="0.00"
    handle_build_failure "discard" "test-run" "kyzn/test-cleanup-branch" "deep" "test"

    # Branch should be deleted
    if ! git branch | grep -q "kyzn/test-cleanup-branch"; then
        pass "orphan branch cleaned up"
    else
        fail "branch cleanup" "branch still exists"
    fi

    cleanup_sandbox
}

# ---------------------------------------------------------------------------
# v0.3 coverage gap tests (always run)
# ---------------------------------------------------------------------------

test_verify_build_generic() {
    log_header "21. verify_build succeeds for generic project"

    source "$KYZN_ROOT/lib/verify.sh"

    create_sandbox generic
    detect_project_type

    if verify_build 2>/dev/null; then
        pass "generic verify_build returns 0"
    else
        fail "generic verify_build" "returned non-zero for generic project"
    fi

    cleanup_sandbox
}

test_verify_build_dispatch() {
    log_header "22. verify_build dispatches by project type"

    source "$KYZN_ROOT/lib/verify.sh"

    # Node project with passing test script
    create_sandbox node
    detect_project_type
    assert_eq "node type detected" "node" "$KYZN_PROJECT_TYPE"

    # Inject a failing test to confirm dispatch (test script exits 1)
    jq '.scripts.test = "exit 1"' package.json > package.json.tmp && mv package.json.tmp package.json
    git add -A && git commit -q -m "break tests"

    if ! verify_build 2>/dev/null; then
        pass "node verify_build dispatches and detects failure"
    else
        fail "node verify_build dispatch" "should fail when test script exits 1"
    fi

    cleanup_sandbox
}

test_build_failure_report_strategy() {
    log_header "23. handle_build_failure report strategy writes file and cleans branch"

    source "$KYZN_ROOT/lib/execute.sh"

    create_sandbox generic
    ensure_kyzn_dirs

    # Create branch (simulate kyzn mid-run)
    git checkout -b kyzn/test-report-branch 2>/dev/null

    local KYZN_CLAUDE_COST="1.23"
    handle_build_failure "report" "test-run-report" "kyzn/test-report-branch" "deep" "security"

    assert_file_exists "failure report created" "$KYZN_REPORTS_DIR/test-run-report-failed.md"

    local content
    content=$(cat "$KYZN_REPORTS_DIR/test-run-report-failed.md")
    assert_contains "report has cost" "$content" "1.23"
    assert_contains "report has mode" "$content" "deep"
    assert_contains "report has run_id" "$content" "test-run-report"

    if ! git branch | grep -q "kyzn/test-report-branch"; then
        pass "report strategy cleans orphan branch"
    else
        fail "report branch cleanup" "branch still exists"
    fi

    cleanup_sandbox
}

test_health_score_edge_cases() {
    log_header "24. compute_health_score edge cases"

    source "$KYZN_ROOT/lib/measure.sh"

    # Empty measurements → score 0
    local tmpfile
    tmpfile=$(mktemp)
    echo '[]' > "$tmpfile"
    compute_health_score "$tmpfile"
    assert_eq "empty measurements → score 0" "0" "$KYZN_HEALTH_SCORE"

    # Single category at 100% → weighted score equals that category's weight percentage
    echo '[{"category":"security","score":10,"max_score":10}]' > "$tmpfile"
    compute_health_score "$tmpfile"
    assert_eq "security-only perfect score" "100" "$KYZN_HEALTH_SCORE"

    # Single category at 0%
    echo '[{"category":"security","score":0,"max_score":10}]' > "$tmpfile"
    compute_health_score "$tmpfile"
    assert_eq "security-only zero score" "0" "$KYZN_HEALTH_SCORE"

    rm -f "$tmpfile"
}

test_prompt_yn() {
    log_header "25. prompt_yn handles y/n/defaults"

    # "y" should return true
    if echo "y" | prompt_yn "Continue?" "n" 2>/dev/null; then
        pass "prompt_yn accepts y"
    else
        fail "prompt_yn y" "should return true for y"
    fi

    # "n" should return false
    if echo "n" | prompt_yn "Continue?" "y" 2>/dev/null; then
        fail "prompt_yn n" "should return false for n"
    else
        pass "prompt_yn rejects n"
    fi

    # Empty input uses default "y"
    if echo "" | prompt_yn "Continue?" "y" 2>/dev/null; then
        pass "prompt_yn default y"
    else
        fail "prompt_yn default y" "empty input should use default y"
    fi

    # Empty input uses default "n"
    if echo "" | prompt_yn "Continue?" "n" 2>/dev/null; then
        fail "prompt_yn default n" "empty input should use default n"
    else
        pass "prompt_yn default n"
    fi
}

test_clean_full_mode_constraints() {
    log_header "26. assemble_prompt clean and full mode constraints"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/prompt.sh"

    create_sandbox generic
    detect_project_type
    KYZN_HEALTH_SCORE=50

    local tmpfile
    tmpfile=$(mktemp)
    echo '[]' > "$tmpfile"

    local clean_prompt
    clean_prompt=$(assemble_prompt "$tmpfile" "clean" "auto" "generic")
    assert_contains "clean has CLEANUP header" "$clean_prompt" "FOCUS ON CLEANUP"
    assert_contains "clean forbids behavior change" "$clean_prompt" "Do NOT change behavior"

    local full_prompt
    full_prompt=$(assemble_prompt "$tmpfile" "full" "auto" "generic")
    assert_contains "full has FULL IMPROVEMENT header" "$full_prompt" "FULL IMPROVEMENT MODE"

    rm -f "$tmpfile"
    cleanup_sandbox
}

test_approve_reject() {
    log_header "27. cmd_approve and cmd_reject create correct history entries"

    source "$KYZN_ROOT/lib/approve.sh"

    create_sandbox generic
    ensure_kyzn_dirs

    # Approve with report present
    echo "# Fake report" > "$KYZN_REPORTS_DIR/test-approve-001.md"
    cmd_approve "test-approve-001" 2>/dev/null

    assert_file_exists "approve history file created" "$KYZN_HISTORY_DIR/test-approve-001.json"
    local status
    status=$(jq -r '.status' "$KYZN_HISTORY_DIR/test-approve-001.json")
    assert_eq "approve sets status approved" "approved" "$status"

    # Reject with reason
    echo "# Fake report" > "$KYZN_REPORTS_DIR/test-reject-001.md"
    cmd_reject "test-reject-001" --reason "too aggressive" 2>/dev/null

    assert_file_exists "reject history file created" "$KYZN_HISTORY_DIR/test-reject-001.json"
    local rstatus
    rstatus=$(jq -r '.status' "$KYZN_HISTORY_DIR/test-reject-001.json")
    assert_eq "reject sets status rejected" "rejected" "$rstatus"

    local reason
    reason=$(jq -r '.rejection_reason' "$KYZN_HISTORY_DIR/test-reject-001.json")
    assert_eq "reject stores reason" "too aggressive" "$reason"

    cleanup_sandbox
}

test_approve_missing_report() {
    log_header "28. cmd_approve fails gracefully without report"

    source "$KYZN_ROOT/lib/approve.sh"

    create_sandbox generic
    ensure_kyzn_dirs

    local exit_code=0
    cmd_approve "nonexistent-run" 2>/dev/null || exit_code=$?
    assert_eq "approve fails without report" "1" "$exit_code"

    cleanup_sandbox
}

test_allowlist_rust_go() {
    log_header "29. Allowlist generation for rust and go"

    source "$KYZN_ROOT/lib/allowlist.sh"

    local rust_list
    rust_list=$(build_allowlist "rust")
    assert_contains "rust has cargo" "$rust_list" "cargo"
    assert_contains "rust has Read" "$rust_list" "Read"

    local go_list
    go_list=$(build_allowlist "go")
    assert_contains "go has go" "$go_list" "go"
    assert_contains "go has Read" "$go_list" "Read"
}

test_get_system_prompt() {
    log_header "30. get_system_prompt returns file path"

    source "$KYZN_ROOT/lib/prompt.sh"

    # Without profile — should return templates/system-prompt.md
    local sys
    sys=$(get_system_prompt "")
    assert_eq "no profile returns system-prompt.md" "$KYZN_ROOT/templates/system-prompt.md" "$sys"

    # With valid profile — should return a temp file (combined)
    local combined
    combined=$(get_system_prompt "testing")
    if [[ "$combined" != "$KYZN_ROOT/templates/system-prompt.md" && -f "$combined" ]]; then
        pass "testing profile returns combined temp file"
        local content
        content=$(cat "$combined")
        assert_contains "combined includes system prompt content" "$content" "kyzn"
        rm -f "$combined"
    else
        fail "get_system_prompt with profile" "did not return a valid combined file"
    fi

    # With nonexistent profile — should fall back to system-prompt.md
    local fallback
    fallback=$(get_system_prompt "nonexistent")
    assert_eq "nonexistent profile falls back" "$KYZN_ROOT/templates/system-prompt.md" "$fallback"
}

# ---------------------------------------------------------------------------
# v0.3.0 security hardening tests
# ---------------------------------------------------------------------------

test_disallowed_file_globs() {
    log_header "31. --disallowedFileGlobs in execute_claude"

    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/allowlist.sh"

    # Read the function source and verify it contains disallowedFileGlobs
    local src
    src=$(cat "$KYZN_ROOT/lib/execute.sh")
    assert_contains "execute.sh has disallowedFileGlobs in settings" "$src" "disallowedFileGlobs"
    assert_contains "blocks ~/.ssh" "$src" "~/.ssh/**"
    assert_contains "blocks ~/.aws" "$src" "~/.aws/**"
    assert_contains "blocks .env files" "$src" "**/.env"
    assert_contains "blocks .pem files" "$src" "**/*.pem"
    assert_contains "uses --settings flag" "$src" '--settings "$settings_json"'
}

test_ci_blocking() {
    log_header "32. CI file blocking (check_dangerous_files)"

    source "$KYZN_ROOT/lib/execute.sh"

    create_sandbox generic

    # Stage a CI workflow file
    mkdir -p .github/workflows
    echo 'name: evil' > .github/workflows/evil.yml
    git add .github/workflows/evil.yml

    # Without --allow-ci, should unstage
    KYZN_ALLOW_CI=false check_dangerous_files 2>/dev/null

    local staged
    staged=$(git diff --cached --name-only 2>/dev/null | grep -c 'evil.yml' || true)
    assert_eq "CI file unstaged by default" "0" "$staged"

    # With --allow-ci, should keep staged
    git add .github/workflows/evil.yml
    KYZN_ALLOW_CI=true check_dangerous_files 2>/dev/null

    staged=$(git diff --cached --name-only 2>/dev/null | grep -c 'evil.yml' || true)
    assert_eq "CI file kept with --allow-ci" "1" "$staged"

    cleanup_sandbox
}

test_timeout_flag() {
    log_header "33. Timeout wrapping in execute_claude"

    local src
    src=$(cat "$KYZN_ROOT/lib/execute.sh")
    assert_contains "has timeout wrapper" "$src" 'timeout "$claude_timeout"'
    assert_contains "has KYZN_CLAUDE_TIMEOUT env" "$src" "KYZN_CLAUDE_TIMEOUT"
    assert_contains "default 600s" "$src" ':-600'
}

test_tightened_allowlist() {
    log_header "34. Tightened allowlist wildcards"

    source "$KYZN_ROOT/lib/allowlist.sh"

    # Python: should NOT have broad 'python *', should have specific subcommands
    local py_list
    py_list=$(build_allowlist "python")
    assert_not_contains "python no broad wildcard" "$py_list" '"Bash(python *)"'
    assert_contains "python has pytest" "$py_list" "pytest"
    assert_contains "python has python -m pytest" "$py_list" "python -m pytest"

    # Node: should NOT have broad 'npm *', should have specific subcommands
    local node_list
    node_list=$(build_allowlist "node")
    assert_not_contains "node no broad npm wildcard" "$node_list" '"Bash(npm *)"'
    assert_contains "node has npm test" "$node_list" "npm test"
    assert_contains "node has npm run" "$node_list" "npm run"
    assert_not_contains "node no bare node" "$node_list" '"Bash(node *)"'

    # Rust: should NOT have broad 'cargo *'
    local rust_list
    rust_list=$(build_allowlist "rust")
    assert_not_contains "rust no broad cargo wildcard" "$rust_list" '"Bash(cargo *)"'
    assert_contains "rust has cargo test" "$rust_list" "cargo test"
    assert_contains "rust has cargo check" "$rust_list" "cargo check"

    # Go: should NOT have broad 'go *'
    local go_list
    go_list=$(build_allowlist "go")
    assert_not_contains "go no broad go wildcard" "$go_list" '"Bash(go *)"'
    assert_contains "go has go test" "$go_list" "go test"
    assert_contains "go has go build" "$go_list" "go build"

    # Generic: should NOT have 'cat *'
    local gen_list
    gen_list=$(build_allowlist "generic")
    assert_not_contains "generic no cat" "$gen_list" "cat"
}

test_trust_in_local_yaml() {
    log_header "35. Trust stored in local.yaml, not config.yaml"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/interview.sh"

    create_sandbox node

    # Run interview with all defaults
    echo -e "1\n1\n2.50\n1\n1" | run_interview 2>/dev/null

    # Config should NOT have trust
    local config_trust
    config_trust=$(config_get '.preferences.trust' 'MISSING')
    assert_eq "config.yaml has no trust" "MISSING" "$config_trust"

    # Local config should have trust
    assert_file_exists "local.yaml created" "$KYZN_LOCAL_CONFIG"
    local local_trust
    local_trust=$(local_config_get '.trust' '')
    assert_eq "local.yaml has trust=guardian" "guardian" "$local_trust"

    # .gitignore should include local.yaml
    local gi
    gi=$(cat "$KYZN_DIR/.gitignore")
    assert_contains "gitignore has local.yaml" "$gi" "local.yaml"

    cleanup_sandbox
}

test_per_category_floor() {
    log_header "36. Per-category score floor logic"

    source "$KYZN_ROOT/lib/measure.sh"

    # Create measurement files where one category drops > 5 points
    local tmpdir
    tmpdir=$(mktemp -d)

    cat > "$tmpdir/baseline.json" <<'JSON'
[
  {"category": "security", "score": 9, "max_score": 10},
  {"category": "quality", "score": 8, "max_score": 10}
]
JSON

    cat > "$tmpdir/after.json" <<'JSON'
[
  {"category": "security", "score": 2, "max_score": 10},
  {"category": "quality", "score": 10, "max_score": 10}
]
JSON

    # Even though aggregate might be similar, security dropped 70 points
    local before_sec after_sec
    before_sec=$(jq -r '[.[] | select(.category == "security") | .score] | if length > 0 then (add * 100 / ([.[]] | length * 10)) else empty end' "$tmpdir/baseline.json")
    after_sec=$(jq -r '[.[] | select(.category == "security") | .score] | if length > 0 then (add * 100 / ([.[]] | length * 10)) else empty end' "$tmpdir/after.json")

    local b_int="${before_sec%.*}" a_int="${after_sec%.*}"
    local drop=$(( b_int - a_int ))

    if (( drop > 5 )); then
        pass "per-category floor detects security drop ($b_int → $a_int, drop=$drop)"
    else
        fail "per-category floor" "should detect drop, got $drop"
    fi

    rm -rf "$tmpdir"
}

test_analyze_prompt_assembly() {
    log_header "38. Specialist prompt assembly"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/prompt.sh"
    source "$KYZN_ROOT/lib/analyze.sh"

    create_sandbox generic
    detect_project_type
    KYZN_HEALTH_SCORE=50

    # Test each specialist prompt
    local sec_prompt
    sec_prompt=$(build_specialist_prompt "security" "test-proj" "Generic" "50" "[]")
    assert_contains "security prompt has injection" "$sec_prompt" "Injection"
    assert_contains "security prompt has SEC prefix" "$sec_prompt" "SEC-001"

    local cor_prompt
    cor_prompt=$(build_specialist_prompt "correctness" "test-proj" "Generic" "50" "[]")
    assert_contains "correctness prompt has logic errors" "$cor_prompt" "Logic errors"
    assert_contains "correctness prompt has BUG prefix" "$cor_prompt" "BUG-001"

    local perf_prompt
    perf_prompt=$(build_specialist_prompt "performance" "test-proj" "Generic" "50" "[]")
    assert_contains "performance prompt has N+1" "$perf_prompt" "N+1"
    assert_contains "performance prompt has PERF prefix" "$perf_prompt" "PERF-001"

    local arch_prompt
    arch_prompt=$(build_specialist_prompt "architecture" "test-proj" "Generic" "50" "[]")
    assert_contains "architecture prompt has circular deps" "$arch_prompt" "Circular dependencies"
    assert_contains "architecture prompt has ARCH prefix" "$arch_prompt" "ARCH-001"

    cleanup_sandbox
}

test_consensus_prompt() {
    log_header "39a. Consensus prompt merges specialist findings"

    source "$KYZN_ROOT/lib/analyze.sh"

    local prompt
    prompt=$(build_consensus_prompt '[{"id":"SEC-001"}]' '[{"id":"BUG-001"}]' '[{"id":"PERF-001"}]' '[{"id":"ARCH-001"}]')

    assert_contains "consensus has security section" "$prompt" "Security Reviewer"
    assert_contains "consensus has correctness section" "$prompt" "Correctness Reviewer"
    assert_contains "consensus has performance section" "$prompt" "Performance Reviewer"
    assert_contains "consensus has architecture section" "$prompt" "Architecture Reviewer"
    assert_contains "consensus has dedup instruction" "$prompt" "Deduplicate"
}

test_analysis_system_prompt() {
    log_header "39b. Analysis system prompt exists and has personality"

    local analysis_prompt="$KYZN_ROOT/templates/analysis-prompt.md"
    assert_file_exists "analysis-prompt.md exists" "$analysis_prompt"

    local content
    content=$(cat "$analysis_prompt")
    assert_contains "has personality" "$content" "senior staff engineer"
    assert_contains "has methodology" "$content" "entry points"
    assert_contains "has output quality" "$content" "self-contained"
}

test_extract_findings() {
    log_header "40. extract_findings parses JSON from Claude response"

    source "$KYZN_ROOT/lib/analyze.sh"

    # Simulate Claude response with embedded JSON
    local fake_result
    fake_result=$(jq -n '{result: "Here are my findings:\n```json\n[{\"id\":\"BUG-001\",\"severity\":\"HIGH\",\"title\":\"test\"}]\n```"}')

    local findings
    findings=$(extract_findings "$fake_result")

    if echo "$findings" | jq -e 'type == "array"' &>/dev/null; then
        pass "extract_findings returns array"
    else
        fail "extract_findings" "did not return JSON array"
    fi
}

test_generate_fix_prompt() {
    log_header "41. Fix prompt generation from findings"

    source "$KYZN_ROOT/lib/analyze.sh"

    local tmpfile
    tmpfile=$(mktemp)
    cat > "$tmpfile" <<'JSON'
[
  {"id":"BUG-001","severity":"CRITICAL","category":"bug","title":"Null deref","file":"src/main.ts","line":10,"fix":"Add null check"},
  {"id":"SEC-001","severity":"HIGH","category":"security","title":"SQL injection","file":"src/db.ts","line":20,"fix":"Use parameterized query"},
  {"id":"STYLE-001","severity":"LOW","category":"quality","title":"Naming","file":"src/utils.ts","line":5,"fix":"Rename"}
]
JSON

    local prompt
    prompt=$(generate_fix_prompt "$tmpfile" 10 "HIGH")

    assert_contains "fix prompt has BUG-001" "$prompt" "BUG-001"
    assert_contains "fix prompt has SEC-001" "$prompt" "SEC-001"
    # LOW severity should be filtered out when min is HIGH
    assert_not_contains "fix prompt excludes LOW" "$prompt" "STYLE-001"

    rm -f "$tmpfile"
}

test_analyze_wired_in_kyzn() {
    log_header "42. analyze command is wired into kyzn"

    local help_output
    help_output=$("$KYZN_ROOT/kyzn" help 2>&1)
    assert_contains "help shows analyze" "$help_output" "analyze"
}

test_reject_no_learn_message() {
    log_header "43. Reject says 'recorded' not 'will learn'"

    local src
    src=$(cat "$KYZN_ROOT/lib/approve.sh")
    assert_contains "has 'Rejection recorded'" "$src" "Rejection recorded"
    assert_not_contains "no 'will learn' message" "$src" "will learn"
}

# ---------------------------------------------------------------------------
# Stress tests (--full or --stress only)
# ---------------------------------------------------------------------------

test_stress_rapid_ids() {
    log_header "S1. Stress: rapid run ID generation (100 IDs)"

    local tmpfile
    tmpfile=$(mktemp)
    local collisions=0
    for _ in $(seq 1 100); do
        generate_run_id >> "$tmpfile"
    done

    local total unique
    total=$(wc -l < "$tmpfile")
    unique=$(sort -u "$tmpfile" | wc -l)
    collisions=$(( total - unique ))
    rm -f "$tmpfile"

    if (( collisions == 0 )); then
        pass "100 unique run IDs"
    else
        fail "run ID collisions" "$collisions collisions in 100"
    fi
}

test_stress_measure_repeated() {
    log_header "S2. Stress: repeated measurements (10x)"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/measure.sh"

    create_sandbox generic
    detect_project_type

    local scores=()
    for i in $(seq 1 10); do
        run_measurements "$KYZN_PROJECT_TYPE" 2>/dev/null
        scores+=("$KYZN_HEALTH_SCORE")
    done

    # All scores should be the same (deterministic)
    local first="${scores[0]}"
    local all_same=true
    for s in "${scores[@]}"; do
        if [[ "$s" != "$first" ]]; then
            all_same=false
            break
        fi
    done

    if $all_same; then
        pass "10 measurements are deterministic (all $first)"
    else
        fail "measurement determinism" "scores varied: ${scores[*]}"
    fi

    cleanup_sandbox
}

test_stress_all_project_types() {
    log_header "S3. Stress: measure all project types"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/measure.sh"

    for ptype in node python go rust generic; do
        create_sandbox "$ptype"
        detect_project_type

        local detected="$KYZN_PROJECT_TYPE"
        run_measurements "$detected" 2>/dev/null

        if (( KYZN_HEALTH_SCORE >= 0 )); then
            pass "measure $ptype (score: $KYZN_HEALTH_SCORE)"
        else
            fail "measure $ptype" "invalid score: $KYZN_HEALTH_SCORE"
        fi
        cleanup_sandbox
    done
}

test_stress_config_overwrite() {
    log_header "S4. Stress: config overwrite cycle"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/interview.sh"

    create_sandbox generic

    # Run interview 5 times, each with different choices
    for mode_choice in 1 2 3 1 2; do
        echo -e "1\n${mode_choice}\n3.00\n1\n1" | run_interview 2>/dev/null
    done

    # Final config should be valid YAML
    if yq eval '.' "$KYZN_CONFIG" &>/dev/null; then
        pass "config valid after 5 overwrites"
    else
        fail "config validity" "invalid YAML after repeated writes"
    fi

    # Should have mode=clean (choice 2 was last)
    local mode
    mode=$(config_get '.preferences.mode' '')
    assert_eq "last mode wins" "clean" "$mode"

    cleanup_sandbox
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
main() {
    local mode="${1:---quick}"
    local start_time
    start_time=$(date +%s)

    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  kyzn selftest${RESET}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    # Core tests (always run)
    test_core
    test_prompt_stderr
    test_detect
    test_config
    test_interview_config
    test_measure
    test_allowlist
    test_report_arithmetic
    test_branch_uniqueness
    test_claude_json_parsing
    test_symlink_resolution
    test_doctor
    test_version
    test_help
    test_unknown_command
    test_rust_workspace_detection
    test_configurable_model
    test_deep_mode_constraints
    test_score_regression_gate
    test_branch_cleanup_in_failure
    test_verify_build_generic
    test_verify_build_dispatch
    test_build_failure_report_strategy
    test_health_score_edge_cases
    test_prompt_yn
    test_clean_full_mode_constraints
    test_approve_reject
    test_approve_missing_report
    test_allowlist_rust_go
    test_get_system_prompt
    test_disallowed_file_globs
    test_ci_blocking
    test_timeout_flag
    test_tightened_allowlist
    test_trust_in_local_yaml
    test_per_category_floor
    test_analyze_prompt_assembly
    test_consensus_prompt
    test_analysis_system_prompt
    test_extract_findings
    test_generate_fix_prompt
    test_analyze_wired_in_kyzn
    test_reject_no_learn_message

    # Stress tests
    if [[ "$mode" == "--full" || "$mode" == "--stress" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}━━━ Stress tests ━━━${RESET}"
        test_stress_rapid_ids
        test_stress_measure_repeated
        test_stress_all_project_types
        test_stress_config_overwrite
    else
        echo ""
        echo -e "${DIM}  (run with --full or --stress for stress tests)${RESET}"
    fi

    # Summary
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${GREEN}✓ $TESTS_PASSED passed${RESET}  ${RED}✗ $TESTS_FAILED failed${RESET}  ${DIM}⊘ $TESTS_SKIPPED skipped${RESET}  ⏱ ${duration}s"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    if (( TESTS_FAILED > 0 )); then
        echo ""
        echo -e "${RED}${BOLD}Failures:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        return 1
    fi

    echo ""
    return 0
}

main "$@"
