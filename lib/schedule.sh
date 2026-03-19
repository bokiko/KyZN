#!/usr/bin/env bash
# kyzn/lib/schedule.sh — Cron integration

# ---------------------------------------------------------------------------
# Schedule command
# ---------------------------------------------------------------------------
cmd_schedule() {
    local frequency="${1:-}"

    case "$frequency" in
        daily)
            schedule_cron "0 3 * * *" "daily"
            ;;
        weekly)
            schedule_cron "0 3 * * 0" "weekly"
            ;;
        off)
            remove_cron
            ;;
        "")
            log_error "Usage: kyzn schedule daily|weekly|off"
            return 1
            ;;
        *)
            log_error "Unknown frequency: $frequency (use daily, weekly, or off)"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Add a cron entry
# ---------------------------------------------------------------------------
schedule_cron() {
    local cron_expr="$1"
    local label="$2"

    require_git_repo

    local project_dir
    project_dir=$(project_root)
    local kyzn_path
    kyzn_path=$(command -v kyzn 2>/dev/null || echo "$KYZN_ROOT/kyzn")

    local project_tag
    project_tag=$(basename "$project_dir")
    local cron_line="$cron_expr cd \"$project_dir\" && \"$kyzn_path\" improve --auto >> \"$project_dir/.kyzn/reports/cron.log\" 2>&1 # kyzn:${project_tag}:$label"

    # Remove existing kyzn entry for THIS project only, then add new one
    (crontab -l 2>/dev/null | grep -vF "# kyzn:${project_tag}:"; echo "$cron_line") | crontab -

    log_ok "Scheduled $label runs for $(project_name)"
    log_dim "Cron: $cron_expr"
    log_dim "Command: kyzn improve --auto"
    log_info "View schedule with: crontab -l | grep kyzn"
}

# ---------------------------------------------------------------------------
# Remove cron entry
# ---------------------------------------------------------------------------
remove_cron() {
    local project_dir
    project_dir=$(project_root)
    local project_tag
    project_tag=$(basename "$project_dir")

    crontab -l 2>/dev/null | grep -vF "# kyzn:${project_tag}:" | crontab - 2>/dev/null

    log_ok "Removed kyzn schedule for $(project_name)"
}
