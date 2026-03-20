# Phoenix Refactoring & Technical Debt Report

**Project:** KyZN (Autonomous Code Improvement CLI)
**Date:** 2026-03-20
**Author:** phoenix-agent (Claude Opus 4.6)
**Codebase size:** ~6,764 lines across 20 source files (bash)

---

## Executive Summary

KyZN is well-structured for a bash project. The modular library approach (`lib/*.sh`, `measurers/*.sh`, `profiles/*.md`, `templates/*.md`) is sound. The main issues are:

1. **`eval` usage for indirect variable access** (security-sensitive, replaceable with namerefs)
2. **Massive code duplication** in jq JSON-building across all measurers and in `analyze.sh`
3. **`analyze.sh` is a 1,154-line god file** combining prompt-building, parallel orchestration, progress UI, report generation, and fix execution
4. **Duplicated color/helper definitions** between `install.sh` and `lib/core.sh`
5. **Duplicated Claude invocation patterns** across `execute.sh` and `analyze.sh`
6. **`config_set` and `config_set_str` are identical functions**

Overall risk level: **Medium** (functional code, but maintenance burden grows with each feature).

---

## Findings by Priority

### PRIORITY 1: Quick Wins (< 30 min each)

#### QW-1: `config_set` and `config_set_str` are identical
**Location:** `lib/core.sh:97-116`
**Severity:** Low
**Effort:** 5 minutes

Both functions have identical implementations. `config_set_str` appears to be a copy-paste artifact.

**Before (`lib/core.sh:97-116`):**
```bash
config_set() {
    local key="$1"
    local value="$2"
    ensure_kyzn_dirs
    if [[ ! -f "$KYZN_CONFIG" ]]; then
        echo "# kyzn configuration — commit this file" > "$KYZN_CONFIG"
    fi
    VALUE="$value" yq eval -i "$key = strenv(VALUE)" "$KYZN_CONFIG"
}

config_set_str() {
    local key="$1"
    local value="$2"
    ensure_kyzn_dirs
    if [[ ! -f "$KYZN_CONFIG" ]]; then
        echo "# kyzn configuration — commit this file" > "$KYZN_CONFIG"
    fi
    VALUE="$value" yq eval -i "$key = strenv(VALUE)" "$KYZN_CONFIG"
}
```

**After:**
```bash
config_set() {
    local key="$1"
    local value="$2"
    ensure_kyzn_dirs
    if [[ ! -f "$KYZN_CONFIG" ]]; then
        echo "# kyzn configuration — commit this file" > "$KYZN_CONFIG"
    fi
    VALUE="$value" yq eval -i "$key = strenv(VALUE)" "$KYZN_CONFIG"
}

# Backward compat alias
config_set_str() { config_set "$@"; }
```

---

#### QW-2: `has_cmd` is defined in both `install.sh` and `lib/core.sh`
**Location:** `install.sh:39`, `lib/core.sh:200`
**Severity:** Low
**Effort:** N/A (acceptable — install.sh must be standalone)

This is actually fine. `install.sh` runs standalone before kyzn is installed, so it cannot source `lib/core.sh`. Documented here as "not a bug."

---

#### QW-3: Color definitions duplicated between `install.sh` and `lib/core.sh`
**Location:** `install.sh:22-32`, `lib/core.sh:7-18`
**Severity:** Low
**Effort:** N/A (same reason as QW-2 — install.sh is standalone)

Acceptable duplication. No action needed.

---

#### QW-4: Duplicated `_resolve` / `_kyzn_resolve` symlink resolution
**Location:** `kyzn:18-30`, `tests/selftest.sh:7-15`
**Severity:** Low
**Effort:** 10 minutes

Both files implement identical symlink resolution. The selftest version is a compressed copy. Since selftest sources `core.sh` anyway, it could use a shared function if one were exported to core. However, since `kyzn` runs before `core.sh` is loaded, the main script's copy is necessary. The selftest copy could reference the one in core.

**Recommendation:** Add `_kyzn_resolve` to `lib/core.sh` and have both `kyzn` and `selftest.sh` use it after sourcing core. The main `kyzn` script needs its copy for bootstrapping (to find `lib/core.sh`), so the selftest's copy is the one to remove.

---

### PRIORITY 2: Medium Refactors (1-3 hours each)

#### MR-1: `eval` usage in `enforce_config_ceilings` — replace with namerefs
**Location:** `lib/execute.sh:52-75`
**Severity:** Medium (security-adjacent in a tool that processes potentially untrusted config)
**Effort:** 30 minutes

Uses `eval` to read and write variables by name. Bash 4.3+ namerefs (`declare -n`) are safer and already required by kyzn (version check at `kyzn:7`).

**Before (`lib/execute.sh:58-74`):**
```bash
enforce_config_ceilings() {
    local _var_budget=$1 _var_turns=$2 _var_diff_limit=$3
    local max_budget=25 max_turns=100 max_diff=10000

    local _cur_budget _cur_turns _cur_diff
    eval "_cur_budget=\$$_var_budget"
    eval "_cur_turns=\$$_var_turns"
    eval "_cur_diff=\$$_var_diff_limit"

    if (( $(awk "BEGIN {print ($_cur_budget > $max_budget) ? 1 : 0}") )); then
        log_warn "Budget $_cur_budget exceeds max ($max_budget). Capping."
        eval "$_var_budget=$max_budget"
    fi
    # ... similar for turns and diff
}
```

**After:**
```bash
enforce_config_ceilings() {
    local -n _ref_budget=$1 _ref_turns=$2 _ref_diff=$3
    local max_budget=25 max_turns=100 max_diff=10000

    if (( $(awk "BEGIN {print ($_ref_budget > $max_budget) ? 1 : 0}") )); then
        log_warn "Budget $_ref_budget exceeds max ($max_budget). Capping."
        _ref_budget=$max_budget
    fi
    if (( _ref_turns > max_turns )); then
        log_warn "Max turns $_ref_turns exceeds max ($max_turns). Capping."
        _ref_turns=$max_turns
    fi
    if (( _ref_diff > max_diff )); then
        log_warn "Diff limit $_ref_diff exceeds max ($max_diff). Capping."
        _ref_diff=$max_diff
    fi
}
```

---

#### MR-2: `eval` usage in `_get_status` / `_set_status` — replace with associative array
**Location:** `lib/analyze.sh:684-685`
**Severity:** Medium
**Effort:** 20 minutes

Uses `eval` to simulate dynamic variable names for specialist status tracking. An associative array is cleaner.

**Before (`lib/analyze.sh:680-685`):**
```bash
local _status_security="running" _status_correctness="running" ...
_get_status() { eval "echo \$_status_$1"; }
_set_status() { printf -v "_status_$1" '%s' "$2"; }
```

**After:**
```bash
declare -A _agent_status=(
    [security]="running" [correctness]="running"
    [performance]="running" [architecture]="running"
)
# Then use: ${_agent_status[$spec_name]} and _agent_status[$spec_name]="done"
```

---

#### MR-3: Massive jq JSON-building duplication across all measurers
**Location:** `measurers/generic.sh`, `measurers/node.sh`, `measurers/python.sh`, `measurers/rust.sh`, `measurers/go.sh`
**Severity:** Medium
**Effort:** 1-2 hours

Every measurer repeats the same pattern ~3-5 times:
```bash
results=$(echo "$results" | jq --argjson s "$score" --argjson c "$count" \
    '. + [{
        "category": "CATEGORY",
        "score": $s,
        "max_score": 100,
        "details": {"some_field": $c},
        "tool": "tool-name",
        "raw_output": ""
    }]')
```

This pattern appears **~20 times** across 5 files. Extract a helper function.

**After — add to `lib/measure.sh` or a new `lib/measurer-utils.sh`:**
```bash
# Append a measurement result to the JSON array
# Usage: add_measurement results_var category score tool [detail_key detail_val]...
add_measurement() {
    local -n _ref="$1"
    local category="$2" score="$3" tool="$4"
    shift 4

    # Build details object from remaining key=value pairs
    local jq_args=(--arg cat "$category" --argjson s "$score" --arg tool "$tool")
    local detail_expr='{'
    local first=true
    while (( $# >= 2 )); do
        local key="$1" val="$2"; shift 2
        jq_args+=(--argjson "d_$key" "$val")
        $first || detail_expr+=','
        detail_expr+="\"$key\":\$d_$key"
        first=false
    done
    detail_expr+='}'

    _ref=$(echo "$_ref" | jq "${jq_args[@]}" \
        ". + [{category:\$cat, score:\$s, max_score:100, details:$detail_expr, tool:\$tool, raw_output:\"\"}]")
}
```

Then each measurer call becomes:
```bash
add_measurement results "quality" "$todo_score" "grep-todos" todo_count "$todo_count"
```

---

#### MR-4: Duplicated Claude invocation pattern between `execute.sh` and `analyze.sh`
**Location:** `lib/execute.sh:90-183`, `lib/analyze.sh:227-280`, `lib/analyze.sh:633-658`, `lib/analyze.sh:1103-1124`
**Severity:** Medium
**Effort:** 1-2 hours

There are **4 separate places** that invoke `claude -p ...` with nearly identical argument patterns (timeout, settings_json, stderr handling, exit code checking). Each copy has subtle differences in error handling and cleanup.

**Recommendation:** Extract a `run_claude()` function in `lib/execute.sh` that handles:
- Timeout wrapping
- stderr capture
- Exit code detection (124 = timeout vs other)
- JSON validation of result
- Cost/session extraction

```bash
# lib/execute.sh
run_claude() {
    local prompt="$1" model="$2" budget="$3" max_turns="$4"
    local sys_prompt_file="$5" allowlist="$6"
    local timeout_secs="${KYZN_CLAUDE_TIMEOUT:-600}"
    local settings_json='{"permissions":{"disallowedFileGlobs":[...]}}'

    local stderr_file
    stderr_file=$(mktemp)

    local result
    # shellcheck disable=SC2086
    result=$(timeout "$timeout_secs" claude -p "$prompt" \
        --model "$model" \
        --max-budget-usd "$budget" \
        --max-turns "$max_turns" \
        $allowlist \
        --settings "$settings_json" \
        --append-system-prompt-file "$sys_prompt_file" \
        --output-format json \
        --no-session-persistence \
        2>"$stderr_file") || {
        local exit_code=$?
        if (( exit_code == 124 )); then
            log_error "Claude timed out after ${timeout_secs}s"
        else
            log_error "Claude invocation failed (exit $exit_code)"
        fi
        rm -f "$stderr_file"
        return 1
    }
    rm -f "$stderr_file"

    if ! echo "$result" | jq . &>/dev/null; then
        log_error "Claude returned invalid JSON"
        return 1
    fi

    # Set globals for caller
    KYZN_CLAUDE_RESULT="$result"
    KYZN_CLAUDE_COST=$(echo "$result" | jq -r '.total_cost_usd // "unknown"')
}
```

Then each callsite becomes a 1-3 line call instead of 20-30 lines.

---

#### MR-5: Duplicated `settings_json` literal string
**Location:** `lib/execute.sh:109`, `lib/analyze.sh:237`, `lib/analyze.sh:613`, `lib/analyze.sh:1095`
**Severity:** Low
**Effort:** 10 minutes

The exact same JSON string for file access restrictions is hardcoded in 4 places:
```bash
local settings_json='{"permissions":{"disallowedFileGlobs":["~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key"]}}'
```

**Recommendation:** Define once in `lib/core.sh`:
```bash
KYZN_SETTINGS_JSON='{"permissions":{"disallowedFileGlobs":["~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key"]}}'
```

---

#### MR-6: `cmd_dashboard` in `history.sh` is 141 lines with deeply nested logic
**Location:** `lib/history.sh:100-241`
**Severity:** Medium
**Effort:** 1 hour

This function handles: directory scanning, JSON parsing, legacy filename extraction, fallback logic, formatting, color coding, and rendering. It should be split into:
- `_dashboard_load_entries()` — load and normalize history entries
- `_dashboard_render()` — format and display

---

### PRIORITY 3: Major Refactors (half-day+)

#### MAJ-1: `analyze.sh` is a 1,154-line god file
**Location:** `lib/analyze.sh`
**Severity:** High
**Effort:** 3-4 hours

This single file contains 7 distinct responsibilities:
1. **Specialist prompt building** (lines 8-175) — ~170 lines of heredocs
2. **Consensus prompt building** (lines 180-222) — ~40 lines
3. **Claude invocation wrapper** (lines 227-280) — `run_specialist()`
4. **JSON extraction** (lines 285-313) — `extract_findings()`
5. **Terminal display** (lines 318-377) — `display_findings()`
6. **Fix prompt generation** (lines 382-462) — `generate_fix_prompt()`
7. **Main orchestrator** (lines 467-923) — `cmd_analyze()` at **456 lines**
8. **Report generation** (lines 928-1057) — `generate_detailed_report()` at **130 lines**
9. **Fix execution** (lines 1062-1154) — `run_fix_phase()` at **93 lines**

**Recommendation:** Split into:
- `lib/analyze-prompts.sh` — prompt builders (1, 2, 6)
- `lib/analyze-report.sh` — report generation (5, 8)
- `lib/analyze.sh` — orchestrator (7, 9) + imports
- Move `run_specialist()` and `extract_findings()` (3, 4) into the shared `run_claude()` from MR-4

---

#### MAJ-2: `cmd_improve` in `execute.sh` is a 341-line function
**Location:** `lib/execute.sh:188-528`
**Severity:** High
**Effort:** 2-3 hours

This is the main workhorse function and does everything sequentially:
- Argument parsing (30 lines)
- Project detection (10 lines)
- Config loading (30 lines)
- Interactive confirmation (30 lines)
- Baseline measurement (20 lines)
- Branch creation (10 lines)
- Prompt assembly (15 lines)
- Claude execution (10 lines)
- Diff size check (30 lines)
- Build verification (35 lines)
- Re-measurement (10 lines)
- Score regression check (30 lines)
- Per-category regression check (20 lines)
- Report generation (10 lines)
- History writing (5 lines)

While each step is sequential and interdependent, the function could be broken into `_improve_parse_args()`, `_improve_setup()`, `_improve_execute()`, `_improve_verify()`, `_improve_finalize()` to improve readability.

---

#### MAJ-3: `selftest.sh` is 1,584 lines — extract test framework
**Location:** `tests/selftest.sh`
**Severity:** Low (tests, not production code)
**Effort:** 2 hours

The test file contains both the test framework (`pass()`, `fail()`, `assert_eq()`, etc.) and ~50 individual tests. The framework (~50 lines) could be extracted to `tests/framework.sh`, making the test file focused on test definitions.

---

### PRIORITY 4: Design & Pattern Issues

#### DP-1: Inconsistent score clamping patterns across measurers
**Location:** All `measurers/*.sh`
**Severity:** Low

Some measurers clamp with a separate statement:
```bash
if (( score < 0 )); then score=0; fi
```
Others use inline:
```bash
(( sec_score -= critical * 30 )) || true
```
Some forget to clamp to max (scores can theoretically exceed 100 in `generic.sh:140` for doc_score, though it's caught later).

**Recommendation:** The `add_measurement` helper from MR-3 could auto-clamp: `if (( score < 0 )); then score=0; elif (( score > 100 )); then score=100; fi`

---

#### DP-2: Mixed use of `safe_git` and `git` within the same flows
**Location:** `lib/execute.sh`, `lib/report.sh`, `lib/analyze.sh`
**Severity:** Medium

`safe_git()` disables hooks for security. But several calls use bare `git`:
- `lib/execute.sh:403-406` — `safe_git add -A` then `git diff --cached` then `git reset HEAD`
- `lib/report.sh:32-37` — `safe_git add -A` then `git diff --cached` then `safe_git reset`
- `lib/history.sh:256` — `git branch -a`, `git diff`

The inconsistency means some operations run hooks and some don't. All git operations initiated by kyzn should use `safe_git` for consistency, except informational commands (`git diff`, `git status`, `git log`, `git branch`) which don't trigger hooks.

**Recommendation:** Document the rule: "Use `safe_git` for write operations (checkout, add, commit, push, reset). Use `git` for read operations (diff, status, log, branch -a)." The current code mostly follows this but has a few exceptions (`git push -u origin HEAD` at `report.sh:87` uses bare `git`).

---

#### DP-3: `cmd_analyze` duplicates the Claude invocation in single-agent mode
**Location:** `lib/analyze.sh:618-667`
**Severity:** Medium

The single-agent mode in `cmd_analyze` has its own full Claude invocation block (35 lines) instead of calling `run_specialist()`. This is because `run_specialist()` was designed for background execution and writes to a file. A shared `run_claude()` (MR-4) would eliminate this duplication.

---

#### DP-4: Bash string templating for prompts is fragile
**Location:** `lib/prompt.sh:24-32`
**Severity:** Low

Placeholder replacement uses bash string substitution:
```bash
prompt="${prompt//\{\{PROJECT_NAME\}\}/$(project_name)}"
prompt="${prompt//\{\{MEASUREMENTS\}\}/$measurements_json}"
```

If `measurements_json` contains `{{` or `}}` patterns (unlikely but possible in JSON strings), it could cause unexpected behavior. For a bash project of this scope, this is acceptable — switching to envsubst or sed would add complexity.

---

#### DP-5: Magic numbers scattered through measurers
**Location:** All `measurers/*.sh`
**Severity:** Low

Scoring penalties are hardcoded throughout:
- `generic.sh:21` — `todo_score=$(( 100 - (todo_count * 2) ))` (2 points per TODO)
- `node.sh:21` — `sec_score -= critical * 30` (30 points per critical vuln)
- `python.sh:19` — `lint_score -= error_count * 3` (3 points per lint error)
- `rust.sh:18` — `lint_score -= error_count * 10` (10 points per clippy error)

These are reasonable defaults but not configurable. Adding config overrides (`scoring.penalties.critical_vuln: 30`) would add unnecessary complexity at this stage.

**Recommendation:** Leave as-is but add a comment block at the top of each measurer documenting the penalty weights for transparency.

---

#### DP-6: `write_history` uses namerefs but `enforce_config_ceilings` uses eval
**Location:** `lib/core.sh:242`, `lib/execute.sh:59`
**Severity:** Low (inconsistency)

`write_history` correctly uses `local -n _wh_fields="$_extra_name"` while `enforce_config_ceilings` uses `eval`. Both patterns are in the same codebase. Standardize on namerefs (MR-1 addresses this).

---

### PRIORITY 5: Naming Issues

#### NM-1: Ambiguous variable prefix conventions
**Severity:** Low

The codebase uses several variable name prefixes inconsistently:
- `_kyzn_cleanup` (underscore + module prefix)
- `_wh_fields` (underscore + abbreviation)
- `_ref_pri` (underscore + ref + abbreviation)
- `_hist` (underscore + abbreviation)
- `_cur_budget` (underscore + abbreviation)
- `KYZN_CLAUDE_RESULT` (all-caps for globals)

The all-caps convention for globals and underscore prefix for locals is fine. The abbreviated names (`_wh`, `_ref_pri`) could be more descriptive, but bash conventions vary. Not worth changing.

---

#### NM-2: `safe_git` name is slightly misleading
**Location:** `lib/execute.sh:7`
**Severity:** Low

`safe_git` disables hooks, but doesn't add other safety measures (like `--dry-run`). The name implies general safety. A more precise name would be `git_nohooks` or `hookless_git`. However, the current name is well-documented and used consistently — renaming would be churn.

---

## Anti-Patterns Found

### AP-1: `eval` for variable indirection (execute.sh:59-73, analyze.sh:684)
**Status:** Addressed in MR-1 and MR-2 above. Replace with namerefs and associative arrays.

### AP-2: Piping `echo` through `jq` in loops (measurers, history.sh)
**Severity:** Low

Pattern like `echo "$results" | jq ...` in a loop creates subshell overhead. For the measurer files (3-5 iterations), this is negligible. For `cmd_dashboard` (potentially many history entries), each entry calls `jq` ~7 times individually:
```bash
# lib/history.sh:190-196 — 7 separate jq calls per dashboard entry
proj=$(echo "$dashboard_data" | jq -r ".[$i].project")
type=$(echo "$dashboard_data" | jq -r ".[$i].type // \"-\"")
status=$(echo "$dashboard_data" | jq -r ".[$i].status // \"-\"")
ts=$(echo "$dashboard_data" | jq -r ".[$i].ts // ...")
hb=$(echo "$dashboard_data" | jq -r ".[$i].health_before // ...")
ha=$(echo "$dashboard_data" | jq -r ".[$i].health_after // ...")
fc=$(echo "$dashboard_data" | jq -r ".[$i].finding_count // ...")
```

**Recommendation:** Combine into a single jq call:
```bash
read -r proj type status ts hb ha fc < <(
    echo "$dashboard_data" | jq -r ".[$i] | [.project, (.type // \"-\"), ...] | @tsv"
)
```

Same pattern exists in `display_findings` (4 jq calls per finding) and `generate_detailed_report` (10+ jq calls per finding, across potentially hundreds of findings).

### AP-3: No `trap` cleanup in `analyze.sh`'s `cmd_analyze`
**Severity:** Medium

`cmd_improve` sets up a cleanup trap (`_kyzn_cleanup`), but `cmd_analyze` does not. If interrupted during multi-agent analysis:
- Temp directories (`$measure_dir`, `$tmp_dir`) are not cleaned up
- The `sys_prompt_file` temp file is not deleted
- History entry stays as "running" forever

**Recommendation:** Add a cleanup trap mirroring the one in `cmd_improve`.

---

## Summary Table

| ID | Finding | Priority | Effort | Files |
|----|---------|----------|--------|-------|
| QW-1 | Identical `config_set`/`config_set_str` | Quick Win | 5 min | `lib/core.sh` |
| MR-1 | Replace `eval` with namerefs in `enforce_config_ceilings` | Medium | 30 min | `lib/execute.sh` |
| MR-2 | Replace `eval`/`printf -v` with assoc array for agent status | Medium | 20 min | `lib/analyze.sh` |
| MR-3 | Extract jq JSON-building helper for measurers | Medium | 1-2 hr | `measurers/*.sh`, `lib/measure.sh` |
| MR-4 | Extract shared `run_claude()` function | Medium | 1-2 hr | `lib/execute.sh`, `lib/analyze.sh` |
| MR-5 | Extract `KYZN_SETTINGS_JSON` constant | Medium | 10 min | `lib/core.sh`, `lib/execute.sh`, `lib/analyze.sh` |
| MR-6 | Split `cmd_dashboard` into load + render | Medium | 1 hr | `lib/history.sh` |
| MAJ-1 | Split `analyze.sh` into 3 files | Major | 3-4 hr | `lib/analyze.sh` |
| MAJ-2 | Split `cmd_improve` into sub-functions | Major | 2-3 hr | `lib/execute.sh` |
| MAJ-3 | Extract test framework from selftest | Low | 2 hr | `tests/selftest.sh` |
| DP-1 | Standardize score clamping | Low | 30 min | `measurers/*.sh` |
| DP-2 | Document safe_git vs git usage rules | Low | 15 min | multiple |
| DP-3 | Single-agent mode duplicates Claude invocation | Medium | covered by MR-4 | `lib/analyze.sh` |
| AP-2 | Multiple jq calls per loop iteration | Low | 1 hr | `lib/history.sh`, `lib/analyze.sh` |
| AP-3 | Missing cleanup trap in `cmd_analyze` | Medium | 30 min | `lib/analyze.sh` |

## Recommended Implementation Order

### Phase 1: Safety & Quick Wins (1-2 hours)
1. QW-1 — Deduplicate `config_set_str`
2. MR-1 — Replace `eval` with namerefs in `enforce_config_ceilings`
3. MR-2 — Replace `eval` with associative array in analyze status tracking
4. MR-5 — Extract `KYZN_SETTINGS_JSON` constant
5. AP-3 — Add cleanup trap to `cmd_analyze`

**Rollback:** `git revert` single commit
**Acceptance:** `kyzn selftest` passes

### Phase 2: Deduplication (3-4 hours)
6. MR-4 — Extract shared `run_claude()` function
7. MR-3 — Extract jq JSON-building helper for measurers

**Rollback:** `git revert` per commit
**Acceptance:** `kyzn selftest` passes, `kyzn measure` produces same output, `kyzn analyze --single` works

### Phase 3: Structural (half-day)
8. MAJ-1 — Split `analyze.sh`
9. MAJ-2 — Split `cmd_improve`
10. MR-6 — Split `cmd_dashboard`

**Rollback:** `git revert` per commit
**Acceptance:** Full test suite, manual smoke test of `kyzn improve` and `kyzn analyze`

## What NOT to Refactor

1. **`install.sh` duplication** — It must be standalone (curl-pipeable). Duplicating colors/helpers is intentional.
2. **Template string substitution** — `{{PLACEHOLDER}}` replacement in `prompt.sh` is simple and adequate.
3. **Magic scoring numbers** — Making them configurable adds complexity without clear benefit at this stage.
4. **Test file size** — 1,584 lines of tests is verbose but thorough. The test framework extraction (MAJ-3) is nice-to-have.
5. **The overall module structure** — The `lib/*.sh` + `measurers/*.sh` + `profiles/*.md` + `templates/*.md` organization is well-designed and should be preserved.

---

*Generated by phoenix-agent (Claude Opus 4.6) on 2026-03-20*
