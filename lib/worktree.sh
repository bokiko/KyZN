#!/usr/bin/env bash
# kyzn/lib/worktree.sh — Isolated execution-transaction worktrees for
# `analyze --fix` (issue #21 stage 2).
#
# Layout (KYZN_GLOBAL_DIR = ~/.kyzn, mode 0700):
#   ~/.kyzn/worktrees/<run-id>/metadata.json   KyZN-owned, mode 0600
#   ~/.kyzn/worktrees/<run-id>/checkout/       the only path registered with git
#
# The run directory is keyed by run ID, independent of the repository-wide
# lock's canonical-git-common-dir hash. metadata.json carries git_common_dir
# as a field so a run can be traced back to its source repository.
#
# Every mutating helper here operates against the SOURCE repository (any
# worktree of it — normally invocation_root) via `git -C <source_repo>`, so
# callers never need to `cd` before calling into this module. The isolated
# checkout itself is a plain directory path handed back to the caller, which
# is responsible for `cd`-ing into it to run project commands and Claude.

KYZN_WORKTREES_DIR="${KYZN_GLOBAL_DIR}/worktrees"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
_kyzn_wt_run_dir() {
    printf '%s/%s\n' "$KYZN_WORKTREES_DIR" "$1"
}
_kyzn_wt_checkout_dir() {
    printf '%s/checkout\n' "$(_kyzn_wt_run_dir "$1")"
}
_kyzn_wt_meta_file() {
    printf '%s/metadata.json\n' "$(_kyzn_wt_run_dir "$1")"
}
# The ref name is ALWAYS derived from the validated run ID — never read from
# metadata and trusted directly. Metadata carries this value only so it can
# be verified against the derived value.
_kyzn_wt_ref_name() {
    printf 'refs/kyzn/runs/%s/accepted\n' "$1"
}

# Canonical parent directory for containment checks. Created once, mode 0700.
_kyzn_wt_ensure_root() {
    # shellcheck disable=SC2174 # Restrictive mode is desired on first creation; chmod below fixes pre-existing dirs.
    mkdir -p -m 700 "$KYZN_WORKTREES_DIR" 2>/dev/null || true
    chmod 700 "$KYZN_WORKTREES_DIR" 2>/dev/null || true
    ( cd "$KYZN_WORKTREES_DIR" 2>/dev/null && pwd -P )
}

# ---------------------------------------------------------------------------
# Atomic write: temp file in the same directory, mode 0600, then rename.
# ---------------------------------------------------------------------------
_kyzn_wt_atomic_write() {
    local path="$1" content="$2"
    local dir tmp
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null || true
    tmp=$(mktemp "$dir/.meta.XXXXXX" 2>/dev/null) || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    printf '%s' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# Metadata read/write
# ---------------------------------------------------------------------------

# Validate + echo the raw metadata JSON for a run. Returns 1 (no output) on
# any missing/malformed required field, or an unsupported schema_version.
_kyzn_wt_read_metadata() {
    local run_id="$1" meta_file json schema
    meta_file="$(_kyzn_wt_meta_file "$run_id")"
    [[ -s "$meta_file" ]] || return 1
    json=$(cat "$meta_file" 2>/dev/null) || return 1
    jq -e '.' >/dev/null 2>&1 <<<"$json" || return 1

    schema=$(jq -r '.schema_version // empty' <<<"$json" 2>/dev/null)
    [[ "$schema" =~ ^[0-9]+$ ]] || return 1

    if (( schema != 1 )); then
        # Listable but not otherwise trusted — caller decides what "listable
        # only" means for its purpose.
        printf '%s' "$json"
        return 0
    fi

    local run_id_f owner_pid phase checkout_state status ref_name accepted_head
    run_id_f=$(jq -r '.run_id // empty' <<<"$json")
    owner_pid=$(jq -r '.owner_pid // empty' <<<"$json")
    phase=$(jq -r '.phase // empty' <<<"$json")
    checkout_state=$(jq -r '.checkout_state // empty' <<<"$json")
    status=$(jq -r '.status // empty' <<<"$json")
    ref_name=$(jq -r '.ref_name // empty' <<<"$json")
    accepted_head=$(jq -r '.accepted_head // empty' <<<"$json")

    [[ "$run_id_f" == "$run_id" ]] || return 1
    [[ "$owner_pid" =~ ^[0-9]+$ ]] && (( owner_pid > 0 )) || return 1
    case "$phase" in registered|materialized|analysis|batch-mutating|publication) ;; *) return 1 ;; esac
    case "$checkout_state" in absent|registering|registered|materializing|materialized|removing) ;; *) return 1 ;; esac
    case "$status" in active|preserved) ;; *) return 1 ;; esac
    [[ "$ref_name" == "$(_kyzn_wt_ref_name "$run_id")" ]] || return 1
    [[ "$accepted_head" =~ ^[0-9a-f]{7,40}$ ]] || return 1

    if [[ "$status" == "preserved" ]]; then
        local reason
        reason=$(jq -r '.preservation_reason // empty' <<<"$json")
        case "$reason" in
            verification-unavailable|interrupted|branch-creation-failed|push-failed|pr-creation-failed) ;;
            *) return 1 ;;
        esac
    fi

    printf '%s' "$json"
    return 0
}

# Apply a jq filter to the current metadata and atomically write the result,
# bumping updated_at. Extra args (e.g. `--arg v value`) are passed through to
# jq BEFORE the filter — jq's own option parser only reliably recognizes
# `--arg`/`--argjson`/etc. ahead of the filter expression, so they are never
# appended after it.
_kyzn_wt_update_metadata() {
    local run_id="$1" filter="$2"
    shift 2
    local meta_file json new now
    meta_file="$(_kyzn_wt_meta_file "$run_id")"
    json=$(cat "$meta_file" 2>/dev/null) || return 1
    now="$(timestamp)"
    new=$(jq "$@" --arg now "$now" "($filter) | .updated_at = \$now" <<<"$json" 2>/dev/null) || return 1
    [[ -n "$new" ]] || return 1
    _kyzn_wt_atomic_write "$meta_file" "$new"
}

_kyzn_wt_set_checkout_state() {
    _kyzn_wt_update_metadata "$1" '.checkout_state = $v' --arg v "$2"
}
_kyzn_wt_set_phase() {
    _kyzn_wt_update_metadata "$1" '.phase = $v' --arg v "$2"
}

# ---------------------------------------------------------------------------
# Registration: claim a run ID, write the active record, CAS-create the
# private accepted-ref at the pinned source commit.
#
# Sets KYZN_WT_RUN_ID on success. Returns 1 with nothing created on any
# failure (best-effort cleanup of a partially created run directory).
# ---------------------------------------------------------------------------
kyzn_wt_register() {
    local source_repo="$1" source_commit="$2"
    _kyzn_wt_ensure_root >/dev/null

    local common_dir
    common_dir=$(git -C "$source_repo" rev-parse --git-common-dir 2>/dev/null) || return 1
    [[ "$common_dir" == /* ]] || common_dir="$source_repo/$common_dir"
    common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || return 1

    local run_id run_dir attempt=0
    while (( attempt < 20 )); do
        run_id=$(generate_run_id)
        run_dir="$(_kyzn_wt_run_dir "$run_id")"
        if mkdir -m 700 "$run_dir" 2>/dev/null; then
            break
        fi
        run_id=""
        (( attempt++ )) || true
    done
    [[ -n "$run_id" ]] || return 1

    # $BASHPID must be captured HERE, in the shell that actually owns this
    # run, not inside the `meta=$( ... )` substitution below — a command
    # substitution forks a subshell, and $BASHPID inside it would be that
    # subshell's (already-exited-by-the-time-anyone-reads-it) PID rather
    # than the real owning process. See release_kyzn_lock's identical
    # concern in lib/core.sh for why owner PID correctness matters.
    local owner_pid="$BASHPID"

    local ref_name meta
    ref_name="$(_kyzn_wt_ref_name "$run_id")"
    meta=$(jq -n \
        --arg run_id "$run_id" \
        --arg git_common_dir "$common_dir" \
        --arg source_repo "$source_repo" \
        --arg owner_pid "$owner_pid" \
        --arg ref_name "$ref_name" \
        --arg accepted_head "$source_commit" \
        --arg now "$(timestamp)" \
        '{
            schema_version: 1,
            run_id: $run_id,
            git_common_dir: $git_common_dir,
            source_repo: $source_repo,
            owner_pid: ($owner_pid | tonumber),
            ref_name: $ref_name,
            accepted_head: $accepted_head,
            pending_head: null,
            phase: "registered",
            checkout_state: "absent",
            status: "active",
            preservation_reason: null,
            local_branch: null,
            remote_branch: null,
            created_at: $now,
            updated_at: $now
        }')
    if ! _kyzn_wt_atomic_write "$(_kyzn_wt_meta_file "$run_id")" "$meta"; then
        rm -rf "$run_dir"
        return 1
    fi

    # CAS-create: empty old-value means "ref must not already exist".
    if ! git -C "$source_repo" update-ref "$ref_name" "$source_commit" "" 2>/dev/null; then
        rm -rf "$run_dir"
        return 1
    fi

    # shellcheck disable=SC2034 # Cross-file out-param: read by callers in lib/analyze.sh.
    KYZN_WT_RUN_ID="$run_id"
    return 0
}

# ---------------------------------------------------------------------------
# Checkout-execution boundary
# ---------------------------------------------------------------------------

# Batched, NUL-safe `filter` attribute lookup for every tracked path in
# HEAD, evaluated in the checkout's own git context (so includeIf
# gitdir:/worktree config is honored). Writes NUL-terminated
# <path>\0<attribute>\0<value>\0 triples to $2. Returns 1 (nothing written,
# or a partial/undefined file) the moment either `ls-tree` or `check-attr`
# fails — callers MUST treat that as "inspection failed", never as "no
# attributed paths", since a swallowed failure here is indistinguishable
# from a clean repository with no filters configured.
_kyzn_wt_filter_attr_pairs() {
    local checkout_dir="$1" out_file="$2"
    local tmp_paths
    tmp_paths=$(mktemp) || return 1
    if ! git -C "$checkout_dir" ls-tree -r --name-only -z HEAD > "$tmp_paths" 2>/dev/null; then
        rm -f "$tmp_paths"
        return 1
    fi
    if ! git -C "$checkout_dir" check-attr --stdin -z filter < "$tmp_paths" > "$out_file" 2>/dev/null; then
        rm -f "$tmp_paths"
        return 1
    fi
    rm -f "$tmp_paths"
    return 0
}

# Enumerate non-LFS smudge/process filters that would fire for the pinned
# tree. Prints the first offending filter name and returns 1 if one is
# found. Returns 2 (fail closed, no name printed) if the attribute scan or
# any `git config --get` read could not be completed — never silently
# treated as "no filters." Returns 0 (silent) only when the scan and every
# config read genuinely completed and found nothing but "lfs"/unset.
_kyzn_wt_inspect_filters() {
    local checkout_dir="$1"
    local tmp_attrs
    tmp_attrs=$(mktemp) || return 2
    if ! _kyzn_wt_filter_attr_pairs "$checkout_dir" "$tmp_attrs"; then
        rm -f "$tmp_attrs"
        return 2
    fi

    local -a names=()
    local field i=0 value
    while IFS= read -r -d '' field; do
        if (( i % 3 == 2 )); then
            value="$field"
            if [[ -n "$value" && "$value" != "unspecified" && "$value" != "unset" && "$value" != "lfs" ]]; then
                local seen=false n
                for n in "${names[@]:-}"; do [[ "$n" == "$value" ]] && seen=true && break; done
                $seen || names+=("$value")
            fi
        fi
        (( i++ )) || true
    done < "$tmp_attrs"
    rm -f "$tmp_attrs"

    local nm
    for nm in "${names[@]:-}"; do
        local smudge process smudge_rc=0 process_rc=0
        smudge=$(git -C "$checkout_dir" config --get "filter.$nm.smudge" 2>/dev/null) || smudge_rc=$?
        process=$(git -C "$checkout_dir" config --get "filter.$nm.process" 2>/dev/null) || process_rc=$?
        # git config --get: rc 0 = value present, rc 1 = key not set
        # (benign — filter has no smudge/process configured), rc > 1 = a
        # real read failure (bad config file, etc.) that must fail closed.
        if (( smudge_rc > 1 || process_rc > 1 )); then
            printf '%s\n' "$nm"
            return 2
        fi
        if [[ -n "$smudge" || -n "$process" ]]; then
            printf '%s\n' "$nm"
            return 1
        fi
    done
    return 0
}

# Register the worktree in git with --no-checkout (no hook, no filter runs
# at this step), then, only after filter inspection passes, materialize the
# working tree via read-tree + checkout-index — an index-level operation
# that never invokes hooks, with LFS smudge disabled and any other filter's
# smudge/process already refused by the inspection step above.
#
# Prints an "unavailable reason" string and returns 1 if isolated execution
# cannot proceed (non-LFS filter, unresolved LFS pointer, submodules).
# Returns 0 and sets KYZN_WT_LAST_UNAVAILABLE="" on success.
kyzn_wt_materialize() {
    local run_id="$1" commit="$2"
    local source_repo checkout_dir
    source_repo=$(jq -r '.source_repo' <<<"$(_kyzn_wt_read_metadata "$run_id")") || return 1
    checkout_dir="$(_kyzn_wt_checkout_dir "$run_id")"
    # shellcheck disable=SC2034 # Cross-file out-param: read by callers in lib/analyze.sh.
    KYZN_WT_LAST_UNAVAILABLE=""

    _kyzn_wt_set_checkout_state "$run_id" registering
    if ! safe_git -C "$source_repo" worktree add --no-checkout --detach "$checkout_dir" "$commit" 2>/dev/null; then
        _kyzn_wt_set_checkout_state "$run_id" absent
        KYZN_WT_LAST_UNAVAILABLE="could not create the isolated execution worktree"
        return 1
    fi
    _kyzn_wt_set_checkout_state "$run_id" registered

    local bad_filter filter_rc=0
    bad_filter=$(_kyzn_wt_inspect_filters "$checkout_dir") || filter_rc=$?
    if (( filter_rc == 2 )); then
        KYZN_WT_LAST_UNAVAILABLE="could not inspect the checkout's filter configuration — refusing to materialize"
        _kyzn_wt_discard "$run_id"
        return 1
    elif (( filter_rc == 1 )); then
        KYZN_WT_LAST_UNAVAILABLE="repository configures a non-LFS checkout filter ('$bad_filter') — isolated execution is unavailable"
        _kyzn_wt_discard "$run_id"
        return 1
    fi

    # Submodules are not populated by `git worktree add` at all — checked
    # against the pinned tree object, since the working tree has no files
    # yet (materialization happens below).
    if git -C "$checkout_dir" cat-file -e "HEAD:.gitmodules" 2>/dev/null; then
        KYZN_WT_LAST_UNAVAILABLE="repository uses submodules, which git worktree add does not populate"
        _kyzn_wt_discard "$run_id"
        return 1
    fi

    _kyzn_wt_set_checkout_state "$run_id" materializing
    if ! GIT_LFS_SKIP_SMUDGE=1 safe_git -C "$checkout_dir" read-tree "$commit" 2>/dev/null || \
       ! GIT_LFS_SKIP_SMUDGE=1 safe_git -C "$checkout_dir" checkout-index -a -f 2>/dev/null; then
        KYZN_WT_LAST_UNAVAILABLE="failed to materialize the pinned commit into the isolated worktree"
        _kyzn_wt_discard "$run_id"
        return 1
    fi
    _kyzn_wt_set_checkout_state "$run_id" materialized

    # Unresolved LFS pointers: any tracked path attributed filter=lfs whose
    # materialized content is still a pointer file (smudge was disabled).
    # NUL-safe end to end (path, attribute name, and value are all read as
    # NUL-delimited fields) so paths containing newlines, colons, tabs, or
    # spaces are handled correctly. A failed attribute scan fails closed —
    # it is never treated as "no LFS paths".
    local tmp_attrs
    tmp_attrs=$(mktemp) || {
        KYZN_WT_LAST_UNAVAILABLE="could not inspect Git LFS attributes — refusing to materialize"
        return 1
    }
    if ! _kyzn_wt_filter_attr_pairs "$checkout_dir" "$tmp_attrs"; then
        rm -f "$tmp_attrs"
        KYZN_WT_LAST_UNAVAILABLE="could not inspect Git LFS attributes — refusing to materialize"
        return 1
    fi
    local field i=0 lfs_path="" value
    while IFS= read -r -d '' field; do
        case $(( i % 3 )) in
            0) lfs_path="$field" ;;
            2)
                value="$field"
                if [[ "$value" == "lfs" && -f "$checkout_dir/$lfs_path" ]] && \
                   head -c 40 "$checkout_dir/$lfs_path" 2>/dev/null | grep -q '^version https://git-lfs'; then
                    rm -f "$tmp_attrs"
                    # shellcheck disable=SC2034 # Cross-file out-param: read by callers in lib/analyze.sh.
                    KYZN_WT_LAST_UNAVAILABLE="repository uses Git LFS; required objects are not materialized in isolated execution"
                    return 1
                fi
                ;;
        esac
        (( i++ )) || true
    done < "$tmp_attrs"
    rm -f "$tmp_attrs"

    return 0
}

# Verify the checkout is exactly the one this module registered (canonical
# parent containment + real git registration) before removing it. A
# checkout directory that genuinely does not exist AND has no symlink entry
# at that path is "absent"; anything else that could not be positively
# confirmed as either absent or this run's own verified, git-registered
# checkout is NOT guessed at — it fails closed and returns non-zero,
# `checkout_state` is left exactly as found, and nothing is deleted.
_kyzn_wt_discard() {
    local run_id="$1"
    validate_run_id "$run_id" || { log_error "Refusing to discard: invalid run ID '$run_id'."; return 1; }

    local run_dir checkout_dir source_repo canon_parent
    run_dir="$(_kyzn_wt_run_dir "$run_id")"
    checkout_dir="$(_kyzn_wt_checkout_dir "$run_id")"

    # Genuinely absent: no directory entry AND no symlink entry (dangling
    # or not) at the checkout path. `-d` alone would misreport a dangling
    # symlink as absent (it dereferences and the target is missing) — that
    # would silently discard the "present but untrusted" case below.
    if [[ ! -e "$checkout_dir" && ! -L "$checkout_dir" ]]; then
        _kyzn_wt_set_checkout_state "$run_id" absent 2>/dev/null || true
        return 0
    fi

    # A symlink at the checkout path — dangling, retargeted, or pointing
    # somewhere legitimate — is present-but-untrusted. It is never
    # dereferenced for canonicalization, never treated as absent, and never
    # a raw-deletion target: fail closed and let an operator inspect it.
    if [[ -L "$checkout_dir" ]]; then
        log_error "Run $run_id's checkout path is a symlink — refusing to remove it or treat it as absent: $checkout_dir"
        return 1
    fi

    canon_parent="$(_kyzn_wt_ensure_root)"
    [[ -n "$canon_parent" ]] || {
        log_error "Could not canonicalize the worktrees root — refusing to guess run $run_id's checkout state."
        return 1
    }
    local real_checkout
    real_checkout=$(cd "$checkout_dir" 2>/dev/null && pwd -P) || {
        log_error "Could not canonicalize the checkout path for run $run_id — refusing to guess its state."
        return 1
    }
    case "$real_checkout" in
        "$canon_parent/$run_id/checkout") ;;
        *) log_error "Refusing to remove a worktree path outside the canonical parent: $real_checkout"; return 1 ;;
    esac

    local meta_json
    meta_json=$(cat "$(_kyzn_wt_meta_file "$run_id")" 2>/dev/null)
    source_repo=$(jq -r '.source_repo // empty' <<<"$meta_json" 2>/dev/null)
    [[ -n "$source_repo" ]] || {
        log_error "Run $run_id has no readable source_repo in metadata — refusing to guess removal authority."
        return 1
    }

    _kyzn_wt_set_checkout_state "$run_id" removing

    # Enumerate registered worktrees EXACTLY ONCE, into an owned temp file,
    # with that exact invocation's exit status checked directly. A
    # process-substitution relay (the prior implementation) hides a failed
    # `git worktree list` behind an empty loop — indistinguishable from "not
    # registered" — which would wrongly authorize raw deletion of a
    # checkout Git still has registered. Any enumeration, temp-file, or
    # parse failure here deletes nothing and returns non-zero; checkout_state
    # stays "removing" rather than being guessed at as "absent".
    local enum_file
    enum_file=$(mktemp) || {
        log_error "Could not create a temporary file to enumerate worktree registrations for run $run_id — refusing to remove anything."
        return 1
    }
    if ! git -C "$source_repo" worktree list --porcelain -z > "$enum_file" 2>/dev/null; then
        rm -f "$enum_file"
        log_error "Could not enumerate worktree registrations for run $run_id — refusing to remove anything without proof of registration state."
        return 1
    fi
    # Well-formed non-empty `--porcelain -z` output always ends on a NUL
    # record terminator. A file that doesn't fails closed as malformed or
    # truncated rather than being parsed as if it were complete — a
    # truncated read could otherwise drop exactly the record that proves
    # this checkout is still registered.
    if [[ -s "$enum_file" ]] && [[ -n "$(tail -c1 "$enum_file" | tr -d '\0')" ]]; then
        rm -f "$enum_file"
        log_error "Worktree registration listing for run $run_id looks malformed or truncated — refusing to remove anything."
        return 1
    fi

    local registered=false field cur_path=""
    while IFS= read -r -d '' field; do
        if [[ -z "$field" ]]; then
            cur_path=""
            continue
        fi
        case "$field" in
            "worktree "*) cur_path="${field#worktree }" ;;
        esac
        if [[ "$cur_path" == "$real_checkout" ]]; then
            registered=true
            break
        fi
    done < "$enum_file"
    rm -f "$enum_file"

    if $registered; then
        # No fallback to `rm -rf` on a failed Git removal: a failed
        # removal preserves state (checkout_state stays "removing") and
        # returns non-zero rather than silently authorizing raw deletion
        # of a path Git still has registered.
        if ! safe_git -C "$source_repo" worktree remove --force "$real_checkout" 2>/dev/null; then
            log_error "Could not remove the isolated worktree registration for run $run_id — leaving it in place."
            return 1
        fi
    else
        # Raw filesystem deletion of a checkout Git enumeration just proved
        # UNREGISTERED is authorized only for this run's own validated,
        # canonically contained, non-symlinked partial checkout — never a
        # metadata-supplied path, and only when the recorded checkout_state
        # itself proves this is an owned, still-registering partial
        # materialization (the crash-recovery case), not some other state
        # that happens to have lost its Git registration unexpectedly.
        local checkout_state
        checkout_state=$(jq -r '.checkout_state // empty' <<<"$meta_json" 2>/dev/null)
        if [[ "$checkout_state" != "registering" ]]; then
            log_error "Run $run_id's checkout is unregistered with Git but its recorded state ('${checkout_state:-<unreadable>}') does not prove an owned partial checkout — refusing to delete."
            return 1
        fi
        if [[ -L "$run_dir" || -L "$checkout_dir" ]]; then
            log_error "Refusing to delete run $run_id's checkout: a symlink was found where a real directory was expected."
            return 1
        fi
        rm -rf "$real_checkout"
    fi

    if ! _kyzn_wt_set_checkout_state "$run_id" absent; then
        log_error "Run $run_id: the checkout was removed, but recording checkout_state=absent failed — metadata is now inconsistent with reality. Inspect and correct $(_kyzn_wt_meta_file "$run_id") manually."
        return 1
    fi
    return 0
}

# Discard the current checkout (if any) and materialize a fresh one at the
# given commit. This is the ONLY way batches move between commits — there is
# no in-place reset.
kyzn_wt_recreate() {
    local run_id="$1" commit="$2"
    _kyzn_wt_discard "$run_id" || return 1
    kyzn_wt_materialize "$run_id" "$commit"
}

# ---------------------------------------------------------------------------
# Accepted-head transaction anchor — two-phase CAS
# ---------------------------------------------------------------------------

kyzn_wt_accepted_head() {
    jq -r '.accepted_head' <<<"$(_kyzn_wt_read_metadata "$1")" 2>/dev/null
}

kyzn_wt_ref_name() { _kyzn_wt_ref_name "$1"; }
kyzn_wt_checkout_dir() { _kyzn_wt_checkout_dir "$1"; }
kyzn_wt_set_phase() { _kyzn_wt_set_phase "$1" "$2"; }
kyzn_wt_phase() { jq -r '.phase // empty' <<<"$(_kyzn_wt_read_metadata "$1")" 2>/dev/null; }
kyzn_wt_discard() { _kyzn_wt_discard "$1"; }

# Advance accepted_head from its current value to $2 (a commit reachable via
# the batch worktree's detached HEAD). Must be called BEFORE that worktree
# is discarded.
kyzn_wt_advance_accepted_head() {
    local run_id="$1" candidate="$2"
    local source_repo old ref_name
    source_repo=$(jq -r '.source_repo' <<<"$(_kyzn_wt_read_metadata "$run_id")") || return 1
    old=$(kyzn_wt_accepted_head "$run_id") || return 1
    ref_name="$(_kyzn_wt_ref_name "$run_id")"

    _kyzn_wt_update_metadata "$run_id" '.pending_head = $v' --arg v "$candidate" || return 1
    if ! git -C "$source_repo" update-ref "$ref_name" "$candidate" "$old" 2>/dev/null; then
        log_error "Accepted-head CAS failed for run $run_id — refusing to advance the transaction."
        return 1
    fi
    _kyzn_wt_update_metadata "$run_id" '.accepted_head = $v | .pending_head = null' --arg v "$candidate" || return 1
    return 0
}

# Reconcile an in-progress pending_head against the ref's actual value.
# Must be called under the repository lock before resuming or removing a run.
kyzn_wt_reconcile_pending() {
    local run_id="$1"
    local json source_repo ref_name accepted pending cur
    json="$(_kyzn_wt_read_metadata "$run_id")" || return 1
    source_repo=$(jq -r '.source_repo' <<<"$json")
    # Derived from the validated run ID, never trusted from metadata as the
    # value handed to Git — metadata's own ref_name is already checked
    # against this same derivation inside _kyzn_wt_read_metadata, but the
    # value that actually reaches `git rev-parse`/`update-ref` here must
    # come from the derivation itself, not a JSON field.
    ref_name="$(_kyzn_wt_ref_name "$run_id")"
    accepted=$(jq -r '.accepted_head' <<<"$json")
    pending=$(jq -r '.pending_head // empty' <<<"$json")
    [[ -n "$pending" ]] || return 0

    cur=$(git -C "$source_repo" rev-parse --verify -q "$ref_name" 2>/dev/null) || return 1
    if [[ "$cur" == "$accepted" ]]; then
        _kyzn_wt_update_metadata "$run_id" '.pending_head = null'
    elif [[ "$cur" == "$pending" ]]; then
        _kyzn_wt_update_metadata "$run_id" '.accepted_head = $v | .pending_head = null' --arg v "$pending"
    else
        log_error "Run $run_id: accepted-ref is at neither the accepted nor pending head — failing closed."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Preservation / status
# ---------------------------------------------------------------------------

kyzn_wt_preserve() {
    local run_id="$1" reason="$2" local_branch="${3:-}" remote_branch="${4:-}"
    # `if ... then null else $lb end`, not `select(. != "")`: select on an
    # empty string produces ZERO outputs, which makes the whole `.field = `
    # assignment produce zero outputs too — silently emitting no JSON at all
    # (and failing the `[[ -n "$new" ]]` check in the caller) whenever a
    # branch name is omitted, which is the common case for most
    # preservation reasons.
    _kyzn_wt_update_metadata "$run_id" \
        '.status = "preserved" | .preservation_reason = $r | .local_branch = (if $lb == "" then null else $lb end) | .remote_branch = (if $rb == "" then null else $rb end)' \
        --arg r "$reason" --arg lb "$local_branch" --arg rb "$remote_branch"
}

# ---------------------------------------------------------------------------
# Full-run removal: reconcile pending head, discard checkout, CAS-delete the
# private ref, remove metadata + run directory. Used both by the
# all-batches-failed path and by `kyzn worktrees remove`.
# ---------------------------------------------------------------------------
kyzn_wt_remove_run() {
    local run_id="$1"
    local json source_repo ref_name accepted
    json="$(_kyzn_wt_read_metadata "$run_id")" || {
        log_error "Run $run_id has no valid metadata record — refusing to guess at removal."
        return 1
    }
    kyzn_wt_reconcile_pending "$run_id" || return 1
    json="$(_kyzn_wt_read_metadata "$run_id")" || return 1
    source_repo=$(jq -r '.source_repo' <<<"$json")
    ref_name=$(jq -r '.ref_name' <<<"$json")
    accepted=$(jq -r '.accepted_head' <<<"$json")

    local derived_ref
    derived_ref="$(_kyzn_wt_ref_name "$run_id")"
    if [[ "$ref_name" != "$derived_ref" ]]; then
        log_error "Run $run_id: metadata ref_name does not match the derived name — refusing to touch it."
        return 1
    fi

    local checkout_state
    checkout_state=$(jq -r '.checkout_state' <<<"$json")
    if [[ "$checkout_state" != "absent" ]]; then
        _kyzn_wt_discard "$run_id" || return 1
    fi

    if git -C "$source_repo" rev-parse --verify -q "$derived_ref" >/dev/null 2>&1; then
        if ! git -C "$source_repo" update-ref -d "$derived_ref" "$accepted" 2>/dev/null; then
            log_error "Run $run_id: checkout removed, but the private ref could not be deleted (moved or CAS mismatch)."
            log_error "  Retry: kyzn worktrees remove $run_id"
            return 1
        fi
    fi

    rm -rf "$(_kyzn_wt_run_dir "$run_id")"
    return 0
}

# ---------------------------------------------------------------------------
# kyzn worktrees list / remove
# ---------------------------------------------------------------------------

cmd_worktrees() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        list)   _kyzn_wt_cmd_list "$@" ;;
        remove) _kyzn_wt_cmd_remove "$@" ;;
        *)
            log_error "Usage: kyzn worktrees list | kyzn worktrees remove <run-id>"
            return 1
            ;;
    esac
}

# Read-only. Never acquires the repository lock, never mutates or
# reconciles anything — see lib/worktree.sh header. Labels an active record
# with an absent owner_pid as "stale" purely as a display fact.
_kyzn_wt_cmd_list() {
    _kyzn_wt_ensure_root >/dev/null
    [[ -d "$KYZN_WORKTREES_DIR" ]] || { log_info "No retained worktrees."; return 0; }

    local found=false run_id
    for run_id in "$KYZN_WORKTREES_DIR"/*/; do
        [[ -d "$run_id" ]] || continue
        run_id="$(basename "$run_id")"
        validate_run_id "$run_id" || continue
        found=true

        local meta_file raw schema
        meta_file="$(_kyzn_wt_meta_file "$run_id")"
        raw=$(cat "$meta_file" 2>/dev/null) || { echo "$run_id  [unreadable metadata]"; continue; }
        schema=$(jq -r '.schema_version // empty' <<<"$raw" 2>/dev/null)
        if [[ "$schema" != "1" ]]; then
            echo "$run_id  status=unsupported-schema (schema_version=${schema:-?}) — not removable automatically"
            continue
        fi

        local json
        if ! json="$(_kyzn_wt_read_metadata "$run_id")"; then
            echo "$run_id  status=malformed — not removable automatically"
            continue
        fi

        local status phase checkout_state owner_pid preservation_reason source_repo
        status=$(jq -r '.status' <<<"$json")
        phase=$(jq -r '.phase' <<<"$json")
        checkout_state=$(jq -r '.checkout_state' <<<"$json")
        owner_pid=$(jq -r '.owner_pid' <<<"$json")
        preservation_reason=$(jq -r '.preservation_reason // "-"' <<<"$json")
        source_repo=$(jq -r '.source_repo' <<<"$json")

        local stale=""
        if [[ "$status" == "active" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
            stale=" (stale — owner not visible in this PID namespace)"
        fi

        printf '%s  status=%s%s  phase=%s  checkout=%s  reason=%s  repo=%s\n' \
            "$run_id" "$status" "$stale" "$phase" "$checkout_state" "$preservation_reason" "$source_repo"
    done

    $found || log_info "No retained worktrees."
    return 0
}

_kyzn_wt_cmd_remove() {
    local run_id="${1:-}"
    validate_run_id "$run_id" || { log_error "Invalid run ID: '$run_id'"; return 1; }

    local meta_file raw schema
    meta_file="$(_kyzn_wt_meta_file "$run_id")"
    [[ -f "$meta_file" ]] || { log_error "No retained worktree with run ID: $run_id"; return 1; }
    raw=$(cat "$meta_file" 2>/dev/null) || { log_error "Could not read metadata for $run_id"; return 1; }
    schema=$(jq -r '.schema_version // empty' <<<"$raw" 2>/dev/null)
    if [[ "$schema" != "1" ]]; then
        log_error "Run $run_id has an unsupported schema_version ($schema) — not removable automatically."
        return 1
    fi

    local json
    json="$(_kyzn_wt_read_metadata "$run_id")" || { log_error "Run $run_id has a malformed metadata record — refusing to remove."; return 1; }

    local status owner_pid
    status=$(jq -r '.status' <<<"$json")
    owner_pid=$(jq -r '.owner_pid' <<<"$json")
    if [[ "$status" == "active" ]] && kill -0 "$owner_pid" 2>/dev/null; then
        log_error "Run $run_id looks active (owner PID $owner_pid is alive) — refusing to remove."
        return 1
    fi
    if [[ "$status" == "active" ]]; then
        log_warn "Run $run_id is active but its owner (PID $owner_pid) is not visible in this PID namespace."
        log_warn "  This can mean the owner crashed, or is running in a different PID namespace."
    fi

    local source_repo
    source_repo=$(jq -r '.source_repo' <<<"$json")

    # acquire_kyzn_lock derives repository identity from the CURRENT
    # directory, not from an argument — enter the run's source repository
    # first so the lock acquired here is the same one `analyze --fix` holds
    # against it, regardless of where `kyzn worktrees remove` was invoked
    # from.
    local orig_pwd; orig_pwd=$(pwd)
    if [[ -d "$source_repo/.git" || -f "$source_repo/.git" ]] && cd "$source_repo" 2>/dev/null; then
        acquire_kyzn_lock "worktrees-remove" || { cd "$orig_pwd" 2>/dev/null || true; return 1; }
    fi
    trap 'cd "$orig_pwd" 2>/dev/null || true; release_kyzn_lock' EXIT INT TERM

    local rc=0
    if [[ -d "$source_repo/.git" || -f "$source_repo/.git" ]] && git -C "$source_repo" rev-parse --is-inside-work-tree &>/dev/null; then
        kyzn_wt_remove_run "$run_id" || rc=1
    else
        # Metadata fallback: source repository is gone or inaccessible.
        local canon_parent derived_dir
        canon_parent="$(_kyzn_wt_ensure_root)"
        derived_dir="$canon_parent/$run_id"
        local real_dir
        real_dir=$(cd "$derived_dir" 2>/dev/null && pwd -P) || real_dir=""
        if [[ -n "$real_dir" && "$real_dir" == "$derived_dir" ]]; then
            rm -rf "$derived_dir"
            log_warn "Source repository was inaccessible — removed only this run's KyZN-owned metadata/checkout."
            log_warn "  Git administrative metadata (worktree registration, private ref) could not be updated."
            log_warn "  Possible orphaned entries: inspect 'git worktree list' for this run's checkout path ($derived_dir/checkout) and refs/kyzn/runs/$run_id/accepted in the source repository — remove only that specific entry, not a broad 'git worktree prune'."
        else
            log_error "Run $run_id's directory failed containment validation — refusing to remove anything."
            rc=1
        fi
    fi

    cd "$orig_pwd" 2>/dev/null || true
    release_kyzn_lock
    trap - EXIT INT TERM
    return "$rc"
}
