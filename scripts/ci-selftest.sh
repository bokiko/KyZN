#!/usr/bin/env bash
# Run tests/selftest.sh for CI and fail unless the suite both exits 0 and prints
# its canonical summary banner.
#
# This closes two ways a CI job can report success without having tested KyZN:
#
#   1. Unsupported interpreter. KyZN requires Bash 4.3+ (lib/allowlist.sh uses
#      namerefs) and the `kyzn` entrypoint refuses to start on anything older,
#      but `bash tests/selftest.sh` silently inherits whatever `bash` resolves
#      to — Bash 3.2 on stock macOS. Pick a supported interpreter explicitly, or
#      fail saying so.
#
#   2. Truncation. A suite that dies part-way through can still leave the step
#      shell reporting success: Bash 3.2 runs an EXIT trap with `$?` already
#      cleared when the shell aborts on a `set -u` violation. Requiring the
#      summary banner makes "never reached the end" a failure on its own, no
#      matter what exit status the suite handed back.
#
# Kept Bash 3.2 compatible on purpose — on macOS runners this script is itself
# executed by the stock interpreter, before it has chosen a better one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The canonical banner from tests/selftest.sh. Matched on its ASCII skeleton so
# the assertion does not depend on the locale or on ANSI colour being enabled.
BANNER_PATTERN='[0-9]+ passed.*[0-9]+ failed.*[0-9]+ skipped'

# Echo the path of the first Bash 4.3+ interpreter available, or return 1.
select_interpreter() {
    local candidate resolved
    for candidate in bash /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
        resolved=$(command -v "$candidate" 2>/dev/null) || continue
        if "$resolved" -c 'exit $(( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) ))' 2>/dev/null; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done
    return 1
}

interpreter=$(select_interpreter) || {
    echo "ci-selftest: no Bash 4.3+ interpreter found — KyZN requires Bash 4.3 or later" >&2
    echo "ci-selftest: install one (macOS: brew install bash) before running the self-tests" >&2
    exit 1
}

echo "ci-selftest: interpreter $interpreter ($("$interpreter" -c 'echo "$BASH_VERSION"'))"

log_file="${TMPDIR:-/tmp}/kyzn-ci-selftest.$$.log"
trap 'rm -f "$log_file"' EXIT

"$interpreter" "$ROOT/tests/selftest.sh" "$@" 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}

if ! LC_ALL=C grep -Eq "$BANNER_PATTERN" "$log_file"; then
    echo "ci-selftest: self-test summary banner never printed — the suite did not run to completion" >&2
    echo "ci-selftest: treating this as a failure even though the suite exited $status" >&2
    exit 1
fi

if [[ "$status" -ne 0 ]]; then
    echo "ci-selftest: self-test suite exited $status" >&2
    exit "$status"
fi

echo "ci-selftest: summary banner present and suite exited 0"
