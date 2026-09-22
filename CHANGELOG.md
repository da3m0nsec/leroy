# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Full-screen, dependency-free TUI dashboard with arrow-key navigation, direct shortcuts, action result views, lifecycle state, and connection status.
- Protected in-TUI destruction and recreation confirmations.
- Checkbox-based TUI selector for multitenancy, roles and users, environments, groups, policies, automation, and service catalog.
- `demo list` and `demo state` report saved deployments and their recorded Morpheus IDs from local state, without appliance credentials.
- TUI manifest-source screen listing the built-in preset, every deployment recorded in the state directory, and a manifest file of your choosing, plus a deployment inventory screen and hand-off from the wizard to the active manifest.
- TUI build preview: the plan runs first, reports how many resources it would create, update, and adopt, and asks for confirmation before anything is sent to Morpheus.
- TUI retry with force when destruction or recreation stops on an ownership mismatch, gated on typing `force` and offered only for failures that forcing can resolve.
- TUI scrolling for action output longer than the terminal, and a startup connection probe that reports the authenticated identity and appliance build.
- Component drift indicator for a selection that differs from the saved deployment.
- Shared collection helper that follows Morpheus `max`/`offset` pagination.
- `docs/APPLIANCE_VALIDATION.md`, listing every behavior that stays unverified until it runs against a Morpheus appliance.
- Manifest schema version 2: personas are no longer fixed at three, and each one carries its own Morpheus permission rules, the access it must and must not have, whether it receives catalog access, and whether it runs the demonstration workflow. `leroy.sh` reads schema 1 and 2, and `demo preset --schema 2` emits the built-in demo in the new form.
- Landing page in front of the builder explaining the tool, how it works, the seven blocks it deploys and the security model, with copyable `curl` and `wget` commands that install the CLI. The builder opens from it and is deep-linkable at `#constructor`.
- Graphical manifest builder under `web/`, deployed to GitHub Pages: a canvas of draggable boxes wired by the dependencies Leroy applies, with demo scenarios for platform, banking, retail, telco and public sector, persona and permission editing, live validation against the same rules as `leroy.sh`, and manifest import and export.
- `make web` serves the builder locally and `make web-manifests` prints each scenario's manifest.
- TUI action to configure the appliance URL and token without leaving the dashboard, for a wrong token or a second appliance. The token is read hidden and never displayed back, and the values apply to the session only.
- A project-local `.env` is read on start, with no sourcing or exporting. It is parsed rather than sourced: only Leroy's own settings are read, `export` prefixes, quotes and CRLF endings are tolerated, and a value is never evaluated. `LEROY_ENV_FILE` points it elsewhere or, when empty, skips it.

### Changed

- TUI actions are grouped by what an operator is doing rather than by internal category: connection, plan, build, lifecycle and manifest, with verification folded into lifecycle.
- Missing URL and token values are requested interactively instead of immediately failing.
- TLS certificate verification now defaults to disabled.
- Role feature access uses the valid access type advertised by the Morpheus base role.
- Interactive operations now return to the dashboard after both successful and failed actions.
- Plans, applies, deep verification, and custom manifests now honor the selected deployment components.
- Deployments without multitenancy place selected content in the Master Tenant.
- Verification reports one row per check in table and JSON output instead of only a failure count.
- The wizard prints a summary of the manifest it generated instead of the whole document, which scrolled its own save prompt off the screen.
- The component selector computes its checkboxes in one pass and only rebuilds the manifest after a change, roughly halving redraw cost.
- Environment lists, role discovery, policy-type resolution, and name lookups read every page instead of the first 100 records, and normalize a collection wrapped under an unexpected key.

### Fixed

- Exact Cypher key discovery no longer produces false conflicts from partial search matches.
- Existing Leroy-owned generated-password keys are adopted during resumable plans and applies.
- The TUI describes and acts on the manifest it has loaded rather than assuming the built-in preset and the demo ID `leroy-demo`.
- Resource totals are derived from the manifest, so a customized manifest is no longer reported with preset counts.
- Destruction and recreation confirm with the organization name recorded in state, and are offered only when that state exists.
- Unmapped terminal escape sequences no longer quit the dashboard or leak their trailing characters into the next keystroke.
- Two uses of jq's alternative operator treated a stored `false` as absent: a persona excluded from catalog access was granted it anyway, and a workflow execution returning `success: false` passed deep verification instead of failing it.
- The Leroy-identity check that guards `--force` evaluates its name test as written; it was piped through `tostring`, which hid every value from it, and it now takes the prefix from the manifest instead of assuming `leroy-`. Resources matching that prefix already counted as owned, so no resource becomes deletable that was not before unless the manifest sets no prefix.

### Security

- The builder runs entirely in the browser: no server, no analytics, and no Morpheus calls. Manifests it produces carry no credentials, since Leroy generates demo passwords with Cypher at apply time.
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
