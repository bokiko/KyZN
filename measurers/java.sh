#!/usr/bin/env bash
# kyzn/measurers/java.sh — Java / JVM measurements
set -euo pipefail

results='[]'

# Recompute build flavor locally so measurer is self-contained.
build=""
if [[ -f "build.gradle" || -f "build.gradle.kts" || \
      -f "settings.gradle" || -f "settings.gradle.kts" ]]; then
    build="gradle"
elif [[ -f "pom.xml" ]]; then
    build="maven"
fi

gw="gradle"
[[ -x "./gradlew" ]] && gw="./gradlew"

# ---------------------------------------------------------------------------
# 1. Build (quality)
# Counts WARNING + ERROR lines from compile output.
# Score: 100 - errors*10 - warnings*2 (floor 0).
# ---------------------------------------------------------------------------
build_output=""
build_tool=""
if [[ "$build" == "maven" ]] && command -v mvn &>/dev/null; then
    build_output=$(mvn -q compile 2>&1) || true
    build_tool="mvn-compile"
elif [[ "$build" == "gradle" ]]; then
    if [[ "$gw" == "./gradlew" ]] || command -v gradle &>/dev/null; then
        build_output=$($gw build -x test 2>&1) || true
        build_tool="gradle-build"
    fi
fi

if [[ -n "$build_output" ]]; then
    warning_count=$(echo "$build_output" | grep -cE '(\[WARNING\]|warning:)' 2>/dev/null) || warning_count=0
    error_count=$(echo "$build_output"   | grep -cE '(\[ERROR\]|error:)'     2>/dev/null) || error_count=0

    lint_score=100
    lint_score=$(( lint_score - error_count * 10 ))
    lint_score=$(( lint_score - warning_count * 2 ))
    if (( lint_score < 0 )); then lint_score=0; fi

    results=$(echo "$results" | jq --argjson s "$lint_score" \
        --argjson e "$error_count" --argjson w "$warning_count" \
        --arg t "$build_tool" \
        '. + [{
            "category": "quality",
            "score": $s,
            "max_score": 100,
            "details": {"errors": $e, "warnings": $w},
            "tool": $t,
            "raw_output": ""
        }]')
fi

# ---------------------------------------------------------------------------
# 2. OWASP dependency-check (security)
# Skip silently if not configured. Parses vulnerable-dependency count.
# ---------------------------------------------------------------------------
sec_output=""
sec_tool=""
if command -v dependency-check &>/dev/null; then
    sec_output=$(dependency-check --project kyzn-scan --scan . --format CSV --out . 2>&1) || true
    sec_tool="dependency-check"
elif [[ "$build" == "maven" ]] && command -v mvn &>/dev/null; then
    sec_output=$(mvn -q org.owasp:dependency-check-maven:check 2>&1) || true
    sec_tool="mvn-owasp"
elif [[ "$build" == "gradle" ]] && { [[ "$gw" == "./gradlew" ]] || command -v gradle &>/dev/null; }; then
    sec_output=$($gw dependencyCheckAnalyze 2>&1) || true
    sec_tool="gradle-owasp"
fi

if [[ -n "$sec_output" ]] && echo "$sec_output" | grep -qE 'identified with known vulnerabilities|One or more dependencies'; then
    vuln_count=$(echo "$sec_output" | grep -cE '(CVE-[0-9]+-[0-9]+|^.+\(.+\):\s+CVE)' 2>/dev/null) || vuln_count=0

    sec_score=100
    sec_score=$(( sec_score - vuln_count * 20 ))
    if (( sec_score < 0 )); then sec_score=0; fi

    results=$(echo "$results" | jq --argjson s "$sec_score" --argjson v "$vuln_count" \
        --arg t "$sec_tool" \
        '. + [{
            "category": "security",
            "score": $s,
            "max_score": 100,
            "details": {"vulnerabilities": $v},
            "tool": $t,
            "raw_output": ""
        }]')
fi

# ---------------------------------------------------------------------------
# 3. Test file ratio (testing)
# ---------------------------------------------------------------------------
if [[ -n "$build" ]]; then
    test_files=$(find . \( -name '*Test.java' -o -name '*Tests.java' \
        -o -path '*/src/test/java/*' -o -path '*/src/test/kotlin/*' \) -type f \
        -not -path '*/target/*' -not -path '*/build/*' \
        -not -path '*/out/*' -not -path '*/.gradle/*' 2>/dev/null | wc -l) || true
    src_files=$(find . -name '*.java' -type f \
        -not -path '*/target/*' -not -path '*/build/*' \
        -not -path '*/out/*' -not -path '*/.gradle/*' 2>/dev/null | wc -l) || true

    test_ratio=0
    if (( src_files > 0 )); then
        test_ratio=$(( (test_files * 100) / src_files ))
    fi
    if (( test_ratio > 100 )); then test_ratio=100; fi

    results=$(echo "$results" | jq --argjson s "$test_ratio" \
        --argjson tf "$test_files" --argjson sf "$src_files" \
        '. + [{
            "category": "testing",
            "score": $s,
            "max_score": 100,
            "details": {"test_files": $tf, "source_files": $sf},
            "tool": "java-test-ratio",
            "raw_output": ""
        }]')
fi

echo "$results"
