# E2E Scenario Audit Report: KyZN CLI

Generated: 2026-03-20T16:30:00Z
Agent: Atlas (E2E Testing)
Model: Claude Opus 4.6 (1M context)

## Overall Status: PASS (with 3 bugs found)

All 10 scenarios were tested. Core functionality works correctly across all project types. Three bugs were discovered, one of which is a functional defect that affects a user-facing command.

---

## Environment

- OS: Ubuntu 24.04.3 LTS (kernel 6.8.0)
- Bash: 5.2+
- KyZN version: 0.4.0
- Required tools: git 2.43.0, gh 2.45.0, claude 2.1.80, jq 1.7, yq 4.52.4
- Selftest suite: 178/178 passing (--quick mode, 4s)

---

## Test Summary

| # | Scenario | Status | Duration | Notes |
|---|----------|--------|----------|-------|
| 1 | `kyzn measure` in temp repo | PASS | ~3s | Correct detection, scoring, history write |
| 2 | `kyzn dashboard` | PASS | ~1s | Correct format, shows all projects |
| 3 | `kyzn doctor` | PASS | ~1s | All required tools found, optional tools listed |
| 4 | `kyzn init` with piped input | PASS | ~1s | Config, local.yaml, .gitignore all created correctly |
| 5 | `kyzn approve` / `kyzn reject` | PASS | ~1s | Status updates, path traversal blocked |
| 6 | `kyzn history` / `kyzn history --global` | PASS | ~1s | Works, but global shows stale test data (see findings) |
| 7 | `.kyzn/` directory structure | PASS | - | history/, reports/ created, .gitignore correct |
| 8 | Lock file mechanism | PASS | ~1s | Stale lock recovery, active lock blocking, no-PID edge case |
| 9 | Different project types | PASS | ~5s | node, python, go, rust, generic all measured correctly |
| 10 | Update check mechanism | PASS | ~2s | Fetch throttled to 1/day, skipped for fast commands |

---

## Scenario Details

### 1. `kyzn measure` in a temporary git repo

**What was tested:** Created a Node.js project with `package.json`, `index.js` (with TODO/FIXME comments), and a short `README.md`. Ran `kyzn measure`.

**Result: PASS**

- Correctly detected project type as `node`
- Ran both `generic.sh` and `node.sh` measurers
- Health score: 89/100 (reasonable given the TODO comments and short README)
- Category breakdown: security 100%, performance 100%, quality 98%, documentation 20%
- Weakest area correctly identified as `documentation`
- History entry written to `.kyzn/history/measure-*.json` with correct fields
- History also written to `~/.kyzn/history/` (global)

**History entry format verified:**
```json
{
  "run_id": "measure-20260320-162934",
  "type": "measure",
  "status": "completed",
  "project": "test-node-project",
  "ts": "2026-03-20T16:29:34Z",
  "health_score": "89"
}
```

### 2. `kyzn dashboard`

**What was tested:** Ran `kyzn dashboard` to verify machine-wide activity summary.

**Result: PASS**

- Shows `KyZN v0.4.0` header
- Table format with PROJECT, LAST RUN, TYPE, RESULT columns
- Shows real projects from global history (mission-control, test-node-project)
- Relative time display works ("just now")
- Health scores displayed correctly ("health 89/100")

### 3. `kyzn doctor`

**What was tested:** Ran doctor to verify prerequisite checks.

**Result: PASS**

- All 5 required tools checked with version numbers: git (2.43.0), gh (2.45.0), claude (2.1.80), jq (1.7), yq (4.52.4)
- Claude auth detected via existing `~/.claude` directory
- GitHub auth verified via `gh auth status`
- Optional tools listed per project type (npm, npx, ruff, pytest, go present; eslint, tsc, mypy, cargo, govulncheck absent)
- Final message: "All required tools found. KyZN is ready."
- Exit code: 0

### 4. `kyzn init` with piped input

**What was tested:** Created a new Node.js repo and piped answers to `kyzn init`: approach=auto, mode=deep, budget=$2.50, on_fail=report, trust=guardian.

**Result: PASS**

- Project type correctly detected as `node`
- Missing optional tools warned (eslint, tsc) with install hints
- All interview prompts accepted piped input correctly
- Generated files verified:
  - `.kyzn/config.yaml`: correct YAML with project name, type, preferences (mode, model, budget, max_turns, diff_limit, on_build_fail), and focus priorities
  - `.kyzn/local.yaml`: trust level stored separately (gitignored)
  - `.kyzn/.gitignore`: correctly ignores `history/`, `reports/`, `local.yaml`

### 5. `kyzn approve` and `kyzn reject`

**What was tested:** Created fake history entries and reports, then tested approve/reject workflows.

**Result: PASS**

- **Approve:** Status updated from "completed" to "approved", `approved_at` timestamp added, project name preserved
- **Reject with reason:** Status updated to "rejected", `rejected_at` and `rejection_reason` fields added
- **Reject without reason:** Works, stores empty string for rejection_reason
- **Missing report:** Returns error "No report found for run nonexistent-run" with exit code 1
- **Missing run_id:** Returns error "Usage: kyzn approve <run-id>" with exit code 1
- **Path traversal:** `kyzn approve "../../../etc/passwd"` correctly blocked with "Invalid run ID" and exit code 1
- Both approve and reject copy to global history

### 6. `kyzn history` and `kyzn history --global`

**What was tested:** Local project history and global history display.

**Result: PASS (with observation)**

- Local history: Correctly shows project-scoped entries with run ID, status (colored), before/after scores, focus
- Global history: Shows all entries across projects
- Empty history: Correctly shows "No runs yet" message

**Observation:** Global history directory accumulated 81 files from previous selftest runs (test-approve-001, test-reject-001 repeated with tmp.* prefixes from /tmp sandboxes). This is not a bug per se -- the selftest creates real entries in global history -- but it causes visual noise. The selftest could clean up after itself.

### 7. `.kyzn/` directory structure

**What was tested:** Verified directory layout after various operations.

**Result: PASS**

Created structure:
```
.kyzn/
  config.yaml       (committed)
  local.yaml        (gitignored)
  .gitignore         (gitignore rules)
  history/           (gitignored, run JSON files)
  reports/           (gitignored, markdown reports)
```

Global structure:
```
~/.kyzn/
  last-update-check  (epoch timestamp)
  history/           (global copies of all run history)
```

### 8. Lock file mechanism

**What was tested:** Three lock scenarios exercised directly against the lock logic.

**Result: PASS**

| Test | Input | Expected | Actual |
|------|-------|----------|--------|
| Stale lock (dead PID 99999999) | mkdir fails, PID not running | Detect stale, remove, reacquire | Correct |
| Active lock (current shell PID) | mkdir fails, PID is alive | Block with error | Correct |
| No PID file in lock dir | mkdir fails, empty PID | Detect stale, remove, reacquire | Correct |

The lock mechanism uses `mkdir` (atomic on all filesystems) with a PID file inside for stale detection. This is a robust design.

### 9. Different project types

**What was tested:** Created minimal projects for each supported type and ran `kyzn measure`.

| Type | Detection | Measurers Run | Score | Categories Measured |
|------|-----------|---------------|-------|---------------------|
| Node.js | `package.json` | generic + node | 89/100 | security, performance, quality, documentation |
| Python | `pyproject.toml` | generic + python | 79/100 | security, testing, performance, quality, documentation |
| Go | `go.mod` | generic + go | 66/100 | security, testing, performance, quality, documentation |
| Rust | `Cargo.toml` | generic + rust | 90/100 | security, performance, quality, documentation |
| Generic | (no manifest) | generic only | 86/100 | security, performance, quality, documentation |

**Observations:**
- Go project scored 0% on testing (no `*_test.go` files) -- correct behavior
- Python correctly found test files and computed test ratio
- Rust measured without cargo (not installed) -- gracefully skipped cargo-specific checks
- Generic project measured git health, TODOs, large files, secrets, and README only

### 10. Update check mechanism

**What was tested:** Verified the daily fetch throttle, fast-command bypass, and forced fetch behavior.

**Result: PASS**

- `last-update-check` file stores epoch timestamp in `~/.kyzn/`
- Commands that skip update check: version, help, doctor, selftest (confirmed)
- Fresh timestamp check: within 86400s of last check, fetch is skipped
- Forced fetch (timestamp set to 0): `git fetch origin` runs, timestamp updated
- Local HEAD vs remote HEAD comparison works (both equal = no update message)

---

## Bugs Found

### BUG 1: `kyzn diff` crashes when no matching branch exists (MEDIUM)

**File:** `lib/history.sh`, line 256

**Problem:** The branch detection pipeline uses `grep "kyzn/"` which returns exit code 1 when no match is found. Under `set -euo pipefail`, this causes the entire script to exit before reaching the report fallback logic.

**Reproduction:**
```bash
cd /path/to/repo-with-history
kyzn diff test-run-001  # Has a report file but no matching git branch
# Exits with code 1, no error message shown, report not displayed
```

**Root cause:** Line 256:
```bash
branch=$(git branch -a 2>/dev/null | grep "kyzn/" | grep "$run_id" | head -1 | tr -d ' *' | sed 's|^remotes/origin/||')
```

The `grep "kyzn/"` step fails (exit 1) when no branches match the pattern. With `pipefail`, the entire pipeline returns non-zero, and `set -e` kills the script.

**Fix:** Append `|| true` to the pipeline:
```bash
branch=$(git branch -a 2>/dev/null | grep "kyzn/" | grep "$run_id" | head -1 | tr -d ' *' | sed 's|^remotes/origin/||' || true)
```

**Impact:** Users cannot view reports for runs whose branches have been deleted (a normal workflow after merging a PR).

---

### BUG 2: Global history pollution from selftest runs (LOW)

**File:** `tests/selftest.sh`

**Problem:** The selftest creates approve/reject entries in `~/.kyzn/history/` and never cleans them up. Over time (and repeated test runs), the global history accumulates dozens of test artifacts, polluting `kyzn dashboard` and `kyzn history --global` output.

**Current state:** 81 files in `~/.kyzn/history/`, of which ~70 are selftest artifacts.

**Fix:** The selftest should either:
1. Clean up global history entries it creates, or
2. Use `KYZN_GLOBAL_DIR` override to redirect global writes to a temp dir during testing

**Impact:** Cosmetic only. Dashboard shows real data but buried among test entries.

---

### BUG 3: `kyzn diff` with no matching run silently returns 0 (LOW, edge case)

**File:** `lib/history.sh`, line 256-270

**Problem:** When `cmd_diff` is called with a run ID that has no branch AND a report file does exist (the `$KYZN_REPORTS_DIR/$run_id.md` path), the function should `cat` the report. However, due to Bug 1 above, execution never reaches this code path. If Bug 1 is fixed, then this path works correctly.

This is a consequence of Bug 1, not a separate issue.

---

## Edge Cases Tested

| Case | Expected | Actual | Status |
|------|----------|--------|--------|
| `kyzn measure` outside git repo | Error message, exit 1 | "Not a git repository" + exit 1 | PASS |
| `kyzn foobar` (unknown command) | Error + usage, exit 1 | "Unknown command: foobar" + usage + exit 1 | PASS |
| `kyzn help` | Usage text, exit 0 | Full usage displayed, exit 0 | PASS |
| `kyzn approve` (no args) | Usage error, exit 1 | "Usage: kyzn approve <run-id>" + exit 1 | PASS |
| `kyzn reject` without reason | Success, empty reason | Success, empty string stored | PASS |
| Path traversal in approve | Blocked | "Invalid run ID" + exit 1 | PASS |
| `config_get` with no config | Returns default value | Returns "fallback-default" | PASS |
| `kyzn history` in empty project | Info message | "No runs yet" | PASS |
| `kyzn status` | Runs measure + shows history | Correct output with both | PASS |

---

## Code Quality Observations

### Strengths
1. **Robust lock mechanism** -- `mkdir` atomic lock with PID-based stale detection handles all edge cases (dead process, no PID file, active process)
2. **Config poisoning prevention** -- Hard ceilings on budget ($25), turns (100), diff lines (10000) enforced via `enforce_config_ceilings`
3. **Security-conscious design** -- Secret file unstaging, dangerous file detection (CI pipelines), disallowed file globs for sensitive paths, git hooks disabled during execution
4. **Path traversal prevention** in approve/reject (rejects `..` and `/` in run IDs)
5. **Graceful degradation** -- Missing optional tools are skipped without errors; measurers handle command absence cleanly
6. **Dual-write history** -- Local project history + global machine-wide history
7. **Trust level separation** -- Stored in `local.yaml` (gitignored) to prevent config poisoning via committed files
8. **Comprehensive selftest** -- 178 tests covering core functionality, edge cases, and regression scenarios

### Minor Issues
1. The `vet_score` calculation in `go.sh` (line 17) does `vet_score=$(( vet_score - vet_issues * 5 ))` but `vet_issues` counts ALL lines from go vet output including blank lines, not just issue lines. When go vet returns no issues, `vet_output` is empty but `grep -c '^'` on empty string returns 0, so this works correctly in practice.
2. The health score is stored as a string in history JSON (`"health_score": "89"`) rather than a number. This does not cause issues since jq handles both.

---

## Recommendations

### Critical (Fix Before Next Release)
1. **Fix `kyzn diff` pipefail crash** (Bug 1) -- Single-line fix, affects user-facing functionality

### Suggested
2. **Clean up selftest global artifacts** (Bug 2) -- Wrap selftest in a `KYZN_GLOBAL_DIR` override
3. **Add `--json` output flag** to `kyzn measure` and `kyzn history` for scripting/CI integration
4. **Consider adding `kyzn clean`** to remove stale history and lock files

---

## Artifacts

- Test sandbox: `/tmp/kyzn-atlas-Q9HJ1T/` (temporary, will be cleaned by OS)
- Selftest results: 178/178 passing (4s)
- This report: `full-audit-by-claude/atlas-report.md`
