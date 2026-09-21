# Architecture

## Purpose

Leroy is a Bash application that presents one Morpheus management capability through two adapters: an interactive terminal interface and a script-friendly command-line interface. Both adapters invoke the same command functions, validation rules, configuration loader, and HTTP client so their behavior does not drift.

The demo lifecycle builds a dependency-ordered, operator-selected set of Morpheus 9 resources. Plan is read-only, apply records each successful mutation atomically, and destroy verifies local state plus remote ownership before deleting in reverse dependency order.

## Design principles

1. **One behavior, two interfaces.** TUI actions call command functions rather than duplicating API requests.
2. **Safe automation.** CLI output, exit codes, non-interactive behavior, and confirmation rules must be deterministic.
3. **Explicit security posture.** Credentials are not passed in arguments or logs. TLS verification is disabled for internal demo appliances by default, emits a warning, and can be enabled explicitly.
4. **Replaceable presentation.** TUI rendering is isolated from transport and business logic so a richer terminal framework can be adopted later.
5. **Single-file delivery.** All runtime code lives in `leroy.sh`; clearly separated functions keep responsibilities understandable.
6. **Testable transport.** API calls are centralized so `curl` can be mocked and response handling can be exercised without a live appliance.

## Runtime flow

```text
User or automation
       |
       v
 leroy.sh (configuration and mode selection)
       |
       +-------------------+
       |                   |
       v                   v
 TUI functions       CLI dispatch
       |                   |
       +---------+---------+
                 |
                 v
      API request functions
     (HTTP, auth, errors)
                 |
                 v
       Morpheus REST API
```

Within `leroy.sh`, configuration functions run before either adapter, shared helpers provide diagnostics and exit codes, and every Morpheus call passes through `api_request`.

## Repository organization

| Path | Responsibility |
| --- | --- |
| `leroy.sh` | Complete runtime: helpers, configuration, API transport, commands, TUI, and dispatch. |
| `config/` | Sanitized configuration examples and future schema/default data. |
| `tests/` | Bats unit and contract tests with mocked external commands. |
| `docs/` | Focused operator and developer guides beyond top-level project documents. |
| `web/` | Static graphical manifest builder published to GitHub Pages. |
| `.github/workflows/` | Automated syntax, lint, and test checks, and the Pages deployment. |

## Configuration and precedence

Configuration values are resolved in this order, from lowest to highest priority:

1. built-in non-secret defaults;
2. `${XDG_CONFIG_HOME:-$HOME/.config}/leroy/config`;
3. the file selected by `--config`; and
4. exported `MORPHEUS_*` environment variables.

The bootstrap implementation sources configuration as shell assignments. A configuration file must therefore be owned and controlled by the operator and must never be sourced from an untrusted location. A future release may replace this format with a non-executable parser.

Access tokens are read from `MORPHEUS_API_TOKEN`. They are deliberately excluded from positional arguments, URLs, debug messages, and process titles. TLS certificate validation defaults to off for demonstration appliances with internal certificates. Set `MORPHEUS_VERIFY_TLS=true` whenever the appliance certificate is trusted.

## API interaction

All requests pass through `api_request`. The transport layer joins the appliance URL with an `/api/...` path, adds bearer authentication and JSON headers, applies timeouts, separates response bodies from status codes, maps failures to application exit codes, and validates successful JSON responses.

Resource functions understand Morpheus response shapes and select user-facing fields. Only `api_request` builds `curl` commands. Collection reads go through `api_collection`, which follows Morpheus `max`/`offset` pagination until a short page, detects the collection key from the first page when the caller does not name it, and returns one merged document. List commands, base-role discovery, policy-type resolution, and name lookups all use it, so no consumer is limited to the first page.

Morpheus versions may differ in endpoint availability and payload shape. Version-specific behavior will be capability-driven where possible and documented in `API_REFERENCE.md`; it must not silently discard fields or retry a mutation.

## TUI mode

Running `leroy` or `leroy tui` starts a dependency-free, full-screen terminal adapter. It uses ANSI terminal capabilities and Bash character input instead of `dialog`, `whiptail`, or an ncurses binding, preserving the single-file distribution and the Bash, `curl`, and `jq` runtime baseline.

The dashboard groups actions by operator intent: inspect, build, validate, lifecycle, and configure. Its component selector models seven feature bundles as checkboxes, defaults all of them on, and enforces dependency rules while toggling. It supports arrow keys, `j`/`k`, direct shortcuts, and `Enter`; the alternate screen and cursor are always restored through the process cleanup trap. Rendering is width-aware, respects `NO_COLOR`, and keeps action output on a dedicated result view until the operator dismisses it.

The dashboard derives every row it shows from one source of truth: the manifest currently selected in the TUI. `tui_sync_manifest` rebuilds the effective manifest from the selected source plus the selected components, then republishes the demo ID, organization name, state file, and expected resource count that the rows and the lifecycle actions use. Resource totals come from expanding the manifest, not from per-bundle constants, so a customized manifest is described by its own contents. Actions that need saved state are offered only when that state exists, and destruction confirms with the organization name recorded in it.

Interactive screens that read input, the wizard and the manifest and component selectors, run outside the captured action runner. The runner copies action output through a FIFO rather than a pipeline, because a pipeline runs the action in a subshell and discards the session state it updates; the wizard additionally requires a terminal on standard output.

The manifest source is one of three kinds: the built-in preset, a manifest file, or a deployment recorded in the state directory. A saved deployment is used by extracting the manifest its state file embeds, so every source reduces to a manifest file and the rest of the TUI needs no special case. Building previews the plan and requires confirmation before it mutates anything, and a destroy that stops on an ownership mismatch offers a gated retry with force; that offer is made only when the failure names `--force` as the remedy, so failures force cannot resolve are not offered one.

The TUI owns navigation, selection, human-readable tables, prompts, status summaries, and confirmation. It delegates all actual work to command functions. Mutating workflows follow a consistent sequence:

```text
Select resource -> edit values -> validate -> show diff/preview -> confirm -> submit -> report result
```

The TUI detects a non-interactive terminal and fails clearly rather than waiting for unavailable input.

## Manifest schema versions

Schema 1 fixes the persona set: three personas with known keys and profiles,
whose Morpheus permission rules and verification paths live in `leroy.sh`.
Schema 2 moves that description into the manifest, so a manifest can define any
number of personas and state, per persona, its permission rules, the access it
must have, the access it must not have, whether it receives catalog access, and
which persona executes the demonstration workflow.

`validate_manifest` dispatches on `schemaVersion` and shares the identity and
feature-dependency rules between the two validators. Every schema 2 lookup
(`tenant_admin_key`, `catalog_persona_keys`, `workflow_persona`,
`persona_permissions`) reduces to the schema 1 arrangement when the manifest
states no preference, so one code path serves both versions and existing
manifests and saved deployments are unaffected.

A tenant administrator remains mandatory whenever persona roles are deployed,
because the tenant token is obtained by logging in as that persona.

## Graphical manifest builder

`web/` holds a static, dependency-free builder that produces schema 2
manifests, published to GitHub Pages. It shares no runtime with `leroy.sh`:
the page cannot execute bash, so `web/assets/schema.js` restates the manifest
rules in JavaScript. That duplication is deliberate and guarded rather than
avoided. `web/tools/emit-manifests.mjs` runs the same modules the page loads
outside the browser, and the test suite feeds every scenario through
`validate_manifest` and compares both implementations' resource counts, so a
rule that changes on one side and not the other fails CI.

The canvas models resource groups as nodes wired by the dependencies Leroy
applies, and node toggles map onto the same feature flags and dependency rules
as the TUI component selector.

## Component selection and scope

The manifest stores normalized feature flags for `multitenancy`, `roles`, `environments`, `groups`, `policies`, `automation`, and `catalog`. Missing flags default to `true` for compatibility with earlier manifests. Validation enforces these relationships:

- multitenancy and persona roles/users are selected together;
- policies require groups; and
- service catalog requires automation.

The feature filter runs before planning, so unselected resources never enter the desired-resource stream. When multitenancy is selected, tenant content uses a temporary tenant-admin token. When it is not selected, environments, groups, policies, automation, and catalog content use the Master Tenant token and payloads omit tenant-account references. The selected feature set is stored in lifecycle state; a later mismatch fails with exit code 8 and requires an explicit recreate.

## Local state inspection

`demo list` and `demo state` read the state directory only. They run after configuration is loaded, so `--config` selects the right state directory, but before credentials are required, because inspecting what Leroy recorded must not depend on a valid token. State holds resource identifiers, the manifest, and the appliance it belongs to; generated passwords stay in Cypher.

## CLI mode

Providing a resource command selects CLI mode. CLI commands have no implicit prompts, offer JSON output with `--output json`, reserve standard output for results, and use documented exit codes. `demo plan` is read-only; `destroy` and `recreate` require explicit confirmation plus verified ownership.

## Error and exit-code contract

| Code | Meaning |
| ---: | --- |
| `0` | Success |
| `2` | Invalid command, arguments, or configuration |
| `3` | Missing runtime dependency |
| `4` | Authentication or authorization failure |
| `5` | Network, TLS, timeout, or API server failure |
| `6` | Resource not found |
| `7` | Invalid or unsupported API response |
| `8` | Ownership conflict or configuration drift |
| `9` | Structural or deep verification failure |
| `10` | Partial apply retained for a safe subsequent resume |

Additional codes require documentation and tests before use.

## Testing strategy

Fast tests mock `curl` and validate configuration, dispatch, request construction, response parsing, exit codes, secret redaction, manifest expansion, pagination, verification reporting, and terminal rendering. Contract fixtures will represent supported Morpheus response versions. Optional integration tests will run against an isolated test tenant and will never be part of the default test command.

No automated test reaches a Morpheus appliance, so payload acceptance, endpoint availability, and demonstration behavior remain unproven until an operator runs the checklist in `docs/APPLIANCE_VALIDATION.md`. Every change that adds or alters an API interaction adds an entry there.

CI performs Bash syntax checks, ShellCheck analysis, and Bats tests. Mutating API tests must use fixtures until an explicitly configured integration environment exists.

## Extension path

New resources should be introduced by adding a command function, CLI route, TUI action, fixture set, tests, API-reference entry, and appliance-validation entry. Cross-cutting behavior belongs in an existing shared layer rather than a new resource-specific transport implementation.
