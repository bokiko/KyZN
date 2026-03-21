# Changelog

All notable changes to KyZN are documented here.

## [0.5.0] — 2026-03-21

### Security
- Replaced `eval` with safe bash built-ins (`${!var}`, `printf -v`, `awk -v`) — eliminates injection risk in config ceiling enforcement
- Converted tool allowlist from string word-splitting to proper bash array expansion — fixes silently broken language-specific tool restrictions
- Added `validate_run_id()` with positive format check — prevents path traversal in approve, reject, and diff commands
- Expanded restricted file access list (shell configs, package manager credentials, container configs)
- Narrowed `npx *` wildcard to specific tools (eslint, tsc, vitest, jest, prettier)
- Removed `trust` setting from committable config — now only in gitignored `local.yaml`
- Replaced `source /etc/os-release` with safe `grep` parsing in installer
- Set restrictive permissions (700) on global directories

### Crash Safety
- Added cleanup trap to `cmd_analyze` — kills background Claude processes on Ctrl+C, updates history to "failed", cleans temp files
- Measurer errors now logged instead of silently discarded
- Fixed crontab crash when no existing crontab exists
- Added PATH to cron entries so scheduled runs find tools
- Pre-initialized trap variables before setting trap in `cmd_improve`

### Measurement Accuracy
- Fixed govulncheck NDJSON parsing (was treating newline-delimited JSON as single object)
- Fixed `go vet` issue counting (was counting `ok` lines as errors)
- Fixed `cargo clippy` overcounting (was matching nested JSON, not top-level compiler messages)

### Performance
- Batched jq calls in history, dashboard, and report generation (5-7x fewer subprocesses)
- Cached `project_root()` and `project_name()` (called ~15 times per improve run)

### UX
- Shows Claude stderr on failure (was silently deleted)
- `kyzn analyze --fix` now creates PRs (was commit-only)
- Added concurrency lock and diff-limit check to fix phase
- Update notification changed from red to yellow
- Documented all previously undocumented flags in `--help`
- Fixed misleading approval message

### Dead Code
- Replaced duplicate `config_set_str` with alias to `config_set`
- Wired in `display_findings()` (was defined but never called)
- Extracted `KYZN_SETTINGS_JSON` constant (was hardcoded in 4 places)

### Testing
- **208 tests passing** (was 156)
- New tests: `enforce_config_ceilings` (including awk injection), `unstage_secrets`, path traversal in reject/diff, `validate_run_id`

### Transparency
- Published all 16 agent audit reports in `full-audit-by-claude/`
- Added Security Transparency section to README

## [0.4.0] — 2026-03-18

### Added
- Multi-agent analysis — 4 Opus specialists + consensus (`kyzn analyze`)
- Two-model architecture (Opus analyzes, Sonnet fixes)
- Live progress indicator during multi-agent analysis
- `--fix` mode for analyze (Sonnet implements findings)
- Compact terminal output + detailed `kyzn-report.md`
- Full report context passed to fix phase
- Machine-wide activity dashboard (`kyzn dashboard`)
- Per-category score floor (aborts if any category drops > 5pts)
- Trust isolation (trust level in gitignored local.yaml)
- CI file blocking (unstages pipeline files by default)
- Tightened allowlists to specific subcommands
- File access restrictions via `--settings` flag
- Invocation timeout (default 10min)

## [0.3.0] — 2026-03-17

### Added
- Core improvement cycle (detect, measure, improve, verify, PR)
- Node.js, Python, Rust, Go support
- Interactive model and budget selection
- Score regression gate
- Pre-existing test failure detection
- Branch cleanup on all failure paths
- Approve/reject workflow
- Cron scheduling
- Health score dashboard with category breakdown
