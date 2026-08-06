#!/usr/bin/env bash
# kyzn/tests/toolchain/run-matrix.sh — real-toolchain integration matrix
#
# Exercises lib/verify.sh against REAL compilers and test runners for the
# toolchains the mocked selftest suite can only simulate. Every fixture is a
# throwaway git repo under a temp dir that is removed on exit.
#
# For each suite it proves:
#   1. a valid project verifies clean            → rc 0
#   2. a deliberate compile/test failure is seen → rc 1
#   3. the real, expected local binary was used  (asserted from verifier output)
#
# Usage:
#   run-matrix.sh [flags] <suite>...   suites: typescript dotnet maven gradle
#                                              gradle-wrapper all
#
# Flags — deliberately independent, because strictness and network access are
# different decisions and must never imply one another:
#   --require           a skipped or unavailable suite is a FAILURE, not a skip.
#                       Grants nothing; it only changes how gaps are reported.
#   --allow-downloads   authorizes fetching the pinned fixture dependencies.
#                       Equivalent env form: KYZN_ALLOW_DOWNLOAD=true
#
# With neither flag a suite is skipped and nothing is fetched, so the script is
# safe to run on a workstation. With --require but no download authorization the
# run FAILS and still invokes no package manager. CI passes both.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KYZN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export KYZN_ROOT

# ---------------------------------------------------------------------------
# Pinned FIXTURE DEPENDENCY versions — the packages the sample projects pull in.
# Each was resolved from the upstream registry, not recalled. SDK and runtime
# versions (Node, .NET SDK, JDK, Gradle) are NOT pinned here — they are pinned
# in .github/workflows/toolchain-matrix.yml, which provisions them.
# Bump deliberately; drift here silently changes what the matrix proves.
# ---------------------------------------------------------------------------
TS_VERSION="${KYZN_TS_VERSION:-5.9.3}"          # npm: typescript
JUNIT_VERSION="5.12.2"                          # maven central: org.junit:junit-bom
SUREFIRE_VERSION="3.5.6"                        # maven central: maven-surefire-plugin
COMPILER_PLUGIN_VERSION="3.15.0"                # maven central: maven-compiler-plugin
XUNIT_VERSION="2.9.3"                           # nuget: xunit
XUNIT_RUNNER_VERSION="3.1.5"                    # nuget: xunit.runner.visualstudio
TEST_SDK_VERSION="18.8.1"                       # nuget: Microsoft.NET.Test.Sdk
DOTNET_TFM="${KYZN_DOTNET_TFM:-net10.0}"        # matches the pinned SDK channel
JAVA_RELEASE="17"

REQUIRE=false
ALLOW_DOWNLOADS=false
PASSED=0; FAILED=0; SKIPPED=0
WORKDIR=""

cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

ok()   { PASSED=$((PASSED+1)); echo "  PASS  $1"; }
bad()  { FAILED=$((FAILED+1)); echo "  FAIL  $1 — $2"; }
skip() { SKIPPED=$((SKIPPED+1)); echo "  SKIP  $1"; }

# A toolchain that CI expects must never be silently skipped.
need() { # need <tool> <suite>
    if command -v "$1" &>/dev/null; then
        return 0
    fi
    if $REQUIRE; then
        bad "$2" "required tool '$1' is not installed (--require)"
    else
        skip "$2 — '$1' not available on this host"
    fi
    return 1
}

# Every suite fetches pinned dependencies (npm/nuget/maven-central/gradle dist).
# Network access is authorized ONLY by --allow-downloads (or its env form).
# --require deliberately does NOT grant it: strictness must never widen
# permissions, or "be strict" silently becomes "go online".
downloads_allowed() {
    $ALLOW_DOWNLOADS && return 0
    [[ "${KYZN_ALLOW_DOWNLOAD:-false}" == "true" ]]
}

# Returns non-zero to mean "stop before touching any package manager".
may_download() { # may_download <suite>
    if downloads_allowed; then
        return 0
    fi
    if $REQUIRE; then
        bad "$1" "network downloads are not authorized — pass --allow-downloads (no package manager was invoked)"
    else
        skip "$1 — needs pinned dependency downloads (pass --allow-downloads, or KYZN_ALLOW_DOWNLOAD=true)"
    fi
    return 1
}

check() { # check <label> <expected_rc> <actual_rc>
    if [[ "$2" == "$3" ]]; then ok "$1 (rc=$3)"; else bad "$1" "expected rc $2, got $3"; fi
}

grep_out() { # grep_out <label> <file> <pattern>
    if grep -q -- "$3" "$2"; then ok "$1"; else bad "$1" "output lacks '$3'"; fi
}

load_kyzn() {
    # shellcheck source=../../lib/core.sh
    source "$KYZN_ROOT/lib/core.sh"
    # shellcheck source=../../lib/detect.sh
    source "$KYZN_ROOT/lib/detect.sh"
    # shellcheck source=../../lib/verify.sh
    source "$KYZN_ROOT/lib/verify.sh"
}

newfix() { # newfix <name> — fresh disposable git repo, cds into it
    local d="$WORKDIR/$1"
    rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 1
    git init -q .
    git config user.email "toolchain-matrix@kyzn.local"
    git config user.name "KyZN Toolchain Matrix"
    git commit --allow-empty -qm init
}

verify_rc() { # verify_rc <outfile> — echoes verify_build's exit code
    local out="$1" rc=0
    verify_build > "$out" 2>&1 || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# TypeScript — project-local compiler only
# ---------------------------------------------------------------------------
suite_typescript() {
    echo "== typescript (typescript@$TS_VERSION) =="
    need npm typescript || return 0
    may_download typescript || return 0

    newfix ts-pass
    cat > package.json <<'JSON'
{ "name": "fx", "version": "1.0.0", "private": true }
JSON
    echo '{"compilerOptions":{"strict":true,"noEmit":true}}' > tsconfig.json
    mkdir -p src
    echo 'export const add = (a: number, b: number): number => a + b;' > src/index.ts
    git add -A && git commit -qm scaffold

    # The ONLY download in this suite, and it is explicit and pinned.
    npm install --no-audit --no-fund --save-exact "typescript@$TS_VERSION" >/dev/null 2>&1
    if [[ ! -x node_modules/.bin/tsc ]]; then
        bad "typescript: local install" "node_modules/.bin/tsc missing after npm install"
        return 0
    fi
    ok "typescript: node_modules/.bin/tsc present ($(node_modules/.bin/tsc --version 2>&1))"

    detect_project_type
    local rc; rc=$(verify_rc out.txt)
    check "typescript/pass: valid project verifies" 0 "$rc"
    grep_out "typescript/pass: used the project-local compiler" out.txt "node_modules/.bin/tsc"

    # Deliberate type error — must be a real failure, not "unavailable"
    echo 'export const bad: number = "not a number";' > src/index.ts
    rc=$(verify_rc out2.txt)
    check "typescript/fail: real type error detected" 1 "$rc"

    # Remove the local compiler: must become "not executed", with no download
    rm -rf node_modules
    rc=$(verify_rc out3.txt)
    check "typescript/unavail: no local tsc → not executed" 2 "$rc"
    if [[ ! -d node_modules ]]; then
        ok "typescript/unavail: nothing was downloaded (npx never ran)"
    else
        bad "typescript/unavail: no download" "node_modules reappeared"
    fi
}

# ---------------------------------------------------------------------------
# .NET
# ---------------------------------------------------------------------------
suite_dotnet() {
    echo "== dotnet =="
    need dotnet dotnet || return 0
    may_download dotnet || return 0
    echo "   sdk: $(dotnet --version 2>&1)"

    _dotnet_fixture() { # _dotnet_fixture <name> <calc-body> <expected>
        newfix "$1"
        cat > fx.csproj <<XML
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$DOTNET_TFM</TargetFramework>
    <Nullable>enable</Nullable>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="$TEST_SDK_VERSION" />
    <PackageReference Include="xunit" Version="$XUNIT_VERSION" />
    <PackageReference Include="xunit.runner.visualstudio" Version="$XUNIT_RUNNER_VERSION" />
  </ItemGroup>
</Project>
XML
        cat > Calc.cs <<CS
namespace Fx;
public static class Calc { public static int Add(int a, int b) => $2; }
CS
        cat > CalcTests.cs <<CS
using Xunit;
namespace Fx;
public class CalcTests { [Fact] public void Adds() => Assert.Equal($3, Calc.Add(1, 2)); }
CS
        git add -A && git commit -qm scaffold
        detect_project_type
    }

    # Valid: Add returns a+b, test expects 3
    _dotnet_fixture dotnet-pass 'a + b' '3'
    local rc; rc=$(verify_rc out.txt)
    check "dotnet/pass: valid project verifies" 0 "$rc"
    grep_out "dotnet/pass: real dotnet build ran" out.txt "Build passed"
    grep_out "dotnet/pass: real dotnet test ran" out.txt "Tests passed"

    # Failing test: Add returns a+b, test expects 4
    _dotnet_fixture dotnet-testfail 'a + b' '4'
    rc=$(verify_rc out.txt)
    check "dotnet/fail: real xunit failure detected" 1 "$rc"

    # Compile error
    _dotnet_fixture dotnet-compilefail 'a + b' '3'
    echo 'namespace Fx; public static class Broken { public static int X() => "nope"; }' > Broken.cs
    rc=$(verify_rc out.txt)
    check "dotnet/fail: real compile error detected" 1 "$rc"
}

# ---------------------------------------------------------------------------
# Java — shared fixture sources
# ---------------------------------------------------------------------------
_java_sources() { # _java_sources <expected-sum>
    mkdir -p src/main/java/fx src/test/java/fx
    cat > src/main/java/fx/Calc.java <<'JAVA'
package fx;

public class Calc {
    public static int add(int a, int b) {
        return a + b;
    }
}
JAVA
    cat > src/test/java/fx/CalcTest.java <<JAVA
package fx;

import static org.junit.jupiter.api.Assertions.assertEquals;
import org.junit.jupiter.api.Test;

class CalcTest {
    @Test
    void adds() {
        assertEquals($1, Calc.add(1, 2));
    }
}
JAVA
}

_maven_pom() {
    cat > pom.xml <<XML
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>local.fx</groupId>
  <artifactId>fx</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
  <properties>
    <maven.compiler.release>$JAVA_RELEASE</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.junit</groupId>
        <artifactId>junit-bom</artifactId>
        <version>$JUNIT_VERSION</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>org.junit.jupiter</groupId>
      <artifactId>junit-jupiter</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>$COMPILER_PLUGIN_VERSION</version>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>$SUREFIRE_VERSION</version>
      </plugin>
    </plugins>
  </build>
</project>
XML
}

_gradle_build() {
    cat > settings.gradle <<'GRADLE'
rootProject.name = 'fx'
GRADLE
    cat > build.gradle <<GRADLE
plugins { id 'java' }

repositories { mavenCentral() }

java { toolchain { languageVersion = JavaLanguageVersion.of($JAVA_RELEASE) } }

dependencies {
    testImplementation platform('org.junit:junit-bom:$JUNIT_VERSION')
    testImplementation 'org.junit.jupiter:junit-jupiter'
    testRuntimeOnly 'org.junit.platform:junit-platform-launcher'
}

test { useJUnitPlatform() }
GRADLE
}

suite_maven() {
    echo "== java / maven =="
    need mvn maven || return 0
    may_download maven || return 0

    newfix maven-pass
    _maven_pom
    _java_sources 3
    git add -A && git commit -qm scaffold
    detect_project_type
    [[ "${KYZN_JAVA_BUILD:-}" == "maven" ]] && ok "maven: detected as maven build" \
        || bad "maven: detection" "KYZN_JAVA_BUILD=${KYZN_JAVA_BUILD:-unset}"
    local rc; rc=$(verify_rc out.txt)
    check "maven/pass: valid project verifies" 0 "$rc"
    grep_out "maven/pass: real mvn compile ran" out.txt "Build passed"
    grep_out "maven/pass: real mvn test ran" out.txt "Tests passed"

    newfix maven-testfail
    _maven_pom
    _java_sources 4          # test expects 4, add() returns 3
    git add -A && git commit -qm scaffold
    detect_project_type
    rc=$(verify_rc out.txt)
    check "maven/fail: real JUnit failure detected" 1 "$rc"

    newfix maven-compilefail
    _maven_pom
    _java_sources 3
    echo 'package fx; public class Broken { int x = "nope"; }' > src/main/java/fx/Broken.java
    git add -A && git commit -qm scaffold
    detect_project_type
    rc=$(verify_rc out.txt)
    check "maven/fail: real compile error detected" 1 "$rc"
}

suite_gradle() {
    echo "== java / gradle (system) =="
    need gradle gradle || return 0
    may_download gradle || return 0

    newfix gradle-pass
    _gradle_build
    _java_sources 3
    git add -A && git commit -qm scaffold
    detect_project_type
    [[ "${KYZN_JAVA_BUILD:-}" == "gradle" ]] && ok "gradle: detected as gradle build" \
        || bad "gradle: detection" "KYZN_JAVA_BUILD=${KYZN_JAVA_BUILD:-unset}"
    local rc; rc=$(verify_rc out.txt)
    check "gradle/pass: valid project verifies" 0 "$rc"
    grep_out "gradle/pass: used system gradle (no wrapper present)" out.txt "Running gradle build"
    grep_out "gradle/pass: real gradle test ran" out.txt "Tests passed"

    newfix gradle-testfail
    _gradle_build
    _java_sources 4
    git add -A && git commit -qm scaffold
    detect_project_type
    rc=$(verify_rc out.txt)
    check "gradle/fail: real JUnit failure detected" 1 "$rc"
}

suite_gradle_wrapper() {
    echo "== java / gradle (wrapper precedence) =="
    need gradle gradle-wrapper || return 0
    may_download gradle-wrapper || return 0

    newfix gradle-wrapper-pass
    _gradle_build
    _java_sources 3
    # Generate a real wrapper from the pinned system Gradle.
    gradle wrapper --quiet >/dev/null 2>&1
    if [[ ! -x ./gradlew ]]; then
        bad "gradle-wrapper: generation" "gradle wrapper did not produce an executable ./gradlew"
        return 0
    fi
    ok "gradle-wrapper: real ./gradlew generated"
    git add -A && git commit -qm scaffold
    detect_project_type

    local rc; rc=$(verify_rc out.txt)
    check "gradle-wrapper/pass: valid project verifies" 0 "$rc"
    # Precedence: BOTH a wrapper and a system gradle are on hand — the wrapper wins.
    grep_out "gradle-wrapper: wrapper takes precedence over system gradle" out.txt "Running ./gradlew build"
    if grep -q "Running gradle build" out.txt; then
        bad "gradle-wrapper: precedence" "system gradle was used despite a wrapper being present"
    else
        ok "gradle-wrapper: system gradle was not used"
    fi

    newfix gradle-wrapper-testfail
    _gradle_build
    _java_sources 4
    gradle wrapper --quiet >/dev/null 2>&1
    git add -A && git commit -qm scaffold
    detect_project_type
    rc=$(verify_rc out.txt)
    check "gradle-wrapper/fail: real JUnit failure detected" 1 "$rc"
}

# ---------------------------------------------------------------------------
main() {
    local -a suites=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --require)         REQUIRE=true; shift ;;
            --allow-downloads) ALLOW_DOWNLOADS=true; shift ;;
            -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
            all)       suites=(typescript dotnet maven gradle gradle-wrapper); shift ;;
            *)         suites+=("$1"); shift ;;
        esac
    done
    [[ ${#suites[@]} -eq 0 ]] && suites=(typescript dotnet maven gradle gradle-wrapper)

    WORKDIR=$(mktemp -d) || { echo "cannot create temp dir"; exit 1; }
    load_kyzn

    echo "KyZN toolchain matrix — fixtures under $WORKDIR"
    echo "require-mode: $REQUIRE"
    echo ""

    local s
    for s in "${suites[@]}"; do
        case "$s" in
            typescript)     suite_typescript ;;
            dotnet)         suite_dotnet ;;
            maven)          suite_maven ;;
            gradle)         suite_gradle ;;
            gradle-wrapper) suite_gradle_wrapper ;;
            *) echo "unknown suite: $s"; exit 2 ;;
        esac
        echo ""
    done

    echo "================================================="
    echo "  passed: $PASSED   failed: $FAILED   skipped: $SKIPPED"
    echo "================================================="
    [[ "$FAILED" -eq 0 ]]
}

main "$@"
