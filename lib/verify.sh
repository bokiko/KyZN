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
                # Capture both FAILED (assertion errors) and ERROR (collection/import errors)
                # ERR: prefix on ERROR lines prevents cross-format matching in grep -qF comparisons
                failures=$(pytest --tb=no -q 2>&1 \
                    | grep -E '^(FAILED |ERROR )' \
                    | sed -E 's/^ERROR (collecting )?/ERR:/; s/^FAILED //' \
                    | sort -u) || true
            fi
            ;;
        node)
            if [[ -f "package.json" ]] && jq -e '.scripts.test' package.json &>/dev/null 2>&1; then
                failures=$(CI=true timeout 300 npm test 2>&1 | grep -E '(FAIL |✕ |✗ |× )' | sort) || true
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
        csharp)
            if command -v dotnet &>/dev/null; then
                failures=$(dotnet test --nologo --verbosity quiet 2>&1 \
                    | grep -E '^\s*(Failed|X) ' | sort -u) || true
            fi
            ;;
        java)
            if [[ "${KYZN_JAVA_BUILD:-}" == "maven" ]] && command -v mvn &>/dev/null; then
                failures=$(mvn -q test 2>&1 \
                    | grep -E '^\[ERROR\] (Failures:|Errors:|Tests run:.*FAILURE)' \
                    | sort -u) || true
            elif [[ "${KYZN_JAVA_BUILD:-}" == "gradle" ]]; then
                local _gw="gradle"
                [[ -x "./gradlew" ]] && _gw="./gradlew"
                if [[ "$_gw" == "./gradlew" ]] || command -v gradle &>/dev/null; then
                    failures=$($_gw test 2>&1 \
                        | grep -E '(FAILED$|^.*> .*FAILED$)' | sort -u) || true
                fi
            fi
            ;;
    esac

    echo "$failures"
}

# ---------------------------------------------------------------------------
# Gate: check new test files for import errors (Python only)
# Populates a variable with --ignore flags for broken test files
# Usage: gate_new_test_files MY_VAR  →  MY_VAR="--ignore=bad1.py --ignore=bad2.py"
# ---------------------------------------------------------------------------
KYZN_PYTEST_EXTRA_ARGS=""

verify_install_deps_enabled() {
    if [[ "${KYZN_VERIFY_INSTALL_DEPS:-false}" == "true" ]]; then
        return 0
    fi

    if [[ "$(config_get '.verification.install_deps' 'false')" == "true" ]]; then
        return 0
    fi

    return 1
}

install_node_dependencies() {
    [[ -f "package.json" && ! -d "node_modules" ]] || return 0

    log_step "Installing Node dependencies..."
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

    [[ -d "node_modules" ]] && log_ok "Dependencies installed" || log_warn "Dependency install may have failed"
}

install_python_dependencies() {
    [[ ! -d ".venv" && ! -d "venv" ]] || return 0

    if [[ -f "pyproject.toml" ]] && command -v uv &>/dev/null; then
        log_step "Installing Python dependencies (uv sync)..."
        uv sync --quiet 2>&1 | tail -3
        [[ -d ".venv" ]] && log_ok "Dependencies installed" || log_warn "uv sync may have failed"
    elif [[ -f "requirements.txt" ]]; then
        log_step "Installing Python dependencies (pip)..."
        python3 -m venv .venv 2>/dev/null
        .venv/bin/pip install -q -r requirements.txt 2>&1 | tail -3
        log_ok "Dependencies installed"
    fi
}

install_project_dependencies() {
    case "${KYZN_PROJECT_TYPE:-generic}" in
        node)   install_node_dependencies ;;
        python) install_python_dependencies ;;
        *)      log_info "No dependency installer for ${KYZN_PROJECT_TYPE:-generic} projects." ;;
    esac
}

gate_new_test_files() {
    local _var_flags="${1:-}"
    local project_type="${KYZN_PROJECT_TYPE:-generic}"
    KYZN_PYTEST_EXTRA_ARGS=""  # reset between calls

    [[ "$project_type" != "python" ]] && return 0
    command -v pytest &>/dev/null || return 0

    local new_tests ignore_list=""
    new_tests=$(git ls-files --others --exclude-standard 2>/dev/null \
        | grep -E '(test_.*\.py$|.*_test\.py$)') || true
    [[ -z "$new_tests" ]] && return 0

    while IFS= read -r tf; do
        [[ -z "$tf" ]] && continue
        if ! pytest --collect-only "$tf" &>/dev/null; then
            log_warn "New test file has import errors: $tf (excluding from test run)"
            ignore_list+=" --ignore=$tf"
        fi
    done <<< "$new_tests"

    if [[ -n "$ignore_list" ]]; then
        KYZN_PYTEST_EXTRA_ARGS="$ignore_list"
        [[ -n "$_var_flags" ]] && printf -v "$_var_flags" '%s' "$ignore_list"
    fi
}

# ---------------------------------------------------------------------------
# Verify build and tests pass
# ---------------------------------------------------------------------------
verify_build() {
    local project_type="${KYZN_PROJECT_TYPE:-generic}"

    log_header "KyZN verify — checking build & tests"

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
        csharp)
            verify_csharp || build_ok=false
            ;;
        java)
            verify_java || build_ok=false
            ;;
        generic)
            # Best-effort: check for common build systems
            if [[ -f "Makefile" ]]; then
                log_step "Running make check (Makefile detected)..."
                make check 2>/dev/null || make test 2>/dev/null || {
                    log_warn "make check/test failed — treating as verification failure"
                    build_ok=false
                }
            else
                log_warn "Generic project — no build system detected, skipping verification"
            fi
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

    if [[ -f "package.json" && ! -d "node_modules" ]]; then
        if verify_install_deps_enabled; then
            log_step "Installing dependencies (node_modules not found, install_deps enabled)..."
            install_node_dependencies
        else
            log_warn "node_modules not found — skipping dependency install by default"
            log_dim "  Set verification.install_deps: true or KYZN_VERIFY_INSTALL_DEPS=true to opt in."
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
        local test_output test_exit
        # CI=true disables vitest/jest watch mode; timeout guards against hangs
        test_output=$(CI=true timeout 300 npm test 2>&1) || test_exit=$?
        test_exit=${test_exit:-0}

        # vitest exits 1 with "No test files found" — treat as pass (no tests to fail)
        if (( test_exit != 0 )); then
            if echo "$test_output" | grep -q "No test files found"; then
                log_info "No test files found — skipping test verification"
            else
                echo "$test_output" | tail -10
                log_error "Tests failed"
                ok=false
            fi
        else
            echo "$test_output" | tail -10
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

    if [[ ! -d ".venv" && ! -d "venv" ]]; then
        if verify_install_deps_enabled; then
            install_python_dependencies
        elif [[ -f "pyproject.toml" || -f "requirements.txt" ]]; then
            log_warn "Python dependencies not installed — skipping dependency install by default"
            log_dim "  Set verification.install_deps: true or KYZN_VERIFY_INSTALL_DEPS=true to opt in."
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

    # pytest (with optional --ignore flags from gate_new_test_files)
    if command -v pytest &>/dev/null && [[ -d "tests" || -f "conftest.py" ]]; then
        log_step "Running pytest..."
        local -a pytest_args=()
        if [[ -n "${KYZN_PYTEST_EXTRA_ARGS:-}" ]]; then
            read -ra pytest_args <<< "$KYZN_PYTEST_EXTRA_ARGS"
        fi
        if ! pytest "${pytest_args[@]}" 2>&1 | tail -10; then
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

# ---------------------------------------------------------------------------
# C# / .NET verification
# ---------------------------------------------------------------------------
verify_csharp() {
    local ok=true

    if command -v dotnet &>/dev/null; then
        log_step "Running dotnet build..."
        if ! dotnet build --nologo -v quiet 2>&1 | tail -20; then
            log_error "Build failed"
            ok=false
        else
            log_ok "Build passed"
        fi

        log_step "Running dotnet test..."
        if ! dotnet test --nologo --verbosity quiet 2>&1 | tail -20; then
            log_error "Tests failed"
            ok=false
        else
            log_ok "Tests passed"
        fi
    fi

    $ok
}

# ---------------------------------------------------------------------------
# Java / JVM verification (Maven or Gradle, dispatched on KYZN_JAVA_BUILD)
# ---------------------------------------------------------------------------
verify_java() {
    local ok=true
    local build="${KYZN_JAVA_BUILD:-}"

    if [[ "$build" == "maven" ]] && command -v mvn &>/dev/null; then
        log_step "Running mvn compile..."
        if ! mvn -q compile 2>&1 | tail -20; then
            log_error "Build failed"
            ok=false
        else
            log_ok "Build passed"
        fi

        log_step "Running mvn test..."
        if ! mvn -q test 2>&1 | tail -20; then
            log_error "Tests failed"
            ok=false
        else
            log_ok "Tests passed"
        fi
    elif [[ "$build" == "gradle" ]]; then
        local gw="gradle"
        [[ -x "./gradlew" ]] && gw="./gradlew"

        if [[ "$gw" == "./gradlew" ]] || command -v gradle &>/dev/null; then
            log_step "Running $gw build -x test..."
            if ! $gw build -x test 2>&1 | tail -20; then
                log_error "Build failed"
                ok=false
            else
                log_ok "Build passed"
            fi

            log_step "Running $gw test..."
            if ! $gw test 2>&1 | tail -20; then
                log_error "Tests failed"
                ok=false
            else
                log_ok "Tests passed"
            fi
        fi
    fi

    $ok
}
