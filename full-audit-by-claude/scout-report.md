# Codebase Report: KyZN Full Audit
Generated: 2026-03-20

## Summary

KyZN is a Bash CLI tool (v0.4.0) that orchestrates Claude Code to autonomously improve codebases. The architecture is clean and well-decomposed into 13 library modules. The codebase shows strong engineering discipline — branch isolation, budget caps, score regression gates, pre-existing failure detection, and supply-chain-safe installer. Most findings are LOW to MEDIUM severity. A few HIGH items need attention, particularly a trust field committed to the wrong config file and a CRIT-level undefined variable in the `analyze` flow.

---

## Project Structure

```
kyzn/
├── kyzn                    # Entry point + subcommand router (341 lines)
├── install.sh              # One-liner installer with checksum verification (442 lines)
├── lib/
│   ├── core.sh             # Colors, logging, config helpers, utilities (267 lines)
│   ├── detect.sh           # Project type + feature detection (114 lines)
│   ├── interview.sh        # Interactive setup questionnaire (343 lines)
│   ├── measure.sh          # Measurement dispatcher + health scoring (243 lines)
│   ├── prompt.sh           # Prompt assembly for Claude Code (90 lines)
│   ├── execute.sh          # Claude invocation + cmd_improve orchestration (586 lines)
│   ├── verify.sh           # Build/test verification per language (251 lines)
│   ├── allowlist.sh        # Per-language tool permissions (75 lines)
│   ├── analyze.sh          # Multi-agent Opus analysis (1154 lines)  ← LARGEST
│   ├── report.sh           # Report generation + PR creation (186 lines)
│   ├── approve.sh          # Approve/reject handling (109 lines)
│   ├── history.sh          # Run history + dashboard (306 lines)
│   └── schedule.sh         # Cron integration (70 lines)
├── measurers/
│   ├── generic.sh          # TODOs, secrets, git health, docs (154 lines)
│   ├── node.sh             # npm audit, eslint, tsc, coverage (151 lines)
│   ├── python.sh           # ruff, mypy, pytest-cov, pip-audit (131 lines)
│   ├── rust.sh             # cargo clippy, cargo audit (85 lines)
│   └── go.sh               # go vet, govulncheck (82 lines)
├── templates/
│   ├── system-prompt.md    # Claude Code system prompt for improve
│   ├── analysis-prompt.md  # Analysis-mode system prompt
│   └── improvement-prompt.md # User prompt template
├── profiles/
│   ├── security.md
│   ├── testing.md
│   ├── performance.md
│   ├── quality.md
│   └── documentation.md
├── tests/
│   └── selftest.sh         # Self-test suite (1584 lines, ~150 assertions)
├── docs/
│   ├── research-autonomous-agents.md
│   └── research-self-improving-agents.md
├── .kyzn/                  # Project's own kyzn config
│   ├── config.yaml         # Committed config (has ISSUE — see below)
│   └── .gitignore          # Ignores history/, reports/, (MISSING: local.yaml)
├── .kyzn.example.yaml      # Template config
├── .gitignore
├── .github/
│   └── workflows/shellcheck.yml
├── LICENSE                 # MIT
└── README.md               # Comprehensive (400+ lines)
```

---

## Questions Answered

### Q1: Is code organization logical?

YES — the split is clean:
- `kyzn` (entry point) does only routing + update check + doctor command
- All state and logic is in `lib/`
- Lazy loading pattern: each subcommand sources only its required modules
- `measurers/` correctly separated from `lib/` (they're executable scripts, not sourced libraries)
- `templates/` and `profiles/` correctly separate prompt content from code

### Q2: Are naming conventions consistent?

YES — with one exception:
- Files: lowercase, no separator (`core.sh`, `analyze.sh`) — consistent
- Functions: `snake_case` with `cmd_` prefix for top-level commands — consistent
- Variables: `KYZN_` prefix for exported globals, local prefixed with `_` for internal — consistent
- Exception: `config_set` and `config_set_str` in `core.sh` are functionally identical (both use `strenv(VALUE)`) — one is dead code

### Q3: Dead code?

- `config_set_str()` in `lib/core.sh` (lines 108-116) is identical to `config_set()` (lines 97-105). Zero callers of `config_set_str` exist in the codebase. DEAD CODE.
- `tests_ok` variable in `lib/verify.sh` (line 47) is declared in a comment as "reserved for future per-step tracking" but never used. Harmless dead comment, not actual dead code.

### Q4: Missing files?

- `kyzn-report.md` (written to project root by `kyzn analyze`) is NOT in `.gitignore`. When kyzn analyzes itself, the report lands in the root and will show as an untracked file.
- `.kyzn/local.yaml` is NOT in `.kyzn/.gitignore`. The file `setup_kyzn_gitignore()` in `interview.sh` writes `local.yaml` to `.kyzn/.gitignore`, but the file at `.kyzn/.gitignore` currently only has `history/` and `reports/`. This means `local.yaml` is not covered if the file was hand-edited or never regenerated.
- No `CONTRIBUTING.md` (low priority — not uncommon for solo projects).
- No `CHANGELOG.md` (low priority).
- No `SECURITY.md` (medium — the tool manipulates code and creates PRs; a vulnerability disclosure process matters).

### Q5: Import/source chains — circular or fragile paths?

No circular dependencies. Source chain is strictly linear:
```
kyzn → core.sh (always)
kyzn → detect.sh (when needed)
kyzn → interview.sh → detect.sh (requires detect_project_type)
kyzn → measure.sh (requires core.sh functions)
kyzn → execute.sh → allowlist.sh, verify.sh (inline, no additional sources)
kyzn → analyze.sh (self-contained)
kyzn → report.sh (uses execute.sh globals: KYZN_CLAUDE_COST)
kyzn → history.sh
kyzn → approve.sh
kyzn → schedule.sh
```

The `report.sh` module reads `KYZN_CLAUDE_COST`, `KYZN_CLAUDE_RESULT`, etc. that are set by `execute.sh`. This is an implicit coupling via globals — not circular, but fragile: if `generate_report` is called without `execute_claude` having run first, `KYZN_CLAUDE_COST` is empty and the report shows `$unknown`.

### Q6: File sizes — anything bloated?

- `analyze.sh` at 1154 lines is the largest lib file by a significant margin. It handles: specialist prompt building (4 specialists × ~50 lines), parallel execution + progress monitor, consensus merging, detailed report generation, fix prompt generation, and `cmd_analyze` orchestration. This is a legitimate split concern — could be split into `analyze-prompts.sh`, `analyze-run.sh`, `analyze-report.sh`. Not a bug, but a maintainability risk as the feature grows.
- `selftest.sh` at 1584 lines is large but appropriate for a test file.

---

## Findings

### CRITICAL

#### C1: `trust` field committed to `.kyzn/config.yaml` — security policy bypass possible
**File:** `.kyzn/config.yaml`, line 14
**Severity:** CRITICAL

The `trust` key appears in the committed `.kyzn/config.yaml`:
```yaml
  trust: guardian
```

The design intent (documented in `report.sh` line 73-76 and README) is that `trust` must only live in `.kyzn/local.yaml` (gitignored) to prevent config poisoning — an attacker controlling a PR cannot flip the project to `autopilot` auto-merge mode. However, `trust: guardian` is in the committed config. `report.sh` reads trust via `local_config_get '.trust' 'guardian'`, which reads `local.yaml` — so the committed value in `config.yaml` is currently not read. But this is misleading and one refactor away from accidentally reading it, or from a future contributor adding `config_get` instead of `local_config_get`.

The root cause is that `save_interview_config()` in `interview.sh` correctly writes trust to `local.yaml` only, but the project's own `.kyzn/config.yaml` was written by a different path (possibly hand-edited or from an older version).

**Impact:** Currently non-exploitable because `report.sh` explicitly uses `local_config_get`. But the committed `trust` key is documentation/design confusion and a latent security risk.

**Fix:** Remove `trust:` from `.kyzn/config.yaml`. Add a validation in `cmd_improve` that warns if `trust` appears in the committed config.

---

### HIGH

#### H1: `config_set` and `config_set_str` are identical — dead function
**File:** `lib/core.sh`, lines 97-116
**Severity:** HIGH (maintainability)

`config_set_str()` (lines 108-116) is byte-for-byte identical to `config_set()` (lines 97-105). Neither function is clearly distinguished in intent. Grep confirms `config_set_str` is never called anywhere in the codebase. This dead function creates confusion: future contributors may call `config_set_str` thinking it handles strings differently, or copy it rather than using `config_set`.

**Fix:** Delete `config_set_str`. It is dead code.

#### H2: `kyzn-report.md` written to project root, not gitignored
**File:** `lib/analyze.sh`, line 854-855; `.gitignore`
**Severity:** HIGH

`cmd_analyze` copies the analysis report to `kyzn-report.md` in the project root. This file is NOT in `.gitignore`. When kyzn is used on any project (including itself), `kyzn-report.md` will appear as an untracked file after every analysis run. Users either:
1. Accidentally commit it (pollutes project history)
2. Are constantly bothered by `git status` noise
3. Must manually add it to every project's `.gitignore`

The README mentions `kyzn-report.md` prominently as the output location, so users expect it. But the installer and `kyzn init` never add it to the user project's `.gitignore`.

**Fix:** In `setup_kyzn_gitignore()` (interview.sh), add `kyzn-report.md` to the written `.gitignore` entries. Also add it to the project-level `.gitignore` in the kyzn repo itself.

#### H3: `.kyzn/local.yaml` missing from `.kyzn/.gitignore`
**File:** `.kyzn/.gitignore`
**Severity:** HIGH

The file `.kyzn/.gitignore` currently contains:
```
history/
reports/
```

It does NOT contain `local.yaml`. The `setup_kyzn_gitignore()` function in `interview.sh` writes the correct content including `local.yaml`, but the `.kyzn/.gitignore` in the kyzn repository itself was not updated to match. If a user runs `kyzn init` on a fresh project, `local.yaml` IS gitignored correctly. But if someone forked this repo and ran `kyzn init` on kyzn itself, `local.yaml` could be committed.

**Fix:** Add `local.yaml` to `.kyzn/.gitignore`.

#### H4: `eval` in `enforce_config_ceilings` is fragile — use namerefs instead
**File:** `lib/execute.sh`, lines 52-74
**Severity:** HIGH (security + correctness)

`enforce_config_ceilings` uses `eval` to read and write caller variables by name:
```bash
eval "_cur_budget=\$$_var_budget"
eval "$_var_budget=$max_budget"
```

While the variable names come from the calling code (not user input), this pattern is fragile — a mis-typed variable name silently produces wrong behavior, and any future code that passes user-derived variable names would create code injection. Bash 4.3+ (which kyzn already requires) supports namerefs (`local -n`) which are safer and clearer.

**Fix:**
```bash
enforce_config_ceilings() {
    local -n _budget=$1 _turns=$2 _diff=$3
    local max_budget=25 max_turns=100 max_diff=10000
    if awk "BEGIN {exit !($_budget > $max_budget)}"; then
        log_warn "Budget $_budget exceeds max ($max_budget). Capping."
        _budget=$max_budget
    fi
    ...
}
```

---

### MEDIUM

#### M1: README test count claims are inconsistent
**File:** `README.md`
**Severity:** MEDIUM (accuracy)

The README badge claims "156 passing tests" but the body text says:
- Line 378: "156 tests (43 core + 4 stress)"
- Line 386: "Quick tests (147 cases)"

The actual assertion count in `selftest.sh` is approximately 150 (grep count). The numbers 156, 147, and "43 core + 4 stress" are internally inconsistent. This erodes trust in the documentation.

**Fix:** Run `kyzn selftest --full` and update all three mentions to match the actual count.

#### M2: `govulncheck` JSON flag is wrong
**File:** `measurers/go.sh`, line 35
**Severity:** MEDIUM (silent failure)

```bash
vuln_output=$(govulncheck -json ./... 2>/dev/null) || true
```

The govulncheck CLI flag for JSON output is `--json` (double dash), not `-json` (single dash). With a wrong flag, `govulncheck` may print an error to stderr (which is suppressed by `2>/dev/null`) and exit non-zero (ignored by `|| true`). The result: the security measurement silently produces no data for Go projects, so they always get 100/100 on security without any actual scan.

**Fix:**
```bash
vuln_output=$(govulncheck --json ./... 2>/dev/null) || true
```

#### M3: Missing `local.yaml` in `setup_kyzn_gitignore` generates incomplete gitignore content
**File:** `lib/interview.sh`, lines 264-272
**Severity:** MEDIUM

The `setup_kyzn_gitignore()` function writes:
```
history/
reports/
local.yaml
```

But `.kyzn/.gitignore` in the kyzn repo only has `history/` and `reports/`. This means the kyzn project's own config directory is not self-consistent with what it writes to user projects. (Related to H3 above, but noting the write side here.)

#### M4: Parallel analysis result costs cannot be summed (silent approximation)
**File:** `lib/analyze.sh`, line 831
**Severity:** MEDIUM (UX/accuracy)

The multi-agent analyze mode runs 4 Opus sessions in parallel but cannot sum their costs. The code comment says "Total cost is approximate (we can't easily sum parallel costs)". The specialist cost is tracked per-agent via `run_specialist` writing to JSON, but the aggregation sums the data correctly from the files. However, if a specialist fails, its cost is 0 in the total — the user under-counts actual spend.

This is a known limitation acknowledged in a comment, but it's not surfaced to the user. A "cost is approximate" disclaimer should appear in the terminal output.

#### M5: `kyzn doctor` suggests haiku as a valid model option
**File:** `lib/execute.sh`, lines 282-290
**Severity:** MEDIUM (UX — inconsistency with design intent)

The interactive model picker in `cmd_improve` offers:
```
1) sonnet  — fast, cost-effective (recommended)
2) opus    — highest quality, slower
3) haiku   — cheapest, basic improvements
```

The README clearly says KyZN uses Sonnet for improve and Opus for analyze. Offering haiku as a valid model is misleading — haiku is unlikely to produce meaningful code improvements and will frustrate users who pick it for cost savings.

**Fix:** Either remove haiku from the picker, or add a clear warning: "haiku — minimal quality, may produce incorrect changes".

#### M6: `schedule.sh` cron command does not set `PATH` or use absolute kyzn path reliably
**File:** `lib/schedule.sh`, line 47
**Severity:** MEDIUM

The generated cron line:
```bash
$cron_expr cd "$project_dir" && "$kyzn_path" improve --auto >> ...
```

Cron runs with a minimal environment — `PATH` typically does not include `~/.local/bin` where kyzn's dependencies (jq, yq, gh, claude) are installed. The `kyzn_path` is captured at schedule-time via `command -v kyzn`, which is correct. But the resolved `kyzn` binary then sources `lib/core.sh` which calls `jq` and `yq` — and these may not be on cron's `PATH`.

**Fix:** Prepend `PATH=/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin` in the cron line, or detect the actual paths at schedule time and inject them.

#### M7: `generate_category_comparison` uses raw score averages, not weighted scores
**File:** `lib/report.sh`, lines 126-128
**Severity:** MEDIUM (accuracy)

```bash
before_val=$(jq -r ... '[.[] | select(.category == $c) | .score] | if length > 0 then (add / length) else "-" end' ...)
```

The report's category comparison table shows a simple average of raw scores, but `compute_health_score()` in `measure.sh` computes `(sum of scores * 100) / (sum of max_scores)` — a weighted average. These two formulas produce different numbers when measurements have different `max_score` values. The report table can show numbers inconsistent with the health dashboard.

---

### LOW

#### L1: `relative_time()` uses GNU-specific `date -d` with macOS fallback — fragile
**File:** `lib/history.sh`, lines 79-81
**Severity:** LOW

```bash
if then_epoch=$(date -d "$ts" +%s 2>/dev/null); then :
elif then_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null); then :
```

The macOS `date` fallback uses `-jf` with a format string. However, the timestamp stored is `%Y-%m-%dT%H:%M:%SZ` (UTC with literal Z). The macOS `date` command does not understand the trailing `Z` as a timezone indicator without extra handling, so the macOS fallback may silently fail and return `-` for all timestamps.

#### L2: `check_dangerous_files` in `handle_build_failure` draft-pr mode does not abort on CI files
**File:** `lib/execute.sh`, lines 572-583
**Severity:** LOW

In the `draft-pr` failure path, the code calls `check_dangerous_files` which will log a warning about CI files but then proceed to commit and push them. In the normal (success) flow via `report.sh`, CI files are also unstaged then committed — but the unstaging happens BEFORE the commit. In the draft-pr failure path, the order is: `safe_git add -A` → `unstage_secrets` → `check_dangerous_files` → `safe_git commit`. This is correct. However, `check_dangerous_files` calls `git reset HEAD -- <files>` to unstage CI files, but this reset is not checked for success. If the reset silently fails (e.g., on older git), CI files could be committed.

#### L3: `cmd_status` loads history data without proper sorting — order is filesystem-dependent
**File:** `lib/history.sh`, lines 295-305
**Severity:** LOW

```bash
for f in "$KYZN_HISTORY_DIR"/*.json; do
```

The glob expands in filesystem order (typically inode order, not chronological). On some filesystems the "recent runs" shown may not be the 5 most recent. The `cmd_history` function has the same issue. The dashboard (`cmd_dashboard`) correctly uses jq's `sort_by(.ts)` — the inconsistency is confusing.

**Fix:** Use `ls -t "$KYZN_HISTORY_DIR"/*.json` or sort by embedded timestamp.

#### L4: `binary_count` logic in diff checking is incorrect
**File:** `lib/execute.sh`, lines 414-419
**Severity:** LOW

```bash
binary_count=$(echo "$numstat" | grep -c '^-' 2>/dev/null) || true
```

`git diff --numstat` marks binary files as `-  -  filename` (dashes for the counts). But this grep matches any line starting with `-`, which in practice might match legitimate diff lines or return incorrect counts. The correct check is:

```bash
binary_count=$(echo "$numstat" | grep -cP '^-\t-\t' 2>/dev/null) || true
```

#### L5: `update` command recurses into `kyzn version` using a subshell — fragile
**File:** `kyzn`, lines 220-227
**Severity:** LOW

```bash
new_ver=$(bash "$KYZN_ROOT/kyzn" version 2>/dev/null || echo "unknown")
```

After a `git pull`, the new version of kyzn is invoked via `bash` to get the version string. This spawns a full shell with a new environment, re-sources `core.sh`, and then check_for_updates runs (which does a git fetch). For the "just updated" case, the update check is redundant and slows down the `kyzn update` command by 5 seconds.

**Fix:** Read the version directly from the updated file:
```bash
new_ver=$(grep 'KYZN_VERSION=' "$KYZN_ROOT/kyzn" | head -1 | cut -d'"' -f2 || echo "unknown")
```

#### L6: `selftest.sh` test count in README badge is hardcoded and will drift
**File:** `README.md`, line 18
**Severity:** LOW

The badge `tests-156%20passing` is hardcoded. As tests are added or removed, the badge will show stale numbers. This should either be generated dynamically by CI or updated as part of the release process.

#### L7: `docs/` research files are internal artifacts, not user documentation
**File:** `docs/`
**Severity:** LOW

`docs/research-autonomous-agents.md` and `docs/research-self-improving-agents.md` are internal research notes, not user-facing documentation. They're not linked from the README. Shipping them in the public repo is fine but may confuse contributors who expect `docs/` to contain guides.

---

## Conventions Discovered

### Naming
| Element | Convention | Example |
|---------|-----------|---------|
| Library files | `<module>.sh` | `core.sh`, `execute.sh` |
| Commands | `cmd_<subcommand>()` | `cmd_improve`, `cmd_analyze` |
| Global exports | `KYZN_` prefix | `KYZN_HEALTH_SCORE`, `KYZN_ROOT` |
| Internal locals | `_` prefix for loop vars | `_wh_project`, `_cur_budget` |
| Config keys | snake_case YAML | `on_build_fail`, `max_turns` |
| Run IDs | `YYYYMMDD-HHMMSS-<hex8>` | `20260318-103733-760baee7` |
| Branch names | `kyzn/<date>-<focus>-<hex>` | `kyzn/20260318-security-760baee7` |

### Patterns
| Pattern | Usage | Location |
|---------|-------|---------|
| Lazy module loading | Source libs only when needed | `kyzn` main() |
| Trap-based cleanup | EXIT/INT/TERM | `execute.sh` `_kyzn_cleanup` |
| Lock directory | Atomic concurrency guard | `execute.sh` `.improve.lock` |
| Nameref for output params | Returning values from functions | `interview.sh` `_ref_priorities` |
| Global result accumulation | Measurer pattern | All `measurers/*.sh` |
| Dual-write history | Local + global | `core.sh` `write_history` |

### Testing
- Location: `tests/selftest.sh` (monolithic)
- Framework: custom assert_eq/assert_contains/assert_not_contains
- Invocation: `kyzn selftest [--quick|--full|--stress]`
- CI: ShellCheck via `.github/workflows/shellcheck.yml` (not test runner)

---

## Architecture Map

```
User
  │
  ▼
kyzn (entry)
  │── cmd_doctor (inline)
  │── cmd_improve → detect → measure → interview? → execute_claude → verify → report → PR
  │── cmd_analyze → detect → measure → [4x Opus parallel] → consensus → report → fix?
  │── cmd_measure → detect → measure → display
  │── cmd_status  → detect → measure → history (last 5)
  │── cmd_init    → detect → interview → config write
  │── cmd_history → history files (JSON)
  │── cmd_dashboard → global history files
  │── cmd_approve/reject → history JSON mutation
  │── cmd_diff    → git diff or report fallback
  │── cmd_schedule → crontab mutation
  │── update      → git pull (inline)
  │── selftest    → bash tests/selftest.sh
  └── version     → echo KYZN_VERSION

Data stores:
  .kyzn/config.yaml      (committed project config)
  .kyzn/local.yaml       (gitignored trust level)
  .kyzn/history/*.json   (per-project run records)
  .kyzn/reports/*.md     (improvement + analysis reports)
  ~/.kyzn/history/*.json (global cross-project dashboard)
```

---

## Key Files
| File | Purpose | Entry Points |
|------|---------|-------------|
| `kyzn` | Entry point + routing | `main()` |
| `lib/core.sh` | Foundation | All lib files source this |
| `lib/execute.sh` | Claude invocation + improve flow | `execute_claude()`, `cmd_improve()` |
| `lib/analyze.sh` | Multi-agent analysis | `cmd_analyze()` |
| `lib/measure.sh` | Health scoring | `run_measurements()`, `compute_health_score()` |
| `lib/verify.sh` | Build/test gates | `verify_build()` |
| `lib/report.sh` | PR creation | `generate_report()` |
| `install.sh` | Installer | Direct execution |
| `tests/selftest.sh` | Test suite | `kyzn selftest` |

---

## Prioritized Recommendations

1. **[CRITICAL] Remove `trust: guardian` from `.kyzn/config.yaml`** — it defeats the config poisoning protection.
2. **[HIGH] Delete `config_set_str()` from `lib/core.sh`** — it is dead code identical to `config_set()`.
3. **[HIGH] Add `kyzn-report.md` to `.gitignore` and to `setup_kyzn_gitignore()`** — prevents accidental commits after analysis runs.
4. **[HIGH] Add `local.yaml` to `.kyzn/.gitignore`** — makes the repo self-consistent.
5. **[HIGH] Replace `eval` in `enforce_config_ceilings` with namerefs** — safer, cleaner.
6. **[MEDIUM] Fix govulncheck flag: `-json` → `--json`** — silent Go security scan failure.
7. **[MEDIUM] Fix cron PATH issue in `schedule.sh`** — ensures tools are found in cron environment.
8. **[MEDIUM] Remove haiku from interactive model picker** — or add a quality warning.
9. **[MEDIUM] Fix category comparison table formula** — align with `compute_health_score` weighted math.
10. **[LOW] Sort history entries by timestamp** in `cmd_status` and `cmd_history`.

---

## Open Questions

- The `analyze.sh` architecture (4 parallel Opus sessions) handles partial failures gracefully, but it's unclear what happens when the consensus agent also fails. The current code (`generate_detailed_report`) would produce an empty-findings report. Is this the intended behavior or should it be surfaced as an error?
- `kyzn-report.md` is written to the current working directory (project root). If `kyzn analyze` is run from a subdirectory of a project, the report ends up in the wrong place. Should `kyzn-report.md` always go to `$(project_root)/kyzn-report.md`?
- The `--fix` flow in `analyze` passes full report context to Sonnet but does NOT create a PR. Is this by design (user manually reviews then commits), or is PR creation intended for the fix flow too?

