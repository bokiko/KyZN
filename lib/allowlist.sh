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

    # Language-specific bash commands
    # SECURITY NOTE: Glob '*' matches shell metacharacters (;, &&, |).
    # Only use trailing '*' where subcommand args are genuinely needed.
    # Prompt injection mitigation (sanitized inputs) is the primary defense.
    case "$project_type" in
        node)
            _al_arr+=(
                --allowedTools 'Bash(npm test*)'
                --allowedTools 'Bash(npm run *)'
                --allowedTools 'Bash(npm audit)'
                --allowedTools 'Bash(npm audit fix)'
                --allowedTools 'Bash(npm ci)'
                --allowedTools 'Bash(npx eslint*)'
                --allowedTools 'Bash(npx tsc*)'
                --allowedTools 'Bash(npx vitest*)'
                --allowedTools 'Bash(npx jest*)'
                --allowedTools 'Bash(npx prettier*)'
            )
            ;;
        python)
            _al_arr+=(
                --allowedTools 'Bash(pip list)'
                --allowedTools 'Bash(pytest*)'
                --allowedTools 'Bash(python -m pytest*)'
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
                --allowedTools 'Bash(cargo audit)'
            )
            ;;
        go)
            _al_arr+=(
                --allowedTools 'Bash(go build*)'
                --allowedTools 'Bash(go test*)'
                --allowedTools 'Bash(go vet*)'
                --allowedTools 'Bash(go mod tidy)'
                --allowedTools 'Bash(go mod download)'
            )
            ;;
        generic)
            # Minimal read-only bash access for generic projects
            _al_arr+=(
                --allowedTools 'Bash(ls)'
                --allowedTools 'Bash(ls -*)'
                --allowedTools 'Bash(wc -l *)'
            )
            ;;
    esac
}
