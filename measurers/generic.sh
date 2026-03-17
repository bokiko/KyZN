#!/usr/bin/env bash
# kyzn/measurers/generic.sh — Language-agnostic measurements
# Outputs JSON array of measurement results
set -euo pipefail

results='[]'

# ---------------------------------------------------------------------------
# 1. TODO/FIXME/HACK count (quality indicator)
# ---------------------------------------------------------------------------
todo_count=0
if command -v grep &>/dev/null; then
    todo_count=$(grep -rn --include='*.py' --include='*.js' --include='*.ts' --include='*.tsx' \
        --include='*.jsx' --include='*.go' --include='*.rs' --include='*.java' \
        -E '(TODO|FIXME|HACK|XXX|WORKAROUND)\b' . 2>/dev/null | grep -v node_modules | grep -v '.git/' | wc -l) || true
fi

# Score: fewer TODOs = better (0 = 100, 50+ = 0)
todo_score=100
if (( todo_count > 0 )); then
    todo_score=$(( 100 - (todo_count * 2) ))
    (( todo_score < 0 )) && todo_score=0
fi

results=$(echo "$results" | jq --argjson s "$todo_score" --argjson c "$todo_count" \
    '. + [{
        "category": "quality",
        "score": $s,
        "max_score": 100,
        "details": {"todo_count": $c},
        "tool": "grep-todos",
        "raw_output": ""
    }]')

# ---------------------------------------------------------------------------
# 2. Git health (uncommitted changes, unpushed commits)
# ---------------------------------------------------------------------------
if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
    dirty_files=$(git status --porcelain 2>/dev/null | wc -l) || true
    unpushed=$(git log --oneline '@{u}..HEAD' 2>/dev/null | wc -l) || true

    git_score=100
    (( dirty_files > 10 )) && git_score=$(( git_score - 20 ))
    (( dirty_files > 0 )) && git_score=$(( git_score - 10 ))
    (( unpushed > 5 )) && git_score=$(( git_score - 20 ))

    results=$(echo "$results" | jq --argjson s "$git_score" --argjson d "$dirty_files" --argjson u "$unpushed" \
        '. + [{
            "category": "quality",
            "score": $s,
            "max_score": 100,
            "details": {"dirty_files": $d, "unpushed_commits": $u},
            "tool": "git-health",
            "raw_output": ""
        }]')
fi

# ---------------------------------------------------------------------------
# 3. Large files (potential performance issue)
# ---------------------------------------------------------------------------
large_files=0
if command -v find &>/dev/null; then
    large_files=$(find . -not -path './.git/*' -not -path './node_modules/*' \
        -not -path './.venv/*' -not -path './target/*' -not -path './vendor/*' \
        -type f -size +1M 2>/dev/null | wc -l) || true
fi

large_score=100
(( large_files > 0 )) && large_score=$(( 100 - (large_files * 10) ))
(( large_score < 0 )) && large_score=0

results=$(echo "$results" | jq --argjson s "$large_score" --argjson c "$large_files" \
    '. + [{
        "category": "performance",
        "score": $s,
        "max_score": 100,
        "details": {"large_files_count": $c},
        "tool": "file-size-check",
        "raw_output": ""
    }]')

# ---------------------------------------------------------------------------
# 4. Security: check for potential secrets in code
# ---------------------------------------------------------------------------
secret_patterns='(api[_-]?key|secret[_-]?key|password|token|private[_-]?key)\s*[=:]\s*["\x27][^"\x27]{8,}'
secrets_found=0
if command -v grep &>/dev/null; then
    secrets_found=$(grep -rniE "$secret_patterns" . \
        --include='*.py' --include='*.js' --include='*.ts' --include='*.go' --include='*.rs' \
        --include='*.yaml' --include='*.yml' --include='*.json' --include='*.toml' \
        2>/dev/null | grep -v node_modules | grep -v '.git/' | grep -v '.env.example' | wc -l) || true
fi

secret_score=100
(( secrets_found > 0 )) && secret_score=$(( 100 - (secrets_found * 25) ))
(( secret_score < 0 )) && secret_score=0

results=$(echo "$results" | jq --argjson s "$secret_score" --argjson c "$secrets_found" \
    '. + [{
        "category": "security",
        "score": $s,
        "max_score": 100,
        "details": {"potential_secrets": $c},
        "tool": "secret-scan",
        "raw_output": ""
    }]')

# ---------------------------------------------------------------------------
# 5. Documentation: README exists and has content
# ---------------------------------------------------------------------------
doc_score=0
if [[ -f "README.md" ]]; then
    readme_lines=$(wc -l < README.md)
    if (( readme_lines > 50 )); then
        doc_score=80
    elif (( readme_lines > 20 )); then
        doc_score=60
    elif (( readme_lines > 5 )); then
        doc_score=40
    else
        doc_score=20
    fi

    # Check for sections
    if grep -qi 'install' README.md 2>/dev/null; then
        doc_score=$(( doc_score + 5 ))
    fi
    if grep -qi 'usage' README.md 2>/dev/null; then
        doc_score=$(( doc_score + 5 ))
    fi
    if grep -qi 'license' README.md 2>/dev/null; then
        doc_score=$(( doc_score + 5 ))
    fi
    if grep -qi 'contributing' README.md 2>/dev/null; then
        doc_score=$(( doc_score + 5 ))
    fi
    (( doc_score > 100 )) && doc_score=100
fi

results=$(echo "$results" | jq --argjson s "$doc_score" \
    '. + [{
        "category": "documentation",
        "score": $s,
        "max_score": 100,
        "details": {},
        "tool": "readme-check",
        "raw_output": ""
    }]')

# Output
echo "$results"
