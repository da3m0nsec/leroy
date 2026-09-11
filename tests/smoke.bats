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


@test "TLS verification defaults to false" {
  run env -u MORPHEUS_VERIFY_TLS bash -c 'source "$1"; printf "%s\n" "$MORPHEUS_VERIFY_TLS"' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "runtime configuration prompt captures missing URL and token" {
  run env -u MORPHEUS_URL -u MORPHEUS_API_TOKEN bash -c '
    source "$1"
    MORPHEUS_URL=""
    MORPHEUS_API_TOKEN=""
    prompt_runtime_config <<< $'"'"'https://morpheus.example.test/\ntest-session-token\n'"'"'
    printf "%s|%s|%s\n" "$MORPHEUS_URL" "$MORPHEUS_API_TOKEN" "$MASTER_TOKEN"
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://morpheus.example.test|test-session-token|test-session-token"* ]]
}

@test "Cypher lookup uses exact key filtering" {
  run bash -c '
    source "$1"
    api_request() {
      [[ "$2" == "/api/cypher?list=true&key=password%2F24%2Fleroy-demo%2Fleroy-admin" ]] || return 99
      printf "%s\n" '"'"'{"cyphers":[{"key":"password/24/leroy-demo/leroy-admin"}]}'"'"'
    }
    cypher_find "password/24/leroy-demo/leroy-admin"
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  jq -e '.key == "password/24/leroy-demo/leroy-admin"' <<<"$output"
}

@test "plan adopts an existing Cypher key in the demo namespace" {
  run bash -c '
    source "$1"
    CURRENT_DEMO_ID=leroy-demo
    state_resource() { return 0; }
    find_remote() { printf "%s\n" '"'"'{"key":"password/24/leroy-demo/leroy-admin"}'"'"'; }
    desired_action '"'"'{"key":"cypher:admin","type":"cypher","scope":"master","name":"leroy-admin","spec":{"path":"password/24/leroy-demo/leroy-admin"}}'"'"'
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  [ "$output" = "adopt" ]
}

@test "role permissions reuse access types accepted by Morpheus" {
  local captured="$BATS_TEST_TMPDIR/role-payloads.jsonl"
  run bash -c '
    source "$1"; BASE_USER_ROLE_ID=1; MASTER_TOKEN=test; captured="$2"
    api_request() {
      if [[ "$1" == GET ]]; then
        printf "%s\n" '"'"'{"permissions":[{"code":"provisioning-instances","name":"Provisioning: Instances","access":"full"},{"code":"infrastructure-groups","name":"Infrastructure: Groups","access":"yes"}]}'"'"'
      else printf "%s\n" "$3" >>"$captured"; printf "%s\n" '"'"'{"success":true}'"'"'; fi
    }
    configure_role_permissions platform-operator 42
  ' _ "$LEROY_BIN" "$captured"
  [ "$status" -eq 0 ]
  jq -se 'length == 2 and any(.[]; .permissionCode == "provisioning-instances" and .access == "full") and any(.[]; .permissionCode == "infrastructure-groups" and .access == "yes")' "$captured"
}


@test "preset enables every deployment component" {
  run bash "$LEROY_BIN" demo preset
  [ "$status" -eq 0 ]
  jq -e '.features == {multitenancy:true,roles:true,environments:true,groups:true,policies:true,automation:true,catalog:true}' <<<"$output"
}

@test "master-only selection excludes multitenancy and persona resources" {
  run bash -c '
    source "$1"
    TUI_FEATURES_JSON='"'"'{"multitenancy":false,"roles":false,"environments":true,"groups":true,"policies":true,"automation":true,"catalog":true}'"'"'
    manifest_to_temp
    resource_stream
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  jq -se '
    length == 13 and
    all(.[]; .scope == "master") and
    all(.[]; (.type == "tenant" or .type == "role" or .type == "user" or .type == "cypher") | not)
  ' <<<"$output"
}

@test "manifest validation rejects invalid component dependencies" {
  local bad_manifest="$BATS_TEST_TMPDIR/dependencies.json"
  bash "$LEROY_BIN" demo preset | jq '.features.multitenancy=false' >"$bad_manifest"
  run bash -c 'source "$1"; validate_manifest "$2"' _ "$LEROY_BIN" "$bad_manifest"
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest is invalid"* ]]
}

@test "component toggles enforce dependent selections" {
  run bash -c '
    source "$1"
    TUI_FEATURES_JSON="$(feature_defaults)"; TUI_COMPONENT_NOTICE=""
    tui_toggle_component multitenancy
    jq -e ".multitenancy == false and .roles == false" <<<"$TUI_FEATURES_JSON"
    TUI_FEATURES_JSON="$(feature_defaults)"
    tui_toggle_component groups
    jq -e ".groups == false and .policies == false" <<<"$TUI_FEATURES_JSON"
    TUI_FEATURES_JSON="$(feature_defaults)"
    tui_toggle_component automation
    jq -e ".automation == false and .catalog == false" <<<"$TUI_FEATURES_JSON"
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
}

@test "changing component selection on existing state requires recreate" {
  run bash -c '
    source "$1"
    LEROY_STATE_DIR="$2/state"; MORPHEUS_URL=https://morpheus.example.test; APPLIANCE_BUILD=9.0.0
    manifest_to_temp; state_init
    TUI_FEATURES_JSON='"'"'{"multitenancy":false,"roles":false,"environments":true,"groups":true,"policies":true,"automation":true,"catalog":true}'"'"'
    manifest_to_temp
    state_assert_features
  ' _ "$LEROY_BIN" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 8 ]
  [[ "$output" == *"use recreate"* ]]
}

@test "master-scoped policy payload omits a tenant account" {
  local state="$BATS_TEST_TMPDIR/state.json"
  printf '%s\n' '{"resources":[]}' >"$state"
  run bash -c '
    source "$1"; STATE_FILE="$2"; CURRENT_MARKER="Managed by Leroy demo:leroy-demo"
    resource_id() { return 0; }
    resolve_policy_type() { printf "%s\n" '"'"'{"id":7,"code":"motd","name":"Message of the Day"}'"'"'; }
    build_payload '"'"'{"type":"policy","spec":{"name":"Leroy Demo Message","code":"leroy-demo-message","type":"motd","scope":"tenant","config":{"message":"Hello"}}}'"'"'
  ' _ "$LEROY_BIN" "$state"
  [ "$status" -eq 0 ]
  jq -e '.policy.account == null and .policy.policyType.id == 7' <<<"$output"
}
