#!/usr/bin/env bash
# kyzn/lib/schedule.sh — Cron integration

# ---------------------------------------------------------------------------
# Schedule command
# ---------------------------------------------------------------------------
cmd_schedule() {
    local frequency="${1:-}"

    case "$frequency" in
        daily|weekly)
            schedule_cron
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
# Scheduled mutation creation is disabled until isolated execution exists
# ---------------------------------------------------------------------------
schedule_cron() {
    log_error "Scheduled mutating runs are disabled until KyZN provides isolated execution."
    log_info "Use 'kyzn schedule off' to remove an existing KyZN schedule."
    return 1
}

# ---------------------------------------------------------------------------
# Remove cron entry
# ---------------------------------------------------------------------------
remove_cron() {
    local project_dir
    project_dir=$(project_root)
    local project_tag
    project_tag=$(basename "$project_dir")

    (crontab -l 2>/dev/null || true) | grep -vF "# kyzn:${project_tag}:" | crontab - 2>/dev/null

    log_ok "Removed KyZN schedule for $(project_name)"
}
