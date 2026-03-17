# kyzn

Autonomous code improvement CLI. Point it at any project, and it measures → improves → verifies → creates a PR.

Powered by [Claude Code](https://claude.ai/code) headless mode.

## Install

```bash
# Clone and symlink
git clone https://github.com/bokiko/kyzn.git ~/.kyzn-cli
ln -sf ~/.kyzn-cli/kyzn ~/.local/bin/kyzn

# Or one-liner
curl -fsSL https://raw.githubusercontent.com/bokiko/kyzn/main/install.sh | bash
```

## Prerequisites

```bash
kyzn doctor  # checks everything
```

Required: `git`, `gh`, `claude` CLI, `jq`, `yq`, `ANTHROPIC_API_KEY`

## Usage

```bash
# First time — set up your project
kyzn init

# Check project health
kyzn measure

# Run an improvement cycle
kyzn improve

# With options
kyzn improve --mode deep      # real improvements only (no cosmetics)
kyzn improve --mode clean     # cleanup only (dead code, naming)
kyzn improve --mode full      # everything
kyzn improve --focus security # target specific area
kyzn improve --budget 5.00    # override budget cap
kyzn improve --auto           # use saved config (for cron)

# Review results
kyzn history
kyzn diff <run-id>
kyzn approve <run-id>
kyzn reject <run-id> -r "reason"

# Schedule recurring runs
kyzn schedule weekly
kyzn schedule off
```

## How It Works

1. **Detect** — identifies project type (Node, Python, Rust, Go)
2. **Interview** — asks what you want to improve (or auto-detects weakest area)
3. **Measure** — runs real tools (eslint, ruff, npm audit, pytest-cov, etc.)
4. **Improve** — invokes Claude Code with measurements + constraints
5. **Verify** — runs build + tests after changes
6. **Report** — creates PR with before/after health scores

## Safety

- Never touches `main` — works on `kyzn/` branches
- Budget cap per run (default $2.50)
- Per-language tool allowlists (no `rm`, `sudo`, `git push`)
- Build gate — PR only if build + tests pass
- Diff guard — aborts if changes exceed threshold

## Config

`kyzn init` creates `.kyzn/config.yaml` (commit this):

```yaml
project:
  name: my-project
  type: node

preferences:
  mode: deep
  budget: 2.50
  trust: guardian      # guardian | autopilot
  on_build_fail: report

focus:
  priorities: [security, testing]
```

## Supported Languages

| Language | Detection | Measurers | Tools |
|----------|-----------|-----------|-------|
| Node.js  | package.json | npm audit, eslint, tsc, coverage | npm, npx, node |
| Python   | pyproject.toml | ruff, mypy, pytest-cov, pip-audit | pip, pytest, ruff, mypy |
| Rust     | Cargo.toml | clippy, cargo test, cargo audit | cargo |
| Go       | go.mod | go vet, go test, govulncheck | go |
| Generic  | (fallback) | TODOs, git health, secrets, docs | — |

## License

MIT
