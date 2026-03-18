#!/usr/bin/env bash
# kyzn/lib/approve.sh — Sign-off / rejection handling

# ---------------------------------------------------------------------------
# Approve a run
# ---------------------------------------------------------------------------
cmd_approve() {
    local run_id="${1:-}"

    if [[ -z "$run_id" ]]; then
        log_error "Usage: kyzn approve <run-id>"
        return 1
    fi

    require_git_repo
    ensure_kyzn_dirs

    # Find the report
    local report="$KYZN_REPORTS_DIR/$run_id.md"
    if [[ ! -f "$report" ]]; then
        log_error "No report found for run $run_id"
        log_info "Run 'kyzn history' to see available runs."
        return 1
    fi

    # Mark as approved in history
    local history_file="$KYZN_HISTORY_DIR/$run_id.json"
    if [[ -f "$history_file" ]]; then
        local updated
        updated=$(jq '.status = "approved" | .approved_at = "'"$(timestamp)"'"' "$history_file")
        echo "$updated" > "$history_file"
    else
        # Create history entry (use jq to avoid JSON injection from run_id)
        jq -n \
            --arg id "$run_id" \
            --arg ts "$(timestamp)" \
            '{"run_id":$id,"status":"approved","approved_at":$ts,"created_at":$ts}' \
            > "$history_file"
    fi

    # Also save to global history
    mkdir -p "$KYZN_GLOBAL_HISTORY"
    local project
    project=$(project_name)
    cp "$history_file" "$KYZN_GLOBAL_HISTORY/${project}-${run_id}.json"

    log_ok "Run $run_id approved!"
    log_info "The improvements are part of the project now."
}

# ---------------------------------------------------------------------------
# Reject a run
# ---------------------------------------------------------------------------
cmd_reject() {
    local run_id="${1:-}"
    local reason=""

    if [[ -z "$run_id" ]]; then
        log_error "Usage: kyzn reject <run-id> [-r|--reason \"...\"]"
        return 1
    fi
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--reason) reason="$2"; shift 2 ;;
            *)           reason="$1"; shift ;;
        esac
    done

    require_git_repo
    ensure_kyzn_dirs

    # Mark as rejected in history
    local history_file="$KYZN_HISTORY_DIR/$run_id.json"
    if [[ -f "$history_file" ]]; then
        local updated
        updated=$(jq --arg r "$reason" '.status = "rejected" | .rejected_at = "'"$(timestamp)"'" | .rejection_reason = $r' "$history_file")
        echo "$updated" > "$history_file"
    else
        jq -n \
            --arg id "$run_id" \
            --arg reason "$reason" \
            --arg ts "$(timestamp)" \
            '{"run_id":$id,"status":"rejected","rejected_at":$ts,"rejection_reason":$reason,"created_at":$ts}' \
            > "$history_file"
    fi

    # Save to global history
    mkdir -p "$KYZN_GLOBAL_HISTORY"
    local project
    project=$(project_name)
    cp "$history_file" "$KYZN_GLOBAL_HISTORY/${project}-${run_id}.json"

    log_ok "Run $run_id rejected."
    if [[ -n "$reason" ]]; then
        log_info "Reason: $reason"
        log_info "Rejection recorded."
    fi
}
