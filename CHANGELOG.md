# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
