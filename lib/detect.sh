#!/usr/bin/env bash
# kyzn/lib/detect.sh — Project type detection

# Detect the primary project type based on manifest files.
# Sets KYZN_PROJECT_TYPE and KYZN_PROJECT_TYPES (array of all detected types).
detect_project_type() {
    KYZN_PROJECT_TYPE=""
    KYZN_PROJECT_TYPES=()

    local root
    root="$(project_root)"

    # Check each type — order matters (first match = primary)
    if [[ -f "$root/package.json" ]]; then
        KYZN_PROJECT_TYPES+=("node")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="node"
    fi

    if [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/setup.cfg" || -f "$root/requirements.txt" ]]; then
        KYZN_PROJECT_TYPES+=("python")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="python"
    fi

    if [[ -f "$root/Cargo.toml" ]]; then
        KYZN_PROJECT_TYPES+=("rust")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="rust"
    fi

    if [[ -f "$root/go.mod" ]]; then
        KYZN_PROJECT_TYPES+=("go")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="go"
    fi

    # Fallback
    if [[ -z "$KYZN_PROJECT_TYPE" ]]; then
        KYZN_PROJECT_TYPE="generic"
        KYZN_PROJECT_TYPES+=("generic")
    fi
}

# Detect additional project characteristics
detect_project_features() {
    local root
    root="$(project_root)"

    KYZN_HAS_TYPESCRIPT=false
    KYZN_HAS_TESTS=false
    KYZN_HAS_CI=false
    KYZN_HAS_DOCKER=false
    KYZN_HAS_LINTER=false

    # TypeScript
    if [[ -f "$root/tsconfig.json" ]]; then
        KYZN_HAS_TYPESCRIPT=true
    fi

    # Tests
    if [[ -d "$root/tests" || -d "$root/test" || -d "$root/__tests__" ]] ||
       [[ -f "$root/jest.config.js" || -f "$root/jest.config.ts" ]] ||
       [[ -f "$root/vitest.config.ts" || -f "$root/vitest.config.js" ]] ||
       [[ -f "$root/pytest.ini" || -f "$root/conftest.py" ]]; then
        KYZN_HAS_TESTS=true
    fi

    # CI
    if [[ -d "$root/.github/workflows" || -f "$root/.gitlab-ci.yml" || -f "$root/.circleci/config.yml" ]]; then
        KYZN_HAS_CI=true
    fi

    # Docker
    if [[ -f "$root/Dockerfile" || -f "$root/docker-compose.yml" || -f "$root/docker-compose.yaml" ]]; then
        KYZN_HAS_DOCKER=true
    fi

    # Linter config
    if [[ -f "$root/.eslintrc.js" || -f "$root/.eslintrc.json" || -f "$root/.eslintrc.yml" || -f "$root/.eslintrc.yaml" || -f "$root/eslint.config.js" || -f "$root/eslint.config.mjs" ]] ||
       [[ -f "$root/ruff.toml" || -f "$root/.ruff.toml" ]] ||
       [[ -f "$root/clippy.toml" || -f "$root/.clippy.toml" ]] ||
       grep -q '\[tool\.ruff\]' "$root/pyproject.toml" 2>/dev/null; then
        KYZN_HAS_LINTER=true
    fi
}

# Print detection results
print_detection() {
    log_step "Project type: ${BOLD}${KYZN_PROJECT_TYPE}${RESET}"

    if (( ${#KYZN_PROJECT_TYPES[@]} > 1 )); then
        log_dim "Also detected: ${KYZN_PROJECT_TYPES[*]}"
    fi

    local features=()
    $KYZN_HAS_TYPESCRIPT && features+=("TypeScript")
    $KYZN_HAS_TESTS      && features+=("Tests")
    $KYZN_HAS_CI          && features+=("CI")
    $KYZN_HAS_DOCKER      && features+=("Docker")
    $KYZN_HAS_LINTER      && features+=("Linter")

    if (( ${#features[@]} > 0 )); then
        log_dim "Features: ${features[*]}"
    fi
}

# Get a friendly name for the project type
project_type_name() {
    case "${1:-$KYZN_PROJECT_TYPE}" in
        node)    echo "Node.js / JavaScript" ;;
        python)  echo "Python" ;;
        rust)    echo "Rust" ;;
        go)      echo "Go" ;;
        generic) echo "Generic" ;;
        *)       echo "$1" ;;
    esac
}
