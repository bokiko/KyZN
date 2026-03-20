# KyZN Architecture & Design Audit

**Author:** architect-agent (Claude Opus 4.6)  
**Date:** 2026-03-20  
**Scope:** Full codebase — all source files in kyzn, lib/, measurers/, templates/, profiles/, tests/  
**Method:** Complete file-by-file read of every source file, tracing all data flows and interfaces

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Module Boundaries & Coupling](#2-module-boundaries--coupling)
3. [Data Flow Analysis](#3-data-flow-analysis)
4. [Extension Points](#4-extension-points)
5. [Configuration Architecture](#5-configuration-architecture)
6. [State Management](#6-state-management)
7. [Error Propagation](#7-error-propagation)
8. [Scalability](#8-scalability)
9. [Missing Abstractions](#9-missing-abstractions)
10. [Findings Summary](#10-findings-summary)

---

## 1. Architecture Overview

KyZN is a ~1,800-line bash CLI tool structured as a main dispatcher (`kyzn`) that lazy-loads library modules from `lib/`. The architecture follows a pipeline pattern:

```
detect → measure → prompt → execute(Claude) → verify → report → history
```

### File-level architecture

| Layer | Files | Responsibility |
|-------|-------|----------------|
| Entry point | `kyzn` | CLI routing, doctor, update |
| Core | `lib/core.sh` | Logging, config I/O, utils, history write |
| Detection | `lib/detect.sh` | Project type + feature detection |
| Interview | `lib/interview.sh` | Interactive config setup |
| Measurement | `lib/measure.sh` + `measurers/*.sh` | Health score computation |
| Prompt | `lib/prompt.sh` | Template assembly |
| Execution | `lib/execute.sh` | Claude invocation, safety, `cmd_improve` |
| Verification | `lib/verify.sh` | Build/test validation |
| Allowlist | `lib/allowlist.sh` | Per-language tool permissions |
| Report | `lib/report.sh` | Report generation, PR creation |
| Analysis | `lib/analyze.sh` | Multi-agent deep analysis (Opus) |
| History | `lib/history.sh` | History display, dashboard, diff, status |
| Approval | `lib/approve.sh` | Approve/reject runs |
| Scheduling | `lib/schedule.sh` | Cron integration |
| Profiles | `profiles/*.md` | Focus-area expert personas |
| Templates | `templates/*.md` | System/improvement/analysis prompts |
| Tests | `tests/selftest.sh` | Self-test suite |

---

## 2. Module Boundaries & Coupling

### FINDING ARC-001: `execute.sh` is a God Module
**Severity: HIGH**

`execute.sh` (587 lines) contains the entire `cmd_improve` function which is the heart of the system. It handles:
- Argument parsing
- Config loading + ceiling enforcement
- Interactive model/budget prompts
- Lock management
- Baseline measurement
- Branch creation
- Prompt assembly
- Claude execution
- Diff size checking
- Build verification
- Post-measurement + score regression
- Per-category regression gates
- Report generation delegation
- History writing
- Cleanup/trap handling

This is a 300+ line function (`cmd_improve`) that should be decomposed. Every concern of the pipeline is wired directly into this function rather than being composed from smaller, independently testable units.

**Recommendation:** Extract `cmd_improve` into a pipeline orchestrator that calls discrete phases. Each phase (lock, measure-baseline, execute, verify, report) should be a separate function that returns a status code and sets well-defined output variables.

---

### FINDING ARC-002: Implicit Module Contracts via Global Variables
**Severity: MEDIUM**

Modules communicate through global shell variables rather than explicit interfaces:
- `KYZN_PROJECT_TYPE`, `KYZN_PROJECT_TYPES` — set by `detect.sh`, read everywhere
- `KYZN_HEALTH_SCORE`, `KYZN_CATEGORY_SCORES` — set by `compute_health_score()`, read by display/report
- `KYZN_MEASUREMENTS_FILE` — set by `run_measurements()`, read by callers
- `KYZN_CLAUDE_RESULT`, `KYZN_CLAUDE_COST`, `KYZN_CLAUDE_SESSION`, `KYZN_CLAUDE_STOP_REASON` — set by `execute_claude()`, read by report
- `KYZN_HAS_TYPESCRIPT`, `KYZN_HAS_TESTS`, etc. — set by `detect_project_features()`

There is no documentation of which functions set which globals, and no validation that they were set before being read. If `compute_health_score` is called before `run_measurements`, `KYZN_MEASUREMENTS_FILE` is stale or unset.

**Recommendation:** Document all global variable contracts in a comment block at the top of each module. Consider creating a `lib/globals.sh` that initializes all shared variables with safe defaults and documents their lifecycle.

---

### FINDING ARC-003: Circular Re-computation of Health Scores
**Severity: LOW**

`compute_health_score()` is called multiple times throughout a single improve cycle, each time overwriting the same global variables (`KYZN_HEALTH_SCORE`, `KYZN_CATEGORY_SCORES`):

1. In `run_measurements()` at line 53 of measure.sh
2. In `cmd_improve()` at line 336 of execute.sh (baseline)
3. In `cmd_improve()` at lines 476-479 (before/after comparison)
4. In `generate_report()` at lines 18-23 of report.sh (before and after again)

Each call overwrites the globals, meaning the caller must carefully sequence reads. In `cmd_improve`, between lines 476-479, the before score is computed, saved to a local, then the after score is computed overwriting the same global. This works but is fragile.

**Recommendation:** `compute_health_score()` should return values (via a nameref or output) rather than setting globals. This eliminates sequencing bugs.

---

### FINDING ARC-004: `analyze.sh` Duplicates Execution Logic from `execute.sh`
**Severity: MEDIUM**

`analyze.sh` (1,060+ lines) duplicates significant patterns from `execute.sh`:
- Lock management (same mkdir-based lock pattern, lines ~550-570)
- Argument parsing (same `--model`, `--budget`, `--verbose` flags)
- Claude invocation (calls `execute_claude` but also has its own parallel execution with `run_specialist`)
- Safety operations (calls `safe_git`, `unstage_secrets`, `check_dangerous_files`)
- History writing

The `cmd_analyze` function is ~500 lines, rivaling `cmd_improve` in complexity. Both commands share a common "measure then invoke Claude then report" skeleton but implement it independently.

**Recommendation:** Extract a shared pipeline runner that both `cmd_improve` and `cmd_analyze` can use, with hooks for customizing the prompt, execution strategy, and report format.

---

### FINDING ARC-005: Tight Coupling Between Report and Git Operations
**Severity: MEDIUM**

`generate_report()` in `report.sh` does four unrelated things:
1. Generates a markdown report file
2. Stages files with `safe_git add -A`
3. Creates a git commit
4. Pushes to remote and creates a PR via `gh`

These should be separate responsibilities. A user might want a report without a PR, or might want to customize the PR flow. Currently, report generation always triggers git operations.

**Recommendation:** Split `generate_report()` into `write_report()`, `commit_changes()`, and `create_pr()`. Let the caller compose them.

---

## 3. Data Flow Analysis

### Measurement → Prompt → Claude → Report pipeline

```
detect_project_type()
    → sets KYZN_PROJECT_TYPE (global)

run_measurements(project_type, output_dir)
    → dispatches to measurers/generic.sh + measurers/{type}.sh
    → each measurer outputs JSON to stdout
    → run_measurer() merges into results_file
    → compute_health_score() sets KYZN_HEALTH_SCORE, KYZN_CATEGORY_SCORES
    → sets KYZN_MEASUREMENTS_FILE (global)

assemble_prompt(measurements_file, mode, focus, project_type)
    → reads template from templates/improvement-prompt.md
    → performs {{PLACEHOLDER}} substitution
    → returns prompt string via stdout

execute_claude(prompt, system_prompt_file, budget, max_turns, project_type, model, verbose)
    → builds allowlist via build_allowlist()
    → invokes `claude` CLI with --output-format json
    → sets KYZN_CLAUDE_RESULT, KYZN_CLAUDE_COST, etc. (globals)

verify_build()
    → dispatches to verify_{node,python,rust,go}()
    → returns exit code

generate_report(run_id, before_file, after_file, mode, focus)
    → writes markdown report
    → commits, pushes, creates PR
```

### FINDING ARC-006: Measurement Data is File-Path-Coupled
**Severity: LOW**

Measurement results are passed between functions as file paths to temporary files. The temp files are created in `mktemp -d`, passed around as strings, and manually cleaned up in a trap handler. If any function in the chain fails to propagate the path correctly, data is lost.

The file-path coupling also means measurements cannot be easily piped, cached, or inspected in memory. Every intermediate step requires disk I/O.

**Recommendation:** For a bash tool this is acceptable, but consider defining a standard temp directory structure (e.g., `$KYZN_DIR/.run/$run_id/`) that persists until explicitly cleaned, rather than anonymous mktemp directories. This would make debugging failed runs much easier.

---

### FINDING ARC-007: Prompt Assembly Uses Naive String Substitution
**Severity: MEDIUM**

In `prompt.sh` line 32:
```bash
prompt="${prompt//\{\{MEASUREMENTS\}\}/$measurements_json}"
```

This substitutes the entire measurements JSON blob into the prompt via bash string replacement. If the JSON contains bash-special characters (`\`, `$`, backticks), the substitution could corrupt the prompt. In practice, the JSON comes from `jq` output which should be safe, but this is a fragile assumption.

Additionally, if `measurements_json` is very large (e.g., many measurers producing detailed output), the prompt could exceed Claude's context window budget inefficiently.

**Recommendation:** Write the prompt to a temp file using `cat` with heredoc or `printf` to avoid bash interpolation issues. Consider summarizing measurements rather than embedding raw JSON.

---

## 4. Extension Points

### FINDING ARC-008: Measurer Plugin System is Half-Implemented
**Severity: MEDIUM**

The measurer system has a clean plugin architecture conceptually -- each measurer is a standalone script that outputs JSON. However, the discovery and dispatch is hardcoded in `measure.sh`:

```bash
case "$project_type" in
    node)   ... run_measurer "$KYZN_ROOT/measurers/node.sh" ...
    python) ... run_measurer "$KYZN_ROOT/measurers/python.sh" ...
    rust)   ... run_measurer "$KYZN_ROOT/measurers/rust.sh" ...
    go)     ... run_measurer "$KYZN_ROOT/measurers/go.sh" ...
esac
```

Adding a new language (e.g., Java, Ruby, C++) requires modifying `measure.sh`, `detect.sh`, `verify.sh`, `allowlist.sh`, and `execute.sh`. There is no registry or convention-based discovery.

**Recommendation:** Auto-discover measurers by convention: any file matching `measurers/*.sh` that starts with a header comment like `# KYZN_MEASURER: type=java` could be auto-loaded. The verify and allowlist modules should follow the same pattern.

---

### FINDING ARC-009: Verification is Not Pluggable
**Severity: MEDIUM**

`verify.sh` hardcodes verification logic for each language in separate functions (`verify_node`, `verify_python`, etc.). Adding a new language requires writing a new function and adding a case branch.

More critically, there is no way for a project to define custom verification commands. A Node.js project that uses `bun test` instead of `npm test`, or a Python project that uses `tox`, cannot customize verification without modifying KyZN source.

**Recommendation:** Allow `config.yaml` to define custom verify commands:
```yaml
verify:
  build: "bun run build"
  test: "bun test"
  lint: "bun run lint"
```
Fall back to auto-detected commands when not configured.

---

### FINDING ARC-010: Profile System is Effective but Static
**Severity: LOW**

The profile system (`profiles/*.md`) is well-designed -- each profile is a markdown file that gets appended to the system prompt. However, users cannot define custom profiles. A user who wants a "database" or "API" focus has no extension point.

**Recommendation:** Allow user-defined profiles in `.kyzn/profiles/` that override or extend the built-in ones.

---

### FINDING ARC-011: Allowlist is Too Restrictive for Some Projects
**Severity: LOW**

The allowlist in `allowlist.sh` restricts Claude to specific bash commands per project type. This is good for security but blocks legitimate operations. For example:
- A Node.js project using `pnpm` or `bun` cannot use those commands
- A Python project using `uv` or `poetry` is blocked
- A generic project gets almost no bash access (`ls *`, `wc *` only)
- No project type allows `cat`, `find`, or other exploratory commands

**Recommendation:** Allow `config.yaml` to define additional allowlist entries:
```yaml
allowlist:
  extra:
    - '"Bash(pnpm *)"'
    - '"Bash(bun *)"'
```

---

## 5. Configuration Architecture

### FINDING ARC-012: Config Layering is Well-Designed
**Severity: INFO (positive)**

The config architecture uses a clean three-layer approach:
1. **`config.yaml`** -- committed to repo, shared by team
2. **`local.yaml`** -- gitignored, per-developer settings (trust level)
3. **CLI args** -- override everything

The separation of `trust` into `local.yaml` prevents config poisoning (a malicious PR couldn't set `trust: autopilot` in committed config). This is a thoughtful security decision.

---

### FINDING ARC-013: Config Read is Repeated and Uncached
**Severity: LOW**

`config_get()` calls `yq eval` every time. In `cmd_improve()`, config values are read one at a time:
```bash
mode="${mode:-$(config_get '.preferences.mode' 'deep')}"
model="${model:-$(config_get '.preferences.model' 'sonnet')}"
budget="${budget:-$(config_get '.preferences.budget' '2.50')}"
max_turns="${max_turns:-$(config_get '.preferences.max_turns' '30')}"
```

Each `config_get` spawns a `yq` subprocess. This is 4+ subprocess spawns to read a single YAML file.

**Recommendation:** Read all config values in one `yq` call and cache them in shell variables. For example:
```bash
eval "$(yq eval '. as $d | "CFG_MODE=\"\($d.preferences.mode)\" CFG_MODEL=..."' config.yaml)"
```

---

### FINDING ARC-014: `config_set` and `config_set_str` are Identical
**Severity: LOW**

`config_set()` (lines 97-105) and `config_set_str()` (lines 108-116) in `core.sh` have identical implementations. The `_str` variant was likely intended to force string quoting, but both use `strenv(VALUE)` which produces the same result.

**Recommendation:** Remove `config_set_str` and use `config_set` everywhere. Or differentiate them if there is a real need (e.g., `config_set_int` that doesn't quote).

---

### FINDING ARC-015: Environment Variable Overrides are Inconsistent
**Severity: LOW**

Some behaviors are controlled by env vars (`KYZN_ALLOW_CI`, `KYZN_CLAUDE_TIMEOUT`) while others are config-only. There is no documented list of environment variables. The env var `KYZN_CLAUDE_TIMEOUT` (default 600s) is only documented in the code comment.

**Recommendation:** Document all environment variables in the README and in `kyzn doctor` output. Consider a consistent naming convention (`KYZN_*`) and document the precedence: env var > CLI arg > config.yaml > default.

---

## 6. State Management

### FINDING ARC-016: History Dual-Write Has No Atomicity Guarantee
**Severity: MEDIUM**

`write_history()` writes to both local (`.kyzn/history/`) and global (`~/.kyzn/history/`):
```bash
echo "$json" > "$KYZN_HISTORY_DIR/$run_id.json" 2>/dev/null || true
echo "$json" > "$KYZN_GLOBAL_HISTORY/$run_id.json" 2>/dev/null || true
```

If the process is killed between the two writes, the local and global history diverge. The `|| true` suppression means write failures are silently ignored.

**Recommendation:** Write to a temp file first, then `mv` to the final path (atomic on the same filesystem). For cross-filesystem (local vs global), accept eventual consistency but log failures instead of silently swallowing them.

---

### FINDING ARC-017: Lock File Race Condition
**Severity: MEDIUM**

The lock mechanism in `cmd_improve()` uses `mkdir` (atomic) but the stale lock check has a TOCTOU race:

```bash
if ! mkdir "$lockdir" 2>/dev/null; then
    stale_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
    if [[ -z "$stale_pid" ]] || ! kill -0 "$stale_pid" 2>/dev/null; then
        rm -rf "$lockdir"               # <-- Race: another process could mkdir between rm and our mkdir
        mkdir "$lockdir" 2>/dev/null     # <-- Could fail if another process won
    fi
fi
```

Between `rm -rf "$lockdir"` and `mkdir "$lockdir"`, another process could create the lock. The second `mkdir` does handle this with `|| { log_error ...; return 1; }`, so the race is non-catastrophic -- it just means two concurrent runs that both detect a stale lock will both try to take it, and one will fail with an error.

**Recommendation:** This is acceptable for a CLI tool. Document the behavior. For robustness, consider using `flock` on Linux (with a fallback for macOS).

---

### FINDING ARC-018: History Files Have No Size Limit or Rotation
**Severity: MEDIUM**

History files accumulate indefinitely in `.kyzn/history/` and `~/.kyzn/history/`. Each run creates a JSON file. The dashboard (`cmd_dashboard`) reads ALL files with `find` + `cat` + `jq -s`.

With 1000+ runs across multiple projects, the dashboard will:
1. Open and read 1000+ files
2. Pipe all content through `jq -s` which loads everything into memory
3. Group, sort, and deduplicate in a single jq expression

See also: [Scalability section](#8-scalability)

**Recommendation:** Implement rotation: keep the last N history files per project (e.g., 100), archive or delete older ones. Alternatively, consolidate history into a single JSONL file with append-only writes.

---

### FINDING ARC-019: `.kyzn/` Directory Ownership is Ambiguous
**Severity: LOW**

The `.kyzn/` directory contains:
- `config.yaml` -- committed (shared)
- `local.yaml` -- gitignored (private)
- `history/` -- gitignored (local state)
- `reports/` -- gitignored (local state)
- `.improve.lock/` -- runtime (should not persist)
- `.gitignore` -- committed (controls the above)

The `.gitignore` inside `.kyzn/` is correct and well-maintained. However, the `config.yaml` living alongside gitignored state files in the same directory is slightly unusual. A committed config sitting next to gitignored runtime state can confuse users.

**Recommendation:** This is a minor style issue. The current approach works. An alternative would be a top-level `.kyznrc` or `.kyzn.yaml` for committed config, with `.kyzn/` being entirely gitignored state. Not worth changing at this stage.

---

## 7. Error Propagation

### FINDING ARC-020: Silent Error Suppression Pattern
**Severity: HIGH**

Throughout the codebase, errors are aggressively suppressed with `2>/dev/null`, `|| true`, and `2>/dev/null || true`. Examples:

- `run_measurer`: `output=$(bash "$measurer" 2>/dev/null) || true` -- a measurer crash is silently ignored
- `write_history`: `echo "$json" > "..." 2>/dev/null || true` -- history write failure is silent
- `cmd_dashboard`: `dashboard_data=$(cat ... | jq ... 2>/dev/null) || dashboard_data='[]'` -- corrupt JSON silently becomes empty
- `safe_git push`: `2>/dev/null || { log_warn ...; return 1 }` -- at least this warns
- `gh pr create`: `2>/dev/null || { log_warn ...; return 1 }` -- warns too

The pattern is understandable for a CLI that needs to be resilient, but it means:
1. Measurers that crash produce no data and no warning (user sees "(no results from measurer.sh)")
2. A full disk causing history writes to fail is never reported
3. Corrupt history files are silently treated as empty

**Recommendation:** Replace `|| true` with `|| { log_dim "measurer failed: $measurer"; }` in `run_measurer`. For critical paths (history writes, report generation), log warnings on failure. Keep `|| true` only for truly optional operations.

---

### FINDING ARC-021: `enforce_config_ceilings` Uses `eval` for Variable Indirection
**Severity: MEDIUM**

In `execute.sh` lines 58-75:
```bash
eval "_cur_budget=\$$_var_budget"
...
eval "$_var_budget=$max_budget"
```

This uses `eval` with variable names passed as strings. While the caller controls the variable names (they are hardcoded as `budget`, `max_turns`, `diff_limit`), this pattern is fragile. If a variable name contained shell metacharacters, it would be exploitable.

In practice, the function is called as `enforce_config_ceilings budget max_turns diff_limit` which are safe literal strings. The risk is low but the pattern is an anti-pattern.

**Recommendation:** Use bash namerefs (`local -n`) instead of eval:
```bash
enforce_config_ceilings() {
    local -n _budget=$1 _turns=$2 _diff=$3
    # Direct access via _budget, _turns, _diff
}
```

---

### FINDING ARC-022: Build Verification Output is Truncated
**Severity: LOW**

In `verify.sh`, build and test output is truncated:
```bash
npm run build 2>&1 | tail -20
npm test 2>&1 | tail -10
```

If a build failure message appears in the first lines of output (before the tail window), the user cannot diagnose the failure from KyZN's output. The full output is discarded.

**Recommendation:** Capture full output to a temp file, display the tail, and save the full output to the report directory for debugging:
```bash
npm run build > "$KYZN_REPORTS_DIR/$run_id-build.log" 2>&1
tail -20 "$KYZN_REPORTS_DIR/$run_id-build.log"
```

---

## 8. Scalability

### FINDING ARC-023: Dashboard Performance Degrades with History Volume
**Severity: MEDIUM**

`cmd_dashboard()` in `history.sh` reads ALL history JSON files:
```bash
_dash_files=$(find "$global_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
...
dashboard_data=$(cat "${_valid_files[@]}" 2>/dev/null | jq -s '...')
```

With 1000 history files:
- `find` lists 1000 files
- `cat` reads all 1000 files into a pipe
- `jq -s` slurps all into a single array in memory
- Group-by, sort, and filter operations run on the full dataset

This is O(n) in file count for every dashboard invocation.

**Recommendation:** 
1. Maintain a summary index file (`~/.kyzn/dashboard-index.json`) that gets updated on each run
2. Dashboard reads only the index, not individual files
3. Rebuild index on corruption or `kyzn dashboard --rebuild`

---

### FINDING ARC-024: Measurer Subprocess Spawning is Expensive
**Severity: LOW**

Each measurer runs as a subprocess (`bash "$measurer" 2>/dev/null`), and within each measurer, multiple `jq` calls are made to build the results array. The generic measurer alone spawns:
- 1x `grep` for TODOs
- 1x `git status`
- 1x `git log`
- 1x `find` for large files
- 1x `grep` for secrets
- Multiple `grep` calls for README sections
- 6+ `jq` calls to build the JSON array

For a Node.js project, add:
- `npm audit` (network call)
- `npx eslint` (heavy)
- `npx tsc` (heavy)
- `npm outdated` (network call)

A full measurement cycle spawns 20-30+ subprocesses. This is acceptable for a tool that runs infrequently, but makes `kyzn measure` noticeably slow.

**Recommendation:** Accept for now. If performance becomes a concern, batch `jq` calls (build JSON with printf/echo and validate once at the end) and run independent measurers in parallel with `&` and `wait`.

---

### FINDING ARC-025: `analyze.sh` Parallel Claude Invocations
**Severity: LOW (positive finding)**

The analysis system runs 4 specialist Claude sessions in parallel using background processes and `wait`. This is well-implemented:
```bash
for specialist in "${specialists[@]}"; do
    run_specialist "$specialist" ... &
    pids+=($!)
done
for pid in "${pids[@]}"; do
    wait "$pid" || ...
done
```

The consensus merge step after parallel execution is also well-designed -- it deduplicates by file+line, counts votes, and ranks findings by severity and consensus.

---

## 9. Missing Abstractions

### FINDING ARC-026: No Pipeline/Phase Abstraction
**Severity: MEDIUM**

The improve and analyze commands follow a clear phase sequence, but there is no abstraction for a "phase" or "pipeline step." Each command manually sequences its phases, handles errors at each step, writes history, and manages cleanup. This leads to:
- Duplicated cleanup logic between `cmd_improve` and `cmd_analyze`
- Duplicated lock management
- Inconsistent error handling (improve uses trap+cleanup; analyze has its own cleanup)

**Recommendation:** Create a `run_pipeline` function that accepts a list of phase functions and handles cross-cutting concerns (locking, cleanup, history, traps) once.

---

### FINDING ARC-027: No Measurer Result Type
**Severity: LOW**

Measurer results are bare JSON objects with an informal schema:
```json
{
  "category": "quality",
  "score": 85,
  "max_score": 100,
  "details": {...},
  "tool": "eslint",
  "raw_output": ""
}
```

There is no validation that a measurer produces valid output. If a measurer outputs `{"category": "quality"}` without `score` or `max_score`, `compute_health_score` will produce NaN or incorrect results because it does:
```jq
(([.[].score] | add) * 100 / ([.[].max_score] | add))
```

A missing `max_score` would make the denominator wrong.

**Recommendation:** Add a validation step in `run_measurer()` that checks each result object has the required fields:
```bash
echo "$output" | jq 'if type == "array" then .[] else . end | 
  select(.category and .score != null and .max_score != null)' ...
```

---

### FINDING ARC-028: No Abstraction for "Run Context"
**Severity: MEDIUM**

Information about the current run is scattered across many variables and file paths:
- `$run_id` (local variable in cmd_improve)
- `$branch_name` (local)
- `$baseline_dir`, `$after_dir` (temp dirs)
- `$KYZN_CLAUDE_COST` (global)
- `$KYZN_HEALTH_SCORE` (global, overwritten)
- `$focus`, `$mode`, `$model` (locals)

There is no single "run context" object that captures all state for a run. This makes it hard to:
- Pass run information to helper functions cleanly
- Serialize run state for debugging
- Resume a failed run

**Recommendation:** Create an associative array or a temp JSON file that captures all run context:
```bash
declare -A RUN_CTX=(
    [id]="$run_id"
    [branch]="$branch_name"
    [mode]="$mode"
    [focus]="$focus"
    [model]="$model"
    [baseline_dir]="$baseline_dir"
    [baseline_score]=""
    [after_score]=""
    [cost]=""
)
```

---

### FINDING ARC-029: No Dry-Run Mode
**Severity: LOW**

There is no `--dry-run` flag for `kyzn improve` that would:
1. Run measurements
2. Assemble the prompt
3. Show what would be sent to Claude
4. Exit without invoking Claude or creating branches

This makes it hard to debug prompt assembly issues or validate config without spending API budget.

**Recommendation:** Add `--dry-run` that runs through measurement and prompt assembly, then prints the prompt and exits.

---

## 10. Findings Summary

### By Severity

| Severity | Count | IDs |
|----------|-------|-----|
| HIGH | 2 | ARC-001, ARC-020 |
| MEDIUM | 10 | ARC-002, ARC-004, ARC-005, ARC-007, ARC-008, ARC-009, ARC-016, ARC-017, ARC-018, ARC-021, ARC-023, ARC-026, ARC-028 |
| LOW | 10 | ARC-003, ARC-006, ARC-010, ARC-011, ARC-013, ARC-014, ARC-015, ARC-019, ARC-022, ARC-024, ARC-027, ARC-029 |
| INFO | 2 | ARC-012 (positive), ARC-025 (positive) |

### By Category

| Category | Findings |
|----------|----------|
| Module Boundaries | ARC-001, ARC-002, ARC-003, ARC-004, ARC-005 |
| Data Flow | ARC-006, ARC-007 |
| Extension Points | ARC-008, ARC-009, ARC-010, ARC-011 |
| Configuration | ARC-012, ARC-013, ARC-014, ARC-015 |
| State Management | ARC-016, ARC-017, ARC-018, ARC-019 |
| Error Handling | ARC-020, ARC-021, ARC-022 |
| Scalability | ARC-023, ARC-024, ARC-025 |
| Missing Abstractions | ARC-026, ARC-027, ARC-028, ARC-029 |

### Positive Architectural Decisions

1. **Config poisoning prevention** (ARC-012): Separating `trust` into gitignored `local.yaml` is a smart security decision.
2. **Parallel analysis** (ARC-025): The 4-specialist parallel execution with consensus merge is well-designed.
3. **Safe git operations**: Using `core.hooksPath=/dev/null` prevents RCE from malicious repo hooks.
4. **Hard config ceilings**: Budget/turns/diff caps prevent runaway costs even with malicious config.
5. **Secret unstaging**: Automatically removing staged secrets before commit is a good safety net.
6. **Measurer JSON protocol**: The convention of measurers outputting JSON arrays is clean and extensible in concept.
7. **Lazy module loading**: Only sourcing lib files needed for the current command keeps startup fast.

### Priority Recommendations

1. **Decompose `cmd_improve`** (ARC-001) -- this is the single highest-impact refactor. Extract phases into separate functions.
2. **Replace silent error suppression** (ARC-020) -- change `|| true` to logging on critical paths.
3. **Add history rotation/indexing** (ARC-018, ARC-023) -- prevent degradation at scale.
4. **Convention-based measurer discovery** (ARC-008) -- enable extensibility without modifying core code.
5. **Custom verify commands in config** (ARC-009) -- critical for projects with non-standard tooling.
6. **Separate report generation from git operations** (ARC-005) -- cleaner responsibility boundaries.

---

*Report generated by architect-agent. All findings verified by reading actual source code.*
