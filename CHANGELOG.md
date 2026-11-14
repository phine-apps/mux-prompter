# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-11-14

### Added
- **Zellij multiplexer backend**: Added native support for Zellij (0.44+) across tabs and floating panes (`MUX_BACKEND=zellij`, `ZELLIJ_BIN_PATH`, `--pane-id` targeting, `paste --` injection, `dump-screen --full`, and `list-panes` / `list-tabs` queries), with `Ctrl+b` → `P` (`tmux` mode) keybinding guidance in `README.md`.
- **Expanded Git & worktree placeholders**: Added `{{git_worktree}}` (with default `cd-worktree` template), `{{git_diff:branch}}`, `{{git_log}}`, `{{git_log:branch}}`, `{{git_commit}}`, `{{git_commit:diff}}`, `{{git_branch:choose}}`, `{{git_conflicts}}`, and `{{git_changed_file}}`.
- **Enhanced pane log & chooser capabilities**: Added `{{pane_logs:lines=N}}` and `{{pane_logs:errors}}`, plus `[current]` pane indicators, live log previews, and `:lines=N` / `:errors` modifiers for `{{pane:choose}}`.
- **Real-multiplexer E2E test suite**: Added `tests/e2e_test.py` and Zellij/fzf test mocks for isolated PTY testing across `tmux`, `zellij`, and `herdr`, and updated CI to print Bats output on failure.

### Fixed
- **Herdr auto-detection priority**: Prioritized `$HERDR_PLUGIN_CONTEXT_JSON` over inherited `$TMUX` or `$ZELLIJ` environment variables, falling back cleanly when context is absent.
- **Pane log sanitization**: Stripped DEC private CSI sequences, OSC sequences, and leading/trailing blank runs from captured pane logs.
- **Edge-case & security hardening**: Prevented interactive dependency-check hangs in non-interactive/CI environments, prevented history file race conditions using PID-scoped temp files, filtered numeric percentage progress lines in `{{last_command}}`, preserved caller target panes during `{{pane:choose}}`, used `git ls-files` for clean file discovery, avoided `sed` broken pipe errors when `SIGPIPE` is ignored, and hardened quoting in template editor invocations and `prompter.tmux`.
- **Lint & static analysis**: Resolved `shellcheck` and `ruff` warnings across `prompter.sh` and the test suite.

## [0.3.0] - 2026-09-23

### Added
- **Markdown-based template management**: Prompts are now managed as individual `.md` files under `templates/` (supporting subdirectories for categories) with automatic migration from legacy `templates.txt`.
- **Interactive template management UI**: New `🔧 Edit Templates` menu to create, edit (supporting `$VISUAL`/`$EDITOR` with command flags), and delete templates (`Ctrl-D`).
- **Enhanced pane targeting & choosers**: Added support for choosing the current pane in choosers, plus `PROMPTER_CALLER_PANE` and `PROMPTER_TARGET_PANE` environment overrides.
- **Dedicated custom variable definitions**: Candidate generators can be specified in `templates/_vars.txt` or within any template markdown file.

### Removed
- **Immediate execution (`!`)**: Removed automatic Enter submission for templates prefixed with `!`; all templates now safely inject text directly into the active pane buffer for review.

### Fixed
- **Live preview synchronization**: Fixed `fzf` preview to track the currently highlighted item while filtering.
- **Safe text injection & escape preservation**: Guaranteed preservation of raw backslashes (`\n`, Windows paths), prevented code syntax corruption upon history restoration, and prevented pipe/option parsing collisions in history.
- **Robust placeholder resolution**: Implemented non-recursive sentinel token replacement preventing secondary placeholder injection, resolved multiple `{{file:lines=...}}` ranges in a single template, preserved command spaces and multi-space prompt layouts in `{{last_command}}`, and added support for Powerlevel9k/Powerline (``/``) and multi-arrow (`❯❯❯`) prompt terminators.
- **Cross-platform template compatibility**: Sanitized CRLF line endings in template files and previews, preventing carriage return corruption across Windows, Git checkout, and macOS/Linux environments.
- **Multiplexer compatibility & UI fixes**: Standardized cross-mux UI rendering (`🔧`), excluded temporary prompter panes in tmux split mode, and improved injection timing.

## [0.2.0] - 2026-08-12

### Added
- Native **tmux** support using TPM (Tmux Plugin Manager) or manual setup.
- Hybrid backend auto-detection and custom override (`MUX_BACKEND` environment variable).
- Configured automated tests with GitHub Actions CI using `bats-action`.

### Changed
- Migrated testing framework from custom setup to **`bats-core`**.

## [0.1.0] - 2026-07-20

### Added
- Initial release of Mux Prompter featuring interactive `fzf` picker UI and context placeholders (`{{git_diff}}`, `{{error}}`, `{{pane_logs}}`, etc.) for Herdr environments.
