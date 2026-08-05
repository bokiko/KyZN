#!/usr/bin/env bash
# kyzn/lib/verify.sh — Build/test verification

# ---------------------------------------------------------------------------
# Verification outcome — three states, not two
#
# "The tool isn't installed" is NOT the same as "the build passed". Treating
# them alike lets KyZN open a PR certifying changes it never actually checked.
# verify_build therefore returns:
#   0 — passed        checks ran, everything green
#   1 — failed        checks ran, something is broken
#   2 — not executed  a required tool is unavailable (see KYZN_VERIFY_STATUS)
#
# Callers that mutate the repo (commit / push / PR) must treat 2 as a hard stop.
# ---------------------------------------------------------------------------
KYZN_VERIFY_RC_UNAVAILABLE=2
KYZN_VERIFY_STATUS="passed"
KYZN_VERIFY_UNAVAILABLE_REASON=""

# Record that a required check could not be run. Does not mark the build failed —
# verify_build maps the status to exit code 2 once every check has been attempted.
verify_unavailable() {
    local reason="$1"
    KYZN_VERIFY_STATUS="unavailable"
    if [[ -n "$KYZN_VERIFY_UNAVAILABLE_REASON" ]]; then
        KYZN_VERIFY_UNAVAILABLE_REASON+="; $reason"
    else
        KYZN_VERIFY_UNAVAILABLE_REASON="$reason"
    fi
    log_warn "Verification not executed: $reason"
}

# True when a verify_build exit code means "was not executed".
verify_not_executed() {
    (( ${1:-0} == KYZN_VERIFY_RC_UNAVAILABLE ))
}

# Resolve a Python tool, preferring the project's own virtualenv so KyZN works
# without the venv being activated (the opt-in installer creates .venv, which a
# bare `command -v` would never see). Echoes the command; returns 1 if absent.
_kyzn_python_tool() {
    local name="$1" p
    for p in ".venv/bin/$name" "venv/bin/$name"; do
        if [[ -x "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    command -v "$name" 2>/dev/null && return 0
    return 1
}

# True when the project ships tests that verification is expected to run.
#
# Must agree with what KyZN already treats as tests elsewhere, or those layouts
# score a green verify with no runner: detect.sh counts test/ and pytest.ini,
# and gate_new_test_files recognises root-level test_*.py / *_test.py.
# Deliberately shallow — standard directories plus root globs, no recursive scan.
_kyzn_python_has_tests() {
    if [[ -d "tests" || -d "test" || -f "conftest.py" || -f "pytest.ini" ]]; then
        return 0
    fi
    if compgen -G "test_*.py" >/dev/null 2>&1; then
        return 0
    fi
    if compgen -G "*_test.py" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Capture failing test names (for pre-existing failure comparison)
# Returns newline-separated list of FAILED test identifiers
# ---------------------------------------------------------------------------
capture_failing_tests() {
    local project_type="${KYZN_PROJECT_TYPE:-generic}"
    local failures=""

    case "$project_type" in
        python)
            local _pytest
            if _pytest=$(_kyzn_python_tool pytest) && _kyzn_python_has_tests; then
                # Capture both FAILED (assertion errors) and ERROR (collection/import errors)
                # ERR: prefix on ERROR lines prevents cross-format matching in grep -qF comparisons
                failures=$("$_pytest" --tb=no -q 2>&1 \
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
    local _pytest
    _pytest=$(_kyzn_python_tool pytest) || return 0

    local new_tests ignore_list=""
    new_tests=$(git ls-files --others --exclude-standard 2>/dev/null \
        | grep -E '(test_.*\.py$|.*_test\.py$)') || true
    [[ -z "$new_tests" ]] && return 0

    while IFS= read -r tf; do
        [[ -z "$tf" ]] && continue
        if ! "$_pytest" --collect-only "$tf" &>/dev/null; then
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

    # Reset outcome tracking — verify_build is called repeatedly within a run
    KYZN_VERIFY_STATUS="passed"
    KYZN_VERIFY_UNAVAILABLE_REASON=""

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

    # "Could not check" OUTRANKS "check failed" for the authorization decision.
    # A failure is the more actionable message, but it must not downgrade the
    # verdict: if any required check did not execute, the run stays ineligible
    # for commit/push/PR no matter what else happened. Failure detail is still
    # reported — it just does not win the decision.
    if [[ "$KYZN_VERIFY_STATUS" == "unavailable" ]]; then
        if ! $build_ok; then
            log_error "Checks that did run also reported failures (see output above)."
        fi
        log_error "Verification incomplete — required tooling unavailable: $KYZN_VERIFY_UNAVAILABLE_REASON"
        return "$KYZN_VERIFY_RC_UNAVAILABLE"
    fi

    if ! $build_ok; then
        KYZN_VERIFY_STATUS="failed"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Node.js verification
# ---------------------------------------------------------------------------
verify_node() {
    local ok=true

    # npm is the only runner this verifier drives. Without it nothing can be
    # checked — say so explicitly rather than waiting for a configured script to
    # produce command-not-found (and reporting green when there are no scripts).
    if [[ -f "package.json" ]] && ! command -v npm &>/dev/null; then
        verify_unavailable "npm not found — Node build and tests were not run"
        return 0
    fi

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

    # TypeScript check — project-local compiler ONLY.
    # Never `npx tsc`: with no local install, npx resolves and downloads `tsc`
    # from the registry, which is an unrelated package (not the TypeScript
    # compiler). That is both a supply-chain risk and a fake type check.
    if [[ -f "tsconfig.json" ]]; then
        if [[ -x "node_modules/.bin/tsc" ]]; then
            log_step "Running TypeScript check (node_modules/.bin/tsc)..."
            if ! node_modules/.bin/tsc --noEmit 2>&1 | tail -20; then
                log_error "TypeScript check failed"
                ok=false
            else
                log_ok "TypeScript check passed"
            fi
        else
            verify_unavailable "tsconfig.json present but TypeScript is not installed locally (node_modules/.bin/tsc missing) — type check was not run"
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

    # Ruff / mypy stay OPTIONAL — they are linters, and their absence is not a
    # gap in verification. Resolved project-local first so a venv install counts.
    local ruff_bin mypy_bin pytest_bin
    if ruff_bin=$(_kyzn_python_tool ruff); then
        log_step "Running ruff check ($ruff_bin)..."
        if ! "$ruff_bin" check . 2>&1 | tail -20; then
            log_warn "Ruff found issues (non-blocking)"
        else
            log_ok "Ruff check passed"
        fi
    fi

    if mypy_bin=$(_kyzn_python_tool mypy); then
        log_step "Running mypy ($mypy_bin)..."
        if ! "$mypy_bin" . 2>&1 | tail -20; then
            log_warn "Mypy found issues (non-blocking)"
        else
            log_ok "Mypy check passed"
        fi
    fi

    # pytest is REQUIRED when the project ships tests. Skipping it silently is
    # how a project with no usable test runner used to score a green verify.
    if _kyzn_python_has_tests; then
        if pytest_bin=$(_kyzn_python_tool pytest); then
            log_step "Running pytest ($pytest_bin)..."
            local -a pytest_args=()
            if [[ -n "${KYZN_PYTEST_EXTRA_ARGS:-}" ]]; then
                read -ra pytest_args <<< "$KYZN_PYTEST_EXTRA_ARGS"
            fi
            if ! "$pytest_bin" "${pytest_args[@]}" 2>&1 | tail -10; then
                log_error "Tests failed"
                ok=false
            else
                log_ok "Tests passed"
            fi
        else
            verify_unavailable "project has tests but pytest was not found in .venv/bin, venv/bin, or PATH — tests were not run"
        fi
    fi

    $ok
}

# ---------------------------------------------------------------------------
# Rust verification
# ---------------------------------------------------------------------------
verify_rust() {
    local ok=true

    if ! command -v cargo &>/dev/null; then
        verify_unavailable "cargo not found — Rust build and tests were not run"
        return 0
    fi

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

    $ok
}

# ---------------------------------------------------------------------------
# Go verification
# ---------------------------------------------------------------------------
verify_go() {
    local ok=true

    if ! command -v go &>/dev/null; then
        verify_unavailable "go not found — Go build and tests were not run"
        return 0
    fi

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

    $ok
}

# ---------------------------------------------------------------------------
# C# / .NET verification
# ---------------------------------------------------------------------------
verify_csharp() {
    local ok=true

    if ! command -v dotnet &>/dev/null; then
        verify_unavailable "dotnet not found — C# build and tests were not run"
        return 0
    fi

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

    $ok
}

# ---------------------------------------------------------------------------
# Java / JVM verification (Maven or Gradle, dispatched on KYZN_JAVA_BUILD)
# ---------------------------------------------------------------------------
verify_java() {
    local ok=true
    local build="${KYZN_JAVA_BUILD:-}"

    if [[ -z "$build" ]]; then
        verify_unavailable "no Maven or Gradle build detected — Java build and tests were not run"
        return 0
    fi

    if [[ "$build" == "maven" ]] && ! command -v mvn &>/dev/null; then
        verify_unavailable "mvn not found — Maven build and tests were not run"
        return 0
    fi

    if [[ "$build" == "gradle" ]] && [[ ! -x "./gradlew" ]] && ! command -v gradle &>/dev/null; then
        verify_unavailable "no ./gradlew wrapper and gradle not found — Gradle build and tests were not run"
        return 0
    fi

    if [[ "$build" == "maven" ]]; then
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

    $ok
}
