#!/usr/bin/env bash

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LEROY_BIN="$PROJECT_ROOT/leroy.sh"

export MORPHEUS_URL="https://morpheus.test"
export MORPHEUS_API_TOKEN="test-token-not-a-secret"
export MORPHEUS_VERIFY_TLS="false"

# Leroy reads a .env from the working directory. Tests must not pick up
# whichever one a developer happens to have, so the file is disabled by default
# and the tests that exercise it name it explicitly.
export LEROY_ENV_FILE=
