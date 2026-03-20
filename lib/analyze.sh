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
    local model="${6:-opus}"

    local allowlist='--allowedTools Read --allowedTools Glob --allowedTools Grep'
    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-900}"
    local settings_json='{"permissions":{"disallowedFileGlobs":["~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key"]}}'

    local stderr_file
    stderr_file=$(mktemp)

    local result
    # shellcheck disable=SC2086
    result=$(timeout "$claude_timeout" claude -p "$prompt" \
        --model "$model" \
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
    local report_path="${2:-kyzn-report.md}"
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

    # Severity counts
    local critical high medium low
    critical=$(jq '[.[] | select(.severity == "CRITICAL")] | length' "$findings_file")
    high=$(jq '[.[] | select(.severity == "HIGH")] | length' "$findings_file")
    medium=$(jq '[.[] | select(.severity == "MEDIUM")] | length' "$findings_file")
    low=$(jq '[.[] | select(.severity == "LOW")] | length' "$findings_file")

    echo ""
    echo -e "  ${BOLD}Analysis Findings${RESET} — $count issues"
    echo ""

    # One-liner per finding — full details are in the report
    local i=0
    while (( i < count )); do
        local id severity title file
        id=$(jq -r ".[$i].id // \"F-$((i+1))\"" "$findings_file")
        severity=$(jq -r ".[$i].severity // \"MEDIUM\"" "$findings_file")
        title=$(jq -r ".[$i].title // \"Untitled\"" "$findings_file")
        file=$(jq -r ".[$i].file // \"unknown\"" "$findings_file")

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

        ((i++)) || true
    done
    echo ""
}

# ---------------------------------------------------------------------------
# Generate fix prompt from findings for Sonnet
# ---------------------------------------------------------------------------
generate_fix_prompt() {
    local findings_file="$1"
    local max_findings="${2:-10}"
    local min_severity="${3:-LOW}"
    local report_file="${4:-}"

    local min_rank
    case "$min_severity" in
        CRITICAL) min_rank=4 ;;
        HIGH)     min_rank=3 ;;
        MEDIUM)   min_rank=2 ;;
        *)        min_rank=1 ;;
    esac

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

    cat <<EOF
## Fix These Issues

The following issues were identified by a multi-agent deep analysis (4 specialized Opus reviewers + consensus). Fix each one.

### Findings to Fix

\`\`\`json
$selected
\`\`\`

${report_context}## Rules

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
    local profile=""
    local export_path=""
    local auto=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --focus)        focus="$2"; shift 2 ;;
            --budget)       budget="$2"; shift 2 ;;
            --fix)          fix=true; shift ;;
            --fix-budget)   fix_budget="$2"; shift 2 ;;
            --min-severity) min_severity="$2"; shift 2 ;;
            --single)       single=true; shift ;;
            --profile)      profile="$2"; shift 2 ;;
            --export)       export_path="$2"; shift 2 ;;
            --auto)         auto=true; shift ;;
            *)              log_error "Unknown option: $1"; return 1 ;;
        esac
    done

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

    local per_agent_budget
    if $single; then
        per_agent_budget="$budget"
    else
        per_agent_budget=$(awk "BEGIN {printf \"%.2f\", $budget / 5}")
    fi

    # Confirm (no dollar amounts shown)
    echo ""
    echo -e "${BOLD}Analysis settings:${RESET}"
    echo -e "  Profile: ${CYAN}$profile${RESET}"
    if ! $single && [[ -z "$focus" ]]; then
        echo -e "  Agents:  ${CYAN}4 specialists + consensus${RESET}"
        echo -e "           security | correctness | performance | architecture"
    elif [[ -n "$focus" ]]; then
        echo -e "  Focus:   ${CYAN}$focus${RESET} (single reviewer)"
    fi
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
        log_step "Opus is reading your codebase... (this may take several minutes)"

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
        # Parallel arrays: pid_specs[i] matches pids[i]
        local pid_specs=()
        # Status tracking: _status_security, _status_correctness, etc.
        local _status_security="running" _status_correctness="running" _status_performance="running" _status_architecture="running"

        # Helper: get/set status for a specialist
        _get_status() { eval "echo \$_status_$1"; }
        _set_status() { printf -v "_status_$1" '%s' "$2"; }

        for spec in "${specialists[@]}"; do
            local spec_prompt
            spec_prompt=$(build_specialist_prompt "$spec" "$(project_name)" \
                "$(project_type_name "$KYZN_PROJECT_TYPE")" "${KYZN_HEALTH_SCORE:-0}" "$measurements_json")

            run_specialist "$spec" "$spec_prompt" "$sys_prompt_file" "$per_agent_budget" "$tmp_dir/${spec}.json" "$(_agent_model "$spec")" &
            local pid=$!
            pids+=($pid)
            pid_specs+=("$spec")
        done

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
            local hint="${phase_hints[$((elapsed / 12 % ${#phase_hints[@]}))]}"
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
        log_step "Opus is merging and ranking findings..."

        local consensus_prompt
        consensus_prompt=$(build_consensus_prompt "$sec_findings" "$cor_findings" "$perf_findings" "$arch_findings")

        local consensus_stderr
        consensus_stderr=$(mktemp)

        local consensus_result
        consensus_result=$(timeout "$claude_timeout" claude -p "$consensus_prompt" \
            --model "$(_agent_model consensus)" \
            --max-budget-usd "$per_agent_budget" \
            --max-turns 10 \
            --output-format json \
            --no-session-persistence \
            2>"$consensus_stderr") || {
            log_warn "Consensus merge failed — using raw concatenated findings"
            # Fallback: just concatenate all findings (sort by severity rank, not string)
            jq -s 'add | sort_by(if .severity == "CRITICAL" then 0 elif .severity == "HIGH" then 1 elif .severity == "MEDIUM" then 2 else 3 end)' \
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
        total_cost="~$(awk "BEGIN {printf \"%.2f\", $per_agent_budget * 5}")"
    fi

    rm -f "$sys_prompt_file"
    rm -rf "$measure_dir"

    local finding_count
    finding_count=$(jq 'length' "$findings_file")
    log_info "Final findings: $finding_count issues"

    # Generate detailed markdown report (before display, so we can reference the path)
    ensure_kyzn_dirs
    local report_file="$KYZN_REPORTS_DIR/$run_id-analysis.md"
    local report_basename
    report_basename=$(basename "$report_file")
    generate_detailed_report "$findings_file" "$report_file" "$run_id" "$profile" "$total_cost" "$finding_count"

    # Copy report to project root for easy access (archive stays in .kyzn/)
    local root_report="kyzn-report.md"
    cp "$report_file" "$root_report" || log_warn "Could not copy report to project root"

    echo ""
    log_ok "Full report: ${BOLD}$root_report${RESET}"
    log_dim "  Archive: $report_file"
    log_dim "  JSON:    $findings_file"

    # Export if requested
    if [[ -n "$export_path" ]]; then
        cp "$report_file" "$export_path"
        log_ok "Report exported to $export_path"
    fi

    # If no findings, we're done
    if (( finding_count == 0 )); then
        return 0
    fi

    # Count by severity for the menu
    local critical high medium low
    critical=$(jq '[.[] | select(.severity == "CRITICAL")] | length' "$findings_file")
    high=$(jq '[.[] | select(.severity == "HIGH")] | length' "$findings_file")
    medium=$(jq '[.[] | select(.severity == "MEDIUM")] | length' "$findings_file")
    low=$(jq '[.[] | select(.severity == "LOW")] | length' "$findings_file")

    # Interactive fix menu (unless --fix or --auto)
    if $fix; then
        # --fix flag: use min_severity from CLI
        run_fix_phase "$findings_file" "$min_severity" "$run_id" "$fix_budget"
    elif ! $auto; then
        echo ""
        log_info "Review the full report: ${BOLD}kyzn-report.md${RESET}"
        echo ""
        local fix_choice
        fix_choice=$(prompt_choice "What would you like to do?" \
            "Done — review kyzn-report.md manually" \
            "Fix critical + high ($((critical + high)) issues)" \
            "Fix all ($finding_count issues)" \
            "Pick severity to fix")

        case "$fix_choice" in
            1)
                echo ""
                echo -e "  ${DIM}Tip: Feed the report to Claude for guided fixes:${RESET}"
                echo -e "  ${CYAN}cat kyzn-report.md | claude${RESET}"
                ;;
            2)
                run_fix_phase "$findings_file" "HIGH" "$run_id" "$fix_budget"
                ;;
            3)
                run_fix_phase "$findings_file" "LOW" "$run_id" "$fix_budget"
                ;;
            4)
                local sev_choice
                sev_choice=$(prompt_choice "Minimum severity to fix?" \
                    "CRITICAL only ($critical issues)" \
                    "HIGH and above ($((critical + high)) issues)" \
                    "MEDIUM and above ($((critical + high + medium)) issues)" \
                    "All including LOW ($finding_count issues)")
                case "$sev_choice" in
                    1) run_fix_phase "$findings_file" "CRITICAL" "$run_id" "$fix_budget" ;;
                    2) run_fix_phase "$findings_file" "HIGH" "$run_id" "$fix_budget" ;;
                    3) run_fix_phase "$findings_file" "MEDIUM" "$run_id" "$fix_budget" ;;
                    4) run_fix_phase "$findings_file" "LOW" "$run_id" "$fix_budget" ;;
                esac
                ;;
        esac
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

    local critical high medium low
    critical=$(jq '[.[] | select(.severity == "CRITICAL")] | length' "$findings_file")
    high=$(jq '[.[] | select(.severity == "HIGH")] | length' "$findings_file")
    medium=$(jq '[.[] | select(.severity == "MEDIUM")] | length' "$findings_file")
    low=$(jq '[.[] | select(.severity == "LOW")] | length' "$findings_file")

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

        # Group findings by category
        local categories
        categories=$(jq -r '[.[].category] | unique | .[]' "$findings_file" 2>/dev/null)

        for cat in $categories; do
            local cat_upper
            cat_upper=$(echo "$cat" | tr '[:lower:]' '[:upper:]' | tr '-' ' ')
            echo "## $cat_upper"
            echo ""

            local cat_count
            cat_count=$(jq --arg c "$cat" '[.[] | select(.category == $c)] | length' "$findings_file")
            local i=0

            while (( i < cat_count )); do
                local id severity title file line description fix effort
                id=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].id // "?"' "$findings_file")
                severity=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].severity // "?"' "$findings_file")
                title=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].title // "?"' "$findings_file")
                file=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].file // "?"' "$findings_file")
                line=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].line // "?"' "$findings_file")
                description=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].description // ""' "$findings_file")
                fix=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].fix // ""' "$findings_file")
                effort=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | .['$i'].effort // "?"' "$findings_file")

                echo "### $id — $title"
                echo ""
                echo "- **Severity:** $severity"
                echo "- **File:** \`$file:$line\`"
                echo "- **Effort:** $effort"
                echo ""
                if [[ -n "$description" && "$description" != "null" ]]; then
                    echo "$description"
                    echo ""
                fi
                if [[ -n "$fix" && "$fix" != "null" ]]; then
                    echo "**Suggested fix:** $fix"
                    echo ""
                fi
                echo "---"
                echo ""

                ((i++)) || true
            done
        done

        echo "*Generated by [KyZN](https://github.com/bokiko/KyZN) — multi-agent analysis ($profile profile)*"
        echo ""

        # AI Fix Instructions section
        if (( finding_count > 0 )); then
            echo "## Fix Instructions"
            echo ""
            echo "Paste this entire report into Claude Code to fix the findings above."
            echo ""
            echo "### Findings to Fix (ordered by severity)"
            echo ""
            echo "| # | ID | Severity | File | Title |"
            echo "|---|-----|----------|------|-------|"

            # Build ranked table from findings sorted by severity
            local fix_num=1
            for sev_level in CRITICAL HIGH MEDIUM LOW; do
                local sev_items
                sev_items=$(jq --arg s "$sev_level" '[.[] | select(.severity == $s)]' "$findings_file")
                local sev_len
                sev_len=$(echo "$sev_items" | jq 'length')
                local si=0
                while (( si < sev_len )); do
                    local fix_id fix_sev fix_file fix_line fix_title
                    fix_id=$(echo "$sev_items" | jq -r ".[$si].id // \"?\"")
                    fix_sev=$(echo "$sev_items" | jq -r ".[$si].severity // \"?\"")
                    fix_file=$(echo "$sev_items" | jq -r ".[$si].file // \"?\"")
                    fix_line=$(echo "$sev_items" | jq -r ".[$si].line // \"?\"")
                    fix_title=$(echo "$sev_items" | jq -r ".[$si].title // \"?\"")
                    echo "| $fix_num | $fix_id | $fix_sev | \`$fix_file:$fix_line\` | $fix_title |"
                    ((fix_num++)) || true
                    ((si++)) || true
                done
            done

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
# Run the fix phase (Sonnet implements findings)
# ---------------------------------------------------------------------------
run_fix_phase() {
    local findings_file="$1"
    local min_severity="$2"
    local run_id="$3"
    local fix_budget="$4"

    # Pass the full report to give Claude rich context for fixes
    local report_file="$KYZN_REPORTS_DIR/$run_id-analysis.md"

    local fix_prompt
    fix_prompt=$(generate_fix_prompt "$findings_file" 10 "$min_severity" "$report_file")

    if [[ -z "$fix_prompt" ]]; then
        log_info "No findings at or above $min_severity severity to fix."
        return 0
    fi

    echo ""
    log_header "Fixing issues (min severity: $min_severity)"

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

    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-900}"
    local settings_json='{"permissions":{"disallowedFileGlobs":["~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key"]}}'

    local fix_stderr
    fix_stderr=$(mktemp)

    log_step "Sonnet is implementing fixes..."

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

    # Commit the fixes
    safe_git add -A 2>/dev/null
    unstage_secrets
    check_dangerous_files
    safe_git commit -m "KyZN: apply analysis fixes ($run_id)" 2>/dev/null || true

    local diff_stat
    diff_stat=$(git diff --stat HEAD~1 HEAD 2>/dev/null || echo "No changes")

    log_info "Changes committed:"
    echo "$diff_stat"
    echo ""
    log_info "Review the fixes, then:"
    echo -e "  ${CYAN}kyzn approve $run_id${RESET}   — sign off"
    echo -e "  ${CYAN}kyzn reject $run_id${RESET}    — discard"
}
