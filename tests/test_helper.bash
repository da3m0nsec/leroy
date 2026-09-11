#!/usr/bin/env bash

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LEROY_BIN="$PROJECT_ROOT/leroy.sh"

export MORPHEUS_URL="https://morpheus.test"
export MORPHEUS_API_TOKEN="test-token-not-a-secret"
export MORPHEUS_VERIFY_TLS="false"
