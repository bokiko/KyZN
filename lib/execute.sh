#!/usr/bin/env bash
# kyzn/lib/execute.sh — Claude Code invocation + safety

# ---------------------------------------------------------------------------
# Module-level constant: generated/dependency directory pattern
# (defined once here; referenced in stage_claude_changes and count_diff_size)
# ---------------------------------------------------------------------------
_KYZN_GENERATED_DIRS='(^|/)(\.(next|nuxt|output|cache|parcel-cache)|node_modules|dist|build|out|__pycache__|\.pytest_cache|target/(debug|release)|vendor)/'

# KyZN's own artifacts, excluded from staging and from diff accounting.
_KYZN_ARTIFACT_PATHS='^\.kyzn/|^kyzn-report\.md$|^\.claude/'

# ---------------------------------------------------------------------------
# NUL-safe path plumbing
#
# Every `git` command that lists paths must use `-z`. Default output is
# newline-delimited AND C-quotes any path containing a newline, quote or
# backslash — so `a/b` inside $'log\nfile.txt' arrives as two lines, neither of
# which is a real path, and the quoted form no longer matches a `^\.kyzn/`
# exclusion either. The observable failures are a safety filter that silently
# skips the file it was meant to catch, and `git add` rejecting a path that
# does not exist, which aborts staging for the whole batch.
#
# Filtering is done with Bash's own `=~` rather than `grep`: `grep -z` is a GNU
# extension and is not available in the BSD grep macOS ships.
#
# Usage: <producer -z> | _kyzn_filter_paths_z keep|drop <ERE> [-i]
# ---------------------------------------------------------------------------
_kyzn_filter_paths_z() {
    local mode="$1" pattern="$2" fold="${3:-}" path matched
    [[ "$fold" == "-i" ]] && shopt -s nocasematch
    while IFS= read -r -d '' path; do
        matched=false
        [[ "$path" =~ $pattern ]] && matched=true
        if [[ "$mode" == "keep" ]]; then
            $matched && printf '%s\0' "$path"
        else
            $matched || printf '%s\0' "$path"
        fi
    done
    [[ "$fold" == "-i" ]] && shopt -u nocasematch
    return 0
}

# Read a NUL stream of paths and pass them to `git <args> -- <paths>` in bounded
# batches. Empty input is a no-op, matching `xargs -r`.
#
# The bound is the point. Collecting the whole stream into one argument list is
# what `xargs` exists to avoid: on a large tree it can exceed the platform
# argument limit, and the resulting failure lands on safety cleanups such as
# unstaging generated files.
#
# The limit that actually applies is ARG_MAX, which is a byte budget, not a path
# count — measured on macOS arm64 (ARG_MAX 1048576), 256 paths of 1024 bytes go
# through while 256 of 4096 bytes fail with E2BIG. So a count cap alone only
# holds under an assumption about path length that nothing here enforces. Both
# bounds are applied: whichever is reached first flushes the batch.
#
# 128 KiB leaves roughly 8x headroom against the smallest limit either supported
# platform reports, which absorbs the environment, git's own command words, and
# the argv pointer array without needing to model any of them.
_KYZN_GIT_PATH_BATCH="${_KYZN_GIT_PATH_BATCH:-256}"
_KYZN_GIT_PATH_BATCH_BYTES="${_KYZN_GIT_PATH_BATCH_BYTES:-131072}"

_kyzn_git_apply_paths_z() {
    # `${#path}` counts characters, and a byte budget needs bytes — a UTF-8 path
    # would otherwise be undercounted by up to 4x. Localised, so it is restored
    # on return and cannot leak into anything else.
    local LC_ALL=C
    local -a paths=()
    local path
    local failed=0 processed=0 bytes=0 size

    while IFS= read -r -d '' path; do
        [[ -n "$path" ]] || continue
        size=$(( ${#path} + 1 ))

        # Flush *before* appending, so a batch never exceeds either bound. A
        # single path bigger than the whole budget still goes on its own; there
        # is nothing smaller to split it into.
        if (( ${#paths[@]} > 0 )) &&
           (( ${#paths[@]} >= _KYZN_GIT_PATH_BATCH || bytes + size > _KYZN_GIT_PATH_BATCH_BYTES )); then
            processed=$(( processed + ${#paths[@]} ))
            git -c core.hooksPath=/dev/null "$@" -- "${paths[@]}" 2>/dev/null || failed=$(( failed + 1 ))
            paths=()
            bytes=0
        fi

        paths+=("$path")
        bytes=$(( bytes + size ))
    done

    if (( ${#paths[@]} > 0 )); then
        processed=$(( processed + ${#paths[@]} ))
        git -c core.hooksPath=/dev/null "$@" -- "${paths[@]}" 2>/dev/null || failed=$(( failed + 1 ))
    fi

    # Deliberately not propagated. Every caller runs this as the tail of a
    # pipeline inside a `set -e` shell, where returning non-zero would abort the
    # whole run over a best-effort staging cleanup. Silence was the real defect,
    # so the failure is named instead of swallowed.
    if (( failed > 0 )); then
        log_warn "git $* failed on $failed path batch(es) covering $processed path(s) — some paths were left unprocessed"
    fi
    return 0
}

# Read `git diff --numstat -z` and emit "<added>\t<deleted>" for each entry
# whose path survives the drop-pattern. The -z record format is
# "<add>\t<del>\t<path>" per NUL record, except renames, which emit an entry
# ending in a tab followed by two further records (source, destination).
_kyzn_numstat_z_filtered() {
    local drop_pattern="$1" record add del path
    while IFS= read -r -d '' record; do
        add="${record%%$'\t'*}"
        record="${record#*$'\t'}"
        del="${record%%$'\t'*}"
        path="${record#*$'\t'}"
        if [[ -z "$path" ]]; then
            # Rename: the source path record is consumed and discarded, then
            # the destination becomes the path this entry is attributed to.
            IFS= read -r -d '' _ || break
            IFS= read -r -d '' path || break
        fi
        [[ "$path" =~ $drop_pattern ]] && continue
        printf '%s\t%s\n' "$add" "$del"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Safety: unstage files matching secret patterns (works with actual globs)
# ---------------------------------------------------------------------------
_KYZN_SECRET_PATHS='\.(env|pem|key|p12|pfx|jks|p8|tfvars)$|(^|/)\.env(\.[^/]+)?$|^\.env|credentials|kubeconfig|\.npmrc|\.pypirc|id_rsa|id_ed25519|id_ecdsa|authorized_keys|\.htpasswd|\.docker/config\.json'

unstage_secrets() {
    local -a staged_secrets=()
    local f
    while IFS= read -r -d '' f; do
        staged_secrets+=("$f")
    done < <(git diff --cached --name-only -z 2>/dev/null \
        | _kyzn_filter_paths_z keep "$_KYZN_SECRET_PATHS" -i)

    if (( ${#staged_secrets[@]} > 0 )); then
        git -c core.hooksPath=/dev/null reset HEAD -- "${staged_secrets[@]}" 2>/dev/null || true
        log_warn "Unstaged potential secrets from commit:"
        for f in "${staged_secrets[@]}"; do
            log_dim "  - $f"
        done
    fi
}

# ---------------------------------------------------------------------------
# Internal helper: stage Claude's changes excluding KyZN artifacts (shared logic)
# ---------------------------------------------------------------------------
_stage_for_count() {
    # Stage modified tracked files
    safe_git add -u 2>/dev/null

    # Unstage any generated directories that add -u may have picked up
    git diff --cached --name-only -z 2>/dev/null \
        | _kyzn_filter_paths_z keep "$_KYZN_GENERATED_DIRS" \
        | _kyzn_git_apply_paths_z reset HEAD

    # Stage new files Claude created, excluding KyZN artifacts and generated dirs
    git ls-files -z --others --exclude-standard 2>/dev/null \
        | _kyzn_filter_paths_z drop "$_KYZN_ARTIFACT_PATHS" \
        | _kyzn_filter_paths_z drop "$_KYZN_GENERATED_DIRS" \
        | _kyzn_git_apply_paths_z add
}

# ---------------------------------------------------------------------------
# Safety: stage only Claude's changes, excluding KyZN artifacts
# ---------------------------------------------------------------------------
stage_claude_changes() {
    _stage_for_count

    # Run safety filters on what's staged
    unstage_secrets
    check_dangerous_files
    check_test_deletions
}

# ---------------------------------------------------------------------------
# Safety: count diff size without permanently staging (excludes KyZN artifacts)
# ---------------------------------------------------------------------------
count_diff_size() {
    local _var_added=$1 _var_deleted=$2 _var_binary=$3

    # Count tracked changes without touching the index (avoids expensive add+reset cycle)
    local numstat
    numstat=$(git diff HEAD --numstat -z 2>/dev/null \
        | _kyzn_numstat_z_filtered "$_KYZN_GENERATED_DIRS|$_KYZN_ARTIFACT_PATHS") || true

    # Also count new untracked files (excluding KyZN artifacts and generated dirs).
    #
    # Git classifies each one, rather than `wc -l`: a binary has no lines, so it
    # used to contribute nothing AND never register as binary, letting a new
    # binary slip past the limit entirely. `--numstat` emits "-<TAB>-" for binary
    # content — the same marker already counted for tracked changes — so no
    # extension guessing or `file` output parsing is needed. `--no-index` exits
    # non-zero whenever the two paths differ, which is always here.
    local _nf_file _nf_stat
    local new_files_stat=""
    local -a _nf_arr=()
    while IFS= read -r -d '' _nf_file; do
        _nf_arr+=("$_nf_file")
    done < <(git ls-files -z --others --exclude-standard 2>/dev/null \
        | _kyzn_filter_paths_z drop "$_KYZN_ARTIFACT_PATHS" \
        | _kyzn_filter_paths_z drop "$_KYZN_GENERATED_DIRS")
    for _nf_file in ${_nf_arr[@]+"${_nf_arr[@]}"}; do
        [[ -z "$_nf_file" || ! -f "$_nf_file" ]] && continue
        # Take only the counts: the path field is irrelevant here and would
        # otherwise need unquoting.
        _nf_stat=$(git diff --no-index --numstat -z -- /dev/null "$_nf_file" 2>/dev/null \
            | _kyzn_numstat_z_filtered '^$') || true
        [[ -n "$_nf_stat" ]] && new_files_stat+="${_nf_stat}"$'\n'
    done

    local combined="${numstat}"$'\n'"${new_files_stat}"

    local added=0 deleted=0 binary=0
    if [[ -n "$combined" ]]; then
        added=$(echo "$combined" | awk '/^[0-9]/ {sum+=$1} END {print sum+0}')
        deleted=$(echo "$combined" | awk '/^[0-9]/ {sum+=$2} END {print sum+0}')
        binary=$(echo "$combined" | grep -c '^-' 2>/dev/null) || true
    fi

    printf -v "$_var_added" '%s' "$added"
    printf -v "$_var_deleted" '%s' "$deleted"
    printf -v "$_var_binary" '%s' "$binary"
}

# ---------------------------------------------------------------------------
# Safety: one diff-size policy, applied at every point work can grow.
#
# Reports and returns; it performs NO branch cleanup, so both callers route an
# over-limit result through the same existing abort path rather than growing a
# second copy of the policy — or a second cleanup implementation.
#
# Usage: _kyzn_diff_within_limit <diff_limit>   → 0 within limit, 1 over
# ---------------------------------------------------------------------------
_kyzn_diff_within_limit() {
    local diff_limit="$1"
    local diff_lines=0 del_lines=0 binary_count=0
    count_diff_size diff_lines del_lines binary_count
    local total_diff=$(( diff_lines + del_lines ))

    if (( binary_count > 0 )); then
        log_warn "Claude added $binary_count binary file(s)"
        total_diff=$(( total_diff + binary_count * 500 )) # penalize binaries
    fi

    if (( total_diff > diff_limit )); then
        log_warn "Diff exceeds limit ($total_diff > $diff_limit lines). Aborting."
        return 1
    fi

    log_info "Changes: +$diff_lines -$del_lines ($total_diff lines)"
    return 0
}

# ---------------------------------------------------------------------------
# Safety: check for dangerous staged files (CI pipelines, git hooks)
# ---------------------------------------------------------------------------
# Safety: flag and unstage test files with large deletions (>50% removed)
# ---------------------------------------------------------------------------
check_test_deletions() {
    # Find test files where deletions exceed twice the additions (net loss >50%).
    # Parsed record by record from the -z stream so a path containing a newline
    # cannot escape the check by splitting into two unparseable lines.
    local -a deleted_tests=()
    local record add del path src f
    while IFS= read -r -d '' record; do
        add="${record%%$'\t'*}"
        record="${record#*$'\t'}"
        del="${record%%$'\t'*}"
        path="${record#*$'\t'}"
        src=""
        if [[ -z "$path" ]]; then
            # Rename: the two following records are the source and destination.
            # Both are kept. Attributing a rename to its destination alone let a
            # test file be gutted and moved out of the test tree in one staged
            # change — `tests/test_big.py` -> `src/helper.py` minus half its
            # body reads as a non-test path and walked straight past the guard.
            IFS= read -r -d '' src || break
            IFS= read -r -d '' path || break
        fi
        [[ "$add" == "-" || "$del" == "-" ]] && continue
        # Either side qualifying is enough — the protection is owed to the file
        # that was a test before this change, not only after it.
        [[ "$path" == *test* || "$src" == *test* ]] || continue
        if (( del > add * 2 && del > 20 )); then
            # Unstaging a rename needs both halves: resetting the destination
            # alone would leave the source's deletion staged.
            [[ -n "$src" ]] && deleted_tests+=("$src")
            deleted_tests+=("$path")
        fi
    done < <(git diff --cached --numstat -z HEAD 2>/dev/null)

    if (( ${#deleted_tests[@]} > 0 )); then
        log_warn "Large test deletions detected — unstaging to protect test coverage:"
        for f in "${deleted_tests[@]}"; do
            log_dim "  - $f"
        done
        git -c core.hooksPath=/dev/null reset HEAD -- "${deleted_tests[@]}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Safety: check for dangerous staged files (CI pipelines, git hooks)
# ---------------------------------------------------------------------------
check_dangerous_files() {
    local allow_ci="${KYZN_ALLOW_CI:-false}"
    local -a dangerous=()
    local f
    while IFS= read -r -d '' f; do
        dangerous+=("$f")
    done < <(git diff --cached --name-only -z 2>/dev/null \
        | _kyzn_filter_paths_z keep '\.github/workflows/|\.git/hooks/|\.gitlab-ci\.yml|Jenkinsfile|\.circleci/')

    if (( ${#dangerous[@]} > 0 )); then
        if [[ "$allow_ci" == "true" ]]; then
            log_warn "Claude created CI/pipeline files (--allow-ci enabled):"
        else
            log_warn "Claude created CI/pipeline files — unstaging (use --allow-ci to override):"
        fi
        for f in "${dangerous[@]}"; do
            log_warn "  - $f"
        done
        if [[ "$allow_ci" != "true" ]]; then
            git -c core.hooksPath=/dev/null reset HEAD -- "${dangerous[@]}" 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Safety: enforce hard ceilings on config values
# ---------------------------------------------------------------------------
enforce_config_ceilings() {
    local _var_budget=$1 _var_turns=$2 _var_diff_limit=$3

    # Hard ceilings (cannot be overridden by config)
    local max_budget=25 max_turns=100 max_diff=10000

    local _cur_budget _cur_turns _cur_diff
    _cur_budget="${!_var_budget}"
    _cur_turns="${!_var_turns}"
    _cur_diff="${!_var_diff_limit}"

    if (( $(awk -v b="$_cur_budget" -v m="$max_budget" 'BEGIN {print (b > m) ? 1 : 0}') )); then
        log_warn "Budget $_cur_budget exceeds max ($max_budget). Capping."
        printf -v "$_var_budget" '%s' "$max_budget"
    fi
    if (( $(awk -v b="$_cur_turns" -v m="$max_turns" 'BEGIN {print (b > m) ? 1 : 0}') )); then
        log_warn "Max turns $_cur_turns exceeds max ($max_turns). Capping."
        printf -v "$_var_turns" '%s' "$max_turns"
    fi
    if (( $(awk -v b="$_cur_diff" -v m="$max_diff" 'BEGIN {print (b > m) ? 1 : 0}') )); then
        log_warn "Diff limit $_cur_diff exceeds max ($max_diff). Capping."
        printf -v "$_var_diff_limit" '%s' "$max_diff"
    fi
}

# ---------------------------------------------------------------------------
# Safety: return to main/master branch (fallback chain)
# ---------------------------------------------------------------------------
safe_checkout_back() {
    local target="${KYZN_ORIGINAL_BRANCH:-}"
    if [[ -n "$target" ]]; then
        safe_git checkout "$target" 2>/dev/null && return
    fi
    safe_git checkout - 2>/dev/null ||
    safe_git checkout main 2>/dev/null ||
    safe_git checkout master 2>/dev/null ||
    log_warn "Could not return to previous branch — run 'git checkout main' manually"
}

# ---------------------------------------------------------------------------
# Safety: detect symlinks that escape the repository root (symlink exfiltration)
# ---------------------------------------------------------------------------
check_symlink_escapes() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0

    local escaping
    escaping=$(find . -type l \
        -not -path './node_modules/*' \
        -not -path './.venv/*' \
        -not -path './vendor/*' \
        -not -path './target/*' \
        -not -path './.git/*' \
        2>/dev/null | while IFS= read -r link; do
        local target
        # Portable symlink resolution (readlink -f doesn't exist on stock macOS)
        target=$(readlink -f "$link" 2>/dev/null) || {
            # Fallback: manual multi-level resolution (macOS without coreutils)
            local _resolved="$link"
            local _depth=0
            while [[ -L "$_resolved" ]] && (( _depth++ < 20 )); do
                local _link_dir
                _link_dir=$(cd "$(dirname "$_resolved")" 2>/dev/null && pwd -P) || true
                local _link_target
                _link_target=$(readlink "$_resolved" 2>/dev/null) || true
                if [[ -z "$_link_target" ]]; then
                    echo "$link -> (unresolvable)"
                    continue 2
                fi
                if [[ "$_link_target" == /* ]]; then
                    _resolved="$_link_target"
                else
                    _resolved="$_link_dir/$_link_target"
                fi
            done
            if (( _depth >= 20 )); then
                echo "$link -> (symlink loop)"
                continue
            fi
            target=$(cd "$(dirname "$_resolved")" 2>/dev/null && pwd -P)/$(basename "$_resolved")
        }
        # Allow symlinks whose resolved target is within the repo root
        if [[ "$target" != "$repo_root"/* && "$target" != "$repo_root" ]]; then
            echo "$link -> $target"
        fi
    done)

    if [[ -n "$escaping" ]]; then
        log_error "Repository contains symlinks pointing outside the repo root:"
        echo "$escaping" | while IFS= read -r line; do
            log_dim "  $line"
        done
        log_error "Aborting: symlinks could bypass disallowedFileGlobs restrictions."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Execute Claude Code with safety layers
# ---------------------------------------------------------------------------
execute_claude() {
    local prompt="$1"
    local system_prompt_file="$2"
    local budget="${3:-2.50}"
    local max_turns="${4:-30}"
    local project_type="${5:-$KYZN_PROJECT_TYPE}"
    local model="${6:-sonnet}"
    local verbose="${7:-false}"

    # Build allowlist
    local -a allowlist_arr=()
    build_allowlist allowlist_arr "$project_type"

    # Pre-flight: reject symlinks that escape the repo root (prevents secret exfiltration)
    check_symlink_escapes || return 1

    log_step "Invoking Claude Code (model: $model, budget: \$$budget, max turns: $max_turns)..."

    local stderr_file
    stderr_file=$(mktemp)

    # Timeout (default 10 minutes)
    local claude_timeout="${KYZN_CLAUDE_TIMEOUT:-600}"

    # Core invocation (allowlist is an array — properly quoted expansion)
    local result
    if $verbose; then
        # Stream condensed progress lines to terminal in real-time
        result=$(timeout "$claude_timeout" claude -p "$prompt" \
            --model "$model" \
            --max-budget-usd "$budget" \
            --max-turns "$max_turns" \
            "${allowlist_arr[@]}" \
            --settings "$KYZN_SETTINGS_JSON" \
            --append-system-prompt-file "$system_prompt_file" \
            --output-format json \
            --no-session-persistence \
            2> >(tee "$stderr_file" | while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local short
                short=$(truncate_str "$line" 100)
                echo -e "  ${DIM}${short}${RESET}" >&2
            done)) || {
            local exit_code=$?
            if (( exit_code == 124 )); then
                log_error "Claude Code timed out after ${claude_timeout}s"
            else
                log_error "Claude Code invocation failed"
                if [[ -s "$stderr_file" ]]; then
                    log_dim "Last stderr lines:"
                    tail -10 "$stderr_file" | while IFS= read -r line; do
                        log_dim "  $line"
                    done
                fi
            fi
            rm -f "$stderr_file"; return 1
        }
    else
        result=$(timeout "$claude_timeout" claude -p "$prompt" \
            --model "$model" \
            --max-budget-usd "$budget" \
            --max-turns "$max_turns" \
            "${allowlist_arr[@]}" \
            --settings "$KYZN_SETTINGS_JSON" \
            --append-system-prompt-file "$system_prompt_file" \
            --output-format json \
            --no-session-persistence \
            2>"$stderr_file") || {
            local exit_code=$?
            if (( exit_code == 124 )); then
                log_error "Claude Code timed out after ${claude_timeout}s"
            else
                log_error "Claude Code invocation failed"
                if [[ -s "$stderr_file" ]]; then
                    log_dim "Last stderr lines:"
                    tail -10 "$stderr_file" | while IFS= read -r line; do
                        log_dim "  $line"
                    done
                fi
            fi
            rm -f "$stderr_file"; return 1
        }
    fi

    rm -f "$stderr_file"

    # Defensive JSON extraction
    if ! echo "$result" | jq . &>/dev/null; then
        log_error "Claude returned invalid JSON"
        return 1
    fi

    local cost session_id stop_reason
    cost=$(echo "$result" | jq -r '.total_cost_usd // "unknown"')
    session_id=$(echo "$result" | jq -r '.session_id // "none"')
    stop_reason=$(echo "$result" | jq -r '.stop_reason // "unknown"')

    log_ok "Claude finished (cost: \$$cost, reason: $stop_reason)"

    # Store result for later use
    # shellcheck disable=SC2034 # Exported via globals for callers/tests after execute_claude returns.
    KYZN_CLAUDE_RESULT="$result"
    KYZN_CLAUDE_COST="$cost"
    # shellcheck disable=SC2034 # Exported via globals for callers/tests after execute_claude returns.
    KYZN_CLAUDE_SESSION="$session_id"
    # shellcheck disable=SC2034 # Exported via globals for callers/tests after execute_claude returns.
    KYZN_CLAUDE_STOP_REASON="$stop_reason"
}

# ---------------------------------------------------------------------------
# Main improve command
# ---------------------------------------------------------------------------
# Verification requirements appended to the quick-path prompt once the baseline
# result is known.
#
# Always states the green requirement. When the baseline is red it adds the
# captured identifiers (when there are any), frames them as context rather than
# an exemption, and grants a NARROW permission to repair them — narrow because
# quick modes carry their own constraints, and "clean" mode in particular tells
# Claude not to change behaviour. Without an explicit precedence rule those two
# instructions contradict each other and the run cannot reach green.
#
# Usage: _kyzn_verification_prompt_section <baseline_ok:true|false> <failures>
_kyzn_verification_prompt_section() {
    local baseline_ok="${1:-true}" failures="${2:-}"
    local section="## Verification Requirement

Final verification must be green before this run can enter the normal success path."

    if [[ "$baseline_ok" != "false" ]]; then
        echo "$section"
        return 0
    fi

    section+="

Build or tests were ALREADY failing before you started."

    if [[ -n "${failures//[$'\n' $'\t']/}" ]]; then
        section+="

\`\`\`
$failures
\`\`\`

These identifiers are diagnostic context, not an exemption."
    else
        section+=" Verification produced no identifiable test names, so the failures are real but unnamed. Treat the verification output itself as the evidence."
    fi

    section+="

Make minimal, scoped changes required to repair existing verification failures and reach green verification. Do not hide, skip, delete, or weaken tests, and do not make the failures worse; preserve or strengthen coverage.

This verification requirement overrides mode constraints only for minimal changes necessary to repair existing verification failures and reach green verification. It must not authorize unrelated refactoring or feature work."

    echo "$section"
}


cmd_improve() {
    require_git_repo

    # Parse args
    local auto=false
    local allow_dirty=false
    local focus=""
    local mode=""
    local budget=""
    local max_turns=""
    local model=""
    local verbose=false
    local model_from_cli=false
    local budget_from_cli=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)     auto=true; shift ;;
            --focus)    [[ $# -ge 2 ]] || { log_error "--focus requires a value"; return 1; }; focus="$2"; shift 2 ;;
            --mode)     [[ $# -ge 2 ]] || { log_error "--mode requires a value"; return 1; }; mode="$2"; shift 2 ;;
            --budget)   [[ $# -ge 2 ]] || { log_error "--budget requires a value"; return 1; }; budget="$2"; budget_from_cli=true; shift 2 ;;
            --turns)    [[ $# -ge 2 ]] || { log_error "--turns requires a value"; return 1; }; max_turns="$2"; shift 2 ;;
            --model)    [[ $# -ge 2 ]] || { log_error "--model requires a value"; return 1; }; model="$2"; model_from_cli=true; shift 2 ;;
            --allow-ci) export KYZN_ALLOW_CI=true; shift ;;
            --allow-dirty) allow_dirty=true; shift ;;
            --allow-unsafe-host-execution) allow_unsafe_host_execution; shift ;;
            -v|--verbose) verbose=true; shift ;;
            *)          log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    require_unsafe_host_execution "quick/improve" || return 1
    require_clean_worktree "$allow_dirty" || return 1

    # Prevent concurrent runs on the same repo
    acquire_kyzn_lock "improve" || return 1

    # Detect project
    detect_project_type
    detect_project_features
    print_detection

    # Load config or run interview
    if ! has_config && ! $auto; then
        run_interview
    elif ! has_config && $auto; then
        log_error "No config found. Run 'kyzn init' first, or run without --auto."
        return 1
    fi

    # Apply defaults from config
    mode="${mode:-$(config_get '.preferences.mode' 'deep')}"
    model="${model:-$(config_get '.preferences.model' 'sonnet')}"
    budget="${budget:-$(config_get '.preferences.budget' '2.50')}"
    max_turns="${max_turns:-$(config_get '.preferences.max_turns' '30')}"
    local diff_limit
    diff_limit=$(config_get '.preferences.diff_limit' '2000')
    local on_fail
    on_fail=$(config_get '.preferences.on_build_fail' 'report')

    if [[ -z "$focus" ]]; then
        # Get from config or auto-detect
        local config_focus
        config_focus=$(config_get '.focus.priorities[0]' 'auto')
        focus="$config_focus"
    fi

    # Validate budget format before processing
    if ! [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warn "Invalid budget '$budget' — using default 2.50"
        budget="2.50"
    fi

    # Validate max_turns and diff_limit are numeric integers
    [[ "$max_turns" =~ ^[0-9]+$ ]] || { log_warn "Invalid max_turns '$max_turns' — using default 30"; max_turns=30; }
    [[ "$diff_limit" =~ ^[0-9]+$ ]] || { log_warn "Invalid diff_limit '$diff_limit' — using default 2000"; diff_limit=2000; }

    # Enforce hard ceilings (prevents config poisoning)
    enforce_config_ceilings budget max_turns diff_limit

    # Interactive confirmation (skipped in --auto mode)
    if ! $auto; then
        echo ""
        echo -e "${BOLD}Run settings:${RESET}"
        echo -e "  Mode:   ${CYAN}$mode${RESET}"
        echo -e "  Model:  ${CYAN}$model${RESET}"
        echo -e "  Budget: ${CYAN}\$$budget${RESET}"
        echo -e "  Focus:  ${CYAN}$focus${RESET}"
        echo ""

        # Let user adjust model (skip if --model was passed)
        if ! $model_from_cli; then
            local model_choice
            model_choice=$(prompt_choice "Model to use?" \
                "sonnet  — fast, cost-effective (recommended)" \
                "opus    — highest quality, slower" \
                "haiku   — cheapest, basic improvements")

            case "$model_choice" in
                1) model="sonnet" ;;
                2) model="opus" ;;
                3) model="haiku" ;;
            esac
        fi

        # Let user adjust budget (skip if --budget was passed)
        if ! $budget_from_cli; then
            budget=$(prompt_input "Budget per run (USD)" "$budget")
        fi
    fi

    # Generate run ID
    local run_id
    run_id=$(generate_run_id)
    log_info "Run ID: $run_id"

    # Step 1: Baseline measurement
    local baseline_dir after_dir="" sys_prompt_file=""
    baseline_dir=$(mktemp -d)

    # Cleanup function — handles Ctrl+C, errors, and normal exit
    _kyzn_cleanup() {
        # Mark run as failed if still running
        if [[ -n "${run_id:-}" ]]; then
            local _hist_file
            _hist_file="$(_kyzn_history_dir_path)/$run_id.json"
            if [[ -f "$_hist_file" ]]; then
                local _cur_status
                _cur_status=$(jq -r '.status // ""' "$_hist_file" 2>/dev/null) || true
                if [[ "$_cur_status" == "running" ]]; then
                    declare -A _cleanup_hist=([focus]="${focus:-}")
                    write_history "$run_id" "improve" "failed" _cleanup_hist 2>/dev/null || true
                fi
            fi
        fi
        [[ -d "${baseline_dir:-}" ]] && rm -rf "$baseline_dir" 2>/dev/null
        [[ -d "${after_dir:-}" ]] && rm -rf "$after_dir" 2>/dev/null
        [[ -n "${sys_prompt_file:-}" && "$sys_prompt_file" != "$KYZN_ROOT/templates/system-prompt.md" ]] && rm -f "$sys_prompt_file" 2>/dev/null
        # Release lock
        release_kyzn_lock
        trap - EXIT INT TERM
    }
    trap _kyzn_cleanup EXIT INT TERM

    run_measurements "$KYZN_PROJECT_TYPE" "$baseline_dir"
    local baseline_file="$KYZN_MEASUREMENTS_FILE"

    # Compute baseline score for history
    compute_health_score "$baseline_file"
    local _baseline_health="${KYZN_HEALTH_SCORE:-0}"

    # Write initial "running" history entry
    declare -A _hist=([health_before]="$_baseline_health" [focus]="$focus")
    write_history "$run_id" "improve" "running" _hist

    display_health_dashboard "$baseline_file"

    # Persist model choice to config (only if chosen interactively, not from CLI override)
    if has_config && ! $model_from_cli; then
        VALUE="$model" yq eval -i '.preferences.model = strenv(VALUE)' "$(_kyzn_config_path)"
    fi

    # Step 2: Create branch (use run_id suffix for uniqueness)
    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    KYZN_ORIGINAL_BRANCH="$original_branch"
    local run_suffix="${run_id##*-}"
    local safe_focus="${focus//[^a-zA-Z0-9_-]/-}"
    local branch_name
    branch_name="kyzn/$(date +%Y%m%d)-${safe_focus}-${run_suffix}"
    log_step "Creating branch: $branch_name"
    safe_git checkout -b "$branch_name" || {
        log_error "Failed to create branch $branch_name"
        return 1
    }

    # Step 3: Assemble prompt
    local prompt
    prompt=$(assemble_prompt "$baseline_file" "$mode" "$focus" "$KYZN_PROJECT_TYPE")

    # Pick profile based on focus
    local profile=""
    case "$focus" in
        security*) profile="security" ;;
        testing*)  profile="testing" ;;
        perf*)     profile="performance" ;;
        quality*)  profile="quality" ;;
        doc*)      profile="documentation" ;;
    esac
    sys_prompt_file=$(get_system_prompt "$profile")

    # Step 3.5: Pre-existing test failure detection
    local baseline_verify_ok=true
    local baseline_failures=""
    local baseline_rc=0
    verify_build 2>/dev/null || baseline_rc=$?
    if verify_not_executed "$baseline_rc"; then
        # No verification means no gate. Refusing to open a PR beats shipping
        # changes behind a green light that was never earned.
        log_error "Cannot verify this project: $KYZN_VERIFY_UNAVAILABLE_REASON"
        log_error "Refusing to open a PR for changes KyZN cannot verify."
        log_dim "  Install the missing tool(s) and re-run, or use 'kyzn measure' for a read-only score."
        declare -A _hist_unverified=([health_before]="$_baseline_health" [focus]="$focus")
        write_history "$run_id" "improve" "failed" _hist_unverified
        abort_unverified_run "$branch_name" false
        return 1
    elif (( baseline_rc != 0 )); then
        baseline_verify_ok=false
        baseline_failures=$(capture_failing_tests 2>/dev/null) || true
        log_warn "Pre-existing build/test failures detected (will not block improvements)"
        if [[ -n "$baseline_failures" ]]; then
            log_dim "Known failures:"
            echo "$baseline_failures" | while IFS= read -r f; do
                [[ -n "$f" ]] && log_dim "  - $f"
            done
        fi
    fi

    # Step 3.6: Tell Claude what it is actually being judged against.
    #
    # The prompt above was assembled before verification ran, so it knows nothing
    # about the baseline. Only a green FINAL verification enters the success
    # path, so the requirement is stated unconditionally — including when the
    # baseline produced no identifiable failures, which a red verification often
    # does (test sources that will not compile, or a runner that emits nothing
    # parseable).
    prompt+=$'\n\n'"$(_kyzn_verification_prompt_section "$baseline_verify_ok" "$baseline_failures")"

    # Step 4: Execute Claude
    execute_claude "$prompt" "$sys_prompt_file" "$budget" "$max_turns" "$KYZN_PROJECT_TYPE" "$model" "$verbose" || {
        log_error "Claude execution failed"
        declare -A _hist_fail=([health_before]="$_baseline_health" [focus]="$focus")
        write_history "$run_id" "improve" "failed" _hist_fail
        safe_checkout_back
        safe_git branch -D "$branch_name" 2>/dev/null || true
        return 1
    }

    # Step 5: Check diff size (tracked changes + new untracked files, excludes KyZN artifacts)
    if ! _kyzn_diff_within_limit "$diff_limit"; then
        safe_checkout_back
        safe_git branch -D "$branch_name" 2>/dev/null || true
        return 1
    fi

    # Step 6: Verify (with reflexion retry on failure)
    local verify_errors_file
    verify_errors_file=$(mktemp)

    local verify_out
    verify_out=$(mktemp)

    local verify_rc=0
    verify_build > "$verify_out" 2>&1 || verify_rc=$?
    tail -20 "$verify_out"
    if verify_not_executed "$verify_rc"; then
        # Tooling went missing between baseline and now (e.g. Claude added a
        # tsconfig.json to a project with no local TypeScript).
        log_error "Verification was not executed: $KYZN_VERIFY_UNAVAILABLE_REASON"
        log_error "Refusing to open a PR for changes KyZN cannot verify."
        rm -f "$verify_errors_file" "$verify_out"
        declare -A _hist_unverified_post=([focus]="$focus")
        write_history "$run_id" "improve" "failed" _hist_unverified_post
        abort_unverified_run "$branch_name" true
        return 1
    fi
    if (( verify_rc == 0 )); then
        log_ok "Build and tests passed!"
        rm -f "$verify_errors_file" "$verify_out"
    else
        # Capture error output from first run (no double verify_build)
        local verify_errors
        verify_errors=$(tail -50 "$verify_out")
        echo "$verify_errors" > "$verify_errors_file"
        rm -f "$verify_out"

        # Exactly one self-repair attempt for ANY red final verification. The
        # retry used to be reserved for runs whose baseline started clean, which
        # left a red-baseline run one-shot: it could only reach the green it is
        # judged against by accident.
        #
        # The single attempt is expressed by the control flow, not by a flag:
        # this runs once, and every retry outcome either returns or falls
        # through to success. There is no path back to this point.
        log_warn "Build/tests failing -- attempting self-repair..."

        # Halve the budget for the retry attempt
        local retry_budget
        retry_budget=$(awk -v b="$budget" 'BEGIN { printf "%.2f", b / 2 }')

        # Carry the baseline context into the retry. Wording stays neutral:
        # when the baseline was already red, "your changes broke the build"
        # is simply false, and a prompt that misdescribes the situation
        # invites the model to revert work that was never the problem.
        local retry_baseline_context=""
        if ! $baseline_verify_ok; then
            if [[ -n "${baseline_failures//[$'\n' $'\t']/}" ]]; then
                retry_baseline_context="
## Already Failing Before This Run

\`\`\`
$baseline_failures
\`\`\`

These are diagnostic context, not an exemption. Repair any that remain."
            else
                retry_baseline_context="
## Already Failing Before This Run

Build or tests were already failing before you started, and verification produced no identifiable test names. Existing verification failures may still need repair; use the errors above as the evidence."
            fi
        fi

        # Construct retry prompt with error context + mock guidance
        local retry_prompt
        retry_prompt="Build/tests are still failing after your changes. Here are the errors (last 50 lines):

${verify_errors}
${retry_baseline_context}

## Repair Instructions
- Final verification must be green before this run can enter the normal success path.
- Make minimal, scoped changes to reach green while preserving your improvements. Do not revert all changes.
- Do not hide, skip, delete, or weaken tests; preserve or strengthen coverage.
- If a test import fails (ModuleNotFoundError), rewrite using unittest.mock (Python) or jest.mock (Node).
- Do NOT install new packages or add dependencies."

        # Execute Claude again with error context
        if execute_claude "$retry_prompt" "$sys_prompt_file" "$retry_budget" "$max_turns" "$KYZN_PROJECT_TYPE" "$model" "$verbose"; then
            # Re-verify after retry — branch explicitly on 0 / 1 / 2 rather
            # than relying on global state surviving later control flow.
            local retry_rc=0
            verify_build || retry_rc=$?
            if verify_not_executed "$retry_rc"; then
                log_error "Verification was not executed after self-repair: $KYZN_VERIFY_UNAVAILABLE_REASON"
                log_error "Refusing to open a PR for changes KyZN cannot verify."
                rm -f "$verify_errors_file"
                abort_unverified_run "$branch_name" true
                return 1
            elif (( retry_rc == 0 )); then
                log_ok "Self-repair succeeded -- build and tests pass after retry!"
                rm -f "$verify_errors_file"

                # Step 5 ran BEFORE verification, so it never saw the repair
                # diff. Re-apply the same policy now — before anything is
                # measured, committed, pushed or PR'd — using the same abort
                # path Step 5 uses.
                if ! _kyzn_diff_within_limit "$diff_limit"; then
                    safe_checkout_back
                    safe_git branch -D "$branch_name" 2>/dev/null || true
                    return 1
                fi
            else
                log_error "Self-repair failed -- verification is still not green."
                if ! $baseline_verify_ok; then
                    log_dim "  The baseline was already red. KyZN can still try to improve this repository,"
                    log_dim "  but it will not treat a red final verification as a success."
                fi
                rm -f "$verify_errors_file"
                handle_build_failure "$on_fail" "$run_id" "$branch_name" "$mode" "$focus"
                return 1
            fi
        else
            log_error "Self-repair failed -- Claude execution error on retry."
            rm -f "$verify_errors_file"
            handle_build_failure "$on_fail" "$run_id" "$branch_name" "$mode" "$focus"
            return 1
        fi
        rm -f "$verify_errors_file"
    fi

    # Step 7: Re-measure
    after_dir=$(mktemp -d)
    run_measurements "$KYZN_PROJECT_TYPE" "$after_dir"
    local after_file="$KYZN_MEASUREMENTS_FILE"

    # Step 7.5: Score regression gate (capture baseline first, then after)
    compute_health_score "$baseline_file"
    local baseline_score="${KYZN_HEALTH_SCORE:-0}"
    compute_health_score "$after_file"
    local after_score="${KYZN_HEALTH_SCORE:-0}"

    if (( after_score < baseline_score )); then
        log_warn "Score regressed ($baseline_score → $after_score). Aborting."
        # Always discard on regression — never create a PR for worse code
        handle_build_failure "discard" "$run_id" "$branch_name" "$mode" "$focus"
        return 1
    fi

    # Per-category score floor: abort if any category drops > 5 points
    local category_regression=false
    for cat in security testing performance quality documentation; do
        local before_cat after_cat
        before_cat=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | if length > 0 then (([.[].score] | add) * 100 / ([.[].max_score] | add)) else empty end' "$baseline_file" 2>/dev/null) || true
        after_cat=$(jq -r --arg c "$cat" '[.[] | select(.category == $c)] | if length > 0 then (([.[].score] | add) * 100 / ([.[].max_score] | add)) else empty end' "$after_file" 2>/dev/null) || true

        if [[ -n "$before_cat" && -n "$after_cat" ]]; then
            local b_int="${before_cat%.*}" a_int="${after_cat%.*}"
            b_int="${b_int:-0}"; a_int="${a_int:-0}"
            local drop=$(( b_int - a_int ))
            if (( drop > 5 )); then
                log_warn "Category '$cat' dropped $drop points ($b_int → $a_int)"
                category_regression=true
            fi
        fi
    done

    if $category_regression; then
        log_warn "Per-category score floor breached. Aborting."
        handle_build_failure "discard" "$run_id" "$branch_name" "$mode" "$focus"
        return 1
    fi

    # Step 8: Generate report and create PR
    if ! generate_report "$run_id" "$baseline_file" "$after_file" "$mode" "$focus" "$baseline_score" "$after_score"; then
        log_warn "Report generation or PR creation had issues — check output above."
    fi

    # Clean up temp dirs (after report generation reads them)
    rm -rf "$baseline_dir" "$after_dir" 2>/dev/null
    # Clean up combined system prompt if it was a temp file
    [[ "$sys_prompt_file" != "$KYZN_ROOT/templates/system-prompt.md" ]] && rm -f "$sys_prompt_file" 2>/dev/null

    # Write completed history entry with scores
    declare -A _hist_done=([health_before]="$baseline_score" [health_after]="$after_score" [focus]="$focus")
    write_history "$run_id" "improve" "completed" _hist_done

    log_ok "Improvement cycle complete!"
    log_info "Run 'kyzn approve $run_id' to sign off, or 'kyzn reject $run_id' to discard."
}

# ---------------------------------------------------------------------------
# Handle build failure based on config
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Abort a mutating run because verification could not be executed.
#
# Nothing is committed, pushed, or turned into a PR — that is the safety
# boundary. Anything Claude already changed is deliberately LEFT IN PLACE on
# the KyZN branch, and the run stays checked out there.
#
# Automatic cleanup is NOT attempted: code that deletes a user's files to tidy
# up after an abort is more dangerous than leaving them in place to inspect.
# The leftover state needs a deliberate review — the changes are uncommitted, so
# dropping the branch alone would not discard them — but every option stays open
# to the user, whereas a wrong deletion is unrecoverable.
#
# Usage: abort_unverified_run <branch_name> <worktree_may_be_modified:true|false>
# ---------------------------------------------------------------------------
abort_unverified_run() {
    local branch_name="${1:-}"
    local modified="${2:-true}"
    local reason="${KYZN_VERIFY_UNAVAILABLE_REASON:-required verification tooling unavailable}"
    local orig="${KYZN_ORIGINAL_BRANCH:-}"

    log_error "Verification was not executed: $reason"
    log_error "Refusing to commit, push, or open a PR for changes KyZN could not verify."

    # Unwinding is attempted ONLY when Claude has not run — and even then it is
    # an attempt, not a guarantee: build/test commands can themselves touch the
    # worktree. So the checkout is verified before the branch is deleted, and a
    # failure preserves the current checkout instead. Detached HEAD is never
    # guessed at.
    if [[ "$modified" != "true" && -n "$branch_name" && -n "$orig" && "$orig" != "HEAD" ]]; then
        if safe_git checkout "$orig" 2>/dev/null &&
           [[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" == "$orig" ]]; then
            if safe_git branch -D "$branch_name" 2>/dev/null; then
                log_info "Returned to '$orig'; the empty KyZN branch was removed."
            else
                log_warn "Returned to '$orig', but could not delete '$branch_name' — remove it manually."
            fi
            log_dim "  Install the missing tool(s), then re-run once verification can execute."
            release_kyzn_lock
            return 0
        fi
        log_warn "Could not return to '$orig' — preserving the current checkout instead."
    fi

    # Preserve-in-place. Deliberately inspection-only: KyZN cannot tell your
    # work from Claude's (especially after --allow-dirty), so it offers no
    # one-line discard and never stages on your behalf.
    if [[ -n "$branch_name" ]]; then
        log_warn "Your current checkout is the KyZN branch '$branch_name'."
        log_warn "Its working tree holds uncommitted changes; KyZN has left them untouched."
        log_dim "  Review what is there:"
        log_dim "    git status"
        log_dim "    git diff"
        log_dim "    git diff --cached"
        log_dim "  To keep any of it: review the diff, then stage the specific paths you want."
        log_dim "  To discard it: clean up manually — KyZN will not delete your files."
        if [[ "${KYZN_ALLOW_DIRTY:-false}" == "true" ]]; then
            log_warn "  This run used --allow-dirty, so your own pre-existing edits are mixed in"
            log_warn "  with Claude's. Do NOT run 'git reset --hard' or 'git checkout -f' blindly."
        fi
    fi

    log_dim "  Install the missing tool(s), then re-run once verification can execute."
    release_kyzn_lock
}

handle_build_failure() {
    local strategy="$1"
    local run_id="$2"
    local branch_name="${3:-}"
    local fail_mode="${4:-unknown}"
    local fail_focus="${5:-unknown}"

    case "$strategy" in
        report)
            log_info "Writing failure report..."
            ensure_kyzn_dirs
            local failed_report
            failed_report="$(_kyzn_reports_dir_path)/$run_id-failed.md"
            cat > "$failed_report" <<EOF
# KyZN Run Failed: $run_id

**Date:** $(date -u)
**Mode:** $fail_mode
**Focus:** $fail_focus
**Cost:** \$${KYZN_CLAUDE_COST:-unknown}

## What Happened
Build or tests failed after Claude made changes.

## Changes Made
$(git diff --stat 2>/dev/null || echo "No diff available")

## Next Steps
- Review the changes manually
- Consider running with a more conservative mode
EOF
            log_info "Report saved to $failed_report"
            safe_checkout_back
            if [[ -n "$branch_name" ]]; then safe_git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
        discard)
            log_info "Discarding branch..."
            safe_checkout_back
            if [[ -n "$branch_name" ]]; then safe_git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
        draft-pr)
            # Backstop: a draft PR still pushes a branch and opens a PR. Never do
            # that off the back of verification that was never executed.
            if [[ "${KYZN_VERIFY_STATUS:-}" == "unavailable" ]]; then
                abort_unverified_run "$branch_name" true
                return 0
            fi
            log_info "Creating draft PR with failure report..."
            stage_claude_changes
            safe_git commit -m "KyZN: attempted improvements (build failed) [$run_id]" 2>/dev/null || true
            safe_git push -u origin HEAD 2>/dev/null || true
            gh pr create --draft \
                --title "KyZN: attempted improvements (build failed)" \
                --body "**WARNING: Build failed after these changes.**\n\nRun ID: $run_id\nCost: \$${KYZN_CLAUDE_COST:-unknown}" \
                2>/dev/null || true
            safe_checkout_back
            if [[ -n "$branch_name" ]]; then safe_git branch -D "$branch_name" 2>/dev/null || true; fi
            ;;
    esac
}
