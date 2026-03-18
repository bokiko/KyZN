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

    # Language-specific bash commands (tightened to specific subcommands)
    case "$project_type" in
        node)
            tools+=(
                '"Bash(npm test*)"'
                '"Bash(npm run *)"'
                '"Bash(npm audit*)"'
                '"Bash(npm ci*)"'
                '"Bash(npm install*)"'
                '"Bash(npx *)"'
            )
            ;;
        python)
            tools+=(
                '"Bash(pip install*)"'
                '"Bash(pip list*)"'
                '"Bash(pytest*)"'
                '"Bash(python -m pytest*)"'
                '"Bash(python -m pip*)"'
                '"Bash(ruff *)"'
                '"Bash(mypy *)"'
            )
            ;;
        rust)
            tools+=(
                '"Bash(cargo check*)"'
                '"Bash(cargo test*)"'
                '"Bash(cargo clippy*)"'
                '"Bash(cargo build*)"'
                '"Bash(cargo audit*)"'
            )
            ;;
        go)
            tools+=(
                '"Bash(go build*)"'
                '"Bash(go test*)"'
                '"Bash(go vet*)"'
                '"Bash(go mod*)"'
            )
            ;;
        generic)
            # Minimal bash access for generic projects
            tools+=(
                '"Bash(ls *)"'
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
