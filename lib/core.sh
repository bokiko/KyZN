#!/usr/bin/env bash
# kyzn/lib/core.sh — Logging, config, colors, utils

# ---------------------------------------------------------------------------
# Colors & formatting
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    DIM='\033[2m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' RESET=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()   { echo -e "${BLUE}ℹ${RESET} $*"; }
log_ok()     { echo -e "${GREEN}✓${RESET} $*"; }
log_warn()   { echo -e "${YELLOW}⚠${RESET} $*"; }
log_error()  { echo -e "${RED}✗${RESET} $*" >&2; }
log_fail()   { echo -e "${RED}✗${RESET} $*"; }
log_dim()    { echo -e "${DIM}  $*${RESET}"; }
log_header() { echo -e "\n${BOLD}${CYAN}$*${RESET}\n"; }
log_step()   { echo -e "${BOLD}→${RESET} $*"; }

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
KYZN_DIR=".kyzn"
KYZN_CONFIG="$KYZN_DIR/config.yaml"
KYZN_LOCAL_CONFIG="$KYZN_DIR/local.yaml"
KYZN_HISTORY_DIR="$KYZN_DIR/history"
KYZN_REPORTS_DIR="$KYZN_DIR/reports"
KYZN_GLOBAL_DIR="${HOME}/.kyzn"
KYZN_GLOBAL_HISTORY="${KYZN_GLOBAL_DIR}/history"
# shellcheck disable=SC2034 # Shared constant consumed by modules loaded after core.sh.
KYZN_PROFILE_CACHE="$KYZN_DIR/repo-profile.md"

# Sensitive file access restrictions (single constant — used by execute.sh + analyze.sh)
# Note: ~ is expanded to $HOME at runtime to ensure Claude Code resolves home directory paths
KYZN_SETTINGS_JSON='{"permissions":{"disallowedFileGlobs":["**/.git/**","~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key","~/.bashrc","~/.bash_profile","~/.zshrc","~/.profile","~/.gitconfig","~/.git-credentials","~/.config/**","~/.claude/**","~/.npmrc","~/.pypirc","~/.docker/**","~/.kube/**","~/.netrc","~/.local/share/**","**/*.tfstate","**/*.tfstate.backup","**/.credentials","/etc/shadow","/etc/passwd","/proc/**","/sys/**","~/.bash_history","~/.zsh_history","~/.python_history","**/.bash_history"]}}'
KYZN_SETTINGS_JSON="${KYZN_SETTINGS_JSON//\~/$HOME}"

# Ensure .kyzn directories exist (restrictive permissions for global dirs)
ensure_kyzn_dirs() {
    mkdir -p "$KYZN_DIR" "$KYZN_HISTORY_DIR" "$KYZN_REPORTS_DIR"
    # shellcheck disable=SC2174 # Restrictive mode is desired on first creation; chmod below fixes pre-existing dirs.
    mkdir -p -m 700 "$KYZN_GLOBAL_DIR" "$KYZN_GLOBAL_HISTORY"
    chmod 700 "$KYZN_GLOBAL_DIR" "$KYZN_GLOBAL_HISTORY" 2>/dev/null || true

    # Always ensure .kyzn/.gitignore exists (protects target repos even without kyzn init)
    local gi="$KYZN_DIR/.gitignore"
    if [[ ! -f "$gi" ]]; then
        cat > "$gi" <<'GITIGNORE'
# kyzn — gitignored local data
history/
reports/
local.yaml
kyzn-report.md
.improve.lock/
repo-profile.md
GITIGNORE
    fi
}

# ---------------------------------------------------------------------------
# Lock management — atomic mkdir-based lock with stale PID detection
# Usage: acquire_kyzn_lock "label"   (label = "improve" or "fix")
#        release_kyzn_lock
# Returns 0 on success, 1 if another process holds the lock.
# Sets KYZN_LOCKDIR for the caller to use in cleanup traps.
# ---------------------------------------------------------------------------
acquire_kyzn_lock() {
    local label="${1:-improve}"
    ensure_kyzn_dirs
    KYZN_LOCKDIR="$KYZN_DIR/.improve.lock"

    if mkdir "$KYZN_LOCKDIR" 2>/dev/null; then
        echo $$ > "$KYZN_LOCKDIR/pid"
        return 0
    fi

    # Lock exists — check for stale PID
    local stale_pid
    stale_pid=$(cat "$KYZN_LOCKDIR/pid" 2>/dev/null || echo "")
    if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
        log_error "Another KyZN $label is already running on this repo (PID: $stale_pid)."
        log_dim "  If this is wrong, remove the lock: rm -rf $KYZN_LOCKDIR"
        return 1
    fi

    # Stale lock — reclaim: remove then mkdir (not fully atomic, but mkdir failure is handled)
    log_warn "Removing stale lock from a previous run (PID: ${stale_pid:-unknown})"
    rm -rf "$KYZN_LOCKDIR"
    if ! mkdir "$KYZN_LOCKDIR" 2>/dev/null; then
        log_error "Another KyZN $label grabbed the lock during recovery."
        return 1
    fi
    echo $$ > "$KYZN_LOCKDIR/pid"
    return 0
}

release_kyzn_lock() {
    rm -rf "${KYZN_LOCKDIR:-}" 2>/dev/null
}

# Validate run ID format (prevent path traversal and injection)
validate_run_id() {
    local run_id="$1"
    if [[ -z "$run_id" ]]; then
        return 1
    fi
    # Reject slashes, .., and anything that doesn't match run ID format
    if [[ "$run_id" == */* || "$run_id" == *..* ]]; then
        return 1
    fi
    # Positive format check: YYYYMMDD-HHMMSS-hex OR measure-YYYYMMDD-HHMMSS OR test-*
    if [[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]] ||
       [[ "$run_id" =~ ^measure-[0-9]{8}-[0-9]{6}$ ]] ||
       [[ "$run_id" =~ ^test-[a-zA-Z0-9_-]+$ ]]; then
        return 0
    fi
    return 1
}

# Check if we're in a git repo
require_git_repo() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        log_error "Not a git repository. Run kyzn from a project root."
        exit 1
    fi
}

# Require a clean working tree before commands that create branches, stage,
# commit, or reset. This protects user edits from being mixed with AI changes.
require_clean_worktree() {
    local allow_dirty="${1:-false}"
    if $allow_dirty; then
        log_warn "--allow-dirty enabled: existing local changes may be mixed with KyZN changes."
        return 0
    fi

    local dirty
    dirty=$(git status --porcelain 2>/dev/null) || dirty=""
    if [[ -n "$dirty" ]]; then
        log_error "Working tree has uncommitted changes. Commit or stash them before running KyZN."
        log_dim "  Use --allow-dirty only if you intentionally want KyZN to run with local changes present."
        log_dim "  Changed files:"
        echo "$dirty" | head -20 | while IFS= read -r line; do
            log_dim "    $line"
        done
        return 1
    fi
    return 0
}

# Check if config exists
has_config() {
    [[ -f "$KYZN_CONFIG" ]]
}

# Read a config value via yq
config_get() {
    local key="$1"
    local default="${2:-}"
    # Validate key is a safe yq dot-notation path (prevent arbitrary expression injection)
    if [[ ! "$key" =~ ^[.a-zA-Z0-9_]+(\[[0-9]+\])?$ ]]; then echo "$default"; return; fi
    if has_config; then
        local val
        val=$(yq eval "$key" "$KYZN_CONFIG" 2>/dev/null)
        if [[ "$val" == "null" || -z "$val" ]]; then
            echo "$default"
        else
            echo "$val"
        fi
    else
        echo "$default"
    fi
}

# Read a value from local (gitignored) config
local_config_get() {
    local key="$1"
    local default="${2:-}"
    # Validate key — same protection as config_get to prevent yq expression injection
    if [[ ! "$key" =~ ^[.a-zA-Z0-9_]+(\[[0-9]+\])?$ ]]; then echo "$default"; return; fi
    if [[ -f "$KYZN_LOCAL_CONFIG" ]]; then
        local val
        val=$(yq eval "$key" "$KYZN_LOCAL_CONFIG" 2>/dev/null)
        if [[ "$val" == "null" || -z "$val" ]]; then
            echo "$default"
        else
            echo "$val"
        fi
    else
        echo "$default"
    fi
}

# Set a config value via yq (always quotes the value for safety)
config_set() {
    local key="$1"
    local value="$2"
    # Validate key to prevent arbitrary yq expression injection
    if [[ ! "$key" =~ ^[.a-zA-Z0-9_]+(\[[0-9]+\])?$ ]]; then log_error "Invalid config key: $key"; return 1; fi
    ensure_kyzn_dirs
    if [[ ! -f "$KYZN_CONFIG" ]]; then
        echo "# kyzn configuration — commit this file" > "$KYZN_CONFIG"
    fi
    VALUE="$value" yq eval -i "$key = strenv(VALUE)" "$KYZN_CONFIG"
}

# Set a string config value (alias for backward compat)
config_set_str() {
    config_set "$@"
}

# ---------------------------------------------------------------------------
# Safety: git wrapper that disables hooks to prevent RCE from malicious repos
# ---------------------------------------------------------------------------
safe_git() {
    git -c core.hooksPath=/dev/null \
        -c filter.lfs.process= \
        -c filter.lfs.smudge= \
        -c filter.lfs.clean= \
        "$@"
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# Generate a run ID (date + random suffix)
generate_run_id() {
    local date_part
    date_part=$(date +%Y%m%d-%H%M%S)
    local rand_part
    rand_part=$(od -A n -t x1 -N 4 /dev/urandom | tr -d ' \n')
    echo "${date_part}-${rand_part}"
}

# Get project root (git root) — cached after first call
project_root() {
    if [[ -z "${KYZN_PROJECT_ROOT:-}" ]]; then
        KYZN_PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    fi
    echo "$KYZN_PROJECT_ROOT"
}

# Get project name from directory — cached after first call
# Sanitized: strip chars that could be used for prompt injection
project_name() {
    if [[ -z "${KYZN_PROJECT_NAME:-}" ]]; then
        local raw
        raw=$(basename "$(project_root)")
        # Keep only alphanumeric, hyphens, underscores, dots (max 128 chars)
        KYZN_PROJECT_NAME=$(echo "$raw" | tr -cd 'A-Za-z0-9._-' | head -c 128)
        [[ -z "$KYZN_PROJECT_NAME" ]] && KYZN_PROJECT_NAME="unnamed-project"
    fi
    echo "$KYZN_PROJECT_NAME"
}

# Prompt user for input with a default
prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    local result

    if [[ -n "$default" ]]; then
        echo -en "${BOLD}$prompt${RESET} [${DIM}$default${RESET}]: " >&2
    else
        echo -en "${BOLD}$prompt${RESET}: " >&2
    fi
    read -r result
    echo "${result:-$default}"
}

# Prompt user for yes/no
prompt_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local result

    if [[ "$default" == "y" ]]; then
        echo -en "${BOLD}$prompt${RESET} [Y/n]: " >&2
    else
        echo -en "${BOLD}$prompt${RESET} [y/N]: " >&2
    fi
    read -r result
    result="${result:-$default}"
    local lower_result
    lower_result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
    [[ "$lower_result" == "y" || "$lower_result" == "yes" ]]
}

# Prompt user to pick from numbered options
prompt_choice() {
    local prompt="$1"
    shift
    local -a options=("$@")

    echo -e "\n${BOLD}$prompt${RESET}" >&2
    local i=1
    for opt in "${options[@]}"; do
        echo -e "  ${CYAN}$i)${RESET} $opt" >&2
        ((i++)) || true
    done
    echo -en "\n${BOLD}Choice${RESET} [1]: " >&2

    local choice
    read -r choice
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
        echo "$choice"
    else
        echo "1"
    fi
}

# Check if a command exists
has_cmd() {
    command -v "$1" &>/dev/null
}

# Portable timeout wrapper (macOS lacks GNU timeout)
if ! command -v timeout &>/dev/null; then
    timeout() {
        local secs="$1"; shift
        "$@" &
        local pid=$!
        ( sleep "$secs" && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null ) &
        local watcher=$!
        wait "$pid" 2>/dev/null
        local ret=$?
        if kill -0 "$watcher" 2>/dev/null; then
            # Process finished before timeout — cancel watcher
            kill "$watcher" 2>/dev/null
            wait "$watcher" 2>/dev/null
            return $ret
        else
            # Watcher already exited — likely timeout fired (edge case: process finished
            # just as sleep expired, making watcher exit before we check — rare false positive)
            wait "$watcher" 2>/dev/null
            return 124
        fi
    }
fi

# Get current timestamp
timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# Write history entry (dual-write: local + global)
# ---------------------------------------------------------------------------
write_history() {
    local run_id="$1" type="$2" status="$3"
    local _extra_name="${4:-}"

    ensure_kyzn_dirs
    local _wh_project
    _wh_project=$(project_name 2>/dev/null || echo "unknown")

    # Build jq args from optional associative array
    local jq_args=()
    jq_args+=(--arg run_id "$run_id" --arg type "$type" --arg status "$status")
    jq_args+=(--arg project "$_wh_project" --arg ts "$(timestamp)")

    if [[ -n "$_extra_name" ]]; then
        local -n _wh_fields="$_extra_name"
        for key in "${!_wh_fields[@]}"; do
            jq_args+=(--arg "$key" "${_wh_fields[$key]}")
        done
    fi

    local json
    json=$(jq -n "${jq_args[@]}" '$ARGS.named | with_entries(select(.value != ""))') || return 0

    # Write to local project history
    echo "$json" > "$KYZN_HISTORY_DIR/$run_id.json" 2>/dev/null || true

    # Write to global history
    echo "$json" > "$KYZN_GLOBAL_HISTORY/$run_id.json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Progress animation — background process that shows continuous activity
# Writes to /dev/tty directly so \r overwrites work from background process.
# Usage:
#   start_progress "Fixing CRITICAL issues" "reading files" "analyzing code"
#   ... long-running work ...
#   stop_progress
# ---------------------------------------------------------------------------
_KYZN_PROGRESS_PID=""

start_progress() {
    # Don't animate if not a terminal
    [[ ! -t 1 ]] && return 0
    [[ ! -e /dev/tty ]] && return 0

    local title="$1"
    shift
    local -a hints=("$@")

    # Kill any existing progress animation
    stop_progress 2>/dev/null

    (
        local bar_chars=("░" "▒" "▓" "█" "▓" "▒")
        local spinner_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local start_time
        start_time=$(date +%s)
        local idx=0

        # Time-aware hints appended after the provided ones
        local -a time_hints=(
            "complex changes take time..."
            "still working on it..."
            "large codebase, patience pays off..."
        )

        while true; do
            local elapsed=$(( $(date +%s) - start_time ))
            local mins=$(( elapsed / 60 ))
            local secs=$(( elapsed % 60 ))
            local time_str
            time_str="${mins}m$(printf '%02d' $secs)s"

            # Spinning braille
            local spin="${spinner_frames[$((idx % ${#spinner_frames[@]}))]}"

            # Animated flowing bar (16 chars wide, wave pattern)
            local bar=""
            local i
            for i in {0..15}; do
                local ci=$(( (idx + i) % ${#bar_chars[@]} ))
                bar+="${bar_chars[$ci]}"
            done

            # Cycling hint text — time-aware after 2 minutes
            local hint=""
            if (( elapsed >= 120 && ${#time_hints[@]} > 0 )); then
                hint="${time_hints[$(( (elapsed / 4) % ${#time_hints[@]} ))]}"
            elif (( ${#hints[@]} > 0 )); then
                hint="${hints[$(( (elapsed / 4) % ${#hints[@]} ))]}"
            fi

            # Write to /dev/tty — bypasses background process buffering,
            # \r overwrites reliably regardless of foreground/background
            printf '\033[2K\r  %b %b[%s]%b %s  %b%s%b  %b%s%b' \
                "${CYAN}${spin}${RESET}" \
                "${DIM}" "$time_str" "${RESET}" \
                "$title" \
                "${CYAN}" "$bar" "${RESET}" \
                "${DIM}" "$hint" "${RESET}" > /dev/tty

            idx=$((idx + 1))
            sleep 0.3
        done
    ) &
    _KYZN_PROGRESS_PID=$!
}

stop_progress() {
    if [[ -n "$_KYZN_PROGRESS_PID" ]] && kill -0 "$_KYZN_PROGRESS_PID" 2>/dev/null; then
        kill "$_KYZN_PROGRESS_PID" 2>/dev/null
        wait "$_KYZN_PROGRESS_PID" 2>/dev/null || true
        _KYZN_PROGRESS_PID=""
        # Clear the progress line
        printf '\033[2K\r' > /dev/tty 2>/dev/null || printf '\033[2K\r'
    fi
}

# Truncate string to N chars
truncate_str() {
    local str="$1"
    local max="${2:-80}"
    if (( ${#str} > max )); then
        echo "${str:0:$((max-3))}..."
    else
        echo "$str"
    fi
}
