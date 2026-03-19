#!/usr/bin/env bash
# kyzn/lib/analyze.sh — Deep analysis via Opus + fix execution via Sonnet

# ---------------------------------------------------------------------------
# Assemble the analysis prompt for Opus
# ---------------------------------------------------------------------------
assemble_analysis_prompt() {
    local measurements_file="$1"
    local focus="${2:-auto}"
    local project_type="${3:-$KYZN_PROJECT_TYPE}"

    local measurements_json
    measurements_json=$(cat "$measurements_file" 2>/dev/null || echo '[]')

    local focus_instruction=""
    if [[ "$focus" != "auto" ]]; then
        focus_instruction="Focus your analysis primarily on: $focus"
    fi

    cat <<EOF
## Deep Analysis Request

**Project:** $(project_name)
**Type:** $(project_type_name "$project_type")
**Current Health Score:** ${KYZN_HEALTH_SCORE:-0}/100
$focus_instruction

## Measurements

\`\`\`json
$measurements_json
\`\`\`

## Your Task

You are performing a deep code analysis. Read the codebase thoroughly and produce a structured findings report. Do NOT make any changes — only analyze and report.

### What to look for

1. **Bugs** — logic errors, off-by-one, null/undefined access, race conditions, unhandled errors
2. **Security** — injection, auth bypass, secrets in code, unsafe deserialization, path traversal
3. **Architecture** — circular dependencies, god objects, leaky abstractions, missing error boundaries
4. **Performance** — N+1 queries, unbounded loops, memory leaks, missing caching, blocking I/O
5. **Testing gaps** — critical paths without tests, tests that don't assert anything meaningful
6. **Dead code** — unused functions, unreachable branches, stale imports

### How to analyze

1. Start with the entry points and trace through the code
2. Read every file that matters — don't skim
3. For each finding, trace the actual code path to confirm it's real
4. Rate severity: CRITICAL / HIGH / MEDIUM / LOW
5. Provide a concrete fix suggestion for each finding

### Output Format

Return your findings as a JSON array. Each finding must have this structure:

\`\`\`json
[
  {
    "id": "BUG-001",
    "severity": "HIGH",
    "category": "bug",
    "title": "Short description",
    "file": "path/to/file.ts",
    "line": 42,
    "description": "Detailed explanation of the problem",
    "fix": "Concrete description of how to fix it",
    "effort": "small"
  }
]
\`\`\`

Field reference:
- **id**: Unique ID (BUG-001, SEC-001, PERF-001, ARCH-001, TEST-001, DEAD-001)
- **severity**: CRITICAL, HIGH, MEDIUM, LOW
- **category**: bug, security, architecture, performance, testing, dead-code
- **effort**: small (< 10 lines), medium (10-50 lines), large (50+ lines)

### Rules

- Only report findings you can confirm by reading the actual code
- No style complaints, no naming suggestions, no formatting issues
- Every finding must have a concrete file path and fix suggestion
- If you find nothing significant, return an empty array \`[]\`
- Quality over quantity — 5 real bugs beat 50 style nits
EOF
}

# ---------------------------------------------------------------------------
# Parse findings JSON from Claude's response
# ---------------------------------------------------------------------------
extract_findings() {
    local claude_result="$1"

    # Extract the text response from Claude's JSON output
    local text_content
    text_content=$(echo "$claude_result" | jq -r '
        .result // .content // ""
        | if type == "array" then
            map(select(.type == "text") | .text) | join("\n")
          else
            .
          end
    ' 2>/dev/null) || text_content=""

    # Try to find JSON array in the response
    local findings=""

    # First: try the whole text as JSON
    if echo "$text_content" | jq -e 'type == "array"' &>/dev/null; then
        findings="$text_content"
    else
        # Look for JSON array in code blocks or inline
        findings=$(echo "$text_content" | sed -n '/^\[/,/^\]/p' | head -500)
        if ! echo "$findings" | jq -e 'type == "array"' &>/dev/null; then
            # Try extracting from ```json blocks
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

    # Summary by severity
    local critical high medium low
    critical=$(jq '[.[] | select(.severity == "CRITICAL")] | length' "$findings_file")
    high=$(jq '[.[] | select(.severity == "HIGH")] | length' "$findings_file")
    medium=$(jq '[.[] | select(.severity == "MEDIUM")] | length' "$findings_file")
    low=$(jq '[.[] | select(.severity == "LOW")] | length' "$findings_file")

    echo -e "  ${RED}CRITICAL: $critical${RESET}  ${YELLOW}HIGH: $high${RESET}  ${CYAN}MEDIUM: $medium${RESET}  ${DIM}LOW: $low${RESET}"
    echo ""

    # Display each finding
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

        # Color by severity
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

    # Map severity to number for filtering
    local -A sev_rank=(["CRITICAL"]=4 ["HIGH"]=3 ["MEDIUM"]=2 ["LOW"]=1)
    local min_rank="${sev_rank[$min_severity]:-1}"

    # Select findings at or above min severity, up to max
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

The following issues were identified by a deep analysis. Fix each one.

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
# cmd_analyze — Opus deep analysis
# ---------------------------------------------------------------------------
cmd_analyze() {
    require_git_repo

    # Parse args
    local focus=""
    local budget=""
    local fix=false
    local fix_budget=""
    local min_severity="LOW"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --focus)        focus="$2"; shift 2 ;;
            --budget)       budget="$2"; shift 2 ;;
            --fix)          fix=true; shift ;;
            --fix-budget)   fix_budget="$2"; shift 2 ;;
            --min-severity) min_severity="$2"; shift 2 ;;
            *)              log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    budget="${budget:-10.00}"
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

    # Confirm
    echo ""
    echo -e "${BOLD}Analysis settings:${RESET}"
    echo -e "  Model:   ${CYAN}opus${RESET} (deep analysis)"
    echo -e "  Budget:  ${CYAN}\$$budget${RESET}"
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

    # Assemble analysis prompt
    local prompt
    prompt=$(assemble_analysis_prompt "$measurements_file" "${focus:-auto}" "$KYZN_PROJECT_TYPE")

    # Get system prompt (analysis-specific personality for Opus)
    local sys_prompt_file
    sys_prompt_file=$(mktemp)
    cat "$KYZN_ROOT/templates/system-prompt.md" > "$sys_prompt_file"
    echo "" >> "$sys_prompt_file"
    echo "---" >> "$sys_prompt_file"
    echo "" >> "$sys_prompt_file"
    cat "$KYZN_ROOT/templates/analysis-prompt.md" >> "$sys_prompt_file"

    # Execute Opus analysis (read-only — no allowlist needed beyond Read/Glob/Grep)
    log_step "Opus is reading your codebase..."

    local allowlist='--allowedTools Read --allowedTools Edit --allowedTools Write --allowedTools Glob --allowedTools Grep'
    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-900}"
    local settings_json='{"permissions":{"disallowedFileGlobs":["~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key"]}}'

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
                log_error "Claude stderr:"
                head -20 "$stderr_file" | while IFS= read -r line; do
                    log_dim "  $line"
                done
            fi
        fi
        rm -f "$stderr_file" "$sys_prompt_file"
        rm -rf "$measure_dir"
        return 1
    }
    rm -f "$stderr_file" "$sys_prompt_file"

    # Parse cost
    local cost
    cost=$(echo "$result" | jq -r '.total_cost_usd // "unknown"')
    log_ok "Analysis complete (cost: \$$cost)"

    # Extract findings
    local findings
    findings=$(extract_findings "$result")

    # Save findings
    local findings_file="$KYZN_REPORTS_DIR/$run_id-findings.json"
    echo "$findings" | jq '.' > "$findings_file" 2>/dev/null || echo '[]' > "$findings_file"

    local finding_count
    finding_count=$(jq 'length' "$findings_file")
    log_info "Found $finding_count issues"

    # Display findings
    display_findings "$findings_file"

    # Save human-readable report
    local report_file="$KYZN_REPORTS_DIR/$run_id-analysis.md"
    {
        echo "# kyzn Deep Analysis Report"
        echo ""
        echo "**Run ID:** $run_id"
        echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "**Model:** opus"
        echo "**Cost:** \$$cost"
        echo "**Findings:** $finding_count"
        echo ""
        echo "## Findings"
        echo ""
        echo '```json'
        jq '.' "$findings_file"
        echo '```'
        echo ""
        echo "---"
        echo "*Generated by [kyzn](https://github.com/bokiko/kyzn) — deep analysis mode*"
    } > "$report_file"

    log_ok "Report saved to $report_file"
    log_ok "Findings saved to $findings_file"

    # Clean up measure dir
    rm -rf "$measure_dir"

    # If --fix, run Sonnet to implement fixes
    if $fix && (( finding_count > 0 )); then
        echo ""
        log_header "Phase 2: Fixing issues with Sonnet"

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

        # Build Sonnet allowlist
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

        # Verify build
        if verify_build; then
            log_ok "Build and tests passed after fixes!"
        else
            log_error "Build/tests failed after fixes."
            handle_build_failure "report" "$run_id" "$branch_name" "analyze" "fix"
            return 1
        fi

        # Check diff
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
        log_info "Total cost: \$$cost (analysis) + \$$fix_cost (fixes)"
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
