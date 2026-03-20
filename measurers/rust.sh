#!/usr/bin/env bash
# kyzn/measurers/rust.sh — Rust measurements
set -euo pipefail

results='[]'

# ---------------------------------------------------------------------------
# 1. Cargo clippy (quality)
# ---------------------------------------------------------------------------
if command -v cargo &>/dev/null; then
    clippy_output=$(cargo clippy --message-format json 2>/dev/null) || true

    if [[ -n "$clippy_output" ]]; then
        warning_count=$(echo "$clippy_output" | grep -c '"level":"warning"' 2>/dev/null) || true
        error_count=$(echo "$clippy_output" | grep -c '"level":"error"' 2>/dev/null) || true

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
                "tool": "cargo-clippy",
                "raw_output": ""
            }]')
    fi
fi

# ---------------------------------------------------------------------------
# 2. Cargo audit (security)
# ---------------------------------------------------------------------------
if command -v cargo-audit &>/dev/null || cargo audit --version &>/dev/null 2>&1; then
    audit_output=$(cargo audit --json 2>/dev/null) || true

    if [[ -n "$audit_output" ]] && echo "$audit_output" | jq . &>/dev/null; then
        vuln_count=$(echo "$audit_output" | jq '.vulnerabilities.found // 0')

        sec_score=100
        sec_score=$(( sec_score - vuln_count * 20 ))
        if (( sec_score < 0 )); then sec_score=0; fi

        results=$(echo "$results" | jq --argjson s "$sec_score" --argjson v "$vuln_count" \
            '. + [{
                "category": "security",
                "score": $s,
                "max_score": 100,
                "details": {"vulnerabilities": $v},
                "tool": "cargo-audit",
                "raw_output": ""
            }]')
    fi
fi

# ---------------------------------------------------------------------------
# 3. Test count (testing)
# ---------------------------------------------------------------------------
if command -v cargo &>/dev/null; then
    test_files=$(find . -name '*.rs' -path '*/tests/*' -o -name '*test*.rs' 2>/dev/null | grep -v target | wc -l) || true
    src_files=$(find . -name '*.rs' -not -path '*/target/*' -not -path '*/tests/*' 2>/dev/null | wc -l) || true

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
            "tool": "rust-test-ratio",
            "raw_output": ""
        }]')
fi

echo "$results"
