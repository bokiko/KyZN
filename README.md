<p align="center">
  <h1 align="center">kyzn</h1>
  <p align="center">
    Autonomous code improvement CLI powered by Claude Code
    <br />
    <em>Measure. Improve. Verify. Ship.</em>
  </p>
  <p align="center">
    <a href="#install">Install</a> &middot;
    <a href="#quick-start">Quick Start</a> &middot;
    <a href="#how-it-works">How It Works</a> &middot;
    <a href="#supported-languages">Languages</a> &middot;
    <a href="#safety">Safety</a>
  </p>
</p>

---

**kyzn** (from _kaizen_ — continuous improvement) is a CLI that measures your codebase health, sends the measurements to Claude Code with strict constraints, verifies the result, and opens a PR — all autonomously.

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

## Install

```bash
# One-liner (recommended)
curl -fsSL https://raw.githubusercontent.com/bokiko/kyzn/main/install.sh | bash

# Or clone manually
git clone https://github.com/bokiko/kyzn.git ~/.kyzn-cli
ln -sf ~/.kyzn-cli/kyzn ~/.local/bin/kyzn
```

### Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| `git` | Yes | Branch management |
| `gh` | Yes | PR creation |
| `claude` | Yes | [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) |
| `jq` | Yes | JSON processing |
| `yq` | Yes | YAML config |
| `ANTHROPIC_API_KEY` | Yes | Claude API access |

```bash
kyzn doctor  # checks all prerequisites
```

## Quick Start

```bash
cd your-project

# 1. Set up (one-time)
kyzn init

# 2. See your health score
kyzn measure

# 3. Run an improvement cycle
kyzn improve
```

## Usage

### Improve

```bash
kyzn improve                        # Interactive — choose model & budget
kyzn improve --auto                 # Non-interactive — use saved config (for cron)
kyzn improve --mode deep            # Real improvements only (no cosmetic changes)
kyzn improve --mode clean           # Cleanup only (dead code, naming, imports)
kyzn improve --mode full            # Everything
kyzn improve --focus security       # Target a specific area
kyzn improve --model opus           # Use a specific model
kyzn improve --budget 5.00          # Override budget cap
kyzn improve -v                     # Show live progress from Claude
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
2. **Measure** — runs real tools (eslint, ruff, npm audit, cargo clippy, go vet, etc.) and computes a health score out of 100
3. **Improve** — invokes Claude Code in headless mode with measurements, constraints, and a per-language tool allowlist
4. **Verify** — runs build and tests. If they fail and the baseline was clean, aborts. If failures are pre-existing, continues.
5. **Score Gate** — re-measures health. If score dropped, aborts and cleans up the branch.
6. **PR** — commits changes, pushes, and creates a PR with before/after health comparison

## Health Score

kyzn computes a weighted health score across 5 categories:

| Category | Weight | What It Measures |
|----------|--------|------------------|
| Security | 25% | Dependency vulnerabilities, hardcoded secrets |
| Testing | 25% | Test coverage, test file ratio |
| Quality | 25% | Lint errors, type errors, TODO count, git health |
| Performance | 15% | Large files, bundle size indicators |
| Documentation | 10% | README quality and completeness |

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

## Supported Languages

| Language | Detection | Measurers | Verify |
|----------|-----------|-----------|--------|
| **Node.js** | `package.json` | npm audit, eslint, tsc, coverage | npm build, npm test |
| **Python** | `pyproject.toml`, `setup.py` | ruff, mypy, pytest-cov, pip-audit | ruff check, mypy, pytest |
| **Rust** | `Cargo.toml` (incl. workspaces) | cargo clippy, cargo audit | cargo check, cargo test |
| **Go** | `go.mod` | go vet, govulncheck | go build, go test, go vet |
| **Generic** | (fallback) | TODOs, git health, secrets, docs | — |

## Safety

kyzn is designed to never make things worse:

- **Branch isolation** — all changes happen on `kyzn/` branches, never touches `main`
- **Budget cap** — configurable per-run spending limit (default $2.50)
- **Tool allowlist** — per-language restrictions on what Claude can run (no `rm`, `sudo`, `git push`)
- **Build gate** — PR only created if build + tests pass after changes
- **Score gate** — aborts if health score drops after improvements
- **Diff guard** — aborts if changes exceed a configurable line threshold (default 2000)
- **Pre-existing failure detection** — won't abort on test failures that existed before Claude ran
- **Branch cleanup** — failed runs clean up their branches automatically

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

# Optional: custom category weights
scoring:
  weights:
    security: 25
    testing: 25
    quality: 25
    performance: 15
    documentation: 10
```

## Modes

| Mode | What It Does | Best For |
|------|-------------|----------|
| **deep** | Only fixes real bugs, security issues, error handling gaps. No cosmetic changes. | Production codebases |
| **clean** | Dead code removal, unused imports, naming fixes, documentation. No behavior changes. | Tech debt cleanup |
| **full** | Both real improvements and cleanup. Maximum value per run. | Side projects |

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
├── templates/
│   ├── improvement-prompt.md
│   └── system-prompt.md
├── profiles/               # Focus-specific system prompts
│   ├── security.md
│   ├── testing.md
│   ├── performance.md
│   ├── quality.md
│   └── documentation.md
└── tests/
    └── selftest.sh         # 79 tests (20 core + 4 stress)
```

## Self-Test

```bash
kyzn selftest              # Quick tests (20 cases)
kyzn selftest --full       # Full suite including stress tests (79 cases)
```

## License

[MIT](LICENSE)

---

<p align="center">
  Built with <a href="https://claude.ai/code">Claude Code</a>
</p>
