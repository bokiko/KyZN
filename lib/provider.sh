#!/usr/bin/env bash
# kyzn/lib/provider.sh — Provider adapter layer (Claude CLI, Codex CLI)
# All provider-specific logic lives here. No provider conditionals in other modules.

# ---------------------------------------------------------------------------
# Provider resolution (deterministic, fixed order for auto)
# ---------------------------------------------------------------------------
resolve_provider() {
    local requested="${1:-claude}"
    case "$requested" in
        claude)
            if ! has_cmd claude; then
                log_error "Claude CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code"
                return 1
            fi
            echo "claude"
            ;;
        codex)
            if ! has_cmd codex; then
                log_error "Codex CLI not found. Install: https://github.com/openai/codex"
                return 1
            fi
            echo "codex"
            ;;
        auto)
            # Fixed deterministic order: claude first, codex fallback
            if has_cmd claude && check_provider_auth claude 2>/dev/null; then
                echo "claude"
            elif has_cmd codex && check_provider_auth codex 2>/dev/null; then
                echo "codex"
            else
                log_error "No provider available. Install claude or codex CLI."
                return 1
            fi
            ;;
        *)
            log_error "Unknown provider: $requested (expected: claude, codex, auto)"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Provider auth checks
# ---------------------------------------------------------------------------
check_provider_auth() {
    local provider="$1"
    case "$provider" in
        claude)
            if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
                return 0
            elif [[ -d "$HOME/.claude" ]]; then
                return 0
            elif claude auth status &>/dev/null; then
                return 0
            fi
            return 1
            ;;
        codex)
            if [[ -n "${OPENAI_API_KEY:-}" ]]; then
                return 0
            elif codex auth status &>/dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Model mapping (KyZN model hints → provider-specific model IDs)
# ---------------------------------------------------------------------------
resolve_provider_model() {
    local provider="$1"
    local hint="${2:-sonnet}"

    case "$provider" in
        claude)
            # Claude CLI accepts model names directly
            echo "$hint"
            ;;
        codex)
            # Map KyZN model hints to OpenAI models
            case "$hint" in
                opus|o3)    echo "o3" ;;
                sonnet)     echo "o4-mini" ;;
                haiku)      echo "o4-mini" ;;
                *)          echo "$hint" ;;  # pass through if already an OpenAI model
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Output contract validation (fail-closed: returns non-zero on invalid output)
# ---------------------------------------------------------------------------
# Contracts:
#   findings_json  — JSON array of finding objects with id, severity, title
#   consensus_json — JSON array (same structure, deduplicated)
#   improve_json   — JSON object with .total_cost_usd, .result or .session_id
#   free_text      — any non-empty string (profiler output, fix narratives)
# ---------------------------------------------------------------------------
validate_output() {
    local contract="$1"
    local output="$2"

    if [[ -z "$output" ]]; then
        log_error "Provider returned empty output"
        return 1
    fi

    case "$contract" in
        findings_json|consensus_json)
            # Must be a valid JSON array
            if ! echo "$output" | jq -e 'type == "array"' &>/dev/null; then
                log_error "Output contract '$contract' violated: expected JSON array"
                return 1
            fi
            ;;
        improve_json)
            # Must be valid JSON object
            if ! echo "$output" | jq -e 'type == "object"' &>/dev/null; then
                log_error "Output contract '$contract' violated: expected JSON object"
                return 1
            fi
            ;;
        free_text)
            # Any non-empty string is valid
            return 0
            ;;
        *)
            log_error "Unknown output contract: $contract"
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# invoke_ai — unified provider dispatch with contract enforcement
# ---------------------------------------------------------------------------
# Usage:
#   invoke_ai --provider claude --contract findings_json \
#     --prompt "$prompt" --model opus --budget 3.80 --max-turns 30 \
#     --timeout 900 --system-prompt-file "$file" \
#     --allowlist-arr allowlist_arr --settings "$json" --stderr-file "$f"
#
# On success: prints raw provider result to stdout
# On failure: returns non-zero
# ---------------------------------------------------------------------------
invoke_ai() {
    local provider="" contract="" prompt="" model="" budget="" max_turns=""
    local ai_timeout="" system_prompt_file="" allowlist_arr_name="" settings="" stderr_file=""
    local verbose=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider)             provider="$2"; shift 2 ;;
            --contract)             contract="$2"; shift 2 ;;
            --prompt)               prompt="$2"; shift 2 ;;
            --model)                model="$2"; shift 2 ;;
            --budget)               budget="$2"; shift 2 ;;
            --max-turns)            max_turns="$2"; shift 2 ;;
            --timeout)              ai_timeout="$2"; shift 2 ;;
            --system-prompt-file)   system_prompt_file="$2"; shift 2 ;;
            --allowlist-arr)        allowlist_arr_name="$2"; shift 2 ;;
            --settings)             settings="$2"; shift 2 ;;
            --stderr-file)          stderr_file="$2"; shift 2 ;;
            --verbose)              verbose=true; shift ;;
            *)                      log_error "invoke_ai: unknown flag $1"; return 1 ;;
        esac
    done

    # Defaults
    ai_timeout="${ai_timeout:-600}"
    stderr_file="${stderr_file:-$(mktemp)}"
    local _own_stderr=false
    [[ "$stderr_file" == /tmp/* ]] && _own_stderr=true

    # Resolve model to provider-specific ID
    local resolved_model
    resolved_model=$(resolve_provider_model "$provider" "$model")

    local result
    case "$provider" in
        claude)
            result=$(_invoke_claude "$prompt" "$resolved_model" "$budget" "$max_turns" \
                "$ai_timeout" "$system_prompt_file" "$allowlist_arr_name" "$settings" "$stderr_file" "$verbose") || {
                local rc=$?
                $_own_stderr && rm -f "$stderr_file"
                return $rc
            }
            ;;
        codex)
            result=$(_invoke_codex "$prompt" "$resolved_model" "$budget" "$max_turns" \
                "$ai_timeout" "$system_prompt_file" "$contract" "$stderr_file") || {
                local rc=$?
                $_own_stderr && rm -f "$stderr_file"
                return $rc
            }
            ;;
        *)
            log_error "invoke_ai: unsupported provider '$provider'"
            $_own_stderr && rm -f "$stderr_file"
            return 1
            ;;
    esac

    $_own_stderr && rm -f "$stderr_file"

    # Contract validation (fail-closed)
    if [[ -n "$contract" ]]; then
        # For findings/consensus contracts, validate the extracted content
        # For improve_json, validate the raw result
        case "$contract" in
            findings_json|consensus_json)
                local extracted
                extracted=$(extract_findings_from_result "$provider" "$result")
                if ! validate_output "$contract" "$extracted"; then
                    log_error "Provider '$provider' output failed contract '$contract' — aborting stage"
                    return 1
                fi
                ;;
            improve_json)
                if ! validate_output "$contract" "$result"; then
                    log_error "Provider '$provider' output failed contract '$contract' — aborting stage"
                    return 1
                fi
                ;;
            free_text)
                # Always passes for non-empty
                ;;
        esac
    fi

    echo "$result"
}

# ---------------------------------------------------------------------------
# Extract findings from provider result (provider-aware)
# ---------------------------------------------------------------------------
extract_findings_from_result() {
    local provider="$1"
    local result="$2"

    case "$provider" in
        claude)
            # Uses existing extract_findings from analyze.sh
            extract_findings "$result"
            ;;
        codex)
            # Codex returns JSON directly — extract text content
            local text_content
            text_content=$(echo "$result" | jq -r '
                .message // .output // .result // ""
                | if type == "array" then
                    map(select(.type == "text") | .text) | join("\n")
                  else
                    .
                  end
            ' 2>/dev/null) || text_content=""

            # Try direct JSON array parse
            if echo "$text_content" | jq -e 'type == "array"' &>/dev/null; then
                echo "$text_content"
                return
            fi

            # Fallback: extract first [...] block
            local findings
            findings=$(echo "$text_content" | sed -n '/^\[/,/^\]/p' | head -500)
            if echo "$findings" | jq -e 'type == "array"' &>/dev/null; then
                echo "$findings"
                return
            fi

            # Fallback: code fence extraction
            findings=$(echo "$text_content" | sed -n '/```json/,/```/p' | sed '1d;$d')
            if echo "$findings" | jq -e 'type == "array"' &>/dev/null; then
                echo "$findings"
                return
            fi

            echo "[]"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Claude backend — preserves exact existing behavior
# ---------------------------------------------------------------------------
_invoke_claude() {
    local prompt="$1"
    local model="$2"
    local budget="$3"
    local max_turns="$4"
    local ai_timeout="$5"
    local system_prompt_file="$6"
    local allowlist_arr_name="$7"
    local settings="$8"
    local stderr_file="$9"
    local verbose="${10:-false}"

    # Build command args
    local -a cmd_args=(claude -p "$prompt" --model "$model" --output-format json --no-session-persistence)

    [[ -n "$budget" ]] && cmd_args+=(--max-budget-usd "$budget")
    [[ -n "$max_turns" ]] && cmd_args+=(--max-turns "$max_turns")
    [[ -n "$settings" ]] && cmd_args+=(--settings "$settings")
    [[ -n "$system_prompt_file" ]] && cmd_args+=(--append-system-prompt-file "$system_prompt_file")

    # Expand allowlist array by nameref
    if [[ -n "$allowlist_arr_name" ]]; then
        local -n _al_arr="$allowlist_arr_name"
        cmd_args+=("${_al_arr[@]}")
    fi

    local result
    if [[ "$verbose" == "true" ]]; then
        result=$(timeout "$ai_timeout" "${cmd_args[@]}" \
            2> >(tee "$stderr_file" | while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local short
                short=$(truncate_str "$line" 100)
                echo -e "  ${DIM}${short}${RESET}" >&2
            done)) || {
            local exit_code=$?
            if (( exit_code == 124 )); then
                log_error "Claude timed out after ${ai_timeout}s"
            else
                log_error "Claude invocation failed"
                if [[ -s "$stderr_file" ]]; then
                    log_dim "Last stderr lines:"
                    tail -10 "$stderr_file" | while IFS= read -r line; do
                        log_dim "  $line"
                    done
                fi
            fi
            return 1
        }
    else
        result=$(timeout "$ai_timeout" "${cmd_args[@]}" 2>"$stderr_file") || {
            local exit_code=$?
            if (( exit_code == 124 )); then
                log_error "Claude timed out after ${ai_timeout}s"
            else
                log_error "Claude invocation failed"
                if [[ -s "$stderr_file" ]]; then
                    log_dim "Last stderr lines:"
                    tail -10 "$stderr_file" | while IFS= read -r line; do
                        log_dim "  $line"
                    done
                fi
            fi
            return 1
        }
    fi

    # Validate JSON
    if ! echo "$result" | jq . &>/dev/null; then
        log_error "Claude returned invalid JSON"
        return 1
    fi

    echo "$result"
}

# ---------------------------------------------------------------------------
# Codex backend — strict output handling, fail-closed
# ---------------------------------------------------------------------------
_invoke_codex() {
    local prompt="$1"
    local model="$2"
    local budget="$3"
    local max_turns="$4"
    local ai_timeout="$5"
    local system_prompt_file="$6"
    local contract="$7"
    local stderr_file="$8"

    # Max output bytes (configurable via env, default 512KB)
    local max_output="${KYZN_CODEX_MAX_OUTPUT_BYTES:-524288}"

    # Build command args
    local -a cmd_args=(codex --json -p "$prompt")

    [[ -n "$model" ]] && cmd_args+=(--model "$model")

    # Append system prompt as prefix to the prompt if provided
    # (Codex CLI doesn't have --append-system-prompt-file)
    if [[ -n "$system_prompt_file" && -f "$system_prompt_file" ]]; then
        local sys_content
        sys_content=$(cat "$system_prompt_file")
        local combined_prompt="${sys_content}

---

${prompt}"
        cmd_args=(codex --json -p "$combined_prompt")
        [[ -n "$model" ]] && cmd_args+=(--model "$model")
    fi

    local raw_result
    raw_result=$(timeout "$ai_timeout" "${cmd_args[@]}" 2>"$stderr_file" | head -c "$max_output") || {
        local exit_code=$?
        if (( exit_code == 124 )); then
            log_error "Codex timed out after ${ai_timeout}s"
        else
            log_error "Codex invocation failed (exit code: $exit_code)"
            if [[ -s "$stderr_file" ]]; then
                log_dim "Last stderr lines:"
                tail -10 "$stderr_file" | while IFS= read -r line; do
                    log_dim "  $line"
                done
            fi
        fi
        return 1
    }

    # Check output size — if truncated by head -c, fail closed
    local output_len=${#raw_result}
    if (( output_len >= max_output )); then
        log_error "Codex output exceeded max size (${max_output} bytes) — aborting"
        return 1
    fi

    # Validate JSON
    if ! echo "$raw_result" | jq . &>/dev/null; then
        log_error "Codex returned invalid JSON"
        return 1
    fi

    echo "$raw_result"
}

# ---------------------------------------------------------------------------
# Provider display name (for logs)
# ---------------------------------------------------------------------------
provider_display_name() {
    local provider="$1"
    case "$provider" in
        claude) echo "Claude Code" ;;
        codex)  echo "Codex CLI" ;;
        *)      echo "$provider" ;;
    esac
}
