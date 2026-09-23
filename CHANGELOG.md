# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
