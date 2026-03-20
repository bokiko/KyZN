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

    # Validate run_id (prevent path traversal and injection)
    if ! validate_run_id "$run_id"; then
        log_error "Invalid run ID: $run_id"
        return 1
    fi

    # Find the report (improve creates $run_id.md, analyze creates $run_id-analysis.md)
    local report="$KYZN_REPORTS_DIR/$run_id.md"
    if [[ ! -f "$report" ]]; then
        report="$KYZN_REPORTS_DIR/$run_id-analysis.md"
    fi
    if [[ ! -f "$report" ]]; then
        log_error "No report found for run $run_id"
        log_info "Run 'kyzn history' to see available runs."
        return 1
    fi

    # Mark as approved in history
    local history_file="$KYZN_HISTORY_DIR/$run_id.json"
    if [[ -f "$history_file" ]]; then
        local updated
        updated=$(jq --arg ts "$(timestamp)" --arg proj "$(project_name)" \
            '.status = "approved" | .approved_at = $ts | .project = $proj' "$history_file")
        echo "$updated" > "$history_file"
    else
        # Create history entry (use jq to avoid JSON injection from run_id)
        jq -n \
            --arg id "$run_id" \
            --arg ts "$(timestamp)" \
            --arg proj "$(project_name)" \
            '{"run_id":$id,"status":"approved","approved_at":$ts,"created_at":$ts,"project":$proj}' \
            > "$history_file"
    fi

    # Also save to global history (use run_id.json for new entries)
    mkdir -p "$KYZN_GLOBAL_HISTORY"
    cp "$history_file" "$KYZN_GLOBAL_HISTORY/$run_id.json"

    log_ok "Run $run_id approved!"
    log_info "Run signed off. Merge the PR when ready."
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

    # Validate run_id (prevent path traversal)
    if ! validate_run_id "$run_id"; then
        log_error "Invalid run ID: $run_id"
        return 1
    fi

    # Mark as rejected in history
    local history_file="$KYZN_HISTORY_DIR/$run_id.json"
    if [[ -f "$history_file" ]]; then
        local updated
        updated=$(jq --arg r "$reason" --arg ts "$(timestamp)" --arg proj "$(project_name)" \
            '.status = "rejected" | .rejected_at = $ts | .rejection_reason = $r | .project = $proj' "$history_file")
        echo "$updated" > "$history_file"
    else
        jq -n \
            --arg id "$run_id" \
            --arg reason "$reason" \
            --arg ts "$(timestamp)" \
            --arg proj "$(project_name)" \
            '{"run_id":$id,"status":"rejected","rejected_at":$ts,"rejection_reason":$reason,"created_at":$ts,"project":$proj}' \
            > "$history_file"
    fi

    # Save to global history (use run_id.json for new entries)
    mkdir -p "$KYZN_GLOBAL_HISTORY"
    cp "$history_file" "$KYZN_GLOBAL_HISTORY/$run_id.json"

    log_ok "Run $run_id rejected."
    if [[ -n "$reason" ]]; then
        log_info "Reason: $reason"
        log_info "Rejection recorded."
    fi
}
