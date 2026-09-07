# Development Guide

## Local workflow

Run `bash ./scripts/setup.sh` to check the local toolchain, then use `make check` before each pull request. The test suite is designed to run without network access or Morpheus credentials.

## Single-file organization

All runtime logic lives in `leroy.sh`. Keep helpers, configuration, API transport, resource commands, TUI functions, and argument dispatch in distinct sections so the file remains navigable.

## Adding a command

1. Add or extend a resource function in `leroy.sh`.
2. Register its CLI route and help text in the same file.
3. Add a TUI action when interactive use is meaningful.
4. Mock the transport and add Bats coverage.
5. Update the README, API reference, and changelog.

Every demo resource follows the same lifecycle contract: build a validated payload, record its returned ID and logical specification, verify ownership before mutation, and provide reverse-order deletion. Credentials never belong in manifests, state, or test fixtures.

Keep all HTTP mechanics inside `api_request`; command functions should receive validated values and interpret resource-specific JSON.

## Testing without Morpheus

Put mock executables at the front of `PATH` when running the Bats suite. Fixtures must be synthetic or thoroughly sanitized. Never record a live `Authorization` header.
