# How KyZN Works

## `kyzn quick` — Sonnet incremental improvements

```
 ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
 │  Detect  │───▶│ Measure  │───▶│ Improve  │───▶│  Verify  │───▶│  Score   │───▶│    PR    │
 │          │    │          │    │ (Sonnet) │    │          │    │  Gate    │    │          │
 │ language │    │ run real │    │ Claude   │    │ build +  │    │ abort   │    │ before/  │
 │ features │    │ tools    │    │ Code     │    │ tests    │    │ if drop │    │ after    │
 └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
```

If verification fails on a previously clean build, KyZN attempts **self-repair** — it sends the error output back to Claude for one retry before aborting.

## `kyzn analyze` — Multi-agent Opus deep analysis

```
                                  ┌────────────┐
                                  │  Security  │──┐
 ┌──────────┐    ┌──────────┐    ├────────────┤  │    ┌───────────┐    ┌──────────┐
 │  Detect  │───▶│ Measure  │───▶│Correctness │──┼───▶│ Consensus │───▶│  Report  │───▶│   Fix    │
 │          │    │          │    ├────────────┤  │    │  (Opus)   │    │          │    │ (Sonnet) │
 │ language │    │ run real │    │Performance │──┤    │ dedup +   │    │ kyzn-    │    │ optional │
 │ features │    │ tools    │    ├────────────┤  │    │ rank      │    │ report   │    │ --fix    │
 └──────────┘    └──────────┘    │Architecture│──┘    └───────────┘    │ .md      │    └──────────┘
                                  └────────────┘                       └──────────┘
                                   4 Opus sessions
                                   (parallel)
```

## Pipeline steps

1. **Detect** — identifies project type and features (TypeScript, tests, CI, Docker, linter)
2. **Measure** — runs real tools and computes a health score out of 100
3. **Improve/Analyze** — Sonnet for incremental fixes, 4 parallel Opus specialists for deep code review
4. **Verify** — runs build and tests. Aborts on new failures, continues on pre-existing ones
5. **Self-repair** — if verification fails, retries once with error context (reflexion loop)
6. **Score Gate** — re-measures health. If score dropped, aborts and cleans up
7. **Report** — compact terminal summary + detailed `kyzn-report.md` saved to project root
8. **PR** — commits, pushes, and creates PR with before/after health comparison

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

## Modes

| Mode | What It Does | Best For |
|------|-------------|----------|
| **deep** | Only fixes real bugs, security issues, error handling gaps. No cosmetic changes. | Production codebases |
| **clean** | Dead code removal, unused imports, naming fixes, docs. No behavior changes. | Tech debt cleanup |
| **full** | Both real improvements and cleanup. Maximum value per run. | Side projects |

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
  on_build_fail: report # report | discard | draft-pr
  # trust level is in .kyzn/local.yaml (gitignored, not committable)

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

## Supported Languages

| Language | Detection | Measurers | Verify |
|----------|-----------|-----------|--------|
| **Node.js** | `package.json` | npm audit, eslint, tsc, coverage | npm build, npm test |
| **Python** | `pyproject.toml`, `setup.py` | ruff, mypy, pytest-cov, pip-audit | ruff check, mypy, pytest |
| **Rust** | `Cargo.toml` (incl. workspaces) | cargo clippy, cargo audit | cargo check, cargo test |
| **Go** | `go.mod` | go vet, govulncheck | go build, go test, go vet |
| **Generic** | (fallback) | TODOs, git health, secrets, docs | — |
