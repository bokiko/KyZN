# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is KyZN

KyZN (from "kaizen") is a pure-Bash CLI that autonomously improves code quality. It runs real language tools to produce a health score, invokes Claude Code to make improvements, gates changes behind build/test verification and score regression checks, then opens a GitHub PR with before/after comparison. Supports Node.js, Python, Rust, Go, C# / .NET, and Java / JVM.

## Prerequisites

Bash 4.3+, `git`, `gh` (GitHub CLI), `claude` (Anthropic CLI), `jq`, `yq`, and either Perl or Python 3 for portable safety controllers. Language-specific tools are optional (eslint/tsc, ruff/mypy, cargo, go vet, etc.).

## Commands

```bash
# Run tests
kyzn selftest              # Quick self-test suite
kyzn selftest --full       # Include stress tests
bash tests/selftest.sh     # Direct test runner

# Lint (matches CI)
shellcheck -S warning kyzn lib/*.sh measurers/*.sh tests/selftest.sh tests/toolchain/run-matrix.sh

# Usage
kyzn doctor                # Check prerequisites
kyzn doctor --install --allow-unsafe-host-execution  # Opt in to dependency install on this host
kyzn init                  # Interactive setup → .kyzn/config.yaml
kyzn measure               # Static measurements (no project commands)
kyzn measure --allow-unsafe-host-execution  # Include package/build-tool measurements
kyzn fix --allow-unsafe-host-execution       # Deep analysis + auto-fix → PR (recommended)
kyzn fix --auto --allow-unsafe-host-execution  # Non-interactive; manual PR review required
kyzn analyze               # 4 Opus specialists + consensus report (no changes)
kyzn quick --allow-unsafe-host-execution      # Quick single-pass improvement
kyzn quick --auto --allow-unsafe-host-execution  # Non-interactive; manual PR review required
```

## Architecture

### Entry point and library loading

`kyzn` is the entry point — it routes subcommands and lazy-loads only the `lib/*.sh` modules needed. `quick` loads 8 libs; `measure` loads 2; `doctor` loads none (all inline).

### `kyzn quick` pipeline

```
Detect project type → Baseline measure → Create kyzn/ branch
→ Assemble prompt (templates/ + {{PLACEHOLDERS}})
→ execute_claude (allowlist + budget + timeout)
→ Diff size check → verify_build
  ├─ rc 1 (any baseline) → ONE reflexion retry at ½ budget with error output
  │    ├─ green → re-check diff size → continue
  │    └─ still rc 1 → handle_build_failure (report/discard/draft-pr)
  └─ rc 2 → unconditional abort, nothing shipped
→ Re-measure → Score regression gate → Per-category floor gate
→ git commit → git push → gh pr create
```

### `kyzn fix` / `kyzn analyze` pipeline

Profiler agent (Sonnet) reads repo files and caches conventions to `.kyzn/repo-profile.md`. 4 Opus specialists run in parallel (security, correctness, performance, architecture), each producing JSON findings with fix_plan metadata. A 5th consensus session deduplicates and ranks. `kyzn analyze` stops at the report. `kyzn fix` continues: Sonnet implements fixes in severity batches with build/test verification and reflexion retry, then opens a PR.

### Key modules

| File | Role |
|------|------|
| `lib/core.sh` | Logging, config I/O via yq, `KYZN_SETTINGS_JSON` |
| `lib/detect.sh` | Project type detection (package.json / Cargo.toml / go.mod / etc.) |
| `lib/measure.sh` | `run_measurements` → `compute_health_score` → `display_health_dashboard` |
| `lib/execute.sh` | `execute_claude`, `cmd_improve`, safety wrappers (`safe_git`, `unstage_secrets`) |
| `lib/analyze.sh` | Multi-agent Opus pipeline, `cmd_analyze` |
| `lib/verify.sh` | `verify_build`, `capture_failing_tests` (per language) |
| `lib/prompt.sh` | Prompt assembly with `{{PLACEHOLDER}}` replacement |
| `lib/allowlist.sh` | Per-language Claude tool flags |
| `lib/report.sh` | PR body generation, `gh pr create` |
| `measurers/*.sh` | Execute real tools, output JSON metric arrays (generic, node, python, rust, go, csharp, java) |

### Config

Two-layer: `.kyzn/config.yaml` (committed, project settings) and `.kyzn/local.yaml` (gitignored local policy; guardian is enforced and legacy autopilot values are ignored). Config mutation uses `strenv()` in yq to prevent injection.

## Safety model

- Mutating workflows fail closed unless the operator passes `--allow-unsafe-host-execution` for that run; this is an acknowledgement, not isolation
- Autopilot is disabled and every generated PR requires manual review
- `safe_git` disables git hooks (`core.hooksPath=/dev/null`) to prevent RCE from malicious repos
- `KYZN_SETTINGS_JSON` blocks file access to sensitive paths (`~/.ssh`, `~/.aws`, `.env`, `~/.claude`, etc.)
- Tool allowlist tightened to specific subcommands (e.g. `Bash(npm test*)` — not open shell)
- Hard ceilings: max $25 budget, 100 turns, 10000 diff lines
- CI files (`.github/workflows/`) unstaged after Claude runs
- Atomic `mkdir` lock prevents concurrent runs on same repo

## Conventions

- Functions: `snake_case`; commands: `cmd_` prefix; globals: `KYZN_` prefix; internal helpers: `_kyzn_` prefix
- Health score weights (configurable): security 25%, testing 25%, quality 25%, performance 15%, documentation 10%
- Conventional commits: `feat:`, `fix:`, `docs:`, `perf:`
- CI runs ShellCheck at warning severity (`ci.yml`); `toolchain-matrix.yml` exercises
  `lib/verify.sh` against real TypeScript, .NET, Maven and Gradle SDKs via
  `tests/toolchain/run-matrix.sh`

## Verification results

`verify_build` returns three states, not two:

| Code | Meaning |
|------|---------|
| `0` | passed/no-op — every applicable required check passed, or no required check applied |
| `1` | failed — one or more applicable checks ran and failed |
| `2` | not executed — an applicable required check could not run |

Authorization reads the **final** code and nothing else — there is no comparison of failure
output, and no "these were already failing" exemption. Baseline rc 1 still earns an
improvement attempt and one repair attempt; only a verified rc 0 result is ever certified as
verified. "Certified" is not the same as "kept" — see the `draft-pr` case below.

What a red result *does* differs by workflow — do not state it as one rule:

- **`cmd_improve` (quick):** final rc 1 → `handle_build_failure "$on_fail"` (report / discard /
  draft-pr), and the run returns non-zero. `report` and `discard` delete the branch, but
  **`draft-pr` keeps the red result** — it commits, pushes and opens a clearly-marked draft PR
  (`lib/execute.sh:976-993`). The result is retained and surfaced, never certified as verified.
- **`run_fix_phase` (analyze --fix):** the unit is the severity batch. A red batch is reverted
  with `git reset --hard "$pre_batch_head"` and the loop **continues**; `handle_build_failure`
  is never called from `lib/analyze.sh` and `on_build_fail` is not consulted. A run whose
  other tiers passed still pushes and opens a normal PR; only `batches_applied == 0` aborts.

"Not executed" outranks "failed" for authorization: if an applicable required check could
not run, the run is ineligible for commit/push/PR regardless of what else happened. Callers use
`verify_not_executed <rc>`; `KYZN_VERIFY_STATUS` and `KYZN_VERIFY_UNAVAILABLE_REASON` carry
the detail. An unverifiable run that already modified the worktree is preserved in place —
no further changes are committed, and nothing is pushed, PR'd, or deleted. For
`analyze --fix`, severity batches that were already verified and committed before the abort
remain on the branch; preserving them is deliberate, and the branch is left for inspection.

## Test framework

`tests/selftest.sh` is a self-contained Bash test suite with `assert_eq`, `assert_contains`, `assert_exit_code`, etc. Tests use temp-dir sandboxes with fake git repos. Runtime assertion totals come from the suite output; repository-size facts below are generated and checked in CI.

<!-- BEGIN GENERATED REPOSITORY FACTS -->
- Repository files: **78**
- Bash entrypoints/modules/scripts: **26** files, **14549** lines
- Self-test harness: **106** test functions, **6031** lines (runtime assertion totals are reported by the suite, not hardcoded)
- Project profiles: **6** languages plus the generic fallback
- CI matrix: **Linux and macOS**, each running quick and full self-tests
<!-- END GENERATED REPOSITORY FACTS -->
