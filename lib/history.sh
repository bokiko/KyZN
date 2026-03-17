#!/usr/bin/env bash
# kyzn/lib/history.sh — History tracking + health score trends

# ---------------------------------------------------------------------------
# Show run history
# ---------------------------------------------------------------------------
cmd_history() {
    local global=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) global=true; shift ;;
            *)        shift ;;
        esac
    done

    log_header "kyzn history"

    local history_dir
    if $global; then
        history_dir="$KYZN_GLOBAL_HISTORY"
        log_info "Showing global history (all projects)"
    else
        require_git_repo
        ensure_kyzn_dirs
        history_dir="$KYZN_HISTORY_DIR"
        log_info "Project: $(project_name)"
    fi

    if [[ ! -d "$history_dir" ]] || [[ -z "$(ls -A "$history_dir" 2>/dev/null)" ]]; then
        log_info "No runs yet. Run 'kyzn improve' to start."
        return
    fi

    # Display table header
    printf "${BOLD}%-22s %-10s %-8s %-8s %s${RESET}\n" "Run ID" "Status" "Before" "After" "Focus"
    echo "─────────────────────────────────────────────────────────────────"

    # List history entries
    for f in "$history_dir"/*.json; do
        [[ -f "$f" ]] || continue

        local run_id status before after focus
        run_id=$(jq -r '.run_id // "unknown"' "$f")
        status=$(jq -r '.status // "pending"' "$f")
        before=$(jq -r '.health_before // "-"' "$f")
        after=$(jq -r '.health_after // "-"' "$f")
        focus=$(jq -r '.focus // "-"' "$f")

        # Color status
        local status_colored
        case "$status" in
            approved) status_colored="${GREEN}approved${RESET}" ;;
            rejected) status_colored="${RED}rejected${RESET}" ;;
            pending)  status_colored="${YELLOW}pending${RESET}" ;;
            failed)   status_colored="${RED}failed${RESET}" ;;
            *)        status_colored="$status" ;;
        esac

        printf "%-22s " "$run_id"
        echo -en "$status_colored"
        printf "%*s" $((10 - ${#status})) ""
        printf "%-8s %-8s %s\n" "$before" "$after" "$focus"
    done

    echo ""
}

# ---------------------------------------------------------------------------
# Show diff for a run
# ---------------------------------------------------------------------------
cmd_diff() {
    local run_id="${1:-}"

    if [[ -z "$run_id" ]]; then
        log_error "Usage: kyzn diff <run-id>"
        return 1
    fi

    # Try to find the branch
    local branch
    branch=$(git branch -a 2>/dev/null | grep "kyzn/" | grep "$run_id" | head -1 | tr -d ' *')

    if [[ -n "$branch" ]]; then
        git diff "main...$branch" 2>/dev/null || git diff "master...$branch" 2>/dev/null
    else
        # Fall back to report
        local report="$KYZN_REPORTS_DIR/$run_id.md"
        if [[ -f "$report" ]]; then
            cat "$report"
        else
            log_error "No diff or report found for run $run_id"
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Status dashboard
# ---------------------------------------------------------------------------
cmd_status() {
    require_git_repo

    # Run a fresh measurement
    detect_project_type
    detect_project_features

    log_header "kyzn status — $(project_name)"

    print_detection
    echo ""

    local results_file
    results_file=$(run_measurements)

    display_health_dashboard "$results_file"

    # Show recent history
    if [[ -d "$KYZN_HISTORY_DIR" ]] && [[ -n "$(ls -A "$KYZN_HISTORY_DIR" 2>/dev/null)" ]]; then
        echo ""
        log_info "Recent runs:"
        local count=0
        for f in "$KYZN_HISTORY_DIR"/*.json; do
            [[ -f "$f" ]] || continue
            (( count >= 5 )) && break

            local run_id status
            run_id=$(jq -r '.run_id // "unknown"' "$f")
            status=$(jq -r '.status // "pending"' "$f")
            echo -e "  $run_id  ($status)"
            ((count++))
        done
    fi
}
