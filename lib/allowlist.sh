#!/usr/bin/env bash
# kyzn/lib/allowlist.sh — Per-language tool allowlist definitions

# ---------------------------------------------------------------------------
# Build Claude Code --allowedTools flags for a project type
# Usage: build_allowlist <array_nameref> <project_type>
# ---------------------------------------------------------------------------
build_allowlist() {
    local -n _al_arr=$1
    local project_type="$2"

    # Always-allowed tools
    _al_arr=(
        --allowedTools Read
        --allowedTools Edit
        --allowedTools Write
        --allowedTools Glob
        --allowedTools Grep
    )

    # Language-specific bash commands (tightened to specific subcommands)
    case "$project_type" in
        node)
            _al_arr+=(
                --allowedTools 'Bash(npm test*)'
                --allowedTools 'Bash(npm run *)'
                --allowedTools 'Bash(npm audit*)'
                --allowedTools 'Bash(npm ci*)'
                --allowedTools 'Bash(npm install*)'
                --allowedTools 'Bash(npx eslint*)'
                --allowedTools 'Bash(npx tsc*)'
                --allowedTools 'Bash(npx vitest*)'
                --allowedTools 'Bash(npx jest*)'
                --allowedTools 'Bash(npx prettier*)'
            )
            ;;
        python)
            _al_arr+=(
                --allowedTools 'Bash(pip install*)'
                --allowedTools 'Bash(pip list*)'
                --allowedTools 'Bash(pytest*)'
                --allowedTools 'Bash(python -m pytest*)'
                --allowedTools 'Bash(python -m pip*)'
                --allowedTools 'Bash(ruff *)'
                --allowedTools 'Bash(mypy *)'
            )
            ;;
        rust)
            _al_arr+=(
                --allowedTools 'Bash(cargo check*)'
                --allowedTools 'Bash(cargo test*)'
                --allowedTools 'Bash(cargo clippy*)'
                --allowedTools 'Bash(cargo build*)'
                --allowedTools 'Bash(cargo audit*)'
            )
            ;;
        go)
            _al_arr+=(
                --allowedTools 'Bash(go build*)'
                --allowedTools 'Bash(go test*)'
                --allowedTools 'Bash(go vet*)'
                --allowedTools 'Bash(go mod*)'
            )
            ;;
        generic)
            # Minimal bash access for generic projects
            _al_arr+=(
                --allowedTools 'Bash(ls *)'
                --allowedTools 'Bash(wc *)'
            )
            ;;
    esac
}
