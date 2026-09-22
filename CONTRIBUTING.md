# Contributing to Leroy

Thank you for helping improve Leroy. Contributions should keep the tool safe for interactive operators and predictable for automation consumers.

## Before you begin

- Search existing issues and pull requests before starting substantial work.
- Open an issue for large features, new dependencies, or changes to CLI behavior so the design can be agreed before implementation.
- Never include real Morpheus URLs, tokens, passwords, customer data, or unredacted API responses in commits, tests, issues, or logs.
- Keep Bash compatibility at version 4.4 or newer unless a documented design decision changes the baseline.

## Development setup

Fork and clone the repository, then run:

```bash
bash ./scripts/setup.sh
make check
```

The setup script validates required tools and creates a user-local configuration directory when appropriate. It does not install system packages or request credentials.

Recommended development tools are `shellcheck` for static analysis, `shfmt` for formatting, and `bats-core` for automated tests.

## Branches and commits

Create a focused branch from the default branch. Prefer short, imperative commit subjects, for example `Add environment detail command`. Keep unrelated formatting or refactoring out of functional changes.

## Code conventions

- Start executable scripts with `#!/usr/bin/env bash` and use `set -Eeuo pipefail` where appropriate.
- Quote parameter expansions unless intentional word splitting is documented.
- Prefer `[[ ... ]]` for conditions and `printf` over `echo` for portable output.
- Declare function-scoped variables with `local`.
- Prefix functions by responsibility, such as `api_request` or `environments_list`.
- Keep API, command, and presentation functions in clearly labelled sections of `leroy.sh`.
- Send machine-readable command results to standard output and diagnostics to standard error.
- An error message names what failed, the value or request that failed, and what the operator can do next. `die "$EXIT_CONFLICT" 'conflict'` tells nobody anything; naming the resource, the appliance and the remedy does.
- Never log authorization headers, token values, or request bodies known to contain secrets.
- Avoid parsing JSON with regular expressions; use `jq`.

Run `make format` before submitting changes. Formatting should use the repository’s `.editorconfig` and `shfmt` settings.

## Testing

Every behavior change should include or update a Bats test. Tests must not require a live Morpheus appliance. Mock `curl` responses and cover successful requests, error paths, malformed responses, configuration precedence, and safe handling of secrets and destructive-operation confirmation.

The graphical builder in `web/` restates the manifest rules in JavaScript, because a static page cannot run bash. When you change `validate_manifest`, the feature-dependency rules or the resource expansion in `leroy.sh`, change `web/assets/schema.js` with them. `make check` runs every builder scenario through `validate_manifest` and compares both implementations' resource counts, so a divergence fails CI rather than reaching an operator.

No test reaches a Morpheus appliance, so a passing suite does not prove that Morpheus accepts a request. When a change adds or alters an API interaction, add an entry to `docs/APPLIANCE_VALIDATION.md` describing what an operator with appliance access must check and what the expected result is.

Live integration tests, when added, will be opt-in and must target a dedicated non-production tenant. Before opening a pull request, run:

```bash
make check
```

## Documentation and compatibility

Update the README, API reference, and appliance-validation checklist whenever user-facing commands, configuration, dependencies, or supported endpoints change. Record notable changes under `Unreleased` in `CHANGELOG.md`.

CLI flags, JSON fields, exit codes, and standard-output behavior form an automation contract. Backward-incompatible changes require explicit discussion and, after the project reaches `1.0.0`, a major version change.

## Pull requests

A pull request should include a concise problem statement and solution summary, tests appropriate to the risk, documentation and changelog updates when applicable, security implications, and sanitized sample terminal output for user-visible changes.

## Reporting security issues

Do not disclose a suspected vulnerability in a public issue. Contact the maintainers privately through the repository’s security reporting channel. Include reproduction steps without live credentials or customer information.
