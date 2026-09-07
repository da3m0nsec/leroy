#!/usr/bin/env bats

load test_helper

@test "version reports project version" {
  run bash "$LEROY_BIN" --version
  [ "$status" -eq 0 ]
  [ "$output" = "leroy 0.2.0" ]
}

@test "help documents both operating modes" {
  run bash "$LEROY_BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo plan|apply|verify"* ]]
  [[ "$output" == *"environments {list|get ID}"* ]]
}

@test "preset is a valid secret-free version 1 manifest" {
  run bash "$LEROY_BIN" demo preset
  [ "$status" -eq 0 ]
  jq -e '.schemaVersion == 1 and (.personas | length == 3)' <<<"$output"
  ! jq -e '[.. | objects | keys[]] | any(. == "password" or . == "token")' <<<"$output" >/dev/null
}

@test "preset contains the autonomous automation chain" {
  run bash "$LEROY_BIN" demo preset
  [ "$status" -eq 0 ]
  jq -e '
    .automation.inputs[0].fieldName == "demoMessage" and
    .automation.tasks[0].type == "groovy" and
    .automation.workflows[0].type == "operation" and
    .automation.catalogItems[0].context == "none"
  ' <<<"$output"
}

@test "invalid environment ID fails validation before an API call" {
  run bash "$LEROY_BIN" environments get not-an-id
  [ "$status" -eq 2 ]
  [[ "$output" == *"environment ID must be a positive integer"* ]]
}

@test "manifest validation rejects embedded secrets" {
  local bad_manifest="$BATS_TEST_TMPDIR/bad.json"
  bash "$LEROY_BIN" demo preset | jq '.password="not-allowed"' >"$bad_manifest"
  run bash -c 'source "$1"; validate_manifest "$2"' _ "$LEROY_BIN" "$bad_manifest"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must not contain passwords or tokens"* ]]
}

@test "default plan expands all 24 dependency-ordered resources" {
  run bash -c '
    source "$1"
    LEROY_STATE_DIR="$2/state"
    manifest_to_temp
    STATE_FILE="$LEROY_STATE_DIR/leroy-demo.json"
    preflight() { APPLIANCE_BUILD=9.0.0; }
    find_remote() { return 0; }
    LEROY_OUTPUT=json
    demo_plan
  ' _ "$LEROY_BIN" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  jq -e '(.changes | length) == 24 and all(.changes[]; .action == "create")' <<<"$output"
}

@test "preflight rejects a non-Morpheus-9 appliance" {
  run bash -c '
    source "$1"
    MASTER_TOKEN=test
    api_request() { printf "%s\n" "{\"isMasterAccount\":true,\"appliance\":{\"buildVersion\":\"8.0.1\"}}"; }
    preflight
  ' _ "$LEROY_BIN"
  [ "$status" -eq 9 ]
  [[ "$output" == *"major version 9 is required"* ]]
}

@test "ownership check rejects resources without a Leroy identity" {
  run bash -c 'source "$1"; remote_has_leroy_identity "{\"id\":42,\"name\":\"production\"}"' _ "$LEROY_BIN"
  [ "$status" -ne 0 ]
}

@test "TUI key reader supports direct shortcuts and arrow navigation" {
  run bash -c 'source "$1"; printf q | tui_read_key; printf "\033[A" | tui_read_key' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "q" ]
  [ "${lines[1]}" = "up" ]
}

@test "TUI text cropping is safe at narrow widths" {
  run bash -c 'source "$1"; tui_crop "Morpheus demonstration" 10; printf "\n"; tui_crop "ok" 10' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Morpheu..." ]
  [ "${lines[1]}" = "ok" ]
}
