# KyZN Documentation & Communication Audit
**Agent:** scribe
**Date:** 2026-03-20
**Scope:** All user-facing text, documentation, templates, error messages, and onboarding flows

---

## Executive Summary

KyZN has strong documentation foundations. The README is genuinely excellent — clear value prop, accurate examples, well-structured diagrams. The `kyzn --help` output and doctor flow are polished. The AI-facing templates (system prompts, specialist prompts) are among the best-written parts of the project.

The main documentation gaps are: no CONTRIBUTING.md, no CHANGELOG, no architecture doc, and a visible inconsistency in how the project name is written (KyZN vs kyzn). A handful of error messages are terse where they should give actionable guidance, and one generated report has a visible data bug (scores show as 0/empty in generated reports).

Overall rating: **B+** — better than most open-source CLI tools; fixable issues are concrete and small.

---

## 1. README Quality

### What Works Well

The README is well above average for a CLI tool. Specific strengths:

**Value proposition** — The opening tagline "measure, analyze, improve, verify, ship" captures the pipeline in five words. The ASCII-art workflow diagrams for both `kyzn improve` and `kyzn analyze` show architecture at a glance without requiring prose.

**The demo block** — The full terminal session at the top of the README is accurate and shows realistic output including cost, model selection, and score delta. This is a significant asset for first-time visitors.

**Safety table** — Documenting every protection layer (branch isolation, budget cap, tool allowlist, file restrictions, etc.) in a single table is excellent. Other tools hide or omit this. The inline caveats about secret detection limitations ("This is not AST-level analysis") show appropriate honesty.

**Health score explanation** — The score breakdown table with weights and what each category measures is clear and sets correct expectations.

**Project structure** — The directory tree with one-line descriptions for every file is accurate and useful.

### Issues Found

**F1 — Badge mismatch (self-test count)**
The README badge says "156 passing" but the arbiter report confirms the selftest currently runs 79 assertions (`selftest.sh` reports `All 79 assertions passed`). The README likely reflects a planned or previous count. This is visibly wrong to anyone who runs `kyzn selftest`.

```
README badge:  tests-156%20passing
Actual (arbiter output, 2026-03-18):  All 79 assertions passed
```

**F2 — Missing macOS caveat for bash**
Installation section does not warn macOS users upfront that the system bash (3.2) is incompatible. The binary itself gives a clear error, but a user who hits it before running `kyzn doctor` has no guidance in the README. The bash 4.3+ requirement should be noted alongside the prerequisites table.

**F3 — Roadmap has no version targets**
The roadmap checkboxes show completed vs planned items but no version numbers or rough timelines. "When will Reflexion loop ship?" is unanswerable from the README. Even loose groupings ("v0.5", "future") would help users decide whether to wait or build workarounds.

**F4 — Self-test section is sparse**
```
kyzn selftest              # Quick tests (147 cases)
kyzn selftest --full       # Full suite with stress tests (156 cases)
```
Both case counts are inconsistent with current reality (79 assertions per arbiter). The distinction between "quick" and "full" is unexplained — what does `--full` add that `selftest` alone doesn't? A sentence would suffice.

**F5 — No troubleshooting section**
Common failure modes have no documentation: what happens if `gh auth` is not set up, what to do when Claude times out, how to recover from a stale lock (`rm -rf .kyzn/.improve.lock`), etc. These are the first things users will search for.

---

## 2. Inline Comments

### What Works Well

The file headers are consistent and follow the pattern `# kyzn/lib/file.sh — Short description`. Every `.sh` file has this. Function-level section dividers (`# ----`) make it easy to scan large files.

Comments explain intent where it matters:
- `# tests_ok reserved for future per-step tracking` (verify.sh:47)
- `# IMPORTANT: snap yq cannot access hidden directories (.kyzn/)` (install.sh:137)
- `# shellcheck source=lib/core.sh` (kyzn:34)
- `# Defensive JSON extraction` (execute.sh:165)
- The intentional `SC2086` disable for `$allowlist` word-splitting is explained inline.

### Issues Found

**F6 — Complex jq expressions are uncommented**
The health score computation at `measure.sh:115-121` and the dashboard aggregation at `history.sh:132-143` use multi-step jq pipelines that are non-trivial to read. Neither has a comment explaining the algorithm. The category floor check at `execute.sh:489-504` has a comment on the outer logic but not on the jq expressions themselves.

Example from `measure.sh:115`:
```bash
category_scores=$(jq '[.[] | {category, score, max_score}]
    | group_by(.category)
    | map({
        key: .[0].category,
        value: (([.[].score] | add) * 100 / ([.[].max_score] | add))
      })
    | from_entries' "$results_file" 2>/dev/null)
```
A one-line comment like `# Group by category, compute (sum_score / sum_max) * 100 for each` would make this maintainable.

**F7 — Unstage logic is silent on what it filters**
`unstage_secrets()` in `execute.sh:14-24` uses a complex regex pattern without a comment:
```bash
grep -iE '\.(env|pem|key|p12|pfx|jks)$|^\.env|credentials|kubeconfig|\.npmrc|\.pypirc'
```
A comment listing what this pattern covers would help maintainers update it confidently.

**F8 — Dead variable comment is too casual**
```bash
# tests_ok reserved for future per-step tracking
```
This is in `verify.sh:47`. The variable is declared but never used. The comment implies it was intentionally left in. It should either be removed or the comment should clarify what "future per-step tracking" means (per-step results: separate build result vs. test result).

---

## 3. User-Facing Log Messages

### What Works Well

The logging function design is clean. The color-coded prefixes (✓ green, ✗ red, ⚠ yellow, ℹ blue) are consistent throughout. The `log_dim` function for secondary information (install hints, tips) is used appropriately.

The best messages in the codebase:
- `"Build/tests still failing, but all failures are pre-existing. Continuing."` — precise and reassuring
- `"Per-category score floor breached. Aborting."` — explains what happened and what the system did
- `"Removing stale lock from a previous run (PID: ${stale_pid:-unknown})"` — includes context

### Issues Found

**F9 — Update notification tone is alarming**
```bash
echo -e "${RED}✗ KyZN is outdated${RESET} (${behind} commits behind)"
echo -e "  ${RED}Update now for better analysis accuracy and security fixes.${RESET}"
```
Both lines use red (the error color) for what is a non-blocking notification. This pattern trains users to fear red output from kyzn. Yellow (warning) with the update message would be more proportionate. Compare: `git` uses a neutral reminder, not an error.

**F10 — Lock error is not actionable enough**
```bash
log_error "Another KyZN improve is already running on this repo (PID: $stale_pid)."
log_dim "  If this is wrong, remove the lock: rm -rf $lockdir"
```
The second line is good but only appears when there is a valid stale PID. When a live PID is found, the user gets only the error and no hint. The `rm -rf` hint should appear regardless:
```
log_dim "  Wait for it to finish, or if it's stuck: rm -rf $lockdir"
```

**F11 — Claude execution failure gives no diagnosis**
```bash
log_error "Claude Code invocation failed"
```
This appears when the `claude` CLI exits non-zero (not timeout). The user has no idea if this is: auth failure, rate limit, invalid model name, CLI version mismatch, or something else. The stderr is captured to `$stderr_file` but deleted before this message is shown. At minimum, the last few lines of stderr should be shown:
```bash
log_error "Claude Code invocation failed"
tail -5 "$stderr_file" >&2 2>/dev/null
```

**F12 — `log_error` and `log_fail` are functionally identical but semantically confusing**
```bash
log_error()  { echo -e "${RED}✗${RESET} $*" >&2; }
log_fail()   { echo -e "${RED}✗${RESET} $*"; }
```
The only difference is `>&2` (stderr) vs stdout. The names imply different severity. Usage in the codebase is inconsistent — `log_fail` appears in `cmd_doctor` for missing tools while `log_error` appears in command parsing. The distinction is not documented. Consider renaming `log_fail` to `log_error_stdout` or merging them with a flag.

**F13 — Score regression message omits what the score was**
```bash
log_warn "Score regressed ($baseline_score → $after_score). Aborting."
```
This is actually good — it includes the numbers. But the subsequent action (always discard) is not mentioned. A user who configured `on_build_fail: report` will be surprised that regression always discards, not reports. The message should clarify:
```
log_warn "Score regressed ($baseline_score → $after_score). Discarding branch (regression always discards regardless of on_build_fail setting)."
```

**F14 — Approval success message is vague**
```bash
log_ok "Run $run_id approved!"
log_info "The improvements are part of the project now."
```
"The improvements are part of the project now" is false when the PR has not been merged yet. KyZN creates a PR; the human merges it. The approve command marks KyZN's local tracking as approved, not the PR. This message should say: `"Run marked as approved. Merge the PR to incorporate changes."` or check if the PR was merged.

---

## 4. Help Text (`kyzn --help`)

### What Works Well

The help output is clean and structured. Commands are grouped logically. The examples section at the bottom shows the most important usage patterns.

```
kyzn <command> [options]

Commands: [grouped clearly]
Options: [-h, -v]
Examples: [10 real-world examples]
```

### Issues Found

**F15 — `analyze` command description undersells the cost**
```
analyze         Deep analysis with Opus — finds real bugs, security issues, arch problems
```
The README says `kyzn analyze` costs approximately $20 for 4 Opus specialists. The help text gives no indication of this. A first-time user running `kyzn analyze` expecting a quick scan will be surprised. The description should mention the approximate cost:
```
analyze         Deep analysis: 4 Opus specialists in parallel (~$20)
```

**F16 — `status` and `measure` are not clearly differentiated**
Both commands show health scores. `kyzn --help` says:
```
measure         Measure project health (no changes)
status          Show health score dashboard
```
The distinction is not obvious. `status` also runs fresh measurements, shows recent history, and is effectively a superset of `measure`. The descriptions should make this explicit:
```
measure         Run measurements and show health score
status          Health score + recent run history dashboard
```

**F17 — `schedule` options not shown in help**
The help shows:
```
schedule        Set up recurring runs (cron)
```
But `kyzn schedule` requires a subcommand (`daily`, `weekly`, `off`). Running `kyzn schedule` alone produces an error. The help text should show the subcommands or at least hint at them:
```
schedule <daily|weekly|off>   Set up recurring runs via cron
```

**F18 — Options section is minimal**
```
Options:
  -h, --help      Show this help
  -v, --version   Show version
```
There are no global options (like `--dry-run`, `--verbose`) documented here. The `-v` flag on `kyzn improve` means verbose mode, not version. Running `kyzn -v` gives version, running `kyzn improve -v` enables verbose. This duality is not explained and could confuse users.

---

## 5. Error Messages — Actionability Assessment

| Message | Location | Verdict | Issue |
|---------|----------|---------|-------|
| `"Not a git repository. Run kyzn from a project root."` | core.sh | Good | Clear cause and fix |
| `"No config found. Run 'kyzn init' first, or run without --auto."` | execute.sh | Good | Two paths given |
| `"Claude Code timed out after ${claude_timeout}s"` | execute.sh | Good | Includes duration |
| `"Claude Code invocation failed"` | execute.sh | Poor | No diagnosis, no fix |
| `"Unknown command: $cmd"` | kyzn | Acceptable | Prints usage after |
| `"Another KyZN improve is already running (PID: $stale_pid)."` | execute.sh | Partial | Fix hint missing when PID is live |
| `"Could not push to remote. Create PR manually."` | report.sh | Poor | What went wrong? Auth? Network? Wrong branch? |
| `"Could not create PR. Create it manually."` | report.sh | Poor | Same issue — no diagnosis |
| `"Failed to create branch $branch_name"` | execute.sh | Poor | Why? Already exists? Permissions? |
| `"Update failed — check git status in $KYZN_ROOT"` | kyzn | Acceptable | Gives path to investigate |
| `"No report found for run $run_id"` | approve.sh | Good | Suggests `kyzn history` |
| `"Score regressed ($baseline_score → $after_score). Aborting."` | execute.sh | Good | Numbers included |
| `"Diff exceeds limit ($total_diff > $diff_limit lines). Aborting."` | execute.sh | Good | Numbers included |

**Worst offenders:** The three git/PR messages (`git push`, `gh pr create`, `git checkout -b`) all fail silently with "try manually" guidance but no diagnosis. Since stderr is suppressed with `2>/dev/null`, there is no way to see the underlying error.

---

## 6. Generated Report Quality

Two report types exist: improvement reports (`kyzn improve`) and failure reports.

### Improvement Report (`kyzn-report.md`)

**F19 — Health score shows 0 when self-improving**
The generated report at `.kyzn/reports/20260318-103733-760baee7.md` shows:
```
| Before | After | Change |
|--------|-------|--------|
| 0 | 0 | → 0 |
```
And the category scores all show empty or `-` values. This is a measurer data issue: kyzn self-applies to its own repo, but the kyzn repo has no `package.json`, `pyproject.toml`, or language-specific files, so it scores 0 across the board. The report does not explain this. A note like `"No language-specific measurements — only generic measurements apply to this project type"` would clarify.

**F20 — Failure report "Next Steps" is generic**
```
## Next Steps
- Review the changes manually
- Consider running with a more conservative mode
```
These are always identical regardless of what failed. The failure report could include: the name of the test that failed, the error output (already captured by the verification step), and a specific suggestion (e.g., if build failed → "the build log above shows the error", if test failed → "run `npm test` to reproduce").

**F21 — PR body does not link to the report file**
The PR body says `To approve: kyzn approve $run_id` but does not mention that a detailed report exists at `.kyzn/reports/$run_id.md`. A reviewer opening the PR has the diff but not the health score context. Adding `Full report: .kyzn/reports/$run_id.md` to the PR body would help.

**F22 — Cost format inconsistency**
Improvement report shows `$1.3165904999999998` — full floating point. The terminal output shows `$1.23`. The report should round to 2 decimal places: `"$(printf '%.2f' "$KYZN_CLAUDE_COST")"`.

---

## 7. Template Quality

### system-prompt.md

Well-structured. The five rules are crisp and behavioral. The "What you MUST NOT do" and "What you SHOULD do" pattern is clear. The output format instruction ("brief summary ... list of changes with file paths") is actionable.

Minor issues:
- The prohibition on `rm`, `sudo`, and `git push` is in the system prompt, but these are also partially enforced by the allowlist. The system prompt should acknowledge this: "These are also enforced by the tool allowlist, but treat them as hard rules regardless."
- No mention of what to do if the task is impossible: should Claude say so? Partially complete? Currently ambiguous.

### improvement-prompt.md

The template is clean. Placeholder replacement works correctly. The mode constraints injected at runtime are well-written and distinct.

**F23 — Template has no fallback when measurements are empty**
The `{{MEASUREMENTS}}` block renders as `[]` when no measurements are available. Claude then works with an empty measurements list and guesses what to improve. The template should handle this case:
```
{% if measurements is empty %}
No measurements available. Read the project files directly to identify improvements.
{% endif %}
```
This is a template limitation since bash string replacement doesn't support conditionals, but the logic could be added in `prompt.sh` before injection.

**F24 — Priority order in improvement-prompt.md does not match mode**
The prompt always shows this priority order:
```
1. Fix any security issues
2. Fix bugs and potential runtime errors
3. Add missing error handling
4. Improve test coverage
5. Clean up dead code
6. Improve documentation
```
But in `clean` mode, items 1-3 are explicitly excluded by the mode constraints. The priority list is contradictory with the constraints. Clean mode should either use a different priority list or the universal list should be removed.

### analysis-prompt.md

This is the best-written template in the project. The "Your Personality" section giving Claude a role as "a senior staff engineer doing a thorough code review before a critical release" produces better results than generic instructions. The "What Makes a Real Finding" vs "What Is NOT a Finding" distinction is precisely what makes the analysis output useful.

Strengths:
- Methodical thinking process is explicit (start at entry points, trace data flow, check error boundaries)
- Honesty rule ("if the code is fine, you say so. No invented issues to justify your cost.") prevents hallucinated findings
- Handoff instruction ("Your findings report will be handed to Sonnet to implement fixes") aligns Claude's output to the pipeline's needs

No significant issues.

### Specialist prompts (in analyze.sh)

All four specialist prompts (security, correctness, performance, architecture) follow the same structure and are well-differentiated. The id prefix conventions (SEC-, BUG-, PERF-, ARCH-) enable deduplication in the consensus step.

**F25 — Performance specialist includes "Dead code" which overlaps architecture**
```
7. **Dead code** — unused functions, unreachable branches, stale imports that increase load time
```
Dead code is also covered by the architecture specialist:
```
5. **Testing gaps** — critical paths without tests...
```
And it generates DEAD-001 IDs (not PERF-001). This cross-specialty contamination produces findings that the architecture reviewer also finds, increasing deduplication work for the consensus engine. Dead code should be removed from the performance specialist or explicitly noted as "if it causes load time issues."

### Profiles (security.md, testing.md, etc.)

All five profiles are well-focused and use the same internal structure. They are appropriately brief and do not repeat what the system-prompt.md already says.

Minor: the documentation profile says `"Write for the developer who will maintain this code in 6 months"` — good. But the profiles are only loaded for `kyzn improve`, not for `kyzn analyze`. A user running `kyzn analyze --focus documentation` will not get the documentation profile context. This is a code issue, not a template issue, but worth documenting.

---

## 8. Onboarding Flow

### `kyzn init` → `kyzn doctor` → `kyzn measure`

**The documented flow:**
```
kyzn init       # One-time setup
kyzn measure    # See your health score
kyzn improve    # Run improvement cycle
```

**The install.sh flow:**
```
kyzn init  →  kyzn measure  →  kyzn analyze  →  kyzn improve  →  kyzn approve
```

These two flows are different. README says `init → measure → improve`. Installer says `init → measure → analyze → improve → approve`. The `analyze` step between measure and improve is only in the installer. The README flow is simpler and more appropriate for first-time users; the installer flow is more complete. They should match.

**F26 — `kyzn init` next-steps output is in wrong order**
After `kyzn init` completes, it shows:
```
kyzn doctor    — verify prerequisites
kyzn measure   — see your project health score
kyzn analyze   — deep multi-agent code review
kyzn improve   — start your first improvement cycle
```
`kyzn doctor` is listed first, but the user presumably already ran `kyzn doctor` before `init` (as the README recommends). Listing it first here is confusing. The order should be: `measure → analyze → improve`, with `doctor` omitted (already done).

**F27 — Interview step 2 label is ambiguous**
```
How aggressive should improvements be?
  1) Deep — real improvements only (no cosmetic changes)
  2) Clean — dead weight cleanup (remove unused code, fix naming)
  3) Full — everything (maximum value per run)
```
"Aggressive" implies destructiveness. Users may interpret "Deep" as the most aggressive when it is actually the most conservative (real bugs only). A better label: `"What kind of improvements do you want?"`.

**F28 — Interview step 5 (trust level) needs more explanation**
```
Trust level for auto-merging?
  1) Guardian — always create PR, always wait for approval (recommended)
  2) Autopilot — auto-merge if build passes + tests pass + diff < threshold
```
"Auto-merge if build passes + tests pass + diff < threshold" is accurate but does not mention that autopilot uses GitHub's `gh pr merge --auto --squash`, meaning CI must still pass. Users on projects without CI will have autopilot auto-merge immediately. This should be noted.

**F29 — `kyzn doctor` does not check bash version**
`kyzn doctor` checks git, gh, claude, jq, yq — but not the bash version. Since bash 4.3+ is required, `kyzn doctor` should include:
```
bash (4.3+) — required for associative arrays
```
This is the most common failure mode for macOS users and it is not checked in the verification command.

---

## 9. Missing Documentation

| Document | Priority | Reason |
|----------|----------|--------|
| `CONTRIBUTING.md` | High | No contribution guidelines, no PR process, no development setup instructions |
| `CHANGELOG.md` | Medium | No version history, no way to see what changed between v0.3.0 and v0.4.0 |
| `docs/architecture.md` | Medium | The README covers surface structure; there is no explanation of the measurement JSON schema, history file format, or how the consensus engine works |
| Troubleshooting guide | Medium | No documented recovery procedures for common failures (stale lock, auth errors, timeouts) |
| `.kyzn.example.yaml` discoverability | Low | The example config exists but is not mentioned in the README. Users manually editing config have no reference to this file |

**CONTRIBUTING.md gap detail:** Someone wanting to add a new measurer (e.g., `measurers/java.sh`) has no guidance on the expected JSON output schema, what categories to use, or how to add a corresponding `verify_java()` function. This is a significant contributor barrier given the project's clear extension points.

The JSON schema for measurer output (each entry needs `category`, `score`, `max_score`, `details`, `tool`, `raw_output`) is currently only inferrable by reading `measurers/generic.sh` and `measure.sh`. It should be documented.

---

## 10. Tone and Consistency

### Name Inconsistency

The project name appears in three forms:
- `KyZN` — used in the README title, badge links, install.sh header, and `log_header "KyZN doctor"` etc.
- `kyzn` — used in the CLI binary name, GitHub URL (`bokiko/kyzn`), generated reports (`*Generated by [kyzn]*`), and most `log_*` messages.
- `KyZN` — used inconsistently in the `cmd_doctor` header vs `kyzn` in the improvement report footer.

The README title is `# KyZN` but the generated report footer says `Generated by [kyzn]` with lowercase. This is a small but consistent inconsistency. The convention should be: `KyZN` when referring to the product/brand, `kyzn` when referring to the command.

**Example inconsistency in report.sh:**
```bash
*Generated by [KyZN](https://github.com/bokiko/KyZN) — autonomous code improvement*
```
But the success report uses `kyzn` and the GitHub link alternates between `bokiko/kyzn` and `bokiko/KyZN`.

### Tone Assessment

The overall tone is appropriate for a developer tool: direct, specific, uses examples. There is no padding or marketing language in error messages or help text.

The interview questions are well-phrased for technical users. The analysis template's "Honest" characteristic description ("No invented issues to justify your cost") is a good example of the project's self-aware voice.

One tone issue: the update notification uses alarm language (`Update now for better analysis accuracy and security fixes`) where a calm notification would be more appropriate. The phrase "security fixes" in a warning banner trains users to dismiss it as boilerplate.

---

## Prioritized Recommendations

### High Priority (user-visible correctness)

1. **Fix badge test count** — README says 156 tests, selftest runs 79. Change badge to match reality. (F1)
2. **Fix approval message** — "The improvements are part of the project now" is wrong before PR merge. (F14)
3. **Show stderr on Claude failure** — `"Claude Code invocation failed"` with no context is a dead end. Show last 5 lines of stderr. (F11)
4. **Fix the priority list contradiction in improvement-prompt.md** — the priority order and mode constraints conflict in clean mode. (F24)
5. **Add `kyzn doctor` bash version check** — macOS is broken without this check. (F29)

### Medium Priority (UX improvement)

6. **Downgrade update notification from red to yellow** — not an error. (F9)
7. **Add lock removal hint when PID is live** — currently only shown for stale PID. (F10)
8. **Differentiate `measure` vs `status` in help** — descriptions are too similar. (F16)
9. **Show `schedule` subcommands in help** — running bare `kyzn schedule` fails. (F17)
10. **Fix `kyzn init` next-steps order** — `doctor` should not come first after init. (F26)
11. **Clarify interview question 2 label** — "aggressive" misleads about modes. (F27)
12. **Round cost to 2 decimal places in reports** — `$1.3165904999999998` is distracting. (F22)

### Lower Priority (documentation gaps)

13. **Create CONTRIBUTING.md** with measurer JSON schema and extension guide. (F-missing)
14. **Create CHANGELOG.md** — even a retroactive one for v0.4.0. (F-missing)
15. **Add troubleshooting section to README** — lock removal, auth errors, timeouts. (F5)
16. **Reference `.kyzn.example.yaml`** in README configuration section. (F-missing)
17. **Comment the complex jq expressions** in measure.sh and history.sh. (F6)
18. **Add macOS bash requirement to README** prerequisites table. (F2)

---

## What Is Working Well (Do Not Change)

These are specifically worth preserving:

- **The analysis-prompt.md template** — the "personality" framing and "What Is NOT a Finding" section produce high-quality Claude output. This is the best-written file in the project.
- **The safety table in README** — comprehensive, honest about limitations, well-formatted.
- **The doctor command** — install hints per OS, auth status checks, optional tool listing. Best-in-class for CLI tools.
- **The `log_dim` usage for tips and hints** — visually hierarchical without adding verbosity.
- **Pre-existing failure detection messaging** — `"Build/tests still failing, but all failures are pre-existing. Continuing."` is exactly right.
- **The update check design** — once-per-day, non-blocking, shows commit count behind. Non-intrusive.
- **Specialist prompt differentiation** — the four Opus specialists (security, correctness, performance, architecture) have genuinely different "personalities" that produce non-overlapping findings.

---

*Scribe audit complete. All findings reference specific file locations where relevant.*
