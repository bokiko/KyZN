#!/usr/bin/env bash
# kyzn/measurers/python.sh — Python measurements
set -euo pipefail

results='[]'

# ---------------------------------------------------------------------------
# 1. Ruff (linting + quality)
# ---------------------------------------------------------------------------
if command -v ruff &>/dev/null; then
    ruff_output=$(ruff check . --output-format json 2>/dev/null) || true

    if [[ -n "$ruff_output" ]] && echo "$ruff_output" | jq . &>/dev/null; then
        IFS=$'\t' read -r error_count fixable_count total_issues <<< "$(echo "$ruff_output" | jq -r '[
            ([.[] | select(.fix == null)] | length),
            ([.[] | select(.fix != null)] | length),
            length
        ] | @tsv')"

        lint_score=100
        (( lint_score -= error_count * 3 )) || true
        (( lint_score -= fixable_count * 1 )) || true
        if (( lint_score < 0 )); then lint_score=0; fi

        results=$(echo "$results" | jq --argjson s "$lint_score" \
            --argjson e "$error_count" --argjson f "$fixable_count" --argjson t "$total_issues" \
            '. + [{
                "category": "quality",
                "score": $s,
                "max_score": 100,
                "details": {"errors": $e, "fixable": $f, "total": $t},
                "tool": "ruff",
                "raw_output": ""
            }]')
    fi
fi

# ---------------------------------------------------------------------------
# 2. Mypy (type checking)
# ---------------------------------------------------------------------------
if command -v mypy &>/dev/null; then
    mypy_output=$(mypy . --no-error-summary 2>&1) || true
    mypy_errors=$(echo "$mypy_output" | grep -c ': error:' 2>/dev/null) || true

    type_score=100
    (( type_score -= mypy_errors * 3 )) || true
    if (( type_score < 0 )); then type_score=0; fi

    results=$(echo "$results" | jq --argjson s "$type_score" --argjson e "$mypy_errors" \
        '. + [{
            "category": "quality",
            "score": $s,
            "max_score": 100,
            "details": {"type_errors": $e},
            "tool": "mypy",
            "raw_output": ""
        }]')
fi

# ---------------------------------------------------------------------------
# 3. pytest coverage (testing)
# ---------------------------------------------------------------------------
if command -v pytest &>/dev/null; then
    # Check for existing coverage
    if [[ -f ".coverage" ]] || [[ -f "htmlcov/index.html" ]]; then
        # Try to get coverage percentage from coverage report
        if command -v coverage &>/dev/null; then
            cov_output=$(coverage report --format=total 2>/dev/null) || true
            if [[ "$cov_output" =~ ^[0-9]+$ ]]; then
                results=$(echo "$results" | jq --argjson s "$cov_output" --argjson p "$cov_output" \
                    '. + [{
                        "category": "testing",
                        "score": $s,
                        "max_score": 100,
                        "details": {"coverage_percent": $p},
                        "tool": "pytest-cov",
                        "raw_output": ""
                    }]')
            fi
        fi
    fi

    # Count test files
    test_files=$(find . -name 'test_*.py' -o -name '*_test.py' 2>/dev/null | grep -v __pycache__ | grep -v .venv | wc -l) || true
    src_files=$(find . -name '*.py' -not -name 'test_*' -not -name '*_test.py' -not -path './.venv/*' -not -path '*__pycache__*' 2>/dev/null | wc -l) || true

    test_ratio=0
    if (( src_files > 0 )); then
        test_ratio=$(( (test_files * 100) / src_files ))
    fi

    # Score: test file ratio (rough proxy for test coverage)
    test_score=$test_ratio
    if (( test_score > 100 )); then test_score=100; fi

    results=$(echo "$results" | jq --argjson s "$test_score" \
        --argjson tf "$test_files" --argjson sf "$src_files" --argjson r "$test_ratio" \
        '. + [{
            "category": "testing",
            "score": $s,
            "max_score": 100,
            "details": {"test_files": $tf, "source_files": $sf, "test_ratio_pct": $r},
            "tool": "test-file-ratio",
            "raw_output": ""
        }]')
fi

# ---------------------------------------------------------------------------
# 4. pip-audit (security)
# ---------------------------------------------------------------------------
if command -v pip-audit &>/dev/null; then
    audit_output=$(pip-audit --format json 2>/dev/null) || true

    if [[ -n "$audit_output" ]] && echo "$audit_output" | jq . &>/dev/null; then
        vuln_count=$(echo "$audit_output" | jq 'length')

        sec_score=100
        (( sec_score -= vuln_count * 15 )) || true
        if (( sec_score < 0 )); then sec_score=0; fi

        results=$(echo "$results" | jq --argjson s "$sec_score" --argjson v "$vuln_count" \
            '. + [{
                "category": "security",
                "score": $s,
                "max_score": 100,
                "details": {"vulnerabilities": $v},
                "tool": "pip-audit",
                "raw_output": ""
            }]')
    fi
fi

echo "$results"
