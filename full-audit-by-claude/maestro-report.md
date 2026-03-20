# KyZN Full System Audit — Maestro Report

**Generated:** 2026-03-20T16:30:00Z
**Auditor:** maestro-agent (Claude Opus 4.6)
**Project:** KyZN v0.4.0
**Files reviewed:** 32 (all source files, templates, measurers, tests, installer, config)

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Workflow Traces](#workflow-traces)
3. [Per-Command Audit](#per-command-audit)
4. [Cross-Cutting Concerns](#cross-cutting-concerns)
5. [Missing Workflows](#missing-workflows)
6. [Automation Readiness](#automation-readiness)
7. [Findings Summary](#findings-summary)

---

## Architecture Overview

```
kyzn (CLI entry)
  |
  +-- lib/core.sh        Logging, config, colors, utils, write_history
  +-- lib/detect.sh       Project type + feature detection
  +-- lib/interview.sh    Interactive config wizard + cmd_init
  +-- lib/measure.sh      Measurement dispatcher + health score + cmd_measure + cmd_status
  +-- lib/prompt.sh       Prompt assembly + system prompt selection
  +-- lib/execute.sh      Claude invocation + safety layers + cmd_improve
  +-- lib/verify.sh       Build/test verification per language
  +-- lib/allowlist.sh    Per-language Claude tool allowlist
  +-- lib/report.sh       Report generation + PR creation
  +-- lib/approve.sh      Approve/reject commands
  +-- lib/history.sh      History display + dashboard + diff + status
  +-- lib/schedule.sh     Cron integration
  +-- lib/analyze.sh      Multi-agent deep analysis + fix phase
  |
  +-- measurers/
  |   +-- generic.sh      TODOs, git health, large files, secrets, docs
  |   +-- node.sh         npm audit, eslint, tsc, coverage, outdated
  |   +-- python.sh       ruff, mypy, pytest coverage, pip-audit
  |   +-- rust.sh         clippy, cargo-audit, test ratio
  |   +-- go.sh           go vet, govulncheck, test ratio
  |
  +-- templates/
  |   +-- system-prompt.md      Base system prompt for Claude
  |   +-- improvement-prompt.md Template with placeholders
  |   +-- analysis-prompt.md    Deep analysis persona
  |
  +-- profiles/            Focus-specific profile overlays
  +-- tests/selftest.sh    37 unit/integration tests
  +-- install.sh           Cross-platform installer
```

### State Storage

```
.kyzn/                    Per-project (git root)
  config.yaml             Committed config
  local.yaml              Gitignored (trust level)
  history/*.json           Run history entries
  reports/*.md             Improvement/analysis reports
  .improve.lock/           Concurrency lock (mkdir-based)

~/.kyzn/                  Global (user home)
  history/*.json           Dual-written history for dashboard
  last-update-check        Timestamp for daily update checks
```

### Global State Variables (in-process)

| Variable | Set by | Used by |
|----------|--------|---------|
| KYZN_VERSION | kyzn | usage, update |
| KYZN_ROOT | kyzn | all modules (template/measurer paths) |
| KYZN_PROJECT_TYPE | detect.sh | measure, prompt, execute, verify, allowlist |
| KYZN_PROJECT_TYPES[] | detect.sh | print_detection |
| KYZN_HAS_TYPESCRIPT | detect.sh | print_detection |
| KYZN_HAS_TESTS | detect.sh | print_detection |
| KYZN_HAS_CI | detect.sh | print_detection |
| KYZN_HAS_DOCKER | detect.sh | print_detection |
| KYZN_HAS_LINTER | detect.sh | print_detection |
| KYZN_HEALTH_SCORE | measure.sh | prompt, report, history |
| KYZN_CATEGORY_SCORES | measure.sh | display_health_dashboard, cmd_measure |
| KYZN_MEASUREMENTS_FILE | measure.sh | prompt, report |
| KYZN_CLAUDE_RESULT | execute.sh | (unused externally) |
| KYZN_CLAUDE_COST | execute.sh | report, history |
| KYZN_CLAUDE_SESSION | execute.sh | (unused externally) |
| KYZN_CLAUDE_STOP_REASON | execute.sh | (unused externally) |

---

## Workflow Traces

### Workflow 1: `kyzn improve`

```
User runs: kyzn improve [--auto] [--focus X] [--model Y] [--budget Z]
  |
  +-- require_git_repo()
  +-- Acquire .kyzn/.improve.lock (mkdir atomic lock)
  +-- Parse CLI args
  +-- detect_project_type() + detect_project_features()
  +-- If no config AND not --auto: run_interview()
  +-- If no config AND --auto: ERROR EXIT
  +-- Load defaults from config
  +-- enforce_config_ceilings() [hard caps: $25, 100 turns, 10000 diff]
  +-- If interactive: confirm settings, choose model, choose budget
  +-- generate_run_id()
  |
  +-- STEP 1: Baseline measurement
  |   run_measurements() -> generic.sh + language-specific measurer
  |   compute_health_score()
  |   display_health_dashboard()
  |   write_history(run_id, "improve", "running")
  |
  +-- STEP 2: Create branch
  |   safe_git checkout -b kyzn/YYYYMMDD-focus-suffix
  |
  +-- STEP 3: Assemble prompt
  |   assemble_prompt(measurements, mode, focus, type)
  |   get_system_prompt(profile)
  |
  +-- STEP 3.5: Baseline failure detection
  |   verify_build() to record pre-existing failures
  |
  +-- STEP 4: Execute Claude
  |   execute_claude(prompt, sys_prompt, budget, turns, type, model, verbose)
  |     +-- build_allowlist()
  |     +-- timeout + claude CLI invocation
  |     +-- Parse JSON output
  |
  +-- STEP 5: Check diff size
  |   Stage all -> numstat -> unstage
  |   If > diff_limit: ABORT (discard branch)
  |   Check for binary files (penalize)
  |
  +-- STEP 6: Verify
  |   verify_build()
  |   If baseline was clean + now fails: ABORT
  |   If baseline had failures: check for NEW failures only
  |
  +-- STEP 7: Re-measure
  |   run_measurements() -> compute_health_score()
  |   Score regression gate: if after < before -> ABORT
  |   Per-category floor: if any cat drops > 5 points -> ABORT
  |
  +-- STEP 8: Generate report + PR
  |   generate_report() -> write markdown -> commit -> push -> gh pr create
  |   If trust=autopilot: gh pr merge --auto --squash
  |
  +-- write_history(run_id, "improve", "completed")
  +-- Release lock
  +-- DONE: "kyzn approve $run_id" or "kyzn reject $run_id"
```

### Workflow 2: `kyzn analyze`

```
User runs: kyzn analyze [--fix] [--single] [--profile X] [--auto]
  |
  +-- require_git_repo()
  +-- Parse args
  +-- detect_project_type() + detect_project_features()
  +-- run_measurements() + display_health_dashboard()
  +-- Choose model profile (opus/hybrid/sonnet)
  +-- Set budgets based on profile
  +-- generate_run_id()
  +-- write_history(run_id, "analyze", "running")
  |
  +-- IF single/focus mode:
  |     Single Opus session with specialist prompt
  |     extract_findings() from JSON response
  |
  +-- IF multi-agent (default):
  |   PHASE 1: 4 parallel specialist sessions
  |     security, correctness, performance, architecture
  |     Each runs as background process via run_specialist()
  |     Progress spinner with phase hints
  |     Wait for all PIDs
  |
  |   PHASE 2: Consensus merge
  |     build_consensus_prompt() with all 4 findings
  |     Single Claude session to deduplicate + rank
  |     Fallback: concatenate + sort by severity
  |
  +-- generate_detailed_report() -> markdown with all findings
  +-- Copy report to kyzn-report.md at project root
  +-- write_history(run_id, "analyze", "completed")
  |
  +-- IF --fix or user chooses to fix:
  |     run_fix_phase()
  |       Create branch: kyzn/YYYYMMDD-analyze-fix-suffix
  |       generate_fix_prompt() from top findings
  |       Execute Sonnet with fix prompt
  |       verify_build()
  |       Commit changes
  |       "kyzn approve $run_id" or "kyzn reject $run_id"
```

### Workflow 3: `kyzn measure`

```
User runs: kyzn measure
  |
  +-- require_git_repo()
  +-- detect_project_type() + detect_project_features() + print_detection()
  +-- run_measurements(project_type)
  |     generic.sh -> TODOs, git health, large files, secrets, docs
  |     language-specific measurer (if applicable)
  +-- compute_health_score()
  +-- display_health_dashboard()
  +-- Show weakest area with suggestion
  +-- write_history("measure-TIMESTAMP", "measure", "completed")
```

### Workflow 4: `kyzn approve <id>` / `kyzn reject <id>`

```
approve <id>:
  +-- Validate run_id (no slashes, no ..)
  +-- Find report: .kyzn/reports/$id.md or $id-analysis.md
  +-- If no report: ERROR
  +-- Update .kyzn/history/$id.json: status="approved", approved_at=timestamp
  +-- Copy to ~/.kyzn/history/$id.json

reject <id> [--reason "..."]:
  +-- Similar validation
  +-- Update history: status="rejected", rejection_reason
  +-- Copy to global history
```

### Workflow 5: `kyzn diff <id>`

```
  +-- Try to find git branch matching "kyzn/" + run_id
  +-- If found: git diff main...$branch
  +-- If not: fall back to reading .kyzn/reports/$id.md
  +-- If neither: ERROR
```

### Workflow 6: `kyzn history` / `kyzn dashboard`

```
history [--global]:
  +-- Read .kyzn/history/*.json (or ~/.kyzn/history/ if --global)
  +-- Display table: Run ID | Status | Before | After | Focus

dashboard:
  +-- Read ~/.kyzn/history/*.json
  +-- Group by project, take latest per project
  +-- Display: PROJECT | LAST RUN | TYPE | RESULT
  +-- Legacy filename parsing for old entries
```

### Workflow 7: `kyzn schedule daily|weekly|off`

```
  +-- require_git_repo()
  +-- Build cron line with project path + kyzn improve --auto
  +-- Tag with # kyzn:project:frequency
  +-- Remove existing entry for same project, add new one
  +-- off: just remove the entry
```

### Workflow 8: `kyzn init`

```
  +-- require_git_repo()
  +-- detect_project_type() + detect_project_features()
  +-- check_missing_tooling() (language-specific hints)
  +-- run_interview() (6 steps: goals, mode, budget, on_fail, trust)
  +-- save_interview_config() -> .kyzn/config.yaml + .kyzn/local.yaml + .kyzn/.gitignore
```

### Workflow 9: `kyzn doctor`

```
  +-- Check required: git, gh, claude, jq, yq
  +-- Check Claude auth (API key or OAuth)
  +-- Check gh auth
  +-- Check optional tools per language
```

### Workflow 10: `kyzn status`

```
  +-- require_git_repo()
  +-- detect + measure + display_health_dashboard()
  +-- Show recent 5 history entries
```

---

## Per-Command Audit

### 1. `kyzn improve` — CORE WORKFLOW

**Happy path:** Works end-to-end. Measures -> branches -> invokes Claude -> verifies -> reports -> PRs.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| IMP-01 | HIGH | **Lock file not cleaned on SIGKILL/OOM.** The `_kyzn_cleanup` trap handles EXIT/INT/TERM but not KILL. If the process is OOM-killed or receives SIGKILL, `.kyzn/.improve.lock/` persists forever. The stale-lock detection checks PID, but if the PID is reused by a different process, the lock is incorrectly considered active. |
| IMP-02 | HIGH | **`safe_git branch -D` on failure can delete work.** When Claude execution fails (line 397), the branch is force-deleted with `-D`. If Claude made partial changes that the user might want to inspect, they are lost. Should use `-d` (safe delete) or at least warn. |
| IMP-03 | MEDIUM | **`eval` usage in `enforce_config_ceilings` is unsafe.** Lines 59-61 and 65-69 of execute.sh use `eval` with variable names that come from the calling function. While currently called with hardcoded names, this pattern is fragile and would be exploitable if the function were called with user-controlled input. |
| IMP-04 | MEDIUM | **Score regression gate uses integer arithmetic on floats.** `compute_health_score` uses `$(( total_score / total_weight ))` which truncates. A baseline of 79.6 and after of 80.4 would both truncate to 79/80 respectively, but the comparison is coarse. The per-category check at lines 492-493 uses jq to compute floats but then truncates with `${var%.*}`. |
| IMP-05 | MEDIUM | **`--auto` mode still requires `gh` for PR creation.** If `gh` is not authenticated or the remote doesn't exist, the improve cycle completes measurements and Claude execution but fails silently at PR push/create (line 87-88 of report.sh). The run is marked "completed" in history but the PR was never created. |
| IMP-06 | LOW | **`safe_git add -A` in step 5 stages everything including new files Claude created, then immediately unstages.** This is a side effect that could confuse git hooks or watchers. The `git diff --numstat` approach could use `--no-index` or a dedicated staging approach. |
| IMP-07 | LOW | **Model choice "haiku" is offered in interactive prompt** (line 285) but provides lowest quality. The codebase philosophy (per no-haiku.md) discourages haiku, yet it is the 3rd option. |
| IMP-08 | MEDIUM | **Cleanup trap does not clean `after_dir`.** The `_kyzn_cleanup` function references `${after_dir:-}` but `after_dir` is declared on line 471, well after the trap is set on line 330. If the process fails between steps 1-6, `after_dir` is unset and the `rm -rf` silently does nothing (correct), but if it fails at step 7, the temp dir leaks only if the trap somehow doesn't fire. Actually, the trap references `${after_dir:-}` correctly. This is fine. |

### 2. `kyzn analyze` — MULTI-AGENT ANALYSIS

**Happy path:** Dispatches 4 parallel Opus sessions, merges findings, generates report, optionally applies fixes.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| ANZ-01 | HIGH | **No concurrency lock for analyze.** Unlike `improve`, `analyze --fix` creates branches and modifies files but has no `.improve.lock` equivalent. Two concurrent `analyze --fix` runs can corrupt the working tree. |
| ANZ-02 | HIGH | **`run_fix_phase` creates a branch but never pushes or creates a PR.** After committing fixes (line 1143), the function just prints "kyzn approve" instructions. But the user is now on the fix branch. They need to manually `git push` and create a PR, or the changes sit on a local branch forever. Compare with `improve` which auto-pushes and creates PRs. |
| ANZ-03 | MEDIUM | **Parallel specialist `run_specialist` functions run as background processes.** If one hangs, the progress loop waits forever (capped only by Claude's own timeout). There is no overall wallclock timeout for the entire multi-agent phase. Four 15-minute Opus sessions could take 15+ minutes even in parallel. |
| ANZ-04 | MEDIUM | **`extract_findings` uses `sed -n '/^\[/,/^\]/p'` which is fragile.** If Claude's response contains JSON arrays in explanatory text before the actual findings array, the wrong array is captured. The function tries multiple extraction strategies as fallbacks, which is good, but the primary strategy can silently capture wrong data. |
| ANZ-05 | LOW | **Single-agent mode always uses `opus` model (line 636) regardless of `--profile sonnet`.** The `$analysis_model` variable is set but not used in the single-agent invocation path. |
| ANZ-06 | MEDIUM | **`analyze --fix` does not check diff size or run score regression gate.** The fix phase skips the diff_limit and score regression checks that `improve` carefully enforces. A Sonnet fix session could make unbounded changes. |
| ANZ-07 | LOW | **Cost tracking is approximate in multi-agent mode** (line 832: `total_cost="~$(awk ...)"` prefix with tilde). History entry gets finding_count but not cost. |

### 3. `kyzn measure`

**Happy path:** Detects project type, runs measurers, displays dashboard. Works correctly.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| MSR-01 | MEDIUM | **Measurers run as separate bash processes with `set -euo pipefail`.** If a measurer crashes (e.g., `jq` not found), the output is empty and `run_measurer` silently logs "(no results from X)". This is by design but means a completely broken environment produces a health score of 0 with no explanation why. |
| MSR-02 | LOW | **Generic measurer's secret scan regex is aggressive.** The pattern `(api[_-]?key|secret[_-]?key|password|token|private[_-]?key)\s*[=:]\s*["\x27][^"\x27]{8,}` would match variable declarations like `const token = "test-token-for-jest"` in test files. No test file exclusion. |
| MSR-03 | LOW | **Node measurer runs `npm audit`, `npx eslint`, `npx tsc`, `npm outdated` even when measuring.** These are read-only but slow. A measure-only run on a large Node project could take 30+ seconds just for measurements. No parallelization of measurers. |
| MSR-04 | LOW | **Test file ratio is a poor proxy for test coverage.** A project with 10 test files and 10 source files gets 100% testing score regardless of actual coverage. This is acknowledged as "rough proxy" but could mislead users. |
| MSR-05 | MEDIUM | **`cmd_measure` writes history with key `health_score` but `cmd_status` doesn't.** The dashboard reads `health_score` from history to display for measure-type entries. Status runs measurements but writes no history. |

### 4. `kyzn approve` / `kyzn reject`

**Happy path:** Updates history file, copies to global history. Works correctly.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| APR-01 | HIGH | **`approve` does not verify the branch was merged.** A user can `kyzn approve <id>` without ever merging the PR. The history says "approved" but the code changes are still on an unmerged branch. There is no link between approval status and git state. |
| APR-02 | MEDIUM | **`reject` does not clean up the branch or PR.** After rejecting, the kyzn branch and open PR remain. The user must manually delete the branch and close the PR. |
| APR-03 | MEDIUM | **`reject` does not validate run_id for path traversal** like `approve` does (lines 19-22). The `run_id` is used directly in `$KYZN_HISTORY_DIR/$run_id.json` without the slash/dot-dot check that `approve` has. |
| APR-04 | LOW | **`approve` searches for report but `reject` does not require a report.** Asymmetric validation: approve fails if no report exists, reject succeeds even with no report/history. |

### 5. `kyzn diff`

**Happy path:** Shows git diff between main and the kyzn branch, or falls back to report file.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| DIF-01 | MEDIUM | **Branch search is fragile.** Line 256: `git branch -a | grep "kyzn/" | grep "$run_id"` matches any branch containing the run_id string. If the user has branches like `kyzn/feature-aabbccdd` and a run_id containing `aabbccdd`, it could match the wrong branch. The `head -1` means it picks the first alphabetical match. |
| DIF-02 | LOW | **Falls back to displaying the full report as "diff."** When no branch is found, `cat "$report_file"` is displayed, which is a markdown report, not a diff. The user gets a report when they expected a diff, with no indication of what happened. |

### 6. `kyzn history` / `kyzn dashboard`

**Happy path:** Lists history entries in a table. Dashboard aggregates across projects.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| HST-01 | MEDIUM | **History files are iterated with `for f in "$history_dir"/*.json`** which gives results in filesystem order (inode order on ext4), not chronological order. Runs appear in arbitrary order, not newest-first or oldest-first. |
| HST-02 | LOW | **Status column ANSI coloring breaks printf alignment.** The escape codes are included in the `%s` width calculation (line 61-63), causing columns to misalign when statuses have different lengths. |
| HST-03 | MEDIUM | **Dashboard `find` + `cat` + `jq -s` pipeline can fail on large history.** With hundreds of history files, the `cat "${_valid_files[@]}"` could exceed argument length limits. Should use `find ... -exec` or `xargs`. |
| HST-04 | LOW | **Dashboard legacy filename parsing** (line 157-158) assumes project names don't contain hyphens. A project named `my-cool-app` with run_id `20260318-120000-aabbccdd` would extract `my-cool-app` correctly only if the sed regex matches the run_id suffix pattern, but `my` would be extracted if the project name contains date-like patterns. |

### 7. `kyzn schedule`

**Happy path:** Adds/removes cron entries tagged by project.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| SCH-01 | HIGH | **Cron line uses `cd` + `&&` without login shell.** Line 47: `cd "$project_dir" && "$kyzn_path" improve --auto >> ...`. Cron runs with minimal PATH. If `jq`, `yq`, `claude`, or `gh` are not in the default PATH, the cron job fails silently. No `PATH=` prefix or shell profile sourcing. |
| SCH-02 | MEDIUM | **No error notification for cron failures.** Output goes to `cron.log` but there is no email, webhook, or alert mechanism. A weekly cron that fails every run would fill the log but never notify the user. |
| SCH-03 | LOW | **`remove_cron` uses `grep -vF` which removes ALL entries for a project.** If a user has both daily and weekly schedules (unlikely but possible), both are removed by `kyzn schedule off`. |

### 8. `kyzn init`

**Happy path:** Runs detection, interview, saves config. Works correctly.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| INI-01 | LOW | **Re-running `init` overwrites existing config without warning.** If the user already has a customized `.kyzn/config.yaml`, running `init` again replaces it entirely. No backup or merge. |
| INI-02 | LOW | **`setup_kyzn_gitignore` overwrites `.kyzn/.gitignore` every time.** If the user added custom entries, they are lost. |

### 9. `kyzn doctor`

**Happy path:** Checks for required and optional tools. Works correctly.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| DOC-01 | LOW | **Claude auth check is unreliable.** Line 289: `claude auth status &>/dev/null 2>&1 || [[ -d "${HOME}/.claude" ]]` — the mere existence of `~/.claude/` directory (which exists on this machine for Claude Code config) does not mean Claude is authenticated. This will always return true on any machine with Claude Code installed, even without auth. |

### 10. `kyzn status`

**Happy path:** Runs measurement and shows recent history. Works correctly.

**Findings:**

| ID | Severity | Finding |
|----|----------|---------|
| STS-01 | LOW | **History display in `cmd_status` shows newest-last** due to filesystem ordering (same as HST-01). The most recent 5 runs are shown but they may not actually be the most recent. |
| STS-02 | LOW | **`cmd_status` loads `history.sh` and `measure.sh` but not `verify.sh`.** Status could optionally show build status, but doesn't. This is a design choice, not a bug. |

---

## Cross-Cutting Concerns

### A. State Transitions

```
Run Lifecycle:
  (none) --[start]--> running --[success]--> completed --[approve]--> approved
                          |                      |
                          +--[failure]--> failed  +--[reject]--> rejected
```

**Finding CCC-01 (MEDIUM):** There is no state machine enforcement. History files are plain JSON that can be edited to any status. The `approve` command does not check that the current status is "completed" — you can approve a "failed" or "running" run. Similarly, `reject` does not validate current status.

**Finding CCC-02 (LOW):** The "running" state has no heartbeat or timeout. If a run is interrupted without the trap firing, the history entry stays "running" forever. The dashboard shows it as running even months later. No staleness detection for history entries (unlike the lock file which checks PID).

### B. Module Interfaces

**Finding CCC-03 (LOW):** Modules communicate through global variables (`KYZN_HEALTH_SCORE`, `KYZN_MEASUREMENTS_FILE`, etc.) rather than return values or output parameters. This works in bash but makes the code fragile — calling `compute_health_score` twice in sequence (as `cmd_improve` does for baseline and after) requires careful tracking of which global holds which value.

**Finding CCC-04 (LOW):** `report.sh` and `execute.sh` both call `safe_git add -A` + `git diff --cached` + `git reset HEAD`. This staging-unstaging dance is duplicated and could interfere if either function is interrupted mid-operation.

### C. Config Poisoning Defense

**Finding CCC-05 (GOOD):** Trust level is correctly stored in `local.yaml` (gitignored), not `config.yaml` (committed). This prevents a malicious PR from setting `trust: autopilot` via a committed config change. The `enforce_config_ceilings` function correctly caps budget ($25), turns (100), and diff limit (10000). This is well-designed.

**Finding CCC-06 (MEDIUM):** `config.yaml` can set `model: opus` which increases cost. While budget is capped at $25, a committed config change from `budget: 2.50` to `budget: 25.00` combined with `model: opus` could cost up to $25 per cron run. The ceiling prevents runaway cost but $25/run could still surprise a user who set up a daily schedule.

### D. Secret Protection

**Finding CCC-07 (GOOD):** Multiple layers: `unstage_secrets` checks for `.env`, `.pem`, `.key` etc.; `check_dangerous_files` blocks CI/pipeline files; `--settings` with `disallowedFileGlobs` blocks Claude from reading sensitive paths; `build_allowlist` restricts Claude's tools. This is comprehensive.

**Finding CCC-08 (MEDIUM):** The `disallowedFileGlobs` setting uses `~/.ssh/**` tilde paths. It's unclear whether the Claude CLI resolves tildes in glob patterns. If not, these restrictions are ineffective.

### E. Error Recovery

**Finding CCC-09 (HIGH):** When `improve` fails after creating a branch, the branch is deleted with `safe_git branch -D`. But if `safe_checkout_back` fails (line 81-84: tries `checkout -`, `checkout main`, `checkout master`), the user is left on the kyzn branch with no main branch to return to. This can happen if the repo uses a non-standard default branch name (e.g., `develop`, `trunk`).

**Finding CCC-10 (MEDIUM):** The `handle_build_failure` "draft-pr" strategy pushes the broken code to remote and creates a draft PR. If the remote repo has branch protection or push restrictions, this fails silently. The function continues to `safe_checkout_back` regardless, potentially leaving the branch both locally and remotely in an inconsistent state.

### F. Dual History Writes

**Finding CCC-11 (LOW):** Every history write goes to both `.kyzn/history/` and `~/.kyzn/history/`. If the global write fails (e.g., disk full, permissions), the local write succeeds. The `approve` and `reject` commands use `cp` to sync, not `write_history`. The two copies can diverge if any write fails.

---

## Missing Workflows

### MW-01: No `kyzn undo <id>` command (MEDIUM)

After `approve` or during review, there is no way to revert changes from a specific run. The user must manually find the branch, revert, and deal with the git state. A `kyzn undo <id>` that creates a revert commit would complete the lifecycle.

### MW-02: No `kyzn list` for active branches (LOW)

The user has no way to see which `kyzn/*` branches exist and their status (merged/unmerged/stale). `git branch | grep kyzn` works but isn't user-friendly.

### MW-03: No multi-project orchestration (LOW)

`kyzn dashboard` shows all projects but there is no `kyzn improve-all` or `kyzn schedule-all` command to run improvements across multiple projects. The cron approach requires setting up each project individually.

### MW-04: No `kyzn config show` / `kyzn config set` (LOW)

Users must manually edit `.kyzn/config.yaml` to change settings after init. A `kyzn config show` and `kyzn config set preferences.budget 5.00` would be more user-friendly.

### MW-05: No webhook/notification on completion (MEDIUM)

For `--auto` and cron usage, there is no way to get notified when a run completes. No Slack, email, or webhook integration. The PR creation serves as a notification for `improve`, but `analyze` and `measure` produce no external signal.

### MW-06: No `kyzn resume` for interrupted runs (LOW)

If an `improve` run is interrupted (Ctrl+C, OOM, network), there is no way to resume from where it left off. The user must start over. The history shows the run as "running" (or "failed" if the trap fired), but there is no resume mechanism.

### MW-07: Analyze + Improve pipeline not connected (MEDIUM)

`analyze` produces findings. `improve` produces code changes. But there is no `kyzn analyze --fix --auto` -> `kyzn approve` pipeline that flows findings into tracked improvements. The fix phase of `analyze` creates a branch but does not create a PR (ANZ-02), breaking the end-to-end flow.

---

## Automation Readiness (`--auto` mode)

### What works well for CI/cron:

1. `kyzn improve --auto` skips all interactive prompts
2. Lock file prevents concurrent runs
3. Config ceilings prevent runaway cost
4. Secret protection layers prevent credential leaks
5. Score regression gate prevents merging worse code
6. Pre-existing failure detection prevents false blame

### What breaks in CI/cron:

| ID | Severity | Issue |
|----|----------|-------|
| AUTO-01 | HIGH | **PATH issues in cron** (SCH-01). `claude`, `jq`, `yq`, `gh` may not be on cron's minimal PATH. |
| AUTO-02 | HIGH | **`gh auth` required for PR creation.** In CI, `gh` needs `GH_TOKEN` or `GITHUB_TOKEN` env var. No documentation or check for this in `--auto` mode. |
| AUTO-03 | MEDIUM | **`kyzn analyze --auto` skips interactive prompts but still requires `prompt_yn` confirmation** (line 585). The `--auto` flag bypasses this, but only if explicitly passed. |
| AUTO-04 | MEDIUM | **No exit code differentiation.** Both "Claude failed" and "score regressed" return exit code 1. CI cannot distinguish between infrastructure failures and intentional aborts. |
| AUTO-05 | LOW | **Cron log rotation not handled.** `cron.log` grows without bound. No logrotate config or size check. |
| AUTO-06 | LOW | **No machine-readable output for CI.** All output is human-readable with ANSI colors (though colors are disabled for non-TTY). JSON output of run results would help CI integration. |

---

## Findings Summary

### By Severity

| Severity | Count | Key Issues |
|----------|-------|------------|
| HIGH | 7 | Lock robustness, analyze has no lock, approve doesn't verify merge, branch -D data loss, cron PATH, error recovery on non-standard branches, no PR from analyze fix |
| MEDIUM | 16 | eval usage, float arithmetic, history ordering, config overwrite cost, state machine gaps, diff size unchecked in analyze, reject path traversal, notification gap |
| LOW | 16 | Haiku offered, test ratio proxy, status ordering, ANSI alignment, doctor auth check, various UX nits |

### Top 5 Actionable Fixes (by impact)

1. **ANZ-01 + ANZ-02:** Add concurrency lock to `analyze --fix` and push+PR at end of fix phase (same as `improve` does). Without this, the analyze-fix workflow is incomplete.

2. **SCH-01 + AUTO-01:** Add PATH setup to cron line: `PATH=/usr/local/bin:/usr/bin:$HOME/.local/bin:$PATH`. Document CI env requirements.

3. **APR-01 + APR-03:** Add path traversal check to `reject` (copy from `approve`). Add optional `--merge` flag to `approve` that actually merges the PR.

4. **CCC-09:** Support configurable default branch: `config_get '.project.default_branch' 'main'` and use that instead of the main/master fallback chain in `safe_checkout_back`.

5. **HST-01:** Sort history files by timestamp (from the JSON content or filename) before displaying.

### Things Done Well

- **Security layers** are comprehensive: allowlists, secret detection, CI file blocking, config ceilings, disallowed file globs
- **Config poisoning defense** with trust in local.yaml is well-designed
- **Score regression gate** with per-category floor prevents sneaky degradation
- **Pre-existing failure detection** prevents blaming Claude for existing test failures
- **Lock file with stale PID detection** is a solid concurrency primitive
- **Self-test suite** with 37 tests covers core functions, detection, config, measurement, and edge cases
- **Cross-platform support** (macOS symlink resolution, portable timeout, bash version check)
- **Installer** with checksum verification for yq and snap incompatibility detection

---

*Generated by maestro-agent (Claude Opus 4.6) as part of the KyZN full audit.*
