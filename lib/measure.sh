#!/usr/bin/env bash
# kyzn/lib/measure.sh — Measurement dispatcher

# ---------------------------------------------------------------------------
# Run all applicable measurers and collect results
# ---------------------------------------------------------------------------
run_measurements() {
    local project_type="${1:-$KYZN_PROJECT_TYPE}"
    local output_dir="${2:-}"

    if [[ -z "$output_dir" ]]; then
        output_dir=$(mktemp -d)
        KYZN_MEASUREMENTS_DIR="$output_dir"
    fi

    log_header "KyZN measure — analyzing project health"

    local results_file="$output_dir/measurements.json"
    echo '[]' > "$results_file"

    # Always run generic measurer
    log_step "Running generic measurements..."
    run_measurer "$KYZN_ROOT/measurers/generic.sh" "$results_file"

    # Run language-specific measurers
    case "$project_type" in
        node)
            if [[ -f "$KYZN_ROOT/measurers/node.sh" ]]; then
                log_step "Running Node.js measurements..."
                run_measurer "$KYZN_ROOT/measurers/node.sh" "$results_file"
            fi
            ;;
        python)
            if [[ -f "$KYZN_ROOT/measurers/python.sh" ]]; then
                log_step "Running Python measurements..."
                run_measurer "$KYZN_ROOT/measurers/python.sh" "$results_file"
            fi
            ;;
        rust)
            if [[ -f "$KYZN_ROOT/measurers/rust.sh" ]]; then
                log_step "Running Rust measurements..."
                run_measurer "$KYZN_ROOT/measurers/rust.sh" "$results_file"
            fi
            ;;
        go)
            if [[ -f "$KYZN_ROOT/measurers/go.sh" ]]; then
                log_step "Running Go measurements..."
                run_measurer "$KYZN_ROOT/measurers/go.sh" "$results_file"
            fi
            ;;
        csharp)
            if [[ -f "$KYZN_ROOT/measurers/csharp.sh" ]]; then
                log_step "Running C# measurements..."
                run_measurer "$KYZN_ROOT/measurers/csharp.sh" "$results_file"
            fi
            ;;
        java)
            if [[ -f "$KYZN_ROOT/measurers/java.sh" ]]; then
                log_step "Running Java measurements..."
                run_measurer "$KYZN_ROOT/measurers/java.sh" "$results_file"
            fi
            ;;
    esac

    # Compute health score
    compute_health_score "$results_file"

    # Store file path as global
    KYZN_MEASUREMENTS_FILE="$results_file"
}

# ---------------------------------------------------------------------------
# Run a single measurer and append results
# ---------------------------------------------------------------------------
run_measurer() {
    local measurer="$1"
    local results_file="$2"

    if [[ ! -f "$measurer" ]]; then
        log_warn "Measurer not found: $measurer"
        return
    fi

    local output stderr_tmp
    stderr_tmp=$(mktemp)
    output=$(bash "$measurer" 2>"$stderr_tmp") || true

    # Log stderr on failure (was previously discarded with 2>/dev/null)
    if [[ -s "$stderr_tmp" ]]; then
        local measurer_name
        measurer_name=$(basename "$measurer")
        if [[ -z "$output" ]] || ! echo "$output" | jq . &>/dev/null; then
            log_warn "Measurer $measurer_name had errors:"
            head -5 "$stderr_tmp" | while IFS= read -r _line; do
                log_dim "  $_line"
            done
        fi
    fi
    rm -f "$stderr_tmp"

    if [[ -n "$output" ]]; then
        # Validate, check type, and merge in a single jq pass (no tempfile needed)
        local merged
        merged=$(echo "$output" | jq -s --slurpfile existing "$results_file" '
            .[0] as $new |
            if ($new | type) == "array" then $existing[0] + $new
            else $existing[0] + [$new]
            end
        ' 2>/dev/null) || true
        if [[ -n "$merged" ]]; then
            echo "$merged" > "$results_file"
        else
            log_dim "  (no results from $(basename "$measurer"))"
        fi
    else
        log_dim "  (no results from $(basename "$measurer"))"
    fi
}

# ---------------------------------------------------------------------------
# Compute composite health score from measurements
# ---------------------------------------------------------------------------
compute_health_score() {
    local results_file="$1"

    # Default weights (use function to look up)
    _kyzn_weight() {
        local cat="$1"
        # Check config override first
        if has_config; then
            local w
            w=$(config_get ".scoring.weights.$cat" "")
            if [[ -n "$w" ]]; then echo "$w"; return; fi
        fi
        case "$cat" in
            security)      echo 25 ;;
            testing)       echo 25 ;;
            performance)   echo 15 ;;
            quality)       echo 25 ;;
            documentation) echo 10 ;;
            *)             echo 10 ;;
        esac
    }

    # Calculate per-category averages using jq, then weighted score
    local category_scores
    category_scores=$(jq '[.[] | {category, score, max_score}]
        | group_by(.category)
        | map({
            key: .[0].category,
            value: (([.[].score] | add) * 100 / ([.[].max_score] | add))
          })
        | from_entries' "$results_file" 2>/dev/null) || category_scores='{}'

    local total_score=0
    local total_weight=0

    # Read all weights upfront to avoid spawning yq once per category
    local w_security w_testing w_performance w_quality w_documentation
    w_security=$(_kyzn_weight security)
    w_testing=$(_kyzn_weight testing)
    w_performance=$(_kyzn_weight performance)
    w_quality=$(_kyzn_weight quality)
    w_documentation=$(_kyzn_weight documentation)

    for cat in security testing performance quality documentation; do
        local pct
        pct=$(echo "$category_scores" | jq -r --arg c "$cat" '.[$c] // empty')
        if [[ -n "$pct" ]]; then
            local weight
            case "$cat" in
                security)      weight=$w_security ;;
                testing)       weight=$w_testing ;;
                performance)   weight=$w_performance ;;
                quality)       weight=$w_quality ;;
                documentation) weight=$w_documentation ;;
            esac
            # jq may return floats, round properly
            local pct_int
            pct_int=$(printf '%.0f' "$pct" 2>/dev/null || echo "${pct%.*}")
            total_score=$(( total_score + (pct_int * weight) ))
            total_weight=$(( total_weight + weight ))
        fi
    done

    local health=0
    if (( total_weight > 0 )); then
        health=$(( total_score / total_weight ))
    fi

    # Store health score
    KYZN_HEALTH_SCORE=$health
    KYZN_CATEGORY_SCORES="$category_scores"
}

# ---------------------------------------------------------------------------
# Display health score dashboard
# ---------------------------------------------------------------------------
display_health_dashboard() {
    local results_file="${1:-}"
    local health="${KYZN_HEALTH_SCORE:-0}"
    local empty_json='{}'
    local scores="${KYZN_CATEGORY_SCORES:-$empty_json}"

    echo ""
    log_header "Project Health Score"

    # Color based on score
    local color
    if (( health >= 80 )); then
        color="$GREEN"
    elif (( health >= 50 )); then
        color="$YELLOW"
    else
        color="$RED"
    fi

    # Big score display
    echo -e "  ${BOLD}${color}${health}${RESET}${BOLD} / 100${RESET}"
    echo ""

    # Category breakdown
    echo -e "${BOLD}Categories:${RESET}"

    # Extract all category scores in a single jq call (one TSV row per present category)
    local _cat_tsv
    _cat_tsv=$(printf '%s' "$scores" | jq -r '
        [
            ["security",      (.security      // empty | tostring)],
            ["testing",       (.testing       // empty | tostring)],
            ["performance",   (.performance   // empty | tostring)],
            ["quality",       (.quality       // empty | tostring)],
            ["documentation", (.documentation // empty | tostring)]
        ][] | select(.[1] != "") | @tsv
    ' 2>/dev/null) || true

    while IFS=$'\t' read -r cat cat_score; do
        [[ -z "$cat_score" ]] && continue
        local bar=""
        local cs_int="${cat_score%%.*}"
        cs_int="${cs_int:-0}"
        local filled=$(( cs_int / 5 ))
        local empty=$(( 20 - filled ))

        # Color per score
        if (( cs_int >= 80 )); then
            color="$GREEN"
        elif (( cs_int >= 50 )); then
            color="$YELLOW"
        else
            color="$RED"
        fi

        printf -v bar '%*s' "$filled" ''
        bar="${bar// /█}"
        local bar_empty
        printf -v bar_empty '%*s' "$empty" ''
        bar_empty="${bar_empty// /░}"

        printf "  %-15s ${color}%s%s${RESET} %3d%%\n" "$cat" "$bar" "$bar_empty" "$cs_int"
    done <<< "$_cat_tsv"
    echo ""
}

# ---------------------------------------------------------------------------
# cmd_measure — measure only, no changes
# ---------------------------------------------------------------------------
cmd_measure() {
    require_git_repo
    detect_project_type
    detect_project_features
    print_detection

    # run_measurements sets KYZN_HEALTH_SCORE, KYZN_CATEGORY_SCORES, KYZN_MEASUREMENTS_FILE
    run_measurements "$KYZN_PROJECT_TYPE"

    display_health_dashboard "$KYZN_MEASUREMENTS_FILE"

    # Show weakest area
    local weakest
    local empty='{}'
    weakest=$(printf '%s' "${KYZN_CATEGORY_SCORES:-$empty}" | jq -r 'to_entries | sort_by(.value) | .[0].key // empty')

    if [[ -n "$weakest" ]]; then
        local weakest_score
        weakest_score=$(echo "$KYZN_CATEGORY_SCORES" | jq -r --arg c "$weakest" '.[$c]')
        log_info "Weakest area: ${BOLD}$weakest${RESET} ($weakest_score%)"
        echo -e "  Run ${CYAN}kyzn fix${RESET} for deep analysis + auto-fix."
        echo -e "  Run ${CYAN}kyzn analyze${RESET} for a report without changes."
    fi

    # Write history entry for measure
    ensure_kyzn_dirs
    declare -A _hist=([health_score]="${KYZN_HEALTH_SCORE:-0}")
    write_history "measure-$(date +%Y%m%d-%H%M%S)" "measure" "completed" _hist

    # Clean up temp measurement dir created by run_measurements (if any)
    [[ -d "${KYZN_MEASUREMENTS_DIR:-}" ]] && rm -rf "$KYZN_MEASUREMENTS_DIR" 2>/dev/null || true
    KYZN_MEASUREMENTS_DIR=""
}
