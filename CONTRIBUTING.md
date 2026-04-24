# Contributing to KyZN

Thanks for your interest in KyZN! Here's how to get started.

## Development Setup

KyZN is pure Bash — no build step, no compiled dependencies.

```bash
git clone https://github.com/bokiko/KyZN.git
cd KyZN
```

## Running Tests

```bash
# Quick tests (276 cases, ~4s)
bash tests/selftest.sh

# Full suite with stress tests (285 cases, ~9s)
bash tests/selftest.sh --full
```

## Linting

We use ShellCheck (matches CI):

```bash
shellcheck -S warning kyzn lib/*.sh measurers/*.sh tests/selftest.sh
```

## Coding Conventions

- Functions: `snake_case`
- Commands: `cmd_` prefix (e.g., `cmd_improve`)
- Globals: `KYZN_` prefix
- Internal helpers: `_kyzn_` prefix
- Health score weights: security 25%, testing 25%, quality 25%, performance 15%, documentation 10%

## Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — new feature
- `fix:` — bug fix
- `docs:` — documentation
- `perf:` — performance
- `chore:` — maintenance

## Pull Requests

1. Branch from `main`
2. Include test coverage for new features
3. Ensure `shellcheck` and `selftest --full` pass
4. Keep PRs focused — one feature or fix per PR

## Architecture

See [CLAUDE.md](CLAUDE.md) for detailed module descriptions and pipeline architecture, or [docs/how-it-works.md](docs/how-it-works.md) for the user-facing explanation.

## Questions?

Open an issue — we're happy to help.
