#!/usr/bin/env bash
# kyzn/lib/detect.sh — Project type detection

# Detect the primary project type based on manifest files.
# Sets KYZN_PROJECT_TYPE and KYZN_PROJECT_TYPES (array of all detected types).
detect_project_type() {
    KYZN_PROJECT_TYPE=""
    KYZN_PROJECT_TYPES=()
    KYZN_JAVA_BUILD=""

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

    if [[ -f "$root/Cargo.toml" ]] || compgen -G "$root/*/Cargo.toml" >/dev/null 2>&1; then
        KYZN_PROJECT_TYPES+=("rust")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="rust"
    fi

    if [[ -f "$root/go.mod" ]]; then
        KYZN_PROJECT_TYPES+=("go")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="go"
    fi

    if [[ -f "$root/global.json" ]] || \
       compgen -G "$root/*.csproj" >/dev/null 2>&1 || \
       compgen -G "$root/*.sln" >/dev/null 2>&1 || \
       compgen -G "$root/*/*.csproj" >/dev/null 2>&1; then
        KYZN_PROJECT_TYPES+=("csharp")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="csharp"
    fi

    # Java / JVM — gradle wins if both Maven and Gradle present (real-world precedence)
    if [[ -f "$root/build.gradle" || -f "$root/build.gradle.kts" || \
          -f "$root/settings.gradle" || -f "$root/settings.gradle.kts" ]]; then
        KYZN_PROJECT_TYPES+=("java")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="java"
        KYZN_JAVA_BUILD="gradle"
    fi
    if [[ -f "$root/pom.xml" ]]; then
        if [[ ! " ${KYZN_PROJECT_TYPES[*]} " == *" java "* ]]; then
            KYZN_PROJECT_TYPES+=("java")
        fi
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="java"
        [[ -z "$KYZN_JAVA_BUILD" ]] && KYZN_JAVA_BUILD="maven"
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
    if $KYZN_HAS_TYPESCRIPT; then features+=("TypeScript"); fi
    if $KYZN_HAS_TESTS;      then features+=("Tests"); fi
    if $KYZN_HAS_CI;          then features+=("CI"); fi
    if $KYZN_HAS_DOCKER;      then features+=("Docker"); fi
    if $KYZN_HAS_LINTER;      then features+=("Linter"); fi

    if (( ${#features[@]} > 0 )); then
        log_dim "Features: ${features[*]}"
    fi
}

# Detect installed packages for the current project type.
# Python: uses pip list (accurate, handles name divergence).
# Node/Rust/Go: parses manifests (import names match package names).
detect_installed_packages() {
    case "${KYZN_PROJECT_TYPE:-generic}" in
        python)
            if command -v pip &>/dev/null; then
                pip list --format=freeze 2>/dev/null | sed 's/==.*//' | sort
            elif command -v pip3 &>/dev/null; then
                pip3 list --format=freeze 2>/dev/null | sed 's/==.*//' | sort
            fi
            ;;
        node)
            if [[ -f "package.json" ]]; then
                jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' package.json 2>/dev/null | sort || true
            fi
            ;;
        rust)
            if [[ -f "Cargo.toml" ]]; then
                sed -n '/^\[dependencies\]/,/^\[/p' Cargo.toml 2>/dev/null \
                    | grep -v '^\[' | grep -v '^\s*$' | sed 's/\s*=.*//' | sort || true
            fi
            ;;
        go)
            if [[ -f "go.mod" ]]; then
                sed -n '/^require/,/^)/p' go.mod 2>/dev/null \
                    | grep -v '^require' | grep -v '^)' | awk '{print $1}' | sort || true
            fi
            ;;
        csharp)
            if compgen -G "*.csproj" >/dev/null 2>&1 || compgen -G "*/*.csproj" >/dev/null 2>&1; then
                # shellcheck disable=SC2046
                grep -hoE 'Include="[^"]+"' $(compgen -G "*.csproj" || true) $(compgen -G "*/*.csproj" || true) 2>/dev/null \
                    | sed -E 's/Include="([^"]+)"/\1/' | sort -u
            fi
            ;;
        java)
            if [[ "${KYZN_JAVA_BUILD:-}" == "maven" && -f "pom.xml" ]]; then
                awk '/<dependencies>/,/<\/dependencies>/' pom.xml 2>/dev/null \
                    | grep -oE '<artifactId>[^<]+</artifactId>' \
                    | sed -E 's|</?artifactId>||g' | sort -u
            elif [[ "${KYZN_JAVA_BUILD:-}" == "gradle" ]]; then
                local _gf
                for _gf in build.gradle build.gradle.kts; do
                    [[ -f "$_gf" ]] || continue
                    grep -hE '^\s*(implementation|api|compileOnly|runtimeOnly|testImplementation)\s*[("'\'']' "$_gf" 2>/dev/null \
                        | grep -oE '["'\''][^"'\'']+:[^"'\'':]+(:[^"'\''])?["'\'']' \
                        | tr -d '"'\'
                done | sort -u
            fi
            ;;
    esac
}

# Get a friendly name for the project type
project_type_name() {
    case "${1:-$KYZN_PROJECT_TYPE}" in
        node)    echo "Node.js / JavaScript" ;;
        python)  echo "Python" ;;
        rust)    echo "Rust" ;;
        go)      echo "Go" ;;
        csharp)  echo "C# / .NET" ;;
        java)    echo "Java / JVM" ;;
        generic) echo "Generic" ;;
        *)       echo "$1" ;;
    esac
}
