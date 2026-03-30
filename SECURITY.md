# Security Policy

## Reporting Vulnerabilities

For most security issues, please [open a GitHub issue](https://github.com/bokiko/KyZN/issues). KyZN runs locally with no server, no data collection, and no network calls beyond the Claude API and GitHub CLI — so most issues can be discussed openly.

For issues involving API key or token handling, please reach out privately to [@bokiko](https://github.com/bokiko).

## Security Model

KyZN runs AI agents with real tool access inside your codebase. We take this seriously:

- **Branch isolation** — all changes on `kyzn/` branches, never touches `main`
- **Tool allowlist** — per-language restrictions tightened to specific subcommands
- **File access restrictions** — Claude cannot read `~/.ssh`, `~/.aws`, `.env`, key files, or shell configs
- **Budget cap** — configurable per-run spending limit
- **Build/test gate** — PR only created if build and tests pass
- **Score gate** — aborts if health score drops after changes
- **Diff guard** — aborts if changes exceed threshold
- **Secret detection** — regex-based heuristic matching on staged files (`.env`, `.pem`, `.key`, etc.)
- **Trust isolation** — autopilot trust level stored in gitignored `local.yaml`, not committable config

## Autopilot Mode

**Autopilot mode auto-merges AI-generated PRs without human review.** When trust is set to `autopilot` (via `kyzn init`), any PR that passes the build gate, test gate, score regression gate, and diff size gate will be merged automatically via `gh pr merge --auto --squash`.

**What this means:**
- Claude-generated code changes are merged into your default branch with no human in the loop
- The only gates are automated checks (build, tests, health score, diff size)
- If your project has no CI pipeline, GitHub's auto-merge triggers immediately on PR creation

**When autopilot is appropriate:**
- You have comprehensive CI (tests, linting, type checking) that catches regressions
- You are running KyZN for low-risk improvements on non-critical projects
- You accept that AI-generated changes may introduce subtle issues not caught by automated tests

**When autopilot is NOT appropriate:**
- Production services handling user data or financial transactions
- Projects without a test suite or with low test coverage
- Security-sensitive code (auth, crypto, access control)

**Recommendation:** Start with `guardian` mode. Only enable `autopilot` after you have reviewed several KyZN PRs and are confident in your test coverage.

## Threat Model

The primary attack surface is **malicious repositories**. KyZN executes your project's build and test commands (`npm test`, `pytest`, `cargo test`, etc.). Do not run KyZN on repositories you don't trust.

## How We Audit

Before every major release, we run a **parallel multi-agent security audit** — 16 specialist AI agents independently review the entire codebase, each from a different angle:

| Specialist | Focus |
|-----------|-------|
| Security agent | Injection vectors, input validation, access control |
| Architecture agent | Trust boundaries, isolation design, module coupling |
| Testing agent | Coverage gaps, untested critical paths |
| Performance agent | Subprocess bottlenecks, scaling limits |
| + 12 more | Correctness, dead code, crash safety, competitive analysis |

The agents work in parallel and don't see each other's findings. A consensus step deduplicates and ranks the results.

## What We Found and Fixed (v0.5.0)

Our v0.4.0 audit produced **~350KB of findings across 8,400 lines** from 16 agents:

| Category | Issues Found | How We Fixed Them |
|----------|-------------|-------------------|
| **Input handling** | Unsafe variable expansion patterns | Replaced with safe bash built-ins (`${!var}`, `printf -v`, `awk -v`) |
| **Tool restrictions** | Permissions not applied correctly | Converted to proper bash arrays with quoted expansion |
| **Config isolation** | Trust setting in committed config | Moved to gitignored `local.yaml` |
| **Path validation** | Missing input validation | Added format validation with positive pattern matching |
| **File access** | Restricted file list incomplete | Expanded to include shell configs, package manager credentials, container configs |
| **Crash recovery** | Missing cleanup on interrupt | Added trap that kills child processes, updates history, cleans temp files |
| **Measurement accuracy** | Parsers producing inflated counts | Fixed to use structured JSON parsing |

Every finding was verified, fixed, and tested. The full test suite grew from 156 to 276 tests.

## Published Audit Reports

The complete audit reports are published in this repository:

- [`full-audit-by-claude/EXECUTIVE-SUMMARY.md`](full-audit-by-claude/EXECUTIVE-SUMMARY.md) — Overall assessment, prioritized findings, agent report card
- [`full-audit-by-claude/`](full-audit-by-claude/) — All 16 individual agent reports with file-level detail

We publish these because we believe you should be able to read exactly what was found, how serious it was, and how it was resolved — before you decide to run KyZN on your code.

## Disclaimer

KyZN generates AI-powered code changes. Always review PRs before merging. The authors are not responsible for any damage caused by AI-generated modifications.
