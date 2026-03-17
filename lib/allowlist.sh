#!/usr/bin/env bash
# kyzn/lib/allowlist.sh — Per-language tool allowlist definitions

# ---------------------------------------------------------------------------
# Build Claude Code --allowedTools flags for a project type
# ---------------------------------------------------------------------------
build_allowlist() {
    local project_type="$1"

    # Always-allowed tools
    local -a tools=(
        "Read"
        "Edit"
        "Write"
        "Glob"
        "Grep"
    )

    # Language-specific bash commands
    case "$project_type" in
        node)
            tools+=(
                '"Bash(npm *)"'
                '"Bash(npx *)"'
                '"Bash(node *)"'
            )
            ;;
        python)
            tools+=(
                '"Bash(pip *)"'
                '"Bash(pytest *)"'
                '"Bash(ruff *)"'
                '"Bash(mypy *)"'
                '"Bash(python *)"'
            )
            ;;
        rust)
            tools+=(
                '"Bash(cargo *)"'
            )
            ;;
        go)
            tools+=(
                '"Bash(go *)"'
            )
            ;;
        generic)
            # Minimal bash access for generic projects
            tools+=(
                '"Bash(ls *)"'
                '"Bash(cat *)"'
                '"Bash(wc *)"'
            )
            ;;
    esac

    # Build the flag string
    local flags=""
    for tool in "${tools[@]}"; do
        flags+="--allowedTools $tool "
    done

    echo "$flags"
}
