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
- **Unsafe host-execution gate** — mutating runs require a per-run `--allow-unsafe-host-execution` acknowledgement
- **Manual merge** — autopilot is disabled; generated PRs require human review
- **Supply chain** — CI pins and checksum-verifies its downloaded `yq`; installer downloads are verified when a published checksum is available
- **Prompt hardening** — project names sanitized, raw measurement/findings data fenced to prevent prompt injection
- **Concurrency lock** — atomic `mkdir`-based lock with stale PID detection prevents concurrent runs
- **Hook protection** — all git operations disable hooks via `core.hooksPath=/dev/null`

## Autopilot and Host Execution

Autopilot is disabled. KyZN creates reviewable PRs and never requests GitHub auto-merge. Existing gitignored `local.yaml` files containing `trust: autopilot` are handled safely: KyZN warns that the saved mode is disabled and leaves the PR for manual review.

KyZN also has no container or VM isolation yet. `kyzn analyze` and `kyzn measure` default to static generic measurements; their language-specific package/build-tool measurements require `--allow-unsafe-host-execution`. Commands that mutate a repository, execute its build/tests, or install its dependencies fail closed unless the operator passes the same flag for that run. Recurring mutating schedule creation is disabled entirely until KyZN can run it in isolation. The flag is an acknowledgement, not a sandbox: repository code executes with the operator's user permissions, environment, filesystem access, and network access.

Automatic merge must not return until KyZN can verify all of the following: isolated fresh-commit execution, protected branches, mandatory independent CI, and required human/code-owner review.

## Threat Model

The primary attack surface is **malicious repositories**. With the explicit unsafe-host flag, KyZN executes project build and test commands (`npm test`, `pytest`, `cargo test`, etc.) as your user. Do not enable host execution for repositories you do not trust.

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
