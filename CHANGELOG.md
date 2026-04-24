# Changelog

All notable changes to KyZN are documented here.

## Unreleased

### Security
- **Clean-worktree gate** — mutating runs now refuse uncommitted local changes by default, with an explicit `--allow-dirty` escape hatch.
- **Safe verification defaults** — Node/Python dependency installation is opt-in via `kyzn doctor --install`, `verification.install_deps: true`, or `KYZN_VERIFY_INSTALL_DEPS=true`.

### Testing
- Added regression coverage proving dependency installs are skipped by default and dirty worktrees are blocked.
- **285 tests passing** (full suite).

## [1.1.3] — 2026-04-24

### Fixed
- **CI git identity** — GitHub Actions now configures a local git identity before running selftests, fixing sandbox commits on fresh runners.
- **ShellCheck CI failures** — removed dead locals and documented intentional cross-module globals/namerefs with narrow ShellCheck suppressions.
- **Global directory permissions warning** — split `mkdir -p` from `chmod 700` so permissions are enforced without SC2174 warnings.

### Testing
- Selftest sandboxes now configure repo-local git identity, matching CI behavior.
- Added assertions for history project metadata and new-file diff accounting.
- **279 tests passing** (full suite).

## [1.1.2] — 2026-04-01

### Fixed
- **pip-audit JSON parsing** — `jq 'length'` was counting object keys instead of vulnerabilities, causing wrong security scores for all Python projects
- **Symlink check fallback** — macOS fallback now resolves multi-level symlink chains (was single-level only)
- **grep -E vs grep -F** — `cmd_diff` used regex grep despite comment saying fixed-string; changed to match intent
- **mkdir permissions** — `chmod 700` added after `mkdir -p` to fix permissions on pre-existing `~/.kyzn` directories
- **YAML heredoc safety** — `save_interview_config` now quotes interpolated values, matching `strenv()` pattern used elsewhere
- **Unquoted array append** — `pids+=($pid)` → `pids+=("$pid")` in specialist dispatch

### Security
- **Quick-path prompt fencing** — added data fencing instruction to `improvement-prompt.md` (was only on analyze path)
- **Shell history blocked** — added `~/.bash_history`, `~/.zsh_history`, `~/.python_history` to `disallowedFileGlobs`
- **Cached profile gitignored** — `repo-profile.md` added to auto-generated `.kyzn/.gitignore`

### Documentation
- Fixed `kyzn improve` → `kyzn quick` in `docs/how-it-works.md`
- Added missing `model` key to `.kyzn.example.yaml`
- Added 4 post-v0.5.0 security features to `SECURITY.md`
- Fixed wrong log directory path in bug report template (`.kyzn/runs/` → `.kyzn/history/`)
- Added `status` and `dashboard` commands to README

## [1.1.1] — 2026-04-01

### Security
- **CI supply chain hardening** — pinned yq to v4.52.4 with SHA256 checksum verification in CI workflow (was downloading `latest` via `sudo wget` with no integrity check)
- **Tool allowlist tightening** — removed trailing globs from commands that don't need arguments (`npm ci`, `npm audit`, `pip list`, `cargo audit`, `go mod`). Documented glob metacharacter risk for patterns that retain `*`
- **Prompt injection mitigation** — sanitized project names (alphanumeric + hyphens/underscores only, 128 char max) and added data fencing markers around raw JSON blocks injected into Claude prompts

### Fixed
- **TOCTOU lock race** — extracted `acquire_kyzn_lock()` / `release_kyzn_lock()` into `lib/core.sh`, replacing duplicated lock logic in `execute.sh` and `analyze.sh`. The new implementation removes the `rm -rf` → `sleep 0.1` → `mkdir` race window
- **SC2155 ShellCheck warnings** — split 4 `local var=$(cmd)` declarations to avoid masking return values (`analyze.sh`, `core.sh`, `execute.sh`)

### Changed
- **Generic project build gate** — `verify_build` now checks for a Makefile and runs `make check` / `make test` instead of silently skipping all verification for generic projects

## [1.1.0] — 2026-03-31

### Added
- Multi-provider support added then reverted — KyZN remains Claude-only after Codex CLI proved unreliable

### Fixed
- Auto-detect broken `bwrap` sandbox and fallback silently
- Graceful handling of malformed specialist JSON output
- `config_get` regex regression + `skip()` unbound variable
- Robust branch recovery when Claude switches to `main` during fix phase
- Guard missing CLI args + fail-closed checksum verification
- macOS BSD `sed` compatibility (replaced grouping with `tail`)
- Suppress false update warning when local is ahead of remote
- Exclude generated dirs from staging even without `.gitignore`

### Security
- 9 security hardening fixes from Cursor + Codex audits

### Testing
- Added tests to CI workflow
- **276 tests passing** (full suite)

## [1.0.0] — 2026-03-24

### Added
- `kyzn fix` command — unified deep analysis + auto-fix pipeline (analyze → fix → verify → PR)
- Profiler agent — Sonnet reads repo conventions, caches to `.kyzn/repo-profile.md` with SHA invalidation
- fix_plan metadata in analysis findings — structured guidance for targeted Sonnet fixes
- Per-language convention injection into analyze path (Node, Python, Rust, Go)
- `--profile` flag for analysis model selection (opus/hybrid/sonnet)
- `--min-severity` flag for fix severity filtering

### Changed
- `kyzn analyze` is now report-only — no interactive fix menu (use `kyzn fix` instead)
- `kyzn analyze --fix` is now equivalent to `kyzn fix`
- Consensus enforces JSON-only output — prevents truncation on large finding sets

### Fixed
- vitest "No test files found" exit code 1 no longer treated as failure
- `CI=true` set for all npm test calls (prevents vitest/jest watch mode hang)
- 300s timeout on npm test calls (prevents indefinite hangs)

### Security
- Removed `npm install*` and `pip install*` from tool allowlist (arbitrary code execution via install scripts)
- Expanded `~` to `$HOME` in file access restrictions (ensures Claude Code resolves home paths)
- Added gitattributes filter protection to `safe_git` (prevents code execution via clean/smudge)
- Scrubbed personal paths from published audit reports

### Testing
- **259 tests passing** (was 208)

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
