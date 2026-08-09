#!/usr/bin/env bash
# Generate or verify deterministic repository facts embedded in project docs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# `git show :path | grep -q pattern` is not safe here. `grep -q` stops reading at
# its first match, and once the blob outgrows the pipe buffer Git is still
# writing when the reader goes away — so Git dies of SIGPIPE. `set -o pipefail`
# promotes that 141 to the pipeline's status and `set -e` aborts the script with
# no diagnostic at all, which is exactly how a macOS job failed with a bare
# "Process completed with exit code 141". Read the blob first, then match it.
index_blob_matches() {
    local path="$1" pattern="$2" blob
    blob=$(git show ":$path")
    grep -q "$pattern" <<< "$blob"
}

all_files=$(git ls-files --cached | LC_ALL=C sort -u)
tracked_files=$(printf '%s\n' "$all_files" | awk 'NF { count++ } END { print count + 0 }')
shell_files=$(printf '%s\n' "$all_files" | awk '/\.sh$/ || $0 == "kyzn" { count++ } END { print count + 0 }')
shell_lines=0
while IFS= read -r file; do
    [[ "$file" == *.sh || "$file" == "kyzn" ]] || continue
    lines=$(git show ":$file" | wc -l | tr -d ' ')
    shell_lines=$((shell_lines + lines))
done <<< "$all_files"
selftest_lines=$(git show :tests/selftest.sh | wc -l | tr -d ' ')
selftest_functions=$(git show :tests/selftest.sh | grep -Ec '^test_[a-zA-Z0-9_]+\(\)')
language_profiles=$(printf '%s\n' "$all_files" | grep -Ec '^measurers/(node|python|rust|go|csharp|java)\.sh$')

for language in node python rust go csharp java; do
    git cat-file -e ":measurers/$language.sh" 2>/dev/null && \
    git cat-file -e ":templates/conventions/$language.md" 2>/dev/null || {
        echo "missing measurer or convention profile for $language" >&2
        exit 1
    }
    index_blob_matches lib/detect.sh "$language)"
    index_blob_matches lib/measure.sh "$language)"
    index_blob_matches lib/allowlist.sh "$language)"
    index_blob_matches lib/verify.sh "$language)"
done
ci_yaml=$(git show :.github/workflows/ci.yml)
grep -q 'runs-on: ubuntu-latest' <<< "$ci_yaml"
grep -q 'runs-on: macos-latest' <<< "$ci_yaml"
[[ $(grep -c 'name: Run quick tests' <<< "$ci_yaml") -eq 2 ]]
[[ $(grep -c 'name: Run full tests' <<< "$ci_yaml") -eq 2 ]]

generate() {
    cat <<EOF
<!-- BEGIN GENERATED REPOSITORY FACTS -->
- Repository files: **$tracked_files**
- Bash entrypoints/modules/scripts: **$shell_files** files, **$shell_lines** lines
- Self-test harness: **$selftest_functions** test functions, **$selftest_lines** lines (runtime assertion totals are reported by the suite, not hardcoded)
- Project profiles: **$language_profiles** languages plus the generic fallback
- CI matrix: **Linux and macOS**, each running quick and full self-tests
<!-- END GENERATED REPOSITORY FACTS -->
EOF
}

if [[ "${1:-}" == "--print" ]]; then
    echo "<!-- Facts are generated from the Git index. Stage intended additions/changes before regenerating. -->" >&2
    generate
    exit 0
fi

expected=$(generate)
failed=false
for doc in README.md CLAUDE.md; do
    actual=$(awk '/<!-- BEGIN GENERATED REPOSITORY FACTS -->/,/<!-- END GENERATED REPOSITORY FACTS -->/' "$doc")
    if [[ "$actual" != "$expected" ]]; then
        echo "$doc repository facts are stale; replace its generated block with:" >&2
        printf '%s\n' "$expected" >&2
        failed=true
    fi
done

$failed && exit 1
echo "Repository facts are current."
