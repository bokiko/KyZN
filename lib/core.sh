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
KYZN_PROFILE_CACHE="$KYZN_DIR/repo-profile.md"

# Sensitive file access restrictions (single constant — used by execute.sh + analyze.sh)
# Note: ~ is expanded to $HOME at runtime to ensure Claude Code resolves home directory paths
KYZN_SETTINGS_JSON='{"permissions":{"disallowedFileGlobs":["**/.git/**","~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key","~/.bashrc","~/.bash_profile","~/.zshrc","~/.profile","~/.gitconfig","~/.git-credentials","~/.config/**","~/.claude/**","~/.npmrc","~/.pypirc","~/.docker/**","~/.kube/**","~/.netrc","~/.local/share/**","**/*.tfstate","**/*.tfstate.backup","**/.credentials"]}}'
KYZN_SETTINGS_JSON="${KYZN_SETTINGS_JSON//\~/$HOME}"

# Ensure .kyzn directories exist (restrictive permissions for global dirs)
ensure_kyzn_dirs() {
    mkdir -p "$KYZN_DIR" "$KYZN_HISTORY_DIR" "$KYZN_REPORTS_DIR"
    mkdir -p -m 700 "$KYZN_GLOBAL_DIR" "$KYZN_GLOBAL_HISTORY"

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
GITIGNORE
    fi
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

# Check if config exists
has_config() {
    [[ -f "$KYZN_CONFIG" ]]
}

# Read a config value via yq
config_get() {
    local key="$1"
    local default="${2:-}"
    # Validate key is a safe yq dot-notation path (prevent arbitrary expression injection)
    # Brackets allowed for array access (.foo[0]) but dangerous chars (; | ( ) $ ` blocked
    if [[ ! "$key" =~ ^\.[a-zA-Z0-9_.\[\]]+$ ]]; then echo "$default"; return; fi
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
    if [[ ! "$key" =~ ^\.[a-zA-Z0-9_.\[\]]+$ ]]; then echo "$default"; return; fi
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
    if [[ ! "$key" =~ ^\.[a-zA-Z0-9_.\[\]]+$ ]]; then log_error "Invalid config key: $key"; return 1; fi
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
project_name() {
    if [[ -z "${KYZN_PROJECT_NAME:-}" ]]; then
        KYZN_PROJECT_NAME=$(basename "$(project_root)")
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
        ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
        local watcher=$!
        wait "$pid" 2>/dev/null
        local ret=$?
        kill "$watcher" 2>/dev/null
        wait "$watcher" 2>/dev/null
        return $ret
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
            local time_str="${mins}m$(printf '%02d' $secs)s"

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
