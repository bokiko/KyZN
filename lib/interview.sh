#!/usr/bin/env bash
# kyzn/lib/interview.sh — Adaptive questionnaire tree

# ---------------------------------------------------------------------------
# Main interview entry point
# ---------------------------------------------------------------------------
run_interview() {
    log_header "kyzn interview — tell me about your goals"

    # Step 1: What to improve
    local approach
    approach=$(prompt_choice "What do you want to improve?" \
        "Everything (let kyzn decide based on measurements)" \
        "I have specific goals")

    local -a priorities=()

    if [[ "$approach" == "1" ]]; then
        log_info "kyzn will measure your project and focus on the weakest area."
        priorities=("auto")
    else
        interview_specific_goals priorities
    fi

    # Step 2: Improvement mode
    local mode
    mode=$(prompt_choice "How aggressive should improvements be?" \
        "Deep — real improvements only (no cosmetic changes)" \
        "Clean — dead weight cleanup (remove unused code, fix naming)" \
        "Full — everything (maximum value per run)")

    case "$mode" in
        1) mode="deep" ;;
        2) mode="clean" ;;
        3) mode="full" ;;
    esac

    # Step 3: Budget
    local budget
    budget=$(prompt_input "Budget per run (USD)" "2.50")

    # Step 4: Build failure behavior
    local on_fail
    on_fail=$(prompt_choice "If the build breaks after improvements, what should kyzn do?" \
        "Write a report explaining what happened (recommended)" \
        "Silently discard the branch" \
        "Create a draft PR so you can see what was attempted")

    case "$on_fail" in
        1) on_fail="report" ;;
        2) on_fail="discard" ;;
        3) on_fail="draft-pr" ;;
    esac

    # Step 5: Trust level
    local trust
    trust=$(prompt_choice "Trust level for auto-merging?" \
        "Guardian — always create PR, always wait for approval (recommended)" \
        "Autopilot — auto-merge if build passes + tests pass + diff < threshold")

    case "$trust" in
        1) trust="guardian" ;;
        2) trust="autopilot" ;;
    esac

    # Step 6: Save config
    save_interview_config "$mode" "$budget" "$on_fail" "$trust" "${priorities[@]}"

    log_ok "Configuration saved to $KYZN_CONFIG"
}

# ---------------------------------------------------------------------------
# Specific goals interview branch
# ---------------------------------------------------------------------------
interview_specific_goals() {
    local _var_priorities=$1

    local area
    area=$(prompt_choice "Which area do you want to focus on?" \
        "Security — fix vulnerabilities, audit dependencies" \
        "Testing — improve coverage, add missing tests" \
        "Performance — optimize hot paths, reduce memory" \
        "Quality — fix bugs, improve error handling, reduce complexity" \
        "Documentation — improve docs, add JSDoc/docstrings" \
        "Multiple areas")

    case "$area" in
        1) eval "$_var_priorities+=(\"security\")"
           interview_security_depth "$_var_priorities"
           ;;
        2) eval "$_var_priorities+=(\"testing\")"
           interview_testing_depth "$_var_priorities"
           ;;
        3) eval "$_var_priorities+=(\"performance\")"
           interview_performance_depth "$_var_priorities"
           ;;
        4) eval "$_var_priorities+=(\"quality\")"
           ;;
        5) eval "$_var_priorities+=(\"documentation\")"
           ;;
        6) interview_multiple_areas "$_var_priorities"
           ;;
    esac
}

# ---------------------------------------------------------------------------
# Sub-interview: security depth
# ---------------------------------------------------------------------------
interview_security_depth() {
    local _var_pri=$1

    local depth
    depth=$(prompt_choice "Security focus?" \
        "Dependency vulnerabilities (npm audit, pip-audit)" \
        "Code vulnerabilities (injection, XSS, auth issues)" \
        "Both" \
        "Let Claude decide")

    case "$depth" in
        1) eval "$_var_pri+=(\"security-deps\")" ;;
        2) eval "$_var_pri+=(\"security-code\")" ;;
        3) eval "$_var_pri+=(\"security-deps\" \"security-code\")" ;;
        4) ;; # already has "security"
    esac
}

# ---------------------------------------------------------------------------
# Sub-interview: testing depth
# ---------------------------------------------------------------------------
interview_testing_depth() {
    local _var_pri=$1

    local depth
    depth=$(prompt_choice "Testing focus?" \
        "Increase coverage (add tests for uncovered code)" \
        "Fix flaky tests" \
        "Add integration/E2E tests" \
        "Let Claude decide")

    case "$depth" in
        1) eval "$_var_pri+=(\"testing-coverage\")" ;;
        2) eval "$_var_pri+=(\"testing-flaky\")" ;;
        3) eval "$_var_pri+=(\"testing-integration\")" ;;
        4) ;; # already has "testing"
    esac
}

# ---------------------------------------------------------------------------
# Sub-interview: performance depth
# ---------------------------------------------------------------------------
interview_performance_depth() {
    local _var_pri=$1

    local depth
    depth=$(prompt_choice "Performance focus?" \
        "Reduce bundle size / startup time" \
        "Optimize hot paths / database queries" \
        "Memory usage / leak detection" \
        "Let Claude decide")

    case "$depth" in
        1) eval "$_var_pri+=(\"perf-bundle\")" ;;
        2) eval "$_var_pri+=(\"perf-hotpath\")" ;;
        3) eval "$_var_pri+=(\"perf-memory\")" ;;
        4) ;; # already has "performance"
    esac
}

# ---------------------------------------------------------------------------
# Sub-interview: multiple areas
# ---------------------------------------------------------------------------
interview_multiple_areas() {
    local _var_pri=$1

    echo -e "\n${BOLD}Select all that apply (space-separated numbers):${RESET}" >&2
    echo -e "  ${CYAN}1)${RESET} Security" >&2
    echo -e "  ${CYAN}2)${RESET} Testing" >&2
    echo -e "  ${CYAN}3)${RESET} Performance" >&2
    echo -e "  ${CYAN}4)${RESET} Quality" >&2
    echo -e "  ${CYAN}5)${RESET} Documentation" >&2
    echo -en "\n${BOLD}Choices${RESET} [1 2 3]: " >&2

    local choices
    read -r choices
    choices="${choices:-1 2 3}"

    for c in $choices; do
        case "$c" in
            1) eval "$_var_pri+=(\"security\")" ;;
            2) eval "$_var_pri+=(\"testing\")" ;;
            3) eval "$_var_pri+=(\"performance\")" ;;
            4) eval "$_var_pri+=(\"quality\")" ;;
            5) eval "$_var_pri+=(\"documentation\")" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Save interview results to config
# ---------------------------------------------------------------------------
save_interview_config() {
    local mode="$1"
    local budget="$2"
    local on_fail="$3"
    local trust="$4"
    shift 4
    local -a priorities=("$@")

    ensure_kyzn_dirs

    # Detect project info
    detect_project_type

    # Build priorities YAML array
    local pri_yaml="["
    local first=true
    for p in "${priorities[@]}"; do
        if $first; then
            pri_yaml+="\"$p\""
            first=false
        else
            pri_yaml+=", \"$p\""
        fi
    done
    pri_yaml+="]"

    # Write config (trust excluded — lives in local.yaml)
    cat > "$KYZN_CONFIG" <<EOF
# kyzn configuration — commit this file
# Generated by: kyzn init
# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)

project:
  name: "$(project_name)"
  type: $KYZN_PROJECT_TYPE

preferences:
  mode: $mode
  model: sonnet
  budget: $budget
  max_turns: 30
  diff_limit: 2000
  on_build_fail: $on_fail

focus:
  priorities: $pri_yaml
EOF

    # Write trust to gitignored local config (prevents config poisoning)
    cat > "$KYZN_LOCAL_CONFIG" <<EOF
# kyzn local config — NOT committed (gitignored)
# Trust level controls auto-merge behavior
trust: $trust
EOF

    # Create .gitignore for kyzn
    setup_kyzn_gitignore
}

# ---------------------------------------------------------------------------
# Setup .gitignore for .kyzn/
# ---------------------------------------------------------------------------
setup_kyzn_gitignore() {
    local gi="$KYZN_DIR/.gitignore"
    cat > "$gi" <<'EOF'
# kyzn — gitignored local data
history/
reports/
local.yaml
EOF
}

# ---------------------------------------------------------------------------
# Init command
# ---------------------------------------------------------------------------
cmd_init() {
    require_git_repo
    log_header "kyzn init — setting up your project"

    # Detect project
    detect_project_type
    detect_project_features
    print_detection
    echo ""

    # Check for missing tooling
    check_missing_tooling

    # Run interview
    run_interview

    echo ""
    log_ok "kyzn is ready! Next steps:"
    echo -e "  ${CYAN}kyzn doctor${RESET}    — verify prerequisites"
    echo -e "  ${CYAN}kyzn measure${RESET}   — see your project health score"
    echo -e "  ${CYAN}kyzn analyze${RESET}   — deep multi-agent code review"
    echo -e "  ${CYAN}kyzn improve${RESET}   — start your first improvement cycle"
}

# ---------------------------------------------------------------------------
# Check for missing tooling and inform user
# ---------------------------------------------------------------------------
check_missing_tooling() {
    local missing=()

    case "$KYZN_PROJECT_TYPE" in
        node)
            has_cmd eslint || missing+=("eslint (linting)")
            has_cmd tsc || missing+=("tsc (type checking)")
            ;;
        python)
            has_cmd ruff || missing+=("ruff (linting)")
            has_cmd mypy || missing+=("mypy (type checking)")
            has_cmd pytest || missing+=("pytest (testing)")
            ;;
        rust)
            # cargo clippy is a subcommand, check differently
            if has_cmd cargo && ! cargo clippy --version &>/dev/null; then
                missing+=("clippy (linting)")
            fi
            ;;
        go)
            has_cmd govulncheck || missing+=("govulncheck (security)")
            ;;
    esac

    if (( ${#missing[@]} > 0 )); then
        log_warn "Some optional tools are not installed:"
        for tool in "${missing[@]}"; do
            log_dim "  - $tool"
        done
        echo -e "  ${DIM}kyzn will skip measurements for missing tools.${RESET}"
        echo ""
    fi
}
