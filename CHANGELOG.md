# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Full-screen, dependency-free TUI dashboard with arrow-key navigation, direct shortcuts, action result views, lifecycle state, and connection status.
- Protected in-TUI destruction and recreation confirmations.
- Checkbox-based TUI selector for multitenancy, roles and users, environments, groups, policies, automation, and service catalog.

### Changed

- Missing URL and token values are requested interactively instead of immediately failing.
- TLS certificate verification now defaults to disabled.
- Role feature access uses the valid access type advertised by the Morpheus base role.
- Interactive operations now return to the dashboard after both successful and failed actions.
- Plans, applies, deep verification, and custom manifests now honor the selected deployment components.
- Deployments without multitenancy place selected content in the Master Tenant.

### Fixed

- Exact Cypher key discovery no longer produces false conflicts from partial search matches.
- Existing Leroy-owned generated-password keys are adopted during resumable plans and applies.

### Security

## [0.2.0] - 2026-09-06

### Added

- Morpheus 9 demo lifecycle commands: preset, wizard, plan, apply, verify, destroy, and recreate.
- Versioned manifest, atomic local state, ownership verification, Cypher passwords, and deep RBAC checks.

## [0.1.0] - 2026-09-06

### Added

- Initial Bash TUI and CLI project structure.
- Single-file configuration, API transport, command, and terminal UI implementation.
- Project documentation, development automation, and test scaffolding.

[Unreleased]: https://github.com/da3m0nsec/leroy/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/da3m0nsec/leroy/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/da3m0nsec/leroy/releases/tag/v0.1.0
