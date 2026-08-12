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
KYZN_GLOBAL_LOCKS_DIR="${KYZN_GLOBAL_DIR}/locks"
# shellcheck disable=SC2034 # Shared constant consumed by modules loaded after core.sh.
KYZN_PROFILE_CACHE="$KYZN_DIR/repo-profile.md"

# Sensitive file access restrictions (single constant — used by execute.sh + analyze.sh)
# Note: ~ is expanded to $HOME at runtime to ensure Claude Code resolves home directory paths
KYZN_SETTINGS_JSON='{"permissions":{"disallowedFileGlobs":["**/.git/**","~/.ssh/**","~/.aws/**","~/.config/gh/**","~/.gnupg/**","**/.env","**/.env.*","**/*.pem","**/*.key","~/.bashrc","~/.bash_profile","~/.zshrc","~/.profile","~/.gitconfig","~/.git-credentials","~/.config/**","~/.claude/**","~/.npmrc","~/.pypirc","~/.docker/**","~/.kube/**","~/.netrc","~/.local/share/**","**/*.tfstate","**/*.tfstate.backup","**/.credentials","/etc/shadow","/etc/passwd","/proc/**","/sys/**","~/.bash_history","~/.zsh_history","~/.python_history","**/.bash_history"]}}'
KYZN_SETTINGS_JSON="${KYZN_SETTINGS_JSON//\~/$HOME}"

# Ensure .kyzn directories exist (restrictive permissions for global dirs)
ensure_kyzn_dirs() {
    local kyzn_dir history_dir reports_dir
    kyzn_dir=$(_kyzn_dir_path)
    history_dir=$(_kyzn_history_dir_path)
    reports_dir=$(_kyzn_reports_dir_path)
    mkdir -p "$kyzn_dir" "$history_dir" "$reports_dir"
    # shellcheck disable=SC2174 # Restrictive mode is desired on first creation; chmod below fixes pre-existing dirs.
    mkdir -p -m 700 "$KYZN_GLOBAL_DIR" "$KYZN_GLOBAL_HISTORY" "$KYZN_GLOBAL_LOCKS_DIR"
    chmod 700 "$KYZN_GLOBAL_DIR" "$KYZN_GLOBAL_HISTORY" "$KYZN_GLOBAL_LOCKS_DIR" 2>/dev/null || true

    # Always ensure .kyzn/.gitignore exists (protects target repos even without kyzn init)
    local gi="$kyzn_dir/.gitignore"
    if [[ ! -f "$gi" ]]; then
        cat > "$gi" <<'GITIGNORE'
# kyzn — gitignored local data
history/
reports/
local.yaml
kyzn-report.md
repo-profile.md
GITIGNORE
    fi
}

# ---------------------------------------------------------------------------
# Canonical repository identity — shared by lock acquisition (and, in a later
# stage, worktree registration). Two linked worktrees of the same repository
# share one git-common-dir; two unrelated repos never do, regardless of what
# their checkout directories happen to be named.
# ---------------------------------------------------------------------------

# Physical, symlink-resolved absolute path of the repository's shared git
# directory (".git" for a normal checkout; the main worktree's ".git" for a
# linked worktree). This is the identity a repository-wide lock keys on.
# Fails closed (non-zero, no output) if it cannot be determined — callers
# must never fall back to a guessed or partial path.
git_common_dir() {
    local raw
    raw=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    [[ -n "$raw" ]] || return 1
    [[ "$raw" == /* ]] || raw="$(pwd)/$raw"
    local resolved
    resolved=$(cd "$raw" 2>/dev/null && pwd -P) || return 1
    printf '%s\n' "$resolved"
}

# Physical, symlink-resolved absolute path of the checkout KyZN was invoked
# from (the working tree root — possibly a linked worktree). This identifies
# *where* a run is executing, as opposed to git_common_dir() which identifies
# *which repository* it is executing against. Used for lock diagnostics only.
invocation_root() {
    local resolved
    resolved=$(cd "$(project_root)" 2>/dev/null && pwd -P) || return 1
    printf '%s\n' "$resolved"
}

# Portable path hash for partitioning lock directories. Not a security
# boundary — collisions merely need to be detected (which the stored
# canonical path in the lock record does), not to be cryptographically
# infeasible. Verification workflows sanitize PATH down to KyZN's own
# prerequisites (git, jq, perl/python3, ...) to hide language toolchains, so
# this must not depend on sha256sum/shasum/openssl being present — it falls
# back to perl or python3, the same guaranteed-present interpreters the
# portable `timeout` controller above relies on. Prints nothing on total
# failure; callers must treat empty output as a hard failure, not a valid
# (empty) hash.
_kyzn_hash_path() {
    local input="$1"
    if has_cmd sha256sum; then
        printf '%s' "$input" | sha256sum | cut -d' ' -f1
    elif has_cmd shasum; then
        printf '%s' "$input" | shasum -a 256 | cut -d' ' -f1
    elif has_cmd openssl; then
        printf '%s' "$input" | openssl dgst -sha256 | awk '{print $NF}'
    elif has_cmd perl; then
        printf '%s' "$input" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' 2>/dev/null
    elif has_cmd python3; then
        printf '%s' "$input" | python3 -c 'import sys, hashlib; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Lock management — atomic mkdir-based lock with stale PID detection
# Usage: acquire_kyzn_lock "label"   (label = "improve" or "fix")
#        release_kyzn_lock
# Returns 0 on success, 1 if another process holds the lock (or the lock
# record cannot be trusted).
# Sets KYZN_LOCKDIR for the caller to use in cleanup traps.
#
# The lock is keyed on the repository's canonical git-common-dir, not on any
# checkout path, so two linked worktrees of the same repository — and a
# primary checkout plus its linked worktrees — contend for one lock. It is
# stored under ~/.kyzn/locks/<hash>/, never inside the repository's .git
# directory: KyZN does not write application-specific state into shared git
# internals.
# ---------------------------------------------------------------------------
acquire_kyzn_lock() {
    local label="${1:-improve}"
    ensure_kyzn_dirs

    local common_dir
    if ! common_dir="$(git_common_dir)"; then
        log_error "Could not resolve this repository's shared git directory; refusing to acquire the KyZN lock."
        return 1
    fi

    local lock_hash
    lock_hash="$(_kyzn_hash_path "$common_dir")"
    if [[ -z "$lock_hash" ]]; then
        log_error "Could not compute a lock identity hash (no sha256sum, shasum, openssl, perl, or python3 available); refusing to acquire the KyZN lock."
        return 1
    fi
    KYZN_LOCKDIR="$KYZN_GLOBAL_LOCKS_DIR/$lock_hash"

    if mkdir "$KYZN_LOCKDIR" 2>/dev/null; then
        _kyzn_write_lock_metadata "$label" "$common_dir"
        return 0
    fi

    # Lock directory exists — a complete, valid record is required before the
    # existing kill -0 reclaim decision applies. A missing, partial, or
    # malformed record fails closed instead of being treated as reclaimable:
    # richer metadata (multiple fields, not just a PID file) widens the
    # mkdir-then-write window, so treating "incomplete" the same as "stale"
    # would let a lock observed mid-acquisition be reclaimed out from under
    # its owner.
    local rec_pid rec_common rec_label rec_source rec_time
    if ! _kyzn_read_lock_metadata rec_pid rec_common rec_label rec_source rec_time; then
        log_error "Found an incomplete or malformed KyZN lock record at:"
        log_dim "  $KYZN_LOCKDIR"
        log_dim "  This can happen if a previous run was killed at the instant it acquired the lock."
        log_dim "  Manual inspection procedure: check whether a 'kyzn' process for this repository is"
        log_dim "  actually running (e.g. ps -ef | grep kyzn); if not, remove the lock: rm -rf $KYZN_LOCKDIR"
        return 1
    fi

    if kill -0 "$rec_pid" 2>/dev/null; then
        log_error "Another KyZN $rec_label is already running on this repository (PID: $rec_pid)."
        log_dim "  Repository: $rec_common"
        log_dim "  Source checkout: $rec_source"
        log_dim "  Acquired: $rec_time"
        log_dim "  Lock location: $KYZN_LOCKDIR"
        log_dim "  If this is wrong, inspect and remove the lock: rm -rf $KYZN_LOCKDIR"
        return 1
    fi

    # Stale — the recorded PID is a complete record but no longer alive. Reclaim.
    log_warn "Removing stale lock from a previous run (PID: $rec_pid, $rec_label)"
    rm -rf "$KYZN_LOCKDIR"
    if ! mkdir "$KYZN_LOCKDIR" 2>/dev/null; then
        log_error "Another KyZN process grabbed the lock during recovery."
        return 1
    fi
    _kyzn_write_lock_metadata "$label" "$common_dir"
    return 0
}

# Write the lock metadata record. Built in a temp file and moved into place
# with a single rename so a concurrent reader never observes a partially
# written record — it sees either no record (freshly mkdir'd lock) or a
# complete one.
_kyzn_write_lock_metadata() {
    local label="$1" common_dir="$2"
    local source_root
    source_root="$(invocation_root 2>/dev/null || echo "$common_dir")"
    local tmp_file
    tmp_file=$(mktemp "$KYZN_LOCKDIR/.meta.XXXXXX" 2>/dev/null) || return 0
    if jq -n --arg common_dir "$common_dir" --arg pid "$$" --arg label "$label" \
        --arg source "$source_root" --arg time "$(timestamp)" \
        '{common_dir: $common_dir, pid: ($pid | tonumber), label: $label, source: $source, acquired_at: $time}' \
        > "$tmp_file" 2>/dev/null; then
        mv -f "$tmp_file" "$KYZN_LOCKDIR/meta.json" 2>/dev/null || rm -f "$tmp_file"
    else
        rm -f "$tmp_file"
    fi
}

# Read and validate the lock metadata record. Populates the five named
# out-vars and returns 0 only when every field is present and well-formed.
_kyzn_read_lock_metadata() {
    local -n _out_pid="$1" _out_common="$2" _out_label="$3" _out_source="$4" _out_time="$5"
    local meta_file="$KYZN_LOCKDIR/meta.json"

    [[ -s "$meta_file" ]] || return 1
    jq -e '.' "$meta_file" >/dev/null 2>&1 || return 1

    _out_pid=$(jq -r '.pid // empty' "$meta_file" 2>/dev/null)
    _out_common=$(jq -r '.common_dir // empty' "$meta_file" 2>/dev/null)
    _out_label=$(jq -r '.label // empty' "$meta_file" 2>/dev/null)
    _out_source=$(jq -r '.source // empty' "$meta_file" 2>/dev/null)
    _out_time=$(jq -r '.acquired_at // empty' "$meta_file" 2>/dev/null)

    [[ -n "$_out_pid" && "$_out_pid" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$_out_common" && -n "$_out_label" && -n "$_out_source" && -n "$_out_time" ]] || return 1
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
    # shellcheck disable=SC2034 # Read by abort_unverified_run in execute.sh.
    KYZN_ALLOW_DIRTY="$allow_dirty"
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

# Resolve every repository-owned KyZN path against the Git root, never CWD.
# Project tooling temporarily runs from project_workdir(), and users may invoke
# KyZN from any repository subdirectory; neither may create a second .kyzn tree.
_kyzn_repo_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$(project_root)" "$path"
    fi
}

_kyzn_dir_path() {
    _kyzn_repo_path "$KYZN_DIR"
}

_kyzn_config_path() {
    _kyzn_repo_path "$KYZN_CONFIG"
}

_kyzn_local_config_path() {
    _kyzn_repo_path "$KYZN_LOCAL_CONFIG"
}

_kyzn_history_dir_path() {
    _kyzn_repo_path "$KYZN_HISTORY_DIR"
}

_kyzn_reports_dir_path() {
    _kyzn_repo_path "$KYZN_REPORTS_DIR"
}

_kyzn_profile_cache_path() {
    _kyzn_repo_path "$KYZN_PROFILE_CACHE"
}

# Check if config exists
has_config() {
    [[ -f "$(_kyzn_config_path)" ]]
}

# Read a config value via yq
config_get() {
    local key="$1"
    local default="${2:-}"
    # Validate key is a safe yq dot-notation path (prevent arbitrary expression injection)
    if [[ ! "$key" =~ ^[.a-zA-Z0-9_]+(\[[0-9]+\])?$ ]]; then echo "$default"; return; fi
    if has_config; then
        local val
        val=$(yq eval "$key" "$(_kyzn_config_path)" 2>/dev/null)
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
    local local_config_file
    local_config_file="$(_kyzn_local_config_path)"
    if [[ -f "$local_config_file" ]]; then
        local val
        val=$(yq eval "$key" "$local_config_file" 2>/dev/null)
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
    local config_file
    config_file="$(_kyzn_config_path)"
    if [[ ! -f "$config_file" ]]; then
        echo "# kyzn configuration — commit this file" > "$config_file"
    fi
    VALUE="$value" yq eval -i "$key = strenv(VALUE)" "$config_file"
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

# Directory where project-local tooling must run. detect_project_type stores a
# physically resolved path after validating project.root or an auto-detected
# subdirectory. Re-resolve on every use so a deleted directory or a symlink
# swapped after detection fails closed instead of redirecting execution.
project_workdir() {
    [[ -z "${KYZN_PROJECT_WORKDIR_ERROR:-}" ]] || return 1

    local _pw_output_var="${1:-}"
    local _pw_root _pw_root_real _pw_requested _pw_requested_real
    _pw_root="$(project_root)"
    _pw_root_real=$(cd "$_pw_root" 2>/dev/null && pwd -P) || {
        KYZN_PROJECT_WORKDIR_ERROR="repository root is no longer available"
        return 1
    }
    _pw_requested="${KYZN_PROJECT_WORKDIR:-$_pw_root_real}"
    _pw_requested_real=$(cd "$_pw_requested" 2>/dev/null && pwd -P) || {
        KYZN_PROJECT_WORKDIR_ERROR="project directory is no longer available"
        return 1
    }

    case "$_pw_requested_real" in
        "$_pw_root_real"|"$_pw_root_real"/*) ;;
        *)
            KYZN_PROJECT_WORKDIR_ERROR="project directory resolves outside the repository"
            return 1
            ;;
    esac

    if [[ -n "${KYZN_PROJECT_WORKDIR:-}" && "$_pw_requested_real" != "$KYZN_PROJECT_WORKDIR" ]]; then
        KYZN_PROJECT_WORKDIR_ERROR="project directory changed after detection"
        return 1
    fi

    if [[ -n "$_pw_output_var" ]]; then
        printf -v "$_pw_output_var" '%s' "$_pw_requested_real"
    else
        printf '%s\n' "$_pw_requested_real"
    fi
}

project_workdir_error() {
    printf '%s\n' "${KYZN_PROJECT_WORKDIR_ERROR:-project directory is missing or resolves outside the repository}"
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

# Phase 0 safety gate: KyZN does not yet provide an isolated runner. Mutating
# workflows must receive an explicit per-run acknowledgement before executing
# repository-controlled build/test code or AI-generated changes on the host.
_KYZN_UNSAFE_HOST_EXECUTION_WARNED=false
_KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=false
# Bash preserves the export attribute of an inherited variable across a plain
# assignment, so a caller that pre-exports these names would keep them exported
# through the resets above -- publishing the run's authorization state to every
# child process (measurers, build/test commands, the Claude subprocess). Strip
# the attribute here so an inherited value is discarded immediately, before any
# flag parsing. This does not affect the gate: the resets above already discard
# any inherited value.
export -n _KYZN_UNSAFE_HOST_EXECUTION_WARNED _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED

# Grant per-run authorization from the CLI flag. Assigning is not sufficient on
# its own: under `set -a` (`bash -a kyzn ...`, or an exported
# SHELLOPTS=allexport) Bash marks every *modified* variable for export, so a
# plain assignment would silently undo the unexport above. Unexporting at the
# point of assignment keeps authorization in-process however the shell was
# invoked, and without depending on require_unsafe_host_execution being reached
# -- static-only runs never call it.
allow_unsafe_host_execution() {
    _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED=true
    export -n _KYZN_UNSAFE_HOST_EXECUTION_WARNED _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED
}

require_unsafe_host_execution() {
    local context="${1:-mutating workflow}"

    if [[ "$_KYZN_UNSAFE_HOST_EXECUTION_ALLOWED" != "true" ]]; then
        log_error "Unsafe host execution is disabled; $context was not started."
        log_info "Analysis-only remains available: kyzn analyze"
        log_info "To accept this per-run risk, pass --allow-unsafe-host-execution."
        return 1
    fi

    if [[ "$_KYZN_UNSAFE_HOST_EXECUTION_WARNED" != "true" ]]; then
        log_warn "UNSAFE HOST EXECUTION ENABLED for $context."
        log_warn "KyZN has no container/VM isolation yet. Repository-controlled commands and AI-generated changes run with your user permissions."
        _KYZN_UNSAFE_HOST_EXECUTION_WARNED=true
    fi

    # The _WARNED assignment above re-exports under allexport, so unexport again
    # here -- after every assignment this function performs, and before any
    # child process is spawned by the caller.
    export -n _KYZN_UNSAFE_HOST_EXECUTION_WARNED _KYZN_UNSAFE_HOST_EXECUTION_ALLOWED
}

# Portable timeout wrapper (macOS lacks GNU timeout). Keep input semantics the
# same when GNU timeout is present so configuration behaves identically across
# platforms; the system binary remains the controller for valid durations.
_KYZN_TIMEOUT_BIN=$(type -P timeout 2>/dev/null || true)
timeout() {
    local duration="${1:-}"
    (( $# > 0 )) || return 125
    shift

    # Preserve GNU timeout's safe duration grammar on every platform: a
    # non-negative number with an optional s/m/h/d suffix.
    if [[ ! "$duration" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)([smhd]?)$ ]] || (( $# == 0 )); then
        echo "timeout: invalid duration '$duration' (expected a number optionally followed by s, m, h, or d)" >&2
        return 125
    fi
    if [[ "$duration" =~ ^(0+([.]0*)?|[.]0+)[smhd]?$ ]]; then
        "$@"
        return $?
    fi
    if [[ -n "$_KYZN_TIMEOUT_BIN" ]]; then
        "$_KYZN_TIMEOUT_BIN" "$duration" "$@"
        return $?
    fi

    # Use an available portable runtime as the foreground controller. The
    # child gets a separate process group in the caller's session. Signals are
    # forwarded, caller death is detected, and the complete group is reaped.
    if command -v perl &>/dev/null; then
        perl -MPOSIX=:sys_wait_h,setpgid,SIGHUP,SIGINT,SIGQUIT,SIGTERM -MTime::HiRes=time,sleep -e '
            use strict;
            use warnings;
            my ($duration, @cmd) = @ARGV;
            my %multiplier = (s => 1, m => 60, h => 3600, d => 86400);
            my $suffix = $duration =~ s/([smhd])$// ? $1 : "";
            my $seconds = (0 + $duration) * ($suffix ? $multiplier{$suffix} : 1);
            my $caller_pid = getppid();
            my $pending_signal = 0;
            my %signals = (HUP => SIGHUP, INT => SIGINT, QUIT => SIGQUIT, TERM => SIGTERM);
            for my $name (keys %signals) {
                $SIG{$name} = sub { $pending_signal = $signals{$name}; };
            }

            my $pid = fork();
            exit 125 unless defined $pid;
            if ($pid == 0) {
                exit 125 unless defined setpgid(0, 0);
                exec { $cmd[0] } @cmd;
                exit 127;
            }
            setpgid($pid, $pid);

            my $child_reaped = 0;
            my $child_status = 0;
            my $poll_child = sub {
                return if $child_reaped;
                my $waited = waitpid($pid, WNOHANG);
                if ($waited == $pid) {
                    $child_reaped = 1;
                    $child_status = $?;
                }
            };
            my $terminate_group = sub {
                my ($signal_number) = @_;
                kill $signal_number, -$pid;
                my $grace_deadline = time() + 1.0;
                while (time() < $grace_deadline) {
                    $poll_child->();
                    last unless kill 0, -$pid;
                    sleep 0.05;
                }
                kill "KILL", -$pid if kill 0, -$pid;
                if (!$child_reaped) {
                    waitpid($pid, 0);
                    $child_reaped = 1;
                    $child_status = $?;
                }
            };

            my $deadline = time() + $seconds;
            while (1) {
                $poll_child->();
                if ($child_reaped) {
                    exit WEXITSTATUS($child_status) if WIFEXITED($child_status);
                    exit 128 + WTERMSIG($child_status) if WIFSIGNALED($child_status);
                    exit 125;
                }
                if ($pending_signal) {
                    my $signal_number = $pending_signal;
                    $terminate_group->($signal_number);
                    exit 128 + $signal_number;
                }
                if (getppid() != $caller_pid) {
                    $terminate_group->(SIGTERM);
                    exit 125;
                }
                if (time() >= $deadline) {
                    $terminate_group->(SIGTERM);
                    exit 124;
                }
                sleep 0.05;
            }
        ' "$duration" "$@"
    elif command -v python3 &>/dev/null; then
        python3 -c '
import os, re, signal, sys, time

duration = sys.argv[1]
command = sys.argv[2:]
match = re.fullmatch(r"([0-9]+(?:[.][0-9]*)?|[.][0-9]+)([smhd]?)", duration)
number, suffix = match.groups()
seconds = float(number) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[suffix]
caller_pid = os.getppid()
pending_signal = 0

def remember_signal(signum, _frame):
    global pending_signal
    pending_signal = signum

for forwarded_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
    signal.signal(forwarded_signal, remember_signal)

pid = os.fork()
if pid == 0:
    try:
        os.setpgid(0, 0)
        os.execvp(command[0], command)
    except Exception:
        os._exit(127)
try:
    os.setpgid(pid, pid)
except (PermissionError, ProcessLookupError):
    pass

child_reaped = False
child_status = 0

def poll_child():
    global child_reaped, child_status
    if child_reaped:
        return
    waited, status = os.waitpid(pid, os.WNOHANG)
    if waited == pid:
        child_reaped = True
        child_status = status

def group_alive():
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False

def terminate_group(signum):
    global child_reaped, child_status
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        pass
    grace_deadline = time.monotonic() + 1.0
    while time.monotonic() < grace_deadline:
        poll_child()
        if not group_alive():
            break
        time.sleep(0.05)
    if group_alive():
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if not child_reaped:
        _, child_status = os.waitpid(pid, 0)
        child_reaped = True

deadline = time.monotonic() + seconds
while True:
    poll_child()
    if child_reaped:
        if os.WIFEXITED(child_status):
            sys.exit(os.WEXITSTATUS(child_status))
        if os.WIFSIGNALED(child_status):
            sys.exit(128 + os.WTERMSIG(child_status))
        sys.exit(125)
    if pending_signal:
        forwarded = pending_signal
        terminate_group(forwarded)
        sys.exit(128 + forwarded)
    if os.getppid() != caller_pid:
        terminate_group(signal.SIGTERM)
        sys.exit(125)
    if time.monotonic() >= deadline:
        terminate_group(signal.SIGTERM)
        sys.exit(124)
    time.sleep(0.05)
' "$duration" "$@"
    else
        echo "timeout: portable fallback requires perl or python3" >&2
        return 125
    fi
}

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
    echo "$json" > "$(_kyzn_history_dir_path)/$run_id.json" 2>/dev/null || true

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
