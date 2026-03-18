#!/usr/bin/env bash
# kyzn/lib/execute.sh — Claude Code invocation + safety

# ---------------------------------------------------------------------------
# Execute Claude Code with safety layers
# ---------------------------------------------------------------------------
execute_claude() {
    local prompt="$1"
    local system_prompt_file="$2"
    local budget="${3:-2.50}"
    local max_turns="${4:-30}"
    local project_type="${5:-$KYZN_PROJECT_TYPE}"
    local model="${6:-sonnet}"
    local verbose="${7:-false}"

    # Build allowlist
    local allowlist
    allowlist=$(build_allowlist "$project_type")

    log_step "Invoking Claude Code (model: $model, budget: \$$budget, max turns: $max_turns)..."

    local stderr_file
    stderr_file=$(mktemp)

    # Core invocation (allowlist is intentionally unquoted for word splitting)
    local result
    # shellcheck disable=SC2086
    if $verbose; then
        # Stream condensed progress lines to terminal in real-time
        result=$(claude -p "$prompt" \
            --model "$model" \
            --max-budget-usd "$budget" \
            --max-turns "$max_turns" \
            $allowlist \
            --append-system-prompt-file "$system_prompt_file" \
            --output-format json \
            --no-session-persistence \
            2> >(tee "$stderr_file" | while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local short
                short=$(truncate_str "$line" 100)
                echo -e "  ${DIM}${short}${RESET}" >&2
            done)) || { log_error "Claude Code invocation failed"; rm -f "$stderr_file"; return 1; }
    else
        result=$(claude -p "$prompt" \
            --model "$model" \
            --max-budget-usd "$budget" \
            --max-turns "$max_turns" \
            $allowlist \
            --append-system-prompt-file "$system_prompt_file" \
            --output-format json \
            --no-session-persistence \
            2>"$stderr_file") || { log_error "Claude Code invocation failed"; rm -f "$stderr_file"; return 1; }
    fi

    rm -f "$stderr_file"

    # Defensive JSON extraction
    if ! echo "$result" | jq . &>/dev/null; then
        log_error "Claude returned invalid JSON"
        return 1
    fi

    local cost session_id stop_reason
    cost=$(echo "$result" | jq -r '.total_cost_usd // "unknown"')
    session_id=$(echo "$result" | jq -r '.session_id // "none"')
    stop_reason=$(echo "$result" | jq -r '.stop_reason // "unknown"')

    log_ok "Claude finished (cost: \$$cost, reason: $stop_reason)"

    # Store result for later use
    KYZN_CLAUDE_RESULT="$result"
    KYZN_CLAUDE_COST="$cost"
    KYZN_CLAUDE_SESSION="$session_id"
    KYZN_CLAUDE_STOP_REASON="$stop_reason"
}

# ---------------------------------------------------------------------------
# Main improve command
# ---------------------------------------------------------------------------
cmd_improve() {
    require_git_repo

    # Parse args
    local auto=false
    local focus=""
    local mode=""
    local budget=""
    local max_turns=""
    local model=""
    local verbose=false
    local model_from_cli=false
    local budget_from_cli=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)     auto=true; shift ;;
            --focus)    focus="$2"; shift 2 ;;
            --mode)     mode="$2"; shift 2 ;;
            --budget)   budget="$2"; budget_from_cli=true; shift 2 ;;
            --turns)    max_turns="$2"; shift 2 ;;
            --model)    model="$2"; model_from_cli=true; shift 2 ;;
            -v|--verbose) verbose=true; shift ;;
            *)          log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Detect project
    detect_project_type
    detect_project_features
    print_detection

    # Load config or run interview
    if ! has_config && ! $auto; then
        run_interview
    elif ! has_config && $auto; then
        log_error "No config found. Run 'kyzn init' first, or run without --auto."
        return 1
    fi

    # Apply defaults from config
    mode="${mode:-$(config_get '.preferences.mode' 'deep')}"
    model="${model:-$(config_get '.preferences.model' 'sonnet')}"
    budget="${budget:-$(config_get '.preferences.budget' '2.50')}"
    max_turns="${max_turns:-$(config_get '.preferences.max_turns' '30')}"
    local diff_limit
    diff_limit=$(config_get '.preferences.diff_limit' '2000')
    local on_fail
    on_fail=$(config_get '.preferences.on_build_fail' 'report')

    if [[ -z "$focus" ]]; then
        # Get from config or auto-detect
        local config_focus
        config_focus=$(config_get '.focus.priorities[0]' 'auto')
        focus="$config_focus"
    fi

    # Interactive confirmation (skipped in --auto mode)
    if ! $auto; then
        echo ""
        echo -e "${BOLD}Run settings:${RESET}"
        echo -e "  Mode:   ${CYAN}$mode${RESET}"
        echo -e "  Model:  ${CYAN}$model${RESET}"
        echo -e "  Budget: ${CYAN}\$$budget${RESET}"
        echo -e "  Focus:  ${CYAN}$focus${RESET}"
        echo ""

        # Let user adjust model (skip if --model was passed)
        if ! $model_from_cli; then
            local model_choice
            model_choice=$(prompt_choice "Model to use?" \
                "sonnet  — fast, cost-effective (recommended)" \
                "opus    — highest quality, slower" \
                "haiku   — cheapest, basic improvements")

            case "$model_choice" in
                1) model="sonnet" ;;
                2) model="opus" ;;
                3) model="haiku" ;;
            esac
        fi

        # Let user adjust budget (skip if --budget was passed)
        if ! $budget_from_cli; then
            budget=$(prompt_input "Budget per run (USD)" "$budget")
        fi
    fi

    # Generate run ID
    local run_id
    run_id=$(generate_run_id)
    log_info "Run ID: $run_id"

    # Step 1: Baseline measurement
    local baseline_dir
    baseline_dir=$(mktemp -d)
    run_measurements "$KYZN_PROJECT_TYPE" "$baseline_dir"
    local baseline_file="$KYZN_MEASUREMENTS_FILE"

    display_health_dashboard "$baseline_file"

    # Step 2: Create branch (use run_id suffix for uniqueness)
    local run_suffix="${run_id##*-}"
    local branch_name="kyzn/$(date +%Y%m%d)-${focus}-${run_suffix}"
    log_step "Creating branch: $branch_name"
    git checkout -b "$branch_name" 2>/dev/null || {
        log_error "Failed to create branch $branch_name"
        return 1
    }

    # Step 3: Assemble prompt
    local prompt
    prompt=$(assemble_prompt "$baseline_file" "$mode" "$focus" "$KYZN_PROJECT_TYPE")

    local sys_prompt_file
    # Pick profile based on focus
    local profile=""
    case "$focus" in
        security*) profile="security" ;;
        testing*)  profile="testing" ;;
        perf*)     profile="performance" ;;
        quality*)  profile="quality" ;;
        doc*)      profile="documentation" ;;
    esac
    sys_prompt_file=$(get_system_prompt "$profile")

    # Step 3.5: Pre-existing test failure detection
    source "$KYZN_ROOT/lib/verify.sh"
    local baseline_verify_ok=true
    if ! verify_build 2>/dev/null; then
        baseline_verify_ok=false
        log_warn "Pre-existing build/test failures detected (will not block improvements)"
    fi

    # Step 4: Execute Claude
    execute_claude "$prompt" "$sys_prompt_file" "$budget" "$max_turns" "$KYZN_PROJECT_TYPE" "$model" "$verbose" || {
        log_error "Claude execution failed"
        git checkout - 2>/dev/null
        git branch -D "$branch_name" 2>/dev/null || true
        return 1
    }

    # Step 5: Check diff size
    local diff_lines
    diff_lines=$(git diff --stat HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+') || true
    diff_lines="${diff_lines:-0}"
    local del_lines
    del_lines=$(git diff --stat HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+') || true
    del_lines="${del_lines:-0}"
    local total_diff=$(( diff_lines + del_lines ))

    if (( total_diff > diff_limit )); then
        log_warn "Diff exceeds limit ($total_diff > $diff_limit lines). Aborting."
        git checkout - 2>/dev/null
        git branch -D "$branch_name" 2>/dev/null || true
        return 1
    fi

    log_info "Changes: +$diff_lines -$del_lines ($total_diff lines)"

    # Step 6: Verify
    if verify_build; then
        log_ok "Build and tests passed!"
    else
        if $baseline_verify_ok; then
            # New failures introduced by Claude — abort
            log_error "Build or tests failed after improvements."
            handle_build_failure "$on_fail" "$run_id" "$branch_name"
            return 1
        else
            log_warn "Build/tests still failing, but failures are pre-existing. Continuing."
        fi
    fi

    # Step 7: Re-measure
    local after_dir
    after_dir=$(mktemp -d)
    run_measurements "$KYZN_PROJECT_TYPE" "$after_dir"
    local after_file="$KYZN_MEASUREMENTS_FILE"

    # Step 7.5: Score regression gate
    compute_health_score "$after_file"
    local after_score="${KYZN_HEALTH_SCORE:-0}"
    compute_health_score "$baseline_file"
    local baseline_score="${KYZN_HEALTH_SCORE:-0}"

    if (( after_score < baseline_score )); then
        log_warn "Score regressed ($baseline_score → $after_score). Aborting."
        handle_build_failure "$on_fail" "$run_id" "$branch_name"
        return 1
    fi

    # Step 8: Generate report and create PR
    source "$KYZN_ROOT/lib/report.sh"
    generate_report "$run_id" "$baseline_file" "$after_file" "$mode" "$focus"

    log_ok "Improvement cycle complete!"
    log_info "Run 'kyzn approve $run_id' to sign off, or 'kyzn reject $run_id' to discard."
}

# ---------------------------------------------------------------------------
# Handle build failure based on config
# ---------------------------------------------------------------------------
handle_build_failure() {
    local strategy="$1"
    local run_id="$2"
    local branch_name="${3:-}"

    case "$strategy" in
        report)
            log_info "Writing failure report..."
            ensure_kyzn_dirs
            cat > "$KYZN_REPORTS_DIR/$run_id-failed.md" <<EOF
# kyzn Run Failed: $run_id

**Date:** $(date -u)
**Mode:** ${mode:-unknown}
**Focus:** ${focus:-unknown}
**Cost:** \$${KYZN_CLAUDE_COST:-unknown}

## What Happened
Build or tests failed after Claude made changes.

## Changes Made
$(git diff --stat 2>/dev/null || echo "No diff available")

## Next Steps
- Review the changes manually
- Consider running with a more conservative mode
EOF
            log_info "Report saved to $KYZN_REPORTS_DIR/$run_id-failed.md"
            git checkout - 2>/dev/null
            if [[ -n "$branch_name" ]]; then git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
        discard)
            log_info "Discarding branch..."
            git checkout - 2>/dev/null
            if [[ -n "$branch_name" ]]; then git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
        draft-pr)
            log_info "Creating draft PR with failure report..."
            git add -A 2>/dev/null
            git commit -m "kyzn: attempted improvements (build failed) [$run_id]" 2>/dev/null || true
            git push -u origin HEAD 2>/dev/null || true
            gh pr create --draft \
                --title "kyzn: attempted improvements (build failed)" \
                --body "**WARNING: Build failed after these changes.**\n\nRun ID: $run_id\nCost: \$${KYZN_CLAUDE_COST:-unknown}" \
                2>/dev/null || true
            git checkout - 2>/dev/null
            if [[ -n "$branch_name" ]]; then git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
    esac
}
