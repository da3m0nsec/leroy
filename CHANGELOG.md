# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Full-screen, dependency-free TUI dashboard with arrow-key navigation, direct shortcuts, action result views, lifecycle state, and connection status.
- Protected in-TUI destruction and recreation confirmations.
- Checkbox-based TUI selector for multitenancy, roles and users, environments, groups, policies, automation, and service catalog.
- `demo list` and `demo state` report saved deployments and their recorded Morpheus IDs from local state, without appliance credentials.
- TUI manifest-source screen, deployment inventory screen, and hand-off from the wizard to the active manifest.
- TUI scrolling for action output longer than the terminal, and a startup connection probe that reports the authenticated identity and appliance build.
- Component drift indicator for a selection that differs from the saved deployment.
- Shared collection helper that follows Morpheus `max`/`offset` pagination.
- `docs/APPLIANCE_VALIDATION.md`, listing every behavior that stays unverified until it runs against a Morpheus appliance.

### Changed

- Missing URL and token values are requested interactively instead of immediately failing.
- TLS certificate verification now defaults to disabled.
- Role feature access uses the valid access type advertised by the Morpheus base role.
- Interactive operations now return to the dashboard after both successful and failed actions.
- Plans, applies, deep verification, and custom manifests now honor the selected deployment components.
- Deployments without multitenancy place selected content in the Master Tenant.
- Verification reports one row per check in table and JSON output instead of only a failure count.
- Environment lists, role discovery, policy-type resolution, and name lookups read every page instead of the first 100 records.

### Fixed

- Exact Cypher key discovery no longer produces false conflicts from partial search matches.
- Existing Leroy-owned generated-password keys are adopted during resumable plans and applies.
- The TUI describes and acts on the manifest it has loaded rather than assuming the built-in preset and the demo ID `leroy-demo`.
- Resource totals are derived from the manifest, so a customized manifest is no longer reported with preset counts.
- Destruction and recreation confirm with the organization name recorded in state, and are offered only when that state exists.
- Unmapped terminal escape sequences no longer quit the dashboard or leak their trailing characters into the next keystroke.

### Security

- Demo identifiers are validated before they are joined into a state path, so `--demo-id` cannot select or remove a file outside the state directory.
- `demo list` and `demo state` expose resource identifiers only; generated passwords remain in Cypher and are never written to state.

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
