<div align="center">

# KyZN

<strong>Autonomous code improvement CLI — measure, analyze, improve, verify, ship</strong>

<p>
  <a href="https://github.com/bokiko/KyZN"><img src="https://img.shields.io/badge/GitHub-KyZN-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://claude.ai/code"><img src="https://img.shields.io/badge/Powered_by-Claude_Code-6B4FBB?style=for-the-badge" alt="Claude Code"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/github/license/bokiko/KyZN?style=flat-square" alt="License">
  <img src="https://img.shields.io/github/last-commit/bokiko/KyZN?style=flat-square" alt="Last Commit">
  <img src="https://img.shields.io/badge/status-active-success?style=flat-square" alt="Status">
  <img src="https://img.shields.io/badge/version-0.5.0-blue?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/tests-218%20passing-brightgreen?style=flat-square" alt="Tests">
</p>

</div>

---

## Overview

**KyZN** (from _kaizen_ — continuous improvement) measures your project's health with real tools, sends the results to Claude Code with strict safety constraints, verifies the changes, and opens a PR — all autonomously. Supports Node.js, Python, Rust, and Go out of the box.

<div align="center">
  <img src="docs/images/kyzn-demo.png" alt="KyZN in action — health score + multi-agent analysis" width="680">
  <br>
  <em>Health score dashboard + 4-agent parallel analysis</em>
</div>

---

## Quick Demo

```bash
$ cd your-project
$ kyzn measure

  Project Health Score

  68 / 100

  Categories:
  security        ████████████████░░░░  80%
  testing         ██████████░░░░░░░░░░  50%
  quality         ██████████████░░░░░░  72%
  performance     ████████████████████ 100%
  documentation   ████████████░░░░░░░░  60%

  ℹ Weakest area: testing (50%)
    Run kyzn improve --focus testing to improve it.
    Run kyzn analyze for a deep multi-agent code review.
```

That's it — one command, zero config. KyZN runs your project's real tools (eslint, ruff, clippy, go vet) and produces a health score. Then `kyzn improve` sends the results to Claude Code, which makes targeted improvements, verifies them, and opens a PR.

See [`docs/examples/sample-report.md`](docs/examples/sample-report.md) for what a full analysis report looks like.

---

## Quick Start

### Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| `git` | Yes | Branch management |
| `gh` | Yes | PR creation |
| `claude` | Yes | [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) |
| `jq` | Yes | JSON processing |
| `yq` | Yes | YAML config |

### Installation

```bash
# One-liner (recommended)
curl -fsSL https://raw.githubusercontent.com/bokiko/KyZN/main/install.sh | bash

# Or clone manually
git clone https://github.com/bokiko/KyZN.git ~/.kyzn-cli
ln -sf ~/.kyzn-cli/kyzn ~/.local/bin/kyzn

# Verify
kyzn doctor
```

### Authentication

KyZN needs Claude Code authenticated. Pick **one** method:

**Option A — OAuth login (recommended)**
```bash
claude    # Opens browser, log in once, done
```

**Option B — API key**
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

> **Heads up:** If `ANTHROPIC_API_KEY` is set in your shell, Claude will use it instead of OAuth — even if the key is expired. If `kyzn doctor` shows "Claude auth: API key" but things fail, run `unset ANTHROPIC_API_KEY` to fall back to OAuth.

To switch between methods:
- **Use OAuth:** `unset ANTHROPIC_API_KEY` (and remove any export from `~/.bashrc`)
- **Use API key:** `export ANTHROPIC_API_KEY="sk-ant-..."`

`kyzn doctor` shows which method is active.

### First Run

```bash
cd your-project
kyzn init       # One-time setup
kyzn measure    # See your health score
kyzn improve    # Run improvement cycle
```

---

## Features

<table>
<tr>
<td width="50%">

### Measure
- Runs real tools (eslint, ruff, clippy, go vet)
- Health score out of 100 across 5 categories
- Weighted scoring with custom priorities
- Per-language measurers for Node, Python, Rust, Go

</td>
<td width="50%">

### Analyze
- **4 Opus specialists in parallel** — security, correctness, performance, architecture
- Consensus engine deduplicates and ranks findings
- Compact one-liner terminal output + detailed `kyzn-report.md`
- `--fix` mode: full report context passed to Sonnet for accurate fixes

</td>
</tr>
<tr>
<td width="50%">

### Improve
- Sonnet-powered incremental improvements
- Deep, clean, or full improvement modes
- Configurable budget cap per run
- Focus targeting (security, testing, quality)

</td>
<td width="50%">

### Verify
- Runs build + tests after every change
- Pre-existing failure detection
- Score regression gate — aborts if score drops
- Per-category floor — aborts if any area drops > 5pts

</td>
</tr>
<tr>
<td width="50%">

### Ship
- Auto-creates PR with before/after comparison
- Branch isolation — never touches main
- Approve/reject workflow with feedback
- Schedule daily or weekly via cron

</td>
<td width="50%">

### Progress
- Live status line during multi-agent analysis
- Per-agent completion tracking (◌ running, ● done, ✗ failed)
- Elapsed time display
- Cost tracking per session

</td>
</tr>
</table>

---

## Usage

### Analyze (multi-agent Opus deep analysis)

```bash
kyzn analyze                        # 4 Opus specialists + consensus (~$20)
kyzn analyze --fix                  # Analyze then Sonnet fixes top issues
kyzn analyze --focus security       # Single specialist (security only)
kyzn analyze --single               # Single general reviewer (cheaper)
kyzn analyze --budget 30.00         # Higher budget for large codebases
kyzn analyze --min-severity HIGH    # Only fix HIGH+ severity in --fix mode
kyzn analyze --export report.md     # Export report to custom path
```

Terminal output is compact (one line per finding). Full details are saved to `kyzn-report.md` in the project root and archived in `.kyzn/reports/`. When `--fix` runs, the full report is passed to Sonnet so it has complete context for each fix.

### Improve (Sonnet incremental)

```bash
kyzn improve                        # Interactive — choose model & budget
kyzn improve --auto                 # Non-interactive (for cron)
kyzn improve --mode deep            # Real improvements only
kyzn improve --mode clean           # Cleanup only (dead code, naming)
kyzn improve --mode full            # Everything
kyzn improve --focus security       # Target a specific area
kyzn improve --model opus           # Use a specific model
kyzn improve --budget 5.00          # Override budget cap
kyzn improve -v                     # Show live progress
```

### Review

```bash
kyzn history                        # Show all runs with scores
kyzn diff <run-id>                  # Show what changed
kyzn approve <run-id>               # Sign off on improvements
kyzn reject <run-id> -r "reason"    # Reject with feedback
```

### Automate

```bash
kyzn schedule daily                 # Run at 3am daily via cron
kyzn schedule weekly                # Run weekly (Sundays)
kyzn schedule off                   # Remove schedule
```

---

## How It Works

Detect project type → measure health with real tools → improve with Claude → verify build + tests → self-repair on failure → score gate → PR.

For deep analysis, 4 Opus specialists (security, correctness, performance, architecture) review in parallel, then a consensus step deduplicates and ranks findings.

See [`docs/how-it-works.md`](docs/how-it-works.md) for architecture diagrams, health score weights, modes, configuration, and supported languages.

---

## Safety

| Layer | Protection |
|-------|-----------|
| **Branch isolation** | All changes on `kyzn/` branches, never touches `main` |
| **Budget cap** | Configurable per-run spending limit (default $2.50) |
| **Tool allowlist** | Per-language restrictions — tightened to specific subcommands (no `python -c`, no `rm`) |
| **File access restrictions** | Claude cannot read `~/.ssh`, `~/.aws`, `~/.gnupg`, `.env`, or key files |
| **CI file blocking** | Pipeline/workflow files are unstaged by default (override with `--allow-ci`) |
| **Invocation timeout** | Claude calls timeout after 10min by default (`KYZN_CLAUDE_TIMEOUT` to override) |
| **Build gate** | PR only if build + tests pass after changes |
| **Score gate** | Aborts if aggregate health score drops after improvements |
| **Per-category floor** | Aborts if any single category drops more than 5 points |
| **Diff guard** | Aborts if changes exceed configurable threshold (default 2000 lines) |
| **Pre-existing failures** | Won't abort on test failures that existed before |
| **Branch cleanup** | Failed runs delete their branches automatically |
| **Trust isolation** | Autopilot trust level stored in gitignored `local.yaml`, not committable config |
| **Secret detection** | Regex-based heuristic pattern matching on staged files (`.env`, `.pem`, `.key`, etc.). This is not AST-level analysis — it catches common patterns but may miss obfuscated secrets. Use dedicated tools like `gitleaks` or `trufflehog` for comprehensive scanning. |

---

## Security Transparency

We believe security is built on trust, and trust requires transparency.

KyZN runs AI agents with real tool access inside your codebase. That's a serious responsibility. Rather than asking you to take our word that it's safe, we publish our audit process and findings so you can verify it yourself.

### How We Audit

Before every major release, we run a **parallel multi-agent security audit** — 16 specialist AI agents independently review the entire codebase, each from a different angle:

| Specialist | Focus |
|-----------|-------|
| Security agent | Injection vectors, input validation, access control |
| Architecture agent | Trust boundaries, isolation design, module coupling |
| Testing agent | Coverage gaps, untested critical paths |
| Performance agent | Subprocess bottlenecks, scaling limits |
| + 12 more | Correctness, dead code, crash safety, competitive analysis |

The agents work in parallel and don't see each other's findings. A consensus step then deduplicates and ranks the results. This catches issues that any single reviewer — human or AI — would miss.

### What We Found and Fixed (v0.5.0)

Our v0.4.0 audit produced **~350KB of findings across 8,400 lines** from 16 agents. The consensus identified issues in these categories:

| Category | Issues Found | How We Fixed Them |
|----------|-------------|-------------------|
| **Input handling** | Unsafe variable expansion patterns in internal functions | Replaced with safe bash built-ins (`${!var}`, `printf -v`, `awk -v`) |
| **Tool restrictions** | Language-specific tool permissions not applied correctly due to string-vs-array expansion | Converted to proper bash arrays with quoted expansion |
| **Config isolation** | Trust setting in committed config (should be local-only) | Moved to gitignored `local.yaml`, added comment guidance |
| **Path validation** | Missing input validation in some user-facing commands | Added format validation with positive pattern matching |
| **File access** | Restricted file list didn't cover all sensitive paths | Expanded to include shell configs, package manager credentials, container configs |
| **Crash recovery** | Missing cleanup on interrupt during multi-agent analysis | Added trap that kills child processes, updates history, cleans temp files |
| **Measurement accuracy** | Parsers for Go and Rust tools producing inflated counts | Fixed to use structured JSON parsing instead of line counting |

Every finding was verified, fixed, and tested. The full test suite grew from 156 to 208 tests, with new tests specifically covering the fixed attack surfaces.

### Published Reports

The complete audit reports are published in this repository:

- [`full-audit-by-claude/EXECUTIVE-SUMMARY.md`](full-audit-by-claude/EXECUTIVE-SUMMARY.md) — Overall assessment, prioritized findings, agent report card
- [`full-audit-by-claude/`](full-audit-by-claude/) — All 16 individual agent reports with file-level detail

We publish these because we believe you should be able to read exactly what was found, how serious it was, and how it was resolved — before you decide to run KyZN on your code.

### Reporting Security Issues

If you find a security issue in KyZN, please open a GitHub issue. Since KyZN runs locally (no server, no data collection, no network calls beyond Claude API and GitHub), most issues can be discussed openly. For issues involving the Claude API key or token handling, please reach out privately.

---

## Configuration

Run `kyzn init` to create `.kyzn/config.yaml` interactively. Three improvement modes: **deep** (real bugs only), **clean** (dead code + naming), **full** (everything). See [`docs/how-it-works.md`](docs/how-it-works.md) for full config reference and mode details.

---

## Project Structure

```
kyzn/
├── kyzn                       # Entry point + subcommand routing
├── install.sh                 # One-liner installer
├── lib/
│   ├── core.sh                # Logging, config, prompt utilities
│   ├── detect.sh              # Project type + feature detection
│   ├── interview.sh           # Interactive setup questionnaire
│   ├── measure.sh             # Measurement dispatcher + health scoring
│   ├── prompt.sh              # Prompt assembly for Claude
│   ├── execute.sh             # Claude invocation + improve orchestration
│   ├── verify.sh              # Build/test verification per language
│   ├── allowlist.sh           # Per-language tool permissions
│   ├── analyze.sh             # Multi-agent Opus analysis + consensus + fix
│   ├── report.sh              # Report generation + PR creation
│   ├── approve.sh             # Approve/reject handling
│   ├── history.sh             # Run history + status dashboard
│   └── schedule.sh            # Cron integration
├── measurers/
│   ├── generic.sh             # TODOs, secrets, git health, docs
│   ├── node.sh                # npm audit, eslint, tsc, coverage
│   ├── python.sh              # ruff, mypy, pytest-cov, pip-audit
│   ├── rust.sh                # cargo clippy, cargo audit
│   └── go.sh                  # go vet, govulncheck
├── templates/                 # Prompt templates
├── profiles/                  # Focus-specific system prompts
├── docs/                      # Research and design documents
├── full-audit-by-claude/      # Published security audit (16 agent reports)
├── .github/workflows/         # CI (ShellCheck on push/PR)
└── tests/
    └── selftest.sh            # 218 tests (50 core + 4 stress)
```

---

## Self-Test

```bash
kyzn selftest              # Quick tests (209 cases)
kyzn selftest --full       # Full suite with stress tests (218 cases)
```

---

## Roadmap

- [x] Core improvement cycle (detect → measure → improve → verify → PR)
- [x] Node.js, Python, Rust, Go support
- [x] Interactive model and budget selection
- [x] Score regression gate
- [x] Pre-existing test failure detection
- [x] Branch cleanup on all failure paths
- [x] 218-test self-test suite
- [x] Multi-agent analysis — 4 Opus specialists + consensus (`kyzn analyze`)
- [x] Two-model architecture (Opus thinks, Sonnet executes)
- [x] Live progress indicator during analysis
- [x] Security hardening (file restrictions, CI blocking, timeouts, checksums)
- [x] Compact terminal output + `kyzn-report.md` detailed report
- [x] Full report context passed to fix phase for accurate Sonnet fixes
- [x] 16-agent parallel security audit with published reports
- [x] Audit-driven hardening: eval removal, array allowlists, input validation, crash safety
- [x] Reflexion loop (retry with self-reflection on failure)
- [ ] Multi-candidate patches (generate 3, pick best)
- [ ] Experience bank (store/retrieve successful fix patterns)
- [ ] Learning from rejection feedback
- [ ] Coverage-aware test generation

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Made by <a href="https://www.bokiko.io">@bokiko</a>
</p>
