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

# Sensitive file access restrictions (single constant — used by execute.sh + analyze.sh)
KYZN_SETTINGS_JSON='{"permissions":{"disallowedFileGlobs":["~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key","~/.bashrc","~/.bash_profile","~/.zshrc","~/.profile","~/.gitconfig","~/.git-credentials","~/.config/**","~/.claude/**","~/.npmrc","~/.pypirc","~/.docker/**","~/.kube/**","~/.netrc","~/.local/share/**"]}}'

# Ensure .kyzn directories exist (restrictive permissions for global dirs)
ensure_kyzn_dirs() {
    mkdir -p "$KYZN_DIR" "$KYZN_HISTORY_DIR" "$KYZN_REPORTS_DIR"
    mkdir -p -m 700 "$KYZN_GLOBAL_DIR" "$KYZN_GLOBAL_HISTORY"
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
