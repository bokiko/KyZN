#!/usr/bin/env bash
# kyzn/lib/detect.sh — Project type detection

# True when DIR directly contains a manifest for any supported language.
# Pure — mutates nothing. Used to find candidate subdirectories, so it must
# recognize exactly the same files _kyzn_detect_manifests_at() does.
_kyzn_dir_has_manifest() {
    local dir="$1"

    [[ -f "$dir/package.json" ]] && return 0
    [[ -f "$dir/pyproject.toml" || -f "$dir/setup.py" || -f "$dir/setup.cfg" || -f "$dir/requirements.txt" ]] && return 0
    [[ -f "$dir/Cargo.toml" ]] && return 0
    [[ -f "$dir/go.mod" ]] && return 0
    [[ -f "$dir/global.json" ]] && return 0
    compgen -G "$dir/*.csproj" >/dev/null 2>&1 && return 0
    compgen -G "$dir/*.sln" >/dev/null 2>&1 && return 0
    [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" || \
       -f "$dir/settings.gradle" || -f "$dir/settings.gradle.kts" || -f "$dir/pom.xml" ]] && return 0

    return 1
}

# Populate KYZN_PROJECT_TYPE / KYZN_PROJECT_TYPES / KYZN_JAVA_BUILD from
# manifests found directly inside DIR (no fallback to "generic" — the caller
# decides what an empty result means).
_kyzn_detect_manifests_at() {
    local dir="$1"

    # Check each type — order matters (first match = primary)
    if [[ -f "$dir/package.json" ]]; then
        KYZN_PROJECT_TYPES+=("node")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="node"
    fi

    if [[ -f "$dir/pyproject.toml" || -f "$dir/setup.py" || -f "$dir/setup.cfg" || -f "$dir/requirements.txt" ]]; then
        KYZN_PROJECT_TYPES+=("python")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="python"
    fi

    if [[ -f "$dir/Cargo.toml" ]]; then
        KYZN_PROJECT_TYPES+=("rust")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="rust"
    fi

    if [[ -f "$dir/go.mod" ]]; then
        KYZN_PROJECT_TYPES+=("go")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="go"
    fi

    if [[ -f "$dir/global.json" ]] || \
       compgen -G "$dir/*.csproj" >/dev/null 2>&1 || \
       compgen -G "$dir/*.sln" >/dev/null 2>&1; then
        KYZN_PROJECT_TYPES+=("csharp")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="csharp"
    fi

    # Java / JVM — gradle wins if both Maven and Gradle present (real-world precedence)
    if [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" || \
          -f "$dir/settings.gradle" || -f "$dir/settings.gradle.kts" ]]; then
        KYZN_PROJECT_TYPES+=("java")
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="java"
        KYZN_JAVA_BUILD="gradle"
    fi
    if [[ -f "$dir/pom.xml" ]]; then
        # Bash 3.2 (stock macOS) treats `${arr[*]}` on an empty array as an
        # unbound variable under `set -u`, so a Maven-only project — the one
        # case where nothing has been appended yet — would abort the shell.
        if [[ ! " ${KYZN_PROJECT_TYPES[*]:-} " == *" java "* ]]; then
            KYZN_PROJECT_TYPES+=("java")
        fi
        [[ -z "$KYZN_PROJECT_TYPE" ]] && KYZN_PROJECT_TYPE="java"
        [[ -z "$KYZN_JAVA_BUILD" ]] && KYZN_JAVA_BUILD="maven"
    fi
}

# Detect the primary project type based on manifest files.
# Sets KYZN_PROJECT_TYPE, KYZN_PROJECT_TYPES (array of all detected types),
# and KYZN_PROJECT_SUBDIR (relative path from project_root() where the
# manifest actually lives — "" when it lives at project_root() itself).
detect_project_type() {
    KYZN_PROJECT_TYPE=""
    KYZN_PROJECT_TYPES=()
    KYZN_JAVA_BUILD=""
    KYZN_PROJECT_SUBDIR=""

    local root
    root="$(project_root)"

    # Explicit escape hatch: project.root in .kyzn/config.yaml. Needed for
    # monorepo/subdir layouts (e.g. a Next.js app in web/, backend config in
    # supabase/, nothing at the repo root) where auto-detection is ambiguous
    # or the manifest lives more than one level down.
    local configured_root explicit_root_valid=false
    configured_root=$(config_get '.project.root' '')
    if [[ -n "$configured_root" ]]; then
        if [[ "$configured_root" == /* || "$configured_root" == *..* ]]; then
            log_warn "Ignoring project.root '$configured_root' — must be a relative path within the repo"
        elif [[ ! -d "$root/$configured_root" ]]; then
            log_warn "project.root '$configured_root' not found under $root — falling back to auto-detection"
        else
            KYZN_PROJECT_SUBDIR="$configured_root"
            explicit_root_valid=true
        fi
    fi

    local detect_root="$root"
    [[ -n "$KYZN_PROJECT_SUBDIR" ]] && detect_root="$root/$KYZN_PROJECT_SUBDIR"

    _kyzn_detect_manifests_at "$detect_root"

    # Nothing at the root, and no VALID explicit project.root pinning it there
    # — check one level down, generalizing the old Cargo-workspace-only glob
    # to every language. An invalid project.root (typo'd or missing directory)
    # still falls through to this, same as if it had never been set. Ambiguous
    # (manifests in more than one subdirectory) stays generic: guessing wrong
    # here means running the wrong build/test tooling.
    if [[ "$explicit_root_valid" == false && -z "$KYZN_PROJECT_TYPE" ]]; then
        local -a candidates=()
        local d
        for d in "$root"/*/; do
            [[ -d "$d" ]] || continue
            d="${d%/}"
            _kyzn_dir_has_manifest "$d" && candidates+=("$(basename "$d")")
        done

        if (( ${#candidates[@]} == 1 )); then
            KYZN_PROJECT_SUBDIR="${candidates[0]}"
            _kyzn_detect_manifests_at "$root/$KYZN_PROJECT_SUBDIR"
        elif (( ${#candidates[@]} > 1 )); then
            log_warn "Multiple candidate project directories one level down (${candidates[*]}) — set project.root in .kyzn/config.yaml to pick one."
        fi
    fi

    # Fallback
    if [[ -z "$KYZN_PROJECT_TYPE" ]]; then
        KYZN_PROJECT_TYPE="generic"
        KYZN_PROJECT_TYPES+=("generic")
        KYZN_PROJECT_SUBDIR=""
    fi
}

# Detect additional project characteristics
detect_project_features() {
    local root
    root="$(project_workdir)"

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

    # CI and Docker are checked at the true repo root — pipeline and container
    # config is conventionally repo-wide even when the manifest lives in a subdir.
    local repo_root
    repo_root="$(project_root)"
    if [[ -d "$repo_root/.github/workflows" || -f "$repo_root/.gitlab-ci.yml" || -f "$repo_root/.circleci/config.yml" ]]; then
        KYZN_HAS_CI=true
    fi
    if [[ -f "$repo_root/Dockerfile" || -f "$repo_root/docker-compose.yml" || -f "$repo_root/docker-compose.yaml" ]]; then
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

    if [[ -n "${KYZN_PROJECT_SUBDIR:-}" ]]; then
        log_dim "Project root: $KYZN_PROJECT_SUBDIR/"
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
    (
    cd "$(project_workdir)" 2>/dev/null || exit 0
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
