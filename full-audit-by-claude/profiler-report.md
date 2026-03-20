# Performance Analysis: KyZN CLI

Generated: 2026-03-20
Auditor: profiler (Claude Opus 4.6)

## Executive Summary

- **Bottleneck Type:** Subprocess spawning (jq/yq/git/grep), repeated computation, unbatched JSON processing
- **Total Source Lines:** 4,738 across 18 shell scripts
- **Total jq invocations across codebase:** 148
- **Total subshell spawns ($(...)) across codebase:** 360
- **Primary concern:** Per-entry jq loops in `history.sh`, `analyze.sh`, and measurers
- **Expected improvement from batch fixes:** 3-10x faster for dashboard/history/report commands

---

## 1. Startup Time

### Source Loading

KyZN uses lazy loading -- the main `kyzn` script only sources `lib/core.sh` at startup, then conditionally sources command-specific modules. This is well-designed.

| Command    | Files Sourced                          | Count |
|------------|----------------------------------------|-------|
| `version`  | core.sh                                | 1     |
| `doctor`   | core.sh                                | 1     |
| `measure`  | core.sh, detect.sh, measure.sh         | 3     |
| `status`   | core.sh, detect.sh, measure.sh, history.sh | 4  |
| `improve`  | core.sh + 7 modules                   | 8     |
| `analyze`  | core.sh + 8 modules                   | 9     |
| `history`  | core.sh, history.sh                    | 2     |

**Verdict:** Good. Lazy sourcing keeps startup fast for simple commands.

### Update Check

`check_for_updates()` runs on every non-trivial command. It:
1. Reads `~/.kyzn/last-update-check` (1 file read)
2. Conditionally runs `git fetch origin` (network call, 5s timeout)
3. Runs `git rev-parse HEAD` (1 subprocess)
4. Runs `git rev-parse origin/main` (1 subprocess)
5. Conditionally runs `git rev-list --count HEAD..origin/main` (1 subprocess)

**Impact:** Up to 4 subprocesses + 1 file read + 1 potential 5s network call on every command.

**Recommendation:** The 86400-second (daily) check is reasonable. The `timeout 5` guard is correct. Minor: the 3 git rev-parse/rev-list calls could be combined into one `git log --oneline HEAD..origin/main | wc -l` which gives both "is behind" and "count" in one call.

---

## 2. Subprocess Spawning — Per-Command Analysis

### `project_name()` and `project_root()` — Redundant Computation

`project_name()` calls `project_root()` which calls `git rev-parse --show-toplevel`. These are called repeatedly without caching:

| Location | Calls to project_name/project_root |
|----------|-------------------------------------|
| `core.sh:write_history()` | 1 call per history write |
| `prompt.sh:assemble_prompt()` | 2 calls (PROJECT_NAME and PROJECT_TYPE substitution) |
| `report.sh:generate_report()` | 0 (uses variable) |
| `history.sh:cmd_history()` | 1 call |
| `history.sh:cmd_status()` | 2 calls (log_header + run_measurements) |
| `detect.sh:detect_project_type()` | 1 call to project_root() |
| `detect.sh:detect_project_features()` | 1 call to project_root() |
| `interview.sh:save_interview_config()` | 1 call |
| `approve.sh:cmd_approve()` | 2 calls (jq args) |
| `approve.sh:cmd_reject()` | 2 calls (jq args) |
| `schedule.sh` | 3 calls |

**Total:** ~15 `git rev-parse --show-toplevel` subprocesses per `improve` run that all return the same value.

**Recommendation (HIGH IMPACT):** Cache the result at the start of each command:

```bash
# In core.sh, after require_git_repo:
KYZN_PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KYZN_PROJECT_NAME="$(basename "$KYZN_PROJECT_ROOT")"

# Replace project_root() body with: echo "$KYZN_PROJECT_ROOT"
# Replace project_name() body with: echo "$KYZN_PROJECT_NAME"
```

**Expected improvement:** Eliminates ~14 unnecessary `git` subprocess spawns per command.

---

### `config_get()` and `local_config_get()` — yq per call

Each call to `config_get()` spawns a `yq` process. In `cmd_improve()`:

```
mode     → config_get (1 yq)
model    → config_get (1 yq)
budget   → config_get (1 yq)
max_turns → config_get (1 yq)
diff_limit → config_get (1 yq)
on_fail  → config_get (1 yq)
focus    → config_get (1 yq)
```

Plus `compute_health_score()` calls `config_get` once per category with a weight override (5 calls per invocation). Since `compute_health_score()` is called 2-4 times in improve, that's 10-20 extra yq calls.

**Total per improve run:** ~27 yq invocations for config reading.

**Recommendation (MEDIUM IMPACT):** Load all config values in one yq call at command start:

```bash
load_config() {
    if has_config; then
        eval "$(yq eval '
            "KYZN_CFG_MODE=" + (.preferences.mode // "deep"),
            "KYZN_CFG_MODEL=" + (.preferences.model // "sonnet"),
            "KYZN_CFG_BUDGET=" + (.preferences.budget // "2.50"),
            ...
        ' "$KYZN_CONFIG" 2>/dev/null)"
    fi
}
```

Or more safely, read the entire YAML into a bash variable and use yq with `--from-file /dev/stdin` for subsequent queries. This reduces ~27 yq spawns to 1.

---

## 3. JSON Processing — The jq Hot Path

### 3.1 Measurers: Accumulator Anti-Pattern

Every measurer builds results using the pattern:
```bash
results=$(echo "$results" | jq '... + [{...}]')
```

This spawns a new jq process for each measurement added. In `generic.sh`, this happens 5 times. In `node.sh`, up to 5 times. Each jq call parses the growing JSON, adds to it, and re-serializes.

**Per measurer jq count:**
| Measurer    | jq calls for result building | jq calls for parsing output | Total jq |
|-------------|-----------------------------|-----------------------------|----------|
| generic.sh  | 5                           | 0                           | 5        |
| node.sh     | 5                           | 13                          | 18       |
| python.sh   | 4                           | 7                           | 11       |
| rust.sh     | 3                           | 2                           | 5        |
| go.sh       | 3                           | 2                           | 5        |

For a Node.js project, `kyzn measure` spawns: 5 (generic) + 18 (node) + 3 (run_measurer validation) + 10 (compute_health_score) = **~36 jq processes**.

**Recommendation (HIGH IMPACT):** Refactor measurers to build JSON internally and emit once:

```bash
# Instead of repeated jq calls, build a bash array and emit at the end:
_measurements=()
_measurements+=('{"category":"quality","score":'"$score"',"max_score":100,...}')
# ... more measurements ...
printf '[%s]' "$(IFS=,; echo "${_measurements[*]}")"
```

This reduces each measurer to 0 jq calls for result building. Parsing external tool output (npm audit JSON) still needs jq, but those are unavoidable.

### 3.2 `run_measurer()`: Triple jq Validation

```bash
# Line 74-81 of measure.sh
if [[ -n "$output" ]] && echo "$output" | jq . &>/dev/null; then     # jq call 1: validate
    if echo "$output" | jq -e 'type == "array"' &>/dev/null; then     # jq call 2: type check
        merged=$(jq -s '.[0] + .[1]' "$results_file" <(echo "$output"))  # jq call 3: merge
    else
        merged=$(jq -s '.[0] + [.[1]]' "$results_file" <(echo "$output")) # jq call 3: merge
    fi
```

3 jq calls per measurer invocation. Since at least 2 measurers run (generic + language), that's 6 jq calls just for merging.

**Recommendation:** Combine validation + type check + merge into a single jq call:

```bash
merged=$(jq -s --argjson new "$output" '
    if ($new | type) == "array" then .[0] + $new
    else .[0] + [$new] end
' "$results_file" 2>/dev/null) && echo "$merged" > "$results_file"
```

### 3.3 `compute_health_score()`: 5 jq Calls in a Loop

```bash
for cat in security testing performance quality documentation; do
    pct=$(echo "$category_scores" | jq -r --arg c "$cat" '.[$c] // empty')  # 1 jq per category
    weight=$(_kyzn_weight "$cat")  # potentially 1 yq per category
```

5 jq + 5 potential yq = 10 subprocesses per invocation. Called 2-4 times during `improve`.

**Recommendation:** Extract all categories in one jq call:

```bash
eval "$(echo "$category_scores" | jq -r 'to_entries[] | "KYZN_CAT_\(.key | ascii_upcase)=\(.value)"')"
```

### 3.4 `cmd_history()`: Per-Entry jq Loop (Scalability Critical)

```bash
for f in "$history_dir"/*.json; do
    run_id=$(jq -r '.run_id // "unknown"' "$f")       # jq call 1
    status=$(jq -r '.status // "pending"' "$f")        # jq call 2
    before=$(jq -r '.health_before // "-"' "$f")       # jq call 3
    after=$(jq -r '.health_after // "-"' "$f")         # jq call 4
    focus=$(jq -r '.focus // "-"' "$f")                # jq call 5
done
```

**5 jq processes per history entry.** With 100 history files, that's 500 subprocess spawns.

**Recommendation (CRITICAL):** Single jq call per file, or batch all files:

```bash
# Option A: Single jq per file
while IFS=$'\t' read -r run_id status before after focus; do
    ...
done < <(jq -r '[.run_id // "unknown", .status // "pending", .health_before // "-", .health_after // "-", .focus // "-"] | @tsv' "$history_dir"/*.json 2>/dev/null)
```

This reduces 5N jq calls to 1 call total.

### 3.5 `cmd_dashboard()`: Per-Entry jq Loop (Worst Case)

Lines 188-236 of history.sh extract 7 fields per dashboard entry, each with a separate jq call:

```bash
while (( i < count )); do
    proj=$(echo "$dashboard_data" | jq -r ".[$i].project")           # jq 1
    type=$(echo "$dashboard_data" | jq -r ".[$i].type // \"-\"")     # jq 2
    status=$(echo "$dashboard_data" | jq -r ".[$i].status // \"-\"") # jq 3
    ts=$(echo "$dashboard_data" | jq -r "...")                       # jq 4
    hb=$(echo "$dashboard_data" | jq -r "...")                       # jq 5
    ha=$(echo "$dashboard_data" | jq -r "...")                       # jq 6
    fc=$(echo "$dashboard_data" | jq -r "...")                       # jq 7
    # ... plus hs inside conditional = jq 8
```

**7-8 jq processes per project entry.** With 20 projects, that's 160 jq spawns.

**Recommendation (CRITICAL):** Extract all fields in one jq call:

```bash
echo "$dashboard_data" | jq -r '.[] | [.project, .type // "-", .status // "-", (.ts // .timestamp // ""), .health_before // "", .health_after // "", .finding_count // ""] | @tsv' | while IFS=$'\t' read -r proj type status ts hb ha fc; do
    ...
done
```

Reduces 7N jq calls to 1.

### 3.6 `generate_detailed_report()`: Extreme jq per Finding

Lines 928-1057 of analyze.sh: For each finding in each category, it runs 8 separate jq calls:

```bash
id=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].id // "?"' "$findings_file")
severity=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].severity // "?"' "$findings_file")
title=$(jq -r ...)
file=$(jq -r ...)
line=$(jq -r ...)
description=$(jq -r ...)
fix=$(jq -r ...)
effort=$(jq -r ...)
```

**8 jq calls per finding.** With 20 findings across 4 categories, plus the filter `select(.category == $c)` recomputed each time, that's **160+ jq calls** just for report generation.

Additionally, the "Fix Instructions" table section (lines 1020-1039) runs another loop with 4 jq calls per finding per severity level.

**Recommendation (CRITICAL):** Pre-format all findings in a single jq call:

```bash
jq -r 'group_by(.category) | .[] | 
    "## \(.[0].category | ascii_upcase)\n",
    (.[] | "### \(.id) -- \(.title)\n- **Severity:** \(.severity)\n- **File:** `\(.file):\(.line)`\n- **Effort:** \(.effort)\n\n\(.description // "")\n\n**Suggested fix:** \(.fix // "")\n\n---\n")
' "$findings_file"
```

This replaces 8N jq calls with 1.

### 3.7 `display_findings()`: Per-Finding jq Loop

Lines 355-375 of analyze.sh: 4 jq calls per finding (id, severity, title, file), plus 4 calls for severity counts.

With 20 findings: **84 jq calls.**

---

## 4. File I/O Analysis

### Reads Per `kyzn improve` Run

| Operation                     | File Reads        | File Writes       |
|-------------------------------|-------------------|-------------------|
| Config loading (yq)           | ~7 reads          | 0                 |
| Measurements (mktemp dir)     | 0 initial         | 1 (measurements.json) |
| Generic measurer              | README.md (1)     | 0                 |
| Measurer merge                | 2-4 reads         | 2-4 writes        |
| Baseline measurement file     | ~3 reads          | 0                 |
| History write (dual)          | 0                 | 2 (local + global)|
| Claude invocation             | 1 (stderr file)   | 1 (stderr file)   |
| Diff analysis (git)           | 0 (git internal)  | 0                 |
| After measurement             | Same as baseline  | Same              |
| Report generation             | 2 reads           | 1 write           |
| History update                | 1 read            | 2 writes          |
| Lock file                     | 0                 | 1 (pid file)      |

**Total:** ~20 file reads, ~12 file writes per improve run. Reasonable.

### Temp File Cleanup

Temp files (`mktemp`) are properly cleaned up via the `_kyzn_cleanup` trap in `cmd_improve()`. The analyze command also cleans up properly. No leaks detected.

---

## 5. Network Calls

### Update Check

- `git fetch origin` with `timeout 5` -- properly guarded
- Runs once per day (86400s check) -- correct

### Claude API

- `timeout "$claude_timeout"` wraps all Claude invocations (default 600s for improve, 900s for analyze)
- Properly guarded with error handling

### `gh` CLI

- Used for PR creation and auto-merge only
- Error handling with `|| { log_warn ... }` -- correct

**Verdict:** Network calls are properly timeouled. No issues.

---

## 6. Memory Usage

### Large Bash Variables

| Variable | Max Size | Location |
|----------|----------|----------|
| `KYZN_CLAUDE_RESULT` | Entire Claude JSON response (can be 100KB+) | execute.sh:179 |
| `prompt` in assemble_prompt | Full prompt with measurements JSON | prompt.sh |
| `measurements_json` in analyze | Full measurements | analyze.sh |
| `dashboard_data` | All history entries slurped | history.sh:132 |
| `result` in run_specialist | Claude response per agent | analyze.sh:244 |
| `audit_output` in node.sh | npm audit JSON (can be large) | node.sh:11 |

### Concern: analyze.sh Multi-Agent Memory

In multi-agent mode, 4 Claude sessions run in parallel. Each stores its full response in a variable in a background process. After completion, findings are read from disk files. The background processes hold memory until `wait` completes.

With 4 parallel Opus sessions, each potentially returning 100KB+ JSON, memory usage could spike to ~500KB in bash variables. Not a practical concern on a 64GB system, but worth noting for constrained environments.

### Concern: dashboard_data slurp

```bash
dashboard_data=$(cat "${_valid_files[@]}" 2>/dev/null | jq -s '...')
```

This cats ALL global history files into a single jq invocation. With 1000+ history files, each ~500 bytes, that's ~500KB of input. jq can handle this easily, but the `cat` of 1000 files hits shell argument limits (ARG_MAX ~2MB on Linux for the file list). This will break silently with ~4000+ files.

**Recommendation:** Use `find | xargs` or process in batches.

---

## 7. Git Operations

### Per `kyzn improve` Run

| Step | Git Commands | Count |
|------|-------------|-------|
| require_git_repo | `git rev-parse --is-inside-work-tree` | 1 |
| project_root (uncached) | `git rev-parse --show-toplevel` | ~15 |
| detect_project_type | `git rev-parse` (via project_root) | 1 |
| write_history | `git rev-parse` (via project_name) | 2 |
| git checkout -b | `safe_git checkout -b` | 1 |
| verify_build (pre) | 0 git commands | 0 |
| diff check | `git add -A`, `git diff --cached --numstat`, `git reset` | 3 |
| verify_build (post) | 0 git commands | 0 |
| re-measure (project_root) | `git rev-parse` (via project_root) | 2 |
| per-category regression | 0 | 0 |
| generate_report | `git add -A` x2, `git diff --cached` x2, `git reset`, `git commit`, `git push` | 7 |
| safe_checkout_back | `git checkout` | 1 |

**Total:** ~33 git commands per improve run, with ~15 being redundant `rev-parse` calls.

**Recommendation:** Caching `project_root()` (as noted in section 2) saves ~15 git calls.

---

## 8. Measurer Efficiency

### Generic Measurer: Reasonable

- `grep -rn` for TODOs: scans source files once -- unavoidable
- `git status --porcelain`: 1 git call -- fine
- `find . -size +1M`: scans filesystem once -- unavoidable
- `grep -rniE` for secrets: scans source files once -- unavoidable
- README section checks: 4 grep calls on a single file -- negligible

### Node.js Measurer: Heavyweight

- `npm audit` is slow (network call, 5-30s)
- `npx eslint .` can take 10-60s on large projects
- `npx tsc --noEmit` can take 5-30s
- `npm outdated` is a network call (5-15s)

**Total for Node.js measurement:** 4 potentially slow external tool invocations. This is the dominant cost of `kyzn measure` for Node projects.

**Recommendation:** Consider adding `--quick` flag to skip slow tools (npm audit, tsc, eslint) and only run fast checks (grep, file counting).

### Python Measurer: `find` Called Twice

```bash
test_files=$(find . -name 'test_*.py' ...)
src_files=$(find . -name '*.py' -not -name 'test_*' ...)
```

Two separate `find` traversals of the same directory tree. Could be combined.

---

## 9. Dashboard Scalability Analysis

### Current Behavior with N History Files

| N (files) | jq calls (dashboard) | jq calls (history) | Estimated time |
|-----------|----------------------|---------------------|----------------|
| 10        | ~80                  | ~50                 | <1s            |
| 100       | ~710                 | ~500                | ~5s            |
| 500       | ~3,510               | ~2,500              | ~25s           |
| 1,000     | ~7,010               | ~5,000              | ~50s           |
| 5,000     | ~35,010              | ~25,000             | ~4min          |

The per-entry jq loop in both `cmd_history()` (5 jq/file) and `cmd_dashboard()` (7 jq/entry) makes these commands O(N) in subprocess spawns. Each jq subprocess takes ~10-50ms to start, parse, and exit.

### cat ARG_MAX Limit

```bash
dashboard_data=$(cat "${_valid_files[@]}" 2>/dev/null | jq -s '...')
```

On Linux, `ARG_MAX` is typically ~2MB. With file paths averaging ~80 chars, this breaks at ~25,000 files. The `find` on line 106 that counts files works fine, but the `cat` on line 132 will fail silently.

### Legacy Fallback Loop

If no entries have a `project` field, the dashboard falls back to a per-file loop (lines 152-176) with per-file jq + sed. This is even slower: `jq` + `sed` + `echo` per file.

---

## 10. Concurrency Issues

### Analyze Parallel Agents

`cmd_analyze()` runs 4 background `run_specialist` processes. The progress monitor loop (lines 721-761) polls with `kill -0` and `sleep 0.5`. This is correct but polls 2x/second.

No shared mutable state between the parallel agents (each writes to its own file). Clean design.

### Lock File

`cmd_improve()` uses mkdir-based locking with PID staleness check. This is the correct POSIX-portable approach. No race conditions detected.

---

## Recommendations

### Quick Wins (Low effort, high impact)

1. **Cache `project_root()` and `project_name()`** in core.sh — eliminates ~15 git subprocesses per command. File: `lib/core.sh:132-139`.

2. **Batch jq in `cmd_history()`** — replace 5 jq calls per file with 1 `jq -r '@tsv'` call for all files. File: `lib/history.sh:40-64`. Expected: 5x speedup for history display.

3. **Batch jq in `cmd_dashboard()`** — replace 7 jq calls per entry with 1 `jq -r '@tsv'` piped to while-read. File: `lib/history.sh:188-236`. Expected: 7x speedup.

4. **Single jq in `compute_health_score()`** — extract all 5 category values in one call instead of looping. File: `lib/measure.sh:126-138`. Expected: 5x reduction in that function.

### Medium-term (Higher effort)

5. **Refactor measurer result accumulation** — replace per-measurement jq with bash array building + final printf. All measurers in `measurers/`. Expected: eliminate 15-20 jq calls per measure run.

6. **Batch config loading** — load all config values in one yq call at command start. File: `lib/core.sh:62-94`. Expected: eliminate ~20 yq spawns per improve.

7. **Single-call report generation** — replace 8N jq calls in `generate_detailed_report()` with a single jq template. File: `lib/analyze.sh:928-1057`. Expected: 160+ jq calls reduced to 1 for a 20-finding report.

8. **Add `--quick` flag to measurers** — skip slow tools (npm audit, tsc, eslint) for fast feedback. Files: `lib/measure.sh`, `measurers/node.sh`.

### Architecture Changes

9. **Dashboard file format** — with 1000+ history files, consider a single JSONL (newline-delimited JSON) file instead of per-run files. This eliminates the file-per-entry overhead and the `cat` ARG_MAX issue. Would require migration logic.

10. **Python `find` deduplication** — combine two find traversals in `measurers/python.sh` into one with post-processing.

---

## Quantified Impact Summary

| Optimization | Subprocess Savings | Effort | Files |
|-------------|-------------------|--------|-------|
| Cache project_root/name | ~15 git calls/run | Small | core.sh |
| Batch history jq | 5N → 1 jq/run | Small | history.sh |
| Batch dashboard jq | 7N → 1 jq/run | Small | history.sh |
| Batch health score | 5-10 → 1 jq/call | Small | measure.sh |
| Measurer accumulators | ~20 → 0 jq/measure | Medium | measurers/*.sh |
| Config caching | ~20 → 1 yq/run | Medium | core.sh |
| Report generation | 8N → 1 jq/report | Medium | analyze.sh |
| Total (improve run) | ~80 → ~15 subprocesses | - | - |
| Total (analyze run, 20 findings) | ~250+ → ~30 subprocesses | - | - |

---

*Generated by KyZN full audit -- profiler agent*
