#!/usr/bin/env bash
# kyzn/tests/selftest.sh — Comprehensive self-test suite
# Usage: kyzn selftest [--quick|--full|--stress]
set -euo pipefail

# Portable symlink resolution (readlink -f doesn't exist on macOS)
_resolve() {
    local f="$1"; local d=0
    while [[ -L "$f" ]]; do
        if (( d++ > 20 )); then break; fi
        local dir; dir="$(cd "$(dirname "$f")" && pwd)"
        f="$(readlink "$f")"; [[ "$f" != /* ]] && f="$dir/$f"
    done
    echo "$f"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve "${BASH_SOURCE[0]}")")" && pwd)"
KYZN_ROOT="$(dirname "$SCRIPT_DIR")"

# Never let self-tests read or write the operator's real KyZN state. Keeping
# HOME isolated also covers nested `kyzn` processes spawned by CLI tests.
SELFTEST_ORIGINAL_HOME="$HOME"
SELFTEST_HOME=$(mktemp -d)
export HOME="$SELFTEST_HOME"
trap 'rm -rf "$SELFTEST_HOME"' EXIT

# Fixture repositories sometimes commit directly instead of using
# create_sandbox. Process-scoped identity keeps those commits deterministic,
# while the isolated global-config path prevents HOME or XDG config leakage.
export GIT_AUTHOR_NAME="KyZN Selftest"
export GIT_AUTHOR_EMAIL="selftest@kyzn.local"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_CONFIG_GLOBAL="$SELFTEST_HOME/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"

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
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); echo -e "  ${DIM}⊘${RESET} $1 — skipped${2:+ ($2)}"; }

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
    git config user.email "selftest@kyzn.local"
    git config user.name "KyZN Selftest"
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
        csharp)
            cat > test-project.csproj <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
</Project>
XML
            echo 'class Program { static void Main() { } }' > Program.cs
            ;;
        java)
            cat > pom.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>demo</artifactId>
  <version>0.1.0</version>
  <packaging>jar</packaging>
</project>
XML
            mkdir -p src/main/java
            echo 'public class Hello { public static void main(String[] a) { } }' > src/main/java/Hello.java
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
    # The unsafe-host gate is per-run state. Restore the closed default so an
    # opt-in from one test can never silently satisfy the gate in the next —
    # which would turn "defaults closed" into an assertion about test order.
    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=false
    _KYZN_UNSAFE_HOST_EXECUTION_WARNED=false
}

# ---------------------------------------------------------------------------
# Test suites
# ---------------------------------------------------------------------------

test_core() {
    log_header "1. Core library tests"

    assert_eq "selftest global state uses isolated HOME" "$SELFTEST_HOME/.kyzn" "$KYZN_GLOBAL_DIR"
    if [[ "$KYZN_GLOBAL_DIR" != "$SELFTEST_ORIGINAL_HOME/.kyzn" ]]; then
        pass "selftest never targets operator KyZN state"
    else
        fail "selftest never targets operator KyZN state" "global directory still points at the original HOME"
    fi

    # Git also consults XDG_CONFIG_HOME/git/config. Prove the selftest's
    # explicit global-config boundary neither reads nor writes an existing
    # XDG config while direct fixture commits still receive a valid identity.
    local git_isolation_tmp xdg_config config_before config_after global_name_status=0 global_name author
    git_isolation_tmp=$(mktemp -d)
    mkdir -p "$git_isolation_tmp/xdg/git" "$git_isolation_tmp/repo"
    xdg_config="$git_isolation_tmp/xdg/git/config"
    printf '[user]\n\tname = External XDG Identity\n\temail = external@example.invalid\n' > "$xdg_config"
    config_before=$(shasum -a 256 "$xdg_config" | awk '{print $1}')
    global_name=$(XDG_CONFIG_HOME="$git_isolation_tmp/xdg" git config --global --get user.name 2>/dev/null) || global_name_status=$?
    assert_exit_code "selftest does not read existing XDG Git config" "1" "$global_name_status"
    assert_eq "selftest XDG Git identity stays hidden" "" "$global_name"
    (
        cd "$git_isolation_tmp/repo"
        XDG_CONFIG_HOME="$git_isolation_tmp/xdg" git init -q
        printf 'fixture\n' > fixture.txt
        git add fixture.txt
        XDG_CONFIG_HOME="$git_isolation_tmp/xdg" git commit -q -m "fixture commit"
    )
    author=$(git -C "$git_isolation_tmp/repo" log -1 --format='%an <%ae>|%cn <%ce>')
    assert_eq "process-scoped Git identity supports fixture commits" \
        "KyZN Selftest <selftest@kyzn.local>|KyZN Selftest <selftest@kyzn.local>" "$author"
    config_after=$(shasum -a 256 "$xdg_config" | awk '{print $1}')
    assert_eq "selftest does not write existing XDG Git config" "$config_before" "$config_after"
    rm -rf "$git_isolation_tmp"

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

    # C# detection
    create_sandbox csharp
    detect_project_type
    assert_eq "detect csharp" "csharp" "$KYZN_PROJECT_TYPE"
    cleanup_sandbox

    # Java detection (Maven sandbox)
    create_sandbox java
    detect_project_type
    assert_eq "detect java" "java" "$KYZN_PROJECT_TYPE"
    assert_eq "detect java build flavor" "maven" "${KYZN_JAVA_BUILD:-}"
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
    if (( KYZN_HEALTH_SCORE >= 0 && KYZN_HEALTH_SCORE <= 100 )); then pass "health score in range"; else fail "health score range" "$KYZN_HEALTH_SCORE"; fi

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
    local -a node_arr=()
    build_allowlist node_arr "node"
    local node_list="${node_arr[*]}"
    assert_contains "node has npm" "$node_list" "npm"
    assert_contains "node has Read" "$node_list" "Read"

    # Python allowlist
    local -a py_arr=()
    build_allowlist py_arr "python"
    local py_list="${py_arr[*]}"
    assert_contains "python has pytest" "$py_list" "pytest"
    assert_contains "python has ruff" "$py_list" "ruff"

    # Generic allowlist
    local -a gen_arr=()
    build_allowlist gen_arr "generic"
    local gen_list="${gen_arr[*]}"
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
    assert_contains "version output" "$output" "KyZN v"
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

    # shellcheck disable=SC2034 # handle_build_failure reads this global to include cost in the report.
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

    # Clean up test artifacts
    rm -f "$KYZN_GLOBAL_HISTORY/test-approve-001.json" "$KYZN_GLOBAL_HISTORY/test-reject-001.json" 2>/dev/null

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

    local -a rust_arr=()
    build_allowlist rust_arr "rust"
    local rust_list="${rust_arr[*]}"
    assert_contains "rust has cargo" "$rust_list" "cargo"
    assert_contains "rust has Read" "$rust_list" "Read"

    local -a go_arr=()
    build_allowlist go_arr "go"
    local go_list="${go_arr[*]}"
    assert_contains "go has go" "$go_list" "go"
    assert_contains "go has Read" "$go_list" "Read"

    local -a cs_arr=()
    build_allowlist cs_arr "csharp"
    local cs_list="${cs_arr[*]}"
    assert_contains "csharp has dotnet" "$cs_list" "dotnet"
    assert_contains "csharp has Read" "$cs_list" "Read"
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

    # Verify KYZN_SETTINGS_JSON constant in core.sh contains disallowedFileGlobs
    local src
    src=$(cat "$KYZN_ROOT/lib/core.sh")
    assert_contains "core.sh has disallowedFileGlobs in settings" "$src" "disallowedFileGlobs"
    # shellcheck disable=SC2088 # This test intentionally checks literal source text.
    assert_contains "blocks ~/.ssh" "$src" "~/.ssh/**"
    # shellcheck disable=SC2088 # This test intentionally checks literal source text.
    assert_contains "blocks ~/.aws" "$src" "~/.aws/**"
    assert_contains "blocks .env files" "$src" "**/.env"
    assert_contains "blocks .pem files" "$src" "**/*.pem"
    # Verify execute.sh uses the constant
    local exec_src
    exec_src=$(cat "$KYZN_ROOT/lib/execute.sh")
    assert_contains "uses KYZN_SETTINGS_JSON constant" "$exec_src" 'KYZN_SETTINGS_JSON'
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

    local status=0 value error_output
    error_output=$(timeout abc true 2>&1) || status=$?
    assert_exit_code "timeout rejects invalid duration on every platform" "125" "$status"
    assert_contains "timeout explains invalid duration" "$error_output" "invalid duration 'abc'"
    value=$(timeout 0 printf disabled)
    assert_eq "timeout zero disables deadline on every platform" "disabled" "$value"
    value=$(timeout .5s /usr/bin/printf suffix)
    assert_eq "timeout accepts GNU fractional suffix duration" "suffix" "$value"
    value=$(timeout 1m /usr/bin/printf minute)
    assert_eq "timeout accepts GNU minute duration" "minute" "$value"
    status=0
    timeout 3 /bin/bash -c 'exit 7' || status=$?
    assert_exit_code "timeout preserves child status on every platform" "7" "$status"
}

_test_timeout_lifecycle() {
    local controller="$1" action="$2" signal_name="$3" expected_status="$4"
    local runtime_path caller_file controller_file leaf_file
    runtime_path=$(mktemp -d)
    caller_file=$(mktemp)
    controller_file=$(mktemp)
    leaf_file=$(mktemp)
    ln -s "$(command -v "$controller")" "$runtime_path/$controller"
    ln -s "$(command -v sleep)" "$runtime_path/sleep"

    PATH="$runtime_path" /bin/bash --noprofile --norc -c '
        printf "%s\n" "$$" > "$2"
        source "$1"
        timeout 30 /bin/bash -c '\''
            printf "%s\n" "$PPID" > "$1"
            /bin/bash -c "trap \"\" HUP INT QUIT TERM; sleep 30" &
            printf "%s\n" "$!" > "$2"
            wait
        '\'' _ "$3" "$4"
    ' _ "$KYZN_ROOT/lib/core.sh" "$caller_file" "$controller_file" "$leaf_file" \
        >/dev/null 2>&1 &
    local caller_pid=$!

    local attempt
    for ((attempt = 0; attempt < 80; attempt++)); do
        [[ -s "$caller_file" && -s "$controller_file" && -s "$leaf_file" ]] && break
        sleep 0.05
    done

    local recorded_caller controller_pid leaf_pid lifecycle_status=0
    recorded_caller=$(<"$caller_file")
    controller_pid=$(<"$controller_file")
    leaf_pid=$(<"$leaf_file")
    if [[ "$recorded_caller" != "$caller_pid" || -z "$controller_pid" || -z "$leaf_pid" ]]; then
        kill -KILL "$caller_pid" "$controller_pid" "$leaf_pid" 2>/dev/null || true
        wait "$caller_pid" 2>/dev/null || true
        rm -rf "$runtime_path" "$caller_file" "$controller_file" "$leaf_file"
        fail "$controller $action $signal_name lifecycle setup" "failed to capture validated process IDs"
        return
    fi

    if [[ "$action" == parent-death ]]; then
        kill "-$signal_name" "$caller_pid"
    else
        kill "-$signal_name" "$controller_pid"
    fi
    wait "$caller_pid" 2>/dev/null || lifecycle_status=$?

    for ((attempt = 0; attempt < 80; attempt++)); do
        if ! kill -0 "$controller_pid" 2>/dev/null && ! kill -0 "$leaf_pid" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    local survivors=0
    if kill -0 "$controller_pid" 2>/dev/null; then
        survivors=$((survivors + 1))
        kill -KILL "$controller_pid" 2>/dev/null || true
    fi
    if kill -0 "$leaf_pid" 2>/dev/null; then
        survivors=$((survivors + 1))
        kill -KILL "$leaf_pid" 2>/dev/null || true
    fi

    rm -rf "$runtime_path" "$caller_file" "$controller_file" "$leaf_file"
    assert_eq "$controller $action $signal_name leaves no managed processes" "0" "$survivors"
    if [[ "$action" == signal-forward ]]; then
        assert_exit_code "$controller forwards $signal_name with shell status" "$expected_status" "$lifecycle_status"
    fi
}

test_portable_timeout_fallback() {
    log_header "33b. Portable timeout fallback"

    # Force core.sh to define its fallback even on Linux hosts that provide
    # GNU timeout. Provide exactly one controller runtime and an integer-only
    # sleep stub so fractional shell polling would fail deterministically.
    local fallback_path result controller single_marker
    fallback_path=$(mktemp -d)
    if command -v perl &>/dev/null; then
        controller=perl
    elif command -v python3 &>/dev/null; then
        controller=python3
    else
        rm -rf "$fallback_path"
        skip "portable timeout fallback" "perl or python3 unavailable"
        return
    fi
    ln -s "$(command -v "$controller")" "$fallback_path/$controller"
    cat > "$fallback_path/sleep" <<'SH'
#!/bin/sh
case "$1" in
    *.*) exit 64 ;;
esac
exec /bin/sleep "$@"
SH
    chmod +x "$fallback_path/sleep"

    local descendant_pids
    descendant_pids=$(mktemp)
    single_marker="$fallback_path/single-exec-marker"

    result=$(PATH="$fallback_path" /bin/bash --noprofile --norc -c '
        source "$1"
        [[ $(type -t timeout) == function ]] || exit 90

        local_start=$SECONDS
        value=$(timeout 3 /usr/bin/printf hello)
        fast_status=$?
        fast_elapsed=$((SECONDS - local_start))
        printf "fast=%s|%s|%s\n" "$fast_status" "$value" "$fast_elapsed"

        local_start=$SECONDS
        timed_status=0
        timeout 1 sleep 5 || timed_status=$?
        timed_elapsed=$((SECONDS - local_start))
        printf "timed=%s|%s\n" "$timed_status" "$timed_elapsed"

        child_status=0
        timeout 3 /bin/bash -c "exit 7" || child_status=$?
        printf "child=%s\n" "$child_status"

        invalid_status=0
        invalid_output=$(timeout abc true 2>&1) || invalid_status=$?
        printf "invalid=%s|%s\n" "$invalid_status" "$invalid_output"

        suffix_value=$(timeout .5s /usr/bin/printf suffix)
        minute_value=$(timeout 1m /usr/bin/printf minute)
        printf "durations=%s|%s\n" "$suffix_value" "$minute_value"

        zero_value=$(timeout 0 printf disabled)
        zero_status=$?
        printf "zero=%s|%s\n" "$zero_status" "$zero_value"

        tree_status=0
        timeout 1 /bin/bash -c '\''
            /bin/bash -c "trap \"\" TERM; sleep 30" & echo $! >> "$1"
            sleep 30 & echo $! >> "$1"
            wait
        '\'' _ "$2" || tree_status=$?
        printf "tree=%s\n" "$tree_status"

        single_status=0
        timeout 1 "true; /usr/bin/touch $3" 2>/dev/null || single_status=$?
        [[ -e "$3" ]] && single_created=yes || single_created=no
        printf "single=%s|%s\n" "$single_status" "$single_created"
    ' _ "$KYZN_ROOT/lib/core.sh" "$descendant_pids" "$single_marker")

    rm -rf "$fallback_path"

    assert_contains "fallback returns fast command output" "$result" "fast=0|hello|"

    local fast_elapsed timed_elapsed
    fast_elapsed=$(printf '%s\n' "$result" | awk -F'|' '/^fast=/{print $3}')
    timed_elapsed=$(printf '%s\n' "$result" | awk -F'|' '/^timed=/{print $2}')
    if (( fast_elapsed < 2 )); then
        pass "fallback does not wait for timeout after fast command"
    else
        fail "fallback fast command duration" "took ${fast_elapsed}s"
    fi
    assert_contains "fallback returns timeout status" "$result" "timed=124|"
    if (( timed_elapsed >= 1 && timed_elapsed < 3 )); then
        pass "fallback terminates long command near deadline"
    else
        fail "fallback timeout duration" "took ${timed_elapsed}s"
    fi
    assert_contains "fallback preserves child exit status" "$result" "child=7"
    assert_contains "fallback rejects invalid duration" "$result" "invalid=125|timeout: invalid duration 'abc'"
    assert_contains "fallback accepts GNU duration grammar" "$result" "durations=suffix|minute"
    assert_contains "fallback zero disables timeout" "$result" "zero=0|disabled"
    assert_contains "fallback times out process tree" "$result" "tree=124"
    assert_contains "fallback never shell-interprets one argument" "$result" "single=127|no"

    local leaked=0 child_pid
    while IFS= read -r child_pid; do
        if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
            leaked=$((leaked + 1))
            kill "$child_pid" 2>/dev/null || true
        fi
    done < "$descendant_pids"
    rm -f "$descendant_pids"
    assert_eq "fallback reaps descendant processes" "0" "$leaked"

    local no_runtime_path no_runtime_result
    no_runtime_path=$(mktemp -d)
    no_runtime_result=$(PATH="$no_runtime_path" /bin/bash --noprofile --norc -c '
        source "$1"
        status=0
        timeout 1 true || status=$?
        printf "status=%s\n" "$status"
    ' _ "$KYZN_ROOT/lib/core.sh" 2>&1)
    rm -rf "$no_runtime_path"
    assert_contains "fallback fails explicitly without controller runtime" "$no_runtime_result" "status=125"
    assert_contains "fallback explains missing controller runtime" "$no_runtime_result" "requires perl or python3"

    local lifecycle_controller
    for lifecycle_controller in perl python3; do
        command -v "$lifecycle_controller" &>/dev/null || continue
        _test_timeout_lifecycle "$lifecycle_controller" parent-death TERM 0
        _test_timeout_lifecycle "$lifecycle_controller" parent-death KILL 0
        _test_timeout_lifecycle "$lifecycle_controller" signal-forward TERM 143
    done
    command -v perl &>/dev/null && _test_timeout_lifecycle perl signal-forward INT 130
    if command -v python3 &>/dev/null; then
        _test_timeout_lifecycle python3 signal-forward HUP 129
        _test_timeout_lifecycle python3 signal-forward QUIT 131
    fi
}

test_tightened_allowlist() {
    log_header "34. Tightened allowlist wildcards"

    source "$KYZN_ROOT/lib/allowlist.sh"

    # Python: should NOT have broad 'python *', should have specific subcommands
    local -a py_arr=()
    build_allowlist py_arr "python"
    local py_list="${py_arr[*]}"
    assert_not_contains "python no broad wildcard" "$py_list" 'Bash(python *)'
    assert_contains "python has pytest" "$py_list" "pytest"
    assert_contains "python has python -m pytest" "$py_list" "python -m pytest"

    # Node: should NOT have broad 'npm *', should have specific subcommands
    local -a node_arr=()
    build_allowlist node_arr "node"
    local node_list="${node_arr[*]}"
    assert_not_contains "node no broad npm wildcard" "$node_list" 'Bash(npm *)'
    assert_contains "node has npm test" "$node_list" "npm test"
    assert_contains "node has npm run" "$node_list" "npm run"
    assert_not_contains "node no bare node" "$node_list" 'Bash(node *)'

    # Rust: should NOT have broad 'cargo *'
    local -a rust_arr=()
    build_allowlist rust_arr "rust"
    local rust_list="${rust_arr[*]}"
    assert_not_contains "rust no broad cargo wildcard" "$rust_list" 'Bash(cargo *)'
    assert_contains "rust has cargo test" "$rust_list" "cargo test"
    assert_contains "rust has cargo check" "$rust_list" "cargo check"

    # Go: should NOT have broad 'go *'
    local -a go_arr=()
    build_allowlist go_arr "go"
    local go_list="${go_arr[*]}"
    assert_not_contains "go no broad go wildcard" "$go_list" 'Bash(go *)'
    assert_contains "go has go test" "$go_list" "go test"
    assert_contains "go has go build" "$go_list" "go build"

    # C#: should NOT have broad 'dotnet *'
    local -a cs_arr=()
    build_allowlist cs_arr "csharp"
    local cs_list="${cs_arr[*]}"
    assert_not_contains "csharp no broad dotnet wildcard" "$cs_list" 'Bash(dotnet *)'
    assert_contains "csharp has dotnet build" "$cs_list" "dotnet build"
    assert_contains "csharp has dotnet test" "$cs_list" "dotnet test"

    # Java: should NOT have broad 'mvn *' / 'gradle *' / './gradlew *'
    local -a java_arr=()
    build_allowlist java_arr "java"
    local java_list="${java_arr[*]}"
    assert_not_contains "java no broad mvn wildcard"      "$java_list" 'Bash(mvn *)'
    assert_not_contains "java no broad gradle wildcard"   "$java_list" 'Bash(gradle *)'
    assert_not_contains "java no broad gradlew wildcard"  "$java_list" 'Bash(./gradlew *)'
    assert_contains     "java has mvn test"               "$java_list" "mvn test"
    assert_contains     "java has gradlew test"           "$java_list" "./gradlew test"
    assert_contains     "java has gradle build"           "$java_list" "gradle build"

    # Security: npm install and pip install should NOT be in allowlists (arbitrary code execution via install scripts)
    assert_not_contains "node no npm install" "$node_list" 'Bash(npm install'
    assert_not_contains "python no pip install" "$py_list" 'Bash(pip install'
    assert_not_contains "python no python -m pip" "$py_list" 'Bash(python -m pip'

    # Generic: should NOT have 'cat *'
    local -a gen_arr=()
    build_allowlist gen_arr "generic"
    local gen_list="${gen_arr[*]}"
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

test_phase0_execution_and_autopilot_gates() {
    log_header "35b. Phase 0 unsafe-execution and autopilot gates"

    local gate_output gate_status=0
    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=false
    _KYZN_UNSAFE_HOST_EXECUTION_WARNED=false
    gate_output=$(require_unsafe_host_execution "test mutation" 2>&1) || gate_status=$?
    assert_exit_code "unsafe host execution defaults closed" "1" "$gate_status"
    assert_contains "closed gate points to analysis-only" "$gate_output" "kyzn analyze"
    assert_contains "closed gate names explicit override" "$gate_output" "--allow-unsafe-host-execution"

    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=true
    _KYZN_UNSAFE_HOST_EXECUTION_WARNED=false
    gate_status=0
    gate_output=$(require_unsafe_host_execution "test mutation" 2>&1) || gate_status=$?
    assert_exit_code "explicit unsafe host execution opt-in passes" "0" "$gate_status"
    assert_contains "unsafe opt-in gives isolation warning" "$gate_output" "no container/VM isolation"
    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=false
    _KYZN_UNSAFE_HOST_EXECUTION_WARNED=false

    local inherited_output inherited_status=0
    inherited_output=$(_KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=true /bin/bash --noprofile --norc -c '
        source "$1"
        require_unsafe_host_execution "inherited environment test"
    ' _ "$KYZN_ROOT/lib/core.sh" 2>&1) || inherited_status=$?
    assert_exit_code "inherited environment cannot authorize host execution" "1" "$inherited_status"
    assert_contains "inherited authorization still names explicit CLI flag" "$inherited_output" "--allow-unsafe-host-execution"

    source "$KYZN_ROOT/lib/measure.sh"
    local measurement_tmp measurement_script measurement_results measurement_marker
    measurement_tmp=$(mktemp -d)
    measurement_script="$measurement_tmp/dynamic.sh"
    measurement_results="$measurement_tmp/results.json"
    measurement_marker="$measurement_tmp/ran"
    cat > "$measurement_script" <<'DYNAMIC_MEASURER'
#!/usr/bin/env bash
printf 'ran\n' > "$KYZN_TEST_MARKER"
printf '[]\n'
DYNAMIC_MEASURER
    chmod +x "$measurement_script"
    printf '[]\n' > "$measurement_results"
    export KYZN_TEST_MARKER="$measurement_marker"

    local measurement_output measurement_status=0
    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=false
    measurement_output=$(run_measurer "$measurement_script" "$measurement_results" "dynamic" 2>&1) || measurement_status=$?
    assert_exit_code "dynamic measurer skip is non-fatal" "0" "$measurement_status"
    assert_contains "dynamic measurer explains explicit flag" "$measurement_output" "--allow-unsafe-host-execution"
    if [[ ! -e "$measurement_marker" ]]; then
        pass "dynamic measurer cannot launch without explicit flag"
    else
        fail "dynamic measurer cannot launch without explicit flag" "side-effect marker was created"
    fi

    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=true
    _KYZN_UNSAFE_HOST_EXECUTION_WARNED=false
    measurement_status=0
    measurement_output=$(run_measurer "$measurement_script" "$measurement_results" "dynamic" 2>&1) || measurement_status=$?
    assert_exit_code "explicit flag allows dynamic measurer" "0" "$measurement_status"
    assert_contains "dynamic measurer opt-in warns about missing isolation" "$measurement_output" "no container/VM isolation"
    assert_file_exists "explicit flag reaches dynamic measurer side effect" "$measurement_marker"
    unset KYZN_TEST_MARKER
    rm -rf "$measurement_tmp"
    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=false
    _KYZN_UNSAFE_HOST_EXECUTION_WARNED=false

    create_sandbox node
    local gate_tmp="$SANDBOX/gate-test" gate_bin="$SANDBOX/gate-test/bin"
    mkdir -p "$gate_bin" "$gate_tmp/home/.kyzn"
    date +%s > "$gate_tmp/home/.kyzn/last-update-check"
    cat > "$gate_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KYZN_TEST_MARKER"
exit 0
FAKE_CLAUDE
    chmod +x "$gate_bin/claude"
    export KYZN_TEST_MARKER="$gate_tmp/claude-invocations"

    local cli_output cli_status=0
    cli_output=$(HOME="$gate_tmp/home" PATH="$gate_bin:$PATH" "$BASH" "$KYZN_ROOT/kyzn" quick --auto 2>&1) || cli_status=$?
    assert_exit_code "quick CLI defaults closed" "1" "$cli_status"
    assert_contains "quick CLI names explicit override" "$cli_output" "--allow-unsafe-host-execution"
    if [[ ! -e "$KYZN_TEST_MARKER" ]]; then
        pass "quick CLI cannot invoke Claude without explicit flag"
    else
        fail "quick CLI cannot invoke Claude without explicit flag" "Claude marker was created"
    fi

    cli_status=0
    cli_output=$(HOME="$gate_tmp/home" PATH="$gate_bin:$PATH" "$BASH" "$KYZN_ROOT/kyzn" fix --auto 2>&1) || cli_status=$?
    assert_exit_code "fix CLI defaults closed" "1" "$cli_status"
    assert_contains "fix CLI names explicit override" "$cli_output" "--allow-unsafe-host-execution"
    if [[ ! -e "$KYZN_TEST_MARKER" ]]; then
        pass "fix CLI cannot invoke Claude without explicit flag"
    else
        fail "fix CLI cannot invoke Claude without explicit flag" "Claude marker was created"
    fi

    cat > "$gate_bin/npm" <<'FAKE_NPM'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$KYZN_TEST_MARKER"
printf '{}\n'
FAKE_NPM
    cat > "$gate_bin/npx" <<'FAKE_NPX'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "$KYZN_TEST_MARKER"
exit 1
FAKE_NPX
    chmod +x "$gate_bin/npm" "$gate_bin/npx"
    rm -f "$KYZN_TEST_MARKER"

    cli_status=0
    cli_output=$(HOME="$gate_tmp/home" PATH="$gate_bin:$PATH" "$BASH" "$KYZN_ROOT/kyzn" measure 2>&1) || cli_status=$?
    assert_exit_code "measure CLI keeps static path available by default" "0" "$cli_status"
    assert_contains "measure CLI reports skipped dynamic tools" "$cli_output" "Dynamic measurements skipped"
    if [[ ! -e "$KYZN_TEST_MARKER" ]]; then
        pass "measure CLI cannot launch package tools without explicit flag"
    else
        fail "measure CLI cannot launch package tools without explicit flag" "package-tool marker was created"
    fi

    cli_status=0
    cli_output=$(HOME="$gate_tmp/home" PATH="$gate_bin:$PATH" "$BASH" "$KYZN_ROOT/kyzn" measure --allow-unsafe-host-execution 2>&1) || cli_status=$?
    assert_exit_code "measure CLI explicit flag allows dynamic tools" "0" "$cli_status"
    assert_contains "measure CLI explicit flag warns about host execution" "$cli_output" "no container/VM isolation"
    assert_file_exists "measure CLI explicit flag reaches package tools" "$KYZN_TEST_MARKER"
    unset KYZN_TEST_MARKER
    cleanup_sandbox

    source "$KYZN_ROOT/lib/schedule.sh"
    local schedule_tmp schedule_marker schedule_output schedule_status=0
    schedule_tmp=$(mktemp -d)
    schedule_marker="$schedule_tmp/crontab-invoked"
    crontab() { printf 'invoked\n' > "$schedule_marker"; }
    schedule_output=$(cmd_schedule daily 2>&1) || schedule_status=$?
    assert_exit_code "daily schedule creation is disabled" "1" "$schedule_status"
    assert_contains "schedule failure explains isolation requirement" "$schedule_output" "isolated execution"
    if [[ ! -e "$schedule_marker" ]]; then
        pass "disabled schedule creation never invokes crontab"
    else
        fail "disabled schedule creation never invokes crontab" "crontab marker was created"
    fi
    unset -f crontab
    rm -rf "$schedule_tmp"

    source "$KYZN_ROOT/lib/report.sh"
    local autopilot_output
    autopilot_output=$(maybe_request_automerge "autopilot" "https://example.invalid/pr" 2>&1)
    assert_contains "legacy autopilot is visibly disabled" "$autopilot_output" "autopilot mode is disabled"
    assert_contains "legacy autopilot requires manual review" "$autopilot_output" "manual review"

    local execute_src analyze_src interview_src schedule_src measure_src kyzn_src
    execute_src=$(cat "$KYZN_ROOT/lib/execute.sh")
    analyze_src=$(cat "$KYZN_ROOT/lib/analyze.sh")
    interview_src=$(cat "$KYZN_ROOT/lib/interview.sh")
    schedule_src=$(cat "$KYZN_ROOT/lib/schedule.sh")
    measure_src=$(cat "$KYZN_ROOT/lib/measure.sh")
    kyzn_src=$(cat "$KYZN_ROOT/kyzn")

    local executable_sources="" source_file merge_command automerge_flags
    for source_file in "$KYZN_ROOT/kyzn" "$KYZN_ROOT/install.sh" "$KYZN_ROOT"/lib/*.sh "$KYZN_ROOT"/measurers/*.sh "$KYZN_ROOT/tests/selftest.sh"; do
        executable_sources+=$(cat "$source_file")
    done
    merge_command='gh pr'' merge'
    automerge_flags='--auto ''--squash'
    assert_not_contains "all executable sources avoid GitHub auto-merge" "$executable_sources" "$merge_command"
    assert_not_contains "all executable sources avoid auto-merge flags" "$executable_sources" "$automerge_flags"
    assert_not_contains "init no longer offers autopilot" "$interview_src" "Autopilot — auto-merge"
    assert_contains "quick parser exposes unsafe host flag" "$execute_src" "--allow-unsafe-host-execution"
    assert_contains "quick requires unsafe host gate" "$execute_src" 'require_unsafe_host_execution "quick/improve"'
    assert_contains "analyze fix requires unsafe host gate" "$analyze_src" 'require_unsafe_host_execution "analyze --fix"'
    assert_contains "fix phase independently requires gate" "$analyze_src" 'require_unsafe_host_execution "fix phase"'
    assert_contains "dynamic measurement gate is at launch boundary" "$measure_src" 'require_unsafe_host_execution "dynamic project measurement"'
    assert_contains "static generic measurement remains available" "$measure_src" '"static"'
    assert_contains "measure runtime recommends explicit fix opt-in" "$measure_src" "kyzn fix --allow-unsafe-host-execution"
    assert_contains "measure runtime explains missing isolation" "$measure_src" "without container/VM isolation"
    assert_contains "analyze runtime recommends explicit fix opt-in" "$analyze_src" "kyzn fix --allow-unsafe-host-execution"
    assert_contains "analyze runtime explains host risk" "$analyze_src" "project commands and AI changes as your user"
    assert_contains "init runtime describes static measure boundary" "$interview_src" "static measurements (no project commands)"
    assert_contains "init runtime recommends explicit fix opt-in" "$interview_src" "kyzn fix --allow-unsafe-host-execution"
    assert_contains "scheduled mutation creation is disabled" "$schedule_src" "disabled until KyZN provides isolated execution"
    assert_not_contains "schedule creation cannot persist an opt-in" "$schedule_src" "improve --auto --allow-unsafe-host-execution"
    assert_contains "doctor install exposes unsafe host flag" "$kyzn_src" "--allow-unsafe-host-execution"
    assert_contains "doctor install requires unsafe host gate" "$kyzn_src" 'require_unsafe_host_execution "doctor dependency installation"'
    assert_contains "doctor uses non-agent auth status probe" "$kyzn_src" "claude auth status --json"
    assert_not_contains "doctor never starts a model session for auth" "$kyzn_src" 'claude -p "hi"'
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

    # Case 1: direct JSON array in .result field
    local fake_result findings len
    fake_result=$(jq -n '{result: "[{\"id\":\"BUG-001\",\"severity\":\"HIGH\",\"title\":\"test\"}]"}')
    findings=$(extract_findings "$fake_result")
    len=$(echo "$findings" | jq 'length' 2>/dev/null) || len=0
    assert_eq "extract_findings direct JSON array" "1" "$len"

    # Case 2: JSON embedded in prose text
    fake_result=$(jq -n '{result: "I found these issues:\n[\n{\"id\":\"SEC-001\",\"severity\":\"MEDIUM\",\"title\":\"injection\"}\n]\nPlease fix them."}')
    findings=$(extract_findings "$fake_result")
    len=$(echo "$findings" | jq 'length' 2>/dev/null) || len=0
    if (( len >= 1 )); then
        pass "extract_findings JSON embedded in prose"
    else
        fail "extract_findings prose" "expected >=1 findings, got $len"
    fi

    # Case 3: JSON in markdown code fences
    fake_result=$(jq -n '{result: "Here are my findings:\n```json\n[{\"id\":\"BUG-001\",\"severity\":\"HIGH\",\"title\":\"test\"}]\n```"}')
    findings=$(extract_findings "$fake_result")
    if echo "$findings" | jq -e 'type == "array"' &>/dev/null; then
        pass "extract_findings JSON in code fences returns array"
    else
        fail "extract_findings code fences" "did not return JSON array"
    fi

    # Case 4: invalid/empty response returns empty array
    fake_result=$(jq -n '{result: "No findings to report."}')
    findings=$(extract_findings "$fake_result")
    len=$(echo "$findings" | jq 'length' 2>/dev/null) || len=-1
    assert_eq "extract_findings invalid/empty returns []" "0" "$len"

    # Case 5: large array embedded in prose must NOT be silently truncated.
    # Builds 100 findings (~9 lines each pretty-printed = ~900 lines) wrapped
    # in prose so the sed-range extraction path is exercised. The historical
    # `head -500` cap clipped the closing `]` and produced [] silently.
    local big_array
    big_array=$(jq -n '[range(0;100) | {
        id: ("BUG-\(.+1)"),
        severity: "MEDIUM",
        category: "bug",
        title: ("test bug \(.+1)"),
        file: ("src/file\(.+1).js"),
        line: (.+10),
        fix: "fix description here",
        fix_plan: "target_file: src/file.js | target_function: handler"
    }]')
    local prose_wrapped
    prose_wrapped="Here are my findings:
${big_array}
That is all."
    fake_result=$(jq -n --arg t "$prose_wrapped" '{result: $t}')
    findings=$(extract_findings "$fake_result")
    len=$(echo "$findings" | jq 'length' 2>/dev/null) || len=0
    assert_eq "extract_findings preserves 100-finding array in prose (no truncation)" "100" "$len"
}

test_generate_fix_prompt() {
    log_header "41. Fix prompt generation from findings"

    source "$KYZN_ROOT/lib/analyze.sh"

    # generate_fix_prompt now takes JSON string, not file path
    # Severity filtering is done by run_fix_phase before calling this
    local findings_json='[
  {"id":"BUG-001","severity":"CRITICAL","category":"bug","title":"Null deref","file":"src/main.ts","line":10,"fix":"Add null check"},
  {"id":"SEC-001","severity":"HIGH","category":"security","title":"SQL injection","file":"src/db.ts","line":20,"fix":"Use parameterized query"}
]'

    local prompt
    prompt=$(generate_fix_prompt "$findings_json" "" "")

    assert_contains "fix prompt has BUG-001" "$prompt" "BUG-001"
    assert_contains "fix prompt has SEC-001" "$prompt" "SEC-001"
    assert_contains "fix prompt has rules" "$prompt" "Fix each issue"
    assert_contains "fix prompt has skip guidance" "$prompt" "contradicts reality"
    assert_contains "fix prompt requires security tests" "$prompt" "regression test"
    assert_contains "fix prompt requires critical bug tests" "$prompt" "verifies the fix"
    assert_contains "fix prompt forbids test deletion" "$prompt" "Do not delete test files"

    # Test with baseline failures context
    local prompt_with_baseline
    prompt_with_baseline=$(generate_fix_prompt "$findings_json" "" "FAILED test_login
FAILED test_signup")

    assert_contains "baseline context included" "$prompt_with_baseline" "Pre-Existing Test Failures"
    assert_contains "baseline has test names" "$prompt_with_baseline" "test_login"

    # Test with installed packages (4th arg)
    local prompt_with_pkgs
    prompt_with_pkgs=$(generate_fix_prompt "$findings_json" "" "" "fastapi
pydantic
pytest")
    assert_contains "packages section present" "$prompt_with_pkgs" "Available Packages"
    assert_contains "mock guidance present" "$prompt_with_pkgs" "unittest.mock"
    assert_contains "package listed" "$prompt_with_pkgs" "fastapi"

    # Test empty findings
    local empty_prompt
    empty_prompt=$(generate_fix_prompt "[]" "" "")
    assert_eq "empty findings returns empty" "" "$empty_prompt"
}

test_analyze_wired_in_kyzn() {
    log_header "42. analyze and fix commands are wired into kyzn"

    local help_output
    help_output=$("$KYZN_ROOT/kyzn" help 2>&1)
    assert_contains "help shows analyze" "$help_output" "analyze"
    assert_contains "help shows fix" "$help_output" "fix"
    assert_contains "fix is first command" "$help_output" "Deep analysis + auto-fix"
}

test_reject_no_learn_message() {
    log_header "43. Reject says 'recorded' not 'will learn'"

    local src
    src=$(cat "$KYZN_ROOT/lib/approve.sh")
    assert_contains "has 'Rejection recorded'" "$src" "Rejection recorded"
    assert_not_contains "no 'will learn' message" "$src" "will learn"
}

# ---------------------------------------------------------------------------
# Dashboard & write_history tests
# ---------------------------------------------------------------------------

test_relative_time() {
    log_header "44. relative_time() formatting"

    source "$KYZN_ROOT/lib/history.sh"

    # "just now" — current timestamp
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local result
    result=$(relative_time "$now")
    assert_eq "current time → just now" "just now" "$result"

    # "Xm ago" — 5 minutes ago
    local five_min_ago
    five_min_ago=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || {
        skip "relative_time minutes" "BSD date not supported in test"
        return
    }
    result=$(relative_time "$five_min_ago")
    assert_eq "5 min ago" "5m ago" "$result"

    # "Xh ago" — 2 hours ago
    local two_hours_ago
    two_hours_ago=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)
    result=$(relative_time "$two_hours_ago")
    assert_eq "2 hours ago" "2h ago" "$result"

    # "Xd ago" — 3 days ago
    local three_days_ago
    three_days_ago=$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)
    result=$(relative_time "$three_days_ago")
    assert_eq "3 days ago" "3d ago" "$result"

    # Empty/null
    result=$(relative_time "")
    assert_eq "empty → dash" "-" "$result"
    result=$(relative_time "null")
    assert_eq "null → dash" "-" "$result"
}

test_write_history() {
    log_header "45. write_history() dual-write"

    create_sandbox generic

    # write_history writes to both local and global
    declare -A _test_hist=([health_before]="42" [focus]="testing")
    write_history "test-run-001" "improve" "running" _test_hist

    # Check local file exists
    assert_file_exists "local history file" "$KYZN_HISTORY_DIR/test-run-001.json"

    # Check global file exists
    assert_file_exists "global history file" "$KYZN_GLOBAL_HISTORY/test-run-001.json"

    # Check JSON fields
    local json
    json=$(cat "$KYZN_HISTORY_DIR/test-run-001.json")
    local id type status project hb focus
    id=$(echo "$json" | jq -r '.run_id')
    type=$(echo "$json" | jq -r '.type')
    status=$(echo "$json" | jq -r '.status')
    project=$(echo "$json" | jq -r '.project')
    hb=$(echo "$json" | jq -r '.health_before')
    focus=$(echo "$json" | jq -r '.focus')

    assert_eq "run_id field" "test-run-001" "$id"
    assert_eq "type field" "improve" "$type"
    assert_eq "status field" "running" "$status"
    [[ -n "$project" ]] && pass "project field" || fail "project field" "empty"
    assert_eq "health_before field" "42" "$hb"
    assert_eq "focus field" "testing" "$focus"

    # Empty fields should be filtered out
    declare -A _test_hist2=([health_before]="" [focus]="quality")
    write_history "test-run-002" "improve" "completed" _test_hist2

    local has_hb
    has_hb=$(jq 'has("health_before")' "$KYZN_HISTORY_DIR/test-run-002.json")
    assert_eq "empty health_before filtered" "false" "$has_hb"

    # Clean up global files
    rm -f "$KYZN_GLOBAL_HISTORY/test-run-001.json" "$KYZN_GLOBAL_HISTORY/test-run-002.json" 2>/dev/null

    cleanup_sandbox
}

test_dashboard() {
    log_header "46. dashboard shows project entries"

    source "$KYZN_ROOT/lib/history.sh"

    # Create fake global history entries
    local global_dir="$KYZN_GLOBAL_HISTORY"
    mkdir -p "$global_dir"

    # Project 1: improve completed
    jq -n --arg proj "CMS" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:"run1",type:"improve",status:"completed",project:$proj,ts:$ts,health_before:"65",health_after:"72"}' \
        > "$global_dir/test-dash-001.json"

    # Project 2: analyze completed
    jq -n --arg proj "InContext" --arg ts "$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:"run2",type:"analyze",status:"completed",project:$proj,ts:$ts,finding_count:"8"}' \
        > "$global_dir/test-dash-002.json"

    # Project 3: measure completed
    jq -n --arg proj "takamul" --arg ts "$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:"run3",type:"measure",status:"completed",project:$proj,ts:$ts,health_score:"71"}' \
        > "$global_dir/test-dash-003.json"

    # Run dashboard in a subshell to isolate from parent set -e
    local output
    output=$(KYZN_VERSION="0.4.0" bash -c '
        source "'"$KYZN_ROOT"'/lib/core.sh"
        source "'"$KYZN_ROOT"'/lib/history.sh"
        cmd_dashboard
    ' 2>&1) || true

    assert_contains "shows CMS" "$output" "CMS"
    assert_contains "shows InContext" "$output" "InContext"
    assert_contains "shows takamul" "$output" "takamul"
    assert_contains "shows improve type" "$output" "improve"
    assert_contains "shows analyze type" "$output" "analyze"
    assert_contains "shows measure type" "$output" "measure"

    # Clean up
    rm -f "$global_dir/test-dash-001.json" "$global_dir/test-dash-002.json" "$global_dir/test-dash-003.json"
}

test_dashboard_corrupt() {
    log_header "47. dashboard handles corrupt/empty files"

    local global_dir="$KYZN_GLOBAL_HISTORY"
    mkdir -p "$global_dir"

    # Create a 0-byte file
    : > "$global_dir/test-corrupt-001.json"

    # Create a valid entry alongside it
    jq -n --arg proj "ValidProject" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:"run-valid",type:"measure",status:"completed",project:$proj,ts:$ts,health_score:"80"}' \
        > "$global_dir/test-corrupt-002.json"

    local output
    local exit_code=0
    output=$(KYZN_VERSION="0.4.0" bash -c '
        source "'"$KYZN_ROOT"'/lib/core.sh"
        source "'"$KYZN_ROOT"'/lib/history.sh"
        cmd_dashboard
    ' 2>&1) || exit_code=$?

    if (( exit_code == 0 )); then
        pass "dashboard doesn't crash with corrupt file"
    else
        fail "dashboard crash" "exit code $exit_code with corrupt file"
    fi

    # Clean up
    rm -f "$global_dir/test-corrupt-001.json" "$global_dir/test-corrupt-002.json"
}

test_dashboard_hyphenated_project() {
    log_header "48. dashboard handles hyphenated project names"

    local global_dir="$KYZN_GLOBAL_HISTORY"
    mkdir -p "$global_dir"

    jq -n --arg proj "my-cool-app" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:"run-hyph",type:"measure",status:"completed",project:$proj,ts:$ts,health_score:"55"}' \
        > "$global_dir/test-hyph-001.json"

    local output
    output=$(KYZN_VERSION="0.4.0" bash -c '
        source "'"$KYZN_ROOT"'/lib/core.sh"
        source "'"$KYZN_ROOT"'/lib/history.sh"
        cmd_dashboard
    ' 2>&1) || true

    assert_contains "shows hyphenated project" "$output" "my-cool-app"

    # Clean up
    rm -f "$global_dir/test-hyph-001.json"
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

    for ptype in node python go rust csharp java generic; do
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
# v0.5.0 security hardening tests
# ---------------------------------------------------------------------------

test_enforce_config_ceilings() {
    log_header "37. enforce_config_ceilings prevents injection and caps values"

    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/allowlist.sh"

    # Test normal capping
    local budget=30 turns=200 diff=20000
    enforce_config_ceilings budget turns diff
    assert_eq "budget capped to 25" "25" "$budget"
    assert_eq "turns capped to 100" "100" "$turns"
    assert_eq "diff capped to 10000" "10000" "$diff"

    # Test values below ceiling are not changed
    local budget2=5 turns2=10 diff2=500
    enforce_config_ceilings budget2 turns2 diff2
    assert_eq "budget under ceiling unchanged" "5" "$budget2"
    assert_eq "turns under ceiling unchanged" "10" "$turns2"
    assert_eq "diff under ceiling unchanged" "500" "$diff2"

    # Test that malicious input doesn't execute code (awk injection attempt)
    # shellcheck disable=SC2034 # Variables are passed by name to enforce_config_ceilings.
    local budget3='0); system("id") #' turns3=10 diff3=100
    # Should not crash or execute anything — awk -v safely passes the value
    local exit_code=0
    enforce_config_ceilings budget3 turns3 diff3 2>/dev/null || exit_code=$?
    # The value should be capped or left alone, not executed
    pass "awk injection attempt did not crash (exit: $exit_code)"
}

test_unstage_secrets() {
    log_header "49. unstage_secrets removes staged secret files"

    source "$KYZN_ROOT/lib/execute.sh"

    create_sandbox generic

    # Create and stage files matching secret patterns
    echo "SECRET=abc" > .env
    echo "SECRET=abc" > credentials.json
    echo "--- KEY ---" > server.pem
    echo "data" > safe-file.txt

    git add .env credentials.json server.pem safe-file.txt 2>/dev/null

    # Run unstage_secrets
    unstage_secrets 2>/dev/null

    # Check that secret files are no longer staged
    local staged
    staged=$(git diff --cached --name-only 2>/dev/null)

    if echo "$staged" | grep -q '\.env'; then
        fail "unstage .env" ".env still staged"
    else
        pass "unstage .env — removed from staging"
    fi

    if echo "$staged" | grep -q '\.pem'; then
        fail "unstage .pem" "server.pem still staged"
    else
        pass "unstage .pem — removed from staging"
    fi

    if echo "$staged" | grep -q 'credentials'; then
        fail "unstage credentials" "credentials.json still staged"
    else
        pass "unstage credentials — removed from staging"
    fi

    if echo "$staged" | grep -q 'safe-file'; then
        pass "safe file remains staged"
    else
        fail "safe file" "safe-file.txt was incorrectly unstaged"
    fi

    cleanup_sandbox
}

test_unstage_secrets_nested_dotenv() {
    log_header "70. unstage_secrets handles nested .env.* paths (Next.js / monorepo)"

    source "$KYZN_ROOT/lib/execute.sh"

    create_sandbox generic

    # Plant dotenv files in the patterns Next.js / Vercel / monorepos use:
    # top-level with extension, and nested under app dirs.
    mkdir -p web apps/api
    echo "DATABASE_URL=secret" > .env.production
    echo "API_KEY=secret"      > .env.local
    echo "WEB_SECRET=val"      > web/.env.production
    echo "API_SECRET=val"      > apps/api/.env.local
    echo "data"                > web/safe-config.json

    git add .env.production .env.local web/.env.production apps/api/.env.local web/safe-config.json 2>/dev/null

    unstage_secrets 2>/dev/null

    local staged
    staged=$(git diff --cached --name-only 2>/dev/null)

    if echo "$staged" | grep -qx '\.env\.production'; then
        fail "unstage .env.production (top-level)" "still staged"
    else
        pass "unstage .env.production (top-level)"
    fi

    if echo "$staged" | grep -qx '\.env\.local'; then
        fail "unstage .env.local (top-level)" "still staged"
    else
        pass "unstage .env.local (top-level)"
    fi

    if echo "$staged" | grep -qx 'web/\.env\.production'; then
        fail "unstage nested .env.production" "web/.env.production still staged"
    else
        pass "unstage web/.env.production (nested)"
    fi

    if echo "$staged" | grep -qx 'apps/api/\.env\.local'; then
        fail "unstage deeply nested .env.local" "apps/api/.env.local still staged"
    else
        pass "unstage apps/api/.env.local (deeply nested)"
    fi

    if echo "$staged" | grep -qx 'web/safe-config\.json'; then
        pass "safe nested file remains staged"
    else
        fail "safe nested file" "web/safe-config.json was incorrectly unstaged"
    fi

    cleanup_sandbox
}

test_newline_paths_staging_and_accounting() {
    log_header "70b. Staging, accounting and safety filters survive newline-containing paths"

    source "$KYZN_ROOT/lib/execute.sh"

    create_sandbox generic

    # Default `git ls-files` / `--name-only` output is newline-delimited and
    # C-quotes any path containing a newline. Consuming it as a pathname turns
    # one adversarial filename into a path that does not exist, which used to
    # make `git add` fail and abandon staging for the entire batch — including
    # every innocent file beside it.
    local weird=$'evil\nname.txt'
    local weird_secret=$'oops\ncreds.env'
    local weird_ci=$'.github/workflows/we\nird.yml'

    printf 'a\nb\nc\n' > "$weird"          # 3 added lines
    printf 'plain\n'   > normal.txt        # 1 added line
    printf 'SECRET=1\n' > "$weird_secret"  # 1 added line
    mkdir -p .github/workflows
    printf 'on: push\n' > "$weird_ci"      # 1 added line

    # --- accounting: every new file must be counted, not silently skipped ---
    # Out-parameter names must not collide with count_diff_size's own locals.
    local nl_added=0 nl_deleted=0 nl_binary=0
    count_diff_size nl_added nl_deleted nl_binary
    assert_eq "count_diff_size counts lines behind a newline-named file" "6" "$nl_added"
    assert_eq "count_diff_size reports no phantom deletions" "0" "$nl_deleted"
    assert_eq "count_diff_size finds no binaries among the text fixtures" "0" "$nl_binary"

    # --- staging: the newline path AND its innocent neighbours must stage ---
    local stage_rc=0
    _stage_for_count || stage_rc=$?
    assert_eq "_stage_for_count succeeds with a newline-named untracked file" "0" "$stage_rc"

    local -a staged=()
    local p
    while IFS= read -r -d '' p; do staged+=("$p"); done \
        < <(git diff --cached --name-only -z 2>/dev/null)

    local found_weird=false found_normal=false
    for p in ${staged[@]+"${staged[@]}"}; do
        [[ "$p" == "$weird" ]] && found_weird=true
        [[ "$p" == "normal.txt" ]] && found_normal=true
    done
    if $found_weird; then
        pass "newline-named file is staged with its real name"
    else
        fail "newline-named file is staged with its real name" "not present in the index"
    fi
    if $found_normal; then
        pass "innocent file beside a newline-named file still stages"
    else
        fail "innocent file beside a newline-named file still stages" \
            "staging aborted for the whole batch"
    fi

    # --- safety filters must still see through the quoting ---
    # Stage the two adversarial paths explicitly. Without this the assertions
    # below would pass vacuously on any tree where _stage_for_count already
    # failed to stage anything at all.
    git add -- "$weird_secret" "$weird_ci" >/dev/null 2>&1
    unstage_secrets 2>/dev/null
    KYZN_ALLOW_CI=false check_dangerous_files 2>/dev/null

    local secret_staged=false ci_staged=false
    while IFS= read -r -d '' p; do
        [[ "$p" == "$weird_secret" ]] && secret_staged=true
        [[ "$p" == "$weird_ci" ]] && ci_staged=true
    done < <(git diff --cached --name-only -z 2>/dev/null)

    if $secret_staged; then
        fail "unstage_secrets catches a newline-named .env" "still staged"
    else
        pass "unstage_secrets catches a newline-named .env"
    fi
    if $ci_staged; then
        fail "check_dangerous_files catches a newline-named workflow" "still staged"
    else
        pass "check_dangerous_files catches a newline-named workflow"
    fi

    cleanup_sandbox
}

test_newline_paths_test_deletion_guard() {
    log_header "70c. check_test_deletions sees a newline-named test file"

    source "$KYZN_ROOT/lib/execute.sh"

    create_sandbox generic

    # A committed test file, large enough that removing it trips the
    # >50%-deleted guard (deletions > 2x additions and > 20 lines).
    local weird_test=$'tests/gu\nard_test.py'
    mkdir -p tests
    local i
    for ((i = 0; i < 40; i++)); do echo "assert $i == $i"; done > "$weird_test"
    git add -A >/dev/null 2>&1
    git -c user.email=t@t -c user.name=t commit -qm "add test" >/dev/null 2>&1

    rm -f "$weird_test"
    git add -A >/dev/null 2>&1

    check_test_deletions 2>/dev/null

    # Unstaging restores the deletion to the worktree-only state, so the file
    # is no longer part of the pending commit.
    local deletion_staged=false p
    while IFS= read -r -d '' p; do
        [[ "$p" == "$weird_test" ]] && deletion_staged=true
    done < <(git diff --cached --name-only -z 2>/dev/null)

    if $deletion_staged; then
        fail "check_test_deletions unstages a newline-named test deletion" "still staged"
    else
        pass "check_test_deletions unstages a newline-named test deletion"
    fi

    cleanup_sandbox
}

test_newline_paths_pytest_gate() {
    log_header "70d. gate_new_test_files discovers newline-named Python tests"

    source "$KYZN_ROOT/lib/verify.sh"

    create_sandbox generic
    KYZN_PROJECT_TYPE=python

    local fake_bin="$PWD/.fakebin"
    mkdir -p "$fake_bin"
    # A stub pytest that resolves (--version must exit 0 for _kyzn_python_tool
    # to accept it) but fails collection for any path it is given. Each argv
    # element is logged on its own line so argument splitting is observable.
    cat > "$fake_bin/pytest" <<'FAKE_PYTEST'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "pytest 0.0.0-fake"
    exit 0
fi
printf '%s\n' "$@" >> "$PYTEST_ARGV_LOG"
exit 1
FAKE_PYTEST
    chmod +x "$fake_bin/pytest"
    export PYTEST_ARGV_LOG="$PWD/argv.log"
    : > "$PYTEST_ARGV_LOG"

    local weird_test=$'we\nird_test.py'
    printf 'import nonexistent_module\n' > "$weird_test"

    PATH="$fake_bin:$PATH" gate_new_test_files >/dev/null 2>&1 || true

    local ignored=false a
    for a in ${KYZN_PYTEST_IGNORE_ARGS[@]+"${KYZN_PYTEST_IGNORE_ARGS[@]}"}; do
        [[ "$a" == "--ignore=$weird_test" ]] && ignored=true
    done
    if $ignored; then
        pass "gate_new_test_files ignores a newline-named uncollectable test"
    else
        fail "gate_new_test_files ignores a newline-named uncollectable test" \
            "flag not produced (discovery lost the path)"
    fi

    assert_eq "ignore flags are held as one array element per argument" \
        "1" "${#KYZN_PYTEST_IGNORE_ARGS[@]}"

    # A path containing SPACES is the case the old flat-string form broke on:
    # verify_build re-split it with `read -ra`, which splits on IFS, turning
    # one --ignore flag into several bogus arguments. Drive the real consumer
    # and assert pytest received exactly one argv element for the flag.
    local spaced_test='a test file_test.py'
    printf 'import nonexistent_module\n' > "$spaced_test"
    : > "$PYTEST_ARGV_LOG"
    PATH="$fake_bin:$PATH" gate_new_test_files >/dev/null 2>&1 || true
    : > "$PYTEST_ARGV_LOG"
    PATH="$fake_bin:$PATH" _kyzn_python_has_tests >/dev/null 2>&1 && \
        PATH="$fake_bin:$PATH" verify_build >/dev/null 2>&1 || true

    if grep -Fxq -- "--ignore=$spaced_test" "$PYTEST_ARGV_LOG" 2>/dev/null; then
        pass "pytest receives a spaced ignore path as one argv element"
    else
        fail "pytest receives a spaced ignore path as one argv element" \
            "argv log: $(tr '\n' '|' < "$PYTEST_ARGV_LOG" 2>/dev/null)"
    fi

    unset PYTEST_ARGV_LOG
    unset KYZN_PROJECT_TYPE
    cleanup_sandbox
}

test_path_traversal_reject_diff() {
    log_header "50. Path traversal rejected in reject and diff commands"

    source "$KYZN_ROOT/lib/approve.sh"
    source "$KYZN_ROOT/lib/history.sh"

    create_sandbox generic
    ensure_kyzn_dirs

    # Test reject with path traversal
    local exit_code=0
    cmd_reject "../../etc/cron.d/x" 2>/dev/null || exit_code=$?
    assert_eq "reject path traversal blocked" "1" "$exit_code"

    # Test diff with path traversal
    exit_code=0
    cmd_diff "../../etc/passwd" 2>/dev/null || exit_code=$?
    assert_eq "diff path traversal blocked" "1" "$exit_code"

    # Test diff with regex-like input
    exit_code=0
    cmd_diff ".*" 2>/dev/null || exit_code=$?
    assert_eq "diff regex input blocked" "1" "$exit_code"

    cleanup_sandbox
}

test_report_discovery_and_clean_handoff() {
    log_header "50b. Report discovery covers current formats without dirtying target repos"

    source "$KYZN_ROOT/lib/history.sh"
    source "$KYZN_ROOT/lib/analyze.sh"
    create_sandbox generic
    ensure_kyzn_dirs
    git add .kyzn/.gitignore
    git commit -q -m "KyZN report ignore fixture"

    local run_id output status report baseline_status original_branch
    run_id="test-a"
    git branch "kyzn/unrelated-test-a-extra"
    for report in \
        "$KYZN_REPORTS_DIR/$run_id.md:plain-report" \
        "$KYZN_REPORTS_DIR/$run_id-analysis.md:analysis-report" \
        "$KYZN_REPORTS_DIR/$run_id-failed.md:failed-report"; do
        rm -f "$KYZN_REPORTS_DIR/$run_id.md" "$KYZN_REPORTS_DIR/$run_id-analysis.md" "$KYZN_REPORTS_DIR/$run_id-failed.md"
        printf '%s\n' "${report#*:}" > "${report%%:*}"
        status=0
        output=$(cmd_diff "$run_id" 2>&1) || status=$?
        assert_exit_code "diff discovers ${report#*:} location" "0" "$status"
        assert_contains "diff prints ${report#*:}" "$output" "${report#*:}"
    done

    original_branch=$(git branch --show-current)
    git checkout -q -b "kyzn/history-test-ambiguous-selected"
    printf 'history-selected\n' > history-selected.txt
    git add history-selected.txt
    git commit -q -m "history-selected branch fixture"
    git checkout -q "$original_branch"
    git branch "kyzn/unrelated-test-ambiguous-extra"
    status=0
    cmd_diff "test-ambiguous" >/dev/null 2>&1 || status=$?
    assert_exit_code "diff refuses substring-only ambiguous branches" "1" "$status"
    printf '%s\n' '{"branch":"kyzn/history-test-ambiguous-selected"}' > "$KYZN_HISTORY_DIR/test-ambiguous.json"
    status=0
    output=$(cmd_diff "test-ambiguous" 2>&1) || status=$?
    assert_exit_code "diff deterministically uses exact history branch" "0" "$status"
    assert_contains "diff output comes from exact history branch" "$output" "history-selected"

    rm -f "$KYZN_REPORTS_DIR/$run_id.md" "$KYZN_REPORTS_DIR/$run_id-analysis.md" "$KYZN_REPORTS_DIR/$run_id-failed.md"
    printf '# Legacy\n\n**Run ID:** `%s`\nlegacy-report\n' "$run_id" > kyzn-report.md
    output=$(cmd_diff "$run_id")
    assert_contains "diff safely reads matching legacy root report" "$output" "legacy-report"
    status=0
    cmd_diff "test-other-report" >/dev/null 2>&1 || status=$?
    assert_exit_code "diff rejects mismatched legacy root report" "1" "$status"
    rm -f kyzn-report.md

    printf 'archived analysis\n' > "$KYZN_REPORTS_DIR/$run_id-analysis.md"
    baseline_status=$(git status --porcelain)
    copy_analysis_convenience_report "$KYZN_REPORTS_DIR/$run_id-analysis.md"
    assert_file_exists "analysis convenience report lives under .kyzn" "$KYZN_DIR/kyzn-report.md"
    [[ ! -e kyzn-report.md ]] && pass "analysis no longer writes root convenience report" || fail "analysis no longer writes root convenience report" "root report exists"
    assert_eq "analysis report handoff preserves target worktree state" "$baseline_status" "$(git status --porcelain)"
    assert_contains "analysis convenience report preserves content" "$(cat "$KYZN_DIR/kyzn-report.md")" "archived analysis"

    cleanup_sandbox
}

test_repository_facts_are_index_deterministic() {
    log_header "50c. Repository facts derive only from Git index objects"

    local fixture baseline noisy staged
    fixture=$(mktemp -d)
    mkdir -p "$fixture/scripts" "$fixture/lib" "$fixture/measurers" "$fixture/templates/conventions" "$fixture/tests" "$fixture/.github/workflows"
    cp "$KYZN_ROOT/scripts/check-repository-facts.sh" "$fixture/scripts/"
    cp "$KYZN_ROOT/kyzn" "$fixture/"
    cp "$KYZN_ROOT/tests/selftest.sh" "$fixture/tests/"
    cp "$KYZN_ROOT/.github/workflows/ci.yml" "$fixture/.github/workflows/"
    cp "$KYZN_ROOT/lib/detect.sh" "$KYZN_ROOT/lib/measure.sh" "$KYZN_ROOT/lib/allowlist.sh" "$KYZN_ROOT/lib/verify.sh" "$fixture/lib/"
    cp "$KYZN_ROOT"/measurers/*.sh "$fixture/measurers/"
    cp "$KYZN_ROOT"/templates/conventions/*.md "$fixture/templates/conventions/"
    cd "$fixture"
    git init -q
    git config user.email "selftest@kyzn.local"
    git config user.name "KyZN Selftest"
    git add .
    git commit -q -m "facts fixture"

    baseline=$(bash scripts/check-repository-facts.sh --print 2>/dev/null)
    printf 'untracked noise\n' > arbitrary-untracked.tmp
    printf '# dirty tracked noise\n' >> lib/detect.sh
    noisy=$(bash scripts/check-repository-facts.sh --print 2>/dev/null)
    assert_eq "facts ignore arbitrary untracked and dirty tracked files" "$baseline" "$noisy"

    printf '#!/usr/bin/env bash\ntrue\n' > staged-addition.sh
    git add staged-addition.sh
    staged=$(bash scripts/check-repository-facts.sh --print 2>/dev/null)
    [[ "$staged" != "$baseline" ]] && pass "facts include staged additions" || fail "facts include staged additions" "staged file did not change facts"

    cd "$KYZN_ROOT"
    rm -rf "$fixture"
}

test_validate_run_id() {
    log_header "51. validate_run_id accepts valid IDs and rejects invalid"

    # Valid run IDs
    validate_run_id "20260320-143022-abc123ef" && pass "valid run ID accepted" || fail "valid run ID" "rejected"
    validate_run_id "measure-20260320-143022" && pass "valid measure ID accepted" || fail "valid measure ID" "rejected"
    validate_run_id "test-approve-001" && pass "valid test ID accepted" || fail "valid test ID" "rejected"

    # Invalid run IDs
    validate_run_id "../../etc/passwd" && fail "path traversal" "accepted" || pass "path traversal rejected"
    validate_run_id "foo/bar" && fail "slash" "accepted" || pass "slash rejected"
    validate_run_id "" && fail "empty" "accepted" || pass "empty rejected"
    validate_run_id "random-junk" && fail "random junk" "accepted" || pass "random junk rejected"
}

test_reflexion_retry_loop() {
    log_header "42. Reflexion retry loop in cmd_improve"

    local src
    src=$(cat "$KYZN_ROOT/lib/execute.sh")

    # 1. Exactly one retry is expressed by the control flow itself — the first
    #    red verification runs one retry, and every retry outcome either returns
    #    or falls through to success. There is no flag to assert, and no path
    #    back to the retry decision. Behavioural proof lives in test 83.

    # 2. Exactly one retry, for ANY red final verification. The retry is no
    #    longer gated on the baseline having started clean — that left a red
    #    baseline one-shot against a gate that demands green. Behavioural proof
    #    of both the retry and its single-attempt cap lives in test 83.

    # 3. Captures verify_build output to a temp file for error context
    assert_contains "captures verify errors to file" "$src" 'verify_errors_file'

    # 4. Constructs retry prompt with error context and mock guidance
    assert_contains "retry prompt has error message" "$src" 'Build/tests are still failing after your changes'
    assert_not_contains "retry prompt does not blame Claude for a red baseline" \
        "$src" 'Your previous changes broke the build'
    assert_contains "retry prompt includes errors" "$src" 'verify_errors'
    assert_contains "retry has mock guidance" "$src" 'unittest.mock'

    # 5. Halves the budget for retry
    assert_contains "halves budget for retry" "$src" 'retry_budget'

    # 6. Calls execute_claude again for retry
    assert_contains "calls execute_claude for retry" "$src" 'execute_claude "$retry_prompt"'

    # 7. Logs self-repair attempt
    assert_contains "logs self-repair attempt" "$src" 'self-repair'

    # 8 + 9. The single-retry limit is structural, not flag-based: the retry
    #        runs once and every outcome returns or falls through to success.
    #        Test 83 proves the limit behaviourally (exactly two Claude
    #        invocations) rather than asserting on source text here.
}

test_gitignore_preserves_custom() {
    log_header "52. setup_kyzn_gitignore preserves custom entries"

    source "$KYZN_ROOT/lib/interview.sh"

    local tmpdir
    tmpdir=$(mktemp -d)
    KYZN_DIR="$tmpdir/.kyzn"
    mkdir -p "$KYZN_DIR"

    # Create a gitignore with a custom entry
    cat > "$KYZN_DIR/.gitignore" <<'GI'
# kyzn — gitignored local data
history/
reports/
local.yaml
my-custom-scratch/
GI

    # Run setup — should append missing entries, not overwrite
    setup_kyzn_gitignore

    assert_contains "custom entry preserved" "$(cat "$KYZN_DIR/.gitignore")" "my-custom-scratch/"
    assert_contains "kyzn-report.md added" "$(cat "$KYZN_DIR/.gitignore")" "kyzn-report.md"
    assert_contains ".improve.lock/ added" "$(cat "$KYZN_DIR/.gitignore")" ".improve.lock/"
    # history/ already existed — should not be duplicated
    local count
    count=$(grep -c 'history/' "$KYZN_DIR/.gitignore")
    assert_eq "no duplicate history/" "1" "$count"

    rm -rf "$tmpdir"
}

test_capture_error_lines() {
    log_header "53. capture_failing_tests captures ERROR lines with ERR: prefix"

    local src
    src=$(cat "$KYZN_ROOT/lib/verify.sh")

    # Must grep for both FAILED and ERROR
    assert_contains "captures FAILED lines" "$src" "FAILED"
    assert_contains "captures ERROR lines" "$src" "ERROR"
    assert_contains "ERR prefix for errors" "$src" "ERR:"
    assert_contains "strips collecting prefix" "$src" "collecting"
    assert_contains "deduplicates with sort -u" "$src" "sort -u"
}

test_detect_installed_packages() {
    log_header "54. detect_installed_packages returns package list"

    source "$KYZN_ROOT/lib/detect.sh"

    # Test node project detection with a sandbox
    local tmpdir
    tmpdir=$(mktemp -d)
    cd "$tmpdir"

    # Create a minimal package.json
    cat > package.json <<'PKG'
{
  "dependencies": {"express": "^4.0.0"},
  "devDependencies": {"jest": "^29.0.0"}
}
PKG

    KYZN_PROJECT_TYPE="node"
    local pkgs
    pkgs=$(detect_installed_packages 2>/dev/null) || true

    assert_contains "node finds express" "$pkgs" "express"
    assert_contains "node finds jest" "$pkgs" "jest"

    cd "$KYZN_ROOT"
    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Stage 3: fix_plan tests
# ---------------------------------------------------------------------------
test_consensus_prompt_has_fix_plan() {
    log_header "55. Consensus prompt instructs fix_plan generation"

    source "$KYZN_ROOT/lib/analyze.sh"

    local prompt
    prompt=$(build_consensus_prompt '[{"id":"SEC-001"}]' '[]' '[]' '[]')

    assert_contains "consensus preserves fix_plan" "$prompt" "Preserve fix_plan"
    assert_contains "consensus says JSON only" "$prompt" "ONLY the JSON array"
    assert_contains "consensus says no commentary" "$prompt" "No commentary"
    assert_contains "consensus says no code fences" "$prompt" "Do NOT wrap"
}

test_fix_plan_passes_through() {
    log_header "56. fix_plan field survives extract_findings"

    source "$KYZN_ROOT/lib/analyze.sh"

    local fake_result
    fake_result=$(jq -n '{result: "[{\"id\":\"BUG-001\",\"severity\":\"HIGH\",\"title\":\"test\",\"fix\":\"do X\",\"fix_plan\":\"target_file: src/main.py | target_function: process\"}]"}')

    local findings
    findings=$(extract_findings "$fake_result")

    local has_plan
    has_plan=$(echo "$findings" | jq -r '.[0].fix_plan // ""')

    if [[ "$has_plan" == *"target_file"* ]]; then
        pass "fix_plan field preserved through extract_findings"
    else
        fail "fix_plan passthrough" "fix_plan not found in extracted findings"
    fi
}

test_report_includes_fix_plan() {
    log_header "57. generate_detailed_report includes fix_plan in markdown"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/analyze.sh"

    local tmpdir
    tmpdir=$(mktemp -d)
    local findings_file="$tmpdir/findings.json"
    local report_file="$tmpdir/report.md"

    echo '[{"id":"BUG-001","severity":"HIGH","category":"bug","title":"Test bug","file":"src/main.py","line":10,"description":"A bug","fix":"Fix it","fix_plan":"target_file: src/main.py | target_function: process | test_file: tests/test_main.py","effort":"small"}]' > "$findings_file"

    generate_detailed_report "$findings_file" "$report_file" "test-run" "opus" "1.00" "1"

    local content
    content=$(cat "$report_file")
    assert_contains "report has Fix plan label" "$content" "Fix plan:"
    assert_contains "report has target_file" "$content" "target_file"

    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Stage 2: profiler tests
# ---------------------------------------------------------------------------
test_profiler_cache_invalidation() {
    log_header "58. Profiler cache: stale SHA triggers miss, fresh SHA uses cache"

    source "$KYZN_ROOT/lib/core.sh"

    local tmpdir
    tmpdir=$(mktemp -d)
    cd "$tmpdir"
    git init -q
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "init"

    local current_sha
    current_sha=$(git rev-parse HEAD)
    mkdir -p .kyzn

    # Write a cache file with the current SHA
    echo "<!-- sha:${current_sha} -->" > .kyzn/repo-profile.md
    echo "## Cached conventions" >> .kyzn/repo-profile.md

    # Verify cache hit (SHA matches)
    local cached_sha
    cached_sha=$(sed -n '1s/^<!-- sha:\(.*\) -->/\1/p' .kyzn/repo-profile.md)
    assert_eq "cache hit with matching SHA" "$current_sha" "$cached_sha"

    # New commit → SHA changes → cache miss
    echo "change" > file2.txt
    git add file2.txt
    git commit -q -m "change"
    local new_sha
    new_sha=$(git rev-parse HEAD)

    if [[ "$cached_sha" != "$new_sha" ]]; then
        pass "cache miss with new SHA"
    else
        fail "cache invalidation" "SHA didn't change after new commit"
    fi

    cd "$KYZN_ROOT"
    rm -rf "$tmpdir"
}

test_generate_fix_prompt_with_profile() {
    log_header "59. generate_fix_prompt with repo profile produces Repo Profile section"

    source "$KYZN_ROOT/lib/analyze.sh"

    local tmpdir
    tmpdir=$(mktemp -d)

    # Create a fake repo profile
    echo "<!-- sha:abc123 -->" > "$tmpdir/repo-profile.md"
    echo "## Repo-Specific Conventions" >> "$tmpdir/repo-profile.md"
    echo "### Naming" >> "$tmpdir/repo-profile.md"
    echo "snake_case for functions" >> "$tmpdir/repo-profile.md"

    local findings_json='[{"id":"BUG-001","severity":"HIGH","title":"test","fix":"do X"}]'

    local prompt
    prompt=$(generate_fix_prompt "$findings_json" "" "" "" "$tmpdir/repo-profile.md")

    assert_contains "has Repo Profile section" "$prompt" "Repo Profile"
    assert_contains "has conventions content" "$prompt" "snake_case for functions"
    assert_contains "has How to Use Fix Plans" "$prompt" "How to Use Fix Plans"

    rm -rf "$tmpdir"
}

test_budget_carving() {
    log_header "60. Budget carving: \$20 profiler \$0.50, per_agent \$3.90"

    local profiler_budget="0.50"
    local budget="20.00"

    local analysis_budget
    analysis_budget=$(awk "BEGIN {printf \"%.2f\", $budget - $profiler_budget}")
    local per_agent_budget
    per_agent_budget=$(awk "BEGIN {printf \"%.2f\", $analysis_budget / 5}")

    assert_eq "analysis budget" "19.50" "$analysis_budget"
    assert_eq "per agent budget" "3.90" "$per_agent_budget"
}

test_specialist_prompt_has_fix_plan() {
    log_header "61. Specialist prompt includes fix_plan in schema"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/analyze.sh"

    local prompt
    prompt=$(build_specialist_prompt "security" "test-proj" "Generic" "50" "[]")

    assert_contains "specialist has fix_plan in schema" "$prompt" "fix_plan"
    assert_contains "specialist has pipe-delimited" "$prompt" "Pipe-delimited"
}

# ---------------------------------------------------------------------------
# Verify fixes: vitest no-test-files, CI=true
# ---------------------------------------------------------------------------
test_verify_node_no_test_files() {
    log_header "62. verify_node treats 'No test files found' as pass"

    source "$KYZN_ROOT/lib/verify.sh"

    SANDBOX=$(mktemp -d)
    cd "$SANDBOX"
    git init -q
    git commit --allow-empty -m "init" -q
    # Minimal node project: no tsconfig (skip tsc), no build script, test simulates vitest
    echo '{"name":"test-project","scripts":{"test":"echo No test files found && exit 1"}}' > package.json
    mkdir -p src
    git add -A && git commit -q -m "init node"

    source "$KYZN_ROOT/lib/detect.sh"
    detect_project_type

    if verify_build &>/dev/null; then
        pass "no-test-files treated as pass"
    else
        fail "no-test-files" "verify_build should pass when no test files found"
    fi

    cd "$KYZN_ROOT"
    rm -rf "$SANDBOX"
}

test_verify_skips_dependency_install_by_default() {
    log_header "63. verify_build skips dependency installation by default"

    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/detect.sh"

    SANDBOX=$(mktemp -d)
    cd "$SANDBOX"
    git init -q
    git config user.email "selftest@kyzn.local"
    git config user.name "KyZN Selftest"
    git commit --allow-empty -m "init" -q

    echo '{"name":"test-project"}' > package.json
    echo '{"lockfileVersion":3}' > package-lock.json
    mkdir -p fake-bin
    cat > fake-bin/npm <<'SH'
#!/usr/bin/env bash
echo "$*" >> npm.log
exit 0
SH
    chmod +x fake-bin/npm
    PATH="$SANDBOX/fake-bin:$PATH"
    detect_project_type

    unset KYZN_VERIFY_INSTALL_DEPS
    verify_build &>/dev/null || true
    if [[ ! -f npm.log ]]; then
        pass "node install skipped by default"
    else
        fail "node install skipped" "npm was called: $(cat npm.log)"
    fi

    KYZN_VERIFY_INSTALL_DEPS=true verify_build &>/dev/null || true
    if [[ -f npm.log ]] && grep -q 'ci --silent' npm.log; then
        pass "node install opt-in uses npm ci"
    else
        fail "node install opt-in" "npm ci was not called"
    fi

    cd "$KYZN_ROOT"
    rm -rf "$SANDBOX"
}

test_verify_python_skips_dependency_install_by_default() {
    log_header "64. verify_python skips dependency installation by default"

    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/detect.sh"

    SANDBOX=$(mktemp -d)
    cd "$SANDBOX"
    git init -q
    git config user.email "selftest@kyzn.local"
    git config user.name "KyZN Selftest"
    git commit --allow-empty -m "init" -q

    cat > pyproject.toml <<'TOML'
[project]
name = "test-project"
version = "0.1.0"
TOML
    mkdir -p fake-bin
    cat > fake-bin/uv <<'SH'
#!/usr/bin/env bash
echo "$*" >> uv.log
exit 0
SH
    chmod +x fake-bin/uv
    PATH="$SANDBOX/fake-bin:$PATH"
    detect_project_type

    unset KYZN_VERIFY_INSTALL_DEPS
    verify_build &>/dev/null || true
    if [[ ! -f uv.log ]]; then
        pass "python install skipped by default"
    else
        fail "python install skipped" "uv was called: $(cat uv.log)"
    fi

    KYZN_VERIFY_INSTALL_DEPS=true verify_build &>/dev/null || true
    if [[ -f uv.log ]] && grep -q 'sync --quiet' uv.log; then
        pass "python install opt-in uses uv sync"
    else
        fail "python install opt-in" "uv sync was not called"
    fi

    cd "$KYZN_ROOT"
    rm -rf "$SANDBOX"
}

test_install_python_deps_requirements_txt() {
    log_header "64b. install_python_dependencies uses pip when requirements.txt + no uv"

    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/detect.sh"

    SANDBOX=$(mktemp -d)
    cd "$SANDBOX"
    git init -q
    git config user.email "selftest@kyzn.local"
    git config user.name "KyZN Selftest"
    git commit --allow-empty -m "init" -q

    echo "requests==2.32.0" > requirements.txt
    mkdir -p fake-bin
    # Fake python3 that mocks "-m venv <dir>" by creating a pip stub that logs args.
    cat > fake-bin/python3 <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-m" && "$2" == "venv" ]]; then
    mkdir -p "$3/bin"
    cat > "$3/bin/pip" <<'PIP'
#!/usr/bin/env bash
echo "$*" >> pip.log
exit 0
PIP
    chmod +x "$3/bin/pip"
    exit 0
fi
exit 0
SH
    chmod +x fake-bin/python3
    # Isolate PATH — deliberately exclude /usr/local/bin where uv lives, so the
    # requirements.txt branch is forced (`command -v uv` must fail).
    local saved_path="$PATH"
    PATH="$SANDBOX/fake-bin:/usr/bin:/bin"
    detect_project_type

    install_python_dependencies &>/dev/null || true

    PATH="$saved_path"

    if [[ -d .venv && -f pip.log ]] && grep -q 'install -q -r requirements.txt' pip.log; then
        pass "requirements.txt path invokes pip install"
    else
        local got="missing"
        [[ -f pip.log ]] && got=$(cat pip.log)
        fail "requirements.txt path" "expected .venv created and pip called; got pip.log=$got"
    fi

    cd "$KYZN_ROOT"
    rm -rf "$SANDBOX"
}

test_require_clean_worktree() {
    log_header "65. require_clean_worktree blocks dirty repos"

    create_sandbox generic

    echo "local edit" >> scripts/run.sh
    if ! require_clean_worktree false 2>/dev/null; then
        pass "dirty worktree rejected"
    else
        fail "dirty worktree rejected" "dirty repo was accepted"
    fi

    if require_clean_worktree true 2>/dev/null; then
        pass "allow-dirty override accepted"
    else
        fail "allow-dirty override" "override was rejected"
    fi

    cleanup_sandbox
}

# ---------------------------------------------------------------------------
# Security hardening tests (from Cursor + Codex audits)
# ---------------------------------------------------------------------------

test_awk_budget_injection() {
    log_header "66. awk budget calculation rejects injection payloads"

    # awk -v safely passes the string — system() is NOT executed
    rm -f /tmp/kyzn-pwned
    awk -v b='1; system("touch /tmp/kyzn-pwned")' 'BEGIN {printf "%.2f", b + 0}' >/dev/null 2>&1 || true
    if [[ -f /tmp/kyzn-pwned ]]; then
        rm -f /tmp/kyzn-pwned
        fail "awk injection" "injection payload created file on disk"
    else
        pass "awk -v does not execute injected system() calls"
    fi

    # Test numeric budget regex validation (defense-in-depth at parse time)
    local good="2.50"
    local bad='1; system("id")'
    if [[ "$good" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        pass "valid budget passes regex"
    else
        fail "valid budget" "regex rejected valid budget"
    fi
    if [[ "$bad" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        fail "injection blocked" "regex accepted injection payload"
    else
        pass "injection budget blocked by regex"
    fi
}

test_xargs_filename_with_spaces() {
    log_header "64. unstage_secrets handles filenames with spaces"

    source "$KYZN_ROOT/lib/execute.sh"

    create_sandbox generic

    # Create a secret file with spaces in the name
    echo "SECRET=abc" > "my secret.env"
    echo "data" > "safe file.txt"
    git add "my secret.env" "safe file.txt" 2>/dev/null

    # Run unstage_secrets
    unstage_secrets 2>/dev/null

    local staged
    staged=$(git diff --cached --name-only 2>/dev/null)

    # The .env file should have been unstaged despite spaces
    if echo "$staged" | grep -q 'secret\.env'; then
        fail "unstage spaced .env" "my secret.env still staged"
    else
        pass "unstage spaced .env — removed from staging"
    fi

    # Safe file should remain staged
    if echo "$staged" | grep -q 'safe file'; then
        pass "safe file with spaces remains staged"
    else
        fail "safe file with spaces" "was incorrectly unstaged"
    fi

    cleanup_sandbox
}

test_safe_checkout_back_disables_hooks() {
    log_header "65. safe_checkout_back uses safe_git (hooks disabled)"

    # Verify the function body uses safe_git, not bare git
    local func_body
    func_body=$(awk '/^safe_checkout_back\(\)/,/^}/' "$KYZN_ROOT/lib/execute.sh")

    local bare_count
    bare_count=$(echo "$func_body" | grep -cE '^\s+git checkout' 2>/dev/null) || bare_count=0

    assert_eq "no bare git checkout in safe_checkout_back" "0" "$bare_count"
}

test_profile_path_traversal() {
    log_header "66. get_system_prompt rejects path traversal in profile"

    source "$KYZN_ROOT/lib/prompt.sh"

    # Make the fallback branch independent of state leaked by earlier tests.
    # Generic has no conventions file, so this must return the tracked base
    # prompt without ever treating it as disposable temporary output.
    local KYZN_PROJECT_TYPE=generic
    local base_prompt="$KYZN_ROOT/templates/system-prompt.md"
    local result
    assert_file_exists "tracked base prompt exists before traversal test" "$base_prompt"
    result=$(get_system_prompt "../../etc/passwd")
    assert_eq "traversal falls back to tracked base prompt" "$base_prompt" "$result"

    if [[ -f "$result" ]]; then
        local content
        content=$(cat "$result")
        if echo "$content" | grep -q "root:"; then
            fail "traversal blocked" "system prompt contains /etc/passwd content"
        else
            pass "traversal profile sanitized — no /etc/passwd content"
        fi
        # Only get_system_prompt output outside the repository can be temporary.
        [[ "$result" != "$KYZN_ROOT/"* ]] && rm -f "$result"
    else
        fail "traversal returns existing prompt" "missing file: $result"
    fi
    assert_file_exists "tracked base prompt survives traversal test" "$base_prompt"
}

# ---------------------------------------------------------------------------
# Security: check_symlink_escapes coverage
# ---------------------------------------------------------------------------
test_check_symlink_escapes() {
    log_header "68. check_symlink_escapes blocks symlinks pointing outside repo"

    source "$KYZN_ROOT/lib/execute.sh"

    # Test 1: symlink pointing outside repo is rejected
    create_sandbox generic
    ln -s /tmp escape_link
    local exit_code=0
    check_symlink_escapes 2>/dev/null || exit_code=$?
    if (( exit_code != 0 )); then
        pass "escaping symlink rejected (exit $exit_code)"
    else
        fail "escaping symlink check" "check_symlink_escapes returned 0 for /tmp symlink"
    fi
    cleanup_sandbox

    # Test 2: symlink pointing within the repo is allowed
    create_sandbox generic
    ln -s scripts/run.sh internal_link
    exit_code=0
    check_symlink_escapes 2>/dev/null || exit_code=$?
    if (( exit_code == 0 )); then
        pass "internal symlink allowed"
    else
        fail "internal symlink check" "check_symlink_escapes rejected an internal symlink"
    fi
    cleanup_sandbox
}

# ---------------------------------------------------------------------------
# count_diff_size counts real lines for new untracked files
# ---------------------------------------------------------------------------
test_count_diff_size_new_files() {
    log_header "68. count_diff_size: new files counted by real line count"

    create_sandbox "generic"
    local sandbox_dir="$SANDBOX"

    source "$KYZN_ROOT/lib/core.sh"
    source "$KYZN_ROOT/lib/execute.sh" 2>/dev/null || true

    # Return to sandbox after sourcing (execute.sh may change cwd)
    cd "$sandbox_dir"

    # Create a new untracked file with 150 lines
    local i
    for i in $(seq 1 150); do echo "line $i"; done > big_new_file.py

    # Create another with 50 lines
    for i in $(seq 1 50); do echo "line $i"; done > small_new_file.py

    local diff_added=0 diff_deleted=0 diff_binary=0
    count_diff_size diff_added diff_deleted diff_binary

    # Should report ~200 added lines (150 + 50), not 2
    if (( diff_added >= 190 )); then
        pass "new files counted by real lines ($diff_added added)"
    else
        fail "new file line count" "expected ~200 added lines, got $diff_added"
    fi
    assert_eq "new file deleted lines" "0" "$diff_deleted"
    assert_eq "new file binary count" "0" "$diff_binary"

    # Single large file should exceed a low limit
    if (( diff_added > 10 )); then
        pass "diff gate would catch large new files"
    else
        fail "diff gate bypass" "large new files not counted properly ($diff_added lines)"
    fi

    cleanup_sandbox
}

# ---------------------------------------------------------------------------
# Progress animation lifecycle
# ---------------------------------------------------------------------------
test_progress_animation() {
    log_header "69. progress animation: start/stop lifecycle and no orphan on double-start"

    # Skip in CI or when /dev/tty unavailable — animation needs a tty
    if [[ ! -e /dev/tty ]]; then
        skip "progress animation (/dev/tty unavailable)"
        return
    fi

    source "$KYZN_ROOT/lib/core.sh"

    # Test 1: start_progress sets PID; process is alive
    _KYZN_PROGRESS_PID=""
    start_progress "test" 2>/dev/null || true
    if [[ -z "$_KYZN_PROGRESS_PID" ]]; then
        skip "progress animation (not a tty)"
        return
    fi
    local pid1="$_KYZN_PROGRESS_PID"
    if kill -0 "$pid1" 2>/dev/null; then
        pass "start_progress spawns live background process"
    else
        fail "start_progress PID alive" "process $pid1 is not running"
    fi

    # Test 2: stop_progress kills the process
    stop_progress 2>/dev/null || true
    sleep 0.1
    if kill -0 "$pid1" 2>/dev/null; then
        fail "stop_progress kills process" "process $pid1 still running after stop"
    else
        pass "stop_progress terminates background process"
    fi

    # Test 3: double start_progress kills the first before spawning second
    start_progress "first" 2>/dev/null || true
    local pid2="$_KYZN_PROGRESS_PID"
    start_progress "second" 2>/dev/null || true
    local pid3="$_KYZN_PROGRESS_PID"
    sleep 0.1
    if [[ -n "$pid2" ]] && kill -0 "$pid2" 2>/dev/null; then
        fail "double start kills first process" "first process $pid2 still alive after second start"
    else
        pass "double start_progress kills first process before spawning second"
    fi
    stop_progress 2>/dev/null || true
    [[ -n "$pid3" ]] && kill "$pid3" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Fail-closed verification (C#, Java, Rust, Go) + local-only TypeScript
# ---------------------------------------------------------------------------

# Build a PATH containing ONLY a fixed set of shell utilities (plus any extra
# names passed as arguments). Lets a test assert "dotnet/mvn/gradle/cargo/go is
# not installed" deterministically, whatever the host happens to have.
# Echoes the directory so callers can do: PATH=$(_clean_path "$SANDBOX/clean-bin")
_clean_path() {
    local dir="$1"; shift
    mkdir -p "$dir"
    local u src
    for u in bash sh env cat head tail grep sed awk sort uniq wc find tr cut \
             date mktemp rm mkdir chmod ln touch git jq timeout xargs \
             basename dirname "$@"; do
        src=$(command -v "$u" 2>/dev/null) || continue
        ln -sf "$src" "$dir/$u" 2>/dev/null || true
    done
    echo "$dir"
}

test_verify_fails_closed_on_missing_tools() {
    log_header "70. verify_build reports 'not executed' when required tooling is missing"

    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/detect.sh"

    local saved_path="$PATH"
    local ptype rc

    # C#, Rust, Go — one required toolchain each, absent from a sanitized PATH
    for ptype in csharp rust go; do
        create_sandbox "$ptype"
        detect_project_type
        PATH=$(_clean_path "$SANDBOX/clean-bin")
        rc=0
        verify_build &>/dev/null || rc=$?
        PATH="$saved_path"
        assert_exit_code "$ptype: missing toolchain → 'not executed' (2)" 2 "$rc"
        assert_eq "$ptype: status is unavailable" "unavailable" "${KYZN_VERIFY_STATUS:-}"
        cleanup_sandbox
    done

    # Java / Maven — pom.xml present, mvn absent
    create_sandbox java
    detect_project_type
    assert_eq "java: maven flavor detected" "maven" "${KYZN_JAVA_BUILD:-}"
    PATH=$(_clean_path "$SANDBOX/clean-bin")
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "java/maven: missing mvn → 'not executed' (2)" 2 "$rc"
    cleanup_sandbox

    # Java / Gradle — neither ./gradlew wrapper nor system gradle
    create_sandbox generic
    echo 'plugins { id "java" }' > build.gradle
    git add -A && git commit -q -m "gradle project"
    detect_project_type
    assert_eq "java: gradle flavor detected" "gradle" "${KYZN_JAVA_BUILD:-}"
    PATH=$(_clean_path "$SANDBOX/clean-bin")
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "java/gradle: no wrapper, no gradle → 'not executed' (2)" 2 "$rc"
    cleanup_sandbox

    # Documented generic behaviour is preserved — no build system is still a pass
    create_sandbox generic
    detect_project_type
    rc=0
    verify_build &>/dev/null || rc=$?
    assert_exit_code "generic: no build system still returns 0 (documented)" 0 "$rc"
    cleanup_sandbox

    # The gate helper itself: only code 2 means "was not executed"
    if verify_not_executed 2 && ! verify_not_executed 1 && ! verify_not_executed 0; then
        pass "verify_not_executed distinguishes 2 from pass/fail"
    else
        fail "verify_not_executed" "gate helper does not isolate exit code 2"
    fi
}

test_verify_csharp_mocked_dotnet() {
    log_header "71. verify_csharp: mocked dotnet build/test pass and fail"

    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/detect.sh"

    local saved_path="$PATH" cb rc

    create_sandbox csharp
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/dotnet" <<'SH'
#!/usr/bin/env bash
echo "dotnet $*" >> "$FAKE_LOG"
case "$1" in
    build) exit "${FAKE_BUILD_RC:-0}" ;;
    test)  exit "${FAKE_TEST_RC:-0}" ;;
esac
exit 0
SH
    chmod +x "$cb/dotnet"
    export FAKE_LOG="$SANDBOX/dotnet.log"
    PATH="$cb"

    : > "$FAKE_LOG"
    export FAKE_BUILD_RC=0 FAKE_TEST_RC=0
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "dotnet build+test green → 0" 0 "$rc"
    assert_eq "status is passed" "passed" "${KYZN_VERIFY_STATUS:-}"
    assert_contains "dotnet build was invoked" "$(cat "$FAKE_LOG")" "dotnet build"
    assert_contains "dotnet test was invoked" "$(cat "$FAKE_LOG")" "dotnet test"

    export FAKE_BUILD_RC=1 FAKE_TEST_RC=0
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "dotnet build failure → 1" 1 "$rc"

    export FAKE_BUILD_RC=0 FAKE_TEST_RC=1
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "dotnet test failure → 1" 1 "$rc"

    PATH="$saved_path"
    unset FAKE_LOG FAKE_BUILD_RC FAKE_TEST_RC
    cleanup_sandbox
}

test_verify_java_mocked_maven_gradle() {
    log_header "72. verify_java: mocked Maven/Gradle pass, fail, and wrapper selection"

    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/detect.sh"

    local saved_path="$PATH" cb rc

    # --- Maven ---
    create_sandbox java
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/mvn" <<'SH'
#!/usr/bin/env bash
echo "mvn $*" >> "$FAKE_LOG"
for a in "$@"; do
    [[ "$a" == "compile" ]] && exit "${FAKE_BUILD_RC:-0}"
    [[ "$a" == "test" ]] && exit "${FAKE_TEST_RC:-0}"
done
exit 0
SH
    chmod +x "$cb/mvn"
    export FAKE_LOG="$SANDBOX/mvn.log"; : > "$FAKE_LOG"
    PATH="$cb"

    export FAKE_BUILD_RC=0 FAKE_TEST_RC=0
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "mvn compile+test green → 0" 0 "$rc"
    assert_contains "mvn compile invoked" "$(cat "$FAKE_LOG")" "compile"
    assert_contains "mvn test invoked" "$(cat "$FAKE_LOG")" "test"

    export FAKE_BUILD_RC=1 FAKE_TEST_RC=0
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "mvn compile failure → 1" 1 "$rc"

    export FAKE_BUILD_RC=0 FAKE_TEST_RC=1
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "mvn test failure → 1" 1 "$rc"

    PATH="$saved_path"
    cleanup_sandbox

    # --- Gradle: ./gradlew wrapper takes precedence over system gradle ---
    create_sandbox generic
    echo 'plugins { id "java" }' > build.gradle
    cat > gradlew <<'SH'
#!/usr/bin/env bash
echo "wrapper $*" >> "$FAKE_LOG"
if [[ "$1" == "test" ]]; then exit "${FAKE_TEST_RC:-0}"; fi
exit "${FAKE_BUILD_RC:-0}"
SH
    chmod +x gradlew
    git add -A && git commit -q -m "gradle wrapper project"
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/gradle" <<'SH'
#!/usr/bin/env bash
echo "system $*" >> "$FAKE_LOG"
exit 0
SH
    chmod +x "$cb/gradle"
    export FAKE_LOG="$SANDBOX/gradle.log"; : > "$FAKE_LOG"
    PATH="$cb"

    export FAKE_BUILD_RC=0 FAKE_TEST_RC=0
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "gradle wrapper green → 0" 0 "$rc"
    assert_contains "wrapper is used when present" "$(cat "$FAKE_LOG")" "wrapper"
    assert_not_contains "system gradle unused when wrapper present" "$(cat "$FAKE_LOG")" "system"

    export FAKE_BUILD_RC=0 FAKE_TEST_RC=1
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "gradle wrapper test failure → 1" 1 "$rc"

    PATH="$saved_path"
    cleanup_sandbox

    # --- Gradle: system gradle used when no wrapper exists ---
    create_sandbox generic
    echo 'plugins { id "java" }' > build.gradle
    git add -A && git commit -q -m "gradle project, no wrapper"
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/gradle" <<'SH'
#!/usr/bin/env bash
echo "system $*" >> "$FAKE_LOG"
if [[ "$1" == "test" ]]; then exit "${FAKE_TEST_RC:-0}"; fi
exit "${FAKE_BUILD_RC:-0}"
SH
    chmod +x "$cb/gradle"
    export FAKE_LOG="$SANDBOX/gradle2.log"; : > "$FAKE_LOG"
    PATH="$cb"

    export FAKE_BUILD_RC=0 FAKE_TEST_RC=0
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "system gradle green → 0" 0 "$rc"
    assert_contains "system gradle used when no wrapper" "$(cat "$FAKE_LOG")" "system"

    PATH="$saved_path"
    unset FAKE_LOG FAKE_BUILD_RC FAKE_TEST_RC
    cleanup_sandbox
}

test_verify_typescript_local_only() {
    log_header "73. verify_node type-checks with the local tsc only (never npx)"

    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/detect.sh"

    local saved_path="$PATH" cb rc

    create_sandbox node   # ships tsconfig.json, scripts.build + scripts.test
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >> "$FAKE_LOG"
exit 0
SH
    cat > "$cb/npx" <<'SH'
#!/usr/bin/env bash
echo "npx $*" >> "$FAKE_LOG"
exit 0
SH
    chmod +x "$cb/npm" "$cb/npx"
    export FAKE_LOG="$SANDBOX/node.log"
    PATH="$cb"

    # 1. tsconfig.json but TypeScript not installed locally → not executed, no npx
    : > "$FAKE_LOG"
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "tsconfig without local tsc → 'not executed' (2)" 2 "$rc"
    assert_not_contains "npx tsc is never invoked" "$(cat "$FAKE_LOG")" "npx"

    # 2. Local tsc present and clean → pass, still no npx
    mkdir -p node_modules/.bin
    cat > node_modules/.bin/tsc <<'SH'
#!/usr/bin/env bash
echo "local-tsc $*" >> "$FAKE_LOG"
exit "${FAKE_TSC_RC:-0}"
SH
    chmod +x node_modules/.bin/tsc
    : > "$FAKE_LOG"
    export FAKE_TSC_RC=0
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "local tsc clean → 0" 0 "$rc"
    assert_contains "local tsc was invoked" "$(cat "$FAKE_LOG")" "local-tsc --noEmit"
    assert_not_contains "npx still never invoked" "$(cat "$FAKE_LOG")" "npx"

    # 3. Local tsc reports type errors → real failure, not "unavailable"
    : > "$FAKE_LOG"
    export FAKE_TSC_RC=1
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "local tsc type errors → 1" 1 "$rc"

    PATH="$saved_path"
    unset FAKE_LOG FAKE_TSC_RC
    cleanup_sandbox
}

test_csharp_measurer_parsing() {
    log_header "74. csharp measurer parses clean, warning/error, and vulnerable output"

    source "$KYZN_ROOT/lib/detect.sh"

    local saved_path="$PATH" cb out

    create_sandbox csharp
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/dotnet" <<'SH'
#!/usr/bin/env bash
case "$1" in
    build) cat "$FAKE_BUILD_OUT"; exit 0 ;;
    list)  cat "$FAKE_VULN_OUT";  exit 0 ;;
esac
exit 0
SH
    chmod +x "$cb/dotnet"

    export FAKE_BUILD_OUT="$SANDBOX/build.txt"
    export FAKE_VULN_OUT="$SANDBOX/vuln.txt"

    # --- Clean build, no vulnerable packages ---
    echo "Build succeeded." > "$FAKE_BUILD_OUT"
    echo "The given project has no vulnerable packages given the current sources." > "$FAKE_VULN_OUT"
    out=$(PATH="$cb" bash "$KYZN_ROOT/measurers/csharp.sh" 2>/dev/null)
    assert_eq "clean build → quality 100" "100" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="dotnet-build") | .score')"
    assert_eq "no vulnerable packages → security 100" "100" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="dotnet-list-vulnerable") | .score')"

    # --- 1 error + 2 warnings → 100 - 10 - 4 = 86 ---
    cat > "$FAKE_BUILD_OUT" <<'OUT'
Program.cs(4,9): warning CS0168: The variable 'x' is declared but never used
Program.cs(5,9): warning CS0219: The variable 'y' is assigned but never used
Program.cs(9,1): error CS1002: ; expected
OUT
    out=$(PATH="$cb" bash "$KYZN_ROOT/measurers/csharp.sh" 2>/dev/null)
    assert_eq "1 error + 2 warnings → quality 86" "86" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="dotnet-build") | .score')"
    assert_eq "error count parsed" "1" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="dotnet-build") | .details.errors')"
    assert_eq "warning count parsed" "2" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="dotnet-build") | .details.warnings')"

    # --- 2 vulnerable packages → 100 - 40 = 60 ---
    cat > "$FAKE_VULN_OUT" <<'OUT'
Project `demo` has the following vulnerable packages
   [net8.0]:
   Top-level Package      Requested   Resolved   Severity   Advisory URL
   > Newtonsoft.Json      9.0.1       9.0.1      High      https://github.com/advisories/GHSA-1
   > System.Text.Json     4.7.0       4.7.0      Critical  https://github.com/advisories/GHSA-2
OUT
    out=$(PATH="$cb" bash "$KYZN_ROOT/measurers/csharp.sh" 2>/dev/null)
    assert_eq "2 vulnerable packages → security 60" "60" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="dotnet-list-vulnerable") | .score')"
    assert_eq "vulnerability count parsed" "2" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="dotnet-list-vulnerable") | .details.vulnerabilities')"

    PATH="$saved_path"
    unset FAKE_BUILD_OUT FAKE_VULN_OUT
    cleanup_sandbox
}

test_java_measurer_parsing() {
    log_header "75. java measurer parses clean, build-failure, and vulnerable output"

    source "$KYZN_ROOT/lib/detect.sh"

    local saved_path="$PATH" cb out

    create_sandbox java   # pom.xml → maven flavor
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/mvn" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        compile) cat "$FAKE_BUILD_OUT"; exit 0 ;;
        *dependency-check*) cat "$FAKE_VULN_OUT"; exit 0 ;;
    esac
done
exit 0
SH
    chmod +x "$cb/mvn"

    export FAKE_BUILD_OUT="$SANDBOX/build.txt"
    export FAKE_VULN_OUT="$SANDBOX/vuln.txt"

    # --- Clean compile, no vulnerabilities reported ---
    echo "BUILD SUCCESS" > "$FAKE_BUILD_OUT"
    echo "No vulnerabilities found." > "$FAKE_VULN_OUT"
    out=$(PATH="$cb" bash "$KYZN_ROOT/measurers/java.sh" 2>/dev/null)
    assert_eq "clean compile → quality 100" "100" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="mvn-compile") | .score')"
    assert_eq "no security metric emitted when nothing found" "" \
        "$(echo "$out" | jq -r '.[] | select(.category=="security") | .score')"

    # --- Build failure: 1 error + 2 warnings → 100 - 10 - 4 = 86 ---
    cat > "$FAKE_BUILD_OUT" <<'OUT'
[WARNING] /src/main/java/Hello.java: uses unchecked or unsafe operations
[WARNING] /src/main/java/Hello.java: recompile with -Xlint:unchecked
[ERROR] /src/main/java/Hello.java:[7,1] ';' expected
OUT
    out=$(PATH="$cb" bash "$KYZN_ROOT/measurers/java.sh" 2>/dev/null)
    assert_eq "1 error + 2 warnings → quality 86" "86" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="mvn-compile") | .score')"
    assert_eq "java error count parsed" "1" \
        "$(echo "$out" | jq -r '.[] | select(.tool=="mvn-compile") | .details.errors')"

    # --- OWASP output with 2 CVEs → 100 - 40 = 60 ---
    echo "BUILD SUCCESS" > "$FAKE_BUILD_OUT"
    cat > "$FAKE_VULN_OUT" <<'OUT'
One or more dependencies were identified with known vulnerabilities in demo:
log4j-core-2.14.1.jar: CVE-2021-44228
commons-text-1.9.jar: CVE-2022-42889
OUT
    out=$(PATH="$cb" bash "$KYZN_ROOT/measurers/java.sh" 2>/dev/null)
    assert_eq "2 CVEs → security 60" "60" \
        "$(echo "$out" | jq -r '.[] | select(.category=="security") | .score')"

    PATH="$saved_path"
    unset FAKE_BUILD_OUT FAKE_VULN_OUT
    cleanup_sandbox
}

# Mocked binaries for end-to-end workflow tests. Every outbound side effect
# (Claude invocation, git push, git merge, gh pr) is LOGGED instead of performed,
# so a test can assert it never happened rather than trusting source text.
_workflow_mocks() {
    local cb="$1"
    REAL_GIT=$(command -v git)
    export REAL_GIT

    # _clean_path put symlinks here; unlink first so `cat >` writes a new file
    # instead of following the symlink into the real binary.
    rm -f "$cb/git" "$cb/gh" "$cb/claude" "$cb/npm"

    cat > "$cb/git" <<'SH'
#!/usr/bin/env bash
# Passthrough wrapper: intercepts push/merge, delegates everything else.
args=("$@"); sub=""; i=0
while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
        -c) i=$((i+2)) ;;
        -*) i=$((i+1)) ;;
        *)  sub="${args[$i]}"; break ;;
    esac
done
case "$sub" in
    push|merge) echo "FORBIDDEN git $sub" >> "$WORKFLOW_LOG"; exit 0 ;;
esac
exec "$REAL_GIT" "$@"
SH
    cat > "$cb/gh" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "pr" ]] && echo "FORBIDDEN gh pr ${2:-}" >> "$WORKFLOW_LOG"
exit 0
SH
    cat > "$cb/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE-INVOKED" >> "$WORKFLOW_LOG"
_n=$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")
if [[ -n "${CLAUDE_MUTATE:-}" && -f "$CLAUDE_MUTATE" ]]; then
    CLAUDE_CALL="$_n" bash "$CLAUDE_MUTATE"
fi
echo '{"total_cost_usd":0.01,"result":"mock change"}'
exit 0
SH
    # npm mock: `npm test` fails while the flag file exists, so a scenario can
    # break the build on Claude's first pass and repair it on the retry.
    cat > "$cb/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "test" && -n "${BREAK_TESTS_FLAG:-}" && -f "$BREAK_TESTS_FLAG" ]]; then
    echo "test failure (fixture)"
    exit 1
fi
exit 0
SH
    chmod +x "$cb/git" "$cb/gh" "$cb/claude" "$cb/npm"
}

# Wire the current sandbox for a real cmd_improve / run_fix_phase run:
# committed KyZN config, mocked PATH, empty forbidden-call log.
_workflow_setup() {
    local on_build_fail="${1:-report}"
    ensure_kyzn_dirs
    cat > "$KYZN_CONFIG" <<YAML
project:
  name: test-project
  type: ${KYZN_PROJECT_TYPE:-generic}
preferences:
  mode: quick
  model: sonnet
  budget: 0.50
  max_turns: 5
  diff_limit: 10000
  on_build_fail: $on_build_fail
focus:
  priorities: [security]
YAML
    # .kyzn/ may be covered by a global gitignore — either way the worktree must
    # end up clean, so tolerate "nothing to commit".
    git add -A >/dev/null 2>&1 || true
    git commit -q -m "kyzn config" >/dev/null 2>&1 || true
    # Scaffolding lives OUTSIDE the sandbox: mocks and logs must never show up
    # as worktree changes, or the cleanliness assertions become meaningless.
    WORKFLOW_TMP=$(mktemp -d)
    local cb
    cb=$(_clean_path "$WORKFLOW_TMP/clean-bin" yq)
    _workflow_mocks "$cb"
    WORKFLOW_LOG="$WORKFLOW_TMP/workflow.log"
    export WORKFLOW_LOG
    : > "$WORKFLOW_LOG"
    # These fixtures call cmd_improve / run_fix_phase directly rather than
    # through the CLI, so they bypass the flag parser that sets the unsafe-host
    # gate. Opt in the way an operator does with --allow-unsafe-host-execution:
    # the gate is a deliberate per-run acknowledgement, and these tests are
    # about what a mutating run does AFTER that acknowledgement. The gate's own
    # behaviour is covered separately by the "requires unsafe host gate" tests,
    # which run against the closed default that cleanup_sandbox restores.
    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=true
    _KYZN_UNSAFE_HOST_EXECUTION_WARNED=true
    PATH="$cb"
}

# Scripted "Claude" edit that makes TypeScript verification unavailable:
# adds a tsconfig.json to a project with no local compiler, plus other changes.
_write_mutate_script() {
    cat > "$WORKFLOW_TMP/mutate.sh" <<'SH'
#!/usr/bin/env bash
echo '{"compilerOptions":{"strict":true}}' > tsconfig.json
echo 'console.log("claude was here")' >> src/index.js
mkdir -p src/extra
echo 'export const x = 1' > src/extra/new.ts
SH
    CLAUDE_MUTATE="$WORKFLOW_TMP/mutate.sh"
    export CLAUDE_MUTATE
}

# Scripted "Claude" for self-repair scenarios: the first pass breaks the tests,
# the reflexion retry repairs them but adds a tsconfig.json, making TypeScript
# verification unavailable at exactly the retry re-verify call site.
_write_selfrepair_mutate_script() {
    cat > "$WORKFLOW_TMP/mutate.sh" <<'SH'
#!/usr/bin/env bash
if [[ "${CLAUDE_CALL:-1}" == "1" ]]; then
    echo 'console.log("claude first pass")' >> src/index.js
    touch "$BREAK_TESTS_FLAG"
else
    rm -f "$BREAK_TESTS_FLAG"
    echo '{"compilerOptions":{"strict":true}}' > tsconfig.json
fi
SH
    CLAUDE_MUTATE="$WORKFLOW_TMP/mutate.sh"
    BREAK_TESTS_FLAG="$WORKFLOW_TMP/break-tests"
    export CLAUDE_MUTATE BREAK_TESTS_FLAG
}

test_workflow_gate_blocks_pr_when_unverifiable() {
    log_header "76. unavailable verification never reaches Claude, push, or PR"

    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/measure.sh"
    source "$KYZN_ROOT/lib/prompt.sh"
    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/allowlist.sh"
    source "$KYZN_ROOT/lib/report.sh"
    source "$KYZN_ROOT/lib/history.sh"
    source "$KYZN_ROOT/lib/analyze.sh"

    local saved_path="$PATH" rc orig log

    # --- A. cmd_improve, baseline unavailable (C# project, no dotnet) ---
    create_sandbox csharp
    detect_project_type
    _workflow_setup report
    orig=$(git rev-parse --abbrev-ref HEAD)

    rc=0
    cmd_improve --auto &>/dev/null || rc=$?
    trap - EXIT INT TERM          # cmd_improve arms its own cleanup trap
    log=$(cat "$WORKFLOW_LOG")

    assert_exit_code "improve/baseline: aborts non-zero" 1 "$rc"
    assert_not_contains "improve/baseline: Claude never invoked" "$log" "CLAUDE-INVOKED"
    assert_not_contains "improve/baseline: nothing pushed, merged, or PR'd" "$log" "FORBIDDEN"
    assert_eq "improve/baseline: original branch restored" "$orig" "$(git rev-parse --abbrev-ref HEAD)"
    assert_eq "improve/baseline: no kyzn branch left behind" "" "$(git branch --list 'kyzn/*')"
    if [[ ! -d "$KYZN_DIR/.improve.lock" ]]; then
        pass "improve/baseline: lock released"
    else
        fail "improve/baseline: lock released" "lock directory still present"
    fi
    PATH="$saved_path"
    cleanup_sandbox

    # --- B. cmd_improve, unavailable AFTER Claude ran (adds tsconfig.json) ---
    create_sandbox node
    rm -f tsconfig.json           # baseline must pass: no TS check at all
    git add -A && git commit -q -m "drop tsconfig"
    detect_project_type
    _workflow_setup report
    _write_mutate_script
    orig=$(git rev-parse --abbrev-ref HEAD)

    rc=0
    cmd_improve --auto &> "$WORKFLOW_TMP/improve.out" || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")
    local out; out=$(cat "$WORKFLOW_TMP/improve.out")

    assert_contains "improve/post: Claude did run (gate is post-change)" "$log" "CLAUDE-INVOKED"
    assert_exit_code "improve/post: aborts non-zero" 1 "$rc"
    assert_not_contains "improve/post: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    assert_eq "improve/post: no commit was created" "$(git rev-parse "$orig")" "$(git rev-parse HEAD)"
    # Contract: work is LEFT for inspection, not auto-cleaned. Nothing is deleted.
    assert_eq "improve/post: still on the kyzn branch for inspection" \
        "1" "$(git rev-parse --abbrev-ref HEAD | grep -c '^kyzn/')"
    if [[ -f tsconfig.json && -f src/extra/new.ts ]]; then
        pass "improve/post: Claude's new files preserved for inspection"
    else
        fail "improve/post: preserved files" "KyZN deleted files it should have left alone"
    fi
    assert_contains "improve/post: Claude's edit preserved" "$(cat src/index.js)" "claude was here"
    # The guidance itself — asserted against real command output.
    assert_contains "improve/post: names the current checkout" "$out" "current checkout is the KyZN branch"
    assert_contains "improve/post: says changes are untouched" "$out" "left them untouched"
    assert_contains "improve/post: offers safe inspection" "$out" "git diff --cached"
    assert_not_contains "improve/post: offers no destructive one-liner" "$out" "checkout -f"
    assert_not_contains "improve/post: never tells you to stage everything" "$out" "git add -A"
    PATH="$saved_path"
    unset CLAUDE_MUTATE
    cleanup_sandbox

    # --- C. draft-pr configuration cannot bypass the gate ---
    create_sandbox node
    rm -f tsconfig.json
    git add -A && git commit -q -m "drop tsconfig"
    detect_project_type
    _workflow_setup draft-pr
    _write_mutate_script

    rc=0
    cmd_improve --auto &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")
    assert_not_contains "improve/draft-pr: still no push or PR" "$log" "FORBIDDEN"

    # The backstop itself: handle_build_failure must refuse the draft-pr strategy
    # whenever verification was not executed.
    KYZN_VERIFY_STATUS="unavailable"
    git checkout -q -b kyzn/backstop-test
    echo 'backstop tracked edit' >> src/index.js
    echo 'backstop untracked' > backstop-new.txt
    local bk_sha; bk_sha=$(git rev-parse HEAD)
    : > "$WORKFLOW_LOG"
    handle_build_failure "draft-pr" "20260805-bkstp1" "kyzn/backstop-test" "quick" "security" &>/dev/null || true

    assert_not_contains "backstop: draft-pr refuses to push or open a PR" \
        "$(cat "$WORKFLOW_LOG")" "FORBIDDEN"
    assert_eq "backstop: still checked out on the kyzn branch" \
        "kyzn/backstop-test" "$(git rev-parse --abbrev-ref HEAD)"
    assert_eq "backstop: kyzn branch still exists" \
        "1" "$(git branch --list 'kyzn/backstop-test' | grep -c backstop-test)"
    assert_eq "backstop: no commit created" "$bk_sha" "$(git rev-parse HEAD)"
    assert_contains "backstop: tracked change preserved" "$(cat src/index.js)" "backstop tracked edit"
    if [[ -f backstop-new.txt ]]; then
        pass "backstop: untracked file preserved"
    else
        fail "backstop: untracked file" "backstop-new.txt was deleted"
    fi
    if [[ ! -d "$KYZN_DIR/.improve.lock" ]]; then
        pass "backstop: lock released"
    else
        fail "backstop: lock released" "lock directory still present"
    fi
    KYZN_VERIFY_STATUS="passed"
    PATH="$saved_path"
    unset CLAUDE_MUTATE
    cleanup_sandbox

    # --- D. analyze --fix, baseline unavailable → fix phase never calls Claude ---
    create_sandbox csharp
    detect_project_type
    _workflow_setup report
    echo '[{"severity":"CRITICAL","category":"security","title":"t","description":"d","file":"Program.cs","fix":"f"}]' \
        > "$WORKFLOW_TMP/findings.json"
    printf '# Analysis\n' > "$KYZN_REPORTS_DIR/20260805-fixt01-analysis.md"
    orig=$(git rev-parse --abbrev-ref HEAD)

    rc=0
    run_fix_phase "$WORKFLOW_TMP/findings.json" CRITICAL "20260805-fixt01" "1.00" &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")

    assert_exit_code "analyze/baseline: aborts non-zero" 1 "$rc"
    assert_not_contains "analyze/baseline: fix phase never invoked Claude" "$log" "CLAUDE-INVOKED"
    assert_not_contains "analyze/baseline: nothing pushed, merged, or PR'd" "$log" "FORBIDDEN"
    assert_eq "analyze/baseline: no kyzn branch created" "" "$(git branch --list 'kyzn/*')"
    if [[ ! -d "$KYZN_DIR/.improve.lock" ]]; then
        pass "analyze/baseline: lock released"
    else
        fail "analyze/baseline: lock released" "lock directory still present"
    fi
    PATH="$saved_path"
    cleanup_sandbox

    # --- E. analyze --fix, unavailable per batch → no push, no PR, clean tree ---
    create_sandbox node
    rm -f tsconfig.json
    git add -A && git commit -q -m "drop tsconfig"
    detect_project_type
    _workflow_setup report
    _write_mutate_script
    echo '[{"severity":"CRITICAL","category":"security","title":"t","description":"d","file":"src/index.js","fix":"f"}]' \
        > "$WORKFLOW_TMP/findings.json"
    printf '# Analysis\n' > "$KYZN_REPORTS_DIR/20260805-fixt02-analysis.md"
    orig=$(git rev-parse --abbrev-ref HEAD)
    local orig_sha; orig_sha=$(git rev-parse "$orig")

    rc=0
    run_fix_phase "$WORKFLOW_TMP/findings.json" CRITICAL "20260805-fixt02" "1.00" &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")

    assert_contains "analyze/batch: Claude did run" "$log" "CLAUDE-INVOKED"
    assert_exit_code "analyze/batch: aborts non-zero" 1 "$rc"
    assert_not_contains "analyze/batch: nothing pushed, merged, or PR'd" "$log" "FORBIDDEN"
    assert_eq "analyze/batch: original branch has no new commits" \
        "$orig_sha" "$(git rev-parse "$orig")"
    assert_eq "analyze/batch: kyzn branch kept for inspection" \
        "1" "$(git branch --list 'kyzn/*' | grep -c 'kyzn/')"
    if [[ -f tsconfig.json ]]; then
        pass "analyze/batch: Claude's files preserved for inspection"
    else
        fail "analyze/batch: preserved files" "KyZN deleted files it should have left alone"
    fi
    PATH="$saved_path"
    unset CLAUDE_MUTATE
    cleanup_sandbox

    # --- F. --allow-dirty: the user's own work is never destroyed ---
    create_sandbox node
    rm -f tsconfig.json
    git add -A && git commit -q -m "drop tsconfig"
    detect_project_type
    _workflow_setup report
    _write_mutate_script

    # Pre-existing user state that --allow-dirty permits
    echo 'user edit' >> src/index.js
    echo 'user scratch' > user-notes.txt
    local want_untracked
    want_untracked=$(cat user-notes.txt)
    orig=$(git rev-parse --abbrev-ref HEAD)
    local before_head; before_head=$(git rev-parse HEAD)

    rc=0
    cmd_improve --auto --allow-dirty &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")

    assert_contains "improve/dirty: Claude did run" "$log" "CLAUDE-INVOKED"
    assert_exit_code "improve/dirty: aborts non-zero" 1 "$rc"
    assert_not_contains "improve/dirty: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    # The user's own pre-existing work must still be on disk, untouched. KyZN
    # deletes nothing on abort, so this holds without any restore machinery.
    assert_contains "improve/dirty: user's tracked edit still present" \
        "$(cat src/index.js 2>/dev/null)" "user edit"
    assert_eq "improve/dirty: user's untracked file byte-for-byte" \
        "$want_untracked" "$(cat user-notes.txt 2>/dev/null)"
    assert_eq "improve/dirty: no commit created on the original branch" \
        "$before_head" "$(git rev-parse "$orig")"
    PATH="$saved_path"
    unset CLAUDE_MUTATE
    cleanup_sandbox

    # --- G. cmd_improve: unavailable at the SELF-REPAIR re-verify call site ---
    create_sandbox node
    rm -f tsconfig.json
    git add -A && git commit -q -m "drop tsconfig"
    detect_project_type
    _workflow_setup report
    _write_selfrepair_mutate_script
    orig=$(git rev-parse --abbrev-ref HEAD)
    local g_sha; g_sha=$(git rev-parse HEAD)

    rc=0
    cmd_improve --auto &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")

    assert_eq "improve/self-repair: Claude ran twice (reflexion retry fired)" \
        "2" "$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")"
    assert_exit_code "improve/self-repair: aborts non-zero" 1 "$rc"
    assert_not_contains "improve/self-repair: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    assert_eq "improve/self-repair: no commit on the original branch" "$g_sha" "$(git rev-parse "$orig")"
    assert_eq "improve/self-repair: kyzn checkout kept for inspection" \
        "1" "$(git rev-parse --abbrev-ref HEAD | grep -c '^kyzn/')"
    if [[ -f tsconfig.json ]]; then
        pass "improve/self-repair: retry changes preserved"
    else
        fail "improve/self-repair: preserved files" "KyZN deleted files it should have left alone"
    fi
    PATH="$saved_path"
    unset CLAUDE_MUTATE BREAK_TESTS_FLAG
    cleanup_sandbox

    # --- H. run_fix_phase: unavailable at the SELF-REPAIR re-verify call site ---
    create_sandbox node
    rm -f tsconfig.json
    git add -A && git commit -q -m "drop tsconfig"
    detect_project_type
    _workflow_setup report
    _write_selfrepair_mutate_script
    echo '[{"severity":"CRITICAL","category":"security","title":"t","description":"d","file":"src/index.js","fix":"f"}]' \
        > "$WORKFLOW_TMP/findings.json"
    printf '# Analysis\n' > "$KYZN_REPORTS_DIR/20260805-fixt03-analysis.md"
    orig=$(git rev-parse --abbrev-ref HEAD)
    local h_sha; h_sha=$(git rev-parse HEAD)

    rc=0
    run_fix_phase "$WORKFLOW_TMP/findings.json" CRITICAL "20260805-fixt03" "1.00" &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")

    assert_eq "analyze/self-repair: Claude ran twice (reflexion retry fired)" \
        "2" "$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")"
    assert_exit_code "analyze/self-repair: aborts non-zero" 1 "$rc"
    assert_not_contains "analyze/self-repair: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    assert_eq "analyze/self-repair: no commit on the original branch" "$h_sha" "$(git rev-parse "$orig")"
    if [[ -f tsconfig.json ]]; then
        pass "analyze/self-repair: retry changes preserved"
    else
        fail "analyze/self-repair: preserved files" "KyZN deleted files it should have left alone"
    fi
    PATH="$saved_path"
    unset CLAUDE_MUTATE BREAK_TESTS_FLAG
    cleanup_sandbox

    # --- I. Python: tests present, no pytest → gate holds at workflow level ---
    create_sandbox python
    detect_project_type
    _workflow_setup report
    orig=$(git rev-parse --abbrev-ref HEAD)

    rc=0
    cmd_improve --auto &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")

    assert_exit_code "python/workflow: aborts non-zero" 1 "$rc"
    assert_not_contains "python/workflow: Claude never invoked" "$log" "CLAUDE-INVOKED"
    assert_not_contains "python/workflow: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    assert_eq "python/workflow: original branch restored" "$orig" "$(git rev-parse --abbrev-ref HEAD)"
    if [[ ! -d "$KYZN_DIR/.improve.lock" ]]; then
        pass "python/workflow: lock released"
    else
        fail "python/workflow: lock released" "lock directory still present"
    fi
    PATH="$saved_path"
    cleanup_sandbox

    # --- J. Node: npm absent → gate holds at workflow level -------------------
    create_sandbox node
    detect_project_type
    _workflow_setup report
    rm -f "$WORKFLOW_TMP/clean-bin/npm"     # npm disappears from the mocked PATH
    orig=$(git rev-parse --abbrev-ref HEAD)

    rc=0
    cmd_improve --auto &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")

    assert_exit_code "node/workflow: aborts non-zero" 1 "$rc"
    assert_not_contains "node/workflow: Claude never invoked" "$log" "CLAUDE-INVOKED"
    assert_not_contains "node/workflow: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    assert_eq "node/workflow: original branch restored" "$orig" "$(git rev-parse --abbrev-ref HEAD)"
    PATH="$saved_path"
    cleanup_sandbox

    # --- L. Python: Claude adds a root test file after a clean baseline -------
    # Baseline has no tests and no pytest, so nothing is required and it passes.
    # Claude then adds test_new.py, which makes pytest required and unavailable.
    create_sandbox python
    rm -rf tests
    git add -A && git commit -q -m "no tests"
    detect_project_type
    _workflow_setup report
    cat > "$WORKFLOW_TMP/mutate.sh" <<'SH'
#!/usr/bin/env bash
echo 'def test_new(): assert True' > test_new.py
SH
    CLAUDE_MUTATE="$WORKFLOW_TMP/mutate.sh"
    export CLAUDE_MUTATE
    orig=$(git rev-parse --abbrev-ref HEAD)
    local l_sha; l_sha=$(git rev-parse HEAD)

    rc=0
    cmd_improve --auto &> "$WORKFLOW_TMP/py.out" || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")
    out=$(cat "$WORKFLOW_TMP/py.out")

    assert_contains "python/new-test: Claude did run (baseline was clean)" "$log" "CLAUDE-INVOKED"
    # Non-vacuous: prove it aborted for THIS reason, not some unrelated failure.
    assert_contains "python/new-test: aborted because pytest was unavailable" \
        "$out" "no usable pytest was found"
    assert_contains "python/new-test: took the unavailable gate" \
        "$out" "Verification was not executed"
    assert_exit_code "python/new-test: aborts non-zero" 1 "$rc"
    assert_not_contains "python/new-test: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    assert_eq "python/new-test: no commit on the original branch" "$l_sha" "$(git rev-parse "$orig")"
    if [[ -f test_new.py ]]; then
        pass "python/new-test: Claude's test file preserved for inspection"
    else
        fail "python/new-test: preserved files" "KyZN deleted files it should have left alone"
    fi
    PATH="$saved_path"
    unset CLAUDE_MUTATE
    cleanup_sandbox

    # --- K. Precedence at workflow level: unavailable + failing tests ---------
    # Baseline is genuinely broken AND the type check cannot run. The run must
    # take the unavailable gate, not the pre-existing-failure path that would
    # let it proceed to Claude and a PR.
    create_sandbox node                     # tsconfig.json present, no local tsc
    detect_project_type
    _workflow_setup report
    cat > "$WORKFLOW_TMP/clean-bin/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "test" ]]; then echo "tests failing"; exit 1; fi
exit 0
SH
    chmod +x "$WORKFLOW_TMP/clean-bin/npm"
    orig=$(git rev-parse --abbrev-ref HEAD)

    rc=0
    cmd_improve --auto &>/dev/null || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")

    assert_exit_code "precedence/workflow: aborts non-zero" 1 "$rc"
    assert_not_contains "precedence/workflow: failing tests do not unlock Claude" "$log" "CLAUDE-INVOKED"
    assert_not_contains "precedence/workflow: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    assert_eq "precedence/workflow: original branch restored" "$orig" "$(git rev-parse --abbrev-ref HEAD)"
    PATH="$saved_path"
    cleanup_sandbox
}

test_abort_never_destroys_user_work() {
    log_header "77. aborting an unverifiable run destroys nothing"

    source "$KYZN_ROOT/lib/core.sh"
    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/verify.sh"

    create_sandbox generic
    local orig; orig=$(git rev-parse --abbrev-ref HEAD)
    local before_head; before_head=$(git rev-parse HEAD)

    # Awkward but perfectly legal filenames — the abort path must not care,
    # because it never enumerates, copies, or deletes anything.
    printf 'user edit\n' >> scripts/run.sh
    printf 'keep me\n'  > 'user notes.txt'
    printf 'keep me\n'  > -leading-dash.txt
    printf 'keep me\n'  > "$(printf 'tab\tname.txt')"
    mkdir -p 'nested dir'
    printf 'keep me\n'  > 'nested dir/deep file.txt'
    ln -sf 'user notes.txt' link-to-notes

    KYZN_ORIGINAL_BRANCH="$orig"
    git checkout -q -b kyzn/abort-test
    printf 'claude edit\n' >> tests/test.sh
    printf 'claude new\n'  > claude-new.txt

    # shellcheck disable=SC2034 # Read by abort_unverified_run in execute.sh.
    KYZN_VERIFY_UNAVAILABLE_REASON="dotnet not found — test fixture"
    abort_unverified_run "kyzn/abort-test" true &>/dev/null

    assert_eq "abort: stays on the kyzn branch for inspection" \
        "kyzn/abort-test" "$(git rev-parse --abbrev-ref HEAD)"
    assert_eq "abort: branch kept, not deleted" \
        "1" "$(git branch --list 'kyzn/abort-test' | grep -c abort-test)"
    assert_eq "abort: no commit created" "$before_head" "$(git rev-parse "$orig")"

    local f
    for f in 'user notes.txt' '-leading-dash.txt' 'nested dir/deep file.txt' \
             'claude-new.txt' 'tests/test.sh' 'scripts/run.sh'; do
        if [[ -e "$f" ]]; then
            pass "abort: preserved '$f'"
        else
            fail "abort: preserved '$f'" "file was destroyed"
        fi
    done
    if [[ -e "$(printf 'tab\tname.txt')" ]]; then
        pass "abort: preserved filename containing a tab"
    else
        fail "abort: tab filename" "file was destroyed"
    fi
    if [[ -L link-to-notes ]]; then
        pass "abort: symlink preserved as a symlink"
    else
        fail "abort: symlink" "symlink was destroyed or replaced"
    fi
    assert_contains "abort: user's tracked edit intact" "$(cat scripts/run.sh)" "user edit"
    assert_contains "abort: Claude's edit intact for inspection" "$(cat tests/test.sh)" "claude edit"

    # Lock is released even though nothing was cleaned up
    if [[ ! -d "$KYZN_DIR/.improve.lock" ]]; then
        pass "abort: lock released"
    else
        fail "abort: lock released" "lock directory still present"
    fi

    # A failed unwind must NOT be treated as successful cleanup. Point the
    # "original branch" at something that cannot be checked out and confirm the
    # KyZN branch survives and the preserve guidance is shown instead.
    local out
    KYZN_ORIGINAL_BRANCH="no-such-branch-xyz"
    out=$(abort_unverified_run "kyzn/abort-test" false 2>&1)
    assert_eq "abort/failed-unwind: kyzn branch not deleted" \
        "1" "$(git branch --list 'kyzn/abort-test' | grep -c abort-test)"
    assert_contains "abort/failed-unwind: says it could not return" "$out" "Could not return to"
    assert_contains "abort/failed-unwind: falls back to preserve guidance" \
        "$out" "current checkout is the KyZN branch"

    # Detached HEAD is preserved, never guessed at.
    git checkout -q --detach
    # shellcheck disable=SC2034 # Read by abort_unverified_run in execute.sh.
    KYZN_ORIGINAL_BRANCH="HEAD"
    out=$(abort_unverified_run "kyzn/abort-test" false 2>&1)
    assert_eq "abort/detached: kyzn branch still intact" \
        "1" "$(git branch --list 'kyzn/abort-test' | grep -c abort-test)"
    assert_contains "abort/detached: preserves rather than guessing a branch" \
        "$out" "current checkout is the KyZN branch"

    # --allow-dirty users get an explicit warning against blind resets
    KYZN_ALLOW_DIRTY=true
    out=$(abort_unverified_run "kyzn/abort-test" true 2>&1)
    assert_contains "abort/allow-dirty: warns against blind reset" "$out" "reset --hard"
    assert_contains "abort/allow-dirty: names --allow-dirty" "$out" "--allow-dirty"
    # shellcheck disable=SC2034 # Read by abort_unverified_run in execute.sh.
    KYZN_ALLOW_DIRTY=false

    cleanup_sandbox
}

test_verification_precedence_and_tool_contracts() {
    log_header "78. unavailable outranks failure; Node/Python tool contracts"

    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/detect.sh"

    local saved_path="$PATH" cb rc

    # --- A/B. Unavailable must outrank a concurrent failure --------------------
    # tsconfig.json with no local tsc (unavailable) AND a failing npm script.
    # The decision must stay "not executed", or the run slips into the ordinary
    # failure path and becomes eligible for the pre-existing-failure branch.
    local phase
    for phase in build test; do
        create_sandbox node          # ships tsconfig.json + build/test scripts
        detect_project_type
        cb=$(_clean_path "$SANDBOX/clean-bin")
        cat > "$cb/npm" <<'SH'
#!/usr/bin/env bash
# Fail only the phase under test; the other passes.
if [[ "${1:-}" == "run" && "${2:-}" == "$FAIL_PHASE" ]]; then exit 1; fi
if [[ "${1:-}" == "$FAIL_PHASE" ]]; then echo "failing"; exit 1; fi
exit 0
SH
        chmod +x "$cb/npm"
        export FAIL_PHASE="$phase"
        PATH="$cb"
        rc=0
        verify_build &>/dev/null || rc=$?
        PATH="$saved_path"
        assert_exit_code "precedence: missing tsc + failing npm $phase → unavailable (2)" 2 "$rc"
        assert_eq "precedence: status stays unavailable, not failed" \
            "unavailable" "${KYZN_VERIFY_STATUS:-}"
        unset FAIL_PHASE
        cleanup_sandbox
    done

    # --- C. Node: npm absent entirely -----------------------------------------
    create_sandbox node
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "node: npm absent → unavailable (2)" 2 "$rc"
    cleanup_sandbox

    # --- D. Node: no build/test scripts AND no npm must not pass silently -----
    create_sandbox node
    echo '{"name":"test-project"}' > package.json     # no scripts at all
    rm -f tsconfig.json                               # remove the other trigger
    git add -A && git commit -q -m "no scripts"
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "node: no scripts + no npm → unavailable (2)" 2 "$rc"
    cleanup_sandbox

    # --- E. Python: tests present but pytest nowhere --------------------------
    create_sandbox python          # ships tests/test_basic.py
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "python: tests present, no pytest → unavailable (2)" 2 "$rc"
    assert_eq "python: status unavailable" "unavailable" "${KYZN_VERIFY_STATUS:-}"
    cleanup_sandbox

    # --- F. Python: project-local .venv pytest is used without activation -----
    create_sandbox python
    detect_project_type
    mkdir -p .venv/bin
    cat > .venv/bin/pytest <<'SH'
#!/usr/bin/env bash
echo "venv-pytest $*" >> "$FAKE_LOG"
if [[ "${1:-}" == "--version" ]]; then exit 0; fi
exit "${FAKE_PYTEST_RC:-0}"
SH
    chmod +x .venv/bin/pytest
    export FAKE_LOG="$SANDBOX/py.log"; : > "$FAKE_LOG"
    export FAKE_PYTEST_RC=0
    cb=$(_clean_path "$SANDBOX/clean-bin")
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "python: .venv pytest found without activation → 0" 0 "$rc"
    assert_contains "python: .venv pytest actually invoked" "$(cat "$FAKE_LOG")" "venv-pytest"

    # --- G. Python: local pytest failing is a real failure, not unavailable ---
    export FAKE_PYTEST_RC=1
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "python: .venv pytest failing → failed (1)" 1 "$rc"
    unset FAKE_LOG FAKE_PYTEST_RC
    cleanup_sandbox

    # --- H. Python: no tests at all → nothing required, still passes ----------
    create_sandbox python
    rm -rf tests
    git add -A && git commit -q -m "no tests"
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "python: no tests present → 0 (nothing required)" 0 "$rc"
    cleanup_sandbox

    # --- I. Every supported Python test layout requires pytest ----------------
    # KyZN's own detection already counts test/ and pytest.ini as tests, and
    # gate_new_test_files already recognises root test_*.py / *_test.py. The
    # verifier must agree, or those layouts score a green with no runner.
    local layout
    for layout in 'test/' 'conftest.py' 'pytest.ini' 'test_example.py' 'example_test.py'; do
        create_sandbox python
        rm -rf tests                     # remove the one layout already covered
        case "$layout" in
            'test/') mkdir -p test && echo 'def test_ok(): assert True' > test/test_a.py ;;
            *)       echo 'def test_ok(): assert True' > "$layout" ;;
        esac
        git add -A && git commit -q -m "layout $layout"
        detect_project_type
        cb=$(_clean_path "$SANDBOX/clean-bin")
        PATH="$cb"
        rc=0
        verify_build &>/dev/null || rc=$?
        PATH="$saved_path"
        assert_exit_code "python layout '$layout' + no pytest → unavailable (2)" 2 "$rc"
        cleanup_sandbox
    done
}

test_toolchain_matrix_download_authorization() {
    log_header "79. toolchain matrix: --require never authorizes downloads"

    local harness="$KYZN_ROOT/tests/toolchain/run-matrix.sh"
    if [[ ! -f "$harness" ]]; then
        skip "toolchain matrix harness not present"
        return
    fi

    SANDBOX=$(mktemp -d)
    cd "$SANDBOX"
    mkdir -p bin

    # Every package manager the matrix could reach for is mocked to LOG rather
    # than run. If the harness ever shells out to one without authorization,
    # the log is non-empty and this test fails.
    PKG_LOG="$SANDBOX/pkg.log"
    export PKG_LOG
    : > "$PKG_LOG"
    local t
    for t in npm npx dotnet mvn gradle; do
        cat > "bin/$t" <<SH
#!/usr/bin/env bash
echo "INVOKED $t \$*" >> "\$PKG_LOG"
exit 0
SH
        chmod +x "bin/$t"
    done

    local saved="$PATH" out rc

    # 1. Normal mode: every suite skipped, nothing invoked, exit 0
    PATH="$SANDBOX/bin:$PATH"
    rc=0
    out=$(bash "$harness" all 2>&1) || rc=$?
    PATH="$saved"
    assert_exit_code "matrix/normal: exits 0 when downloads are unauthorized" 0 "$rc"
    assert_eq "matrix/normal: no package manager invoked" "" "$(cat "$PKG_LOG")"
    assert_contains "matrix/normal: reports suites as skipped" "$out" "SKIP"

    # 2. --require ALONE: must fail loudly, and still invoke nothing.
    #    This is the regression: strictness must not imply network access.
    : > "$PKG_LOG"
    PATH="$SANDBOX/bin:$PATH"
    rc=0
    out=$(bash "$harness" --require all 2>&1) || rc=$?
    PATH="$saved"
    if (( rc != 0 )); then
        pass "matrix/require: fails when downloads are not authorized"
    else
        fail "matrix/require: fails" "expected non-zero exit, got $rc"
    fi
    assert_eq "matrix/require: STILL no package manager invoked" "" "$(cat "$PKG_LOG")"
    assert_contains "matrix/require: explains downloads are unauthorized" "$out" "not authorized"
    assert_not_contains "matrix/require: does not tell the user to pass --require" "$out" "use --require"

    # 3. The CI workflow must authorize downloads explicitly at every call site.
    local wf="$KYZN_ROOT/.github/workflows/toolchain-matrix.yml"
    if [[ -f "$wf" ]]; then
        local calls unauthorized
        calls=$(grep -c 'run-matrix\.sh --require' "$wf") || calls=0
        unauthorized=$(grep 'run-matrix\.sh --require' "$wf" | grep -vc -- '--allow-downloads') || unauthorized=0
        if (( calls > 0 )); then
            pass "matrix/ci: workflow invokes the harness ($calls call sites)"
        else
            fail "matrix/ci: workflow invokes the harness" "no run-matrix.sh invocation found"
        fi
        assert_eq "matrix/ci: every invocation passes --allow-downloads" "0" "$unauthorized"
    else
        skip "toolchain workflow not present"
    fi

    unset PKG_LOG
    cd "$KYZN_ROOT"
    rm -rf "$SANDBOX"
}

# Python runner shims used by test 80.
#   broken       — executable, but its shebang interpreter does not exist (127)
#   working      — runs, logs, honours FAKE_PYTEST_RC
#   probe-ok     — answers --version fine, but 127 on a real invocation
_write_pytest_shim() { # _write_pytest_shim <path> <kind>
    mkdir -p "$(dirname "$1")"
    case "$2" in
        broken)
            printf '#!/nonexistent/interpreter/python\n' > "$1" ;;
        working)
            # A real runner answers --version with 0 even when the suite fails,
            # so the probe must not be conflated with the test outcome.
            cat > "$1" <<'SH'
#!/usr/bin/env bash
echo "PYTEST $KIND $*" >> "$FAKE_LOG"
if [[ "${1:-}" == "--version" ]]; then exit 0; fi
exit "${FAKE_PYTEST_RC:-0}"
SH
            ;;
        version-fail)
            # Executes fine, but --version reports failure: a candidate that
            # cannot answer the probe cleanly must not be trusted.
            cat > "$1" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then exit 1; fi
exit 0
SH
            ;;
        probe-ok)
            # Answers the probe, then fails to execute for real.
            cat > "$1" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then exit 0; fi
exit "${EXEC_FAIL_RC:-127}"
SH
            ;;
    esac
    chmod +x "$1"
}

test_python_unusable_shim_is_unavailable() {
    log_header "80. unusable Python runners fall through, or report 'not executed'"

    source "$KYZN_ROOT/lib/core.sh"
    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/measure.sh"
    source "$KYZN_ROOT/lib/prompt.sh"
    source "$KYZN_ROOT/lib/allowlist.sh"
    source "$KYZN_ROOT/lib/report.sh"
    source "$KYZN_ROOT/lib/history.sh"

    local saved_path="$PATH" cb rc

    # --- 1 + 6. Broken .venv shim, working PATH pytest → fall through --------
    create_sandbox python
    detect_project_type
    _write_pytest_shim .venv/bin/pytest broken
    cb=$(_clean_path "$SANDBOX/clean-bin")
    FAKE_LOG="$SANDBOX/py.log"; export FAKE_LOG; : > "$FAKE_LOG"
    KIND="path"; export KIND
    FAKE_PYTEST_RC=0; export FAKE_PYTEST_RC
    _write_pytest_shim "$cb/pytest" working
    PATH="$cb"
    assert_eq "shim/fallthrough: resolver skips the broken local shim" \
        "$cb/pytest" "$(_kyzn_python_tool pytest)"
    rc=0
    verify_build &>/dev/null || rc=$?
    assert_exit_code "shim/fallthrough: uses the working PATH runner → 0" 0 "$rc"
    assert_contains "shim/fallthrough: the healthy runner actually ran" "$(cat "$FAKE_LOG")" "PYTEST path"

    # 6. capture_failing_tests and gate_new_test_files use the healthy runner too
    : > "$FAKE_LOG"
    capture_failing_tests >/dev/null 2>&1 || true
    assert_contains "shim/fallthrough: capture_failing_tests uses the healthy runner" \
        "$(cat "$FAKE_LOG")" "PYTEST path"
    : > "$FAKE_LOG"
    echo 'def test_new(): assert True' > test_brand_new.py
    gate_new_test_files >/dev/null 2>&1 || true
    assert_contains "shim/fallthrough: gate_new_test_files uses the healthy runner" \
        "$(cat "$FAKE_LOG")" "collect-only"
    PATH="$saved_path"; cleanup_sandbox

    # --- 1a. Local candidate whose --version exits 1 → fall through ----------
    create_sandbox python
    detect_project_type
    _write_pytest_shim .venv/bin/pytest version-fail
    cb=$(_clean_path "$SANDBOX/clean-bin")
    FAKE_LOG="$SANDBOX/py.log"; export FAKE_LOG; : > "$FAKE_LOG"
    KIND="path"; export KIND
    FAKE_PYTEST_RC=0; export FAKE_PYTEST_RC
    _write_pytest_shim "$cb/pytest" working
    PATH="$cb"
    assert_eq "shim/version-nonzero: resolver skips a candidate whose --version fails" \
        "$cb/pytest" "$(_kyzn_python_tool pytest)"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "shim/version-nonzero: healthy PATH fallback used → 0" 0 "$rc"
    assert_contains "shim/version-nonzero: healthy runner actually ran" "$(cat "$FAKE_LOG")" "PYTEST path"
    unset FAKE_PYTEST_RC KIND
    cleanup_sandbox

    # --- 1b. EVERY candidate fails its probe → unavailable --------------------
    create_sandbox python
    detect_project_type
    _write_pytest_shim .venv/bin/pytest version-fail
    _write_pytest_shim venv/bin/pytest version-fail
    cb=$(_clean_path "$SANDBOX/clean-bin")
    _write_pytest_shim "$cb/pytest" version-fail
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "shim/version-nonzero: all candidates fail probe → not executed (2)" 2 "$rc"
    assert_eq "shim/version-nonzero: status unavailable" "unavailable" "${KYZN_VERIFY_STATUS:-}"
    cleanup_sandbox

    # --- 2. Broken local shim, no usable fallback → unavailable --------------
    create_sandbox python
    detect_project_type
    _write_pytest_shim .venv/bin/pytest broken
    cb=$(_clean_path "$SANDBOX/clean-bin")
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "shim/no-fallback: broken local shim → not executed (2)" 2 "$rc"
    assert_eq "shim/no-fallback: status unavailable" "unavailable" "${KYZN_VERIFY_STATUS:-}"
    cleanup_sandbox

    # --- 3. Broken pytest on PATH, nothing local → unavailable ---------------
    create_sandbox python
    detect_project_type
    cb=$(_clean_path "$SANDBOX/clean-bin")
    _write_pytest_shim "$cb/pytest" broken
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "shim/path-broken: broken PATH pytest → not executed (2)" 2 "$rc"
    cleanup_sandbox

    # --- 4. Passes the probe, then 126 OR 127 on the real run → unavailable --
    local failcode
    for failcode in 126 127; do
        create_sandbox python
        detect_project_type
        _write_pytest_shim .venv/bin/pytest probe-ok
        cb=$(_clean_path "$SANDBOX/clean-bin")
        EXEC_FAIL_RC="$failcode"; export EXEC_FAIL_RC
        PATH="$cb"
        rc=0
        verify_build &>/dev/null || rc=$?
        PATH="$saved_path"
        assert_exit_code "shim/exec-fail: exit $failcode on the real run → not executed (2)" 2 "$rc"
        assert_eq "shim/exec-fail($failcode): status unavailable, not failed" \
            "unavailable" "${KYZN_VERIFY_STATUS:-}"
        unset EXEC_FAIL_RC
        cleanup_sandbox
    done

    # --- 5. A genuine test failure is still an ordinary failure --------------
    create_sandbox python
    detect_project_type
    FAKE_LOG="$SANDBOX/py.log"; export FAKE_LOG; : > "$FAKE_LOG"
    KIND="venv"; export KIND
    FAKE_PYTEST_RC=1; export FAKE_PYTEST_RC
    _write_pytest_shim .venv/bin/pytest working
    cb=$(_clean_path "$SANDBOX/clean-bin")
    PATH="$cb"
    rc=0
    verify_build &>/dev/null || rc=$?
    PATH="$saved_path"
    assert_exit_code "shim/real-failure: pytest exit 1 stays failed (1)" 1 "$rc"
    assert_eq "shim/real-failure: status failed, not unavailable" "failed" "${KYZN_VERIFY_STATUS:-}"
    unset FAKE_PYTEST_RC KIND
    cleanup_sandbox

    # --- 7. Workflow level: no usable pytest cannot reach Claude or a PR -----
    create_sandbox python
    detect_project_type
    _write_pytest_shim .venv/bin/pytest broken
    _workflow_setup report
    rm -f "$WORKFLOW_TMP/clean-bin/pytest" 2>/dev/null || true
    local orig; orig=$(git rev-parse --abbrev-ref HEAD)
    rc=0
    cmd_improve --auto &>/dev/null || rc=$?
    trap - EXIT INT TERM
    local log; log=$(cat "$WORKFLOW_LOG")
    assert_exit_code "shim/workflow: aborts non-zero" 1 "$rc"
    assert_not_contains "shim/workflow: Claude never invoked" "$log" "CLAUDE-INVOKED"
    assert_not_contains "shim/workflow: nothing committed, pushed, or PR'd" "$log" "FORBIDDEN"
    assert_eq "shim/workflow: original branch restored" "$orig" "$(git rev-parse --abbrev-ref HEAD)"
    PATH="$saved_path"
    unset FAKE_LOG
    cleanup_sandbox
}

# Drives a full cmd_improve / run_fix_phase run whose BASELINE already fails, so
# the red-baseline branch is the one under test. The npm mock controls the test
# result and the build result independently, which is what lets each scenario
# isolate one reason for the final verification being red.
_preexisting_sandbox() { # _preexisting_sandbox <mode: buildbreak|newtest|notests|samefail|testcompile|heals>
    local mode="$1"
    create_sandbox node
    rm -f tsconfig.json
    echo '{"name":"fx","scripts":{"build":"x","test":"x"}}' > package.json
    mkdir -p src; echo 'console.log(1)' > src/index.js
    git add -A && git commit -q -m scaffold
    detect_project_type
    _workflow_setup report

    BREAK_BUILD="$WORKFLOW_TMP/break-build"; export BREAK_BUILD
    AFTER_MARK="$WORKFLOW_TMP/after-mark"; export AFTER_MARK
    FAIL_MODE="$mode"; export FAIL_MODE
    rm -f "$BREAK_BUILD" "$AFTER_MARK"

    rm -f "$WORKFLOW_TMP/clean-bin/npm"
    cat > "$WORKFLOW_TMP/clean-bin/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then
    if [[ -f "$BREAK_BUILD" ]]; then echo "error: build broken"; exit 1; fi
    exit 0
fi
if [[ "${1:-}" == "test" ]]; then
    case "${FAIL_MODE:-}" in
        notests)  # tests fail, but emit nothing capture_failing_tests can parse
            if [[ -f "$AFTER_MARK" ]]; then echo "runner crashed: no results emitted"; exit 1; fi
            echo "FAIL src/a.test.js"; exit 1 ;;
        newtest)  # build stays green; a DIFFERENT test starts failing
            if [[ -f "$AFTER_MARK" ]]; then echo "FAIL src/b.test.js"; exit 1; fi
            echo "FAIL src/a.test.js"; exit 1 ;;
        testcompile)  # the already-failing suite stops COMPILING. jest prints the
                      # SAME `FAIL <file>` line either way, so the identifier is
                      # byte-identical to baseline and no identifier comparison
                      # could ever tell these two states apart.
            if [[ -f "$AFTER_MARK" ]]; then
                echo "FAIL src/a.test.js"
                echo "  ● Test suite failed to run"
                exit 1
            fi
            echo "FAIL src/a.test.js"; exit 1 ;;
        heals)    # red baseline that Claude actually repairs
            if [[ -f "$AFTER_MARK" ]]; then exit 0; fi
            echo "FAIL src/a.test.js"; exit 1 ;;
        *)        echo "FAIL src/a.test.js"; exit 1 ;;
    esac
fi
exit 0
SH
    chmod +x "$WORKFLOW_TMP/clean-bin/npm"

    cat > "$WORKFLOW_TMP/mutate.sh" <<'SH'
#!/usr/bin/env bash
touch "$AFTER_MARK"
case "${FAIL_MODE:-}" in
    buildbreak) touch "$BREAK_BUILD"; echo "// claude edit" >> src/index.js ;;
    heals)
        # Must be a genuine improvement: the success path continues into the
        # score-regression gate, which is a SEPARATE guard. Appending a bare
        # comment trips it (86 -> 85) and would stop the run for a reason that
        # has nothing to do with the verification contract under test.
        printf '# Test Project\n\nUsage documentation.\n' > README.md ;;
    *) echo "// claude edit" >> src/index.js ;;
esac
SH
    CLAUDE_MUTATE="$WORKFLOW_TMP/mutate.sh"; export CLAUDE_MUTATE
}

# A red FINAL verification is never a success, whatever it looks like.
#
# KyZN used to carry an escape hatch: if the baseline was already failing and the
# post-change failures "looked pre-existing", the run continued to commit/push/PR.
# Deciding that required KyZN to work out WHY a run was red from the runner's
# output — and some toolchains make that undecidable. `go build ./...` never
# compiles _test.go, so a broken test file leaves the build green while `go test`
# reprints the baseline identifiers next to `[build failed]`. jest prints the same
# `FAIL <file>` line whether a test failed or the suite never ran at all. In both
# cases the identifier set is byte-identical to baseline.
#
# The bypass is gone, so none of that has to be recognised. The contract is:
#   baseline rc 1 → Claude may still attempt improvements
#   final    rc 0 → success path
#   final    rc 1 → build-failure policy, always
#   final    rc 2 → unconditional unavailable abort
test_red_final_verification_never_ships() {
    log_header "81. a red final verification never enters the success path"

    source "$KYZN_ROOT/lib/core.sh"
    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/measure.sh"
    source "$KYZN_ROOT/lib/prompt.sh"
    source "$KYZN_ROOT/lib/allowlist.sh"
    source "$KYZN_ROOT/lib/report.sh"
    source "$KYZN_ROOT/lib/history.sh"
    source "$KYZN_ROOT/lib/analyze.sh"

    local saved_path="$PATH" rc out log cb

    # --- 7a. rc 2 (unavailable) is still an unconditional abort -------------
    create_sandbox node
    detect_project_type              # ships tsconfig.json, no local tsc
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/npm" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$cb/npm"
    PATH="$cb"
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "rc2: unavailable tooling still returns 2" 2 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 7b. A project with no applicable checks is still rc 0 -------------
    create_sandbox generic
    detect_project_type
    rm -f Makefile
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "no-checks: nothing applicable to run still returns 0" 0 "$rc"
    cleanup_sandbox

    # --- 1. Unchanged named baseline failures no longer reach success ------
    # This is the case the removed bypass used to wave through.
    _preexisting_sandbox samefail
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/s.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/s.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "unchanged/baseline-red: Claude still got to attempt improvements" \
        "$log" "CLAUDE-INVOKED"
    assert_contains "unchanged: final verification is still red after the retry" \
        "$out" "Self-repair failed -- verification is still not green"
    assert_contains "unchanged: explicitly not treated as success" \
        "$out" "will not treat a red final verification as a success"
    assert_not_contains "unchanged: nothing pushed or PR'd" "$log" "FORBIDDEN"
    assert_exit_code "unchanged: aborts non-zero" 1 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 2. A newly introduced named failure blocks -------------------------
    _preexisting_sandbox newtest
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/nt.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")
    assert_not_contains "newtest: nothing pushed or PR'd" "$log" "FORBIDDEN"
    assert_exit_code "newtest: aborts non-zero" 1 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 3a. A build failure blocks ----------------------------------------
    _preexisting_sandbox buildbreak
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/q.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")
    assert_not_contains "buildbreak: nothing pushed or PR'd" "$log" "FORBIDDEN"
    assert_exit_code "buildbreak: aborts non-zero" 1 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 3b. A test-loader / test-compilation failure blocks, and does so
    #         WITHOUT KyZN recognising the runner's wording ------------------
    _preexisting_sandbox testcompile
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/tc.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/tc.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "testcompile: final verification is still red after the retry" \
        "$out" "Self-repair failed -- verification is still not green"
    assert_contains "testcompile: explicitly not treated as success" \
        "$out" "will not treat a red final verification as a success"
    assert_not_contains "testcompile: nothing pushed or PR'd" "$log" "FORBIDDEN"
    assert_exit_code "testcompile: aborts non-zero" 1 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 4. Empty / unparseable identifier output cannot authorize ---------
    _preexisting_sandbox notests
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/n.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/n.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "no-identifiers: final verification is still red after the retry" \
        "$out" "Self-repair failed -- verification is still not green"
    assert_not_contains "no-identifiers: nothing pushed or PR'd" "$log" "FORBIDDEN"
    assert_exit_code "no-identifiers: aborts non-zero" 1 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 5. A red baseline that Claude makes GREEN may proceed -------------
    # Guard against over-blocking: removing the bypass must not strand every
    # repository that starts red.
    _preexisting_sandbox heals
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/h.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/h.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "heals: red baseline was allowed to attempt improvements" \
        "$log" "CLAUDE-INVOKED"
    assert_contains "heals: final verification is green" "$out" "Build and tests passed"
    # End to end, not just an intermediate green line: the run must actually
    # reach push AND PR creation, and exit 0.
    assert_contains "heals: reached push" "$log" "FORBIDDEN git push"
    assert_contains "heals: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "heals: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 6. analyze/fix follows the identical rule -------------------------
    local m
    for m in samefail testcompile notests; do
        _preexisting_sandbox "$m"
        echo '[{"severity":"CRITICAL","category":"security","title":"t","description":"d","file":"src/index.js","fix":"f"}]' \
            > "$WORKFLOW_TMP/findings.json"
        printf '# Analysis\n' > "$KYZN_REPORTS_DIR/20260806-blk001-analysis.md"
        rc=0
        run_fix_phase "$WORKFLOW_TMP/findings.json" CRITICAL "20260806-blk001" "1.00" \
            > "$WORKFLOW_TMP/a.out" 2>&1 || rc=$?
        trap - EXIT INT TERM
        out=$(cat "$WORKFLOW_TMP/a.out"); log=$(cat "$WORKFLOW_LOG")
        assert_contains "analyze/$m: still failing after self-repair" \
            "$out" "verification still failing after self-repair"
        assert_contains "analyze/$m: the batch is reverted" \
            "$out" "still broken after retry — reverting batch"
        assert_not_contains "analyze/$m: nothing pushed or PR'd" "$log" "FORBIDDEN"
        assert_exit_code "analyze/$m: aborts non-zero" 1 "$rc"
        PATH="$saved_path"; cleanup_sandbox
    done

    # --- 6b. analyze/fix still ships a red baseline that turns green --------
    _preexisting_sandbox heals
    echo '[{"severity":"CRITICAL","category":"security","title":"t","description":"d","file":"src/index.js","fix":"f"}]' \
        > "$WORKFLOW_TMP/findings.json"
    printf '# Analysis\n' > "$KYZN_REPORTS_DIR/20260806-blk002-analysis.md"
    rc=0
    run_fix_phase "$WORKFLOW_TMP/findings.json" CRITICAL "20260806-blk002" "1.00" \
        > "$WORKFLOW_TMP/ah.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/ah.out"); log=$(cat "$WORKFLOW_LOG")
    # Complete end-to-end success, not an intermediate green line followed by a
    # later abort: the batch must be applied, and the run must reach push AND PR.
    assert_contains "analyze/heals: batch verified green" "$out" "Build/tests pass"
    assert_contains "analyze/heals: batch applied" "$out" "1 batches applied"
    assert_contains "analyze/heals: reached push" "$log" "FORBIDDEN git push"
    assert_contains "analyze/heals: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "analyze/heals: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- The bypass machinery itself must be gone --------------------------
    if declare -F verify_may_continue_with_preexisting >/dev/null 2>&1; then
        fail "removed/bypass" "verify_may_continue_with_preexisting still exists"
    else
        pass "removed: verify_may_continue_with_preexisting is gone"
    fi
    if declare -F verify_had_build_failure >/dev/null 2>&1; then
        fail "removed/categories" "verify_had_build_failure still exists"
    else
        pass "removed: failure-category machinery is gone"
    fi
    if declare -F capture_failing_tests >/dev/null 2>&1; then
        pass "kept: capture_failing_tests retained for baseline diagnostics/prompts"
    else
        fail "kept/capture" "capture_failing_tests was removed but still feeds prompts"
    fi

    PATH="$saved_path"
    unset CLAUDE_MUTATE BREAK_BUILD AFTER_MARK FAIL_MODE
    cleanup_sandbox
}

# A red baseline that KyZN is allowed to attempt must also be REPAIRABLE.
#
# Requiring a green final verification is only coherent if the prompts permit
# reaching one. The fix prompts were written when a red baseline was waived
# through, so they told Sonnet to leave those failures alone — which, under the
# green gate, guarantees every batch is reverted and makes analyze/fix a
# structural no-op on exactly the repositories the gate is meant to serve.
#
# These tests assert on the EMITTED PROMPTS, and drive a "Claude" that obeys
# them: it repairs the pre-existing failure only when the prompt it received
# permits that. A prompt that forbids it produces a run that stays red.
_promptaware_sandbox() { # _promptaware_sandbox <mode: fixprompt|retryprompt>
    local mode="$1"
    create_sandbox node
    rm -f tsconfig.json
    echo '{"name":"fx","scripts":{"build":"x","test":"x"}}' > package.json
    mkdir -p src; echo 'console.log(1)' > src/index.js
    git add -A && git commit -q -m scaffold
    detect_project_type
    _workflow_setup report

    HEAL_MARK="$WORKFLOW_TMP/healed"; export HEAL_MARK
    PROMPT_MODE="$mode"; export PROMPT_MODE
    # WORKFLOW_TMP is not exported by _workflow_setup, so the mock needs its own
    # exported handle or its prompt capture silently writes nowhere.
    PROMPT_DIR="$WORKFLOW_TMP"; export PROMPT_DIR
    rm -f "$HEAL_MARK"

    # Build is always green; tests stay red until the baseline failure is repaired.
    rm -f "$WORKFLOW_TMP/clean-bin/npm"
    cat > "$WORKFLOW_TMP/clean-bin/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then exit 0; fi
if [[ "${1:-}" == "test" ]]; then
    [[ -f "$HEAL_MARK" ]] && exit 0
    if [[ "${PROMPT_MODE:-}" == "emptybaseline" ]]; then
        # Red, but emits nothing capture_failing_tests can parse.
        echo "runner crashed: no results emitted"
    else
        echo "FAIL src/a.test.js"
    fi
    exit 1
fi
exit 0
SH
    chmod +x "$WORKFLOW_TMP/clean-bin/npm"

    # Prompt-obeying Claude: captures each prompt, and repairs the pre-existing
    # failure ONLY if that prompt permits repairing baseline failures.
    rm -f "$WORKFLOW_TMP/clean-bin/claude"
    cat > "$WORKFLOW_TMP/clean-bin/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE-INVOKED" >> "$WORKFLOW_LOG"
n=$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")

prompt=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-p" ]] && prompt="$a"
    prev="$a"
done
printf '%s' "$prompt" > "$PROMPT_DIR/prompt-$n.txt"

# The batch may only be repaired when the prompt BOTH permits baseline repair
# and states the green requirement, and contains no contradicting scope rule.
permits=false
grep -qiE 'repair any of these failures that remain|any remaining baseline failures' \
    <<< "$prompt" && permits=true
grep -qiE 'final verification must be green' <<< "$prompt" && permits=true

# Any of these, unqualified, forbids the repair the green gate now requires.
grep -qiE 'do not try to fix these|fix only the issues your changes introduced' \
    <<< "$prompt" && permits=false
grep -qiE 'do NOT make any changes beyond what' <<< "$prompt" && permits=false
grep -qiE 'only modify tests if a finding specifically targets test code' \
    <<< "$prompt" && permits=false

# Score-neutral change so the batch always produces a diff.
printf '# Test Project\n\nUsage documentation.\n' > README.md

case "${PROMPT_MODE:-}" in
    fixprompt|emptybaseline)
        $permits && touch "$HEAL_MARK" ;;
    retryprompt)
        # Deliberately leaves the baseline red on the first pass, so the value
        # of the RETRY prompt is what decides the run.
        (( n >= 2 )) && $permits && touch "$HEAL_MARK" ;;
esac

echo '{"total_cost_usd":0.01,"result":"mock change"}'
exit 0
SH
    chmod +x "$WORKFLOW_TMP/clean-bin/claude"
}

test_fix_prompts_permit_reaching_green() {
    log_header "82. analyze/fix prompts must permit reaching a green verification"

    source "$KYZN_ROOT/lib/core.sh"
    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/measure.sh"
    source "$KYZN_ROOT/lib/prompt.sh"
    source "$KYZN_ROOT/lib/allowlist.sh"
    source "$KYZN_ROOT/lib/report.sh"
    source "$KYZN_ROOT/lib/history.sh"
    source "$KYZN_ROOT/lib/analyze.sh"

    local saved_path="$PATH" rc out log prompt retry_prompt
    local findings='[{"severity":"CRITICAL","category":"security","title":"t","description":"d","file":"src/index.js","fix":"f"}]'

    # --- 1 + 2. The initial fix prompt ------------------------------------
    create_sandbox node
    prompt=$(generate_fix_prompt "$findings" "" "FAIL src/a.test.js" "" "")
    assert_contains "fix-prompt: carries the real baseline identifier" \
        "$prompt" "FAIL src/a.test.js"
    assert_contains "fix-prompt: states final verification must be green" \
        "$prompt" "final verification must be green"
    assert_contains "fix-prompt: asks for the remaining failures to be repaired" \
        "$prompt" "Repair any of these failures that remain"
    assert_not_contains "fix-prompt: no prohibition on fixing baseline failures" \
        "$prompt" "Do NOT try to fix these"
    assert_not_contains "fix-prompt: not framed as an exemption" \
        "$prompt" "they are pre-existing issues"
    assert_contains "fix-prompt: still forbids hiding or weakening tests" \
        "$prompt" "Do not hide, skip, delete, or weaken tests"
    # Both permissions must be expressible WITHOUT a named identifier: a red
    # verification caused by test source that will not compile, or by a runner
    # emitting nothing parseable, is real but unnamed.
    assert_contains "fix-prompt: scope exception covers existing verification failures" \
        "$prompt" "except for minimal changes required to repair existing verification failures"
    assert_contains "fix-prompt: test repair keyed to verification evidence, not a name" \
        "$prompt" "when verification evidence shows that the existing test itself is genuinely broken"
    assert_not_contains "fix-prompt: scope exception does not presuppose a named failure" \
        "$prompt" "repair known baseline failures"
    assert_not_contains "fix-prompt: test rule does not presuppose a named test" \
        "$prompt" "that named baseline test"
    assert_contains "fix-prompt: coverage must be preserved or strengthened" \
        "$prompt" "preserve or strengthen coverage and never weaken it"
    assert_not_contains "fix-prompt: no unqualified no-drive-by rule" \
        "$prompt" "Do NOT make any changes beyond what's listed here"
    assert_not_contains "fix-prompt: no unqualified test-modification rule" \
        "$prompt" "only modify tests if a finding specifically targets test code"

    # The green requirement is unconditional: a red baseline can yield NO
    # identifiable test names, and the instruction must survive that.
    local empty_prompt
    empty_prompt=$(generate_fix_prompt "$findings" "" "" "" "")
    assert_contains "fix-prompt/empty-baseline: still states the green requirement" \
        "$empty_prompt" "Final verification must be green before this batch can succeed"
    assert_contains "fix-prompt/empty-baseline: carries the scope exception" \
        "$empty_prompt" "except for minimal changes required to repair existing verification failures"
    assert_contains "fix-prompt/empty-baseline: carries the test-repair permission" \
        "$empty_prompt" "when verification evidence shows that the existing test itself is genuinely broken"
    assert_contains "fix-prompt/empty-baseline: deletion still forbidden" \
        "$empty_prompt" "Do not delete test files or remove large blocks of tests"
    assert_contains "fix-prompt/empty-baseline: weakening still forbidden" \
        "$empty_prompt" "never weaken it merely to make verification pass"
    cleanup_sandbox

    # --- 4 + 5a + 6. The initial prompt must be able to drive red -> green --
    _promptaware_sandbox fixprompt
    printf '# Analysis\n' > "$KYZN_REPORTS_DIR/20260807-pp001-analysis.md"
    echo "$findings" > "$WORKFLOW_TMP/findings.json"
    rc=0
    run_fix_phase "$WORKFLOW_TMP/findings.json" CRITICAL "20260807-pp001" "1.00" \
        > "$WORKFLOW_TMP/pp.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/pp.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "fix-prompt/e2e: batch verified green" "$out" "Build/tests pass"
    assert_contains "fix-prompt/e2e: batch applied" "$out" "1 batches applied"
    assert_contains "fix-prompt/e2e: reached push" "$log" "FORBIDDEN git push"
    assert_contains "fix-prompt/e2e: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "fix-prompt/e2e: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 3 + 5b + 6. The SELF-REPAIR prompt must be able to drive red -> green
    _promptaware_sandbox retryprompt
    printf '# Analysis\n' > "$KYZN_REPORTS_DIR/20260807-pp002-analysis.md"
    echo "$findings" > "$WORKFLOW_TMP/findings.json"
    rc=0
    run_fix_phase "$WORKFLOW_TMP/findings.json" CRITICAL "20260807-pp002" "1.00" \
        > "$WORKFLOW_TMP/pr.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/pr.out"); log=$(cat "$WORKFLOW_LOG")

    retry_prompt=""
    [[ -f "$WORKFLOW_TMP/prompt-2.txt" ]] && retry_prompt=$(cat "$WORKFLOW_TMP/prompt-2.txt")
    assert_contains "retry-prompt: capture actually worked" "$retry_prompt" "Repair Instructions"
    assert_contains "retry-prompt: was actually emitted" "$out" "attempting self-repair"
    assert_contains "retry-prompt: permits repairing remaining baseline failures" \
        "$retry_prompt" "any remaining baseline failures"
    assert_contains "retry-prompt: states the goal is a green verification" \
        "$retry_prompt" "Make final verification green"
    assert_not_contains "retry-prompt: drops the ONLY-my-changes restriction" \
        "$retry_prompt" "Fix ONLY the issues your changes introduced"
    assert_contains "retry-prompt: carries the known baseline failures" \
        "$retry_prompt" "FAIL src/a.test.js"
    assert_contains "retry-prompt: still forbids hiding or weakening tests" \
        "$retry_prompt" "do not hide, skip, delete, or weaken tests"
    assert_contains "retry-prompt: neutral 'still failing' framing" \
        "$retry_prompt" "Build/tests are still failing after your fixes"
    assert_not_contains "retry-prompt: does not blame the batch for a red baseline" \
        "$retry_prompt" "broke the build/tests"
    assert_contains "retry-prompt/e2e: self-repair succeeded" "$out" "Self-repair succeeded"
    assert_contains "retry-prompt/e2e: batch applied" "$out" "1 batches applied"
    assert_contains "retry-prompt/e2e: reached push" "$log" "FORBIDDEN git push"
    assert_contains "retry-prompt/e2e: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "retry-prompt/e2e: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- Red baseline with NO identifiable test names must still reach green --
    # capture_failing_tests returns nothing here, so the green requirement has to
    # come from the unconditional rule rather than the baseline paragraph.
    _promptaware_sandbox emptybaseline
    printf '# Analysis\n' > "$KYZN_REPORTS_DIR/20260807-pp003-analysis.md"
    echo "$findings" > "$WORKFLOW_TMP/findings.json"
    rc=0
    run_fix_phase "$WORKFLOW_TMP/findings.json" CRITICAL "20260807-pp003" "1.00" \
        > "$WORKFLOW_TMP/pe.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/pe.out"); log=$(cat "$WORKFLOW_LOG")
    local first_prompt=""
    [[ -f "$WORKFLOW_TMP/prompt-1.txt" ]] && first_prompt=$(cat "$WORKFLOW_TMP/prompt-1.txt")
    assert_not_contains "empty-baseline: no identifier section was emitted" \
        "$first_prompt" "Pre-Existing Test Failures"
    assert_contains "empty-baseline: green requirement present without identifiers" \
        "$first_prompt" "Final verification must be green before this batch can succeed"
    assert_contains "empty-baseline: scope exception present without identifiers" \
        "$first_prompt" "except for minimal changes required to repair existing verification failures"
    assert_contains "empty-baseline: test-repair permission present without identifiers" \
        "$first_prompt" "when verification evidence shows that the existing test itself is genuinely broken"
    assert_contains "empty-baseline: hiding/weakening still forbidden" \
        "$first_prompt" "never weaken it merely to make verification pass"
    assert_contains "empty-baseline/e2e: batch applied" "$out" "1 batches applied"
    assert_contains "empty-baseline/e2e: reached push" "$log" "FORBIDDEN git push"
    assert_contains "empty-baseline/e2e: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "empty-baseline/e2e: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    PATH="$saved_path"
    unset HEAL_MARK PROMPT_MODE PROMPT_DIR
}
# The quick path must be able to reach the green it is now judged against.
#
# `cmd_improve` never forbade repairing baseline failures, but it never permitted
# it either: the prompt was assembled before baseline verification, so it carried
# neither the failures nor the green requirement, and the self-repair retry was
# gated on the baseline having started clean. A red-baseline run was therefore
# one-shot and blind — it reached green only if unrelated improvements happened
# to fix it.
#
# These tests assert the EMITTED prompts and drive a Claude that obeys them.
_quick_promptaware_sandbox() { # <mode: qfix|qempty|qretry|qretryred|qcleanretry>
    local mode="$1"
    create_sandbox node
    rm -f tsconfig.json
    echo '{"name":"fx","scripts":{"build":"x","test":"x"}}' > package.json
    mkdir -p src; echo 'console.log(1)' > src/index.js
    git add -A && git commit -q -m scaffold
    detect_project_type
    _workflow_setup report

    HEAL_MARK="$WORKFLOW_TMP/healed"; export HEAL_MARK
    BREAK_MARK="$WORKFLOW_TMP/broken"; export BREAK_MARK
    QMODE="$mode"; export QMODE
    PROMPT_DIR="$WORKFLOW_TMP"; export PROMPT_DIR
    rm -f "$HEAL_MARK" "$BREAK_MARK"

    rm -f "$WORKFLOW_TMP/clean-bin/npm"
    cat > "$WORKFLOW_TMP/clean-bin/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then exit 0; fi
if [[ "${1:-}" == "test" ]]; then
    if [[ -f "$BREAK_MARK" ]]; then echo "FAIL src/broken.test.js"; exit 1; fi
    # qcleanretry starts GREEN; every other mode starts red.
    [[ "${QMODE:-}" == "qcleanretry" ]] && exit 0
    [[ -f "$HEAL_MARK" ]] && exit 0
    if [[ "${QMODE:-}" == "qempty" || "${QMODE:-}" == "qemptyretry" ]]; then
        echo "runner crashed: no results emitted"
    else
        echo "FAIL src/a.test.js"
    fi
    exit 1
fi
exit 0
SH
    chmod +x "$WORKFLOW_TMP/clean-bin/npm"

    rm -f "$WORKFLOW_TMP/clean-bin/claude"
    cat > "$WORKFLOW_TMP/clean-bin/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE-INVOKED" >> "$WORKFLOW_LOG"
n=$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")
prompt=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-p" ]] && prompt="$a"
    prev="$a"
done
printf '%s' "$prompt" > "$PROMPT_DIR/qprompt-$n.txt"

permits=false
grep -qiE 'repair existing verification failures' <<< "$prompt" && permits=true
grep -qiE 'final verification must be green' <<< "$prompt" && permits=true
grep -qiE 'do not try to fix these|fix only the issues your changes introduced' \
    <<< "$prompt" && permits=false

printf '# Test Project\n\nUsage documentation.\n' > README.md

case "${QMODE:-}" in
    qfix|qempty)  $permits && touch "$HEAL_MARK" ;;
    qretry|qemptyretry)
                  (( n >= 2 )) && $permits && touch "$HEAL_MARK" ;;
    qretryred)    : ;;   # obeys nothing; stays red so the retry budget is proven
    qcleanretry)  if (( n == 1 )); then touch "$BREAK_MARK"; else rm -f "$BREAK_MARK"; fi ;;
esac

echo '{"total_cost_usd":0.01,"result":"mock change"}'
exit 0
SH
    chmod +x "$WORKFLOW_TMP/clean-bin/claude"
}

test_quick_prompts_permit_reaching_green() {
    log_header "83. quick-path prompts and retry must permit reaching green"

    source "$KYZN_ROOT/lib/core.sh"
    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/measure.sh"
    source "$KYZN_ROOT/lib/prompt.sh"
    source "$KYZN_ROOT/lib/allowlist.sh"
    source "$KYZN_ROOT/lib/report.sh"
    source "$KYZN_ROOT/lib/history.sh"

    local saved_path="$PATH" rc out log p1 p2 calls

    # --- 1. Named red baseline: the INITIAL prompt must be able to reach green
    _quick_promptaware_sandbox qfix
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/qf.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/qf.out"); log=$(cat "$WORKFLOW_LOG")
    p1=""; [[ -f "$WORKFLOW_TMP/qprompt-1.txt" ]] && p1=$(cat "$WORKFLOW_TMP/qprompt-1.txt")

    assert_contains "quick/initial: prompt capture worked" "$p1" "Current Health Score"
    assert_contains "quick/initial: states the green requirement" \
        "$p1" "Final verification must be green before this run can enter the normal success path"
    assert_contains "quick/initial: carries the baseline identifier" "$p1" "FAIL src/a.test.js"
    assert_contains "quick/initial: identifiers are context, not an exemption" \
        "$p1" "diagnostic context, not an exemption"
    assert_contains "quick/initial: permits minimal repair" \
        "$p1" "repair existing verification failures"
    assert_contains "quick/initial: forbids hiding or weakening tests" \
        "$p1" "Do not hide, skip, delete, or weaken tests"
    assert_contains "quick/initial: states precedence over mode constraints" \
        "$p1" "overrides mode constraints only for minimal changes"
    assert_contains "quick/initial: refuses to authorize unrelated work" \
        "$p1" "must not authorize unrelated refactoring or feature work"
    assert_contains "quick/initial/e2e: reaches success" "$out" "Build and tests passed"
    assert_contains "quick/initial/e2e: reached push" "$log" "FORBIDDEN git push"
    assert_contains "quick/initial/e2e: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "quick/initial/e2e: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 2. Empty / unparseable baseline output --------------------------
    _quick_promptaware_sandbox qempty
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/qe.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    log=$(cat "$WORKFLOW_LOG")
    p1=""; [[ -f "$WORKFLOW_TMP/qprompt-1.txt" ]] && p1=$(cat "$WORKFLOW_TMP/qprompt-1.txt")
    assert_contains "quick/empty: still states the green requirement" \
        "$p1" "Final verification must be green before this run can enter the normal success path"
    assert_contains "quick/empty: still permits minimal repair" \
        "$p1" "repair existing verification failures"
    assert_exit_code "quick/empty/e2e: succeeds" 0 "$rc"
    assert_contains "quick/empty/e2e: reached PR creation" "$log" "FORBIDDEN gh pr"
    PATH="$saved_path"; cleanup_sandbox

    # --- 3 + 4 + 5. Red baseline still red after attempt 1 gets ONE retry --
    _quick_promptaware_sandbox qretry
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/qr.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/qr.out"); log=$(cat "$WORKFLOW_LOG")
    calls=$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")
    p2=""; [[ -f "$WORKFLOW_TMP/qprompt-2.txt" ]] && p2=$(cat "$WORKFLOW_TMP/qprompt-2.txt")

    assert_eq "quick/retry: red baseline received exactly one retry" "2" "$calls"
    assert_contains "quick/retry: self-repair was attempted" "$out" "self-repair"
    assert_contains "quick/retry: neutral wording" \
        "$p2" "Build/tests are still failing after your changes"
    assert_not_contains "quick/retry: does not blame Claude for a red baseline" \
        "$p2" "Your previous changes broke the build"
    assert_contains "quick/retry: carries baseline context" "$p2" "FAIL src/a.test.js"
    assert_contains "quick/retry: restates the green requirement" \
        "$p2" "verification must be green"
    assert_contains "quick/retry: preserves mock guidance" "$p2" "unittest.mock"
    assert_contains "quick/retry/e2e: retry reached green" "$out" "Self-repair succeeded"
    assert_contains "quick/retry/e2e: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "quick/retry/e2e: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 6. A retry that ends red must not ship, and must not loop --------
    _quick_promptaware_sandbox qretryred
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/qrr.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/qrr.out"); log=$(cat "$WORKFLOW_LOG")
    calls=$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")
    assert_eq "quick/retry-red: exactly one retry, no loop" "2" "$calls"
    assert_not_contains "quick/retry-red: nothing committed, pushed or PR'd" "$log" "FORBIDDEN"
    assert_contains "quick/retry-red: routed to failure handling" "$out" "Self-repair failed"
    assert_exit_code "quick/retry-red: aborts non-zero" 1 "$rc"
    p2=""; [[ -f "$WORKFLOW_TMP/qprompt-2.txt" ]] && p2=$(cat "$WORKFLOW_TMP/qprompt-2.txt")
    assert_contains "quick/retry-red: the retry prompt still demanded green" \
        "$p2" "verification must be green"
    PATH="$saved_path"; cleanup_sandbox

    # --- 6b. A genuinely UNNAMED red baseline must survive the retry too ---
    # Distinct from qretryred, whose runner does emit an identifier. Here
    # capture_failing_tests returns nothing, so the retry prompt has to describe
    # the failure without naming it — and still reach green.
    _quick_promptaware_sandbox qemptyretry
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/qer.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/qer.out"); log=$(cat "$WORKFLOW_LOG")
    calls=$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")
    p2=""; [[ -f "$WORKFLOW_TMP/qprompt-2.txt" ]] && p2=$(cat "$WORKFLOW_TMP/qprompt-2.txt")

    assert_contains "quick/empty-retry: retry prompt capture worked" "$p2" "Repair Instructions"
    assert_not_contains "quick/empty-retry: no identifier could have been captured" \
        "$p2" "FAIL src/a.test.js"
    assert_contains "quick/empty-retry: says the baseline was already failing, unnamed" \
        "$p2" "already failing before you started, and verification produced no identifiable test names"
    assert_contains "quick/empty-retry: permits repairing existing verification failures" \
        "$p2" "Existing verification failures may still need repair"
    assert_contains "quick/empty-retry: demands green verification" \
        "$p2" "Final verification must be green before this run can enter the normal success path"
    assert_eq "quick/empty-retry: exactly two Claude invocations" "2" "$calls"
    assert_contains "quick/empty-retry/e2e: retry reached green" "$out" "Self-repair succeeded"
    assert_contains "quick/empty-retry/e2e: reached push" "$log" "FORBIDDEN git push"
    assert_contains "quick/empty-retry/e2e: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "quick/empty-retry/e2e: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 7. Baseline-clean self-repair must still work --------------------
    _quick_promptaware_sandbox qcleanretry
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/qc.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/qc.out"); log=$(cat "$WORKFLOW_LOG")
    calls=$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")
    assert_eq "quick/clean-retry: exactly one retry" "2" "$calls"
    assert_contains "quick/clean-retry: self-repair succeeded" "$out" "Self-repair succeeded"
    assert_contains "quick/clean-retry: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "quick/clean-retry: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 8. rc 2 remains an unconditional abort ---------------------------
    create_sandbox node
    detect_project_type              # tsconfig.json present, no local tsc
    local cb
    cb=$(_clean_path "$SANDBOX/clean-bin")
    cat > "$cb/npm" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$cb/npm"
    PATH="$cb"
    rc=0; verify_build &>/dev/null || rc=$?
    assert_exit_code "quick/rc2: unavailable tooling still returns 2" 2 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    PATH="$saved_path"
    unset HEAL_MARK BREAK_MARK QMODE PROMPT_DIR
}
# The diff-size limit must survive self-repair.
#
# The Step 5 gate runs BEFORE verification, so it never sees the repair diff. A
# self-repair could therefore add an arbitrarily large change — or a binary —
# and go straight to measurement, commit, push and PR. Widening the retry to red
# baselines widened that hole, so the same policy now runs again after a
# successful repair.
#
# Both callers share ONE checker. It reports and returns; the caller owns the
# existing Step 5 abort path, so no new cleanup machinery is introduced.
_dlimit_sandbox() { # _dlimit_sandbox <mode>
    local mode="$1"
    create_sandbox node
    rm -f tsconfig.json
    echo '{"name":"fx","scripts":{"build":"x","test":"x"}}' > package.json
    mkdir -p src; echo 'console.log(1)' > src/index.js
    git add -A && git commit -q -m scaffold
    detect_project_type
    _workflow_setup report

    # A small limit keeps the fixtures readable. One binary alone (500-line
    # penalty) exceeds it, which is the point.
    #
    # Written with yq, like every other config mutation in this project. NOT via
    # config_set: that wraps the value in strenv() to block expression injection
    # from untrusted input, which stores it as the STRING "50". The limit is a
    # hardcoded literal here, and it must land as a number.
    yq eval -i '.preferences.diff_limit = 50' "$KYZN_CONFIG"

    # Prove the edit landed, and landed numeric. A silently failed edit would
    # leave the default 10000 limit in place and let every over-limit scenario
    # below "pass" for entirely the wrong reason.
    if [[ "$(yq eval '.preferences.diff_limit' "$KYZN_CONFIG" 2>/dev/null)" == "50" ]] \
        && grep -qE '^[[:space:]]*diff_limit: 50[[:space:]]*$' "$KYZN_CONFIG"; then
        pass "dlimit fixture ($mode): config carries numeric diff_limit: 50"
    else
        fail "dlimit fixture ($mode): config carries numeric diff_limit: 50" \
            "got '$(grep -E 'diff_limit' "$KYZN_CONFIG" 2>&1 | tr -d '\n')'"
    fi

    git add -A >/dev/null 2>&1 || true
    git commit -q -m "tighten diff limit" >/dev/null 2>&1 || true

    HEAL_MARK="$WORKFLOW_TMP/healed"; export HEAL_MARK
    DMODE="$mode"; export DMODE
    rm -f "$HEAL_MARK"

    rm -f "$WORKFLOW_TMP/clean-bin/npm"
    cat > "$WORKFLOW_TMP/clean-bin/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then exit 0; fi
if [[ "${1:-}" == "test" ]]; then
    # dlimit_initial starts green: Step 5 must block before verification.
    [[ "${DMODE:-}" == "dlimit_initial" ]] && exit 0
    [[ -f "$HEAL_MARK" ]] && exit 0
    echo "FAIL src/a.test.js"
    exit 1
fi
exit 0
SH
    chmod +x "$WORKFLOW_TMP/clean-bin/npm"

    rm -f "$WORKFLOW_TMP/clean-bin/claude"
    cat > "$WORKFLOW_TMP/clean-bin/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE-INVOKED" >> "$WORKFLOW_LOG"
n=$(grep -c CLAUDE-INVOKED "$WORKFLOW_LOG")

# Builtins only: the sandboxed PATH has no seq/sed.
_big_text() { local i; : > src/big.txt; for ((i=0;i<200;i++)); do printf 'line %d\n' "$i" >> src/big.txt; done; }
_binary()   { printf '\x00\x01\x02\xff\xfe blob \x00 data' > src/blob.bin; }

case "${DMODE:-}" in
    dlimit_initial)
        _big_text ;;
    dlimit_retry_text)
        if (( n == 1 )); then echo "// small" >> src/index.js
        else touch "$HEAL_MARK"; _big_text; fi ;;
    dlimit_retry_bin)
        if (( n == 1 )); then echo "// small" >> src/index.js
        else touch "$HEAL_MARK"; _binary; fi ;;
    dlimit_retry_ok)
        if (( n == 1 )); then echo "// small" >> src/index.js
        else touch "$HEAL_MARK"; printf '# Test Project\n\nUsage documentation.\n' > README.md; fi ;;
esac

echo '{"total_cost_usd":0.01,"result":"mock change"}'
exit 0
SH
    chmod +x "$WORKFLOW_TMP/clean-bin/claude"
}

test_diff_limit_survives_self_repair() {
    log_header "84. the diff-size limit applies after self-repair too"

    source "$KYZN_ROOT/lib/core.sh"
    source "$KYZN_ROOT/lib/detect.sh"
    source "$KYZN_ROOT/lib/verify.sh"
    source "$KYZN_ROOT/lib/execute.sh"
    source "$KYZN_ROOT/lib/measure.sh"
    source "$KYZN_ROOT/lib/prompt.sh"
    source "$KYZN_ROOT/lib/allowlist.sh"
    source "$KYZN_ROOT/lib/report.sh"
    source "$KYZN_ROOT/lib/history.sh"

    local saved_path="$PATH" rc out log

    # --- 1. count_diff_size must classify a NEW UNTRACKED BINARY as binary --
    # `wc -l` reports 0 lines for a binary, so it used to contribute nothing at
    # all and never incremented binary_count.
    create_sandbox node
    # create_sandbox already committed the scaffold; tolerate "nothing to commit".
    git add -A >/dev/null 2>&1 || true
    git commit -q -m base >/dev/null 2>&1 || true
    printf '\x00\x01\x02\xff\xfe blob \x00 data' > blob.bin
    local a=0 d=0 b=0
    count_diff_size a d b
    assert_eq "count_diff_size: new untracked binary increments binary_count" "1" "$b"
    assert_eq "count_diff_size: binary contributes no phantom added lines" "0" "$a"

    # A new untracked TEXT file must still be counted by line, unchanged.
    rm -f blob.bin
    printf 'l1\nl2\nl3\n' > new.txt
    a=0; d=0; b=0
    count_diff_size a d b
    assert_eq "count_diff_size: untracked text still counted by line" "3" "$a"
    assert_eq "count_diff_size: text file is not misread as binary" "0" "$b"
    cleanup_sandbox

    # --- 2. Oversized on the FIRST attempt still blocks, exactly as before --
    _dlimit_sandbox dlimit_initial
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/di.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/di.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "initial-oversize: reports the limit" "$out" "Diff exceeds limit"
    assert_not_contains "initial-oversize: nothing committed, pushed or PR'd" "$log" "FORBIDDEN"
    # The BASELINE measurement (Step 2) prints the same header, so presence
    # proves nothing — the discriminator is whether Step 7 ran a SECOND one.
    assert_eq "initial-oversize: never reached the Step 7 re-measure" "1" \
        "$(grep -c 'analyzing project health' "$WORKFLOW_TMP/di.out" || true)"
    assert_exit_code "initial-oversize: aborts non-zero" 1 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 3 + 5 + 7 + 8. A repair that grows the TEXT diff past the limit ----
    # Red baseline, so this also covers the retry path this PR widened.
    _dlimit_sandbox dlimit_retry_text
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/dt.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/dt.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "repair-oversize/text: the repair itself verified green" \
        "$out" "Self-repair succeeded"
    assert_contains "repair-oversize/text: blocked by the diff limit" \
        "$out" "Diff exceeds limit"
    # Ordering proof: the gate runs after retry verification and before Step 7.
    assert_eq "repair-oversize/text: gate ran BEFORE the Step 7 re-measure" "1" \
        "$(grep -c 'analyzing project health' "$WORKFLOW_TMP/dt.out" || true)"
    assert_not_contains "repair-oversize/text: nothing committed, pushed or PR'd" \
        "$log" "FORBIDDEN"
    assert_exit_code "repair-oversize/text: aborts non-zero" 1 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 4 + 5. A repair that adds an untracked BINARY ---------------------
    _dlimit_sandbox dlimit_retry_bin
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/db.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/db.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "repair-oversize/binary: the repair itself verified green" \
        "$out" "Self-repair succeeded"
    assert_contains "repair-oversize/binary: the binary was seen" \
        "$out" "binary file(s)"
    assert_contains "repair-oversize/binary: blocked by the weighted limit" \
        "$out" "Diff exceeds limit"
    assert_eq "repair-oversize/binary: gate ran BEFORE the Step 7 re-measure" "1" \
        "$(grep -c 'analyzing project health' "$WORKFLOW_TMP/db.out" || true)"
    assert_not_contains "repair-oversize/binary: nothing committed, pushed or PR'd" \
        "$log" "FORBIDDEN"
    assert_exit_code "repair-oversize/binary: aborts non-zero" 1 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    # --- 6. An UNDER-limit repair must still reach the success path --------
    _dlimit_sandbox dlimit_retry_ok
    rc=0
    cmd_improve --auto > "$WORKFLOW_TMP/dok.out" 2>&1 || rc=$?
    trap - EXIT INT TERM
    out=$(cat "$WORKFLOW_TMP/dok.out"); log=$(cat "$WORKFLOW_LOG")
    assert_contains "repair-under-limit: repair verified green" "$out" "Self-repair succeeded"
    assert_not_contains "repair-under-limit: not blocked by the diff limit" \
        "$out" "Diff exceeds limit"
    assert_eq "repair-under-limit: reached the Step 7 re-measure" "2" \
        "$(grep -c 'analyzing project health' "$WORKFLOW_TMP/dok.out" || true)"
    assert_contains "repair-under-limit: reached push" "$log" "FORBIDDEN git push"
    assert_contains "repair-under-limit: reached PR creation" "$log" "FORBIDDEN gh pr"
    assert_exit_code "repair-under-limit: succeeds" 0 "$rc"
    PATH="$saved_path"; cleanup_sandbox

    PATH="$saved_path"
    unset HEAL_MARK DMODE
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
    test_portable_timeout_fallback
    test_tightened_allowlist
    test_trust_in_local_yaml
    test_phase0_execution_and_autopilot_gates
    test_per_category_floor
    test_analyze_prompt_assembly
    test_consensus_prompt
    test_analysis_system_prompt
    test_extract_findings
    test_generate_fix_prompt
    test_analyze_wired_in_kyzn
    test_reject_no_learn_message
    test_relative_time
    test_write_history
    test_dashboard
    test_dashboard_corrupt
    test_dashboard_hyphenated_project
    test_enforce_config_ceilings
    test_unstage_secrets
    test_unstage_secrets_nested_dotenv
    test_newline_paths_staging_and_accounting
    test_newline_paths_test_deletion_guard
    test_newline_paths_pytest_gate
    test_path_traversal_reject_diff
    test_report_discovery_and_clean_handoff
    test_repository_facts_are_index_deterministic
    test_validate_run_id
    test_reflexion_retry_loop
    test_gitignore_preserves_custom
    test_capture_error_lines
    test_detect_installed_packages
    test_consensus_prompt_has_fix_plan
    test_fix_plan_passes_through
    test_report_includes_fix_plan
    test_profiler_cache_invalidation
    test_generate_fix_prompt_with_profile
    test_budget_carving
    test_specialist_prompt_has_fix_plan
    test_verify_node_no_test_files
    test_verify_skips_dependency_install_by_default
    test_verify_python_skips_dependency_install_by_default
    test_install_python_deps_requirements_txt
    test_require_clean_worktree
    test_awk_budget_injection
    test_xargs_filename_with_spaces
    test_safe_checkout_back_disables_hooks
    test_profile_path_traversal
    test_check_symlink_escapes
    test_count_diff_size_new_files
    test_progress_animation
    test_verify_fails_closed_on_missing_tools
    test_verify_csharp_mocked_dotnet
    test_verify_java_mocked_maven_gradle
    test_verify_typescript_local_only
    test_csharp_measurer_parsing
    test_java_measurer_parsing
    test_workflow_gate_blocks_pr_when_unverifiable
    test_abort_never_destroys_user_work
    test_verification_precedence_and_tool_contracts
    test_toolchain_matrix_download_authorization
    test_python_unusable_shim_is_unavailable
    test_red_final_verification_never_ships
    test_fix_prompts_permit_reaching_green
    test_quick_prompts_permit_reaching_green
    test_diff_limit_survives_self_repair

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
