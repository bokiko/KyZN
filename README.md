<p align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=gradient&customColorList=14,20,24&height=200&section=header&text=KyZN&fontSize=60&fontColor=ffffff&animation=fadeIn&fontAlignY=38&desc=Autonomous%20Code%20Improvement%20CLI&descAlignY=55&descAlign=50" />
</p>

<p align="center">
  <a href="https://github.com/bokiko/KyZN"><img src="https://img.shields.io/badge/GitHub-KyZN-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://x.com/bokiko"><img src="https://img.shields.io/badge/X-@bokiko-000000?style=for-the-badge&logo=x&logoColor=white" alt="X"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Bash-5.0+-2ecc71?style=flat-square&logo=gnu-bash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Claude_Code-Powered-2ecc71?style=flat-square" alt="Claude Code">
  <img src="https://img.shields.io/badge/version-1.0.0-2ecc71?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/tests-259%20passing-2ecc71?style=flat-square" alt="Tests">
  <img src="https://img.shields.io/badge/license-MIT-2ecc71?style=flat-square" alt="License">
  <img src="https://img.shields.io/github/last-commit/bokiko/KyZN?style=flat-square&color=2ecc71" alt="Last Commit">
</p>

<p align="center">
  <a href="https://git.io/typing-svg"><img src="https://readme-typing-svg.demolab.com?font=Fira+Code&size=18&pause=1000&color=2ecc71&center=true&vCenter=true&width=500&lines=Measure+%E2%86%92+Analyze+%E2%86%92+Improve+%E2%86%92+Verify+%E2%86%92+Ship;4+Opus+specialists+in+parallel;259+tests+passing;Security+audited+%26+published" alt="Typing SVG"></a>
</p>

---

## Overview

**KyZN** (from _kaizen_ — continuous improvement) measures your project's health with real tools, sends the results to Claude Code with strict safety constraints, verifies the changes, and opens a PR — all autonomously. Supports Node.js, Python, Rust, and Go out of the box.

<div align="center">
  <img src="images/kyzn-measure.png" alt="KyZN measure — health score dashboard" width="580">
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
    Run kyzn fix for deep analysis + auto-fix.
```

That's it — one command, zero config. KyZN runs your project's real tools (eslint, ruff, clippy, go vet) and produces a health score. Then `kyzn fix` runs 4 Opus specialists in parallel, deduplicates findings, and Sonnet fixes them in severity batches — all verified and shipped as a PR.

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

> **macOS:** Requires Bash 4.3+ (`brew install bash`). The system `/bin/bash` is v3.2 and will not work.

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
kyzn fix        # Deep analysis + auto-fix → PR
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

### Fix
- **Full pipeline**: analyze → fix → verify → PR in one command
- Profiler scans repo conventions before analysis
- Severity-batched: CRITICAL → HIGH → MEDIUM → LOW
- Reflexion retry on build failure

</td>
</tr>
<tr>
<td width="50%">

### Analyze
- **4 Opus specialists in parallel** — security, correctness, performance, architecture
- Consensus engine deduplicates and ranks findings
- Compact one-liner terminal output + detailed `kyzn-report.md`
- `--fix` mode: full report context passed to Sonnet for accurate fixes

</td>
<td width="50%">

### Improve
- Sonnet-powered incremental improvements
- Deep, clean, or full improvement modes
- Configurable budget cap per run
- Focus targeting (security, testing, quality)

</td>
</tr>
<tr>
<td width="50%">

### Verify
- Runs build + tests after every change
- Pre-existing failure detection
- Score regression gate — aborts if score drops
- Per-category floor — aborts if any area drops > 5pts

</td>
<td width="50%">

### Ship
- Auto-creates PR with before/after comparison
- Branch isolation — never touches main
- Approve/reject workflow with feedback
- Schedule daily or weekly via cron

</td>
</tr>
</table>

---

## Usage

### Fix (recommended — deep analysis + auto-fix)

```bash
kyzn fix                           # Full pipeline: analyze → fix → verify → PR
kyzn fix --auto                    # Non-interactive (cron-safe)
kyzn fix --profile hybrid          # Cheaper analysis model mix
kyzn fix --min-severity HIGH       # Only fix HIGH+ severity findings
kyzn fix --fix-budget 10.00        # Budget for fix phase
```

One command does everything: profiler scans your repo's conventions, 4 Opus specialists find issues in parallel, consensus deduplicates, Sonnet fixes in severity batches with build/test verification, and opens a PR. If a fix breaks the build, reflexion retry gives Sonnet a second chance.

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

> **Tip:** `kyzn analyze --fix` is equivalent to `kyzn fix`.

<div align="center">
  <img src="images/kyzn-analyze.png" alt="KyZN analyze — multi-agent findings" width="580">
</div>

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

```mermaid
graph LR
    A[Detect] --> P[Profile]
    P --> B[Measure]
    B --> C{Mode?}
    C -->|fix| E[4x Opus]
    C -->|improve| D[Sonnet]
    E --> G[Consensus]
    G --> H[Sonnet Fix]
    D --> F[Verify]
    H --> F
    F -->|fail| R[Reflexion]
    R --> F
    F -->|pass| I[Score Gate]
    I -->|pass| J[PR]
```

> [!TIP]
> See [`docs/how-it-works.md`](docs/how-it-works.md) for detailed architecture, health score weights, modes, and supported languages.

---

## Configuration

Run `kyzn init` to create `.kyzn/config.yaml` interactively. Three improvement modes: **deep** (real bugs only), **clean** (dead code + naming), **full** (everything). See [`.kyzn.example.yaml`](.kyzn.example.yaml) for all options or [`docs/how-it-works.md`](docs/how-it-works.md) for full reference.

---

## Safety

| Layer | Protection |
|-------|-----------|
| **Untrusted repos** | Do not run KyZN on repositories you don't trust — build/test commands are executed |
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

Every finding was verified, fixed, and tested. The full test suite grew from 156 to 259 tests, with new tests specifically covering the fixed attack surfaces.

### Published Reports

The complete audit reports are published in this repository:

- [`full-audit-by-claude/EXECUTIVE-SUMMARY.md`](full-audit-by-claude/EXECUTIVE-SUMMARY.md) — Overall assessment, prioritized findings, agent report card
- [`full-audit-by-claude/`](full-audit-by-claude/) — All 16 individual agent reports with file-level detail

We publish these because we believe you should be able to read exactly what was found, how serious it was, and how it was resolved — before you decide to run KyZN on your code.

### Reporting Security Issues

If you find a security issue in KyZN, please open a GitHub issue. Since KyZN runs locally (no server, no data collection, no network calls beyond Claude API and GitHub), most issues can be discussed openly. For issues involving the Claude API key or token handling, please reach out privately.

---

<details>
<summary><b>Project Structure</b></summary>

```
kyzn/
├── kyzn                       # Entry point + subcommand routing
├── install.sh                 # One-liner installer
├── lib/                       # Core libraries (14 modules)
├── measurers/                 # Per-language health measurers
├── templates/                 # Prompt templates
├── profiles/                  # Focus-specific system prompts
├── docs/                      # Research, examples, architecture
├── full-audit-by-claude/      # Published security audit (16 agent reports)
├── .github/workflows/         # CI (ShellCheck on push/PR)
└── tests/
    └── selftest.sh            # 259 tests (250 quick + 9 stress)
```

</details>

```bash
kyzn selftest              # Quick tests (250 cases)
kyzn selftest --full       # Full suite with stress tests (259 cases)
```

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

<img src="https://capsule-render.vercel.app/api?type=waving&color=gradient&customColorList=14,20,24&height=100&section=footer" />
<p align="center">
  Made by <a href="https://bokiko.io">@bokiko</a>
</p>
