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
    "effort": "small"
  }
]
\`\`\`

- **severity**: CRITICAL, HIGH, MEDIUM, LOW
- **effort**: small (< 10 lines), medium (10-50 lines), large (50+ lines)
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

Return the final deduplicated JSON array in the same format as the inputs.
Only include findings that are real, actionable issues. If reviewers disagree, favor the more specific finding.
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

    local allowlist='--allowedTools Read --allowedTools Glob --allowedTools Grep'
    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-900}"
    local settings_json='{"permissions":{"disallowedFileGlobs":["~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key"]}}'

    local stderr_file
    stderr_file=$(mktemp)

    local result
    # shellcheck disable=SC2086
    result=$(timeout "$claude_timeout" claude -p "$prompt" \
        --model opus \
        --max-budget-usd "$budget" \
        --max-turns 30 \
        $allowlist \
        --settings "$settings_json" \
        --append-system-prompt-file "$sys_prompt_file" \
        --output-format json \
        --no-session-persistence \
        2>"$stderr_file") || {
        local exit_code=$?
        if (( exit_code == 124 )); then
            log_error "[$specialist] timed out"
        else
            log_error "[$specialist] failed (exit code: $exit_code)"
            if [[ -s "$stderr_file" ]]; then
                head -5 "$stderr_file" | while IFS= read -r line; do
                    log_dim "  $line"
                done
            fi
        fi
        rm -f "$stderr_file"
        echo '[]' > "$output_file"
        return 1
    }
    rm -f "$stderr_file"

    # Extract findings and save
    local findings
    findings=$(extract_findings "$result")
    echo "$findings" | jq '.' > "$output_file" 2>/dev/null || echo '[]' > "$output_file"

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
# Display findings in a human-readable format
# ---------------------------------------------------------------------------
display_findings() {
    local findings_file="$1"
    local count
    count=$(jq 'length' "$findings_file")

    if (( count == 0 )); then
        log_ok "No significant issues found."
        return
    fi

    log_header "Analysis Findings ($count issues)"

    local critical high medium low
    critical=$(jq '[.[] | select(.severity == "CRITICAL")] | length' "$findings_file")
    high=$(jq '[.[] | select(.severity == "HIGH")] | length' "$findings_file")
    medium=$(jq '[.[] | select(.severity == "MEDIUM")] | length' "$findings_file")
    low=$(jq '[.[] | select(.severity == "LOW")] | length' "$findings_file")

    echo -e "  ${RED}CRITICAL: $critical${RESET}  ${YELLOW}HIGH: $high${RESET}  ${CYAN}MEDIUM: $medium${RESET}  ${DIM}LOW: $low${RESET}"
    echo ""

    local i=0
    while (( i < count )); do
        local id severity category title file line description fix effort
        id=$(jq -r ".[$i].id // \"F-$((i+1))\"" "$findings_file")
        severity=$(jq -r ".[$i].severity // \"MEDIUM\"" "$findings_file")
        category=$(jq -r ".[$i].category // \"unknown\"" "$findings_file")
        title=$(jq -r ".[$i].title // \"Untitled\"" "$findings_file")
        file=$(jq -r ".[$i].file // \"unknown\"" "$findings_file")
        line=$(jq -r ".[$i].line // \"?\"" "$findings_file")
        description=$(jq -r ".[$i].description // \"\"" "$findings_file")
        fix=$(jq -r ".[$i].fix // \"\"" "$findings_file")
        effort=$(jq -r ".[$i].effort // \"unknown\"" "$findings_file")

        local sev_color="$DIM"
        case "$severity" in
            CRITICAL) sev_color="$RED" ;;
            HIGH)     sev_color="$YELLOW" ;;
            MEDIUM)   sev_color="$CYAN" ;;
        esac

        echo -e "  ${sev_color}[$severity]${RESET} ${BOLD}$id${RESET} — $title"
        echo -e "  ${DIM}$file:$line | $category | effort: $effort${RESET}"
        if [[ -n "$description" && "$description" != "null" ]]; then
            echo -e "  $description"
        fi
        if [[ -n "$fix" && "$fix" != "null" ]]; then
            echo -e "  ${GREEN}Fix:${RESET} $fix"
        fi
        echo ""

        ((i++))
    done
}

# ---------------------------------------------------------------------------
# Generate fix prompt from findings for Sonnet
# ---------------------------------------------------------------------------
generate_fix_prompt() {
    local findings_file="$1"
    local max_findings="${2:-10}"
    local min_severity="${3:-LOW}"

    local -A sev_rank=(["CRITICAL"]=4 ["HIGH"]=3 ["MEDIUM"]=2 ["LOW"]=1)
    local min_rank="${sev_rank[$min_severity]:-1}"

    local selected
    selected=$(jq --argjson min "$min_rank" '
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
        | .[:'"$max_findings"']
        | map(del(._rank))
    ' "$findings_file")

    local count
    count=$(echo "$selected" | jq 'length')

    if (( count == 0 )); then
        echo ""
        return
    fi

    cat <<EOF
## Fix These Issues

The following issues were identified by a multi-agent deep analysis (4 specialized Opus reviewers + consensus). Fix each one.

\`\`\`json
$selected
\`\`\`

## Rules

- Fix each issue in the order listed (highest severity first)
- For each fix, verify you're changing the right code by reading the file first
- After each fix, make sure the code still compiles/passes tests
- If a fix is too risky or you're not confident, skip it and note why
- Do NOT make any changes beyond what's listed here — no drive-by refactoring

## Output

After making changes, summarize what you fixed:
- Finding ID
- What you changed
- File and line
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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --focus)        focus="$2"; shift 2 ;;
            --budget)       budget="$2"; shift 2 ;;
            --fix)          fix=true; shift ;;
            --fix-budget)   fix_budget="$2"; shift 2 ;;
            --min-severity) min_severity="$2"; shift 2 ;;
            --single)       single=true; shift ;;
            *)              log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    budget="${budget:-20.00}"
    fix_budget="${fix_budget:-5.00}"

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

    # Budget split for multi-agent
    local per_agent_budget
    if $single; then
        per_agent_budget="$budget"
    else
        # Split: 4 agents get 20% each, consensus gets 20%
        per_agent_budget=$(echo "scale=2; $budget / 5" | bc)
    fi

    # Confirm
    echo ""
    echo -e "${BOLD}Analysis settings:${RESET}"
    echo -e "  Model:   ${CYAN}opus${RESET} (all sessions)"
    echo -e "  Budget:  ${CYAN}\$$budget${RESET} total"
    if ! $single; then
        echo -e "  Agents:  ${CYAN}4 specialists + consensus${RESET} (\$$per_agent_budget each)"
        echo -e "           security | correctness | performance | architecture"
    fi
    if [[ -n "$focus" ]]; then
        echo -e "  Focus:   ${CYAN}$focus${RESET}"
    fi
    if $fix; then
        echo -e "  Fix:     ${CYAN}yes (sonnet, \$$fix_budget)${RESET}"
    fi
    echo ""

    if ! prompt_yn "Run deep analysis?"; then
        log_info "Cancelled."
        rm -rf "$measure_dir"
        return 0
    fi

    # Generate run ID
    local run_id
    run_id=$(generate_run_id)
    ensure_kyzn_dirs

    local measurements_json
    measurements_json=$(cat "$measurements_file" 2>/dev/null || echo '[]')

    # Build system prompt
    local sys_prompt_file
    sys_prompt_file=$(mktemp)
    cat "$KYZN_ROOT/templates/system-prompt.md" > "$sys_prompt_file"
    echo "" >> "$sys_prompt_file"
    echo "---" >> "$sys_prompt_file"
    echo "" >> "$sys_prompt_file"
    cat "$KYZN_ROOT/templates/analysis-prompt.md" >> "$sys_prompt_file"

    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-900}"
    local settings_json='{"permissions":{"disallowedFileGlobs":["~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key"]}}'
    local total_cost=0

    local findings_file="$KYZN_REPORTS_DIR/$run_id-findings.json"

    if $single || [[ -n "$focus" ]]; then
        # ---------------------------------------------------------------
        # Single-agent mode (--single flag or --focus narrows to one area)
        # ---------------------------------------------------------------
        log_step "Opus is reading your codebase..."

        local prompt
        prompt=$(build_specialist_prompt "${focus:-correctness}" "$(project_name)" \
            "$(project_type_name "$KYZN_PROJECT_TYPE")" "${KYZN_HEALTH_SCORE:-0}" "$measurements_json")

        local allowlist='--allowedTools Read --allowedTools Glob --allowedTools Grep'
        local stderr_file
        stderr_file=$(mktemp)

        local result
        # shellcheck disable=SC2086
        result=$(timeout "$claude_timeout" claude -p "$prompt" \
            --model opus \
            --max-budget-usd "$budget" \
            --max-turns 40 \
            $allowlist \
            --settings "$settings_json" \
            --append-system-prompt-file "$sys_prompt_file" \
            --output-format json \
            --no-session-persistence \
            2>"$stderr_file") || {
            local exit_code=$?
            if (( exit_code == 124 )); then
                log_error "Analysis timed out after ${claude_timeout}s"
            else
                log_error "Analysis failed (exit code: $exit_code)"
                if [[ -s "$stderr_file" ]]; then
                    head -20 "$stderr_file" | while IFS= read -r line; do
                        log_dim "  $line"
                    done
                fi
            fi
            rm -f "$stderr_file" "$sys_prompt_file"
            rm -rf "$measure_dir"
            return 1
        }
        rm -f "$stderr_file"

        total_cost=$(echo "$result" | jq -r '.total_cost_usd // 0')
        log_ok "Analysis complete (cost: \$$total_cost)"

        local findings
        findings=$(extract_findings "$result")
        echo "$findings" | jq '.' > "$findings_file" 2>/dev/null || echo '[]' > "$findings_file"
    else
        # ---------------------------------------------------------------
        # Multi-agent mode (default) — 4 specialists in parallel
        # ---------------------------------------------------------------
        log_header "Phase 1: Dispatching 4 specialist reviewers (parallel)"

        local tmp_dir
        tmp_dir=$(mktemp -d)

        local pids=()
        local specialists=("security" "correctness" "performance" "architecture")

        for spec in "${specialists[@]}"; do
            local spec_prompt
            spec_prompt=$(build_specialist_prompt "$spec" "$(project_name)" \
                "$(project_type_name "$KYZN_PROJECT_TYPE")" "${KYZN_HEALTH_SCORE:-0}" "$measurements_json")

            log_step "Launching $spec reviewer..."
            run_specialist "$spec" "$spec_prompt" "$sys_prompt_file" "$per_agent_budget" "$tmp_dir/${spec}.json" &
            pids+=($!)
        done

        # Wait for all specialists
        local any_failed=false
        for pid in "${pids[@]}"; do
            if ! wait "$pid"; then
                any_failed=true
            fi
        done

        if $any_failed; then
            log_warn "Some specialists failed — continuing with available results"
        fi

        # Read results
        local sec_findings cor_findings perf_findings arch_findings
        sec_findings=$(cat "$tmp_dir/security.json" 2>/dev/null || echo '[]')
        cor_findings=$(cat "$tmp_dir/correctness.json" 2>/dev/null || echo '[]')
        perf_findings=$(cat "$tmp_dir/performance.json" 2>/dev/null || echo '[]')
        arch_findings=$(cat "$tmp_dir/architecture.json" 2>/dev/null || echo '[]')

        # Count raw findings
        local raw_count
        raw_count=$(echo "[$sec_findings, $cor_findings, $perf_findings, $arch_findings]" | jq '[.[] | length] | add')
        log_info "Raw findings from specialists: $raw_count total"

        # ---------------------------------------------------------------
        # Phase 2: Consensus merge
        # ---------------------------------------------------------------
        log_header "Phase 2: Consensus merge (dedup + rank)"

        local consensus_prompt
        consensus_prompt=$(build_consensus_prompt "$sec_findings" "$cor_findings" "$perf_findings" "$arch_findings")

        local consensus_stderr
        consensus_stderr=$(mktemp)

        local consensus_result
        consensus_result=$(timeout "$claude_timeout" claude -p "$consensus_prompt" \
            --model opus \
            --max-budget-usd "$per_agent_budget" \
            --max-turns 10 \
            --output-format json \
            --no-session-persistence \
            2>"$consensus_stderr") || {
            log_warn "Consensus merge failed — using raw concatenated findings"
            # Fallback: just concatenate all findings
            jq -s 'add | sort_by(-.severity)' \
                "$tmp_dir/security.json" "$tmp_dir/correctness.json" \
                "$tmp_dir/performance.json" "$tmp_dir/architecture.json" \
                > "$findings_file" 2>/dev/null || echo '[]' > "$findings_file"
            rm -f "$consensus_stderr"
        }

        if [[ -n "${consensus_result:-}" ]]; then
            rm -f "$consensus_stderr"
            local consensus_cost
            consensus_cost=$(echo "$consensus_result" | jq -r '.total_cost_usd // 0')
            log_ok "Consensus complete (\$$consensus_cost)"

            local consensus_findings
            consensus_findings=$(extract_findings "$consensus_result")
            echo "$consensus_findings" | jq '.' > "$findings_file" 2>/dev/null || echo '[]' > "$findings_file"
        fi

        # Clean up temp dir
        rm -rf "$tmp_dir"

        # Total cost is approximate (we can't easily sum parallel costs)
        total_cost="~$(echo "scale=2; $per_agent_budget * 5" | bc)"
    fi

    rm -f "$sys_prompt_file"
    rm -rf "$measure_dir"

    local finding_count
    finding_count=$(jq 'length' "$findings_file")
    log_info "Final findings: $finding_count issues"

    # Display findings
    display_findings "$findings_file"

    # Save human-readable report
    local report_file="$KYZN_REPORTS_DIR/$run_id-analysis.md"
    {
        echo "# kyzn Deep Analysis Report"
        echo ""
        echo "**Run ID:** $run_id"
        echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "**Model:** opus (multi-agent)"
        echo "**Cost:** \$$total_cost"
        echo "**Findings:** $finding_count"
        if ! $single && [[ -z "$focus" ]]; then
            echo "**Reviewers:** security, correctness, performance, architecture + consensus"
        fi
        echo ""
        echo "## Findings"
        echo ""
        echo '```json'
        jq '.' "$findings_file"
        echo '```'
        echo ""
        echo "---"
        echo "*Generated by [kyzn](https://github.com/bokiko/kyzn) — multi-agent analysis*"
    } > "$report_file"

    log_ok "Report saved to $report_file"
    log_ok "Findings saved to $findings_file"

    # If --fix, run Sonnet to implement fixes
    if $fix && (( finding_count > 0 )); then
        echo ""
        log_header "Phase 3: Fixing issues with Sonnet"

        local fix_prompt
        fix_prompt=$(generate_fix_prompt "$findings_file" 10 "$min_severity")

        if [[ -z "$fix_prompt" ]]; then
            log_info "No findings at or above $min_severity severity to fix."
            return 0
        fi

        # Create branch for fixes
        local run_suffix="${run_id##*-}"
        local branch_name="kyzn/$(date +%Y%m%d)-analyze-fix-${run_suffix}"
        log_step "Creating branch: $branch_name"
        safe_git checkout -b "$branch_name" || {
            log_error "Failed to create branch"
            return 1
        }

        local fix_allowlist
        fix_allowlist=$(build_allowlist "$KYZN_PROJECT_TYPE")

        local fix_stderr
        fix_stderr=$(mktemp)

        local fix_result
        # shellcheck disable=SC2086
        fix_result=$(timeout "$claude_timeout" claude -p "$fix_prompt" \
            --model sonnet \
            --max-budget-usd "$fix_budget" \
            --max-turns 30 \
            $fix_allowlist \
            --settings "$settings_json" \
            --append-system-prompt-file "$KYZN_ROOT/templates/system-prompt.md" \
            --output-format json \
            --no-session-persistence \
            2>"$fix_stderr") || {
            local exit_code=$?
            if (( exit_code == 124 )); then
                log_error "Fix phase timed out"
            else
                log_error "Fix phase failed"
            fi
            rm -f "$fix_stderr"
            safe_checkout_back
            safe_git branch -D "$branch_name" 2>/dev/null || true
            return 1
        }
        rm -f "$fix_stderr"

        local fix_cost
        fix_cost=$(echo "$fix_result" | jq -r '.total_cost_usd // "unknown"')
        log_ok "Fixes applied (cost: \$$fix_cost)"

        if verify_build; then
            log_ok "Build and tests passed after fixes!"
        else
            log_error "Build/tests failed after fixes."
            handle_build_failure "report" "$run_id" "$branch_name" "analyze" "fix"
            return 1
        fi

        safe_git add -A 2>/dev/null
        local diff_stat
        diff_stat=$(git diff --cached --stat HEAD 2>/dev/null || echo "No changes")
        git reset HEAD 2>/dev/null || true

        log_info "Changes applied:"
        echo "$diff_stat"
        echo ""
        log_info "Review the fixes, then:"
        echo -e "  ${CYAN}kyzn approve $run_id${RESET}   — sign off"
        echo -e "  ${CYAN}kyzn reject $run_id${RESET}    — discard"
        echo ""
        log_info "Total cost: \$$total_cost (analysis) + \$$fix_cost (fixes)"
    else
        echo ""
        if (( finding_count > 0 )); then
            log_info "To fix these issues automatically:"
            echo -e "  ${CYAN}kyzn analyze --fix${RESET}"
            echo ""
            log_info "Or use the findings file with improve:"
            echo -e "  ${CYAN}kyzn improve${RESET}  (Sonnet will reference findings)"
        fi
    fi
}
