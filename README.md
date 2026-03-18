<div align="center">

# kyzn

<strong>Autonomous code improvement CLI — measure, improve, verify, ship</strong>

<p>
  <a href="https://github.com/bokiko/kyzn"><img src="https://img.shields.io/badge/GitHub-kyzn-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://claude.ai/code"><img src="https://img.shields.io/badge/Powered_by-Claude_Code-6B4FBB?style=for-the-badge" alt="Claude Code"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/github/license/bokiko/kyzn?style=flat-square" alt="License">
  <img src="https://img.shields.io/github/last-commit/bokiko/kyzn?style=flat-square" alt="Last Commit">
  <img src="https://img.shields.io/badge/status-active-success?style=flat-square" alt="Status">
  <img src="https://img.shields.io/badge/version-0.2.0-blue?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/tests-79%20passing-brightgreen?style=flat-square" alt="Tests">
</p>

</div>

---

## Overview

**kyzn** (from _kaizen_ — continuous improvement) points at any project, measures its health with real tools, sends measurements to Claude Code with strict constraints, verifies the result, and opens a PR — all autonomously.

```
$ kyzn improve

→ Project type: node
  Features: TypeScript Tests CI

  Run settings:
    Mode:   deep
    Model:  sonnet
    Budget: $2.50
    Focus:  auto

  Model to use?
    1) sonnet  — fast, cost-effective (recommended)
    2) opus    — highest quality, slower
    3) haiku   — cheapest, basic improvements
  Choice [1]:

→ Invoking Claude Code (model: sonnet, budget: $2.50, max turns: 30)...
✓ Claude finished (cost: $1.23, reason: end_turn)
✓ Build and tests passed!
✓ Health: 52 → 68 (↑ +16)
✓ PR created: https://github.com/you/project/pull/42
```

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
| Claude auth | Yes | Log in via `claude` CLI (OAuth) **or** set `ANTHROPIC_API_KEY` |

### Installation

```bash
# One-liner (recommended)
curl -fsSL https://raw.githubusercontent.com/bokiko/kyzn/main/install.sh | bash

# Or clone manually
git clone https://github.com/bokiko/kyzn.git ~/.kyzn-cli
ln -sf ~/.kyzn-cli/kyzn ~/.local/bin/kyzn

# Verify
kyzn doctor
```

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

### Improve
- Interactive model selection (sonnet/opus/haiku)
- Configurable budget cap per run
- Deep, clean, or full improvement modes
- Focus targeting (security, testing, quality)

</td>
</tr>
<tr>
<td width="50%">

### Verify
- Runs build + tests after every change
- Pre-existing failure detection
- Score regression gate — aborts if score drops
- Diff guard — aborts if changes too large

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

### Improve

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

```
 ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
 │  Detect  │───▶│ Measure  │───▶│ Improve  │───▶│  Verify  │───▶│  Score   │───▶│    PR    │
 │          │    │          │    │          │    │          │    │  Gate    │    │          │
 │ language │    │ run real │    │ Claude   │    │ build +  │    │ abort   │    │ before/  │
 │ features │    │ tools    │    │ Code     │    │ tests    │    │ if drop │    │ after    │
 └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
```

1. **Detect** — identifies project type and features (TypeScript, tests, CI, Docker, linter)
2. **Measure** — runs real tools and computes a health score out of 100
3. **Improve** — invokes Claude Code in headless mode with measurements and constraints
4. **Verify** — runs build and tests. Aborts on new failures, continues on pre-existing ones.
5. **Score Gate** — re-measures health. If score dropped, aborts and cleans up.
6. **PR** — commits, pushes, and creates PR with before/after health comparison

---

## Health Score

```
  Project Health Score

  68 / 100

  Categories:
  security        ████████████████░░░░  80%
  testing         ██████████░░░░░░░░░░  50%
  quality         ██████████████░░░░░░  72%
  performance     ████████████████████ 100%
  documentation   ████████████░░░░░░░░  60%
```

| Category | Weight | What It Measures |
|----------|--------|------------------|
| Security | 25% | Dependency vulnerabilities, hardcoded secrets |
| Testing | 25% | Test coverage, test file ratio |
| Quality | 25% | Lint errors, type errors, TODO count, git health |
| Performance | 15% | Large files, bundle size indicators |
| Documentation | 10% | README quality and completeness |

---

## Supported Languages

| Language | Detection | Measurers | Verify |
|----------|-----------|-----------|--------|
| **Node.js** | `package.json` | npm audit, eslint, tsc, coverage | npm build, npm test |
| **Python** | `pyproject.toml`, `setup.py` | ruff, mypy, pytest-cov, pip-audit | ruff check, mypy, pytest |
| **Rust** | `Cargo.toml` (incl. workspaces) | cargo clippy, cargo audit | cargo check, cargo test |
| **Go** | `go.mod` | go vet, govulncheck | go build, go test, go vet |
| **Generic** | (fallback) | TODOs, git health, secrets, docs | — |

---

## Safety

| Layer | Protection |
|-------|-----------|
| **Branch isolation** | All changes on `kyzn/` branches, never touches `main` |
| **Budget cap** | Configurable per-run spending limit (default $2.50) |
| **Tool allowlist** | Per-language restrictions — no `rm`, `sudo`, `git push` |
| **Build gate** | PR only if build + tests pass after changes |
| **Score gate** | Aborts if health score drops after improvements |
| **Diff guard** | Aborts if changes exceed configurable threshold (default 2000 lines) |
| **Pre-existing failures** | Won't abort on test failures that existed before |
| **Branch cleanup** | Failed runs delete their branches automatically |

---

## Configuration

`kyzn init` creates `.kyzn/config.yaml`:

```yaml
project:
  name: my-project
  type: node

preferences:
  mode: deep            # deep | clean | full
  model: sonnet         # sonnet | opus | haiku
  budget: 2.50          # USD per run
  max_turns: 30         # Claude conversation turns
  diff_limit: 2000      # max lines changed
  trust: guardian       # guardian (PR) | autopilot (auto-merge)
  on_build_fail: report # report | discard | draft-pr

focus:
  priorities: [auto]    # auto | security | testing | quality | performance | documentation

scoring:
  weights:
    security: 25
    testing: 25
    quality: 25
    performance: 15
    documentation: 10
```

---

## Modes

| Mode | What It Does | Best For |
|------|-------------|----------|
| **deep** | Only fixes real bugs, security issues, error handling gaps. No cosmetic changes. | Production codebases |
| **clean** | Dead code removal, unused imports, naming fixes, docs. No behavior changes. | Tech debt cleanup |
| **full** | Both real improvements and cleanup. Maximum value per run. | Side projects |

---

## Project Structure

```
kyzn/
├── kyzn                    # Entry point + subcommand routing
├── install.sh              # One-liner installer
├── lib/
│   ├── core.sh             # Logging, config, prompt utilities
│   ├── detect.sh           # Project type + feature detection
│   ├── interview.sh        # Interactive setup questionnaire
│   ├── measure.sh          # Measurement dispatcher + health scoring
│   ├── prompt.sh           # Prompt assembly for Claude
│   ├── execute.sh          # Claude invocation + improve orchestration
│   ├── verify.sh           # Build/test verification per language
│   ├── allowlist.sh        # Per-language tool permissions
│   ├── report.sh           # Report generation + PR creation
│   ├── approve.sh          # Approve/reject handling
│   ├── history.sh          # Run history + status dashboard
│   └── schedule.sh         # Cron integration
├── measurers/
│   ├── generic.sh          # TODOs, secrets, git health, docs
│   ├── node.sh             # npm audit, eslint, tsc, coverage
│   ├── python.sh           # ruff, mypy, pytest-cov, pip-audit
│   ├── rust.sh             # cargo clippy, cargo audit
│   └── go.sh               # go vet, govulncheck
├── templates/              # Prompt templates
├── profiles/               # Focus-specific system prompts
└── tests/
    └── selftest.sh         # 79 tests (20 core + 4 stress)
```

---

## Self-Test

```bash
kyzn selftest              # Quick tests (20 cases)
kyzn selftest --full       # Full suite with stress tests (79 cases)
```

---

## Roadmap

- [x] Core improvement cycle (detect → measure → improve → verify → PR)
- [x] Node.js, Python, Rust, Go support
- [x] Interactive model and budget selection
- [x] Score regression gate
- [x] Pre-existing test failure detection
- [x] Branch cleanup on all failure paths
- [x] 79-test self-test suite
- [ ] Parallel runs across multiple focus areas
- [ ] Learning from rejection feedback
- [ ] Coverage-aware test generation
- [ ] Custom measurer plugins
- [ ] GitHub Actions integration

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Made by <a href="https://github.com/bokiko">@bokiko</a>
</p>
