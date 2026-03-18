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
KYZN_HISTORY_DIR="$KYZN_DIR/history"
KYZN_REPORTS_DIR="$KYZN_DIR/reports"
KYZN_GLOBAL_DIR="${HOME}/.kyzn"
KYZN_GLOBAL_HISTORY="${KYZN_GLOBAL_DIR}/history"

# Ensure .kyzn directories exist
ensure_kyzn_dirs() {
    mkdir -p "$KYZN_DIR" "$KYZN_HISTORY_DIR" "$KYZN_REPORTS_DIR"
    mkdir -p "$KYZN_GLOBAL_DIR" "$KYZN_GLOBAL_HISTORY"
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

# Set a config value via yq
config_set() {
    local key="$1"
    local value="$2"
    ensure_kyzn_dirs
    if [[ ! -f "$KYZN_CONFIG" ]]; then
        echo "# kyzn configuration — commit this file" > "$KYZN_CONFIG"
    fi
    yq eval -i "$key = $value" "$KYZN_CONFIG"
}

# Set a string config value (properly quoted)
config_set_str() {
    local key="$1"
    local value="$2"
    ensure_kyzn_dirs
    if [[ ! -f "$KYZN_CONFIG" ]]; then
        echo "# kyzn configuration — commit this file" > "$KYZN_CONFIG"
    fi
    VALUE="$value" yq eval -i "$key = strenv(VALUE)" "$KYZN_CONFIG"
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# Generate a run ID (date + random suffix)
generate_run_id() {
    local date_part
    date_part=$(date +%Y%m%d-%H%M%S)
    local rand_part
    rand_part=$(head -c 4 /dev/urandom | xxd -p)
    echo "${date_part}-${rand_part}"
}

# Get project root (git root)
project_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Get project name from directory
project_name() {
    basename "$(project_root)"
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
    [[ "${result,,}" == "y" || "${result,,}" == "yes" ]]
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
        ((i++))
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

# Get current timestamp
timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
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
