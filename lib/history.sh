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
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    log_header "KyZN history"

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

    # Batch: single jq -s call for all entries, sorted by timestamp, output as TSV
    local _hist_tsv
    _hist_tsv=$(cat "$history_dir"/*.json 2>/dev/null | jq -s '
        [.[] | select(. != null and type == "object")]
        | sort_by(.ts // .timestamp // .created_at // "")
        | .[] | [
            (.run_id // "unknown"),
            (.status // "pending"),
            (.health_before // "-" | tostring),
            (.health_after // "-" | tostring),
            (.focus // "-")
          ] | @tsv
    ' -r 2>/dev/null) || true

    while IFS=$'\t' read -r run_id status before after focus; do
        [[ -z "$run_id" ]] && continue

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
    done <<< "$_hist_tsv"

    echo ""
    echo -e "  ${DIM}Tip:${RESET} Run ${CYAN}kyzn diff <run-id>${RESET} to see what a run changed."
    echo ""
}

# ---------------------------------------------------------------------------
# Relative time display (e.g., "2h ago", "3d ago")
# ---------------------------------------------------------------------------
relative_time() {
    local ts="$1"
    [[ -z "$ts" || "$ts" == "null" ]] && { echo "-"; return; }

    local then_epoch now_epoch
    if then_epoch=$(date -d "$ts" +%s 2>/dev/null); then :
    elif then_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null); then :
    else echo "-"; return
    fi

    now_epoch=$(date +%s)
    local diff=$(( now_epoch - then_epoch ))
    if (( diff < 0 )); then diff=0; fi

    if (( diff < 60 )); then echo "just now"
    elif (( diff < 3600 )); then echo "$(( diff / 60 ))m ago"
    elif (( diff < 86400 )); then echo "$(( diff / 3600 ))h ago"
    elif (( diff < 604800 )); then echo "$(( diff / 86400 ))d ago"
    elif (( diff < 2592000 )); then echo "$(( diff / 604800 ))w ago"
    else echo "$(( diff / 2592000 ))mo ago"
    fi
}

# ---------------------------------------------------------------------------
# Machine-wide activity dashboard
# ---------------------------------------------------------------------------
cmd_dashboard() {
    local global_dir="$KYZN_GLOBAL_HISTORY"
    mkdir -p "$global_dir"

    # Check for any JSON files
    local file_count
    file_count=$(find "$global_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l)
    if (( file_count == 0 )); then
        log_info "No KyZN activity found. Run 'kyzn measure' on a project to start."
        return
    fi

    echo -e "${BOLD}KyZN v${KYZN_VERSION}${RESET}"
    echo ""

    # Single jq -s call: extract all entries, handle legacy files
    local dashboard_data
    local _dash_files
    _dash_files=$(find "$global_dir" -maxdepth 1 -name '*.json' ! -name 'tmp.*' -type f 2>/dev/null) || true

    # Filter to non-empty files
    local _valid_files=()
    local _f
    while IFS= read -r _f; do
        [[ -n "$_f" && -s "$_f" ]] && _valid_files+=("$_f")
    done <<< "$_dash_files"

    if (( ${#_valid_files[@]} == 0 )); then
        log_info "No activity data found. Run 'kyzn measure' on a project."
        return
    fi

    dashboard_data=$(cat "${_valid_files[@]}" 2>/dev/null \
        | jq -s '
            [.[] | select(. != null and type == "object")]
            | map(
                # Add project from filename for legacy entries (handled below)
                . + {_ts: (.ts // .timestamp // .created_at // "")}
              )
            | [.[] | select(.project != null and .project != "")]
            | group_by(.project)
            | map(sort_by(._ts) | last | del(._ts))
            | sort_by(.ts // .timestamp // .created_at // "") | reverse
        ' 2>/dev/null) || dashboard_data='[]'

    local count
    count=$(echo "$dashboard_data" | jq 'length')

    # If no entries with project field, try legacy filenames
    if (( count == 0 )); then
        # Legacy files: {project}-{run_id}.json — extract project from filename
        local _legacy_json=""
        for f in "${_valid_files[@]}"; do
            local bn
            bn=$(basename "$f" .json)
            # Extract project name: everything before the run_id pattern (YYYYMMDD-HHMMSS-hex)
            local proj
            proj=$(echo "$bn" | sed 's/-[0-9]\{8\}-[0-9]\{6\}-[0-9a-f]\{8\}$//')
            if [[ "$proj" != "$bn" && -s "$f" ]]; then
                local _entry
                _entry=$(jq --arg p "$proj" '. + {project: $p}' "$f" 2>/dev/null) || true
                if [[ -n "$_entry" ]]; then
                    _legacy_json+="$_entry"$'\n'
                fi
            fi
        done

        if [[ -n "$_legacy_json" ]]; then
            dashboard_data=$(echo "$_legacy_json" | jq -s '
                [.[] | select(. != null)]
                | group_by(.project)
                | map(sort_by(.ts // .timestamp // .created_at // "") | last)
                | sort_by(.ts // .timestamp // .created_at // "") | reverse
            ' 2>/dev/null) || dashboard_data='[]'
        fi

        count=$(echo "$dashboard_data" | jq 'length')
    fi

    if (( count == 0 )); then
        log_info "No activity data found. Run 'kyzn measure' on a project."
        return
    fi

    printf "${BOLD}%-16s %-12s %-10s %s${RESET}\n" "PROJECT" "LAST RUN" "TYPE" "RESULT"
    printf "%-16s %-12s %-10s %s\n" "───────────────" "───────────" "─────────" "──────────────────────"

    # Batch: single jq call → TSV (proj, type, status, ts, hb, ha, fc, hs)
    local _dash_tsv
    _dash_tsv=$(echo "$dashboard_data" | jq -r '.[] | [
        (.project // "-"),
        (.type // "-"),
        (.status // "-"),
        (.ts // .timestamp // .created_at // ""),
        (.health_before // "" | tostring),
        (.health_after // "" | tostring),
        (.finding_count // "" | tostring),
        (.health_score // "" | tostring)
    ] | @tsv' 2>/dev/null) || _dash_tsv=""

    while IFS=$'\t' read -r proj type status ts hb ha fc hs; do
        [[ -z "$proj" || "$proj" == "-" ]] && continue

        local rel
        rel=$(relative_time "$ts")

        # Build result string based on type
        local result
        case "$type" in
            improve)
                if [[ -n "$hb" && -n "$ha" ]]; then
                    local delta=$(( ha - hb ))
                    if (( delta > 0 )); then result="${GREEN}${hb} → ${ha} (+${delta})${RESET}"
                    elif (( delta < 0 )); then result="${RED}${hb} → ${ha} (${delta})${RESET}"
                    else result="${hb} → ${ha} (=)"
                    fi
                else result="$status"
                fi ;;
            analyze)
                if [[ -n "$fc" ]]; then result="${fc} findings"
                else result="$status"
                fi ;;
            measure)
                if [[ -n "$hs" ]]; then result="health ${hs}/100"
                else result="$status"
                fi ;;
            *) result="$status" ;;
        esac

        # Override for running/failed
        case "$status" in
            running) result="${YELLOW}running${RESET}" ;;
            failed)  result="${RED}failed${RESET}" ;;
        esac

        printf "%-16s %-12s %-10s " "$(truncate_str "$proj" 15)" "$rel" "$type"
        echo -e "$result"
    done <<< "$_dash_tsv"

    echo ""
    echo -e "  ${DIM}Run ${CYAN}kyzn history${RESET}${DIM} inside a project for detailed run history.${RESET}"
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

    # Validate run_id (prevent path traversal and injection)
    if ! validate_run_id "$run_id"; then
        log_error "Invalid run ID: $run_id"
        return 1
    fi

    # Try to find the branch (use fixed-string grep to prevent regex injection)
    local branch
    branch=$(git branch -a 2>/dev/null | grep "kyzn/" | grep -F "$run_id" | head -1 | tr -d ' *' | sed 's|^remotes/origin/||') || true

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

    log_header "KyZN status — $(project_name)"

    print_detection
    echo ""

    run_measurements "$KYZN_PROJECT_TYPE"
    display_health_dashboard "$KYZN_MEASUREMENTS_FILE"
    # Clean up temp measurement dir created by run_measurements (if any)
    [[ -d "${KYZN_MEASUREMENTS_DIR:-}" ]] && rm -rf "$KYZN_MEASUREMENTS_DIR" 2>/dev/null || true
    KYZN_MEASUREMENTS_DIR=""

    # Show recent history
    if [[ -d "$KYZN_HISTORY_DIR" ]] && [[ -n "$(ls -A "$KYZN_HISTORY_DIR" 2>/dev/null)" ]]; then
        echo ""
        log_info "Recent runs:"
        local count=0
        # Use reverse sort so most recent (latest date prefix) appears first
        local _hist_file
        while IFS= read -r _hist_file; do
            [[ -f "$_hist_file" ]] || continue
            if (( count >= 5 )); then break; fi

            local run_id status
            run_id=$(jq -r '.run_id // "unknown"' "$_hist_file")
            status=$(jq -r '.status // "pending"' "$_hist_file")
            echo -e "  $run_id  ($status)"
            ((count++)) || true
        done < <(ls -r "$KYZN_HISTORY_DIR"/*.json 2>/dev/null)
    fi
}
