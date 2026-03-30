#!/usr/bin/env bash
# kyzn/lib/execute.sh — Claude Code invocation + safety

# ---------------------------------------------------------------------------
# Module-level constant: generated/dependency directory pattern
# (defined once here; referenced in stage_claude_changes and count_diff_size)
# ---------------------------------------------------------------------------
_KYZN_GENERATED_DIRS='(^|/)(\.(next|nuxt|output|cache|parcel-cache)|node_modules|dist|build|out|__pycache__|\.pytest_cache|target/(debug|release)|vendor)/'

# ---------------------------------------------------------------------------
# Safety: unstage files matching secret patterns (works with actual globs)
# ---------------------------------------------------------------------------
unstage_secrets() {
    local staged_secrets
    staged_secrets=$(git diff --cached --name-only 2>/dev/null | grep -iE '\.(env|pem|key|p12|pfx|jks|p8|tfvars)$|^\.env|credentials|kubeconfig|\.npmrc|\.pypirc|id_rsa|id_ed25519|id_ecdsa|authorized_keys|\.htpasswd|\.docker/config\.json' || true)
    if [[ -n "$staged_secrets" ]]; then
        echo "$staged_secrets" | tr '\n' '\0' | xargs -0 -r git -c core.hooksPath=/dev/null reset HEAD -- 2>/dev/null || true
        log_warn "Unstaged potential secrets from commit:"
        echo "$staged_secrets" | while IFS= read -r f; do
            [[ -n "$f" ]] && log_dim "  - $f"
        done
    fi
}

# ---------------------------------------------------------------------------
# Internal helper: stage Claude's changes excluding KyZN artifacts (shared logic)
# ---------------------------------------------------------------------------
_stage_for_count() {
    # Stage modified tracked files
    safe_git add -u 2>/dev/null

    # Unstage any generated directories that add -u may have picked up
    git diff --cached --name-only 2>/dev/null \
        | grep -E "$_KYZN_GENERATED_DIRS" \
        | tr '\n' '\0' | xargs -0 -r git -c core.hooksPath=/dev/null reset HEAD -- 2>/dev/null || true

    # Stage new files Claude created, excluding KyZN artifacts and generated dirs
    local new_files
    new_files=$(git ls-files --others --exclude-standard 2>/dev/null \
        | grep -vE '^\.kyzn/|^kyzn-report\.md$|^\.claude/' \
        | grep -vE "$_KYZN_GENERATED_DIRS" || true)
    if [[ -n "$new_files" ]]; then
        echo "$new_files" | tr '\n' '\0' | xargs -0 -r git -c core.hooksPath=/dev/null add -- 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Safety: stage only Claude's changes, excluding KyZN artifacts
# ---------------------------------------------------------------------------
stage_claude_changes() {
    _stage_for_count

    # Run safety filters on what's staged
    unstage_secrets
    check_dangerous_files
    check_test_deletions
}

# ---------------------------------------------------------------------------
# Safety: count diff size without permanently staging (excludes KyZN artifacts)
# ---------------------------------------------------------------------------
count_diff_size() {
    local _var_added=$1 _var_deleted=$2 _var_binary=$3

    # Count tracked changes without touching the index (avoids expensive add+reset cycle)
    local numstat
    numstat=$(git diff HEAD --numstat 2>/dev/null | \
        grep -vE "$_KYZN_GENERATED_DIRS" | \
        grep -vE '^\.kyzn/|^kyzn-report\.md$|^\.claude/' || true)

    # Also count new untracked files (excluding KyZN artifacts and generated dirs)
    local new_files_stat
    new_files_stat=$(git ls-files --others --exclude-standard 2>/dev/null \
        | grep -vE '^\.kyzn/|^kyzn-report\.md$|^\.claude/' \
        | grep -vE "$_KYZN_GENERATED_DIRS" \
        | awk '{print "1\t0\t" $0}' || true)

    local combined="${numstat}"$'\n'"${new_files_stat}"

    local added=0 deleted=0 binary=0
    if [[ -n "$combined" ]]; then
        added=$(echo "$combined" | awk '/^[0-9]/ {sum+=$1} END {print sum+0}')
        deleted=$(echo "$combined" | awk '/^[0-9]/ {sum+=$2} END {print sum+0}')
        binary=$(echo "$combined" | grep -c '^-' 2>/dev/null) || true
    fi

    printf -v "$_var_added" '%s' "$added"
    printf -v "$_var_deleted" '%s' "$deleted"
    printf -v "$_var_binary" '%s' "$binary"
}

# ---------------------------------------------------------------------------
# Safety: check for dangerous staged files (CI pipelines, git hooks)
# ---------------------------------------------------------------------------
# Safety: flag and unstage test files with large deletions (>50% removed)
# ---------------------------------------------------------------------------
check_test_deletions() {
    local deleted_tests
    # Find test files where deletions exceed twice the additions (net loss >50%)
    deleted_tests=$(git diff --cached --numstat HEAD 2>/dev/null \
        | awk '$1 != "-" && $2 != "-" { if ($2 > $1 * 2 && $2 > 20 && $3 ~ /test/) print $3 }' || true)
    if [[ -n "$deleted_tests" ]]; then
        log_warn "Large test deletions detected — unstaging to protect test coverage:"
        echo "$deleted_tests" | while IFS= read -r f; do
            [[ -n "$f" ]] && log_dim "  - $f"
        done
        echo "$deleted_tests" | tr '\n' '\0' | xargs -0 -r git -c core.hooksPath=/dev/null reset HEAD -- 2>/dev/null || true
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
            echo "$dangerous" | tr '\n' '\0' | xargs -0 -r git -c core.hooksPath=/dev/null reset HEAD -- 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Safety: enforce hard ceilings on config values
# ---------------------------------------------------------------------------
enforce_config_ceilings() {
    local _var_budget=$1 _var_turns=$2 _var_diff_limit=$3

    # Hard ceilings (cannot be overridden by config)
    local max_budget=25 max_turns=100 max_diff=10000

    local _cur_budget _cur_turns _cur_diff
    _cur_budget="${!_var_budget}"
    _cur_turns="${!_var_turns}"
    _cur_diff="${!_var_diff_limit}"

    if (( $(awk -v b="$_cur_budget" -v m="$max_budget" 'BEGIN {print (b > m) ? 1 : 0}') )); then
        log_warn "Budget $_cur_budget exceeds max ($max_budget). Capping."
        printf -v "$_var_budget" '%s' "$max_budget"
    fi
    if (( $(awk -v b="$_cur_turns" -v m="$max_turns" 'BEGIN {print (b > m) ? 1 : 0}') )); then
        log_warn "Max turns $_cur_turns exceeds max ($max_turns). Capping."
        printf -v "$_var_turns" '%s' "$max_turns"
    fi
    if (( $(awk -v b="$_cur_diff" -v m="$max_diff" 'BEGIN {print (b > m) ? 1 : 0}') )); then
        log_warn "Diff limit $_cur_diff exceeds max ($max_diff). Capping."
        printf -v "$_var_diff_limit" '%s' "$max_diff"
    fi
}

# ---------------------------------------------------------------------------
# Safety: return to main/master branch (fallback chain)
# ---------------------------------------------------------------------------
safe_checkout_back() {
    local target="${KYZN_ORIGINAL_BRANCH:-}"
    if [[ -n "$target" ]]; then
        safe_git checkout "$target" 2>/dev/null && return
    fi
    safe_git checkout - 2>/dev/null ||
    safe_git checkout main 2>/dev/null ||
    safe_git checkout master 2>/dev/null ||
    log_warn "Could not return to previous branch — run 'git checkout main' manually"
}

# ---------------------------------------------------------------------------
# Safety: detect symlinks that escape the repository root (symlink exfiltration)
# ---------------------------------------------------------------------------
check_symlink_escapes() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0

    local escaping
    escaping=$(find . -type l \
        -not -path './node_modules/*' \
        -not -path './.venv/*' \
        -not -path './vendor/*' \
        -not -path './target/*' \
        -not -path './.git/*' \
        2>/dev/null | while IFS= read -r link; do
        local target
        target=$(readlink -f "$link" 2>/dev/null) || continue
        # Allow symlinks whose resolved target is within the repo root
        if [[ "$target" != "$repo_root"/* && "$target" != "$repo_root" ]]; then
            echo "$link -> $target"
        fi
    done)

    if [[ -n "$escaping" ]]; then
        log_error "Repository contains symlinks pointing outside the repo root:"
        echo "$escaping" | while IFS= read -r line; do
            log_dim "  $line"
        done
        log_error "Aborting: symlinks could bypass disallowedFileGlobs restrictions."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Execute AI provider with safety layers (routes through provider adapter)
# ---------------------------------------------------------------------------
execute_claude() {
    local prompt="$1"
    local system_prompt_file="$2"
    local budget="${3:-2.50}"
    local max_turns="${4:-30}"
    local project_type="${5:-$KYZN_PROJECT_TYPE}"
    local model="${6:-sonnet}"
    local verbose="${7:-false}"
    local provider="${8:-${KYZN_PROVIDER:-claude}}"

    # Build allowlist
    local -a allowlist_arr=()
    build_allowlist allowlist_arr "$project_type"

    # Pre-flight: reject symlinks that escape the repo root (prevents secret exfiltration)
    check_symlink_escapes || return 1

    local provider_name
    provider_name=$(provider_display_name "$provider")
    log_step "Invoking $provider_name (model: $model, budget: \$$budget, max turns: $max_turns)..."

    # Timeout (default 10 minutes)
    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-600}"

    local stderr_file
    stderr_file=$(mktemp)

    local -a invoke_args=(
        --provider "$provider"
        --contract "improve_json"
        --prompt "$prompt"
        --model "$model"
        --budget "$budget"
        --max-turns "$max_turns"
        --timeout "$claude_timeout"
        --system-prompt-file "$system_prompt_file"
        --allowlist-arr allowlist_arr
        --settings "$KYZN_SETTINGS_JSON"
        --stderr-file "$stderr_file"
    )
    [[ "$verbose" == "true" ]] && invoke_args+=(--verbose)

    local result
    result=$(invoke_ai "${invoke_args[@]}") || {
        rm -f "$stderr_file"; return 1
    }

    rm -f "$stderr_file"

    local cost session_id stop_reason
    cost=$(echo "$result" | jq -r '.total_cost_usd // "unknown"')
    session_id=$(echo "$result" | jq -r '.session_id // "none"')
    stop_reason=$(echo "$result" | jq -r '.stop_reason // "unknown"')

    log_ok "$provider_name finished (cost: \$$cost, reason: $stop_reason)"

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

    # Prevent concurrent runs on the same repo (mkdir is atomic and cross-platform)
    ensure_kyzn_dirs
    local lockdir="$KYZN_DIR/.improve.lock"
    if ! mkdir "$lockdir" 2>/dev/null; then
        # Check for stale lock (PID file inside)
        local stale_pid
        stale_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
        if [[ -z "$stale_pid" ]] || ! kill -0 "$stale_pid" 2>/dev/null; then
            # Stale lock — previous run crashed or was interrupted
            log_warn "Removing stale lock from a previous run (PID: ${stale_pid:-unknown})"
            rm -rf "$lockdir"
            # Brief delay before retry to narrow the TOCTOU window
            sleep 0.1
            mkdir "$lockdir" 2>/dev/null || { log_error "Another KyZN improve is already running on this repo."; return 1; }
        else
            log_error "Another KyZN improve is already running on this repo (PID: $stale_pid)."
            log_dim "  If this is wrong, remove the lock: rm -rf $lockdir"
            return 1
        fi
    fi
    echo $$ > "$lockdir/pid"

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
    local provider_from_cli=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)     auto=true; shift ;;
            --provider) [[ $# -ge 2 ]] || { log_error "--provider requires a value"; return 1; }; provider_from_cli="$2"; shift 2 ;;
            --focus)    [[ $# -ge 2 ]] || { log_error "--focus requires a value"; return 1; }; focus="$2"; shift 2 ;;
            --mode)     [[ $# -ge 2 ]] || { log_error "--mode requires a value"; return 1; }; mode="$2"; shift 2 ;;
            --budget)   [[ $# -ge 2 ]] || { log_error "--budget requires a value"; return 1; }; budget="$2"; budget_from_cli=true; shift 2 ;;
            --turns)    [[ $# -ge 2 ]] || { log_error "--turns requires a value"; return 1; }; max_turns="$2"; shift 2 ;;
            --model)    [[ $# -ge 2 ]] || { log_error "--model requires a value"; return 1; }; model="$2"; model_from_cli=true; shift 2 ;;
            --allow-ci) export KYZN_ALLOW_CI=true; shift ;;
            -v|--verbose) verbose=true; shift ;;
            *)          log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Resolve provider (CLI flag > config > default)
    local requested_provider="${provider_from_cli:-$(config_get '.preferences.provider' 'claude')}"
    local KYZN_PROVIDER
    KYZN_PROVIDER=$(resolve_provider "$requested_provider") || return 1
    log_info "Provider: $(provider_display_name "$KYZN_PROVIDER")"

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

    # Validate budget format before processing
    if ! [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "Invalid budget '$budget' — using default 2.50"
        budget="2.50"
    fi

    # Validate max_turns and diff_limit are numeric integers
    [[ "$max_turns" =~ ^[0-9]+$ ]] || { log_warn "Invalid max_turns '$max_turns' — using default 30"; max_turns=30; }
    [[ "$diff_limit" =~ ^[0-9]+$ ]] || { log_warn "Invalid diff_limit '$diff_limit' — using default 2000"; diff_limit=2000; }

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
    local baseline_dir after_dir="" sys_prompt_file=""
    baseline_dir=$(mktemp -d)

    # Cleanup function — handles Ctrl+C, errors, and normal exit
    _kyzn_cleanup() {
        # Mark run as failed if still running
        if [[ -n "${run_id:-}" ]]; then
            local _hist_file="$KYZN_HISTORY_DIR/$run_id.json"
            if [[ -f "$_hist_file" ]]; then
                local _cur_status
                _cur_status=$(jq -r '.status // ""' "$_hist_file" 2>/dev/null) || true
                if [[ "$_cur_status" == "running" ]]; then
                    declare -A _cleanup_hist=([focus]="${focus:-}")
                    write_history "$run_id" "improve" "failed" _cleanup_hist 2>/dev/null || true
                fi
            fi
        fi
        [[ -d "${baseline_dir:-}" ]] && rm -rf "$baseline_dir" 2>/dev/null
        [[ -d "${after_dir:-}" ]] && rm -rf "$after_dir" 2>/dev/null
        [[ -n "${sys_prompt_file:-}" && "$sys_prompt_file" != "$KYZN_ROOT/templates/system-prompt.md" ]] && rm -f "$sys_prompt_file" 2>/dev/null
        # Release lock
        rm -rf "${lockdir:-}" 2>/dev/null
        trap - EXIT INT TERM
    }
    trap _kyzn_cleanup EXIT INT TERM

    run_measurements "$KYZN_PROJECT_TYPE" "$baseline_dir"
    local baseline_file="$KYZN_MEASUREMENTS_FILE"

    # Compute baseline score for history
    compute_health_score "$baseline_file"
    local _baseline_health="${KYZN_HEALTH_SCORE:-0}"

    # Write initial "running" history entry
    declare -A _hist=([health_before]="$_baseline_health" [focus]="$focus")
    write_history "$run_id" "improve" "running" _hist

    display_health_dashboard "$baseline_file"

    # Persist model choice to config (only if chosen interactively, not from CLI override)
    if has_config && ! $model_from_cli; then
        VALUE="$model" yq eval -i '.preferences.model = strenv(VALUE)' "$KYZN_CONFIG"
    fi

    # Step 2: Create branch (use run_id suffix for uniqueness)
    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    KYZN_ORIGINAL_BRANCH="$original_branch"
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

    # Step 4: Execute AI
    execute_claude "$prompt" "$sys_prompt_file" "$budget" "$max_turns" "$KYZN_PROJECT_TYPE" "$model" "$verbose" "$KYZN_PROVIDER" || {
        log_error "Claude execution failed"
        declare -A _hist_fail=([health_before]="$_baseline_health" [focus]="$focus")
        write_history "$run_id" "improve" "failed" _hist_fail
        safe_checkout_back
        safe_git branch -D "$branch_name" 2>/dev/null || true
        return 1
    }

    # Step 5: Check diff size (tracked changes + new untracked files, excludes KyZN artifacts)
    local diff_lines=0 del_lines=0 binary_count=0
    count_diff_size diff_lines del_lines binary_count
    local total_diff=$(( diff_lines + del_lines ))

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

    # Step 6: Verify (with reflexion retry on failure)
    local retried=false
    local verify_errors_file
    verify_errors_file=$(mktemp)

    local verify_out
    verify_out=$(mktemp)

    local verify_rc=0
    verify_build > "$verify_out" 2>&1 || verify_rc=$?
    tail -20 "$verify_out"
    if (( verify_rc == 0 )); then
        log_ok "Build and tests passed!"
        rm -f "$verify_errors_file" "$verify_out"
    else
        # Capture error output from first run (no double verify_build)
        local verify_errors
        verify_errors=$(tail -50 "$verify_out")
        echo "$verify_errors" > "$verify_errors_file"
        rm -f "$verify_out"

        if $baseline_verify_ok && ! $retried; then
            # Baseline was clean, Claude broke it — attempt self-repair (one retry)
            log_warn "Build failed -- attempting self-repair..."
            retried=true

            # Halve the budget for the retry attempt
            local retry_budget
            retry_budget=$(awk -v b="$budget" 'BEGIN { printf "%.2f", b / 2 }')

            # Construct retry prompt with error context + mock guidance
            local retry_prompt
            retry_prompt="Your previous changes broke the build. Here are the errors (last 50 lines):

${verify_errors}

## Repair Instructions
- Fix these issues while preserving your improvements. Do not revert all changes — only fix what is broken.
- If a test import fails (ModuleNotFoundError), rewrite using unittest.mock (Python) or jest.mock (Node).
- Do NOT install new packages or add dependencies."

            # Execute Claude again with error context
            if execute_claude "$retry_prompt" "$sys_prompt_file" "$retry_budget" "$max_turns" "$KYZN_PROJECT_TYPE" "$model" "$verbose" "$KYZN_PROVIDER"; then
                # Re-verify after retry
                if verify_build; then
                    log_ok "Self-repair succeeded -- build and tests pass after retry!"
                    rm -f "$verify_errors_file"
                else
                    log_error "Self-repair failed -- build still broken after retry."
                    rm -f "$verify_errors_file"
                    handle_build_failure "$on_fail" "$run_id" "$branch_name" "$mode" "$focus"
                    return 1
                fi
            else
                log_error "Self-repair failed -- Claude execution error on retry."
                rm -f "$verify_errors_file"
                handle_build_failure "$on_fail" "$run_id" "$branch_name" "$mode" "$focus"
                return 1
            fi
        elif $baseline_verify_ok; then
            # Already retried and still failing
            log_error "Build or tests failed after improvements."
            rm -f "$verify_errors_file"
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
                rm -f "$verify_errors_file"
                handle_build_failure "$on_fail" "$run_id" "$branch_name" "$mode" "$focus"
                return 1
            else
                log_warn "Build/tests still failing, but all failures are pre-existing. Continuing."
            fi
        fi
        rm -f "$verify_errors_file"
    fi

    # Step 7: Re-measure
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
        before_cat=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | if length > 0 then (([.[].score] | add) * 100 / ([.[].max_score] | add)) else empty end' "$baseline_file" 2>/dev/null) || true
        after_cat=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | if length > 0 then (([.[].score] | add) * 100 / ([.[].max_score] | add)) else empty end' "$after_file" 2>/dev/null) || true

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
    if ! generate_report "$run_id" "$baseline_file" "$after_file" "$mode" "$focus" "$baseline_score" "$after_score"; then
        log_warn "Report generation or PR creation had issues — check output above."
    fi

    # Clean up temp dirs (after report generation reads them)
    rm -rf "$baseline_dir" "$after_dir" 2>/dev/null
    # Clean up combined system prompt if it was a temp file
    [[ "$sys_prompt_file" != "$KYZN_ROOT/templates/system-prompt.md" ]] && rm -f "$sys_prompt_file" 2>/dev/null

    # Write completed history entry with scores
    declare -A _hist_done=([health_before]="$baseline_score" [health_after]="$after_score" [focus]="$focus")
    write_history "$run_id" "improve" "completed" _hist_done

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
# KyZN Run Failed: $run_id

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
            stage_claude_changes
            safe_git commit -m "KyZN: attempted improvements (build failed) [$run_id]" 2>/dev/null || true
            safe_git push -u origin HEAD 2>/dev/null || true
            gh pr create --draft \
                --title "KyZN: attempted improvements (build failed)" \
                --body "**WARNING: Build failed after these changes.**\n\nRun ID: $run_id\nCost: \$${KYZN_CLAUDE_COST:-unknown}" \
                2>/dev/null || true
            safe_checkout_back
            if [[ -n "$branch_name" ]]; then safe_git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
    esac
}
