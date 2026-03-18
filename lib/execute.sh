#!/usr/bin/env bash
# kyzn/lib/execute.sh — Claude Code invocation + safety

# ---------------------------------------------------------------------------
# Safety: git wrapper that disables hooks to prevent RCE from malicious repos
# ---------------------------------------------------------------------------
safe_git() {
    git -c core.hooksPath=/dev/null "$@"
}

# ---------------------------------------------------------------------------
# Safety: unstage files matching secret patterns (works with actual globs)
# ---------------------------------------------------------------------------
unstage_secrets() {
    local staged_secrets
    staged_secrets=$(git diff --cached --name-only 2>/dev/null | grep -iE '\.(env|pem|key|p12|pfx|jks)$|^\.env|credentials|kubeconfig|\.npmrc|\.pypirc' || true)
    if [[ -n "$staged_secrets" ]]; then
        echo "$staged_secrets" | xargs -r git reset HEAD -- 2>/dev/null || true
        log_warn "Unstaged potential secrets from commit:"
        echo "$staged_secrets" | while IFS= read -r f; do
            [[ -n "$f" ]] && log_dim "  - $f"
        done
    fi
}

# ---------------------------------------------------------------------------
# Safety: check for dangerous staged files (CI pipelines, git hooks)
# ---------------------------------------------------------------------------
check_dangerous_files() {
    local allow_ci="${KYZN_ALLOW_CI:-false}"
    local dangerous
    dangerous=$(git diff --cached --name-only 2>/dev/null | grep -E '\.github/workflows/|\.git/hooks/|\.gitlab-ci\.yml|Jenkinsfile|\.circleci/' || true)
    if [[ -n "$dangerous" ]]; then
        if [[ "$allow_ci" == "true" ]]; then
            log_warn "Claude created CI/pipeline files (--allow-ci enabled):"
            echo "$dangerous" | while IFS= read -r f; do
                [[ -n "$f" ]] && log_warn "  - $f"
            done
        else
            log_warn "Claude created CI/pipeline files — unstaging (use --allow-ci to override):"
            echo "$dangerous" | while IFS= read -r f; do
                [[ -n "$f" ]] && log_warn "  - $f"
            done
            echo "$dangerous" | xargs -r git reset HEAD -- 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Safety: enforce hard ceilings on config values
# ---------------------------------------------------------------------------
enforce_config_ceilings() {
    local -n _budget=$1 _turns=$2 _diff_limit=$3

    # Hard ceilings (cannot be overridden by config)
    local max_budget=25 max_turns=100 max_diff=10000

    if (( $(echo "$_budget > $max_budget" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "Budget $_budget exceeds max ($max_budget). Capping."
        _budget="$max_budget"
    fi
    if (( _turns > max_turns )); then
        log_warn "Max turns $_turns exceeds max ($max_turns). Capping."
        _turns=$max_turns
    fi
    if (( _diff_limit > max_diff )); then
        log_warn "Diff limit $_diff_limit exceeds max ($max_diff). Capping."
        _diff_limit=$max_diff
    fi
}

# ---------------------------------------------------------------------------
# Safety: return to main/master branch (fallback chain)
# ---------------------------------------------------------------------------
safe_checkout_back() {
    git checkout - 2>/dev/null ||
    git checkout main 2>/dev/null ||
    git checkout master 2>/dev/null ||
    log_warn "Could not return to previous branch — run 'git checkout main' manually"
}

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

    # Sensitive file access restrictions
    local disallowed_globs="~/.ssh/**,~/.aws/**,~/.config/gh/**,~/.gnupg/**,**/.env,**/.env.*,**/*.pem,**/*.key"

    # Timeout (default 10 minutes)
    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-600}"

    # Core invocation (allowlist is intentionally unquoted for word splitting)
    local result
    # shellcheck disable=SC2086
    if $verbose; then
        # Stream condensed progress lines to terminal in real-time
        result=$(timeout "$claude_timeout" claude -p "$prompt" \
            --model "$model" \
            --max-budget-usd "$budget" \
            --max-turns "$max_turns" \
            $allowlist \
            --disallowedFileGlobs "$disallowed_globs" \
            --append-system-prompt-file "$system_prompt_file" \
            --output-format json \
            --no-session-persistence \
            2> >(tee "$stderr_file" | while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local short
                short=$(truncate_str "$line" 100)
                echo -e "  ${DIM}${short}${RESET}" >&2
            done)) || {
            local exit_code=$?
            if (( exit_code == 124 )); then
                log_error "Claude Code timed out after ${claude_timeout}s"
            else
                log_error "Claude Code invocation failed"
            fi
            rm -f "$stderr_file"; return 1
        }
    else
        result=$(timeout "$claude_timeout" claude -p "$prompt" \
            --model "$model" \
            --max-budget-usd "$budget" \
            --max-turns "$max_turns" \
            $allowlist \
            --disallowedFileGlobs "$disallowed_globs" \
            --append-system-prompt-file "$system_prompt_file" \
            --output-format json \
            --no-session-persistence \
            2>"$stderr_file") || {
            local exit_code=$?
            if (( exit_code == 124 )); then
                log_error "Claude Code timed out after ${claude_timeout}s"
            else
                log_error "Claude Code invocation failed"
            fi
            rm -f "$stderr_file"; return 1
        }
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

    # Prevent concurrent runs on the same repo
    ensure_kyzn_dirs
    exec 9>"$KYZN_DIR/.improve.lock"
    if ! flock -n 9; then
        log_error "Another kyzn improve is already running on this repo."
        return 1
    fi

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
            --allow-ci) export KYZN_ALLOW_CI=true; shift ;;
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

    # Enforce hard ceilings (prevents config poisoning)
    enforce_config_ceilings budget max_turns diff_limit

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

    # Cleanup function — handles Ctrl+C, errors, and normal exit
    _kyzn_cleanup() {
        [[ -d "${baseline_dir:-}" ]] && rm -rf "$baseline_dir" 2>/dev/null
        [[ -d "${after_dir:-}" ]] && rm -rf "$after_dir" 2>/dev/null
        [[ -n "${sys_prompt_file:-}" && "$sys_prompt_file" != "$KYZN_ROOT/templates/system-prompt.md" ]] && rm -f "$sys_prompt_file" 2>/dev/null
        # Release flock
        exec 9>&- 2>/dev/null
        trap - EXIT INT TERM
    }
    trap _kyzn_cleanup EXIT INT TERM

    run_measurements "$KYZN_PROJECT_TYPE" "$baseline_dir"
    local baseline_file="$KYZN_MEASUREMENTS_FILE"

    display_health_dashboard "$baseline_file"

    # Persist model choice to config for next run
    if has_config; then
        VALUE="$model" yq eval -i '.preferences.model = strenv(VALUE)' "$KYZN_CONFIG"
    fi

    # Step 2: Create branch (use run_id suffix for uniqueness)
    local run_suffix="${run_id##*-}"
    local safe_focus="${focus//[^a-zA-Z0-9_-]/-}"
    local branch_name="kyzn/$(date +%Y%m%d)-${safe_focus}-${run_suffix}"
    log_step "Creating branch: $branch_name"
    safe_git checkout -b "$branch_name" || {
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
    local baseline_verify_ok=true
    local baseline_failures=""
    if ! verify_build 2>/dev/null; then
        baseline_verify_ok=false
        baseline_failures=$(capture_failing_tests 2>/dev/null) || true
        log_warn "Pre-existing build/test failures detected (will not block improvements)"
        if [[ -n "$baseline_failures" ]]; then
            log_dim "Known failures:"
            echo "$baseline_failures" | while IFS= read -r f; do
                [[ -n "$f" ]] && log_dim "  - $f"
            done
        fi
    fi

    # Step 4: Execute Claude
    execute_claude "$prompt" "$sys_prompt_file" "$budget" "$max_turns" "$KYZN_PROJECT_TYPE" "$model" "$verbose" || {
        log_error "Claude execution failed"
        safe_checkout_back
        safe_git branch -D "$branch_name" 2>/dev/null || true
        return 1
    }

    # Step 5: Check diff size (tracked changes + new untracked files)
    # Stage temporarily to count all changes (tracked + untracked)
    safe_git add -A 2>/dev/null
    local numstat
    numstat=$(git diff --cached --numstat HEAD 2>/dev/null) || true
    git reset HEAD 2>/dev/null || true
    local diff_lines=0 del_lines=0
    if [[ -n "$numstat" ]]; then
        diff_lines=$(echo "$numstat" | awk '{sum+=$1} END {print sum+0}')
        del_lines=$(echo "$numstat" | awk '{sum+=$2} END {print sum+0}')
    fi
    local total_diff=$(( diff_lines + del_lines ))

    # Check for binary files in diff
    local binary_count
    binary_count=$(echo "$numstat" | grep -c '^-' 2>/dev/null) || true
    if (( binary_count > 0 )); then
        log_warn "Claude added $binary_count binary file(s)"
        total_diff=$(( total_diff + binary_count * 500 )) # penalize binaries
    fi

    if (( total_diff > diff_limit )); then
        log_warn "Diff exceeds limit ($total_diff > $diff_limit lines). Aborting."
        safe_checkout_back
        safe_git branch -D "$branch_name" 2>/dev/null || true
        return 1
    fi

    log_info "Changes: +$diff_lines -$del_lines ($total_diff lines)"

    # Step 6: Verify
    if verify_build; then
        log_ok "Build and tests passed!"
    else
        if $baseline_verify_ok; then
            # Baseline was clean, Claude broke it — abort
            log_error "Build or tests failed after improvements."
            handle_build_failure "$on_fail" "$run_id" "$branch_name" "$mode" "$focus"
            return 1
        else
            # Baseline had failures — check if Claude added NEW ones
            local after_failures
            after_failures=$(capture_failing_tests 2>/dev/null) || true

            # Find tests that are in after but not in baseline
            local new_failures=""
            if [[ -n "$after_failures" ]]; then
                while IFS= read -r test_name; do
                    [[ -z "$test_name" ]] && continue
                    if ! echo "$baseline_failures" | grep -qF "$test_name"; then
                        new_failures+="$test_name"$'\n'
                    fi
                done <<< "$after_failures"
            fi

            if [[ -n "${new_failures//[$'\n']/}" ]]; then
                log_error "Claude introduced NEW test failures:"
                echo "$new_failures" | while IFS= read -r f; do
                    [[ -n "$f" ]] && log_error "  - $f"
                done
                handle_build_failure "$on_fail" "$run_id" "$branch_name" "$mode" "$focus"
                return 1
            else
                log_warn "Build/tests still failing, but all failures are pre-existing. Continuing."
            fi
        fi
    fi

    # Step 7: Re-measure
    local after_dir
    after_dir=$(mktemp -d)
    run_measurements "$KYZN_PROJECT_TYPE" "$after_dir"
    local after_file="$KYZN_MEASUREMENTS_FILE"

    # Step 7.5: Score regression gate (capture baseline first, then after)
    compute_health_score "$baseline_file"
    local baseline_score="${KYZN_HEALTH_SCORE:-0}"
    compute_health_score "$after_file"
    local after_score="${KYZN_HEALTH_SCORE:-0}"

    if (( after_score < baseline_score )); then
        log_warn "Score regressed ($baseline_score → $after_score). Aborting."
        # Always discard on regression — never create a PR for worse code
        handle_build_failure "discard" "$run_id" "$branch_name" "$mode" "$focus"
        return 1
    fi

    # Per-category score floor: abort if any category drops > 5 points
    local category_regression=false
    for cat in security testing performance quality documentation; do
        local before_cat after_cat
        before_cat=$(jq -r --arg c "$cat" '[.[] | select(.category == $c) | .score] | if length > 0 then (add * 100 / ([.[]] | length * 10)) else empty end' "$baseline_file" 2>/dev/null) || true
        after_cat=$(jq -r --arg c "$cat" '[.[] | select(.category == $c) | .score] | if length > 0 then (add * 100 / ([.[]] | length * 10)) else empty end' "$after_file" 2>/dev/null) || true

        if [[ -n "$before_cat" && -n "$after_cat" ]]; then
            local b_int="${before_cat%.*}" a_int="${after_cat%.*}"
            b_int="${b_int:-0}"; a_int="${a_int:-0}"
            local drop=$(( b_int - a_int ))
            if (( drop > 5 )); then
                log_warn "Category '$cat' dropped $drop points ($b_int → $a_int)"
                category_regression=true
            fi
        fi
    done

    if $category_regression; then
        log_warn "Per-category score floor breached. Aborting."
        handle_build_failure "discard" "$run_id" "$branch_name" "$mode" "$focus"
        return 1
    fi

    # Step 8: Generate report and create PR
    if ! generate_report "$run_id" "$baseline_file" "$after_file" "$mode" "$focus"; then
        log_warn "Report generation or PR creation had issues — check output above."
    fi

    # Clean up temp dirs (after report generation reads them)
    rm -rf "$baseline_dir" "$after_dir" 2>/dev/null
    # Clean up combined system prompt if it was a temp file
    [[ "$sys_prompt_file" != "$KYZN_ROOT/templates/system-prompt.md" ]] && rm -f "$sys_prompt_file" 2>/dev/null

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
    local fail_mode="${4:-unknown}"
    local fail_focus="${5:-unknown}"

    case "$strategy" in
        report)
            log_info "Writing failure report..."
            ensure_kyzn_dirs
            cat > "$KYZN_REPORTS_DIR/$run_id-failed.md" <<EOF
# kyzn Run Failed: $run_id

**Date:** $(date -u)
**Mode:** $fail_mode
**Focus:** $fail_focus
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
            safe_checkout_back
            if [[ -n "$branch_name" ]]; then safe_git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
        discard)
            log_info "Discarding branch..."
            safe_checkout_back
            if [[ -n "$branch_name" ]]; then safe_git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
        draft-pr)
            log_info "Creating draft PR with failure report..."
            safe_git add -A 2>/dev/null
            unstage_secrets
            check_dangerous_files
            safe_git commit -m "kyzn: attempted improvements (build failed) [$run_id]" 2>/dev/null || true
            git push -u origin HEAD 2>/dev/null || true
            gh pr create --draft \
                --title "kyzn: attempted improvements (build failed)" \
                --body "**WARNING: Build failed after these changes.**\n\nRun ID: $run_id\nCost: \$${KYZN_CLAUDE_COST:-unknown}" \
                2>/dev/null || true
            safe_checkout_back
            if [[ -n "$branch_name" ]]; then safe_git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
    esac
}
