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

@test "resource counts follow the manifest instead of fixed totals" {
  local wide="$BATS_TEST_TMPDIR/wide.json"
  bash "$LEROY_BIN" demo preset |
    jq '.environments += [{name:"Leroy QA",code:"leroy-qa",description:"Managed by Leroy demo:leroy-demo",visibility:"private"}]' >"$wide"
  run bash -c 'source "$1"; resource_count <"$2"' _ "$LEROY_BIN" "$wide"
  [ "$status" -eq 0 ]
  [ "$output" = "25" ]
}

@test "collections follow Morpheus pagination instead of one page" {
  run bash -c '
    source "$1"
    MASTER_TOKEN=test
    api_request() {
      if [[ "$2" == *"offset=0"* ]]; then
        jq -nc "{environments:[range(100)|{id:.}],meta:{total:142}}"
      else
        jq -nc "{environments:[range(42)|{id:(.+100)}],meta:{total:142}}"
      fi
    }
    api_collection "/api/environments" environments
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  jq -e '(.environments | length) == 142 and .environments[141].id == 141' <<<"$output"
}

@test "demo list reports saved deployments without credentials" {
  local state_dir="$BATS_TEST_TMPDIR/state"
  run env -u MORPHEUS_URL -u MORPHEUS_API_TOKEN LEROY_STATE_DIR="$state_dir" bash -c '
    source "$1"
    MORPHEUS_URL=https://morpheus.test; APPLIANCE_BUILD=9.0.0
    manifest_to_temp; state_init
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  run env -u MORPHEUS_URL -u MORPHEUS_API_TOKEN LEROY_STATE_DIR="$state_dir" \
    bash "$LEROY_BIN" --output json demo list
  [ "$status" -eq 0 ]
  jq -e '(.demos | length) == 1 and .demos[0].demoId == "leroy-demo" and .demos[0].expectedResources == 24 and .demos[0].complete == false' <<<"$output"
}

@test "demo state lists recorded resources and reports a missing demo" {
  local state_dir="$BATS_TEST_TMPDIR/state"
  run env LEROY_STATE_DIR="$state_dir" bash -c '
    source "$1"
    MORPHEUS_URL=https://morpheus.test; APPLIANCE_BUILD=9.0.0
    manifest_to_temp; state_init
    state_record "$(jq -nc "{key:\"environment:leroy-dev\",type:\"environment\",scope:\"master\",name:\"Leroy Development\",id:\"5\",spec:{}}")"
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  run env LEROY_STATE_DIR="$state_dir" bash "$LEROY_BIN" demo state --demo-id leroy-demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 recorded of 24 expected"* ]]
  [[ "$output" == *"environment  5"* ]]
  run env LEROY_STATE_DIR="$state_dir" bash "$LEROY_BIN" demo state --demo-id absent-demo
  [ "$status" -eq 6 ]
}

@test "verification reports every check and fails on a missing resource" {
  run bash -c '
    source "$1"
    LEROY_STATE_DIR="$2/state"; MORPHEUS_URL=https://morpheus.test; APPLIANCE_BUILD=9.0.0
    manifest_to_temp; state_init
    state_record "$(jq -nc "{key:\"environment:leroy-dev\",type:\"environment\",scope:\"master\",name:\"Leroy Development\",id:\"5\",spec:{}}")"
    state_record "$(jq -nc "{key:\"group:leroy-production\",type:\"group\",scope:\"master\",name:\"Leroy Production\",id:\"7\",spec:{}}")"
    resource_get() {
      jq -e ".type == \"environment\"" <<<"$1" >/dev/null || return 1
      printf "%s\n" "{\"id\":5,\"description\":\"Managed by Leroy demo:leroy-demo\"}"
    }
    LEROY_OUTPUT=json demo_verify false 2>/dev/null
  ' _ "$LEROY_BIN" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 9 ]
  jq -e '
    .verified == false and .failed == 1 and .checked == 3 and
    (.checks | map(select(.check == "resource" and .status == "fail")) | length) == 1
  ' <<<"$output"
}

@test "TUI ignores unmapped escape sequences instead of quitting" {
  run bash -c '
    source "$1"
    printf "\033[15~" | tui_read_key
    printf "\033[5~" | tui_read_key
    printf "\033" | tui_read_key
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "unknown" ]
  [ "${lines[1]}" = "pageup" ]
  [ "${lines[2]}" = "escape" ]
}

@test "TUI state summary follows the selected manifest" {
  local custom="$BATS_TEST_TMPDIR/custom.json"
  bash "$LEROY_BIN" demo preset |
    jq '.metadata.id="acme-demo" | .metadata.name="Acme Demo" | .metadata.prefix="acme-demo" | .tenant.subdomain="acme-demo"' >"$custom"
  run bash -c '
    source "$1"
    LEROY_STATE_DIR="$2/state"; MORPHEUS_URL=https://morpheus.test; APPLIANCE_BUILD=9.0.0
    tui_bootstrap_manifest
    TUI_MANIFEST_FILE="$3"
    TUI_FEATURES_JSON="$(manifest_features "$3" | jq -Sc .)"
    tui_sync_manifest
    printf "%s|%s|%s\n" "$TUI_DEMO_ID" "$TUI_RESOURCE_COUNT" "$(tui_state_summary)"
  ' _ "$LEROY_BIN" "$BATS_TEST_TMPDIR" "$custom"
  [ "$status" -eq 0 ]
  [ "$output" = "acme-demo|24|Not created" ]
}

@test "TUI reports component drift and the saved organization name" {
  run bash -c '
    source "$1"
    LEROY_STATE_DIR="$2/state"; MORPHEUS_URL=https://morpheus.test; APPLIANCE_BUILD=9.0.0
    tui_bootstrap_manifest; state_init
    tui_bootstrap_manifest
    tui_feature_drift && exit 1
    printf "%s\n" "$(tui_component_summary)"
    printf "%s\n" "$(tui_destroy_phrase)"
    tui_toggle_component automation
    tui_feature_drift || exit 1
    printf "%s\n" "$(tui_component_summary)"
  ' _ "$LEROY_BIN" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "7/7 selected" ]
  [ "${lines[1]}" = "Leroy Demo Organization" ]
  [ "${lines[2]}" = "5/7 selected, deployed 7/7 - recreate required" ]
}

@test "TUI dashboard fits a standard 80x24 terminal" {
  run bash -c '
    source "$1"
    tput() { case "$1" in cols) printf "80\n" ;; lines) printf "24\n" ;; esac; }
    NO_COLOR=1 tui_init_palette
    LEROY_STATE_DIR="$2/state"
    tui_bootstrap_manifest
    TUI_KEYS=(s i p a v d r x c m w q)
    TUI_LABELS=(a b c d e f g h i j k l)
    TUI_HINTS=(a b c d e f g h i j k l)
    TUI_GROUPS=(INSPECT INSPECT INSPECT BUILD VALIDATE VALIDATE LIFECYCLE LIFECYCLE CONFIGURE CONFIGURE CONFIGURE SESSION)
    tui_render 0 | sed "s/\x1b\[[0-9;?]*[a-zA-Z]//g" | wc -l
  ' _ "$LEROY_BIN" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$output" -le 24 ]
}

@test "wizard refuses a non-terminal session so the TUI must not capture it" {
  run bash -c 'source "$1"; wizard_manifest </dev/null | cat' _ "$LEROY_BIN"
  [ "$status" -ne 0 ]
  run bash -c 'source "$1"; wizard_manifest </dev/null >/dev/null' _ "$LEROY_BIN"
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires an interactive terminal"* ]]
}

@test "TUI actions keep the session state they update" {
  run bash -c '
    source "$1"
    tput() { case "$1" in cols) printf "80\n" ;; lines) printf "40\n" ;; esac; }
    NO_COLOR=1 tui_init_palette
    tui_sync_manifest() { :; }
    tui_wait() { :; }
    probe() { TUI_CONNECTION_STATE="Connected as tester"; printf "probe output\n"; }
    tui_run_action "Probe" probe >/dev/null 2>&1
    printf "%s\n" "$TUI_CONNECTION_STATE"
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  [ "$output" = "Connected as tester" ]
}

@test "escape sequences do not leak their tail into the next key" {
  run bash -c '
    source "$1"
    printf "\033[15~x" | { tui_read_key; tui_read_key; }
  ' _ "$LEROY_BIN"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "unknown" ]
  [ "${lines[1]}" = "x" ]
}

@test "demo IDs cannot escape the state directory" {
  run bash "$LEROY_BIN" demo destroy --demo-id '../outside' --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid demo ID"* ]]
  run bash "$LEROY_BIN" demo state --demo-id '../outside'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid demo ID"* ]]
}
