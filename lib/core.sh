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
.improve.lock/
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
# Sets KYZN_LOCKDIR, KYZN_LOCK_TOKEN and KYZN_LOCK_COMMON_DIR for the caller's
# cleanup trap and for release_kyzn_lock's own ownership check — see there.
#
# The lock is keyed on the repository's canonical git-common-dir, not on any
# checkout path, so two linked worktrees of the same repository — and a
# primary checkout plus its linked worktrees — contend for one lock. It is
# stored under ~/.kyzn/locks/<hash>/, never inside the repository's .git
# directory: KyZN does not write application-specific state into shared git
# internals.
# ---------------------------------------------------------------------------

# Generate a per-acquisition ownership token. This is not a security
# boundary — mkdir's atomicity is what excludes other processes from the
# lock directory itself. The token exists so release_kyzn_lock can prove, at
# release time, that it is releasing the specific acquisition it made,
# rather than a directory a successor process has since re-created at the
# same path (same repo => same hash => same path). PID alone cannot serve
# this purpose: the OS reuses PIDs, so a successor can legitimately hold the
# same PID an earlier, already-exited acquisition recorded.
_kyzn_gen_lock_token() {
    local rand_part
    rand_part=$(od -A n -t x1 -N 16 /dev/urandom 2>/dev/null | tr -d ' \n')
    # The token is load-bearing for release_kyzn_lock's ownership check — a
    # token silently missing its random component (od/urandom unavailable
    # or failing) would still be a well-formed, nonempty string, so the
    # caller must fail closed here rather than discover the weakness later.
    [[ -n "$rand_part" ]] || return 1
    printf '%s-%s-%s\n' "$(date +%s%N 2>/dev/null || date +%s)" "$$" "$rand_part"
}

# ---------------------------------------------------------------------------
# Legacy (pre-repository-wide-lock) mutating-workflow lock compatibility.
#
# Before this lock became repository-wide and content-addressed, it was a
# directory at <checkout>/.kyzn/.improve.lock containing a bare `pid` file
# — checkout-local, exactly like .kyzn/ itself. An old KyZN version invoked
# during the upgrade window (mixed old/new installs across a team, or a
# long-running old process outliving an in-place upgrade) knows nothing
# about the new global lock and will happily mutate the repository
# alongside it unless explicitly checked for.
#
# Scope actually provided, stated plainly rather than implied:
#   - A live legacy lock ANYWHERE in the repository's worktrees (checked via
#     `git worktree list`) blocks a new-format acquisition. This is a
#     point-in-time check, re-run on every acquisition attempt. A dead
#     legacy record found this way does not block, and is never migrated
#     or removed — see below.
#   - For the SPECIFIC checkout a new-format acquisition is running from,
#     this process ALSO claims that checkout's own legacy-format guard for
#     the duration of the hold, so an old-version process starting in that
#     SAME checkout after our check is excluded by its own pre-existing
#     mkdir-based logic — not merely a stale check-then-continue snapshot.
#     That guard claim is a FRESH atomic mkdir only: if a legacy lock
#     directory already exists in this checkout for ANY reason — live PID,
#     dead PID, or a missing/malformed/empty/unreadable record — the claim
#     fails closed rather than reclaiming it. This means a dead legacy lock
#     in THIS checkout DOES block a new acquisition here (unlike the
#     cross-worktree check above, which lets a dead record pass), because
#     there is no race-free way to both diagnose "safely dead" and act on
#     it without either coordinating with genuinely-old code (which has no
#     notion of this protocol) or reintroducing the read-then-delete race
#     the new format's own reclaim protocol exists to avoid.
#   - For every OTHER worktree, no such standing guard is held: doing so
#     would mean creating a .kyzn tree in a checkout this process was never
#     invoked from, which is out of scope for a lock compatibility shim.
#     A legacy process that starts in another worktree strictly AFTER this
#     process's check ran is therefore not excluded until its own next
#     acquisition attempt (report-only commands are unaffected either way,
#     since they never held this lock under the old scheme either).
#   - NOT eliminated: the legacy format's own pre-existing mkdir-before-
#     pid-write window (an old-version process's mkdir can succeed before
#     it writes its pid file; another actor reading the directory in that
#     narrow window sees no readable pid record). That race predates this
#     compatibility layer, lives entirely in code this layer does not
#     control, and is out of scope to fix here. A simultaneous old-version
#     and new-version start racing on the identical checkout is therefore
#     NOT guaranteed to have exactly one winner in that narrow window —
#     only sequential (non-overlapping) contention is.
# ---------------------------------------------------------------------------

KYZN_LEGACY_LOCK_NAME=".improve.lock"

_kyzn_legacy_lock_path_for() {
    printf '%s/%s/%s\n' "$1" "$KYZN_DIR" "$KYZN_LEGACY_LOCK_NAME"
}

# Point-in-time check: does a legacy lock anywhere in this repository's
# worktrees block a new-format acquisition right now? A complete record
# (numeric pid) with a live PID blocks. A legacy lock DIRECTORY that exists
# but has no readable, well-formed pid file also blocks — fail closed,
# since an incomplete record could belong to an old-version process still
# mid-acquisition, exactly like the new format's own incomplete-record
# handling. A legacy lock directory that GENUINELY does not exist never
# blocks; nor does one whose complete record's PID is confirmed dead.
# "Genuinely" is load-bearing: every parent directory on the way to the
# legacy lock path must itself be confirmed traversable before an absence
# there is trusted, and the legacy lock path itself (.improve.lock) is
# treated as present (and untrustworthy — blocks) if it is a symlink,
# including a dangling one, rather than a plain directory. `[[ -e path ]]`
# alone cannot tell "genuinely absent" apart from "a parent along the way
# is not traversable, so bash can't see it either way" — conflating those
# is a fail-open bug: a live legacy lock underneath a non-traversable
# .kyzn directory would go completely unseen. This symlink policy is
# NOT the same for .kyzn itself: a .kyzn that is a symlink resolving to a
# traversable directory is permitted (bash's own -d/-x follow symlinks,
# and such a directory is fully inspectable) — only .improve.lock, the
# thing actually being trusted as a source of PID data, is refused
# outright for being a symlink at all.
# Enumeration failure (git worktree list itself fails) ALSO fails closed —
# "could not check" must never silently become "assume clear."
# Diagnostics go to stderr via log_error/log_dim; returns 0 to block, 1 to
# allow.
#
# Consumes `git worktree list --porcelain -z` from a SINGLE invocation,
# captured into an owned temporary file and parsed from that same file —
# never process substitution, never command substitution, never a second
# invocation. Two earlier attempts at this both had a real gap: process
# substitution's `< <(cmd)` doesn't expose `cmd`'s own exit status to the
# shell, so a first attempt ran `git worktree list` a SECOND time (output
# discarded) just to check its status — if that first call happened to
# succeed and the second one then failed (a real, not merely theoretical,
# race — git can fail transiently, or a worktree can be removed between
# the two calls), the parsing loop below silently received zero fields
# and returned "allow." Running it exactly once and checking THAT
# invocation's own status removes the gap entirely. Command substitution
# is avoided for the same reason as always: it strips embedded NUL bytes,
# corrupting the -z parse, and a worktree path containing a literal
# newline would be silently split by any newline-delimited relay of the
# results — a real file preserves both.
# Temporary-file creation failure and the enumeration itself failing both
# fail closed (block); cleanup removes only this function's own owned file.
_kyzn_legacy_lock_blocks() {
    local list_file
    list_file=$(mktemp 2>/dev/null) || {
        log_error "Failed to create a temporary file to enumerate this repository's worktrees; refusing to acquire the KyZN lock until legacy-lock visibility can be confirmed."
        return 0
    }
    if ! git worktree list --porcelain -z > "$list_file" 2>/dev/null; then
        rm -f "$list_file"
        log_error "Could not enumerate this repository's worktrees; refusing to acquire the KyZN lock until legacy-lock visibility can be confirmed."
        return 0
    fi

    local field wt kyzn_dir legacy_dir pid_file raw_pid
    while IFS= read -r -d '' field; do
        case "$field" in
            worktree\ *)
                wt="${field#worktree }"

                # `[[ -e path/to/child ]]` requires traversing every
                # component of the path — if ANY parent directory along
                # the way is not traversable, bash reports the child as
                # nonexistent even when it genuinely, live, exists. A
                # plain `[[ -e "$legacy_dir" ]] || continue` therefore
                # silently treats "I could not check" as "there is
                # nothing there," which is exactly fail-open: an old
                # process's live legacy lock underneath an inaccessible
                # .kyzn directory would never be seen. Establish
                # traversability of each parent explicitly, from the
                # worktree root down, before ever trusting an absence.
                if [[ ! -d "$wt" || ! -x "$wt" ]]; then
                    log_error "Could not inspect a registered worktree for a legacy KyZN lock:"
                    log_dim "  $wt"
                    log_dim "  The worktree root is missing or not traversable; refusing to acquire"
                    log_dim "  the KyZN lock until legacy-lock visibility can be confirmed."
                    rm -f "$list_file"
                    return 0
                fi

                legacy_dir=$(_kyzn_legacy_lock_path_for "$wt")
                kyzn_dir=$(dirname "$legacy_dir")

                # .kyzn genuinely absent (not even a dangling symlink) —
                # only NOW, having confirmed the worktree root itself is
                # traversable, is that conclusion trustworthy.
                if [[ ! -e "$kyzn_dir" && ! -L "$kyzn_dir" ]]; then
                    continue
                fi
                # .kyzn exists as something, but isn't a traversable
                # directory once symlinks are resolved. `-d`/`-x` follow
                # symlinks, so a .kyzn that is itself a symlink resolving
                # to a traversable directory PASSES this check and is
                # permitted, exactly like an ordinary directory — this is
                # deliberate, not an oversight, since such a symlink is
                # fully inspectable. Only a dangling symlink, a symlink to
                # something that isn't a traversable directory, or a
                # permission-denied entry fails closed here, since none of
                # those let this code rule out a live lock underneath.
                if [[ ! -d "$kyzn_dir" || ! -x "$kyzn_dir" ]]; then
                    log_error "Could not inspect a worktree's .kyzn directory for a legacy KyZN lock:"
                    log_dim "  $kyzn_dir"
                    log_dim "  It is not a traversable directory; refusing to acquire the KyZN lock"
                    log_dim "  until legacy-lock visibility can be confirmed."
                    rm -f "$list_file"
                    return 0
                fi

                # $kyzn_dir is now confirmed traversable, so an absence
                # check on the legacy lock path itself is trustworthy —
                # UNLESS that path is a symlink (dangling or not): a
                # dangling symlink reads as absent under plain `-e`, and
                # even a resolving one is not the plain directory this
                # code needs to trust before reading a pid file out of it.
                if [[ ! -e "$legacy_dir" && ! -L "$legacy_dir" ]]; then
                    continue
                fi
                if [[ -L "$legacy_dir" || ! -d "$legacy_dir" || ! -x "$legacy_dir" ]]; then
                    log_error "Found an untrustworthy legacy KyZN lock path (a symlink, a dangling"
                    log_dim "  symlink, or a non-directory entry) at:"
                    log_dim "  $legacy_dir"
                    log_dim "  Manual inspection procedure: confirm no old-version 'kyzn' process is"
                    log_dim "  running for this repository, then remove: rm -rf $legacy_dir"
                    rm -f "$list_file"
                    return 0
                fi

                pid_file="$legacy_dir/pid"
                if [[ ! -s "$pid_file" ]]; then
                    log_error "Found a legacy KyZN lock with no readable pid record at:"
                    log_dim "  $legacy_dir"
                    log_dim "  This can happen if an older KyZN version was killed mid-acquisition."
                    log_dim "  Manual inspection procedure: confirm no old-version 'kyzn' process is"
                    log_dim "  running for this repository, then remove: rm -rf $legacy_dir"
                    rm -f "$list_file"
                    return 0
                fi
                raw_pid=$(cat "$pid_file" 2>/dev/null) || true
                if [[ ! "$raw_pid" =~ ^[0-9]+$ ]]; then
                    log_error "Found a malformed legacy KyZN lock record at:"
                    log_dim "  $pid_file"
                    log_dim "  Manual inspection procedure: confirm no old-version 'kyzn' process is"
                    log_dim "  running for this repository, then remove: rm -rf $legacy_dir"
                    rm -f "$list_file"
                    return 0
                fi
                if kill -0 "$raw_pid" 2>/dev/null; then
                    log_error "An older KyZN version is already running on this repository (PID: $raw_pid)."
                    log_dim "  Checkout: $wt"
                    log_dim "  Legacy lock: $legacy_dir"
                    log_dim "  This is a pre-upgrade lock format; upgrade that checkout's KyZN or let it finish."
                    rm -f "$list_file"
                    return 0
                fi
                ;;
        esac
    done < "$list_file"

    rm -f "$list_file"
    return 1
}

# Claim THIS checkout's own legacy-format lock for the duration this
# process holds the new-format lock — see the header above for exactly
# what this does and does not protect against.
#
# NEVER automatically removes or reclaims an existing legacy lock
# directory, regardless of what its record says: this is a FRESH atomic
# mkdir attempt only. If the directory already exists — live PID, dead
# PID, or a missing/malformed/empty/unreadable record — this fails closed
# and reports which case it was, for manual inspection. Reclaiming a
# legacy lock automatically would reintroduce exactly the read-then-delete
# race the new format's own reclaim protocol above exists to avoid, except
# against genuinely-old code this layer cannot coordinate with at all —
# see the header's note on the pre-existing legacy mkdir-before-pid-write
# race, which this deliberately does not attempt to close.
#
# Writes this process's real PID into a freshly mkdir'd legacy guard
# directory. Factored out to its own function only so tests can override
# this exact write primitive as a black-box boundary (matching the
# existing pattern used for _kyzn_write_lock_metadata elsewhere in this
# file) instead of needing a production-only test hook to force a write
# failure.
_kyzn_write_legacy_pid() {
    echo "$BASHPID" > "$1/pid" 2>/dev/null
}

# Sets KYZN_LEGACY_GUARD_DIR on success and returns 0; leaves it unset and
# returns 1 otherwise. Records $BASHPID, not $$: bash leaves $$ pointing
# at the ORIGINATING shell's PID inside a `( ... )` subshell rather than
# the subshell's own — load-bearing here for the same reason it is
# load-bearing for the new-format lock's own pid field (see
# _kyzn_write_lock_metadata): this guard's only correctness property is
# "the recorded PID's liveness reflects the actual process holding it," and
# a token alone cannot substitute for that, since a subshell inherits its
# parent's variables — including any token — without becoming a different
# process. Real `kyzn` invocations are never themselves running inside a
# subshell, so $BASHPID and $$ agree there; the difference only matters for
# exactly the kind of concurrent-holder simulation this compatibility
# layer's own tests use.
_kyzn_acquire_legacy_guard() {
    local dir; dir="$(_kyzn_legacy_lock_path_for "$(project_root)")"
    mkdir -p "$(dirname "$dir")" 2>/dev/null || true
    if mkdir "$dir" 2>/dev/null; then
        if ! _kyzn_write_legacy_pid "$dir"; then
            # NEVER rm -rf here: the legacy format has no ownership token,
            # so nothing distinguishes "still this attempt's own incomplete
            # directory" from "a successor's live guard that has since
            # reclaimed the same path." Old-version code treats a missing
            # pid file as stale and reclaims it immediately (rm -rf then
            # mkdir) — if an old process does exactly that in the window
            # between our mkdir succeeding and this write failing, deleting
            # $dir now would delete THAT successor's live guard instead of
            # our own dead attempt. Leaving it in place is the only choice
            # that cannot destroy state this process doesn't own; cleanup
            # is deliberately manual.
            log_error "Failed to write the legacy compatibility guard's pid record at:"
            log_dim "  $dir"
            log_dim "  This is left in place rather than removed: the legacy lock format has no"
            log_dim "  ownership token, so there is no safe way to prove this directory still holds"
            log_dim "  only this attempt's own incomplete record rather than a successor's live"
            log_dim "  guard that has since reclaimed the same path. Manual inspection procedure:"
            log_dim "  confirm no 'kyzn' process is running for this repository, then remove: rm -rf $dir"
            return 1
        fi
        KYZN_LEGACY_GUARD_DIR="$dir"
        return 0
    fi

    # Already exists — diagnose only, never touch it.
    local pid
    pid=$(cat "$dir/pid" 2>/dev/null) || true
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        log_error "An older KyZN version is already running on this repository (PID: $pid)."
        log_dim "  Legacy lock: $dir"
    elif [[ "$pid" =~ ^[0-9]+$ ]]; then
        log_error "Found a dead-owner legacy KyZN lock at:"
        log_dim "  $dir"
        log_dim "  This is never reclaimed automatically. Manual inspection procedure: confirm no"
        log_dim "  old-version 'kyzn' process is running for this repository, then remove: rm -rf $dir"
    else
        log_error "Found an incomplete or malformed legacy KyZN lock (missing, empty, or unreadable pid record) at:"
        log_dim "  $dir"
        log_dim "  This is never reclaimed automatically. Manual inspection procedure: confirm no"
        log_dim "  old-version 'kyzn' process is running for this repository, then remove: rm -rf $dir"
    fi
    return 1
}

_kyzn_release_legacy_guard() {
    [[ -n "${KYZN_LEGACY_GUARD_DIR:-}" ]] || return 0
    local pid
    # `|| true`, not just `2>/dev/null`: redirecting stderr silences the
    # message but NOT cat's exit status, and under `set -e` an assignment
    # from a failing command substitution — e.g. this guard's pid file
    # already gone — aborts the entire calling script with no diagnostic
    # at all. release_kyzn_lock must never be the reason a caller's `set -e`
    # script dies outright, so every branch here tolerates a missing file.
    pid=$(cat "$KYZN_LEGACY_GUARD_DIR/pid" 2>/dev/null) || true
    if [[ "$pid" == "$BASHPID" ]]; then
        rm -rf "$KYZN_LEGACY_GUARD_DIR"
    fi
    KYZN_LEGACY_GUARD_DIR=""
}

# Final step of a successful new-format acquisition, run from both the
# fresh-mkdir and stale-reclaim branches below: verify no old-version
# process is visibly holding the pre-upgrade lock anywhere in this
# repository's worktrees, then claim this checkout's own legacy guard for
# the duration of the hold. On failure the caller must remove the
# new-format candidate it just created — this function never publishes
# KYZN_LOCKDIR/KYZN_LOCK_TOKEN/KYZN_LOCK_COMMON_DIR itself.
_kyzn_finalize_new_lock() {
    _kyzn_legacy_lock_blocks && return 1
    _kyzn_acquire_legacy_guard
}

acquire_kyzn_lock() {
    local label="${1:-improve}"
    ensure_kyzn_dirs

    # Everything below operates on a LOCAL candidate path/token, never the
    # global KYZN_LOCKDIR/KYZN_LOCK_TOKEN/KYZN_LOCK_COMMON_DIR — until the
    # complete metadata record is confirmed installed. Publishing KYZN_LOCKDIR
    # early (even just the path, before token/common_dir are known) makes it
    # point at a DIFFERENT lock than what KYZN_LOCK_TOKEN/COMMON_DIR still
    # describe the instant this call is for a different repository than one
    # this process already legitimately owns: e.g. this process holds repo
    # A's lock, then attempts (and is refused for) repo B — if KYZN_LOCKDIR
    # were reassigned to B here, release_kyzn_lock would try to release B
    # using A's token, fail the ownership check, and clear ALL THREE globals
    # — losing every reference needed to ever release A. A failed acquisition
    # must leave whatever this process already owned byte-for-byte unchanged;
    # a caller's cleanup trap firing later still needs to be able to find it.
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
    local candidate_lockdir="$KYZN_GLOBAL_LOCKS_DIR/$lock_hash"

    if mkdir "$candidate_lockdir" 2>/dev/null; then
        local token
        if ! token="$(_kyzn_gen_lock_token)"; then
            log_error "Failed to generate a lock ownership token; lock initialization failed."
            log_dim "  Removing the incomplete lock so a retry can proceed cleanly."
            rm -rf "$candidate_lockdir"
            return 1
        fi
        if ! KYZN_LOCKDIR="$candidate_lockdir" _kyzn_write_lock_metadata "$label" "$common_dir" "$token"; then
            log_error "Failed to write the KyZN lock record; lock initialization failed."
            log_dim "  Removing the incomplete lock so a retry can proceed cleanly."
            rm -rf "$candidate_lockdir"
            return 1
        fi
        if ! _kyzn_finalize_new_lock; then
            rm -rf "$candidate_lockdir"
            return 1
        fi
        KYZN_LOCKDIR="$candidate_lockdir"
        KYZN_LOCK_TOKEN="$token"
        KYZN_LOCK_COMMON_DIR="$common_dir"
        return 0
    fi

    # Lock directory exists — a complete, valid record is required before the
    # existing kill -0 reclaim decision applies. A missing, partial, or
    # malformed record fails closed instead of being treated as reclaimable:
    # richer metadata (multiple fields, not just a PID file) widens the
    # mkdir-then-write window, so treating "incomplete" the same as "stale"
    # would let a lock observed mid-acquisition be reclaimed out from under
    # its owner.
    local rec_pid rec_common rec_label rec_source rec_time rec_token
    if ! KYZN_LOCKDIR="$candidate_lockdir" _kyzn_read_lock_metadata rec_pid rec_common rec_label rec_source rec_time rec_token; then
        log_error "Found an incomplete or malformed KyZN lock record at:"
        log_dim "  $candidate_lockdir"
        log_dim "  This can happen if a previous run was killed at the instant it acquired the lock."
        log_dim "  Manual inspection procedure: check whether a 'kyzn' process for this repository is"
        log_dim "  actually running (e.g. ps -ef | grep kyzn); if not, remove the lock: rm -rf $candidate_lockdir"
        return 1
    fi

    # The lock directory's path is deterministically derived from common_dir
    # (hash of it), so a mismatch here is only ever a hash collision or an
    # implementation error — never normal operation. Check this BEFORE the
    # PID/liveness decision below: a mismatched record belongs to a
    # repository this invocation knows nothing about, so this process must
    # not reclaim it, remove it, or rewrite it, no matter what its recorded
    # PID's liveness looks like.
    if [[ "$rec_common" != "$common_dir" ]]; then
        log_error "Lock identity mismatch at:"
        log_dim "  $candidate_lockdir"
        log_dim "  Recorded repository: $rec_common"
        log_dim "  This repository:     $common_dir"
        log_dim "  This can only happen from a lock-hash collision or an internal error."
        log_dim "  Refusing to touch this lock. Manual inspection procedure: confirm which"
        log_dim "  repository actually owns it before removing anything."
        return 1
    fi

    if kill -0 "$rec_pid" 2>/dev/null; then
        log_error "Another KyZN $rec_label is already running on this repository (PID: $rec_pid)."
        log_dim "  Repository: $rec_common"
        log_dim "  Source checkout: $rec_source"
        log_dim "  Acquired: $rec_time"
        log_dim "  Lock location: $candidate_lockdir"
        log_dim "  If this is wrong, inspect and remove the lock: rm -rf $candidate_lockdir"
        return 1
    fi

    # Stale — the recorded PID is a complete record but no longer alive.
    # Reclaim via _kyzn_reclaim_stale_lock's atomic claim-verify-rename-
    # recreate protocol: two processes that both observed this SAME stale
    # record can never both succeed, and a delayed loser can never destroy
    # the winner's freshly created lock (see that function's header).
    #
    # Called directly, never via `x=$(...)`: command substitution forks a
    # subshell, and inside it $$ still resolves to the ORIGINATING shell
    # (bash's documented behavior for both `( )` and `$( )`), while
    # $BASHPID would instead resolve to that short-lived substitution
    # subshell's own PID — one that exits the instant the substitution
    # completes. Either way, a lock whose metadata pid is meant to name
    # this acquisition's real, still-running process must be written by
    # code running IN that process, not in a subshell spawned to capture
    # its output. The token comes back through an out-variable instead.
    log_warn "Removing stale lock from a previous run (PID: $rec_pid, $rec_label)"
    local reclaimed_token
    if ! _kyzn_reclaim_stale_lock "$candidate_lockdir" "$common_dir" "$rec_pid" "$rec_token" "$label" reclaimed_token; then
        return 1
    fi
    if ! _kyzn_finalize_new_lock; then
        rm -rf "$candidate_lockdir"
        return 1
    fi
    KYZN_LOCKDIR="$candidate_lockdir"
    KYZN_LOCK_TOKEN="$reclaimed_token"
    KYZN_LOCK_COMMON_DIR="$common_dir"
    return 0
}

# Reclaim a stale lock without the read-then-delete race the previous
# implementation had: if two processes both observe the same dead PID in
# the same complete record, an unconditional `rm -rf` + `mkdir` lets a
# delayed process delete the OTHER process's freshly created, live
# replacement lock — both then report success, and both believe they
# exclusively hold a lock the other is also mutating through.
#
# Protocol (claim -> verify -> rename -> recreate):
#   1. Atomically claim this exact incarnation with a marker directory
#      inside it. mkdir is atomic, so at most one process observing this
#      same stale directory can win the claim; every other process's mkdir
#      simply fails and it returns 1 without touching anything.
#   2. The claimant re-reads the record and requires it to still be
#      byte-identical (token, pid, common_dir) to what was originally
#      inspected, and the PID still dead, before trusting it — the marker
#      mkdir proves no one else can be running this same protocol against
#      this directory, but does not by itself prove the record wasn't
#      replaced by something outside this protocol (a manual operator, a
#      pre-migration writer). A mismatch releases the marker and returns 1
#      without further changes.
#   3. Only after that verification does the claimant RENAME the whole
#      claimed directory (marker included) into a quarantine PARENT it
#      atomically created and exclusively owns via `mktemp -d` — never
#      `mktemp -u`. `-u` only PRINTS a name without reserving it: between
#      that print and the later `mv`, another actor can create something
#      at that exact path, and `mv src existing-dir` then NESTS src inside
#      it instead of renaming, silently misplacing this acquisition's data
#      and making a later `rm -rf` on the presumed quarantine path delete
#      state this acquisition never created. `mktemp -d` closes that
#      window by creating the parent atomically; the claimed directory is
#      then renamed to a FIXED child name inside that fresh, exclusively-
#      owned parent — a target that cannot previously exist — and cleanup
#      only ever removes that owned parent, never a bare guessed path.
#   4. The claimant then competes for the now-vacant canonical path with a
#      plain atomic `mkdir`, exactly like a brand-new acquisition. Losing
#      this is a NORMAL fresh-acquisition loss (some other process legally
#      raced in after the path was vacated) — the claimant must never
#      touch that winner, only clean up its own quarantine parent.
#   5. Every failure branch — claim, verify, rename, recreate, token
#      generation, metadata write — cleans up only what this acquisition
#      itself created (the marker, its own quarantine parent, its own
#      fresh candidate) and never reports success.
#
# Sets the caller's out-variable (named by $6) to the new lock's token and
# returns 0 on success. Leaves it untouched and returns 1 on any failure;
# diagnostics go to stderr via log_error, matching the rest of this file.
_kyzn_reclaim_stale_lock() {
    local candidate_lockdir="$1" common_dir="$2" rec_pid="$3" rec_token="$4" label="$5"
    local -n _reclaim_out_token="$6"

    # 1. Atomically claim this exact incarnation.
    if ! mkdir "$candidate_lockdir/.reclaim" 2>/dev/null; then
        return 1
    fi

    # 2. Re-verify the record is exactly what was originally inspected and
    # still dead before trusting the claim.
    local cur_pid cur_common cur_token
    # shellcheck disable=SC2034 # positional out-vars required by _kyzn_read_lock_metadata; only pid/common/token are compared below
    local cur_label cur_source cur_time
    if ! KYZN_LOCKDIR="$candidate_lockdir" _kyzn_read_lock_metadata cur_pid cur_common cur_label cur_source cur_time cur_token ||
       [[ "$cur_pid" != "$rec_pid" || "$cur_common" != "$common_dir" || "$cur_token" != "$rec_token" ]] ||
       kill -0 "$cur_pid" 2>/dev/null; then
        rmdir "$candidate_lockdir/.reclaim" 2>/dev/null
        log_error "The stale lock record changed during reclaim; refusing to touch it."
        return 1
    fi

    # 3. Atomically create an exclusively-owned quarantine parent, then
    # rename the claimed directory to a fixed child inside it.
    local quarantine_parent
    quarantine_parent=$(mktemp -d "${candidate_lockdir}.quarantine.XXXXXX" 2>/dev/null)
    if [[ -z "$quarantine_parent" ]]; then
        rmdir "$candidate_lockdir/.reclaim" 2>/dev/null
        log_error "Failed to create a quarantine directory during reclaim; lock initialization failed."
        return 1
    fi
    # Defense in depth: mktemp -d is documented to return a fresh, empty,
    # uniquely-named directory. If a broken or shadowed implementation
    # somehow returns one that already has content, that content was never
    # created by this acquisition — refuse and leave both it and the
    # stale lock alone rather than assume ownership and rm -rf it away.
    if [[ -n "$(ls -A "$quarantine_parent" 2>/dev/null)" ]]; then
        rmdir "$candidate_lockdir/.reclaim" 2>/dev/null
        log_error "The quarantine directory created for this reclaim was not empty; refusing to touch it."
        log_dim "  $quarantine_parent"
        return 1
    fi
    local quarantine="$quarantine_parent/lock"
    if ! mv "$candidate_lockdir" "$quarantine" 2>/dev/null; then
        rmdir "$candidate_lockdir/.reclaim" 2>/dev/null
        rm -rf "$quarantine_parent"
        log_error "Failed to quarantine the stale lock during reclaim; lock initialization failed."
        return 1
    fi

    # 4. Compete for the now-vacant canonical path exactly like a fresh
    # acquisition. Losing here means a different process legitimately
    # raced in after the path was vacated — never touch its lock.
    if ! mkdir "$candidate_lockdir" 2>/dev/null; then
        rm -rf "$quarantine_parent"
        log_error "Another KyZN process grabbed the lock during recovery."
        return 1
    fi

    local token
    if ! token="$(_kyzn_gen_lock_token)"; then
        rm -rf "$candidate_lockdir" "$quarantine_parent"
        log_error "Failed to generate a lock ownership token; lock initialization failed."
        return 1
    fi
    if ! KYZN_LOCKDIR="$candidate_lockdir" _kyzn_write_lock_metadata "$label" "$common_dir" "$token"; then
        rm -rf "$candidate_lockdir" "$quarantine_parent"
        log_error "Failed to write the KyZN lock record after reclaiming a stale lock; lock initialization failed."
        return 1
    fi

    rm -rf "$quarantine_parent"
    _reclaim_out_token="$token"
    return 0
}

# Write the lock metadata record. Built in a temp file and moved into place
# with a single rename so a concurrent reader never observes a partially
# written record — it sees either no record (freshly mkdir'd lock) or a
# complete one. Returns 0 only when the record is actually in place; every
# failure (mktemp, jq, mv) returns 1 so the caller never treats a lock
# directory with no metadata as a successful acquisition.
#
# Records $BASHPID, not $$. This field is NOT merely diagnostic: it is
# read back by both the live/stale liveness decision (`kill -0 "$rec_pid"`
# in acquire_kyzn_lock and in _kyzn_reclaim_stale_lock's re-verify step)
# and by release_kyzn_lock's owner-bound release check. $$ stays pinned to
# the ORIGINATING shell's PID inside a `( ... )` subshell rather than the
# subshell's own — so a subshell that inherits an already-held lock's
# KYZN_LOCKDIR/KYZN_LOCK_TOKEN variables (ordinary variable inheritance,
# nothing special) would, if metadata recorded $$, also inherit a PID that
# reads back as "$$" from ITS OWN perspective, satisfying release_kyzn_lock's
# ownership check and deleting a lock a DIFFERENT, still-live process
# actually holds — the random token does not prevent this, since the
# subshell inherits the token too. $BASHPID is the actual PID of whichever
# process is running this exact code, subshell or not, so a lock recorded
# by a parent and a release attempted by its child subshell correctly
# disagree.
_kyzn_write_lock_metadata() {
    local label="$1" common_dir="$2" token="$3"
    local source_root
    source_root="$(invocation_root 2>/dev/null || echo "$common_dir")"
    local tmp_file
    tmp_file=$(mktemp "$KYZN_LOCKDIR/.meta.XXXXXX" 2>/dev/null) || return 1
    if jq -n --arg common_dir "$common_dir" --arg pid "$BASHPID" --arg label "$label" \
        --arg source "$source_root" --arg time "$(timestamp)" --arg token "$token" \
        '{common_dir: $common_dir, pid: ($pid | tonumber), label: $label, source: $source, acquired_at: $time, token: $token}' \
        > "$tmp_file" 2>/dev/null; then
        if mv -f "$tmp_file" "$KYZN_LOCKDIR/meta.json" 2>/dev/null; then
            return 0
        fi
        rm -f "$tmp_file"
        return 1
    fi
    rm -f "$tmp_file"
    return 1
}

# Read and validate the lock metadata record. Populates the six named
# out-vars and returns 0 only when every field is present and well-formed.
_kyzn_read_lock_metadata() {
    local -n _out_pid="$1" _out_common="$2" _out_label="$3" _out_source="$4" _out_time="$5" _out_token="$6"
    local meta_file="$KYZN_LOCKDIR/meta.json"

    [[ -s "$meta_file" ]] || return 1
    jq -e '.' "$meta_file" >/dev/null 2>&1 || return 1

    _out_pid=$(jq -r '.pid // empty' "$meta_file" 2>/dev/null)
    _out_common=$(jq -r '.common_dir // empty' "$meta_file" 2>/dev/null)
    _out_label=$(jq -r '.label // empty' "$meta_file" 2>/dev/null)
    _out_source=$(jq -r '.source // empty' "$meta_file" 2>/dev/null)
    _out_time=$(jq -r '.acquired_at // empty' "$meta_file" 2>/dev/null)
    _out_token=$(jq -r '.token // empty' "$meta_file" 2>/dev/null)

    [[ -n "$_out_pid" && "$_out_pid" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$_out_common" && -n "$_out_label" && -n "$_out_source" && -n "$_out_time" && -n "$_out_token" ]] || return 1
    return 0
}

# Owner-bound, single-use release. Verifies this acquisition's token, PID
# and canonical common_dir are still exactly what is recorded at
# KYZN_LOCKDIR before removing anything, then unconditionally clears this
# process's ownership state. That second part is what makes a second call
# safe: the most common second call is the EXIT/INT/TERM trap firing after
# an explicit release earlier in the same function already ran — with
# ownership state cleared, that second call finds KYZN_LOCKDIR/TOKEN empty
# and does nothing, instead of repeating rm -rf against a lock path a
# successor process may have already re-acquired.
release_kyzn_lock() {
    if [[ -z "${KYZN_LOCKDIR:-}" || -z "${KYZN_LOCK_TOKEN:-}" ]]; then
        KYZN_LOCKDIR=""
        KYZN_LOCK_TOKEN=""
        KYZN_LOCK_COMMON_DIR=""
        _kyzn_release_legacy_guard
        return 0
    fi

    local rec_pid rec_common rec_label rec_source rec_time rec_token
    if _kyzn_read_lock_metadata rec_pid rec_common rec_label rec_source rec_time rec_token &&
       [[ "$rec_token" == "$KYZN_LOCK_TOKEN" && "$rec_pid" == "$BASHPID" && "$rec_common" == "${KYZN_LOCK_COMMON_DIR:-}" ]]; then
        rm -rf "$KYZN_LOCKDIR"
    else
        log_warn "Skipping lock release: $KYZN_LOCKDIR no longer holds this acquisition's record."
        log_dim "  This is expected if the lock was already released and reclaimed by another process."
    fi

    KYZN_LOCKDIR=""
    KYZN_LOCK_TOKEN=""
    KYZN_LOCK_COMMON_DIR=""
    _kyzn_release_legacy_guard
    return 0
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
