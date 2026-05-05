#!/usr/bin/env bash
# kyzn/measurers/csharp.sh — C# / .NET measurements
set -euo pipefail

results='[]'

# ---------------------------------------------------------------------------
# 1. dotnet build (quality)
# Counts warnings + errors. Score: 100 - errors*10 - warnings*2 (floor 0).
# ---------------------------------------------------------------------------
if command -v dotnet &>/dev/null; then
    build_output=$(dotnet build --nologo -v quiet 2>&1) || true

    if [[ -n "$build_output" ]]; then
        warning_count=$(echo "$build_output" | grep -cE ': warning ' 2>/dev/null) || warning_count=0
        error_count=$(echo "$build_output"   | grep -cE ': error '   2>/dev/null) || error_count=0

        lint_score=100
        lint_score=$(( lint_score - error_count * 10 ))
        lint_score=$(( lint_score - warning_count * 2 ))
        if (( lint_score < 0 )); then lint_score=0; fi

        results=$(echo "$results" | jq --argjson s "$lint_score" \
            --argjson e "$error_count" --argjson w "$warning_count" \
            '. + [{
                "category": "quality",
                "score": $s,
                "max_score": 100,
                "details": {"errors": $e, "warnings": $w},
                "tool": "dotnet-build",
                "raw_output": ""
            }]')
    fi
fi

# ---------------------------------------------------------------------------
# 2. dotnet list package --vulnerable (security)
# ---------------------------------------------------------------------------
if command -v dotnet &>/dev/null; then
    vuln_output=$(dotnet list package --vulnerable --include-transitive 2>/dev/null) || true

    if [[ -n "$vuln_output" ]]; then
        # Each vulnerable package row starts with '> ' under the project header
        vuln_count=$(echo "$vuln_output" | grep -cE '^\s*>\s' 2>/dev/null) || vuln_count=0

        sec_score=100
        sec_score=$(( sec_score - vuln_count * 20 ))
        if (( sec_score < 0 )); then sec_score=0; fi

        results=$(echo "$results" | jq --argjson s "$sec_score" --argjson v "$vuln_count" \
            '. + [{
                "category": "security",
                "score": $s,
                "max_score": 100,
                "details": {"vulnerabilities": $v},
                "tool": "dotnet-list-vulnerable",
                "raw_output": ""
            }]')
    fi
fi

# ---------------------------------------------------------------------------
# 3. Test file ratio (testing)
# ---------------------------------------------------------------------------
if command -v dotnet &>/dev/null; then
    test_files=$(find . \( -name '*Tests.cs' -o -name '*Test.cs' -o -path '*/Tests/*.cs' \) \
        -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | wc -l) || true
    src_files=$(find . -name '*.cs' \
        -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | wc -l) || true

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
            "tool": "csharp-test-ratio",
            "raw_output": ""
        }]')
fi

echo "$results"
