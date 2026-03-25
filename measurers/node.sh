#!/usr/bin/env bash
# kyzn/measurers/node.sh — Node.js/TypeScript measurements
set -euo pipefail

# Collect individual JSON objects; combined with a single jq -s call at the end
_measurements=()

# ---------------------------------------------------------------------------
# 1. npm audit (security)
# ---------------------------------------------------------------------------
if command -v npm &>/dev/null && [[ -f "package-lock.json" ]]; then
    audit_output=$(npm audit --json 2>/dev/null) || true

    if [[ -n "$audit_output" ]] && echo "$audit_output" | jq . &>/dev/null; then
        IFS=$'\t' read -r critical high moderate low total <<< "$(echo "$audit_output" | jq -r '[
            .metadata.vulnerabilities.critical // 0,
            .metadata.vulnerabilities.high // 0,
            .metadata.vulnerabilities.moderate // 0,
            .metadata.vulnerabilities.low // 0,
            .metadata.vulnerabilities.total // 0
        ] | @tsv')"

        sec_score=100
        (( sec_score -= critical * 30 )) || true
        (( sec_score -= high * 15 )) || true
        (( sec_score -= moderate * 5 )) || true
        (( sec_score -= low * 1 )) || true
        if (( sec_score < 0 )); then sec_score=0; fi

        _measurements+=("$(jq -n --argjson s "$sec_score" \
            --argjson c "$critical" --argjson h "$high" --argjson m "$moderate" \
            --argjson l "$low" --argjson t "$total" '{
                "category": "security",
                "score": $s,
                "max_score": 100,
                "details": {
                    "critical": $c, "high": $h,
                    "moderate": $m, "low": $l, "total": $t
                },
                "tool": "npm-audit",
                "raw_output": ""
            }')")
    fi
fi

# ---------------------------------------------------------------------------
# 2. ESLint (quality)
# ---------------------------------------------------------------------------
if command -v npx &>/dev/null; then
    eslint_output=""
    # Try eslint via npx
    if npx eslint --version &>/dev/null 2>&1; then
        eslint_output=$(npx eslint . --format json 2>/dev/null) || true
    fi

    if [[ -n "$eslint_output" ]] && echo "$eslint_output" | jq . &>/dev/null; then
        IFS=$'\t' read -r error_count warning_count <<< "$(echo "$eslint_output" | jq -r '[
            ([.[] | .errorCount] | add // 0),
            ([.[] | .warningCount] | add // 0)
        ] | @tsv')"

        lint_score=100
        (( lint_score -= error_count * 5 )) || true
        (( lint_score -= warning_count * 1 )) || true
        if (( lint_score < 0 )); then lint_score=0; fi

        _measurements+=("$(jq -n --argjson s "$lint_score" \
            --argjson e "$error_count" --argjson w "$warning_count" '{
                "category": "quality",
                "score": $s,
                "max_score": 100,
                "details": {"errors": $e, "warnings": $w},
                "tool": "eslint",
                "raw_output": ""
            }')")
    fi
fi

# ---------------------------------------------------------------------------
# 3. TypeScript errors (quality)
# ---------------------------------------------------------------------------
if command -v npx &>/dev/null && [[ -f "tsconfig.json" ]]; then
    tsc_output=$(npx tsc --noEmit 2>&1) || true
    tsc_errors=$(echo "$tsc_output" | grep -c 'error TS' 2>/dev/null) || true

    ts_score=100
    (( ts_score -= tsc_errors * 3 )) || true
    if (( ts_score < 0 )); then ts_score=0; fi

    _measurements+=("$(jq -n --argjson s "$ts_score" --argjson e "$tsc_errors" '{
        "category": "quality",
        "score": $s,
        "max_score": 100,
        "details": {"type_errors": $e},
        "tool": "tsc",
        "raw_output": ""
    }')")
fi

# ---------------------------------------------------------------------------
# 4. Test coverage (testing)
# ---------------------------------------------------------------------------
# Check for existing coverage report
coverage_pct=0
coverage_found=false

if [[ -f "coverage/coverage-summary.json" ]]; then
    coverage_pct=$(jq '.total.lines.pct // 0' coverage/coverage-summary.json 2>/dev/null) || true
    coverage_found=true
fi

if $coverage_found; then
    # Convert to integer
    coverage_int=${coverage_pct%.*}

    _measurements+=("$(jq -n --argjson s "$coverage_int" --argjson p "$coverage_int" '{
        "category": "testing",
        "score": $s,
        "max_score": 100,
        "details": {"coverage_percent": $p},
        "tool": "coverage-report",
        "raw_output": ""
    }')")
fi

# ---------------------------------------------------------------------------
# 5. Outdated dependencies (quality)
# ---------------------------------------------------------------------------
if command -v npm &>/dev/null && [[ -f "package.json" ]]; then
    outdated_output=$(npm outdated --json 2>/dev/null) || true

    if [[ -n "$outdated_output" ]] && echo "$outdated_output" | jq . &>/dev/null; then
        IFS=$'\t' read -r outdated_count major_outdated <<< "$(echo "$outdated_output" | jq -r '[
            length,
            ([to_entries[] | select(.value.current != .value.latest)] | length)
        ] | @tsv')"

        dep_score=100
        (( dep_score -= major_outdated * 3 )) || true
        if (( dep_score < 0 )); then dep_score=0; fi

        _measurements+=("$(jq -n --argjson s "$dep_score" --argjson c "$outdated_count" '{
            "category": "quality",
            "score": $s,
            "max_score": 100,
            "details": {"outdated_packages": $c},
            "tool": "npm-outdated",
            "raw_output": ""
        }')")
    fi
fi

if (( ${#_measurements[@]} > 0 )); then
    printf '%s\n' "${_measurements[@]}" | jq -s '.'
else
    echo '[]'
fi
