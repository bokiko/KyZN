# Kraken Implementation Quality & TDD Audit Report

**Project:** KyZN -- Autonomous Code Improvement CLI
**Date:** 2026-03-20
**Auditor:** Kraken (Implementation Agent)
**Status:** DONE

---

## Executive Summary

KyZN has a solid test suite with 187 passing tests across 51 test functions, covering approximately 55% of the 84 source functions. The tests are well-structured with a custom framework (assert_eq, assert_contains, etc.) and use sandbox environments for isolation. However, significant gaps exist in testing critical paths -- particularly the functions that actually invoke Claude, create PRs, modify git state, and execute complex multi-agent orchestration. The tests almost exclusively verify pure logic and string matching; they never mock external commands (claude, gh, git push), which means the most dangerous code paths are completely untested.

---

## 1. Test Coverage Analysis

### 1.1 Function Inventory

Total source functions: **84**
Total test functions: **51** (48 regular + 4 stress)
Functions with direct test coverage: **~46** (55%)
Functions with NO test coverage: **~38** (45%)

### 1.2 Covered Functions (with test quality assessment)

| Function | Test(s) | Quality |
|----------|---------|---------|
| `generate_run_id` | test_core, test_stress_rapid_ids | GOOD -- checks format, uniqueness, collision under stress |
| `truncate_str` | test_core | GOOD -- tests both truncation and no-op paths |
| `timestamp` | test_core | ADEQUATE -- checks format only |
| `prompt_input` | test_prompt_stderr | GOOD -- tests value capture and default behavior |
| `prompt_choice` | test_prompt_stderr | GOOD -- tests return value, stdout purity, default |
| `prompt_yn` | test_prompt_yn | GOOD -- tests y, n, default-y, default-n |
| `detect_project_type` | test_detect, test_rust_workspace_detection | GOOD -- all 5 types plus workspace edge case |
| `detect_project_features` | test_detect | ADEQUATE -- only tests node features |
| `config_get` | test_config | GOOD -- tests read, write, default for missing |
| `config_set` / `config_set_str` | test_config | ADEQUATE -- tests roundtrip |
| `local_config_get` | test_trust_in_local_yaml | ADEQUATE -- tests one value |
| `has_config` | test_config | ADEQUATE -- tests initial absence |
| `run_interview` | test_interview_config | GOOD -- verifies config output is clean |
| `save_interview_config` | test_interview_config | GOOD -- checks no menu text leaks into config |
| `setup_kyzn_gitignore` | test_trust_in_local_yaml | ADEQUATE -- checks local.yaml in .gitignore |
| `run_measurements` | test_measure | ADEQUATE -- verifies file created and valid JSON |
| `compute_health_score` | test_health_score_edge_cases, test_score_regression_gate | GOOD -- empty, 0%, 100%, regression |
| `display_health_dashboard` | (indirectly via test_measure) | WEAK -- only verifies it doesn't crash |
| `build_allowlist` | test_allowlist, test_allowlist_rust_go, test_tightened_allowlist | EXCELLENT -- all 5 types, negative assertions |
| `assemble_prompt` | test_deep_mode_constraints, test_clean_full_mode_constraints | GOOD -- all 3 modes |
| `get_system_prompt` | test_get_system_prompt | GOOD -- no profile, valid profile, invalid profile |
| `cmd_doctor` | test_doctor | ADEQUATE -- verifies output contains tool names |
| `handle_build_failure` | test_branch_cleanup_in_failure, test_build_failure_report_strategy | GOOD -- tests discard and report strategies |
| `verify_build` | test_verify_build_generic, test_verify_build_dispatch | GOOD -- generic pass, node dispatch failure |
| `cmd_approve` | test_approve_reject, test_approve_missing_report | GOOD -- success, missing report edge case |
| `cmd_reject` | test_approve_reject | GOOD -- with reason |
| `check_dangerous_files` | test_ci_blocking | GOOD -- tests both blocked and allowed paths |
| `build_specialist_prompt` | test_analyze_prompt_assembly | GOOD -- all 4 specialists |
| `build_consensus_prompt` | test_consensus_prompt | ADEQUATE -- checks section headers |
| `extract_findings` | test_extract_findings | ADEQUATE -- one path only |
| `generate_fix_prompt` | test_generate_fix_prompt | GOOD -- severity filtering |
| `relative_time` | test_relative_time | GOOD -- now, minutes, hours, days, empty, null |
| `write_history` | test_write_history | GOOD -- dual write, field values, empty field filtering |
| `cmd_dashboard` | test_dashboard, test_dashboard_corrupt, test_dashboard_hyphenated_project | GOOD -- normal, corrupt files, hyphenated names |

### 1.3 Functions With NO Test Coverage

These are ranked by risk/criticality:

#### CRITICAL -- External integration points (never tested)

| Function | File | Risk | Why It Matters |
|----------|------|------|----------------|
| `execute_claude` | execute.sh | **CRITICAL** | Core function that invokes Claude CLI. Builds command line, handles timeout, parses JSON response, sets global state. Zero test coverage. |
| `run_specialist` | analyze.sh | **CRITICAL** | Invokes Claude for each specialist agent. Similar complexity to execute_claude. |
| `run_fix_phase` | analyze.sh | **HIGH** | Creates branches, invokes Claude, commits, handles failure. Complex orchestration. |
| `generate_report` | report.sh | **HIGH** | Stages files, computes scores, writes markdown, creates git commits, pushes, creates PRs via gh. All untested. |
| `cmd_improve` | execute.sh | **HIGH** | The main improvement pipeline. 528 lines of orchestration including lock acquisition, branch creation, Claude invocation, diff checking, verification, score regression gates, cleanup. Zero test coverage. |
| `cmd_analyze` | analyze.sh | **HIGH** | 450+ lines of multi-agent orchestration with parallel processes, progress monitoring, consensus merge. Zero test coverage. |

#### HIGH -- Git and file system operations

| Function | File | Risk |
|----------|------|------|
| `safe_git` | execute.sh | HIGH -- disables git hooks, security-relevant |
| `unstage_secrets` | execute.sh | HIGH -- security guard, untested |
| `safe_checkout_back` | execute.sh | MEDIUM -- fallback chain logic |
| `enforce_config_ceilings` | execute.sh | HIGH -- uses `eval` for variable indirection |
| `schedule_cron` / `remove_cron` | schedule.sh | MEDIUM -- modifies user's crontab |
| `cmd_schedule` | schedule.sh | MEDIUM -- routing logic |
| `check_for_updates` | kyzn | LOW -- non-critical update check |

#### MEDIUM -- Display and helper functions

| Function | File | Risk |
|----------|------|------|
| `display_findings` | analyze.sh | LOW -- display only |
| `generate_detailed_report` | analyze.sh | LOW -- markdown generation |
| `generate_pr_body` | report.sh | LOW -- string template |
| `generate_category_comparison` | report.sh | LOW -- (partially tested via test_report_arithmetic) |
| `cmd_history` | history.sh | LOW -- read-only display |
| `cmd_diff` | history.sh | LOW -- read-only |
| `cmd_status` | history.sh | LOW -- composition of tested functions |
| `cmd_init` | interview.sh | LOW -- thin wrapper |
| `cmd_measure` | measure.sh | LOW -- thin wrapper |
| `project_type_name` | detect.sh | LOW -- string map |
| `print_detection` | detect.sh | LOW -- display only |
| `check_missing_tooling` | interview.sh | LOW -- advisory output |
| `run_measurer` | measure.sh | MEDIUM -- JSON merging logic |

#### Measurer Scripts (standalone executables)

| Script | Coverage |
|--------|----------|
| `measurers/generic.sh` | INDIRECT via test_measure (runs in sandbox but output not inspected) |
| `measurers/python.sh` | NOT TESTED (skipped unless python tools present) |
| `measurers/node.sh` | NOT TESTED |
| `measurers/go.sh` | NOT TESTED |
| `measurers/rust.sh` | NOT TESTED |

---

## 2. Test Quality Assessment

### 2.1 Strengths

1. **Sandbox isolation is excellent.** Every test that touches the filesystem uses `create_sandbox` which creates a temp directory, initializes a git repo, and scaffolds a project. `cleanup_sandbox` removes it. This prevents test pollution of the real repo.

2. **Assertion helpers are clear and informative.** `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_file_exists`, `assert_exit_code` all produce good failure messages.

3. **Negative assertions are used effectively.** The allowlist tests verify that overly broad wildcards are NOT present, not just that specific tools exist. This catches regression if someone loosens the allowlist.

4. **Edge cases are tested where present.** Health score edge cases (empty, 0%, 100%), config overwrite stress test, corrupt dashboard files, hyphenated project names -- these show awareness of boundary conditions.

5. **Tests verify behavior, not just existence.** Most tests check actual return values and output content, not just "did the function run without crashing."

6. **Stress tests exist.** 100 rapid ID generation, 10x measurement determinism, all project types, config overwrite cycles -- good for catching intermittent issues.

### 2.2 Weaknesses

1. **No mocking at all.** The most critical functions (`execute_claude`, `run_specialist`, `generate_report`, `cmd_improve`, `cmd_analyze`) invoke external commands (`claude`, `gh`, `git push`). None of these are mocked. The tests simply skip these functions entirely, leaving the most complex and dangerous code completely untested.

2. **Source code inspection as a test.** Tests 31, 33, and 43 read source files and grep for strings like `disallowedFileGlobs` or `timeout`. This verifies the string exists in code, not that it actually works. If someone moves the string to a comment, the test still passes but the feature is broken.

3. **Measurer output not validated.** `test_measure` runs `run_measurements` and checks that a JSON file was created and the health score is in range, but never inspects the measurement array to verify individual measurements were computed correctly.

4. **Interview tests only test one path.** Only "everything/auto" mode is tested. The specific goals branch, security depth, testing depth, performance depth, and multiple areas paths are all untested.

5. **No test for the `install.sh` script.** The installer has complex logic (OS detection, package manager detection, checksum verification, symlink handling) with zero test coverage.

6. **Missing test numbering.** Test 37 is skipped in the numbering (goes from 36 to 38). This suggests test 37 was removed but others weren't renumbered.

### 2.3 Test Isolation

**Rating: GOOD**

- Each test uses its own sandbox (temp directory with git repo).
- `cleanup_sandbox` is called at the end of each test.
- Dashboard tests clean up their global history entries.
- The test framework uses global counters (`TESTS_PASSED`, `TESTS_FAILED`) which is standard for a custom framework.

**One concern:** Tests that source library files (`source "$KYZN_ROOT/lib/detect.sh"`) do so at the test function level, and functions defined in those libraries persist for the rest of the test run. This is fine for the current test order but could cause hidden dependencies if tests are reordered. For example, `test_verify_build_dispatch` relies on `detect_project_type` being available from a previous source statement (though it does source detect.sh at the start of test_detect, which runs earlier).

### 2.4 Test Determinism

**Rating: GOOD**

- Stress test S2 explicitly verifies measurement determinism (10 identical runs).
- Tests use temp directories with unique names.
- No reliance on network, clock, or random state (except `generate_run_id` which uses /dev/urandom, but that is tested for uniqueness rather than specific values).

---

## 3. Mocking Gaps Analysis

### 3.1 Is It OK That Tests Mock Nothing?

**No.** For a tool that autonomously modifies git repositories, invokes paid AI APIs, creates PRs on GitHub, and modifies user crontabs, the complete absence of mocking is a significant gap.

The current test suite validates all the "leaf" functions (string manipulation, config parsing, scoring arithmetic, prompt assembly) but none of the "trunk" functions that orchestrate these into dangerous workflows.

### 3.2 What Should Be Mocked

| External Command | Where Used | What to Mock |
|-----------------|------------|--------------|
| `claude` | execute_claude, run_specialist | Stub that returns canned JSON response |
| `gh pr create` | generate_report, run_fix_phase | Stub that returns a fake PR URL |
| `git push` | generate_report, run_fix_phase | No-op or return success |
| `npm test/build`, `pytest`, `cargo test`, `go test` | verify_build | Controllable exit codes |
| `crontab` | schedule_cron, remove_cron | Capture input, return success |
| `timeout` | execute_claude | Pass-through to the actual command |

### 3.3 How to Mock in Bash

The standard pattern for bash mocking is function overriding:

```bash
# Override external command
claude() {
    echo '{"total_cost_usd": 0.50, "session_id": "test", "stop_reason": "end_turn", "result": "done"}'
}
export -f claude

# Override git push to no-op
git() {
    if [[ "$1" == "push" ]]; then echo "mock: git push skipped"; return 0; fi
    command git "$@"
}
```

This approach would allow testing the orchestration logic of `cmd_improve` and `cmd_analyze` without spending money or touching remote repos.

---

## 4. Testability Assessment

### 4.1 Functions Well-Designed for Testing

- **Pure functions with clear inputs/outputs:** `truncate_str`, `generate_run_id`, `timestamp`, `config_get`, `build_allowlist`, `assemble_prompt`, `compute_health_score`, `relative_time`, `build_specialist_prompt`, `extract_findings`, `generate_fix_prompt`.

- **Functions with side effects limited to filesystem:** `write_history`, `save_interview_config`, `handle_build_failure` (discard/report modes).

### 4.2 Functions Hard to Test

1. **`execute_claude` (execute.sh:90-183)** -- Tightly coupled to the `claude` CLI. Builds a complex command with multiple flags, captures stdout while tee-ing stderr, parses JSON, sets multiple global variables (`KYZN_CLAUDE_RESULT`, `KYZN_CLAUDE_COST`, `KYZN_CLAUDE_SESSION`, `KYZN_CLAUDE_STOP_REASON`). Could be improved by:
   - Extracting the command construction into a separate function that returns the command array
   - Accepting the claude command as a parameter or environment variable

2. **`cmd_improve` (execute.sh:188-528)** -- Monolithic 340-line function that does everything: arg parsing, detection, interview, measurement, branch creation, prompt assembly, Claude invocation, diff checking, verification, re-measurement, score regression gate, report generation, history writing, cleanup. Should be decomposed.

3. **`cmd_analyze` (analyze.sh:467-923)** -- Similar monolith at 456 lines. Includes inline bash process management with parallel PIDs, spinner animation, progress monitoring. The process management code is tightly coupled to the terminal display.

4. **`enforce_config_ceilings` (execute.sh:52-75)** -- Uses `eval` for variable indirection. While functional, this makes the function difficult to test in isolation because it mutates variables by name.

### 4.3 Global State Dependencies

The following global variables are set by various functions and read by others, creating implicit coupling:

| Variable | Set By | Read By |
|----------|--------|---------|
| `KYZN_PROJECT_TYPE` | `detect_project_type` | ~15 functions |
| `KYZN_PROJECT_TYPES` | `detect_project_type` | `print_detection` |
| `KYZN_HAS_*` | `detect_project_features` | `print_detection`, `check_missing_tooling` |
| `KYZN_HEALTH_SCORE` | `compute_health_score` | ~10 functions |
| `KYZN_CATEGORY_SCORES` | `compute_health_score` | `display_health_dashboard`, `cmd_measure` |
| `KYZN_MEASUREMENTS_FILE` | `run_measurements` | ~5 functions |
| `KYZN_CLAUDE_RESULT` | `execute_claude` | (stored but not read elsewhere) |
| `KYZN_CLAUDE_COST` | `execute_claude` | `handle_build_failure`, `generate_report` |
| `KYZN_CLAUDE_SESSION` | `execute_claude` | (stored but not read) |
| `KYZN_CLAUDE_STOP_REASON` | `execute_claude` | (stored but not read) |

**Finding:** `KYZN_CLAUDE_RESULT`, `KYZN_CLAUDE_SESSION`, and `KYZN_CLAUDE_STOP_REASON` are set by `execute_claude` but never consumed by any other function. This is dead state.

---

## 5. Regression Coverage

### 5.1 Known Bugs That Have Test Coverage

Based on test names and comments:

- **Report arithmetic errors** (test_report_arithmetic) -- Regression test for float-to-int conversion bugs in category comparison.
- **Score regression gate** (test_score_regression_gate) -- Verifies the gate that prevents deploying code that makes scores worse.
- **Per-category score floor** (test_per_category_floor) -- Prevents one category from dropping more than 5 points even if aggregate improves.
- **Branch cleanup on failure** (test_branch_cleanup_in_failure, test_build_failure_report_strategy) -- Ensures orphan branches are deleted on failure.
- **Menu text leaking into config** (test_interview_config) -- Regression for prompt text ending up in YAML config.
- **Trust in local.yaml** (test_trust_in_local_yaml) -- Regression for trust setting leaking into committed config.
- **Reject message wording** (test_reject_no_learn_message) -- Ensures no "will learn" false promise in rejection output.

### 5.2 Likely Past Bugs Without Regression Tests

Based on code complexity and defensive checks that suggest past issues:

1. **Stale lock detection** (execute.sh:194-207) -- Complex lock with PID check suggests past deadlock issues. No test.
2. **Binary file detection in diffs** (execute.sh:415-419) -- Penalizes binary files with 500-line weight. No test.
3. **Pre-existing test failure comparison** (execute.sh:377-466) -- Complex logic to distinguish new failures from pre-existing ones. No test.
4. **Snap yq incompatibility** (install.sh:138-142) -- Specific workaround for snap yq not accessing hidden dirs. No test.
5. **Symlink loop detection** (kyzn:20-29) -- Max depth 20 with error message. No test for the loop case.
6. **Legacy dashboard entries** (history.sh:149-177) -- Fallback parsing for old-format files. No test for legacy format.

---

## 6. Edge Case Testing

### 6.1 Edge Cases That ARE Tested

- Empty measurements array (score = 0)
- Single category at 100% (score = 100)
- Single category at 0% (score = 0)
- Empty string input to prompt_input (uses default)
- Invalid choice number to prompt_choice (uses default)
- Corrupt/empty JSON files in dashboard
- Hyphenated project names in dashboard
- Rust workspace with Cargo.toml in subdirectory
- Run ID uniqueness under rapid generation (100 IDs)
- Config validity after 5 consecutive overwrites
- Missing report for approve command
- Empty/null timestamps in relative_time
- Empty history fields filtered from JSON

### 6.2 Edge Cases That Are NOT Tested

| Edge Case | Function | Risk |
|-----------|----------|------|
| Budget of 0 or negative number | `enforce_config_ceilings` | MEDIUM -- could pass validation |
| Budget with non-numeric input ("abc") | `cmd_improve` arg parsing | MEDIUM -- awk may produce unexpected result |
| Focus string with special characters (spaces, quotes, slashes) | `cmd_improve` branch naming | HIGH -- `safe_focus` sanitization is untested |
| Very long project name (>200 chars) | `generate_report`, `cmd_dashboard` | LOW -- may break formatting |
| Config file with malicious YAML (command injection via yq) | `config_get`, `config_set` | HIGH -- yq processes untrusted input |
| Concurrent `kyzn improve` on same repo | Lock mechanism | MEDIUM -- stale lock detection untested |
| Git repo with no commits | `require_git_repo` | LOW -- would fail early |
| Run ID with path traversal characters | `cmd_approve` | LOW -- has explicit check but test only verifies rejection |
| Measurements file with NaN or Infinity scores | `compute_health_score` | MEDIUM -- jq may produce unexpected output |
| Claude returning non-JSON (HTML error page) | `execute_claude` | HIGH -- JSON extraction would fail |
| Network timeout during git push | `generate_report` | MEDIUM -- error handling path untested |
| Empty diff after Claude runs | `cmd_improve` step 5 | LOW -- would create empty commit |
| All specialists fail in parallel analysis | `cmd_analyze` | MEDIUM -- has `any_failed` flag but untested |

---

## 7. Error Path Testing

### 7.1 Error Paths That ARE Tested

- Unknown command (exits 1 with message)
- Approve without report (exits 1)
- Verify build with failing tests (returns non-zero)

### 7.2 Error Paths That Are NOT Tested

| Error Path | Function | Description |
|------------|----------|-------------|
| Missing git repo | `require_git_repo` | Should exit 1 with message |
| Claude timeout (exit 124) | `execute_claude` | Has specific handling but untested |
| Claude invalid JSON response | `execute_claude` | Returns 1 but path untested |
| Branch creation failure | `cmd_improve` | Has error handling but untested |
| Lock acquisition failure | `cmd_improve` | Concurrent access error untested |
| Git push failure | `generate_report` | Warns but continues -- untested |
| PR creation failure | `generate_report` | Warns but continues -- untested |
| Diff exceeds limit | `cmd_improve` | Aborts with warning -- untested |
| Measurer returns invalid JSON | `run_measurer` | Silent fallback -- untested |
| `yq` not installed | `config_get`, `config_set` | Would fail silently or crash |
| Fix phase timeout | `run_fix_phase` | Has handling but untested |
| All 4 specialists timeout | `cmd_analyze` | Would use empty findings -- untested |
| `crontab` command fails | `schedule_cron` | Would silently fail |

---

## 8. Integration Gaps

### 8.1 Missing Integration Scenarios

1. **End-to-end `improve` with mocked Claude** -- The highest-value missing test. Mock `claude` to return a canned JSON response, verify the full pipeline: detect -> measure -> branch -> prompt -> execute -> verify -> score gate -> report -> PR.

2. **End-to-end `analyze` with mocked Claude** -- Mock `claude` to return canned findings, verify: parallel specialist dispatch -> consensus merge -> report generation -> optional fix phase.

3. **Config poisoning via `.kyzn/config.yaml`** -- Verify that `enforce_config_ceilings` actually caps values when config has budget=999, turns=999, diff_limit=99999.

4. **Secret unstaging integration** -- Create a sandbox with `.env` file staged, run `unstage_secrets`, verify it's no longer staged.

5. **Cron integration** -- Verify `schedule_cron` adds correct entry to crontab output, `remove_cron` removes only the matching project's entry.

6. **Measurer output structure** -- Run each measurer in a sandbox and verify the JSON schema: category, score, max_score, details, tool fields are all present and correctly typed.

7. **Multi-type project detection** -- Create a sandbox with both `package.json` AND `pyproject.toml`, verify primary type is node and KYZN_PROJECT_TYPES contains both.

---

## 9. Test Maintenance Burden

### 9.1 Brittleness Assessment

**Rating: LOW-MEDIUM (mostly robust)**

- **Robust:** Tests use `assert_contains` rather than exact string matching for most output checks. This tolerates formatting changes.
- **Robust:** Sandbox-based tests are self-contained and don't depend on the host environment's project state.
- **Somewhat brittle:** Tests 31, 33, and 43 grep the source code for specific strings. These break if the code is refactored even if behavior is preserved.
- **Somewhat brittle:** Dashboard test creates entries in the global `~/.kyzn/history/` directory. If cleanup fails (test interrupted by Ctrl+C), leftover files could affect future test runs.
- **Robust:** The test framework itself is simple and unlikely to need changes.

### 9.2 Test Run Time

With `--full` flag: 7 seconds for 187 tests. This is fast and encourages frequent execution.

### 9.3 Test Dependencies

The test suite requires: bash 4.3+, git, jq, yq. It does NOT require: claude, gh, npm, python, cargo, go. This is good -- the core tests can run without expensive or complex dependencies.

---

## 10. Recommendations (Ordered by Impact)

### 10.1 HIGH IMPACT -- New Tests to Add

#### R1: Mock-based integration test for `cmd_improve`

Create a mock `claude` command that returns valid JSON, then run the improve pipeline end-to-end. This single test would cover: lock acquisition, detection, measurement, branch creation, prompt assembly, Claude invocation, diff checking, verification, score comparison, report generation, and cleanup.

```bash
test_improve_mocked() {
    create_sandbox generic

    # Mock claude to return valid JSON
    claude() {
        echo '{"total_cost_usd":0.01,"session_id":"mock","stop_reason":"end_turn","result":"no changes needed"}'
    }
    export -f claude

    # Mock gh to no-op
    gh() { echo "https://github.com/test/test/pull/1"; }
    export -f gh

    # Setup config
    echo -e "1\n1\n2.50\n1\n1" | run_interview 2>/dev/null

    # Run improve in auto mode
    cmd_improve --auto --model sonnet 2>/dev/null
    # Verify cleanup, no orphan branches, history written
}
```

Estimated coverage gain: +15-20 functions.

#### R2: `enforce_config_ceilings` with boundary values

Test that budget > 25 is capped, turns > 100 are capped, diff > 10000 is capped. Also test that normal values pass through unchanged. This function uses `eval` which is a security-relevant pattern.

#### R3: `unstage_secrets` integration test

Stage a `.env` file and a `.pem` file, call `unstage_secrets`, verify they are no longer staged.

#### R4: Measurer output schema validation

Run each measurer in a sandbox and verify JSON output has the required fields (category, score, max_score, details, tool) with correct types.

#### R5: `extract_findings` with multiple input formats

Currently only tests one format (JSON in a markdown code block). Also test: raw JSON array as result, nested in content array, malformed JSON (should return []).

### 10.2 MEDIUM IMPACT -- Expand Existing Tests

#### R6: Interview branch coverage

Test `interview_specific_goals` with each area choice (security, testing, performance, quality, documentation, multiple). Currently only the "everything/auto" path is tested.

#### R7: `detect_project_features` for all project types

Currently only tests node features. Test that python sandbox detects tests, that projects with Docker/linter config are detected.

#### R8: Error path for `require_git_repo` outside a git repo

Run a function that calls `require_git_repo` from a non-git temp directory, verify it exits 1.

#### R9: `verify_build` for python project type

Create a python sandbox with a failing test, verify `verify_build` returns non-zero. Currently only tests node dispatch.

#### R10: Focus string sanitization

Test that `safe_focus` properly sanitizes special characters in focus strings (spaces, slashes, quotes, backticks) for branch names.

### 10.3 LOW IMPACT -- Nice to Have

#### R11: `project_type_name` mapping completeness

Trivial but currently untested. Verify all 5 types map correctly.

#### R12: `run_measurer` with invalid JSON output

Verify that a measurer returning garbage doesn't corrupt the results file.

#### R13: `relative_time` with future timestamps

Verify behavior when timestamp is in the future (should show "just now" or handle gracefully).

#### R14: Dashboard with legacy filename format

Test the fallback parsing for old-format history files (project name extracted from filename).

---

## 11. Security-Relevant Testing Gaps

| Gap | Risk | Recommendation |
|-----|------|----------------|
| `config_set` uses `yq eval -i` with user-provided values | If value contains YAML injection, yq could execute it | Test with values containing `: ` and `\n` and `$(...)` |
| `enforce_config_ceilings` uses `eval` | Variable name injection if `$_var_budget` is attacker-controlled | Currently safe (hardcoded callers) but add assertion test |
| `schedule_cron` builds cron line by string concatenation | If project path contains special characters, cron could malfunction | Test with path containing spaces and quotes |
| `safe_git` disables hooks globally | Correct for security but test verifies the `-c core.hooksPath=/dev/null` is actually passed | Currently only implicit via code inspection |
| `unstage_secrets` pattern matching | Test that the regex actually catches common secret filenames | Add test with edge cases like `.env.local`, `credentials.json` |

---

## 12. Dead Code / Unused State

1. **`KYZN_CLAUDE_RESULT`** (execute.sh:179) -- Set by `execute_claude` but never read by any function. Dead state.
2. **`KYZN_CLAUDE_SESSION`** (execute.sh:181) -- Set but never read. Dead state.
3. **`KYZN_CLAUDE_STOP_REASON`** (execute.sh:182) -- Set but never read. Dead state.
4. **`config_set` vs `config_set_str`** (core.sh:97-116) -- Identical implementations. `config_set_str` is redundant.

---

## 13. Summary Scorecard

| Dimension | Score | Notes |
|-----------|-------|-------|
| **Coverage breadth** | 6/10 | 55% of functions have direct tests |
| **Coverage depth** | 4/10 | Critical orchestration paths are completely untested |
| **Test quality** | 8/10 | Tests that exist are well-written with good assertions |
| **Test isolation** | 9/10 | Sandbox pattern is excellent |
| **Edge case coverage** | 5/10 | Good for tested functions, absent for untested ones |
| **Error path coverage** | 2/10 | Almost no error paths are tested |
| **Mocking / external deps** | 1/10 | Zero mocking of any external command |
| **Regression coverage** | 7/10 | Known past bugs have tests, but implicit bugs don't |
| **Maintenance burden** | 8/10 | Tests are clean and unlikely to break on minor changes |
| **Integration testing** | 1/10 | No end-to-end tests of the main workflows |
| **Overall** | **5.1/10** | Strong leaf-level testing, weak at orchestration and integration |

---

*Generated by Kraken (Implementation Quality & TDD Audit Agent)*
*Model: Claude Opus 4.6 (1M context)*
