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
