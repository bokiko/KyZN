Now I have everything. Let me write the complete audit report to the required path. I'll use the bash Write tool functionality by creating the file content directly — but since I only have Read/Grep/Glob tools, I need to produce the output as my final response and ask for a write. Actually, looking at the agent instructions more carefully, I need to "Write findings to" the specified path. Let me check if there's a way to do this with the available tools.

I only have Read, Grep, and Glob tools. I'll produce the full report content and present it, noting that it should be written to the specified path. Actually — I'm the warden agent. Let me write the report as my final answer but also note the path. Given I can only use the file reading tools, I'll produce the complete report text and indicate the target path.

Let me now produce the complete audit report:

---

# Plan Review: KyZN Full Completeness & Consistency Audit
Generated: 2026-03-20

## Plan Summary
- **Goal:** Full completeness and consistency audit of the KyZN autonomous code improvement CLI (v0.4.0)
- **Scope:** All source files — 13 lib/ scripts, 5 measurers, 5 profiles, 3 templates, 1 test suite, README, installer, example config
- **Steps:** Audit across 10 dimensions: feature parity, help accuracy, config consistency, history schema, error messages, exit codes, version consistency, template completeness, test coverage, README accuracy

---

Here is the full warden report. Writing it to the required path:

Since I don't have a Write tool, let me produce this as structured output that can be captured. Given the agent instructions say to write to the path, and I only have Read/Grep/Glob, I'll present the complete report text as my response — the user or orchestrator can write it. But looking at the system again, this is a Claude Code session, so the Write tool is implicitly available through the response. Let me produce the final comprehensive report as my answer:

---

# Warden Audit Report — KyZN v0.4.0

Here is my complete audit with all findings. I'll present this as the report that should be written to `/home/bokiko/Projects/kyzn/full-audit-by-claude/warden-report.md`.

**FULL REPORT CONTENT:**

---

```markdown
# Warden Audit Report — KyZN v0.4.0
Generated: 2026-03-20
Status: DONE_WITH_CONCERNS

## Plan Summary

- **Project:** KyZN — Autonomous Code Improvement CLI
- **Version:** 0.4.0
- **Source files audited:** kyzn (main), lib/core.sh, lib/detect.sh, lib/interview.sh, lib/measure.sh, lib/prompt.sh, lib/execute.sh, lib/verify.sh, lib/allowlist.sh, lib/analyze.sh, lib/report.sh, lib/approve.sh, lib/history.sh, lib/schedule.sh, measurers/{generic,node,python,rust,go}.sh, templates/{system-prompt,improvement-prompt,analysis-prompt}.md, profiles/{security,testing,performance,quality,documentation}.md, tests/selftest.sh, .kyzn.example.yaml, install.sh, README.md
- **Audit dimensions:** Feature parity, help text accuracy, config consistency, history schema, error message quality, exit codes, version consistency, template completeness, test coverage gaps, README vs. reality

---

## Findings

### HIGH RISK

#### 1. `trust` key committed to config.yaml — security isolation broken

**File:** `/home/bokiko/Projects/kyzn/.kyzn/config.yaml:14`

**Gap:** The committed project config file contains `trust: guardian`. The entire trust-isolation design (documented in README and enforced by the interview/`save_interview_config`) separates `trust` into `.kyzn/local.yaml` (gitignored) specifically to prevent config poisoning. The actual `.kyzn/config.yaml` in the repo contains `trust: guardian` on line 14 — contradicting both the design and the test at `selftest.sh:1002` which asserts `config_get '.preferences.trust' 'MISSING'` must return `MISSING`.

**Impact:** Anyone cloning the repo gets a `config.yaml` with a `trust` key. If the codebase ever reads `config.yaml` for trust instead of `local.yaml` (e.g., after a refactor), auto-merge could silently activate. More immediately, the example config (`kyzn.example.yaml:13`) also contains `trust: guardian` in `preferences`, further perpetuating the pattern.

**Recommendation:** Remove `trust: guardian` from `.kyzn/config.yaml`. Remove `trust` from `.kyzn.example.yaml` (it belongs in a `# local.yaml only:` comment section, not the main example). The README should document that trust is never in `config.yaml`.

---

#### 2. `display_findings()` is defined but never called

**File:** `lib/analyze.sh:318`

**Gap:** The `display_findings()` function at line 318 (which produces the compact one-liner terminal output described in the README and features table: "Compact one-liner terminal output") is defined but has **zero callers** anywhere in the codebase. The `cmd_analyze()` function calls `generate_detailed_report()` and `run_fix_phase()` but never `display_findings()`. The README advertises "Compact one-liner terminal output + detailed `kyzn-report.md`" — the compact terminal output is missing from the execution path.

**Impact:** Users running `kyzn analyze` see no per-finding summary on the terminal. Only the report file count is shown (`log_info "Final findings: $finding_count issues"`). The advertised feature is not delivered.

**Recommendation:** Call `display_findings "$findings_file" "$root_report"` after line 858 (after the `log_ok "Full report: ..."` line) in `cmd_analyze()`.

---

#### 3. `--turns` flag undocumented in help and README

**File:** `lib/execute.sh:228`, `kyzn:41-81`

**Gap:** `cmd_improve()` accepts `--turns <N>` to override `max_turns`, but this flag appears in neither the `usage()` function nor the README's improve usage examples. Users have no way to discover it.

**Impact:** LOW discoverability risk, but combined with the fact that `enforce_config_ceilings` caps turns at 100, a user trying `--turns 200` would be silently capped with a warning — which is fine — but they'd have no way to know the flag exists at all.

**Recommendation:** Add `--turns` to the help text in `usage()` and the README improve section.

---

#### 4. `kyzn analyze --fix` does not create a PR or call `generate_report()`

**File:** `lib/analyze.sh:1062-1154`

**Gap:** When `kyzn analyze --fix` runs, `run_fix_phase()` applies changes and commits them, but then only prints "Review the fixes, then: kyzn approve / kyzn reject". It does NOT call `generate_report()` to create a PR. The `kyzn improve` flow always creates a PR (via `generate_report()` in `report.sh`). The analyze+fix flow leaves changes in a local branch with no PR, requiring the user to manually create one or approve/reject from CLI.

The README says under "Analyze" features: "Auto-creates PR with before/after comparison" — but that's only true for `kyzn improve`. For `kyzn analyze --fix`, no PR is created.

**Impact:** Workflow inconsistency. Users expecting a PR after `kyzn analyze --fix` will be confused.

**Recommendation:** Either call `gh pr create` at the end of `run_fix_phase()`, or clarify in the README that analyze-fix doesn't auto-PR. Also: `run_fix_phase()` does not run the score regression gate before committing — a regression is possible.

---

### MEDIUM RISK

#### 5. `config_set` and `config_set_str` are identical functions

**File:** `lib/core.sh:97-116`

**Gap:** Both `config_set` (line 97) and `config_set_str` (line 108) have identical implementations. The comment on `config_set_str` says "properly quoted" but the implementation is character-for-character identical to `config_set`. The distinction is illusory and misleading.

**Impact:** No runtime breakage, but confusion for maintainers and future contributors.

**Recommendation:** Remove `config_set_str` and use `config_set` everywhere. Or differentiate them (e.g., `config_set` for numbers, `config_set_str` for quoted strings).

---

#### 6. Test count claims are incorrect in README

**File:** `README.md:18,378,386-387`

**Gap:** Three test count claims that don't match:
- Badge: "156 passing"
- Project structure comment: "156 tests (43 core + 4 stress)"
- Self-test section: "Quick tests (147 cases)" / "Full suite with stress tests (156 cases)"

**Actual count:** The test suite has 46 non-stress test functions + 4 stress test functions = 50 test functions. Counting individual `pass()`/`fail()` assertions: the actual assertion count for quick mode is approximately 147 individual assertions (the 147 figure may be accurate for assertions, not functions), and ~156 with stress. The "43 core" claim is also wrong — there are 46 non-stress functions. This is likely referring to the v0.3 count before tests were added.

**Impact:** Misleading to users evaluating test coverage quality.

**Recommendation:** Either count actual assertions with `grep -c 'pass\|fail\|assert_' tests/selftest.sh` before publishing or remove the badge/inline claim and just use `kyzn selftest` output.

---

#### 7. `.kyzn.example.yaml` documents `trust` in the wrong location

**File:** `.kyzn.example.yaml:13`

**Gap:** The example config has `trust: guardian` under `preferences`. Per the design, trust belongs only in `.kyzn/local.yaml` (gitignored). The example config will be copied by users running `kyzn init` and teaches the wrong pattern. (See also Finding #1.)

**Impact:** Users may manually add `trust` to their committed `config.yaml` thinking it's valid.

**Recommendation:** Remove `trust` from `.kyzn.example.yaml`. Add a comment block explaining local.yaml and what goes in it.

---

#### 8. `kyzn analyze` does not accept `--auto` in the README examples

**File:** `README.md:165-173`, `lib/analyze.sh:479,491`

**Gap:** `cmd_analyze()` accepts `--auto` (line 491) to skip confirmation prompts (for cron use), but the README automate section only shows `kyzn schedule daily` which runs `kyzn improve --auto`. There is no mention of `kyzn analyze --auto` for scheduling periodic analysis. The `--auto` flag for `analyze` is also undocumented in the README's analyze examples section.

**Recommendation:** Add `kyzn analyze --auto` to the README automate section and the usage examples.

---

#### 9. `cmd_diff` fallback to report is misleading

**File:** `lib/history.sh:246-270`

**Gap:** `kyzn diff <run-id>` first looks for a git branch named `kyzn/*<run-id>*`. If not found, it falls back to displaying the markdown report file. A markdown report and a git diff are completely different things — showing a report when a diff is requested will confuse users, and the error message "No diff or report found" doesn't tell the user why the branch wasn't found (e.g., already merged, manually deleted, wrong run-id).

**Impact:** Silent misleading behavior — user gets a markdown report when they expected a diff.

**Recommendation:** Distinguish clearly: if branch not found, say "Branch for run $run_id not found (may have been merged). Showing saved report instead:" — or fail with a message about how to get the diff from git log.

---

#### 10. `kyzn history --global` flag is not documented

**File:** `lib/history.sh:10`, README, `kyzn` usage

**Gap:** `cmd_history()` accepts `--global` to show all projects' history, but this flag is not shown in `usage()` in the main `kyzn` script, and not mentioned in the README.

**Recommendation:** Add `history --global` to usage/README.

---

#### 11. History schema inconsistency: `run_id` vs `id` field

**File:** `lib/core.sh:239`, `lib/history.sh:44`, `lib/approve.sh:45,91`

**Gap:** `write_history()` in `core.sh` passes `run_id` as a named argument — the resulting JSON has field `run_id`. But `cmd_approve()` in `approve.sh:48` creates a new history entry with field `run_id: $id`. In `cmd_dashboard()` in `history.sh`, the jq filter uses `.id` (line 1285 in the test) not `.run_id`. The test fixture JSON at `selftest.sh:1285` uses field `id` not `run_id`. The `cmd_history()` display function reads `.run_id` (line 44).

**Impact:** Dashboard test fixtures use `id` while the actual production code path writes `run_id`. If a real run's history entry is read by the dashboard, the project field lookup works (since `group_by(.project)` is used), but any display of `run_id` in dashboard would fail silently.

**Recommendation:** Standardize: choose `run_id` everywhere. Update the test fixture at line 1285 and the dashboard's jq to use `run_id`.

---

#### 12. Score regression gate uses integer truncation, not rounding

**File:** `lib/execute.sh:492-494`

**Gap:** The per-category score floor check uses:
```bash
local b_int="${before_cat%.*}" a_int="${after_cat%.*}"
```
This truncates floats (e.g., 89.9 becomes 89, 90.1 becomes 90). A category that goes from 90.1% to 84.9% would show as a drop of 6 (triggering the gate) but a category going from 89.9% to 84.1% shows as a drop of 5 (not triggering). The inconsistency is at the boundary.

The same truncation happens in `display_health_dashboard()` and `generate_category_comparison()`.

**Recommendation:** Use `printf '%.0f'` (already used in `compute_health_score`) for consistent rounding throughout.

---

#### 13. `kyzn analyze --focus` with an invalid specialist silently defaults to `correctness`

**File:** `lib/analyze.sh:618-626`

**Gap:** `cmd_analyze --focus <value>` passes the focus string directly to `build_specialist_prompt()`. The `case` statement in that function only handles `security`, `correctness`, `performance`, `architecture`. Any other value falls through the case and produces no output (the heredoc is never emitted). The call at line 625 then uses `${focus:-correctness}` as the specialist, so `--focus foobar` silently runs `correctness`. No error is shown.

**Impact:** `kyzn analyze --focus typo` gives correctness analysis with no warning.

**Recommendation:** Validate `--focus` against the accepted values and `log_error` + return 1 for invalid values.

---

#### 14. `generate_pr_body` hardcodes "Build: Passed / Tests: Passed"

**File:** `lib/report.sh:176-177`

**Gap:** The PR body template always prints:
```
- Build: ✅ Passed
- Tests: ✅ Passed
```
This is hardcoded regardless of actual build state. While `generate_report()` is only called after passing `verify_build()`, the `on_build_fail: draft-pr` strategy in `handle_build_failure()` also calls `gh pr create` with a body that says "WARNING: Build failed" — but that's a separate code path. The misleading case is if `verify_python()` returns OK when only ruff/mypy failed (non-blocking) but pytest passed — the PR body would still say "Tests: ✅ Passed" even if there were linting issues.

**Recommendation:** Pass the verification result to `generate_pr_body` and reflect actual state, or qualify the line: "Build and tests: ✅ Passed (pre-existing failures excluded)".

---

### LOW RISK

#### 15. `kyzn doctor` exit code: `ok=false` set but `exit 1` only if missing required tools, not if auth fails

**File:** `kyzn:329-337`

**Gap:** Claude auth failure and gh auth failure both emit `log_warn` but don't set `ok=false`. So the final check `if $ok; then log_ok "All required tools found."` returns 0 even when authentication is absent. A user with no Claude auth would see "KyZN is ready" which is wrong.

**Recommendation:** Set `ok=false` for missing Claude auth (it's a hard requirement) or at minimum set a warning flag and change the exit message.

---

#### 16. `log_fail` vs `log_error` inconsistency

**File:** `lib/core.sh:26-27`

**Gap:** Two functions exist for error-like logging:
- `log_error()` — writes to stderr, colored red
- `log_fail()` — writes to stdout, colored red

`log_fail` is used in `cmd_doctor` for missing tools. `log_error` is used elsewhere. The distinction is subtle and inconsistent: some places use `log_fail` in non-doctor contexts. This is a minor inconsistency but could affect scripted consumption of stderr.

---

#### 17. `kyzn measure` history entry uses a hard-coded run_id format

**File:** `lib/measure.sh:242`

**Gap:**
```bash
write_history "measure-$(date +%Y%m%d-%H%M%S)" "measure" "completed" _hist
```
The measure run_id doesn't use `generate_run_id()` (which adds a random suffix for uniqueness). If `kyzn measure` is run twice within the same second, the second run overwrites the first history entry. All other commands use `generate_run_id()`.

**Recommendation:** Use `generate_run_id()` for measure history entries too.

---

#### 18. `kyzn schedule` has no error if not in git repo (partial)

**File:** `lib/schedule.sh:34-56`

**Gap:** `schedule_cron()` calls `require_git_repo` (line 38), which is correct. But `remove_cron()` at line 61 calls `project_root` which calls `git rev-parse --show-toplevel 2>/dev/null || pwd`. If not in a git repo, it falls back to `pwd`. This means `kyzn schedule off` could delete cron entries for the wrong project if run from a non-git directory.

**Recommendation:** Call `require_git_repo` in `remove_cron()` as well.

---

#### 19. `govulncheck` output parsing is fragile

**File:** `measurers/go.sh:38`

**Gap:** The govulncheck JSON output parsing uses:
```bash
vuln_count=$(echo "$vuln_output" | jq '[.vulns[]? | select(.modules)] | length')
```
The govulncheck JSON format changed significantly between versions. The current output format (v1.x) uses a different structure. If govulncheck returns an error or different schema version, `jq` may silently return 0 rather than failing gracefully.

---

#### 20. `truncate_str` boundary behavior: exactly max length is not truncated

**File:** `lib/core.sh:259-266`

**Gap:** The test at `selftest.sh:165` is:
```bash
short=$(truncate_str "hello world" 5)
assert_eq "truncate short" "he..." "$short"
```
"hello world" has 11 chars, max 5: `${str:0:2}...` = "he..." — correct. But the function checks `${#str} > max`, so a string of exactly `max` characters is NOT truncated. This is correct behavior but the test doesn't cover the equal-length boundary case.

---

### QUESTIONS

#### Q1. Does `kyzn analyze --fix` go through the score regression gate?

`run_fix_phase()` in `analyze.sh` does not call `compute_health_score()` before or after applying fixes, nor does it call the per-category floor check from `execute.sh`. This means an analyze-fix run could commit code that reduces the health score without triggering the regression gate. Is this intentional?

#### Q2. The `--profile` flag for analyze is undocumented in README

`cmd_analyze()` accepts `--profile opus|hybrid|sonnet` (line 489) but README only shows: `kyzn analyze --focus security`. Is `--profile` intentionally hidden from users, or was it missed in documentation?

#### Q3. What happens if `kyzn approve` is run on an analyze run?

`cmd_approve` looks for `$run_id.md` or `$run_id-analysis.md`. For an analyze run, `$run_id-analysis.md` exists. Approving marks it as "approved" but does nothing to merge a branch — because analyze runs without `--fix` don't create branches. The approval is semantically empty. Is there intended behavior here?

---

## Unstated Assumptions

1. **`jq` and `yq` are POSIX-compliant versions** — The installer explicitly handles the snap yq incompatibility (snap cannot access hidden directories). But `jq` installed via snap would have the same problem. Only `yq` is explicitly handled.

2. **`git` default branch is `main` or `master`** — `safe_checkout_back()` tries `git checkout -`, then `main`, then `master`. If the repo uses `trunk` or `develop`, it silently fails with a warning. `kyzn diff` also hardcodes `git diff "main...$branch"`.

3. **The Claude CLI flag `--append-system-prompt-file` exists** — This flag is used throughout `execute.sh` and `analyze.sh`. If the Claude CLI changes this flag name (it's not in standard documentation), all invocations silently fail.

4. **`npm test` doesn't require user interaction** — `verify_node()` runs `npm test 2>&1 | tail -10` without timeout or `--ci` flag. A test suite that prompts for input will hang indefinitely.

5. **Parallel `run_specialist` subshells inherit all needed globals** — The specialists are launched with `&` in subshells. Variables like `KYZN_ROOT`, `KYZN_PROJECT_TYPE`, etc. are exported/available. But if any library function uses `$KYZN_CONFIG` or other path variables set after `source`ing, those paths assume cwd matches the project root.

6. **`cargo audit` is installed separately from `cargo`** — `cargo audit --version` is checked, but many Rust devs don't have `cargo-audit` installed. The check (`cargo audit --version &>/dev/null 2>&1`) returns 0 if `cargo` exists but `audit` subcommand is missing (cargo prints "no such subcommand: audit" to stderr but exits 0 on older versions).

7. **Network access is available during `kyzn measure`** — `npm audit`, `pip-audit`, `cargo audit`, `govulncheck` all make network calls. In air-gapped environments, these fail silently (the measurers use `|| true` throughout), producing artificially inflated security scores.

8. **The lock dir cleanup is guaranteed** — `_kyzn_cleanup` is registered with `trap`. But `trap EXIT` in bash doesn't trigger on SIGKILL. If the process is killed with SIGKILL, the lock dir at `.kyzn/.improve.lock` persists. The stale lock detection (checking if PID is alive) handles this on next run, but only if the PID slot hasn't been reused by another process.

---

## Missing Steps / Undocumented Features

- `kyzn history --global` — not in help or README
- `kyzn analyze --auto` — not in README automate section
- `kyzn analyze --profile` — not in README
- `kyzn analyze --fix-budget` — not in README
- `kyzn analyze --single` — listed in README but `--fix` and `--single` interaction is undocumented
- `kyzn improve --turns` — not in help or README
- `kyzn improve --allow-ci` — mentioned in README safety table but not in usage examples
- `display_findings()` function — defined, not called (the advertised compact terminal output is missing)
- Score regression gate is skipped in analyze-fix path

---

## README vs. Reality Discrepancies

| Claim | Reality |
|-------|---------|
| "Compact one-liner terminal output" during analyze | `display_findings()` is never called |
| "4 Opus specialists in parallel (~$20)" | Budget is hidden from user; actual is `20/5 = $4 per agent` with 5 agents (4 specialists + consensus) |
| "156 tests (43 core + 4 stress)" | 50 test functions; "43" is outdated (was pre-v0.4 count) |
| `kyzn selftest` = "Quick tests (147 cases)" | Correct if counting assertions, but confusing vs. "156 tests" badge |
| PR body shows "Build: ✅ Passed" | Hardcoded string, doesn't reflect actual partial failure state |
| "Trust isolation" via gitignored local.yaml | Violated by committed `.kyzn/config.yaml:14` containing `trust: guardian` |
| `--focus security` runs "single specialist" | Correct |
| `analyze --fix` creates a PR | No PR is created; changes are committed locally on a branch |

---

## Test Coverage Gaps

Functions with **no direct test coverage:**

| Function | Location | Risk |
|----------|----------|------|
| `display_findings()` | `analyze.sh:318` | Dead code — never called |
| `run_fix_phase()` | `analyze.sh:1062` | Needs live Claude, not unit-testable, but no integration test |
| `cmd_analyze()` end-to-end | `analyze.sh:467` | Only `build_specialist_prompt`, `build_consensus_prompt`, `extract_findings`, `generate_fix_prompt` are unit-tested |
| `generate_detailed_report()` | `analyze.sh:928` | Not tested |
| `run_specialist()` | `analyze.sh:227` | Not tested (requires live Claude) |
| `verify_python()`, `verify_rust()`, `verify_go()` | `verify.sh` | Only `verify_node` dispatch and `verify_build` generic are tested |
| `capture_failing_tests()` | `verify.sh:8` | Not tested at all |
| `cmd_status()` | `history.sh:275` | Not tested |
| `schedule_cron()` / `remove_cron()` | `schedule.sh` | Not tested (mutates user crontab) |
| `install_jq()` / `install_yq()` | `install.sh` | Not tested |
| `check_missing_tooling()` | `interview.sh:304` | Not tested |
| `cmd_dashboard()` with `find_count == 0` | `history.sh:107` | Coverage via test 46/47, but the `$_valid_files` empty path not covered |
| `generate_pr_body()` | `report.sh:148` | Not unit-tested directly |
| `generate_report()` | `report.sh:7` | Not tested (requires git state) |

**Edge cases untested:**

- `kyzn improve` with pre-existing failures where Claude introduces NEW failures
- `kyzn improve --auto` without config (should error)
- `kyzn approve` when global history dir is read-only
- `kyzn diff` for a run whose branch has been merged (the git diff fallback path)
- `handle_build_failure "draft-pr"` strategy (tested: `report` and `discard`, not `draft-pr`)
- Score regression gate with floating-point scores near the threshold
- `build_allowlist "unknown_type"` — no case in `allowlist.sh` for unknown types (falls through without adding language tools but doesn't error)
- Multi-Cargo.toml workspace detection edge cases beyond one level deep
- `kyzn measure` history entry collision (same second)

---

## Exit Code Consistency

KyZN generally uses exit codes correctly:
- Exit 1 for errors (unknown command, missing args, failed operations)
- Exit 0 for success

**Inconsistency found:** `cmd_doctor` with missing Claude auth logs a warning but still exits 0 (returns without setting `ok=false`). The tool reports "KyZN is ready" when it is not.

**Consistent patterns:**
- All `return 1` paths in lib functions correctly propagate
- `trap _kyzn_cleanup EXIT INT TERM` ensures lock release even on errors
- `handle_build_failure` does not exit — it returns (callers `return 1` after)

---

## Version Consistency

`KYZN_VERSION="0.4.0"` is defined once in `kyzn:16` and used via `$KYZN_VERSION`.

**Consistent:** README badge, version command output, and dashboard header all use this.

**Issue:** The badge in README says `version-0.4.0` as a hardcoded string in the img tag URL, not read from the source. If the version is bumped in `kyzn` but not in README, they diverge.

---

## Template Completeness

All templates fully define their variables:

| Template | Variables | All substituted? |
|----------|-----------|-----------------|
| `improvement-prompt.md` | `{{PROJECT_NAME}}`, `{{PROJECT_TYPE}}`, `{{MODE}}`, `{{FOCUS}}`, `{{HEALTH_SCORE}}`, `{{MEASUREMENTS}}`, `{{MODE_CONSTRAINTS}}` | Yes — all substituted in `assemble_prompt()` |
| `system-prompt.md` | None (static) | N/A |
| `analysis-prompt.md` | None (static) | N/A |

**No orphaned variables found.** Template substitution is correct.

---

## Configuration Consistency

| Config Key | default in code | default in .kyzn.example.yaml | documented in README |
|-----------|-----------------|-------------------------------|---------------------|
| `preferences.mode` | `'deep'` | `deep` | Yes |
| `preferences.model` | `'sonnet'` | — (missing from example) | Yes |
| `preferences.budget` | `'2.50'` | `2.50` | Yes |
| `preferences.max_turns` | `'30'` | `30` | Yes |
| `preferences.diff_limit` | `'2000'` | `2000` | Yes |
| `preferences.on_build_fail` | `'report'` | `report` | Yes |
| `focus.priorities[0]` | `'auto'` | `[security, testing, performance]` | Yes |
| `scoring.weights.security` | `25` | commented out | Yes |
| `preferences.trust` | N/A (local.yaml) | `guardian` (WRONG LOCATION) | Yes (but mislocated in example) |

**Key issue:** `model` key is not in `.kyzn.example.yaml` but IS in README config example and IS written by `save_interview_config`. This creates a gap where the example doesn't show the model key.

---

## Verdict: INCOMPLETE

The project is well-engineered with strong security design, good test coverage for its core paths, and a thoughtful multi-agent architecture. However, several issues must be addressed before claiming feature completeness:

**Must fix (blocking correctness claims):**
1. `display_findings()` is dead code — the advertised compact terminal output during analyze is not delivered (HIGH RISK #2)
2. `trust` key in committed `.kyzn/config.yaml` violates the security isolation design (HIGH RISK #1)
3. `.kyzn.example.yaml` teaches the wrong config structure for trust (HIGH RISK, supporting #1)

**Should fix (misleading documentation):**
4. `kyzn analyze --fix` doesn't create a PR — README implies it does (HIGH RISK #4)
5. Test count badge (156) vs reality (50 functions, ~147 assertions) is misleading
6. `--turns`, `--profile`, `--fix-budget`, `--allow-ci` flags undocumented
7. `cmd_doctor` reports "KyZN is ready" when Claude auth is absent

**Status:** DONE_WITH_CONCERNS
```

Now let me write this to the required output file. I'll compose it directly: