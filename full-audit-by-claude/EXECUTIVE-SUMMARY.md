# KyZN Full Audit — Executive Summary

**Date:** 2026-03-20
**Auditor:** Claude Opus 4.6 (16 parallel specialist agents)
**Version audited:** KyZN v0.4.0 (commit 7ed24ea)
**Total reports:** 16 | **Total lines analyzed:** 8,439 lines of findings | **Codebase:** ~3,500 lines across 23 files

---

## Overall Assessment: B+

KyZN is a well-engineered tool with genuinely strong security design (safe_git, allowlists, config ceilings, trust isolation, secret unstaging). The architecture is clean — lazy module loading, branch isolation, score regression gates, and a comprehensive 187-test suite. However, the audit revealed several issues where the implementation doesn't fully deliver on its own design promises.

---

## Critical Findings (Consensus — flagged by 3+ agents)

### 1. `eval` injection in `enforce_config_ceilings` — 6 agents flagged
**Files:** `lib/execute.sh:59-73`
**Agents:** Aegis, Oracle, Sentinel, Sleuth, Scout, Spark

```bash
eval "_cur_budget=\$$_var_budget"  # reads via eval
eval "$_var_budget=$max_budget"    # writes via eval
```

**The issue:** Uses `eval` for indirect variable access when bash 4.3+ namerefs (`declare -n`) are already required and used elsewhere in the codebase. While not directly exploitable today (callers pass hardcoded variable names), a config-poisoned `budget` value could reach the `awk` command that runs between the eval reads. The pattern is unnecessary — `${!var}` (read) and `printf -v` (write) are safe alternatives.

**My opinion:** This is the highest-priority fix. Not because it's actively exploitable right now, but because it's a 5-line change that eliminates an entire class of risk, and the safe alternative is already used elsewhere in the codebase. No reason for `eval` to exist here.

**Fix:** Replace with `${!_var_budget}` (read) and `printf -v "$_var_budget" '%s' "$max_budget"` (write).

---

### 2. Unquoted `$allowlist` silently breaks tool restrictions — 3 agents flagged
**Files:** `lib/execute.sh:114,123,143`
**Agents:** Sentinel, Oracle, Sleuth

```bash
# shellcheck disable=SC2086
result=$(timeout "$claude_timeout" claude -p "$prompt" \
    $allowlist \    # <-- intentionally unquoted for word splitting
```

**The issue:** The allowlist is built as a flat string (`--allowedTools Read --allowedTools Glob ...`). Unquoted expansion relies on word splitting. But `build_allowlist` emits quoted tokens like `'"Bash(npm test*)"'` — these literal quote characters survive into the arguments, breaking Claude's `--allowedTools` parsing. This means **all language-specific tool restrictions are silently broken** for node, python, rust, and go projects. Claude gets broader tool access than intended.

**My opinion:** This is the most impactful security finding. The code explicitly acknowledges the issue (`# shellcheck disable=SC2086`) but the workaround doesn't work as designed. Converting to a bash array is the right fix and would also eliminate the shellcheck suppression.

**Fix:** Use `local -a allowlist_arr=(...)` and expand with `"${allowlist_arr[@]}"`.

---

### 3. `config_set` and `config_set_str` are identical — 3 agents flagged
**Files:** `lib/core.sh:97-116`
**Agents:** Scout, Spark, Warden

**The issue:** Byte-for-byte identical functions. `config_set_str` was presumably intended to handle string quoting differently, but the implementation is a copy-paste duplicate.

**My opinion:** Trivial fix. Delete one, alias the other. Low risk but high noise-to-signal — every new contributor will wonder about this.

---

### 4. Missing cleanup trap in `cmd_analyze` — 3 agents flagged
**Files:** `lib/analyze.sh`
**Agents:** Phoenix, Maestro, Sleuth

**The issue:** `cmd_improve` has a robust `_kyzn_cleanup` trap for EXIT/INT/TERM. `cmd_analyze` has none. If interrupted during multi-agent analysis, temp files and the measurement directory leak. More importantly, the "running" history entry is never updated to "failed".

**My opinion:** Direct copy of the pattern from `cmd_improve`. Medium effort, high value for crash recovery.

---

## High-Severity Findings

### 5. `display_findings()` is dead code — advertised feature doesn't work
**Agent:** Warden
**File:** `lib/analyze.sh:318`

Defined but never called. The README advertises "compact one-liner terminal output" during analyze — this code exists but doesn't execute. Users only see `"Final findings: N issues"`.

**My opinion:** Either wire it in or delete it. Dead code that's advertised as a feature is worse than no feature.

### 6. `trust: guardian` committed in `.kyzn/config.yaml`
**Agents:** Scout, Warden
**File:** `.kyzn/config.yaml:14`

The entire security design around config poisoning prevention is based on trust living ONLY in the gitignored `local.yaml`. KyZN's own committed config violates this principle.

**My opinion:** Remove the `trust` key from the committed config. It should only be in `local.yaml`.

### 7. `npx *` allowlist is effectively unrestricted
**Agents:** Aegis, Oracle
**File:** `lib/allowlist.sh:28`

For Node.js projects, `npx *` allows Claude to execute any npm package. A malicious repo with a crafted `package.json` could trigger arbitrary code execution via Claude's tool use.

**My opinion:** Replace `npx *` with specific patterns like `npx eslint`, `npx tsc`, `npx vitest`. The current pattern defeats the purpose of having an allowlist.

### 8. `kyzn update` has no signature verification
**Agent:** Aegis
**File:** `kyzn:214-221`

`git pull` + immediate execution. No tag signing, no checksum, no GPG verification. A compromised GitHub account or MITM could push malicious code.

**My opinion:** For a tool that executes Claude with spending authority, this is a real risk. At minimum, verify the commit is signed or pin to tagged releases.

### 9. History entries shown in filesystem order, not chronological
**Agents:** Sentinel, Maestro
**File:** `lib/history.sh:40`

`measure-*` entries sort after date-based entries lexicographically, so measure runs always appear after improve runs regardless of actual time.

**My opinion:** Simple fix — sort by timestamp from the JSON, not by filename glob order.

### 10. `schedule.sh` crashes with no existing crontab
**Agent:** Spark
**File:** `lib/schedule.sh:67`

`crontab -l` fails if user has no crontab. Under `set -euo pipefail`, this kills the pipeline.

**My opinion:** One-line fix: `(crontab -l 2>/dev/null || true)`.

---

## Performance Findings

### 11. Per-entry jq loops are the scalability bottleneck
**Agent:** Profiler

Both `cmd_history()` and `cmd_dashboard()` spawn 5-8 jq processes per history file. With 100 files = 500-800 subprocess spawns. A single `jq -s` with `@tsv` output gives 5-7x speedup.

`generate_detailed_report()` in analyze.sh runs 8 jq calls per finding. With 20 findings = 160 processes.

**My opinion:** The dashboard fix I implemented already uses `jq -s`, but `cmd_history()` and `generate_detailed_report()` still use per-entry loops. Worth fixing for projects with many runs.

### 12. `project_name()` called ~15 times per improve run, never cached
**Agent:** Profiler
**File:** `lib/core.sh:137-139`

Each call spawns `git rev-parse --show-toplevel`. Trivial to cache.

---

## Testing Findings

### 13. Test quality score: 5.1/10
**Agent:** Kraken

The 187 tests that exist are well-crafted. But the entire Claude orchestration pipeline (`execute_claude`, `cmd_improve`, `cmd_analyze`, `generate_report`, `unstage_secrets`) has **zero test coverage**. These are the most dangerous functions in the codebase and they're completely untested.

**My opinion:** Bash function mocking (override with `function claude() { ... }`) would allow testing the full pipeline without API calls. This is the single highest-leverage testing improvement.

### 14. Test artifacts leak into global history
**Agents:** Arbiter, Atlas

`test_approve_reject` writes to `~/.kyzn/history/` but never cleans up. 72+ stale files accumulating.

**My opinion:** Add cleanup to the test teardown. The `tmp.*` prefix filter in dashboard helps, but the files shouldn't exist.

---

## Strategic Findings

### 15. Biggest competitive gap: no retry/reflection loop
**Agent:** Pathfinder

When Claude's changes fail verification, KyZN aborts. Research shows Reflexion-style retries improve success rate by 6-10%. Every competitor (Aider, Devin, Cursor) has retry loops.

### 16. Missing table-stakes metrics
**Agent:** Pathfinder

No cyclomatic complexity, no duplication detection, no dependency vulnerability scanning (beyond govulncheck which is broken). SonarQube/CodeClimate users expect these.

### 17. Biggest existential threat
**Agent:** Pathfinder

Claude Code itself adding native `--improve` and `--measure` capabilities. KyZN's moat is the workflow layer (scheduling, history, approval, multi-agent analysis) — features Anthropic is unlikely to build into the CLI.

---

## Agent Report Card

My assessment of each agent's contribution:

| Agent | Grade | Highlights |
|-------|-------|------------|
| **Sentinel** | A+ | Most thorough. 28 issues with file:line refs and fix suggestions. Found the allowlist break. |
| **Aegis** | A | Strong security focus. eval + config poisoning + npx wildcard all caught. |
| **Sleuth** | A | 30 findings, excellent edge case analysis. Process substitution portability issue is real. |
| **Pathfinder** | A | Strategic insights that no other agent provided. Competitive moat analysis is valuable. |
| **Profiler** | A- | Actionable performance findings with estimated impact. jq batching recommendation is correct. |
| **Warden** | A- | Found dead code and feature gaps others missed. Display_findings() catch was unique. |
| **Scout** | B+ | Solid structural audit. trust-in-config finding is important. |
| **Oracle** | B+ | Good external research but 47 findings had some noise. Prompt injection analysis was thorough. |
| **Phoenix** | B+ | Refactoring recommendations are sound. God file analysis is correct. |
| **Scribe** | B+ | B+ overall rating is fair. Badge count and error message findings are actionable. |
| **Kraken** | B | Test coverage analysis is valuable. Mock-based testing recommendation is the right path. |
| **Maestro** | B | Good workflow analysis. Branch handling edge cases are real. |
| **Spark** | B | Quick fixes are all valid. schedule.sh crash is the most impactful find. |
| **Architect** | B | Architecture review is sound but overlaps heavily with Phoenix. |
| **Arbiter** | B- | Ran all tests successfully. ShellCheck findings were minor. Test leak finding is useful. |
| **Atlas** | B- | E2E scenarios passed. `kyzn diff` crash finding is real. Limited unique value. |

---

## Recommended Fix Priority

### Immediate (do now)
1. Replace `eval` with `${!var}` + `printf -v` in `enforce_config_ceilings`
2. Convert `$allowlist` to a bash array
3. Remove `trust: guardian` from committed `.kyzn/config.yaml`
4. Fix `schedule.sh` crontab crash
5. Add `|| true` to `cmd_diff` grep pipeline

### Soon (next sprint)
6. Add cleanup trap to `cmd_analyze`
7. Delete `config_set_str` (or `config_set`)
8. Wire in or delete `display_findings()`
9. Fix history sort order (by timestamp, not glob)
10. Replace `npx *` with specific patterns in allowlist
11. Clean up test artifact leaks
12. Fix `kyzn diff` pipeline crash
13. Add path traversal validation to `cmd_reject`

### Later (tech debt)
14. Split `analyze.sh` into 3 files
15. Break `cmd_improve` into sub-functions
16. Batch jq calls in history/dashboard/report
17. Cache `project_name()`
18. Add mock-based tests for Claude pipeline
19. Add complexity/duplication metrics to measurers
20. Add retry/reflection loop for failed improvements

---

## Numbers

- **16 agents** ran in parallel
- **~8,400 lines** of findings produced
- **~350KB** of reports
- **~6 minutes** wall clock for all agents
- **Consensus findings** (3+ agents): eval injection, allowlist break, dead duplicate function, missing analyze trap
- **Unique finds** (single agent): dead `display_findings()` (Warden), allowlist quoting break (Sentinel), `kyzn diff` crash (Atlas), schedule.sh crash (Spark)

---

*Generated by Claude Opus 4.6 — 16-agent parallel audit of KyZN v0.4.0*
