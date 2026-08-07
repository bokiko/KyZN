<p align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=gradient&customColorList=14,20,24&height=200&section=header&text=KyZN&fontSize=60&fontColor=ffffff&animation=fadeIn&fontAlignY=38&desc=Autonomous%20Code%20Improvement%20CLI&descAlignY=55&descAlign=50" />
</p>

<p align="center">
  <a href="https://www.kyzn.dev"><img src="https://img.shields.io/badge/Website-kyzn.dev-2ecc71?style=for-the-badge&logo=icloud&logoColor=white" alt="Website"></a>
  <a href="https://github.com/bokiko/KyZN"><img src="https://img.shields.io/badge/GitHub-KyZN-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://x.com/bokiko"><img src="https://img.shields.io/badge/X-@bokiko-000000?style=for-the-badge&logo=x&logoColor=white" alt="X"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Bash-4.3+-2ecc71?style=flat-square&logo=gnu-bash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Claude_Code-Powered-2ecc71?style=flat-square" alt="Claude Code">
  <img src="https://img.shields.io/badge/version-2.0.0-2ecc71?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/selftests-Linux%20%2B%20macOS-2ecc71?style=flat-square" alt="Self-tests on Linux and macOS">
  <img src="https://img.shields.io/badge/license-MIT-2ecc71?style=flat-square" alt="License">
  <img src="https://img.shields.io/github/last-commit/bokiko/KyZN?style=flat-square&color=2ecc71" alt="Last Commit">
</p>

<p align="center">
  <a href="https://git.io/typing-svg"><img src="https://readme-typing-svg.demolab.com?font=Fira+Code&size=18&pause=1000&color=2ecc71&center=true&vCenter=true&width=500&lines=Measure+%E2%86%92+Analyze+%E2%86%92+Fix+%E2%86%92+Verify+%E2%86%92+Ship;4+Opus+specialists+%2B+consensus;Quick+%2B+full+selftests+on+Linux+%2B+macOS;6+language+profiles+%2B+real-toolchain+CI" alt="Typing SVG"></a>
</p>

## Contents

- [Why KyZN?](#why-kyzn)
- [Quick Demo](#quick-demo)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [How It Works](#how-it-works)
- [Safety Model](#safety-model)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)

---

## Why KyZN?

Improving a codebase with Claude is powerful — but doing it manually means you're the glue holding the workflow together:

1. Run linters, type checkers, and security audits for your language
2. Read the output, decide what matters
3. Paste findings into Claude with enough context
4. Hope Claude doesn't burn tokens on cosmetic renames and import shuffling
5. Review the diff for regressions and leaked secrets
6. Run tests yourself
7. Check the health score didn't drop
8. Create a PR with a summary of what changed

**KyZN replaces all of that with one command.** It runs real tools, scores your repo, dispatches 4 specialist agents to find issues across security, correctness, performance, and architecture — then fixes them in severity batches with build verification after each one. If something breaks, it auto-retries. If the health score drops, it aborts. When it's done, you get a PR with before/after scores.

```
kyzn fix --allow-unsafe-host-execution  →  profile repo  →  4 Opus specialists  →  consensus  →  Sonnet fixes  →  verify  →  PR
```

Supports **Node.js**, **Python**, **Rust**, **Go**, **C# / .NET**, and **Java / JVM** out of the box. Works on any project type for generic analysis.

### How KyZN uses tokens efficiently

KyZN is designed to get more value per token than an interactive Claude session:

| Mechanism | What it does |
|-----------|-------------|
| **Structured JSON input** | Linter output is parsed into scored JSON — Claude gets signal, not 200 lines of raw tool output |
| **Mode constraints** | `deep` mode blocks cosmetic changes (renames, reformats, import reordering) so tokens go to real fixes |
| **Read-only analysis** | Specialist agents only get Read/Glob/Grep — zero tokens spent on exploratory edits during analysis |
| **Cached profiler** | Repo conventions are profiled once per commit SHA and reused across runs |
| **Consensus dedup** | 4 specialists may flag the same issue — consensus removes duplicates before the fix phase starts |
| **Hard budget caps** | Every Claude invocation has `--max-budget-usd` and `--max-turns` enforced (default quick run: $2.50, 30 turns) |
| **Stateless sessions** | `--no-session-persistence` on every call — no cross-run context bloat accumulating |
| **Structured fix plans** | Each finding includes target file, function, and pattern — the fix agent doesn't spend tokens figuring out *where* to edit |

---

## Quick Demo

```bash
$ kyzn measure

  Project Health Score: 68 / 100

  security        ████████████████░░░░  80%
  testing         ██████████░░░░░░░░░░  50%
  quality         ██████████████░░░░░░  72%
  performance     ████████████████████ 100%
  documentation   ████████████░░░░░░░░  60%

$ kyzn fix --allow-unsafe-host-execution

  → Profiler: scanning repo conventions...
  → 4 specialists dispatched (security | correctness | performance | architecture)
  → Consensus: 27 findings (deduped from 32)
  → Fixing HIGH (7 issues)... ✓ Build passes
  → Fixing MEDIUM (10 issues)... ✓ Build passes
  → Fixing LOW (6 issues)... ✓ Build passes
  → PR created: https://github.com/you/project/pull/5
```

One command. Zero config. Real bugs fixed, verified, and shipped.

---

## Quick Start

### Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| `git` | Yes | Branch management |
| `gh` | Yes | PR creation ([GitHub CLI](https://cli.github.com)) |
| `claude` | Yes | AI analysis ([Claude Code](https://docs.anthropic.com/en/docs/claude-code)) |
| `jq` | Yes | JSON processing (installer may use the system package manager) |
| `yq` | Yes | YAML config (downloaded pinned binaries are checksum-verified when a published checksum is available) |

> **macOS:** Requires Bash 4.3+ (`brew install bash`). The system `/bin/bash` is v3.2 and will not work.

### Install

```bash
curl -fsSL https://raw.githubusercontent.com/bokiko/KyZN/main/install.sh | bash
```

Or clone manually:
```bash
git clone https://github.com/bokiko/KyZN.git ~/.kyzn-cli
ln -sf ~/.kyzn-cli/kyzn ~/.local/bin/kyzn
```

### First Run

```bash
kyzn doctor     # Check prerequisites
kyzn init       # Interactive setup → .kyzn/config.yaml
kyzn measure    # Static measurements (no project commands)
kyzn fix --allow-unsafe-host-execution  # Deep analysis + auto-fix → PR
```

---

## Usage

### `kyzn fix` — The main command

```bash
kyzn fix --allow-unsafe-host-execution                         # Full pipeline: profile → analyze → fix → verify → PR
kyzn fix --auto --allow-unsafe-host-execution                  # Non-interactive; manual PR review remains required
kyzn fix --profile hybrid --allow-unsafe-host-execution        # Opus for security+correctness, Sonnet for perf+arch
kyzn fix --min-severity HIGH --allow-unsafe-host-execution     # Only fix HIGH+ findings
kyzn fix --fix-budget 10.00 --allow-unsafe-host-execution      # Budget for fix phase
kyzn fix --allow-dirty --allow-unsafe-host-execution           # Expert mode: run with local uncommitted changes
```

Profiler scans conventions, 4 Opus specialists find issues in parallel, consensus deduplicates, Sonnet fixes in severity batches (CRITICAL → HIGH → MEDIUM → LOW) with build/test verification after each batch. If a fix breaks the build, reflexion retry gives Sonnet a second chance with the error output. Opens a PR when done.

### `kyzn analyze` — Report only (no changes)

```bash
kyzn analyze                    # 4 Opus specialists + consensus report
kyzn analyze --focus security   # Single specialist (security only)
kyzn analyze --single           # Single general reviewer (cheaper)
kyzn analyze --export report.md # Export to custom path
```

### `kyzn quick` — Lightweight single-pass

```bash
kyzn quick --allow-unsafe-host-execution                       # Single Sonnet pass, fast
kyzn quick --auto --allow-unsafe-host-execution                # Non-interactive; manual PR review remains required
kyzn quick --mode deep --allow-unsafe-host-execution           # Real improvements only
kyzn quick --mode clean --allow-unsafe-host-execution          # Dead code + naming cleanup
kyzn quick --mode full --allow-unsafe-host-execution           # Everything
kyzn quick --allow-dirty --allow-unsafe-host-execution         # Expert mode: allow uncommitted local changes
```

### Other commands

```bash
kyzn measure                    # Static measurements (no project commands)
kyzn measure --allow-unsafe-host-execution  # Include package/build-tool measurements
kyzn doctor                     # Check prerequisites
kyzn doctor --install --allow-unsafe-host-execution  # Opt in to dependency installation on this host
kyzn history                    # Show all runs
kyzn diff <run-id>              # Show what changed
kyzn approve <run-id>           # Sign off
kyzn reject <run-id> -r "why"   # Reject with feedback
kyzn schedule daily             # Disabled until KyZN provides isolated execution
kyzn schedule off               # Remove schedule
kyzn status                     # Health score dashboard
kyzn dashboard                  # Machine-wide activity summary
kyzn selftest                   # Run the quick self-test suite
kyzn selftest --full            # Include stress tests
```

---

## How It Works

```
kyzn fix --allow-unsafe-host-execution
  │
  ├─ Detect project type (package.json / Cargo.toml / go.mod / etc.)
  ├─ Measure health score with real tools (eslint, ruff, clippy, go vet)
  ├─ Profile repo conventions (Sonnet reads your code patterns)
  │
  ├─ 4 Opus specialists in parallel:
  │   ├─ Security      ─┐
  │   ├─ Correctness    ├─→ Consensus (dedup + rank)
  │   ├─ Performance    │
  │   └─ Architecture  ─┘
  │
  ├─ Sonnet fixes in severity batches:
  │   ├─ CRITICAL → verify → commit
  │   ├─ HIGH     → verify → commit
  │   ├─ MEDIUM   → verify → commit
  │   └─ LOW      → verify → commit
  │   (failed batch → reflexion retry → revert if still fails)
  │
  ├─ Score regression gate
  └─ Push branch → create PR
```

**Health score** (out of 100): security 25%, testing 25%, quality 25%, performance 15%, documentation 10%. Configurable.

**Languages:** Node.js, Python, Rust, Go, C# / .NET, and Java / JVM have detection, measurement, agent-tool, and verification profiles. Generic analysis works on any repository; mutating generic runs require a passing Makefile `check`/`test` target or explicit `verification.command`. A gitignored `.kyzn/local.yaml` command overrides the committed fallback, and KyZN prints the exact command before running it. A tracked `local.yaml` is refused and cannot override the committed contract.

| Project profile | Detection | Measurement | Agent tools | Verification | CI fixtures | Isolated runner |
|-----------------|-----------|-------------|-------------|--------------|-------------|-----------------|
| Node.js | Yes | eslint / TypeScript / audit signals | npm/npx profile | npm build/test + TypeScript | Linux + macOS | No |
| Python | Yes | ruff / mypy / audit signals | pytest/ruff/mypy profile | pytest + optional ruff/mypy | Linux + macOS | No |
| Rust | Yes | clippy / audit signals | cargo profile | cargo build/test | Linux + macOS | No |
| Go | Yes | vet / vulnerability signals | go profile | go build/test/vet | Linux + macOS | No |
| C# / .NET | Yes | dotnet signals | dotnet profile | dotnet build/test/format | Linux + macOS | No |
| Java / JVM | Yes | Maven/Gradle signals | Maven/Gradle profile | Maven or Gradle build/test | Linux + macOS | No |
| Generic | Fallback | Static repository signals | read/search only | Explicit command or Make target | Linux + macOS | No |

The CI entries above are deterministic KyZN fixtures, not claims that every external language toolchain is installed in the matrix. Host execution remains explicitly unsafe until an isolated runner ships.

<!-- BEGIN GENERATED REPOSITORY FACTS -->
- Repository files: **74**
- Bash entrypoints/modules/scripts: **24** files, **12557** lines
- Self-test harness: **94** test functions, **4451** lines (runtime assertion totals are reported by the suite, not hardcoded)
- Project profiles: **6** languages plus the generic fallback
- CI matrix: **Linux and macOS**, each running quick and full self-tests
<!-- END GENERATED REPOSITORY FACTS -->

Verification fails closed when a required language runner is unavailable. Root and nested tracked or untracked Python test layouts are detected. KyZN never converts broken tests into ignore flags.

---

## Safety Model

KyZN runs AI with real tool access on your code. Every layer has safety constraints:

| Layer | Protection |
|-------|-----------|
| **Branch isolation** | All changes on `kyzn/` branches, never touches `main` |
| **Clean-worktree gate** | Mutating runs refuse uncommitted changes unless `--allow-dirty` is explicit |
| **Host-execution gate** | Mutating runs fail closed unless each run explicitly passes `--allow-unsafe-host-execution` |
| **Hook protection** | All git operations disable hooks via `core.hooksPath=/dev/null` |
| **Tool allowlist** | Per-language restrictions tightened to specific subcommands (glob-safe where possible) |
| **File restrictions** | Claude cannot read `~/.ssh`, `~/.aws`, `.env`, key files, Terraform state |
| **Symlink detection** | Rejects repos with symlinks escaping the repo root |
| **Budget cap** | Hard ceiling: $25/run, 100 turns, 10000 diff lines |
| **Verification gate** | Authorization depends only on the **final** `verify_build` exit code — a red result is never certified as verified. In `quick` / `improve`: `0` → success path, `1` → the configured `on_build_fail` strategy (marked draft PR available), `2` → unconditional abort. In `analyze --fix` the unit is the severity batch: a red batch is reverted (`git reset --hard`) and the run continues, so a partially failed run can still open a normal PR of the batches that passed — `on_build_fail` does not apply there. Either way a red baseline still earns an improvement attempt plus one repair attempt. Note `0` also means "no applicable check applied" — it does not by itself prove checks ran. |
| **Score gate** | Aborts if health score drops |
| **Secret detection** | Unstages files matching `.env`, `.pem`, `.key`, credentials patterns |
| **CI blocking** | Workflow files unstaged by default |
| **Manual merge** | Autopilot is disabled; every generated PR waits for human review |
| **Supply chain** | CI pins and checksum-verifies its downloaded `yq` binary; installer downloads are verified when a published checksum is available |
| **Prompt hardening** | Project names sanitized, raw data fenced to prevent prompt injection |
| **Concurrency lock** | Atomic `mkdir`-based lock with stale PID detection prevents concurrent runs |

> **Important:** KyZN does not yet provide container or VM isolation. `kyzn analyze` and `kyzn measure` default to static generic measurements; language-specific package/build tools run only with `--allow-unsafe-host-execution`. Mutating commands fail closed unless that run explicitly passes the same flag. This acknowledgement means repository-controlled builds/tests and AI-generated changes run with your user permissions. Dependency installation additionally requires `kyzn doctor --install --allow-unsafe-host-execution`. Recurring mutating schedule creation is disabled until isolated execution exists. Do not enable host execution for repositories you do not trust. See [SECURITY.md](SECURITY.md) for the full threat model.

---

## Project Structure

```
kyzn/
├── kyzn                    # Entry point + subcommand routing
├── install.sh              # Installer (package-manager or verified download)
├── lib/                    # 13 core modules
│   ├── core.sh             # Logging, config, constants
│   ├── detect.sh           # Project type detection
│   ├── measure.sh          # Health score computation
│   ├── execute.sh          # Claude invocation + safety
│   ├── analyze.sh          # Multi-agent pipeline + fix phase
│   ├── verify.sh           # Build/test verification
│   ├── prompt.sh           # Prompt assembly
│   ├── allowlist.sh        # Per-language tool restrictions
│   ├── report.sh           # PR body generation
│   ├── interview.sh        # Interactive setup
│   ├── history.sh          # Run history + dashboard
│   ├── approve.sh          # Approve/reject workflow
│   └── schedule.sh         # Legacy schedule removal; creation disabled
├── measurers/              # Per-language health measurers
│   ├── generic.sh, node.sh, python.sh, rust.sh, go.sh, csharp.sh, java.sh
├── templates/              # System prompts + analysis templates
├── profiles/               # Focus-specific prompts
├── tests/selftest.sh       # Quick, full, and stress self-test harness
├── tests/toolchain/
│   └── run-matrix.sh       # Real-toolchain integration matrix
├── SECURITY.md             # Threat model + published audit
└── .github/workflows/      # ci.yml (ShellCheck + selftests)
                            # toolchain-matrix.yml (real SDKs)
```

---

## Contributing

KyZN is early-stage and actively developed. Contributions are welcome — whether it's a bug fix, a new language measurer, or an idea for the pipeline.

### Quick dev setup

```bash
git clone https://github.com/bokiko/KyZN.git
cd KyZN
bash tests/selftest.sh          # Quick self-test suite
bash tests/selftest.sh --full   # Include stress tests
shellcheck -S warning kyzn lib/*.sh measurers/*.sh tests/selftest.sh tests/toolchain/run-matrix.sh
```

No build step — it's pure Bash. `ci.yml` runs repository-wide ShellCheck at warning severity plus the quick and full selftests, with a configured git identity for sandbox commits. A second workflow, `toolchain-matrix.yml`, exercises `lib/verify.sh` against real TypeScript, .NET, Maven and Gradle toolchains on pinned SDKs. See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions, commit format, and PR guidelines.

### Where to contribute

| Area | What's needed | Start here |
|------|--------------|------------|
| **New languages** | Add measurers for Ruby, PHP, etc. | `measurers/` — follow `python.sh` as a template |
| **Measurers** | Improve scoring accuracy, add new tools | `measurers/*.sh` |
| **Analysis prompts** | Better specialist prompts, fewer false positives | `templates/` |
| **Safety** | New edge cases, threat model gaps | `lib/execute.sh`, [SECURITY.md](SECURITY.md) |
| **Tests** | Cover untested paths, new edge cases | `tests/selftest.sh` |
| **Docs** | Improve guides, add examples | `README.md`, `docs/` |

### Report a bug or request a feature

- [Bug Report](https://github.com/bokiko/KyZN/issues/new?template=bug_report.yml)
- [Feature Request](https://github.com/bokiko/KyZN/issues/new?template=feature_request.yml)

---

## License

MIT — see [LICENSE](LICENSE).

---

<img src="https://capsule-render.vercel.app/api?type=waving&color=gradient&customColorList=14,20,24&height=100&section=footer" />
<p align="center">
  Made by <a href="https://bokiko.io">@bokiko</a>
</p>
