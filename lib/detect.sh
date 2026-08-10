#!/usr/bin/env bash
# kyzn/lib/detect.sh — Project type detection

# Detect the primary project type based on manifest files.
# Sets KYZN_PROJECT_TYPE, KYZN_PROJECT_TYPES (array of all detected types),
# and KYZN_PROJECT_DIR (relative path, empty for root).
detect_project_type() {
    KYZN_PROJECT_TYPE=""
    KYZN_PROJECT_TYPES=()
    KYZN_JAVA_BUILD=""
    KYZN_PROJECT_DIR=""

    local root
    root="$(project_root)"

    # Check config for explicit project directory
    if has_config; then
        local cfg_dir
        cfg_dir=$(config_get ".project.dir" "")
        if [[ -n "$cfg_dir" && "$cfg_dir" != "null" ]]; then
            KYZN_PROJECT_DIR="$cfg_dir"
        fi
    fi

    # Check each type — order matters (first match = primary)
    _detect_in_dir() {
        local d="$1"
        local found=false
        if [[ -f "$d/package.json" ]]; then
            KYZN_PROJECT_TYPES+=("node")
            [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="node"
            found=true
        fi

        if [[ -f "$d/pyproject.toml" || -f "$d/setup.py" || -f "$d/setup.cfg" || -f "$d/requirements.txt" ]]; then
            KYZN_PROJECT_TYPES+=("python")
            [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="python"
            found=true
        fi

        if [[ -f "$d/Cargo.toml" ]] || compgen -G "$d/*/Cargo.toml" >/dev/null 2>&1; then
            KYZN_PROJECT_TYPES+=("rust")
            [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="rust"
            found=true
        fi

        if [[ -f "$d/go.mod" ]]; then
            KYZN_PROJECT_TYPES+=("go")
            [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="go"
            found=true
        fi

        if [[ -f "$d/global.json" ]] || \
           compgen -G "$d/*.csproj" >/dev/null 2>&1 || \
           compgen -G "$d/*.sln" >/dev/null 2>&1 || \
           compgen -G "$d/*/*.csproj" >/dev/null 2>&1; then
            KYZN_PROJECT_TYPES+=("csharp")
            [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="csharp"
            found=true
        fi

        # Java / JVM — gradle wins if both Maven and Gradle present (real-world precedence)
        if [[ -f "$d/build.gradle" || -f "$d/build.gradle.kts" || \
              -f "$d/settings.gradle" || -f "$d/settings.gradle.kts" ]]; then
            KYZN_PROJECT_TYPES+=("java")
            [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="java"
            KYZN_JAVA_BUILD="gradle"
            found=true
        fi
        if [[ -f "$d/pom.xml" ]]; then
            if [[ ! " ${KYZN_PROJECT_TYPES[*]:-} " == *" java "* ]]; then
                KYZN_PROJECT_TYPES+=("java")
            fi
            [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="java"
            [[ -z "$KYZN_JAVA_BUILD" ]] && KYZN_JAVA_BUILD="maven"
            found=true
        fi
        $found
    }

    if [[ -n "$KYZN_PROJECT_DIR" ]]; then
        _detect_in_dir "$root/$KYZN_PROJECT_DIR" || true
    else
        # Try root first
        if ! _detect_in_dir "$root"; then
            # No primary project found at root, try checking one level down
            local -a candidate_dirs=()
            local d
            for d in "$root"/*/; do
                if [[ -d "$d" ]] && _detect_in_dir "$d"; then
                    local rel="${d#$root/}"
                    rel="${rel%/}"
                    candidate_dirs+=("$rel")
                    # Clear types to check next
                    KYZN_PROJECT_TYPE=""
                    KYZN_PROJECT_TYPES=()
                    KYZN_JAVA_BUILD=""
                fi
            done

            # If exactly one subdirectory has a match, use it
            if (( ${#candidate_dirs[@]} == 1 )); then
                KYZN_PROJECT_DIR="${candidate_dirs[0]}"
                _detect_in_dir "$root/$KYZN_PROJECT_DIR" || true
            else
                # Ambiguous or none -> Generic, remain at root
                KYZN_PROJECT_TYPE=""
                KYZN_PROJECT_TYPES=()
                KYZN_JAVA_BUILD=""
            fi
        fi
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
    local target_dir="$root"
    if [[ -n "${KYZN_PROJECT_DIR:-}" ]]; then
        target_dir="$root/$KYZN_PROJECT_DIR"
    fi

    KYZN_HAS_TYPESCRIPT=false
    KYZN_HAS_TESTS=false
    KYZN_HAS_CI=false
    KYZN_HAS_DOCKER=false
    KYZN_HAS_LINTER=false

    # TypeScript
    if [[ -f "$target_dir/tsconfig.json" ]]; then
        KYZN_HAS_TYPESCRIPT=true
    fi

    # Tests
    if [[ -d "$target_dir/tests" || -d "$target_dir/test" || -d "$target_dir/__tests__" ]] ||
       [[ -f "$target_dir/jest.config.js" || -f "$target_dir/jest.config.ts" ]] ||
       [[ -f "$target_dir/vitest.config.ts" || -f "$target_dir/vitest.config.js" ]] ||
       [[ -f "$target_dir/pytest.ini" || -f "$target_dir/conftest.py" ]]; then
        KYZN_HAS_TESTS=true
    fi

    # CI (always check root for CI regardless of project dir)
    if [[ -d "$root/.github/workflows" || -f "$root/.gitlab-ci.yml" || -f "$root/.circleci/config.yml" ]]; then
        KYZN_HAS_CI=true
    fi

    # Docker (check target_dir but fallback to root)
    if [[ -f "$target_dir/Dockerfile" || -f "$target_dir/docker-compose.yml" || -f "$target_dir/docker-compose.yaml" ]] ||
       [[ -f "$root/Dockerfile" || -f "$root/docker-compose.yml" || -f "$root/docker-compose.yaml" ]]; then
        KYZN_HAS_DOCKER=true
    fi

    # Linter config
    if [[ -f "$target_dir/.eslintrc.js" || -f "$target_dir/.eslintrc.json" || -f "$target_dir/.eslintrc.yml" || -f "$target_dir/.eslintrc.yaml" || -f "$target_dir/eslint.config.js" || -f "$target_dir/eslint.config.mjs" ]] ||
       [[ -f "$target_dir/ruff.toml" || -f "$target_dir/.ruff.toml" ]] ||
       [[ -f "$target_dir/clippy.toml" || -f "$target_dir/.clippy.toml" ]] ||
       grep -q '\[tool\.ruff\]' "$target_dir/pyproject.toml" 2>/dev/null; then
        KYZN_HAS_LINTER=true
    fi
}

# Print detection results
print_detection() {
    log_step "Project type: ${BOLD}${KYZN_PROJECT_TYPE}${RESET}"

    if [[ -n "${KYZN_PROJECT_DIR:-}" ]]; then
        log_dim "Project root: ${KYZN_PROJECT_DIR}"
    fi

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
    local target_dir
    target_dir="$(project_root)"
    if [[ -n "${KYZN_PROJECT_DIR:-}" ]]; then
        target_dir="$target_dir/$KYZN_PROJECT_DIR"
    fi

    (
        cd "$target_dir" || return 0
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
    )
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
