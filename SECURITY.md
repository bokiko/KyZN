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

## Threat Model

The primary attack surface is **malicious repositories**. KyZN executes your project's build and test commands (`npm test`, `pytest`, `cargo test`, etc.). Do not run KyZN on repositories you don't trust.

## Audit Reports

We publish our security audit reports transparently:
- [Executive Summary](full-audit-by-claude/EXECUTIVE-SUMMARY.md)
- [All 16 agent reports](full-audit-by-claude/)

## Disclaimer

KyZN generates AI-powered code changes. Always review PRs before merging. The authors are not responsible for any damage caused by AI-generated modifications.
