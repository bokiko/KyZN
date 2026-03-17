#!/usr/bin/env bash
# kyzn/lib/prompt.sh — Prompt assembly pipeline

# ---------------------------------------------------------------------------
# Assemble the full prompt for Claude Code
# ---------------------------------------------------------------------------
assemble_prompt() {
    local measurements_file="$1"
    local mode="${2:-deep}"
    local focus="${3:-auto}"
    local project_type="${4:-$KYZN_PROJECT_TYPE}"

    local prompt=""

    # Load base improvement prompt template
    local template="$KYZN_ROOT/templates/improvement-prompt.md"
    if [[ -f "$template" ]]; then
        prompt=$(cat "$template")
    else
        prompt="Improve this codebase."
    fi

    # Replace placeholders
    prompt="${prompt//\{\{PROJECT_NAME\}\}/$(project_name)}"
    prompt="${prompt//\{\{PROJECT_TYPE\}\}/$(project_type_name "$project_type")}"
    prompt="${prompt//\{\{MODE\}\}/$mode}"
    prompt="${prompt//\{\{FOCUS\}\}/$focus}"

    # Inject measurements
    local measurements_json
    measurements_json=$(cat "$measurements_file" 2>/dev/null || echo '[]')
    prompt="${prompt//\{\{MEASUREMENTS\}\}/$measurements_json}"

    # Inject health score
    prompt="${prompt//\{\{HEALTH_SCORE\}\}/${KYZN_HEALTH_SCORE:-0}}"

    # Inject mode-specific constraints
    local mode_constraints=""
    case "$mode" in
        deep)
            mode_constraints="IMPORTANT CONSTRAINTS:
- Make REAL improvements only: fix bugs, add error handling, improve performance, add tests for uncovered paths
- Do NOT: rename variables for style, add comments, reformat code, reorganize imports
- Every change must have measurable impact on code quality, security, or reliability"
            ;;
        clean)
            mode_constraints="FOCUS ON CLEANUP:
- Remove dead code, unused imports, unused variables
- Fix naming inconsistencies
- Improve documentation and docstrings
- Organize imports and file structure
- Do NOT change behavior or add new features"
            ;;
        full)
            mode_constraints="FULL IMPROVEMENT MODE:
- Both real improvements AND cleanup are welcome
- Prioritize high-impact changes first
- Fix bugs, add error handling, improve tests, AND clean up code"
            ;;
    esac
    prompt="${prompt//\{\{MODE_CONSTRAINTS\}\}/$mode_constraints}"

    echo "$prompt"
}

# ---------------------------------------------------------------------------
# Get the system prompt file path
# ---------------------------------------------------------------------------
get_system_prompt() {
    local profile="${1:-}"
    local sys_prompt="$KYZN_ROOT/templates/system-prompt.md"

    if [[ -n "$profile" && -f "$KYZN_ROOT/profiles/$profile.md" ]]; then
        # Combine system prompt with profile
        local combined
        combined=$(mktemp)
        cat "$sys_prompt" > "$combined"
        echo "" >> "$combined"
        echo "---" >> "$combined"
        echo "" >> "$combined"
        cat "$KYZN_ROOT/profiles/$profile.md" >> "$combined"
        echo "$combined"
    else
        echo "$sys_prompt"
    fi
}
