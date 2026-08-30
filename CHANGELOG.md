# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-21

### Added
- **Markdown-based template management**: Prompts are now managed as individual `.md` files under `templates/` (supporting subdirectories for categories and Unicode filenames).
- **Automatic legacy migration**: Existing single-file `templates.txt` is automatically converted into clean `.md` files under `templates/` and backed up to `templates.txt.bak`.
- **Interactive template creation/editing**: `⚙️ Edit Templates` now offers fuzzy selection of existing files or creation of new templates.
- **Dedicated custom variable definitions**: Candidate generators can be specified in `templates/_vars.txt` or within any template markdown file.

### Removed
- **Immediate execution (`!`)**: Removed automatic Enter submission for templates prefixed with `!`. All templates now safely inject text directly into the active pane buffer without auto-submitting.

### Fixed
- **Local scope syntax error**: Fixed `local count=1` invoked in main loop during new template creation.
- **Escape sequence preservation**: Removed post-resolution `echo -e` evaluations to strictly preserve raw backslashes (`\c`, `\n`, `\t`, Windows paths) within injected content.
- **History pipe parsing**: Adopted tab delimiter separation for history entries to prevent corruption when prompts contain pipeline `|` characters.
- **Preview quoting safety**: Passed `{q}` safely to preview command and consumed context JSON directly via environment variables to eliminate shell quote parsing crashes.
- **Pipeline & redirection retention in `{{last_command}}`**: Refined prompt prefix stripping to avoid truncating pipeline commands (`|`) or redirections (`>`).
- **Exact tmux pane matching**: Replaced partial grep filtering with exact pane ID matching in `mux_list_panes` to prevent accidental exclusion of panes `%10`, `%11`, etc.
- **Slug traversal safeguard**: Added validation in `slugify` to sanitize dot-only inputs (`.`, `..`).

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
