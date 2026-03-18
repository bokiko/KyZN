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
    fi

    log_header "kyzn measure — analyzing project health"

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

    local output
    output=$(bash "$measurer" 2>/dev/null) || true

    if [[ -n "$output" ]] && echo "$output" | jq . &>/dev/null; then
        # Measurer may return a single object or array of objects
        local merged
        if echo "$output" | jq -e 'type == "array"' &>/dev/null; then
            merged=$(jq -s '.[0] + .[1]' "$results_file" <(echo "$output"))
        else
            merged=$(jq -s '.[0] + [.[1]]' "$results_file" <(echo "$output"))
        fi
        echo "$merged" > "$results_file"
    else
        log_dim "  (no results from $(basename "$measurer"))"
    fi
}

# ---------------------------------------------------------------------------
# Compute composite health score from measurements
# ---------------------------------------------------------------------------
compute_health_score() {
    local results_file="$1"

    # Default weights
    local -A weights=(
        ["security"]=25
        ["testing"]=25
        ["performance"]=15
        ["quality"]=25
        ["documentation"]=10
    )

    # Override with config if available
    if has_config; then
        for cat in security testing performance quality documentation; do
            local w
            w=$(config_get ".scoring.weights.$cat" "")
            if [[ -n "$w" ]]; then
                weights[$cat]=$w
            fi
        done
    fi

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

    for cat in security testing performance quality documentation; do
        local pct
        pct=$(echo "$category_scores" | jq -r --arg c "$cat" '.[$c] // empty')
        if [[ -n "$pct" ]]; then
            local weight=${weights[$cat]:-10}
            # jq may return floats, truncate
            local pct_int=${pct%.*}
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

    local categories=("security" "testing" "performance" "quality" "documentation")
    for cat in "${categories[@]}"; do
        local cat_score
        cat_score=$(printf '%s' "$scores" | jq -r --arg c "$cat" '.[$c] // empty')

        if [[ -n "$cat_score" ]]; then
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
        fi
    done
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
        echo -e "  Run ${CYAN}kyzn improve --focus $weakest${RESET} to improve it."
    fi
}
