#!/usr/bin/env bash
# kyzn/measurers/go.sh — Go measurements
set -euo pipefail

results='[]'

# ---------------------------------------------------------------------------
# 1. go vet (quality)
# ---------------------------------------------------------------------------
if command -v go &>/dev/null; then
    vet_output=$(go vet ./... 2>&1) || true
    vet_issues=$(echo "$vet_output" | grep -c '^' 2>/dev/null) || true
    # Empty output = 0 issues
    [[ -z "$vet_output" ]] && vet_issues=0

    vet_score=100
    vet_score=$(( vet_score - vet_issues * 5 ))
    (( vet_score < 0 )) && vet_score=0

    results=$(echo "$results" | jq --argjson s "$vet_score" --argjson i "$vet_issues" \
        '. + [{
            "category": "quality",
            "score": $s,
            "max_score": 100,
            "details": {"vet_issues": $i},
            "tool": "go-vet",
            "raw_output": ""
        }]')
fi

# ---------------------------------------------------------------------------
# 2. govulncheck (security)
# ---------------------------------------------------------------------------
if command -v govulncheck &>/dev/null; then
    vuln_output=$(govulncheck -json ./... 2>/dev/null) || true

    if [[ -n "$vuln_output" ]] && echo "$vuln_output" | jq . &>/dev/null; then
        vuln_count=$(echo "$vuln_output" | jq '[.vulns[]? | select(.modules)] | length') || true
        vuln_count="${vuln_count:-0}"

        sec_score=100
        sec_score=$(( sec_score - vuln_count * 20 ))
        (( sec_score < 0 )) && sec_score=0

        results=$(echo "$results" | jq --argjson s "$sec_score" --argjson v "$vuln_count" \
            '. + [{
                "category": "security",
                "score": $s,
                "max_score": 100,
                "details": {"vulnerabilities": $v},
                "tool": "govulncheck",
                "raw_output": ""
            }]')
    fi
fi

# ---------------------------------------------------------------------------
# 3. Test file ratio (testing)
# ---------------------------------------------------------------------------
if command -v go &>/dev/null; then
    test_files=$(find . -name '*_test.go' -not -path '*/vendor/*' 2>/dev/null | wc -l) || true
    src_files=$(find . -name '*.go' -not -name '*_test.go' -not -path '*/vendor/*' 2>/dev/null | wc -l) || true

    test_ratio=0
    if (( src_files > 0 )); then
        test_ratio=$(( (test_files * 100) / src_files ))
    fi
    (( test_ratio > 100 )) && test_ratio=100

    results=$(echo "$results" | jq --argjson s "$test_ratio" \
        --argjson tf "$test_files" --argjson sf "$src_files" \
        '. + [{
            "category": "testing",
            "score": $s,
            "max_score": 100,
            "details": {"test_files": $tf, "source_files": $sf},
            "tool": "go-test-ratio",
            "raw_output": ""
        }]')
fi

echo "$results"
