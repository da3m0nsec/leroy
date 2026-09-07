# Architecture

## Purpose

Leroy is a Bash application that presents one Morpheus management capability through two adapters: an interactive terminal interface and a script-friendly command-line interface. Both adapters invoke the same command functions, validation rules, configuration loader, and HTTP client so their behavior does not drift.

The demo lifecycle builds a dependency-ordered set of Morpheus 9 resources. Plan is read-only, apply records each successful mutation atomically, and destroy verifies local state plus remote ownership before deleting in reverse dependency order.

## Design principles

1. **One behavior, two interfaces.** TUI actions call command functions rather than duplicating API requests.
2. **Safe automation.** CLI output, exit codes, non-interactive behavior, and confirmation rules must be deterministic.
3. **Secure defaults.** TLS verification is enabled, credentials are not passed in arguments, and authorization data is never logged.
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
| `.github/workflows/` | Automated syntax, lint, and test checks. |

## Configuration and precedence

Configuration values are resolved in this order, from lowest to highest priority:

1. built-in non-secret defaults;
2. `${XDG_CONFIG_HOME:-$HOME/.config}/leroy/config`;
3. the file selected by `--config`; and
4. exported `MORPHEUS_*` environment variables.

The bootstrap implementation sources configuration as shell assignments. A configuration file must therefore be owned and controlled by the operator and must never be sourced from an untrusted location. A future release may replace this format with a non-executable parser.

Access tokens are read from `MORPHEUS_API_TOKEN`. They are deliberately excluded from positional arguments, URLs, debug messages, and process titles. TLS certificate validation is on unless `MORPHEUS_VERIFY_TLS=false` is explicitly configured.

## API interaction

All requests pass through `api_request`. The transport layer joins the appliance URL with an `/api/...` path, adds bearer authentication and JSON headers, applies timeouts, separates response bodies from status codes, maps failures to application exit codes, and validates successful JSON responses.

Resource functions understand Morpheus response shapes and select user-facing fields. Only `api_request` builds `curl` commands. Pagination will be implemented once and shared by TUI and CLI consumers.

Morpheus versions may differ in endpoint availability and payload shape. Version-specific behavior will be capability-driven where possible and documented in `API_REFERENCE.md`; it must not silently discard fields or retry a mutation.

## TUI mode

Running `leroy` or `leroy tui` starts a dependency-free, full-screen terminal adapter. It uses ANSI terminal capabilities and Bash character input instead of `dialog`, `whiptail`, or an ncurses binding, preserving the single-file distribution and the Bash, `curl`, and `jq` runtime baseline.

The dashboard groups actions by operator intent: inspect, build, validate, lifecycle, and configure. It supports arrow keys, `j`/`k`, direct shortcuts, and `Enter`; the alternate screen and cursor are always restored through the process cleanup trap. Rendering is width-aware, respects `NO_COLOR`, and keeps action output on a dedicated result view until the operator dismisses it.

The TUI owns navigation, selection, human-readable tables, prompts, status summaries, and confirmation. It delegates all actual work to command functions. Mutating workflows follow a consistent sequence:

```text
Select resource -> edit values -> validate -> show diff/preview -> confirm -> submit -> report result
```

The TUI detects a non-interactive terminal and fails clearly rather than waiting for unavailable input.

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

Fast tests mock `curl` and validate configuration, dispatch, request construction, response parsing, exit codes, and secret redaction. Contract fixtures will represent supported Morpheus response versions. Optional integration tests will run against an isolated test tenant and will never be part of the default test command.

CI performs Bash syntax checks, ShellCheck analysis, and Bats tests. Mutating API tests must use fixtures until an explicitly configured integration environment exists.

## Extension path

New resources should be introduced by adding a command function, CLI route, TUI action, fixture set, tests, and API-reference entry. Cross-cutting behavior belongs in an existing shared layer rather than a new resource-specific transport implementation.
