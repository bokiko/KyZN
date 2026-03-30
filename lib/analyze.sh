#!/usr/bin/env bash
# kyzn/lib/analyze.sh — Multi-agent deep analysis via Opus + fix execution via Sonnet
# Architecture: 4 parallel specialized Opus sessions → consensus merge → findings report

# ---------------------------------------------------------------------------
# Specialist prompt builders (each reviewer gets a focused personality)
# ---------------------------------------------------------------------------
build_specialist_prompt() {
    local specialist="$1"
    local project_name="$2"
    local project_type="$3"
    local health_score="$4"
    local measurements_json="$5"

    local preamble="## Deep Analysis Request

**Project:** $project_name
**Type:** $project_type
**Current Health Score:** $health_score/100

## Measurements

\`\`\`json
$measurements_json
\`\`\`"

    local output_format='### Output Format

Return your findings as a JSON array. Each finding must have this structure:

\`\`\`json
[
  {
    "id": "PREFIX-001",
    "severity": "HIGH",
    "category": "CATEGORY",
    "title": "Short description",
    "file": "path/to/file",
    "line": 42,
    "description": "Detailed explanation of the problem",
    "fix": "Concrete description of how to fix it",
    "fix_plan": "target_file: path/to/file.py | target_function: process_data | pattern_to_follow: see src/auth.py:validate for correct pattern | test_file: tests/test_process.py | test_approach: mock with unittest.mock.patch, assert ValueError raised | constraints: do not modify function signature",
    "effort": "small"
  }
]
\`\`\`

- **severity**: CRITICAL, HIGH, MEDIUM, LOW
- **effort**: small (< 10 lines), medium (10-50 lines), large (50+ lines)
- **fix_plan**: structured guidance for the AI that will implement the fix. Include: target_file, target_function, pattern_to_follow (reference existing code), test_file, test_approach, constraints. Pipe-delimited fields. Optional — omit if the fix is trivially obvious.
- Only report findings you can CONFIRM by reading actual code
- If you find nothing significant, return an empty array `[]`
- Quality over quantity — 3 real findings beat 20 maybes'

    case "$specialist" in
        security)
            cat <<EOF
$preamble

## Your Role: SECURITY REVIEWER

You are a senior application security engineer performing a security audit. Your job is to find vulnerabilities that could be exploited.

### What to look for

1. **Injection** — SQL injection, command injection, XSS, template injection, path traversal
2. **Authentication & Authorization** — auth bypass, privilege escalation, missing access checks
3. **Secrets** — hardcoded credentials, API keys, tokens, passwords in source code
4. **Cryptography** — weak hashing, insecure random, hardcoded IVs/salts
5. **Deserialization** — unsafe deserialization of untrusted data (pickle, eval, YAML load)
6. **Dependencies** — known vulnerable packages, outdated security-critical deps
7. **Input validation** — missing sanitization at trust boundaries

### How to analyze

1. Start at external entry points (HTTP handlers, CLI args, file uploads, API endpoints)
2. Trace user input through the entire data flow — where does it end up?
3. Look for EVERY place external data touches a sensitive operation (DB, shell, file system)
4. Check authentication middleware — is it applied to every route that needs it?
5. Use **id prefix**: SEC-001, SEC-002, etc.
6. Use **category**: security

$output_format
EOF
            ;;
        correctness)
            cat <<EOF
$preamble

## Your Role: CORRECTNESS REVIEWER

You are a senior software engineer focused on finding bugs and logic errors. You care about correctness, not style.

### What to look for

1. **Logic errors** — wrong conditions, off-by-one, inverted boolean, missing negation
2. **Null/undefined access** — dereferencing null, accessing properties on undefined, missing nil checks
3. **Race conditions** — concurrent access without synchronization, TOCTOU bugs
4. **Error handling** — uncaught exceptions, swallowed errors, missing error propagation
5. **Type errors** — type coercion bugs, wrong type assumptions, unsafe casts
6. **Edge cases** — empty arrays, zero values, boundary conditions, Unicode, large inputs
7. **Resource leaks** — unclosed files/connections/handles, missing cleanup

### How to analyze

1. Start at entry points, trace execution paths end-to-end
2. For each function, ask: "What happens when the input is empty? Null? Very large? Wrong type?"
3. Check every error path — are errors handled or silently swallowed?
4. Look for assumptions that aren't validated ("this array always has elements")
5. Use **id prefix**: BUG-001, BUG-002, etc.
6. Use **category**: bug

$output_format
EOF
            ;;
        performance)
            cat <<EOF
$preamble

## Your Role: PERFORMANCE REVIEWER

You are a senior performance engineer. You find code that will be slow, use too much memory, or scale poorly.

### What to look for

1. **N+1 queries** — database queries inside loops, redundant fetches
2. **Unbounded operations** — loops without limits, recursive calls without depth control
3. **Memory issues** — large objects held unnecessarily, missing cleanup, growing buffers
4. **Blocking I/O** — synchronous I/O on hot paths, missing async/concurrency
5. **Missing caching** — expensive computations repeated without caching
6. **Algorithmic complexity** — O(n²) or worse where O(n) is possible
7. **Dead code** — unused functions, unreachable branches, stale imports that increase load time

### How to analyze

1. Identify hot paths — what code runs on every request/invocation?
2. Look for loops that do I/O (database, network, file system)
3. Check data structures — are they appropriate for the access patterns?
4. Look for missing pagination, unbounded result sets
5. Use **id prefix**: PERF-001 for performance, DEAD-001 for dead code
6. Use **category**: performance or dead-code

$output_format
EOF
            ;;
        architecture)
            cat <<EOF
$preamble

## Your Role: ARCHITECTURE REVIEWER

You are a senior architect. You find structural problems that make the codebase hard to maintain, test, or extend.

### What to look for

1. **Circular dependencies** — modules importing each other, tight coupling
2. **God objects/functions** — classes/functions doing too many things
3. **Leaky abstractions** — implementation details exposed across module boundaries
4. **Missing error boundaries** — errors propagating unchecked across layers
5. **API design issues** — inconsistent interfaces, breaking contracts, missing validation at boundaries
6. **Testing gaps** — critical paths without tests, tests that don't assert anything meaningful
7. **Configuration issues** — hardcoded values that should be configurable, missing environment handling

### How to analyze

1. Map the module/package structure — who depends on whom?
2. Look at public interfaces — are they minimal and consistent?
3. Check test coverage — which critical paths have NO tests?
4. Look for patterns that make testing impossible (global state, hard dependencies)
5. Use **id prefix**: ARCH-001 for architecture, TEST-001 for testing gaps
6. Use **category**: architecture or testing

$output_format
EOF
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Build consensus prompt from all specialist findings
# ---------------------------------------------------------------------------
build_consensus_prompt() {
    local security_findings="$1"
    local correctness_findings="$2"
    local performance_findings="$3"
    local architecture_findings="$4"

    cat <<EOF
## Consensus Review

Four specialist reviewers analyzed a codebase independently. Your job is to merge their findings into a single, deduplicated, ranked report.

### Security Reviewer Findings
\`\`\`json
$security_findings
\`\`\`

### Correctness Reviewer Findings
\`\`\`json
$correctness_findings
\`\`\`

### Performance Reviewer Findings
\`\`\`json
$performance_findings
\`\`\`

### Architecture Reviewer Findings
\`\`\`json
$architecture_findings
\`\`\`

## Your Task

1. **Deduplicate** — if two reviewers found the same issue, keep the better description
2. **Validate** — remove findings that seem like false positives or style complaints
3. **Rank** — order by severity (CRITICAL > HIGH > MEDIUM > LOW), then by confidence
4. **Re-ID** — assign clean sequential IDs (SEC-001, BUG-001, PERF-001, ARCH-001, TEST-001, DEAD-001)
5. **Quality filter** — remove any finding that doesn't have a concrete file path and actionable fix
6. **Preserve fix_plan** — if a specialist provided a fix_plan field, keep it as-is. Do NOT generate new fix_plan fields — that is the specialists' job.

## Output Rules

- Output ONLY the JSON array. No commentary, no explanations, no reasoning.
- Start your response with \`[\` and end with \`]\`.
- Do NOT wrap the JSON in markdown code fences.
- Only include findings that are real, actionable issues. If reviewers disagree, favor the more specific finding.
EOF
}

# ---------------------------------------------------------------------------
# Run a single specialist Opus session
# ---------------------------------------------------------------------------
run_specialist() {
    local specialist="$1"
    local prompt="$2"
    local sys_prompt_file="$3"
    local budget="$4"
    local output_file="$5"
    local model="${6:-opus}"
    local provider="${7:-${KYZN_PROVIDER:-claude}}"

    local -a allowlist_arr=(--allowedTools Read --allowedTools Glob --allowedTools Grep)
    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-900}"

    local stderr_file
    stderr_file=$(mktemp)

    local result
    result=$(invoke_ai \
        --provider "$provider" \
        --contract "findings_json" \
        --prompt "$prompt" \
        --model "$model" \
        --budget "$budget" \
        --max-turns 30 \
        --timeout "$claude_timeout" \
        --system-prompt-file "$sys_prompt_file" \
        --allowlist-arr allowlist_arr \
        --settings "$KYZN_SETTINGS_JSON" \
        --stderr-file "$stderr_file") || {
        log_error "[$specialist] failed"
        rm -f "$stderr_file"
        echo '[]' > "$output_file"
        return 1
    }
    rm -f "$stderr_file"

    # Extract findings and save (validate JSON before writing)
    local findings
    findings=$(extract_findings_from_result "$provider" "$result")
    local validated
    validated=$(echo "$findings" | jq -e 'type == "array"' > /dev/null 2>&1 && echo "$findings" | jq '.' 2>/dev/null) || validated=""
    if [[ -n "$validated" ]]; then
        echo "$validated" > "$output_file"
    else
        log_warn "[$specialist] returned malformed findings — skipping"
        echo '[]' > "$output_file"
    fi

    local cost count
    cost=$(echo "$result" | jq -r '.total_cost_usd // "?"')
    count=$(jq 'length' "$output_file")
    log_ok "[$specialist] done — $count findings (\$$cost)"
}

# ---------------------------------------------------------------------------
# Parse findings JSON from Claude's response
# ---------------------------------------------------------------------------
extract_findings() {
    local claude_result="$1"

    local text_content
    text_content=$(echo "$claude_result" | jq -r '
        .result // .content // ""
        | if type == "array" then
            map(select(.type == "text") | .text) | join("\n")
          else
            .
          end
    ' 2>/dev/null) || text_content=""

    local findings=""

    if echo "$text_content" | jq -e 'type == "array"' &>/dev/null; then
        findings="$text_content"
    else
        findings=$(echo "$text_content" | sed -n '/^\[/,/^\]/p' | head -500)
        if ! echo "$findings" | jq -e 'type == "array"' &>/dev/null; then
            findings=$(echo "$text_content" | sed -n '/```json/,/```/p' | sed '1d;$d')
            if ! echo "$findings" | jq -e 'type == "array"' &>/dev/null; then
                findings="[]"
            fi
        fi
    fi

    echo "$findings"
}

# ---------------------------------------------------------------------------
# Run profiler agent — reads repo files, extracts conventions, caches result
# ---------------------------------------------------------------------------
run_profiler() {
    local project_type="$1"
    local budget="$2"
    local output_file="$3"

    # Cache check: .kyzn/repo-profile.md with SHA on line 1
    local cache_file="$KYZN_PROFILE_CACHE"
    local current_sha
    current_sha=$(git rev-parse HEAD 2>/dev/null || echo "none")
    if [[ -f "$cache_file" ]]; then
        local cached_sha
        cached_sha=$(sed -n '1s/^<!-- sha:\(.*\) -->/\1/p' "$cache_file")
        if [[ "$cached_sha" == "$current_sha" ]]; then
            log_ok "Profiler: using cached repo profile (SHA match)"
            cp "$cache_file" "$output_file"
            return 0
        fi
    fi

    local lang_name
    lang_name=$(project_type_name "$project_type")

    local profiler_prompt="## Repo Convention Profiler

You are analyzing a $lang_name project to extract its coding conventions. Read 3-5 representative source files and produce a concise conventions profile.

### What to Extract

1. **Naming** — variable/function/class naming style (snake_case, camelCase, PascalCase)
2. **Imports** — import organization pattern (grouped? sorted? relative vs absolute?)
3. **Error handling** — how errors are handled (exceptions, Result types, error codes, custom error classes)
4. **Testing** — test framework, test file location, fixture patterns, mocking approach
5. **Architecture** — module organization, layer separation, dependency injection pattern
6. **Type safety** — type annotations, strict mode, interface patterns

### How to Analyze

1. Use Glob to find source files (look in src/, lib/, app/, or root)
2. Read 3-5 files that seem central (entry points, core modules, models)
3. Read 1-2 test files to understand testing patterns
4. Look at config files (tsconfig, pyproject.toml, Cargo.toml, etc.) for style settings

### Output Format

Return ONLY a markdown document under 500 words with these sections:

\`\`\`markdown
## Repo-Specific Conventions

### Naming
(patterns observed)

### Imports
(patterns observed)

### Error Handling
(patterns observed)

### Testing
(framework, patterns, file locations)

### Architecture
(module structure, patterns)

### Key Patterns
(any notable patterns specific to this codebase)
\`\`\`

Be specific — reference actual file names and patterns you observed. Do not guess or generalize beyond what you read."

    local profiler_stderr
    profiler_stderr=$(mktemp)
    local profiler_timeout=60
    local profiler_provider="${KYZN_PROVIDER:-claude}"

    log_step "Profiler: scanning repo conventions..."

    local -a profiler_allowlist=(--allowedTools Read --allowedTools Glob --allowedTools Grep)
    local profiler_result
    profiler_result=$(invoke_ai \
        --provider "$profiler_provider" \
        --contract "free_text" \
        --prompt "$profiler_prompt" \
        --model sonnet \
        --budget "$budget" \
        --max-turns 15 \
        --timeout "$profiler_timeout" \
        --allowlist-arr profiler_allowlist \
        --settings "$KYZN_SETTINGS_JSON" \
        --stderr-file "$profiler_stderr") || {
        log_warn "Profiler failed — continuing without repo conventions"
        rm -f "$profiler_stderr"
        return 1
    }
    rm -f "$profiler_stderr"

    # Extract text content from Claude response
    local profile_text
    profile_text=$(echo "$profiler_result" | jq -r '
        .result // .content // ""
        | if type == "array" then
            map(select(.type == "text") | .text) | join("\n")
          else
            .
          end
    ' 2>/dev/null) || profile_text=""

    if [[ -z "$profile_text" ]]; then
        log_warn "Profiler returned empty result — continuing without repo conventions"
        return 1
    fi

    local profiler_cost
    profiler_cost=$(echo "$profiler_result" | jq -r '.total_cost_usd // "?"')
    log_ok "Profiler complete (\$$profiler_cost)"

    # Write to cache with SHA header
    ensure_kyzn_dirs
    {
        echo "<!-- sha:${current_sha} -->"
        echo "$profile_text"
    } > "$cache_file"

    # Copy to output
    cp "$cache_file" "$output_file"

    # Add to .kyzn/.gitignore if not already there
    local gi="$KYZN_DIR/.gitignore"
    if [[ -f "$gi" ]] && ! grep -qF "repo-profile.md" "$gi"; then
        echo "repo-profile.md" >> "$gi"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Display findings in a human-readable format
# ---------------------------------------------------------------------------
display_findings() {
    local findings_file="$1"
    local report_path="${2:-kyzn-report.md}"
    # Optional pre-computed severity counts (args 3-6) — computed from file if absent
    local critical="${3:-}"
    local high="${4:-}"
    local medium="${5:-}"
    local low="${6:-}"

    local count
    count=$(jq 'length' "$findings_file")

    if (( count == 0 )); then
        log_ok "No significant issues found."
        return
    fi

    # Terminal width (capped at 120)
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 80)
    if (( term_width > 120 )); then term_width=120; fi

    # Column widths: 2 indent + 10 ID + 2 gap + title (adaptive) + 2 gap + 30 file
    local id_col=10
    local file_col=30
    local gap=2
    local indent=4
    local title_col=$(( term_width - indent - id_col - gap - file_col - gap ))
    if (( title_col < 20 )); then title_col=20; fi

    # Severity counts (use pre-computed values if provided)
    if [[ -z "$critical" ]]; then
        critical=$(jq '[.[] | select(.severity == "CRITICAL")] | length' "$findings_file")
        high=$(jq '[.[] | select(.severity == "HIGH")] | length' "$findings_file")
        medium=$(jq '[.[] | select(.severity == "MEDIUM")] | length' "$findings_file")
        low=$(jq '[.[] | select(.severity == "LOW")] | length' "$findings_file")
    fi

    echo ""
    echo -e "  ${BOLD}Analysis Findings${RESET} — $count issues"
    echo ""

    # One-liner per finding — full details are in the report
    while IFS=$'\t' read -r id severity title file; do
        local sev_color="$DIM"
        local sev_pad=""
        case "$severity" in
            CRITICAL) sev_color="$RED" ;;
            HIGH)     sev_color="$YELLOW"; sev_pad="    " ;;
            MEDIUM)   sev_color="$CYAN"; sev_pad="  " ;;
            LOW)      sev_pad="     " ;;
        esac

        printf "  ${sev_color}[%s]${RESET}%s ${BOLD}%s${RESET} — %-50s ${DIM}%s${RESET}\n" \
            "$severity" "$sev_pad" "$id" "$title" "$file"
    done < <(jq -r '.[] | [(.id // "?"), (.severity // "MEDIUM"), (.title // "?"), (.file // "?")] | @tsv' "$findings_file")
    echo ""
}

# ---------------------------------------------------------------------------
# Generate fix prompt from findings for Sonnet
# ---------------------------------------------------------------------------
generate_fix_prompt() {
    local findings_json="$1"
    local report_file="${2:-}"
    local baseline_failures="${3:-}"
    local installed_packages="${4:-}"
    local repo_profile="${5:-}"

    local count
    count=$(echo "$findings_json" | jq 'length')

    if (( count == 0 )); then
        echo ""
        return
    fi

    # Include full markdown report for rich context if available
    local report_context=""
    if [[ -n "$report_file" && -f "$report_file" ]]; then
        report_context="## Full Analysis Report

The following detailed report was generated by the analysis phase. Use it for context on each finding — it contains full descriptions, explanations, and suggested fixes.

<report>
$(cat "$report_file")
</report>

---

"
    fi

    # Include baseline failure context so Claude knows what was already broken
    local baseline_context=""
    if [[ -n "$baseline_failures" ]]; then
        baseline_context="## Pre-Existing Test Failures

The following tests were ALREADY failing before your changes. Do NOT try to fix these — they are pre-existing issues. Only ensure you don't make them worse or add NEW failures.

\`\`\`
$baseline_failures
\`\`\`

---

"
    fi

    # Include repo profile if available
    local profile_context=""
    if [[ -n "$repo_profile" && -f "$repo_profile" ]]; then
        local profile_content
        # Strip SHA comment line
        profile_content=$(tail -n +2 "$repo_profile")
        if [[ -n "$profile_content" ]]; then
            profile_context="## Repo Profile

The following conventions were extracted from this repo by a profiler agent. Follow these patterns when writing fixes.

$profile_content

---

"
        fi
    fi

    cat <<EOF
## Fix These Issues

The following issues were identified by a multi-agent deep analysis (4 specialized Opus reviewers + consensus). Fix each one.

### Findings to Fix ($count issues)

\`\`\`json
$findings_json
\`\`\`

$(
    # Project context section — language, test framework, available packages
    local _test_fw=""
    case "${KYZN_PROJECT_TYPE:-generic}" in
        python) _test_fw="pytest" ;;
        node)   _test_fw="jest/vitest" ;;
        rust)   _test_fw="cargo test" ;;
        go)     _test_fw="go test" ;;
    esac
    if [[ -n "$_test_fw" ]]; then
        echo "## Project Context"
        echo "- Language: $(project_type_name)"
        echo "- Test framework: $_test_fw"
        echo ""
    fi
    if [[ -n "$installed_packages" ]]; then
        echo "## Available Packages"
        echo "These packages are installed. When writing tests, ONLY import from these packages plus the standard library. For anything else, use mocks (unittest.mock for Python, jest.mock for Node)."
        echo ""
        echo '```'
        echo "$installed_packages"
        echo '```'
        echo ""
        echo "Do NOT add new dependencies to requirements.txt, package.json, or any manifest."
        echo ""
    fi
)
${report_context}${baseline_context}${profile_context}## How to Use Fix Plans

Each finding may include a fix_plan with guidance on which file, function, and pattern to follow.
- START by reading the target file and verifying the fix_plan matches reality
- If the fix_plan references a function that doesn't exist, find the correct location yourself
- If the fix_plan references a pattern from another file, read that file first
- The fix_plan is a guide, not a script — adapt it to the actual code state
- If you deviate from the plan, note what you changed and why

## Rules

- Fix each issue in the order listed (highest severity first)
- For each fix, verify you're changing the right code by reading the file first
- After each fix, make sure the code still compiles/passes tests
- If a finding describes something that contradicts reality (e.g., claims code is broken but it works), skip that finding and explain why
- If a fix is too risky or you're not confident, skip it and note why
- When fixing a security vulnerability (SEC-*), add at least one regression test that would have caught the vulnerability
- When fixing a critical bug (BUG-* at CRITICAL/HIGH), add a test that verifies the fix
- Do NOT make any changes beyond what's listed here — no drive-by refactoring
- Do NOT delete test files or remove large blocks of existing tests — only modify tests if a finding specifically targets test code AND the test is genuinely broken

## Output

After making changes, summarize what you fixed:
- Finding ID
- What you changed
- File and line
- Any findings you skipped and why
EOF
}

# ---------------------------------------------------------------------------
# cmd_analyze — Multi-agent Opus deep analysis
# ---------------------------------------------------------------------------
cmd_analyze() {
    require_git_repo

    # Parse args
    local focus=""
    local budget=""
    local fix=false
    local fix_budget=""
    local min_severity="LOW"
    local single=false
    local profile=""
    local export_path=""
    local auto=false
    local provider_from_cli=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider)     [[ $# -ge 2 ]] || { log_error "--provider requires a value"; return 1; }; provider_from_cli="$2"; shift 2 ;;
            --focus)        [[ $# -ge 2 ]] || { log_error "--focus requires a value"; return 1; }; focus="$2"; shift 2 ;;
            --budget)       [[ $# -ge 2 ]] || { log_error "--budget requires a value"; return 1; }; budget="$2"; shift 2
                [[ "${budget:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { log_error "Invalid budget value: $budget"; return 1; } ;;
            --fix)          fix=true; shift ;;
            --fix-budget)   [[ $# -ge 2 ]] || { log_error "--fix-budget requires a value"; return 1; }; fix_budget="$2"; shift 2
                [[ "${fix_budget:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { log_error "Invalid fix-budget value: $fix_budget"; return 1; } ;;
            --min-severity) [[ $# -ge 2 ]] || { log_error "--min-severity requires a value"; return 1; }; min_severity="$2"; shift 2 ;;
            --single)       single=true; shift ;;
            --profile)      [[ $# -ge 2 ]] || { log_error "--profile requires a value"; return 1; }; profile="$2"; shift 2 ;;
            --export)       [[ $# -ge 2 ]] || { log_error "--export requires a value"; return 1; }; export_path="$2"; shift 2 ;;
            --auto)         auto=true; shift ;;
            *)              log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    fix_budget="${fix_budget:-5.00}"

    # Resolve provider (CLI flag > config > default) — pinned for this entire command
    local requested_provider="${provider_from_cli:-$(config_get '.preferences.provider' 'claude')}"
    local KYZN_PROVIDER
    KYZN_PROVIDER=$(resolve_provider "$requested_provider") || return 1
    log_info "Provider: $(provider_display_name "$KYZN_PROVIDER")"

    # Detect project
    detect_project_type
    detect_project_features
    print_detection

    # Measure first
    local measure_dir
    measure_dir=$(mktemp -d)
    run_measurements "$KYZN_PROJECT_TYPE" "$measure_dir"
    local measurements_file="$KYZN_MEASUREMENTS_FILE"

    display_health_dashboard "$measurements_file"

    # Model profile selection (unless --auto or --profile passed)
    local analysis_model="opus"
    local _model_security="opus" _model_correctness="opus" _model_performance="opus" _model_architecture="opus" _model_consensus="opus"

    # Helper to get model for a specialist
    _agent_model() {
        case "$1" in
            security)     echo "$_model_security" ;;
            correctness)  echo "$_model_correctness" ;;
            performance)  echo "$_model_performance" ;;
            architecture) echo "$_model_architecture" ;;
            consensus)    echo "$_model_consensus" ;;
        esac
    }

    if [[ -z "$profile" ]] && ! $auto && ! $single && [[ -z "$focus" ]]; then
        local profile_choice
        profile_choice=$(prompt_choice "Model profile?" \
            "All Opus    — maximum accuracy (recommended)" \
            "Hybrid      — Opus for security+correctness, Sonnet for perf+arch" \
            "All Sonnet  — fastest, cheapest")

        case "$profile_choice" in
            1) profile="opus" ;;
            2) profile="hybrid" ;;
            3) profile="sonnet" ;;
        esac
    fi
    profile="${profile:-opus}"

    case "$profile" in
        opus)
            ;; # all opus, default
        hybrid)
            _model_performance="sonnet"
            _model_architecture="sonnet"
            _model_consensus="sonnet"
            ;;
        sonnet)
            _model_security="sonnet"; _model_correctness="sonnet"
            _model_performance="sonnet"; _model_architecture="sonnet"
            _model_consensus="sonnet"
            analysis_model="sonnet"
            ;;
    esac

    # Set budgets based on profile (hidden from user)
    if [[ -z "$budget" ]]; then
        case "$profile" in
            opus)   budget="20.00" ;;
            hybrid) budget="12.00" ;;
            sonnet) budget="8.00" ;;
        esac
    fi

    local profiler_budget="0.50"
    local per_agent_budget
    if $single; then
        per_agent_budget="$budget"
    else
        local analysis_budget
        analysis_budget=$(awk -v b="$budget" -v p="$profiler_budget" 'BEGIN {printf "%.2f", b - p}')
        per_agent_budget=$(awk -v a="$analysis_budget" 'BEGIN {printf "%.2f", a / 5}')
    fi

    # Confirm
    echo ""
    echo -e "${BOLD}Analysis settings:${RESET}"
    echo -e "  Profile: ${CYAN}$profile${RESET}"
    if ! $single && [[ -z "$focus" ]]; then
        echo -e "  Agents:  ${CYAN}4 specialists + consensus${RESET}"
        echo -e "           security | correctness | performance | architecture"
    elif [[ -n "$focus" ]]; then
        echo -e "  Focus:   ${CYAN}$focus${RESET} (single reviewer)"
    fi
    echo -e "  Estimated cost: ${YELLOW}~\$$budget${RESET} ($profile profile)"
    echo ""

    if ! $auto && ! prompt_yn "Run deep analysis?"; then
        log_info "Cancelled."
        rm -rf "$measure_dir"
        return 0
    fi

    # Generate run ID
    local run_id
    run_id=$(generate_run_id)
    ensure_kyzn_dirs

    # Write initial "running" history entry
    declare -A _hist=([health_score]="${KYZN_HEALTH_SCORE:-0}")
    write_history "$run_id" "analyze" "running" _hist

    # Cleanup variables (initialized before trap)
    local _analyze_pids=() _analyze_tmp_dir="" _analyze_sys_prompt="" _analyze_consensus_stderr=""

    # Cleanup function — handles Ctrl+C, errors, and normal exit
    _kyzn_analyze_cleanup() {
        # Kill any running background Claude processes
        local _p
        for _p in "${_analyze_pids[@]:-}"; do
            [[ -n "$_p" ]] && kill "$_p" 2>/dev/null && wait "$_p" 2>/dev/null || true
        done
        # Update history if still running
        if [[ -n "${run_id:-}" ]]; then
            local _hist_file="$KYZN_HISTORY_DIR/$run_id.json"
            if [[ -f "$_hist_file" ]]; then
                local _cur_status
                _cur_status=$(jq -r '.status // ""' "$_hist_file" 2>/dev/null) || true
                if [[ "$_cur_status" == "running" ]]; then
                    declare -A _cleanup_hist=([health_score]="${KYZN_HEALTH_SCORE:-0}")
                    write_history "$run_id" "analyze" "failed" _cleanup_hist 2>/dev/null || true
                fi
            fi
        fi
        # Clean temp files
        [[ -d "${_analyze_tmp_dir:-}" ]] && rm -rf "$_analyze_tmp_dir" 2>/dev/null
        [[ -n "${_analyze_sys_prompt:-}" ]] && rm -f "$_analyze_sys_prompt" 2>/dev/null
        [[ -n "${_analyze_consensus_stderr:-}" ]] && rm -f "$_analyze_consensus_stderr" 2>/dev/null
        [[ -d "${measure_dir:-}" ]] && rm -rf "$measure_dir" 2>/dev/null
        trap - EXIT INT TERM
    }
    trap _kyzn_analyze_cleanup EXIT INT TERM

    local measurements_json
    measurements_json=$(cat "$measurements_file" 2>/dev/null || echo '[]')

    # Build system prompt
    local sys_prompt_file
    sys_prompt_file=$(mktemp)
    _analyze_sys_prompt="$sys_prompt_file"
    cat "$KYZN_ROOT/templates/system-prompt.md" > "$sys_prompt_file"
    echo "" >> "$sys_prompt_file"
    echo "---" >> "$sys_prompt_file"
    echo "" >> "$sys_prompt_file"
    cat "$KYZN_ROOT/templates/analysis-prompt.md" >> "$sys_prompt_file"

    # Append language conventions to sys_prompt_file (Stage 1 gap fix — was missing in analyze path)
    local lang="${KYZN_PROJECT_TYPE:-generic}"
    local conventions="$KYZN_ROOT/templates/conventions/$lang.md"
    if [[ -f "$conventions" ]]; then
        echo "" >> "$sys_prompt_file"
        echo "---" >> "$sys_prompt_file"
        echo "" >> "$sys_prompt_file"
        cat "$conventions" >> "$sys_prompt_file"
    fi

    # Run profiler agent — reads repo files, extracts conventions, caches result
    local repo_profile_file=""
    if ! $single; then
        repo_profile_file=$(mktemp)
        if run_profiler "$KYZN_PROJECT_TYPE" "$profiler_budget" "$repo_profile_file"; then
            # Append repo profile to sys_prompt_file so all specialists see it
            echo "" >> "$sys_prompt_file"
            echo "---" >> "$sys_prompt_file"
            echo "" >> "$sys_prompt_file"
            # Strip SHA comment line from output
            tail -n +2 "$repo_profile_file" >> "$sys_prompt_file"
        else
            rm -f "$repo_profile_file"
            repo_profile_file=""
        fi
    fi

    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-900}"
    local settings_json="$KYZN_SETTINGS_JSON"
    local total_cost=0

    local findings_file="$KYZN_REPORTS_DIR/$run_id-findings.json"

    if $single || [[ -n "$focus" ]]; then
        # ---------------------------------------------------------------
        # Single-agent mode (--single flag or --focus narrows to one area)
        # ---------------------------------------------------------------
        local provider_name
        provider_name=$(provider_display_name "$KYZN_PROVIDER")
        log_step "$provider_name is reading your codebase... (this may take several minutes)"

        local prompt
        prompt=$(build_specialist_prompt "${focus:-correctness}" "$(project_name)" \
            "$(project_type_name "$KYZN_PROJECT_TYPE")" "${KYZN_HEALTH_SCORE:-0}" "$measurements_json")

        local -a allowlist_arr=(--allowedTools Read --allowedTools Glob --allowedTools Grep)
        local stderr_file
        stderr_file=$(mktemp)

        local result
        result=$(invoke_ai \
            --provider "$KYZN_PROVIDER" \
            --contract "findings_json" \
            --prompt "$prompt" \
            --model opus \
            --budget "$budget" \
            --max-turns 40 \
            --timeout "$claude_timeout" \
            --system-prompt-file "$sys_prompt_file" \
            --allowlist-arr allowlist_arr \
            --settings "$settings_json" \
            --stderr-file "$stderr_file") || {
            rm -f "$stderr_file" "$sys_prompt_file"
            rm -rf "$measure_dir"
            return 1
        }
        rm -f "$stderr_file"

        total_cost=$(echo "$result" | jq -r '.total_cost_usd // 0')
        log_ok "Analysis complete (cost: \$$total_cost)"

        local findings
        findings=$(extract_findings_from_result "$KYZN_PROVIDER" "$result")
        echo "$findings" | jq '.' > "$findings_file" 2>/dev/null || echo '[]' > "$findings_file"
    else
        # ---------------------------------------------------------------
        # Multi-agent mode (default) — 4 specialists in parallel
        # ---------------------------------------------------------------
        log_header "Phase 1: Dispatching 4 specialist reviewers (parallel)"

        local tmp_dir
        tmp_dir=$(mktemp -d)
        _analyze_tmp_dir="$tmp_dir"

        local pids=()
        local specialists=("security" "correctness" "performance" "architecture")
        # Parallel arrays: pid_specs[i] matches pids[i]
        local pid_specs=()
        # Status tracking: _status_security, _status_correctness, etc.
        local _status_security="running" _status_correctness="running" _status_performance="running" _status_architecture="running"

        # Helper: get/set status for a specialist
        _get_status() { declare -n _ref="_status_$1"; echo "$_ref"; }
        _set_status() { printf -v "_status_$1" '%s' "$2"; }

        for spec in "${specialists[@]}"; do
            local spec_prompt
            spec_prompt=$(build_specialist_prompt "$spec" "$(project_name)" \
                "$(project_type_name "$KYZN_PROJECT_TYPE")" "${KYZN_HEALTH_SCORE:-0}" "$measurements_json")

            run_specialist "$spec" "$spec_prompt" "$sys_prompt_file" "$per_agent_budget" "$tmp_dir/${spec}.json" "$(_agent_model "$spec")" "$KYZN_PROVIDER" &
            local pid=$!
            pids+=($pid)
            pid_specs+=("$spec")
        done

        # Track PIDs for cleanup trap
        _analyze_pids=("${pids[@]}")

        echo ""

        # Progress monitor — spinner + agent dots + phase hints
        local start_time completed_count
        start_time=$(date +%s)
        completed_count=0

        # Spinner frames and phase hint messages
        local spinner_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local phase_hints=(
            "Reading entry points and imports..."
            "Tracing function call chains..."
            "Analyzing error handling paths..."
            "Checking data flow and validation..."
            "Reviewing authentication logic..."
            "Scanning for edge cases..."
            "Examining test coverage gaps..."
            "Inspecting dependency usage..."
            "Evaluating API boundaries..."
            "Cross-referencing module dependencies..."
            "Mapping input sanitization..."
            "Checking resource cleanup paths..."
            "Analyzing concurrency patterns..."
            "Reviewing type safety..."
            "Inspecting configuration handling..."
            "Tracing data serialization..."
        )
        local spin_idx=0

        while (( completed_count < ${#specialists[@]} )); do
            # Check which pids have finished
            local pi
            for pi in "${!pids[@]}"; do
                local spec_name="${pid_specs[$pi]}"
                if [[ "$(_get_status "$spec_name")" == "running" ]] && ! kill -0 "${pids[$pi]}" 2>/dev/null; then
                    if wait "${pids[$pi]}" 2>/dev/null; then
                        _set_status "$spec_name" "done"
                    else
                        _set_status "$spec_name" "failed"
                    fi
                    completed_count=$((completed_count + 1))
                fi
            done

            # Build status display
            local elapsed=$(( $(date +%s) - start_time ))
            local mins=$(( elapsed / 60 ))
            local secs=$(( elapsed % 60 ))
            local frame="${spinner_frames[$((spin_idx % ${#spinner_frames[@]}))]}"
            local hint="${phase_hints[$((elapsed / 4 % ${#phase_hints[@]}))]}"
            spin_idx=$((spin_idx + 1))

            # Line 1: spinner + time + agent dots
            local status_line="  ${CYAN}${frame}${RESET} ${DIM}[${mins}m$(printf '%02d' $secs)s]${RESET} "
            for spec in "${specialists[@]}"; do
                case "$(_get_status "$spec")" in
                    running) status_line+="${YELLOW}◌${RESET} $spec  " ;;
                    done)    status_line+="${GREEN}●${RESET} $spec  " ;;
                    failed)  status_line+="${RED}✗${RESET} $spec  " ;;
                esac
            done

            # Line 2: phase hint
            local hint_line="  ${DIM}${hint}${RESET}"

            # Move up, clear, print both lines
            echo -en "\033[2K\r${status_line}\n\033[2K\r${hint_line}\033[1A"

            if (( completed_count < ${#specialists[@]} )); then sleep 0.5; fi
        done
        # Clear the hint line and move past it
        echo -en "\n\033[2K\r"

        local any_failed=false
        for spec in "${specialists[@]}"; do
            if [[ "$(_get_status "$spec")" == "failed" ]]; then
                any_failed=true
            fi
        done

        if $any_failed; then
            log_warn "Some specialists failed — continuing with available results"
        fi

        # Read results (validate each file is a JSON array; fallback to [] if corrupt)
        _safe_read_json() { local f="$1"; jq -e 'type == "array"' "$f" > /dev/null 2>&1 && cat "$f" || echo '[]'; }
        local sec_findings cor_findings perf_findings arch_findings
        sec_findings=$(_safe_read_json "$tmp_dir/security.json")
        cor_findings=$(_safe_read_json "$tmp_dir/correctness.json")
        perf_findings=$(_safe_read_json "$tmp_dir/performance.json")
        arch_findings=$(_safe_read_json "$tmp_dir/architecture.json")

        # Count raw findings
        local raw_count
        raw_count=$(echo "[$sec_findings, $cor_findings, $perf_findings, $arch_findings]" | jq '[.[] | length] | add' 2>/dev/null) || raw_count=0
        log_info "Raw findings from specialists: $raw_count total"

        # ---------------------------------------------------------------
        # Phase 2: Consensus merge
        # ---------------------------------------------------------------
        log_header "Phase 2: Consensus merge (dedup + rank)"

        local consensus_prompt
        consensus_prompt=$(build_consensus_prompt "$sec_findings" "$cor_findings" "$perf_findings" "$arch_findings")

        local consensus_stderr
        consensus_stderr=$(mktemp)

        start_progress "Opus merging $raw_count findings" \
            "deduplicating across specialists..." \
            "ranking by severity and confidence..." \
            "cross-referencing related issues..." \
            "building final report..."

        local -a consensus_allowlist=(--allowedTools Read)
        local consensus_result
        consensus_result=$(invoke_ai \
            --provider "$KYZN_PROVIDER" \
            --contract "consensus_json" \
            --prompt "$consensus_prompt" \
            --model "$(_agent_model consensus)" \
            --budget "$per_agent_budget" \
            --max-turns 10 \
            --timeout "$claude_timeout" \
            --allowlist-arr consensus_allowlist \
            --settings "$KYZN_SETTINGS_JSON" \
            --stderr-file "$consensus_stderr") || {
            stop_progress
            log_warn "Consensus merge failed — using raw concatenated findings"
            # Fallback: just concatenate all findings (sort by severity rank, not string)
            jq -s 'add | sort_by(if .severity == "CRITICAL" then 0 elif .severity == "HIGH" then 1 elif .severity == "MEDIUM" then 2 else 3 end)' \
                "$tmp_dir/security.json" "$tmp_dir/correctness.json" \
                "$tmp_dir/performance.json" "$tmp_dir/architecture.json" \
                > "$findings_file" 2>/dev/null || echo '[]' > "$findings_file"
            rm -f "$consensus_stderr"
        }

        if [[ -n "${consensus_result:-}" ]]; then
            stop_progress
            rm -f "$consensus_stderr"
            local consensus_cost
            consensus_cost=$(echo "$consensus_result" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo "?")
            log_ok "Consensus complete (\$$consensus_cost)"

            local consensus_findings
            consensus_findings=$(extract_findings_from_result "$KYZN_PROVIDER" "$consensus_result")

            # Validate JSON before writing — fallback to raw concatenation on parse error
            if echo "$consensus_findings" | jq -e 'type == "array"' &>/dev/null; then
                echo "$consensus_findings" > "$findings_file"
            else
                log_warn "Consensus returned malformed JSON — using raw concatenated findings"
                jq -s 'add | sort_by(if .severity == "CRITICAL" then 0 elif .severity == "HIGH" then 1 elif .severity == "MEDIUM" then 2 else 3 end)' \
                    "$tmp_dir/security.json" "$tmp_dir/correctness.json" \
                    "$tmp_dir/performance.json" "$tmp_dir/architecture.json" \
                    > "$findings_file" 2>/dev/null || echo '[]' > "$findings_file"
            fi
        fi

        # Clean up temp dir
        rm -rf "$tmp_dir"

        # Total cost is approximate (we can't easily sum parallel costs)
        total_cost="~$(awk -v p="$per_agent_budget" 'BEGIN {printf "%.2f", p * 5}')"
    fi

    # Clear trap variables (cleanup handled below, not by trap on success)
    _analyze_pids=()
    rm -f "$sys_prompt_file" 2>/dev/null; _analyze_sys_prompt=""
    [[ -n "${repo_profile_file:-}" ]] && rm -f "$repo_profile_file" 2>/dev/null
    rm -rf "$measure_dir" 2>/dev/null
    trap - EXIT INT TERM

    # Validate findings file is valid JSON array (guard against malformed consensus output)
    if ! jq -e 'type == "array"' "$findings_file" &>/dev/null; then
        log_warn "Findings file contains invalid JSON — resetting to empty"
        echo '[]' > "$findings_file"
    fi

    local finding_count
    finding_count=$(jq 'length' "$findings_file" 2>/dev/null) || finding_count=0
    log_info "Final findings: $finding_count issues"

    # Write completed history entry
    declare -A _hist_done=([finding_count]="$finding_count" [health_score]="${KYZN_HEALTH_SCORE:-0}")
    write_history "$run_id" "analyze" "completed" _hist_done

    # Generate detailed markdown report (before display, so we can reference the path)
    ensure_kyzn_dirs
    local report_file="$KYZN_REPORTS_DIR/$run_id-analysis.md"
    local report_basename
    report_basename=$(basename "$report_file")
    # Compute severity counts once (shared by generate_detailed_report + display_findings)
    local _sev_counts _sev_c _sev_h _sev_m _sev_l
    _sev_counts=$(jq -r '[
        [.[] | select(.severity == "CRITICAL")] | length,
        [.[] | select(.severity == "HIGH")] | length,
        [.[] | select(.severity == "MEDIUM")] | length,
        [.[] | select(.severity == "LOW")] | length
    ] | @tsv' "$findings_file" 2>/dev/null) || _sev_counts="0	0	0	0"
    IFS=$'\t' read -r _sev_c _sev_h _sev_m _sev_l <<< "$_sev_counts"

    generate_detailed_report "$findings_file" "$report_file" "$run_id" "$profile" "$total_cost" "$finding_count" "$_sev_c" "$_sev_h" "$_sev_m" "$_sev_l"

    # Copy report to project root for easy access (archive stays in .kyzn/)
    local root_report="kyzn-report.md"
    cp "$report_file" "$root_report" || log_warn "Could not copy report to project root"

    echo ""
    log_ok "Full report: ${BOLD}$root_report${RESET}"
    log_dim "  Archive: $report_file"
    log_dim "  JSON:    $findings_file"

    # Display compact findings summary in terminal
    display_findings "$findings_file" "" "$_sev_c" "$_sev_h" "$_sev_m" "$_sev_l"

    # Export if requested
    if [[ -n "$export_path" ]]; then
        cp "$report_file" "$export_path"
        log_ok "Report exported to $export_path"
    fi

    # If no findings, we're done
    if (( finding_count == 0 )); then
        return 0
    fi

    # Fix phase: only runs when --fix flag is set (i.e. 'kyzn fix' or 'kyzn analyze --fix')
    if $fix; then
        run_fix_phase "$findings_file" "$min_severity" "$run_id" "$fix_budget"
    elif ! $auto; then
        echo ""
        echo -e "  ${DIM}To auto-fix these findings:${RESET}"
        echo -e "  ${CYAN}kyzn fix${RESET}"
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Generate detailed markdown report with full descriptions
# ---------------------------------------------------------------------------
generate_detailed_report() {
    local findings_file="$1"
    local report_file="$2"
    local run_id="$3"
    local profile="$4"
    local total_cost="$5"
    local finding_count="$6"
    # Optional pre-computed severity counts (args 7-10) — computed from file if absent
    local critical="${7:-}"
    local high="${8:-}"
    local medium="${9:-}"
    local low="${10:-}"

    if [[ -z "$critical" ]]; then
        critical=$(jq '[.[] | select(.severity == "CRITICAL")] | length' "$findings_file")
        high=$(jq '[.[] | select(.severity == "HIGH")] | length' "$findings_file")
        medium=$(jq '[.[] | select(.severity == "MEDIUM")] | length' "$findings_file")
        low=$(jq '[.[] | select(.severity == "LOW")] | length' "$findings_file")
    fi

    {
        echo "# KyZN Deep Analysis Report"
        echo ""
        echo "**Run ID:** \`$run_id\`"
        echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "**Profile:** $profile"
        echo "**Total Findings:** $finding_count"
        echo ""
        echo "## Summary"
        echo ""
        echo "| Severity | Count |"
        echo "|----------|-------|"
        if (( critical > 0 )); then echo "| CRITICAL | $critical |"; fi
        if (( high > 0 )); then echo "| HIGH | $high |"; fi
        if (( medium > 0 )); then echo "| MEDIUM | $medium |"; fi
        if (( low > 0 )); then echo "| LOW | $low |"; fi
        echo ""

        # Group findings by category and generate markdown in a single jq call
        jq -r '
            group_by(.category)
            | map(
                "## " + (.[0].category | ascii_upcase | gsub("-"; " ")) + "\n\n" +
                (map(
                    "### " + (.id // "?") + " — " + (.title // "?") + "\n\n" +
                    "- **Severity:** " + (.severity // "?") + "\n" +
                    "- **File:** `" + (.file // "?") + ":" + ((.line // "?") | tostring) + "`\n" +
                    "- **Effort:** " + (.effort // "?") + "\n\n" +
                    (if (.description // "") != "" and (.description // "") != "null"
                     then (.description // "") + "\n\n" else "" end) +
                    (if (.fix // "") != "" and (.fix // "") != "null"
                     then "**Suggested fix:** " + (.fix // "") + "\n\n" else "" end) +
                    (if (.fix_plan // "") != "" and (.fix_plan // "") != "null"
                     then "**Fix plan:** " + (.fix_plan // "") + "\n\n" else "" end) +
                    "---\n"
                ) | join("\n"))
              )
            | join("\n\n")
        ' "$findings_file" 2>/dev/null || true

        echo "*Generated by [KyZN](https://github.com/bokiko/KyZN) — multi-agent analysis ($profile profile)*"
        echo ""

        # AI Fix Instructions section
        if (( finding_count > 0 )); then
            echo "## Fix Instructions"
            echo ""
            echo "Paste this entire report into your AI assistant to fix the findings above."
            echo ""
            echo "### Findings to Fix (ordered by severity)"
            echo ""
            echo "| # | ID | Severity | File | Title |"
            echo "|---|-----|----------|------|-------|"

            # Build ranked table from findings sorted by severity (single jq call)
            jq -r '
                def sev_rank: if . == "CRITICAL" then 0 elif . == "HIGH" then 1
                  elif . == "MEDIUM" then 2 else 3 end;
                sort_by(.severity | sev_rank)
                | to_entries
                | map("| " + ((.key + 1) | tostring) + " | " + (.value.id // "?") + " | " +
                    (.value.severity // "?") + " | `" + (.value.file // "?") + ":" +
                    ((.value.line // "?") | tostring) + "` | " + (.value.title // "?") + " |")
                | join("\n")
            ' "$findings_file" 2>/dev/null || true

            echo ""
            echo "### Rules for AI"
            echo ""
            echo "- Fix each issue in the order listed (highest severity first)"
            echo "- Read the file before making changes — verify you're editing the right code"
            echo "- After each fix, ensure the code still compiles/passes tests"
            echo "- If a fix is too risky or you're not confident, skip it and explain why"
            echo "- Do NOT make changes beyond what's listed — no drive-by refactoring"
            echo "- Refer to the detailed finding sections above for full context and suggested fixes"
            echo ""
            echo "### Output Format"
            echo ""
            echo "After fixing, summarize:"
            echo "- Finding ID → what you changed → file and line"
        fi
    } > "$report_file"
}

# ---------------------------------------------------------------------------
# Run the fix phase (Sonnet implements findings) — batched with reflexion
# ---------------------------------------------------------------------------
run_fix_phase() {
    local findings_file="$1"
    local min_severity="$2"
    local run_id="$3"
    local fix_budget="$4"
    local repo_profile="${5:-$KYZN_PROFILE_CACHE}"

    # Concurrency lock (prevents two concurrent analyze-fix runs from corrupting working tree)
    local lockdir="$KYZN_DIR/.improve.lock"
    if ! mkdir "$lockdir" 2>/dev/null; then
        local stale_pid
        stale_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
        if [[ -z "$stale_pid" ]] || ! kill -0 "$stale_pid" 2>/dev/null; then
            rm -rf "$lockdir"
            mkdir "$lockdir" 2>/dev/null || { log_error "Another fix is already running."; return 1; }
        else
            log_error "Another KyZN fix/improve is already running (PID: $stale_pid)."
            return 1
        fi
    fi
    echo $$ > "$lockdir/pid"

    # Cleanup on exit — also calls analyze-phase cleanup to ensure pids/tmpfiles
    # from the preceding analyze phase are cleaned up if interrupted here.
    _kyzn_fix_cleanup() {
        stop_progress 2>/dev/null
        rm -rf "${lockdir:-}" 2>/dev/null
        _kyzn_analyze_cleanup 2>/dev/null || true
        trap - EXIT INT TERM
    }
    trap _kyzn_fix_cleanup EXIT INT TERM

    # Pass the full report to give Claude rich context for fixes
    local report_file="$KYZN_REPORTS_DIR/$run_id-analysis.md"

    # Filter findings by severity
    local min_rank
    case "$min_severity" in
        CRITICAL) min_rank=4 ;;
        HIGH)     min_rank=3 ;;
        MEDIUM)   min_rank=2 ;;
        *)        min_rank=1 ;;
    esac

    local all_selected
    all_selected=$(jq --argjson min "$min_rank" '
        map(
            . + {"_rank": (
                if .severity == "CRITICAL" then 4
                elif .severity == "HIGH" then 3
                elif .severity == "MEDIUM" then 2
                else 1 end
            )}
        )
        | sort_by(-.["_rank"])
        | map(select(._rank >= $min))
        | map(del(._rank))
    ' "$findings_file")

    local total_findings
    total_findings=$(echo "$all_selected" | jq 'length')

    if (( total_findings == 0 )); then
        log_info "No findings at or above $min_severity severity to fix."
        return 0
    fi

    echo ""
    log_header "Fixing issues (min severity: $min_severity, $total_findings findings)"

    # Step 1: Baseline test state — capture pre-existing failures
    log_step "Capturing baseline test state..."
    local baseline_verify_ok=true
    local baseline_failures=""
    if ! verify_build 2>/dev/null; then
        baseline_verify_ok=false
        baseline_failures=$(capture_failing_tests 2>/dev/null) || true
        log_warn "Pre-existing test failures detected (will not block fixes)"
        if [[ -n "$baseline_failures" ]]; then
            echo "$baseline_failures" | while IFS= read -r f; do
                [[ -n "$f" ]] && log_dim "  - $f"
            done
        fi
    else
        log_ok "Baseline tests passing"
    fi

    # Step 2: Create branch (capture base for diff budget tracking)
    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    KYZN_ORIGINAL_BRANCH="$original_branch"
    local branch_base
    branch_base=$(git rev-parse HEAD)
    local run_suffix="${run_id##*-}"
    local branch_name="kyzn/$(date +%Y%m%d)-analyze-fix-${run_suffix}"
    log_step "Creating branch: $branch_name"
    safe_git checkout -b "$branch_name" || {
        log_error "Failed to create branch"
        return 1
    }

    # Step 3: Split findings into severity batches
    local -a severity_tiers=()
    local crit_count high_count med_count low_count
    IFS=$'\t' read -r crit_count high_count med_count low_count <<< "$(echo "$all_selected" | jq -r '[
        ([.[] | select(.severity == "CRITICAL")] | length),
        ([.[] | select(.severity == "HIGH")] | length),
        ([.[] | select(.severity == "MEDIUM")] | length),
        ([.[] | select(.severity == "LOW")] | length)
    ] | @tsv')"

    (( crit_count > 0 )) && severity_tiers+=("CRITICAL")
    (( high_count > 0 )) && severity_tiers+=("HIGH")
    (( med_count > 0 )) && severity_tiers+=("MEDIUM")
    (( low_count > 0 )) && severity_tiers+=("LOW")

    local -a fix_allowlist_arr=()
    build_allowlist fix_allowlist_arr "$KYZN_PROJECT_TYPE"
    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-900}"

    local total_fix_cost=0
    local batches_applied=0
    local batches_failed=0
    local batches_skipped=0
    local -a applied_tiers=()

    # Diff budget: analyze --fix uses a higher limit than improve (more files touched)
    # Config override takes precedence, otherwise 5000 for analyze, hard ceiling 10000
    local diff_limit
    diff_limit=$(config_get '.preferences.analyze_diff_limit' '')
    if [[ -z "$diff_limit" ]]; then
        diff_limit=$(config_get '.preferences.diff_limit' '5000')
        # Ensure analyze default is at least 5000 even if improve's limit is lower
        if [[ "$diff_limit" =~ ^[0-9]+$ ]] && (( diff_limit < 5000 )); then
            diff_limit=5000
        fi
    fi
    # Validate diff_limit is a numeric integer before arithmetic operations
    [[ "$diff_limit" =~ ^[0-9]+$ ]] || { log_warn "Invalid diff_limit '$diff_limit' — using default 5000"; diff_limit=5000; }
    # Hard ceiling
    if (( diff_limit > 10000 )); then diff_limit=10000; fi
    local cumulative_diff=0
    local fix_summaries=""

    # Detect installed packages once (used in fix prompts for dependency awareness)
    local installed_packages=""
    installed_packages=$(detect_installed_packages 2>/dev/null) || true

    # Step 4: Fix each severity tier as a separate batch, commit incrementally
    for tier in "${severity_tiers[@]}"; do
        local tier_findings
        tier_findings=$(echo "$all_selected" | jq --arg sev "$tier" '[.[] | select(.severity == $sev)]')
        local tier_count
        tier_count=$(echo "$tier_findings" | jq 'length')

        # Cap at 10 findings per batch to avoid overwhelming Claude
        if (( tier_count > 10 )); then
            tier_findings=$(echo "$tier_findings" | jq '.[0:10]')
            tier_count=10
            log_warn "Capped $tier batch to 10 findings (had more)"
        fi

        echo ""
        log_step "Batch: $tier ($tier_count issues)"

        # Check diff budget headroom before starting this batch
        if (( cumulative_diff > diff_limit * 80 / 100 )); then
            log_warn "Diff budget ${cumulative_diff}/${diff_limit} lines (>80%) — skipping remaining batches"
            (( batches_skipped++ )) || true
            continue
        fi

        # Budget per batch: proportional to findings count
        local batch_budget
        batch_budget=$(awk -v total="$fix_budget" -v batch="$tier_count" -v all="$total_findings" \
            'BEGIN { b = total * batch / all; if (b < 0.50) b = 0.50; printf "%.2f", b }')

        local fix_prompt
        fix_prompt=$(generate_fix_prompt "$tier_findings" "$report_file" "$baseline_failures" "$installed_packages" "$repo_profile")

        if [[ -z "$fix_prompt" ]]; then
            log_info "No findings for $tier tier."
            continue
        fi

        # Load profile overlay based on dominant finding category
        local dominant_cat
        dominant_cat=$(echo "$tier_findings" | jq -r '
            [.[].category // "unknown"] | group_by(.) | sort_by(-length) | .[0][0] // ""
        ' 2>/dev/null) || true
        local sys_prompt_file
        sys_prompt_file=$(get_system_prompt "$dominant_cat")

        # Snapshot HEAD before batch so we can reset cleanly on failure
        local pre_batch_head
        pre_batch_head=$(git rev-parse HEAD)

        # Execute Claude for this batch
        local fix_stderr
        fix_stderr=$(mktemp)

        start_progress "Sonnet fixing $tier ($tier_count issues)" \
            "reading source files..." \
            "analyzing issue context..." \
            "writing fixes..." \
            "verifying changes..." \
            "checking for side effects..."

        local fix_provider="${KYZN_PROVIDER:-claude}"
        local fix_result
        fix_result=$(invoke_ai \
            --provider "$fix_provider" \
            --contract "free_text" \
            --prompt "$fix_prompt" \
            --model sonnet \
            --budget "$batch_budget" \
            --max-turns 30 \
            --timeout "$claude_timeout" \
            --system-prompt-file "$sys_prompt_file" \
            --allowlist-arr fix_allowlist_arr \
            --settings "$KYZN_SETTINGS_JSON" \
            --stderr-file "$fix_stderr") || {
            stop_progress
            log_error "$tier batch failed — skipping"
            rm -f "$fix_stderr"
            [[ "${sys_prompt_file:-}" != "$KYZN_ROOT/templates/system-prompt.md" ]] && rm -f "${sys_prompt_file:-}" 2>/dev/null
            (( batches_failed++ )) || true
            continue
        }
        stop_progress
        rm -f "$fix_stderr"

        local batch_cost
        batch_cost=$(echo "$fix_result" | jq -r '.total_cost_usd // "0"')
        total_fix_cost=$(awk -v a="$total_fix_cost" -v b="$batch_cost" 'BEGIN { printf "%.2f", a + b }')
        log_ok "$tier fixes applied (cost: \$$batch_cost)"

        # Extract Claude's summary of what was fixed (for PR body)
        local batch_summary
        batch_summary=$(echo "$fix_result" | jq -r '.result // empty' 2>/dev/null) || true
        if [[ -n "$batch_summary" ]]; then
            fix_summaries+="**${tier}:** ${batch_summary}"$'\n\n'
        fi

        # Gate new test files before verification (exclude broken imports)
        KYZN_PYTEST_EXTRA_ARGS=""
        gate_new_test_files 2>/dev/null || true

        # Verify after this batch
        local batch_passed=false
        local first_verify_out
        first_verify_out=$(mktemp)
        if verify_build > "$first_verify_out" 2>&1; then
            cat "$first_verify_out"
            log_ok "Build/tests pass after $tier batch"
            batch_passed=true
            rm -f "$first_verify_out"
        else
            cat "$first_verify_out"
            # Reflexion retry — capture errors, give Claude a second chance
            log_warn "$tier batch broke build — attempting self-repair..."

            # Use saved output from first verify_build run (avoids running tests twice)
            local verify_errors
            verify_errors=$(tail -50 "$first_verify_out")
            rm -f "$first_verify_out"

            local retry_budget
            retry_budget=$(awk -v b="$batch_budget" 'BEGIN { printf "%.2f", b / 2 }')

            local retry_prompt="Your previous fixes for $tier severity issues broke the build/tests.

## Errors (last 50 lines)
${verify_errors}

## What You Were Fixing
\`\`\`json
${tier_findings}
\`\`\`

## Repair Instructions
- Fix ONLY the issues your changes introduced. Do not revert all changes — preserve what works.
- If a test import fails (ModuleNotFoundError), rewrite the test using mocks instead:
  - Python: use unittest.mock (Mock, patch, MagicMock) — do NOT import the missing package
  - Node: use jest.mock()
- Do NOT install new packages or add dependencies.
- If a specific fix is unfixable, revert just that one fix."

            local retry_stderr
            retry_stderr=$(mktemp)

            start_progress "Self-repairing $tier batch" \
                "reading error output..." \
                "identifying broken changes..." \
                "reverting problematic fixes..." \
                "re-testing..."

            local retry_result
            retry_result=$(invoke_ai \
                --provider "$fix_provider" \
                --contract "free_text" \
                --prompt "$retry_prompt" \
                --model sonnet \
                --budget "$retry_budget" \
                --max-turns 20 \
                --timeout "$claude_timeout" \
                --system-prompt-file "$sys_prompt_file" \
                --allowlist-arr fix_allowlist_arr \
                --settings "$KYZN_SETTINGS_JSON" \
                --stderr-file "$retry_stderr") || true
            stop_progress
            rm -f "$retry_stderr"

            if [[ -n "$retry_result" ]]; then
                local retry_cost
                retry_cost=$(echo "$retry_result" | jq -r '.total_cost_usd // "0"')
                total_fix_cost=$(awk -v a="$total_fix_cost" -v b="$retry_cost" 'BEGIN { printf "%.2f", a + b }')
            fi

            if verify_build; then
                log_ok "Self-repair succeeded for $tier batch"
                batch_passed=true
            elif ! $baseline_verify_ok; then
                # Baseline had failures — check if Claude added NEW ones
                local after_failures
                after_failures=$(capture_failing_tests 2>/dev/null) || true
                local new_failures=""
                if [[ -n "$after_failures" ]]; then
                    while IFS= read -r test_name; do
                        [[ -z "$test_name" ]] && continue
                        if ! echo "$baseline_failures" | grep -qF "$test_name"; then
                            new_failures+="$test_name"$'\n'
                        fi
                    done <<< "$after_failures"
                fi

                if [[ -z "${new_failures//[$'\n']/}" ]]; then
                    log_warn "$tier batch: all failures are pre-existing — continuing"
                    batch_passed=true
                fi
            fi
        fi

        if $batch_passed; then
            # Safety: verify we're still on the kyzn branch (Claude may have switched)
            local current_branch
            current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            if [[ "$current_branch" != "$branch_name" ]]; then
                log_warn "Branch switched to '$current_branch' — restoring '$branch_name'"
                if ! safe_git checkout "$branch_name" 2>/dev/null; then
                    # Branch may have been deleted or never created — recreate it
                    if git rev-parse --verify "$branch_name" &>/dev/null; then
                        safe_git checkout "$branch_name" 2>&1 || log_error "Failed to restore branch $branch_name"
                    else
                        log_warn "Branch $branch_name lost — recreating from current state"
                        safe_git checkout -b "$branch_name" 2>/dev/null || log_error "Failed to recreate branch $branch_name"
                    fi
                fi
            fi

            # Commit this batch immediately — preserves work even if later batches fail
            stage_claude_changes
            safe_git commit -m "KyZN($tier): fix $tier_count findings [run:$run_id]" 2>/dev/null || true
            (( batches_applied++ )) || true
            applied_tiers+=("$tier")

            # Update cumulative diff tracking (from branch base, not HEAD)
            local _branch_numstat
            _branch_numstat=$(git diff --numstat "$branch_base"...HEAD 2>/dev/null) || true
            if [[ -n "$_branch_numstat" ]]; then
                local _ba _bd
                _ba=$(echo "$_branch_numstat" | awk '{sum+=$1} END {print sum+0}')
                _bd=$(echo "$_branch_numstat" | awk '{sum+=$2} END {print sum+0}')
                cumulative_diff=$(( _ba + _bd ))
            fi
            log_dim "  Diff budget: ${cumulative_diff}/${diff_limit} lines"
        else
            log_error "$tier batch still broken after retry — reverting batch"
            # Save user's local config before cleaning (gitignored, would be lost)
            local _saved_local=""
            [[ -f "$KYZN_DIR/local.yaml" ]] && _saved_local=$(cat "$KYZN_DIR/local.yaml")
            safe_git reset --hard "$pre_batch_head" 2>/dev/null
            # Restore saved files
            if [[ -n "$_saved_local" ]]; then
                mkdir -p "$KYZN_DIR"
                echo "$_saved_local" > "$KYZN_DIR/local.yaml"
            fi
            ensure_kyzn_dirs  # re-create .kyzn/ structure if wiped
            (( batches_failed++ )) || true
        fi

        # Clean up combined prompt file if it was a temp file
        [[ "${sys_prompt_file:-}" != "$KYZN_ROOT/templates/system-prompt.md" ]] && rm -f "$sys_prompt_file" 2>/dev/null
    done

    # Step 5: Check if any batches succeeded
    if (( batches_applied == 0 )); then
        log_error "All fix batches failed. No changes to commit."
        safe_checkout_back
        safe_git branch -D "$branch_name" 2>/dev/null || true
        rm -rf "$lockdir" 2>/dev/null
        return 1
    fi

    # Step 6: Summary
    echo ""
    local diff_stat
    diff_stat=$(git diff --stat "${branch_name}~${batches_applied}..${branch_name}" 2>/dev/null \
        || git diff --stat "main..HEAD" 2>/dev/null \
        || echo "No diff available")

    log_ok "Fix phase complete: $batches_applied batches applied, $batches_failed failed, $batches_skipped skipped"
    log_info "Total cost: \$$total_fix_cost | Diff: $cumulative_diff lines"
    echo "$diff_stat"

    # Step 7: Push and create PR
    # Safety: never push directly to main/master
    local push_branch
    push_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ "$push_branch" == "main" || "$push_branch" == "master" ]]; then
        log_warn "On $push_branch instead of kyzn branch — recovering"
        if git rev-parse --verify "$branch_name" &>/dev/null; then
            safe_git checkout "$branch_name" 2>/dev/null
        else
            # Branch lost — create it from current HEAD (which has the fix commits)
            log_warn "Branch $branch_name lost — creating from current commits"
            safe_git checkout -b "$branch_name" 2>/dev/null || {
                log_error "Cannot create branch $branch_name"
                rm -rf "$lockdir" 2>/dev/null
                return 1
            }
            # Reset main back to before our commits so PR has a clean diff
            local reset_target="HEAD~${batches_applied}"
            safe_git branch -f "$push_branch" "$reset_target" 2>/dev/null || true
        fi
    fi

    log_step "Pushing and creating PR..."
    safe_git push -u origin HEAD 2>/dev/null || {
        log_warn "Push failed — changes are committed locally on $branch_name"
        rm -rf "$lockdir" 2>/dev/null
        return 0
    }

    # Build applied tiers string for PR body
    local tiers_str
    tiers_str=$(printf '%s → ' "${applied_tiers[@]}")
    tiers_str="${tiers_str% → }"  # strip trailing arrow

    local pr_body
    pr_body=$(cat <<EOF
## Analysis Fixes

Applied fixes for findings at severity **$min_severity** and above.

**Run ID:** \`$run_id\`
**Cost:** \$$total_fix_cost
**Batches:** $batches_applied applied ($tiers_str), $batches_failed failed, $batches_skipped skipped
**Diff:** $cumulative_diff lines

### Changes
\`\`\`
$diff_stat
\`\`\`

$(if [[ -n "$fix_summaries" ]]; then
echo "### What Was Fixed"
echo ""
echo "$fix_summaries"
fi)

### Approach
Findings were batched by severity tier (CRITICAL → HIGH → MEDIUM → LOW).
Each batch was verified and committed independently — if a batch broke tests,
self-repair was attempted. Failed batches were reverted to protect passing code.
Diff budget was tracked incrementally to prevent waste.

---
*Generated by [KyZN](https://github.com/bokiko/KyZN) — autonomous code improvement*
EOF
    )

    gh pr create \
        --title "KyZN: fix $(IFS=+; echo "${applied_tiers[*]}") findings ($run_id)" \
        --body "$pr_body" \
        2>/dev/null || log_warn "PR creation failed — push succeeded, create PR manually"

    rm -rf "$lockdir" 2>/dev/null

    echo ""
    log_info "Review the PR, then:"
    echo -e "  ${CYAN}kyzn approve $run_id${RESET}   — sign off"
    echo -e "  ${CYAN}kyzn reject $run_id${RESET}    — discard"
}
