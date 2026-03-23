# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is KyZN

KyZN (from "kaizen") is a pure-Bash CLI that autonomously improves code quality. It runs real language tools to produce a health score, invokes Claude Code to make improvements, gates changes behind build/test verification and score regression checks, then opens a GitHub PR with before/after comparison. Supports Node.js, Python, Rust, and Go.

## Prerequisites

Bash 4.3+, `git`, `gh` (GitHub CLI), `claude` (Anthropic CLI), `jq`, `yq`. Language-specific tools are optional (eslint/tsc, ruff/mypy, cargo, go vet, etc.).

## Commands

```bash
# Run tests
kyzn selftest              # 209 quick tests
kyzn selftest --full       # 218 tests including stress tests
bash tests/selftest.sh     # Direct test runner

# Lint (matches CI)
shellcheck -S warning kyzn lib/*.sh measurers/*.sh tests/selftest.sh

# Usage
kyzn doctor                # Check prerequisites
kyzn init                  # Interactive setup → .kyzn/config.yaml
kyzn measure               # Health score only
kyzn improve               # Full improve cycle
kyzn improve --auto        # Non-interactive (cron-safe)
kyzn analyze               # 4 Opus specialists + consensus report
kyzn analyze --fix         # Analyze then auto-fix
```

## Architecture

### Entry point and library loading

`kyzn` is the entry point — it routes subcommands and lazy-loads only the `lib/*.sh` modules needed. `improve` loads 8 libs; `measure` loads 2; `doctor` loads none (all inline).

### `kyzn improve` pipeline

```
Detect project type → Baseline measure → Create kyzn/ branch
→ Assemble prompt (templates/ + {{PLACEHOLDERS}})
→ execute_claude (allowlist + budget + timeout)
→ Diff size check → verify_build
  ├─ fail (was clean baseline) → reflexion retry at ½ budget with error output
  └─ still fail → handle_build_failure (report/discard/draft-pr)
→ Re-measure → Score regression gate → Per-category floor gate
→ git commit → git push → gh pr create
```

### `kyzn analyze` pipeline

4 Opus specialists run in parallel background subshells (security, correctness, performance, architecture), each producing JSON findings. A 5th consensus Opus session deduplicates and ranks. Output goes to `kyzn-report.md`. Optional `--fix` passes the report to Sonnet for targeted fixes.

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
| `measurers/*.sh` | Execute real tools, output JSON metric arrays (generic, node, python, rust, go) |

### Config

Two-layer: `.kyzn/config.yaml` (committed, project settings) and `.kyzn/local.yaml` (gitignored, trust level — `guardian` vs `autopilot`). Config mutation uses `strenv()` in yq to prevent injection.

## Safety model

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
- CI runs ShellCheck at warning severity

## Test framework

`tests/selftest.sh` is a self-contained 1764-line Bash test suite with `assert_eq`, `assert_contains`, `assert_exit_code`, etc. Tests use temp-dir sandboxes with fake git repos.
