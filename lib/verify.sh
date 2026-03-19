#!/usr/bin/env bash
# kyzn/lib/verify.sh — Build/test verification

# ---------------------------------------------------------------------------
# Capture failing test names (for pre-existing failure comparison)
# Returns newline-separated list of FAILED test identifiers
# ---------------------------------------------------------------------------
capture_failing_tests() {
    local project_type="${KYZN_PROJECT_TYPE:-generic}"
    local failures=""

    case "$project_type" in
        python)
            if command -v pytest &>/dev/null && [[ -d "tests" || -f "conftest.py" ]]; then
                failures=$(pytest --tb=no -q 2>&1 | grep '^FAILED ' | sed 's/^FAILED //' | sort) || true
            fi
            ;;
        node)
            if [[ -f "package.json" ]] && jq -e '.scripts.test' package.json &>/dev/null 2>&1; then
                failures=$(npm test 2>&1 | grep -E '(FAIL |✕ |✗ |× )' | sort) || true
            fi
            ;;
        rust)
            if command -v cargo &>/dev/null; then
                failures=$(cargo test 2>&1 | grep '^test .* FAILED$' | sort) || true
            fi
            ;;
        go)
            if command -v go &>/dev/null; then
                failures=$(go test ./... 2>&1 | grep '^--- FAIL:' | sort) || true
            fi
            ;;
    esac

    echo "$failures"
}

# ---------------------------------------------------------------------------
# Verify build and tests pass
# ---------------------------------------------------------------------------
verify_build() {
    local project_type="${KYZN_PROJECT_TYPE:-generic}"

    log_header "kyzn verify — checking build & tests"

    local build_ok=true
    # tests_ok reserved for future per-step tracking

    case "$project_type" in
        node)
            verify_node || build_ok=false
            ;;
        python)
            verify_python || build_ok=false
            ;;
        rust)
            verify_rust || build_ok=false
            ;;
        go)
            verify_go || build_ok=false
            ;;
        generic)
            log_info "Generic project — skipping language-specific verification"
            ;;
    esac

    if $build_ok; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Node.js verification
# ---------------------------------------------------------------------------
verify_node() {
    local ok=true

    # Auto-install dependencies if node_modules is missing
    if [[ -f "package.json" && ! -d "node_modules" ]]; then
        log_step "Installing dependencies (node_modules not found)..."
        if [[ -f "package-lock.json" ]]; then
            npm ci --silent 2>&1 | tail -3 || npm install --silent 2>&1 | tail -3
        elif [[ -f "yarn.lock" ]]; then
            yarn install --frozen-lockfile --silent 2>&1 | tail -3
        elif [[ -f "pnpm-lock.yaml" ]]; then
            pnpm install --frozen-lockfile --silent 2>&1 | tail -3
        elif [[ -f "bun.lockb" ]]; then
            bun install --frozen-lockfile 2>&1 | tail -3
        else
            npm install --silent 2>&1 | tail -3
        fi

        if [[ -d "node_modules" ]]; then
            log_ok "Dependencies installed"
        else
            log_warn "Dependency install may have failed — continuing anyway"
        fi
    fi

    # Check if build script exists
    if [[ -f "package.json" ]] && jq -e '.scripts.build' package.json &>/dev/null; then
        log_step "Running npm build..."
        if ! npm run build 2>&1 | tail -20; then
            log_error "Build failed"
            ok=false
        else
            log_ok "Build passed"
        fi
    fi

    # TypeScript check
    if [[ -f "tsconfig.json" ]] && command -v npx &>/dev/null; then
        log_step "Running TypeScript check..."
        if ! npx tsc --noEmit 2>&1 | tail -20; then
            log_error "TypeScript check failed"
            ok=false
        else
            log_ok "TypeScript check passed"
        fi
    fi

    # Run tests
    if jq -e '.scripts.test' package.json &>/dev/null 2>&1; then
        log_step "Running tests..."
        if ! npm test 2>&1 | tail -10; then
            log_error "Tests failed"
            ok=false
        else
            log_ok "Tests passed"
        fi
    fi

    $ok
}

# ---------------------------------------------------------------------------
# Python verification
# ---------------------------------------------------------------------------
verify_python() {
    local ok=true

    # Auto-install dependencies if no venv and project has deps
    if [[ ! -d ".venv" && ! -d "venv" ]]; then
        if [[ -f "pyproject.toml" ]] && command -v uv &>/dev/null; then
            log_step "Installing dependencies (uv sync)..."
            uv sync --quiet 2>&1 | tail -3
            [[ -d ".venv" ]] && log_ok "Dependencies installed" || log_warn "uv sync may have failed"
        elif [[ -f "requirements.txt" ]]; then
            log_step "Installing dependencies (pip)..."
            python3 -m venv .venv 2>/dev/null
            .venv/bin/pip install -q -r requirements.txt 2>&1 | tail -3
            log_ok "Dependencies installed"
        fi
    fi

    # Ruff check
    if command -v ruff &>/dev/null; then
        log_step "Running ruff check..."
        if ! ruff check . 2>&1 | tail -20; then
            log_warn "Ruff found issues (non-blocking)"
        else
            log_ok "Ruff check passed"
        fi
    fi

    # Mypy
    if command -v mypy &>/dev/null; then
        log_step "Running mypy..."
        if ! mypy . 2>&1 | tail -20; then
            log_warn "Mypy found issues (non-blocking)"
        else
            log_ok "Mypy check passed"
        fi
    fi

    # pytest
    if command -v pytest &>/dev/null && [[ -d "tests" || -f "conftest.py" ]]; then
        log_step "Running pytest..."
        if ! pytest 2>&1 | tail -10; then
            log_error "Tests failed"
            ok=false
        else
            log_ok "Tests passed"
        fi
    fi

    $ok
}

# ---------------------------------------------------------------------------
# Rust verification
# ---------------------------------------------------------------------------
verify_rust() {
    local ok=true

    if command -v cargo &>/dev/null; then
        log_step "Running cargo check..."
        if ! cargo check 2>&1 | tail -20; then
            log_error "Build failed"
            ok=false
        else
            log_ok "Build passed"
        fi

        log_step "Running cargo test..."
        if ! cargo test 2>&1 | tail -10; then
            log_error "Tests failed"
            ok=false
        else
            log_ok "Tests passed"
        fi
    fi

    $ok
}

# ---------------------------------------------------------------------------
# Go verification
# ---------------------------------------------------------------------------
verify_go() {
    local ok=true

    if command -v go &>/dev/null; then
        log_step "Running go build..."
        if ! go build ./... 2>&1 | tail -20; then
            log_error "Build failed"
            ok=false
        else
            log_ok "Build passed"
        fi

        log_step "Running go test..."
        if ! go test ./... 2>&1 | tail -10; then
            log_error "Tests failed"
            ok=false
        else
            log_ok "Tests passed"
        fi

        log_step "Running go vet..."
        if ! go vet ./... 2>&1 | tail -20; then
            log_warn "go vet found issues (non-blocking)"
        else
            log_ok "go vet passed"
        fi
    fi

    $ok
}
