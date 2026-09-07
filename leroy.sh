#!/usr/bin/env bash
set -Eeuo pipefail

readonly LEROY_VERSION="0.2.0"
readonly EXIT_USAGE=2 EXIT_DEPENDENCY=3 EXIT_AUTH=4 EXIT_API=5
readonly EXIT_NOT_FOUND=6 EXIT_RESPONSE=7 EXIT_CONFLICT=8 EXIT_VERIFY=9 EXIT_PARTIAL=10

ENV_URL_SET="${MORPHEUS_URL+x}" ENV_TOKEN_SET="${MORPHEUS_API_TOKEN+x}"
ENV_TLS_SET="${MORPHEUS_VERIFY_TLS+x}" ENV_CONNECT_SET="${MORPHEUS_CONNECT_TIMEOUT+x}"
ENV_REQUEST_SET="${MORPHEUS_REQUEST_TIMEOUT+x}" ENV_OUTPUT_SET="${LEROY_OUTPUT+x}"
ENV_LOG_SET="${LEROY_LOG_LEVEL+x}" ENV_STATE_SET="${LEROY_STATE_DIR+x}"
MORPHEUS_URL="${MORPHEUS_URL-}"
MORPHEUS_API_TOKEN="${MORPHEUS_API_TOKEN-}"
MORPHEUS_VERIFY_TLS="${MORPHEUS_VERIFY_TLS:-true}"
MORPHEUS_CONNECT_TIMEOUT="${MORPHEUS_CONNECT_TIMEOUT:-10}"
MORPHEUS_REQUEST_TIMEOUT="${MORPHEUS_REQUEST_TIMEOUT:-60}"
LEROY_OUTPUT="${LEROY_OUTPUT:-table}"
LEROY_LOG_LEVEL="${LEROY_LOG_LEVEL:-info}"
LEROY_STATE_DIR="${LEROY_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/leroy}"
MASTER_TOKEN=""
TENANT_TOKEN=""
TENANT_TOKEN_ID=""
TENANT_ADMIN_USER_ID=""
STATE_FILE=""
CURRENT_MANIFEST=""
CURRENT_DEMO_ID=""
CURRENT_MARKER=""
APPLIANCE_BUILD=""
BASE_ACCOUNT_ROLE_ID=""
BASE_USER_ROLE_ID=""
ACTIVE_AUTH_FILE=""
TEMP_TOKEN_USERS=()
TEMP_TOKEN_IDS=()
TUI_ACTIVE=false
TUI_CONNECTION_STATE="Not checked"
TUI_LAST_RESULT="No actions run in this session"
TUI_RESET='' TUI_BOLD='' TUI_DIM='' TUI_ACCENT='' TUI_MUTED=''
TUI_SUCCESS='' TUI_WARNING='' TUI_DANGER='' TUI_SELECTED=''

log_error() { printf 'error: %s\n' "$*" >&2; }
log_warn() { printf 'warning: %s\n' "$*" >&2; }
log_info() { [[ "$LEROY_LOG_LEVEL" == "error" || "$LEROY_LOG_LEVEL" == "warn" ]] || printf 'info: %s\n' "$*" >&2; }
die() { local code="$1"; shift; log_error "$*"; return "$code"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$EXIT_DEPENDENCY" "required command not found: $1"; }

cleanup() {
  local index token_id
  tui_leave_screen 2>/dev/null || true
  [[ -z "$ACTIVE_AUTH_FILE" ]] || rm -f "$ACTIVE_AUTH_FILE"
  if [[ -n "$MASTER_TOKEN" ]]; then
    for index in "${!TEMP_TOKEN_USERS[@]}"; do
      token_id="${TEMP_TOKEN_IDS[$index]:-}"
      [[ -n "$token_id" ]] || token_id="$(find_token_id "${TEMP_TOKEN_USERS[$index]}" 2>/dev/null || true)"
      [[ -z "$token_id" ]] || api_request DELETE "/api/tokens/${token_id}?userId=${TEMP_TOKEN_USERS[$index]}" "" "$MASTER_TOKEN" >/dev/null 2>&1 || true
    done
  fi
  [[ -z "$TENANT_TOKEN_ID" || -z "$MASTER_TOKEN" ]] ||
    api_request DELETE "/api/tokens/${TENANT_TOKEN_ID}${TENANT_ADMIN_USER_ID:+?userId=${TENANT_ADMIN_USER_ID}}" "" "$MASTER_TOKEN" >/dev/null 2>&1 || true
  [[ -z "$CURRENT_MANIFEST" || ! -f "$CURRENT_MANIFEST" || "$CURRENT_MANIFEST" != "${TMPDIR:-/tmp}"/leroy-manifest.* ]] || rm -f "$CURRENT_MANIFEST"
}
trap cleanup EXIT INT TERM

load_config() {
  local explicit="${1:-}" default="${XDG_CONFIG_HOME:-${HOME}/.config}/leroy/config"
  local e_url="$MORPHEUS_URL" e_token="$MORPHEUS_API_TOKEN" e_tls="$MORPHEUS_VERIFY_TLS"
  local e_connect="$MORPHEUS_CONNECT_TIMEOUT" e_request="$MORPHEUS_REQUEST_TIMEOUT"
  local e_output="$LEROY_OUTPUT" e_log="$LEROY_LOG_LEVEL" e_state="$LEROY_STATE_DIR"
  if [[ -n "$explicit" ]]; then
    [[ -r "$explicit" ]] || die "$EXIT_USAGE" "configuration file is not readable: $explicit" || return
    # shellcheck source=/dev/null
    source "$explicit"
  elif [[ -r "$default" ]]; then
    # shellcheck source=/dev/null
    source "$default"
  fi
  [[ -z "$ENV_URL_SET" ]] || MORPHEUS_URL="$e_url"
  [[ -z "$ENV_TOKEN_SET" ]] || MORPHEUS_API_TOKEN="$e_token"
  [[ -z "$ENV_TLS_SET" ]] || MORPHEUS_VERIFY_TLS="$e_tls"
  [[ -z "$ENV_CONNECT_SET" ]] || MORPHEUS_CONNECT_TIMEOUT="$e_connect"
  [[ -z "$ENV_REQUEST_SET" ]] || MORPHEUS_REQUEST_TIMEOUT="$e_request"
  [[ -z "$ENV_OUTPUT_SET" ]] || LEROY_OUTPUT="$e_output"
  [[ -z "$ENV_LOG_SET" ]] || LEROY_LOG_LEVEL="$e_log"
  [[ -z "$ENV_STATE_SET" ]] || LEROY_STATE_DIR="$e_state"
  MORPHEUS_URL="${MORPHEUS_URL%/}"
  MASTER_TOKEN="$MORPHEUS_API_TOKEN"
}

validate_runtime_config() {
  require_command curl || return
  require_command jq || return
  [[ -n "$MORPHEUS_URL" && "$MORPHEUS_URL" =~ ^https?:// ]] || die "$EXIT_USAGE" 'MORPHEUS_URL must be an http(s) appliance URL' || return
  [[ -n "$MORPHEUS_API_TOKEN" ]] || die "$EXIT_USAGE" 'MORPHEUS_API_TOKEN is required' || return
  [[ "$MORPHEUS_VERIFY_TLS" == true || "$MORPHEUS_VERIFY_TLS" == false ]] || die "$EXIT_USAGE" 'MORPHEUS_VERIFY_TLS must be true or false' || return
  [[ "$MORPHEUS_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ && "$MORPHEUS_REQUEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "$EXIT_USAGE" 'timeouts must be positive integers' || return
  [[ "$LEROY_OUTPUT" == table || "$LEROY_OUTPUT" == json ]] || die "$EXIT_USAGE" 'output must be table or json' || return
  [[ "$MORPHEUS_VERIFY_TLS" != false ]] || log_warn 'TLS certificate verification is disabled'
}

urlencode() { jq -nr --arg value "$1" '$value | @uri'; }

api_request() {
  local method="$1" path="$2" body="${3:-}" token="${4:-$MASTER_TOKEN}"
  local status curl_rc response combined auth_file=""
  local -a args=(--silent --show-error --request "$method" --connect-timeout "$MORPHEUS_CONNECT_TIMEOUT" --max-time "$MORPHEUS_REQUEST_TIMEOUT" --header 'Accept: application/json')
  if [[ -n "$token" ]]; then
    auth_file="$(mktemp "${TMPDIR:-/tmp}/leroy-auth.XXXXXX")" || return "$EXIT_API"
    ACTIVE_AUTH_FILE="$auth_file"
    chmod 600 "$auth_file"; printf 'Authorization: BEARER %s\n' "$token" >"$auth_file"
    args+=(--header "@${auth_file}")
  fi
  [[ "$MORPHEUS_VERIFY_TLS" != false ]] || args+=(--insecure)
  if [[ -n "$body" ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary @-)
  fi
  args+=(--write-out $'\n%{http_code}' "${MORPHEUS_URL}${path}")
  set +e
  if [[ -n "$body" ]]; then combined="$(printf '%s' "$body" | curl "${args[@]}")"; else combined="$(curl "${args[@]}")"; fi
  curl_rc=$?
  set -e
  [[ -z "$auth_file" ]] || rm -f "$auth_file"; ACTIVE_AUTH_FILE=""
  status="${combined##*$'\n'}"; response="${combined%$'\n'*}"
  ((curl_rc == 0)) || { die "$EXIT_API" "request transport failed (curl exit $curl_rc)"; return; }
  case "$status" in
    2??) ;;
    401 | 403) die "$EXIT_AUTH" "authentication or authorization failed: HTTP $status"; return ;;
    404) die "$EXIT_NOT_FOUND" 'resource not found: HTTP 404'; return ;;
    *)
      local message; message="$(jq -r '.msg // .message // .error // empty' <<<"$response" 2>/dev/null || true)"
      die "$EXIT_API" "Morpheus API failed: HTTP $status${message:+: $message}"; return
      ;;
  esac
  jq empty <<<"$response" >/dev/null 2>&1 || { die "$EXIT_RESPONSE" 'Morpheus returned invalid JSON'; return; }
  printf '%s\n' "$response"
}

oauth_login() {
  local username="$1" password="$2" status curl_rc response form combined
  form="$(jq -nr --arg username "$username" --arg password "$password" '["grant_type=password","scope=write","client_id=morph-api",("username="+($username|@uri)),("password="+($password|@uri))] | join("&")')"
  local -a args=(--silent --show-error --request POST --connect-timeout "$MORPHEUS_CONNECT_TIMEOUT" --max-time "$MORPHEUS_REQUEST_TIMEOUT" --header 'Accept: application/json' --header 'Content-Type: application/x-www-form-urlencoded' --data-binary @- --write-out $'\n%{http_code}')
  [[ "$MORPHEUS_VERIFY_TLS" != false ]] || args+=(--insecure)
  set +e; combined="$(printf '%s' "$form" | curl "${args[@]}" "${MORPHEUS_URL}/oauth/token")"; curl_rc=$?; set -e
  status="${combined##*$'\n'}"; response="${combined%$'\n'*}"
  ((curl_rc == 0)) || return "$EXIT_API"
  [[ "$status" == 2?? ]] || { die "$EXIT_AUTH" "temporary persona login failed: HTTP $status"; return; }
  jq -e '.access_token and (.access_token | length > 0)' <<<"$response" >/dev/null || return "$EXIT_RESPONSE"
  printf '%s\n' "$response"
}

preset_manifest() {
  jq -n '{
    schemaVersion: 1,
    metadata: {id:"leroy-demo", name:"Leroy Demo Organization", prefix:"leroy-demo", language:"en"},
    tenant: {name:"Leroy Demo Organization", subdomain:"leroy-demo", description:"Managed by Leroy demo:leroy-demo"},
    personas: [
      {key:"admin", role:"Leroy Tenant Admin", username:"leroy-admin", email:"leroy-admin@example.invalid", profile:"tenant-admin"},
      {key:"operator", role:"Leroy Platform Operator", username:"leroy-operator", email:"leroy-operator@example.invalid", profile:"platform-operator"},
      {key:"consumer", role:"Leroy Service Consumer", username:"leroy-consumer", email:"leroy-consumer@example.invalid", profile:"service-consumer"}
    ],
    environments: [
      {name:"Leroy Development", code:"leroy-dev", description:"Managed by Leroy demo:leroy-demo", visibility:"private"},
      {name:"Leroy Staging", code:"leroy-stg", description:"Managed by Leroy demo:leroy-demo", visibility:"private"},
      {name:"Leroy Production", code:"leroy-prod", description:"Managed by Leroy demo:leroy-demo", visibility:"private"}
    ],
    groups: [
      {name:"Leroy Development", code:"leroy-development", location:"Development", description:"Managed by Leroy demo:leroy-demo"},
      {name:"Leroy Production", code:"leroy-production", location:"Production", description:"Managed by Leroy demo:leroy-demo"}
    ],
    policies: [
      {name:"Leroy Demo Message", code:"leroy-demo-message", type:"motd", scope:"tenant", config:{message:"Welcome to the Leroy Morpheus demonstration environment."}},
      {name:"Leroy Instance Naming", code:"leroy-instance-naming", type:"instance-name", scope:"groups", config:{namingPattern:"leroy-${userInitials}-${sequence}"}},
      {name:"Leroy Demo Expiration", code:"leroy-expiration", type:"expiration", scope:"groups", config:{expirationDays:30}},
      {name:"Leroy Cypher Access", code:"leroy-cypher-access", type:"cypher", scope:"tenant", config:{keyPattern:"password/24/leroy-demo/*"}}
    ],
    automation: {
      inputs:[{name:"Leroy Demo Message", fieldName:"demoMessage", fieldLabel:"Demo message", type:"text", defaultValue:"Hello from Leroy", required:true}],
      tasks:[{name:"Leroy Demo Hello", code:"leroy-demo-hello", type:"groovy", resultType:"json", content:"return [success:true, message:(customOptions?.demoMessage ?: \"Hello from Leroy\"), source:\"leroy-demo\"]"}],
      workflows:[{name:"Leroy Demo Welcome", code:"leroy-demo-welcome", type:"operation", task:"leroy-demo-hello", input:"demoMessage"}],
      catalogItems:[{name:"Leroy Demo Welcome", code:"leroy-demo-catalog", category:"Leroy Demo", workflow:"leroy-demo-welcome", input:"demoMessage", context:"none", enabled:true, featured:true, visibility:"private"}]
    }
  }'
}

validate_manifest() {
  local file="$1"
  jq -e '
    .schemaVersion == 1 and
    (.metadata.id | test("^[a-z][a-z0-9-]{2,40}$")) and
    (.metadata.name | length > 0) and .metadata.language == "en" and
    (.tenant.name | length > 0) and (.tenant.subdomain | test("^[a-z][a-z0-9-]+$")) and
    (.personas | length == 3) and
    ([.personas[].key] | sort == ["admin","consumer","operator"]) and
    ([.personas[].profile] | sort == ["platform-operator","service-consumer","tenant-admin"]) and
    ([.personas[].username] | unique | length == 3) and
    (.environments | type == "array") and (.groups | type == "array") and
    (.policies | type == "array") and (.automation | type == "object")
  ' "$file" >/dev/null || { die "$EXIT_USAGE" 'manifest is invalid or uses an unsupported schema'; return; }
  if jq -e '[.. | objects | keys[]] | any(. == "password" or . == "token" or . == "access_token")' "$file" >/dev/null; then
    die "$EXIT_USAGE" 'manifest must not contain passwords or tokens'; return
  fi
}

manifest_to_temp() {
  local source="${1:-}"
  [[ -z "$CURRENT_MANIFEST" || ! -f "$CURRENT_MANIFEST" ]] || rm -f "$CURRENT_MANIFEST"
  CURRENT_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/leroy-manifest.XXXXXX")" || return "$EXIT_API"
  if [[ -n "$source" ]]; then jq -S . "$source" >"$CURRENT_MANIFEST"; else preset_manifest | jq -S . >"$CURRENT_MANIFEST"; fi
  validate_manifest "$CURRENT_MANIFEST"
  CURRENT_DEMO_ID="$(jq -r '.metadata.id' "$CURRENT_MANIFEST")"
  CURRENT_MARKER="Managed by Leroy demo:${CURRENT_DEMO_ID}"
  STATE_FILE="${LEROY_STATE_DIR}/${CURRENT_DEMO_ID}.json"
}

state_write() {
  local json="$1" tmp
  mkdir -p "$LEROY_STATE_DIR"; chmod 700 "$LEROY_STATE_DIR" 2>/dev/null || true
  tmp="$(mktemp "${LEROY_STATE_DIR}/.state.XXXXXX")" || return "$EXIT_API"
  printf '%s\n' "$json" | jq -S . >"$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$STATE_FILE"
}

state_init() {
  [[ ! -e "$STATE_FILE" ]] || return 0
  state_write "$(jq -n --arg url "$MORPHEUS_URL" --arg build "$APPLIANCE_BUILD" --slurpfile manifest "$CURRENT_MANIFEST" '{stateVersion:1,applianceUrl:$url,applianceBuild:$build,manifest:$manifest[0],resources:[]}')"
}

state_assert_appliance() {
  [[ ! -f "$STATE_FILE" ]] || [[ "$(jq -r '.applianceUrl' "$STATE_FILE")" == "$MORPHEUS_URL" ]] || { die "$EXIT_CONFLICT" 'state belongs to a different Morpheus appliance'; return; }
}

state_resource() { [[ -f "$STATE_FILE" ]] && jq -c --arg key "$1" '.resources[]? | select(.key==$key)' "$STATE_FILE" | head -n 1; }

state_record() {
  local entry="$1" next
  next="$(jq --argjson entry "$entry" '.resources = ([.resources[] | select(.key != $entry.key)] + [$entry])' "$STATE_FILE")"
  state_write "$next"
}

state_remove() {
  local key="$1" next
  next="$(jq --arg key "$key" '.resources = [.resources[] | select(.key != $key)]' "$STATE_FILE")"
  state_write "$next"
}

preflight() {
  local whoami roles version capability
  whoami="$(api_request GET '/api/whoami' '' "$MASTER_TOKEN")" || return
  jq -e '.isMasterAccount == true' <<<"$whoami" >/dev/null || { die "$EXIT_AUTH" 'a Master Tenant administrator token is required'; return; }
  version="$(jq -r '[.. | objects | (.buildVersion?,.applianceVersion?,.version?)] | map(select(type=="string" and test("^9([. -]|$)"))) | first // empty' <<<"$whoami")"
  [[ -n "$version" ]] || { die "$EXIT_VERIFY" 'Morpheus major version 9 is required'; return; }
  APPLIANCE_BUILD="$version"
  roles="$(api_request GET '/api/roles?max=100&includeDefaultAccess=true' '' "$MASTER_TOKEN")" || return
  BASE_ACCOUNT_ROLE_ID="$(jq -r '[.. | objects | select((.roleType? == "account") and (.name? | test("Tenant Admin|Account Admin";"i")))][0].id // empty' <<<"$roles")"
  BASE_USER_ROLE_ID="$(jq -r '[.. | objects | select((.roleType? == "user") and (.name? | test("Admin";"i")))][0].id // empty' <<<"$roles")"
  [[ -n "$BASE_ACCOUNT_ROLE_ID" && -n "$BASE_USER_ROLE_ID" ]] || { die "$EXIT_VERIFY" 'required built-in Morpheus 9 base roles were not found'; return; }
  for capability in accounts policies policy-types tasks task-sets catalog-item-types library/option-types cypher; do
    api_request GET "/api/${capability}?max=1" '' "$MASTER_TOKEN" >/dev/null || { die "$EXIT_VERIFY" "required API capability is unavailable: $capability"; return; }
  done
  export BASE_ACCOUNT_ROLE_ID BASE_USER_ROLE_ID
}

resource_stream() {
  jq -c '
    {key:"role:tenant",type:"role",scope:"master",name:(.metadata.name+" Tenant Role"),spec:{kind:"account",profile:"tenant-root"}},
    {key:"tenant",type:"tenant",scope:"master",name:.tenant.name,spec:.tenant},
    (.personas[] | {key:("role:"+.key),type:"role",scope:"master",name:.role,spec:{kind:"user",profile:.profile}}),
    (.personas[] | {key:("cypher:"+.key),type:"cypher",scope:"master",name:.username,spec:{path:("password/24/"+$root.metadata.id+"/"+.username)}}),
    (.personas[] | {key:("user:"+.key),type:"user",scope:"master",name:.username,spec:.}),
    (.environments[] | {key:("environment:"+.code),type:"environment",scope:"tenant",name:.name,spec:.}),
    (.groups[] | {key:("group:"+.code),type:"group",scope:"tenant",name:.name,spec:.}),
    (.policies[] | {key:("policy:"+.code),type:"policy",scope:"tenant",name:.name,spec:.}),
    (.automation.inputs[] | {key:("input:"+.fieldName),type:"input",scope:"tenant",name:.name,spec:.}),
    (.automation.tasks[] | {key:("task:"+.code),type:"task",scope:"tenant",name:.name,spec:.}),
    (.automation.workflows[] | {key:("workflow:"+.code),type:"workflow",scope:"tenant",name:.name,spec:.}),
    (.automation.catalogItems[] | {key:("catalog:"+.code),type:"catalog",scope:"tenant",name:.name,spec:.})
  ' --argjson root "$(command cat "$CURRENT_MANIFEST")" "$CURRENT_MANIFEST"
}

resource_path() {
  case "$1" in
    tenant) printf '/api/accounts' ;;
    role) printf '/api/roles' ;;
    user) printf '/api/accounts/%s/users' "$(resource_id tenant)" ;;
    environment) printf '/api/environments' ;;
    group) printf '/api/groups' ;;
    policy) printf '/api/policies' ;;
    input) printf '/api/library/option-types' ;;
    task) printf '/api/tasks' ;;
    workflow) printf '/api/task-sets' ;;
    catalog) printf '/api/catalog-item-types' ;;
    cypher) printf '/api/cypher' ;;
    *) return "$EXIT_USAGE" ;;
  esac
}

resource_id() { state_resource "$1" | jq -r '.id // empty'; }
resource_token() {
  if [[ "$1" == tenant ]]; then ensure_tenant_token || return; printf '%s' "$TENANT_TOKEN"
  else printf '%s' "$MASTER_TOKEN"
  fi
}

cypher_find() {
  local path="$1" response
  response="$(api_request GET "/api/cypher?max=100&phrase=$(urlencode "$path")" '' "$MASTER_TOKEN")" || return
  jq -ce --arg path "$path" '[.. | objects | select((.key?==$path) or (.path?==$path) or (.name?==$path))][0]' <<<"$response"
}

resource_get() {
  local entry="$1" type scope id path token
  type="$(jq -r '.type' <<<"$entry")"; scope="$(jq -r '.scope' <<<"$entry")"; id="$(jq -r '.id // empty' <<<"$entry")"
  if [[ "$type" == cypher ]]; then
    path="$(jq -r '.spec.path' <<<"$entry")"; cypher_find "$path"
  else
    path="$(resource_path "$type")"; token="$(resource_token "$scope")"
    api_request GET "${path}/${id}" '' "$token"
  fi
}

remote_is_owned() {
  local type="$1" response="$2" expected_name="$3"
  if [[ "$type" == cypher ]]; then [[ "$expected_name" == "$CURRENT_DEMO_ID"/* || "$expected_name" == password/*/"$CURRENT_DEMO_ID"/* ]]; return; fi
  jq -e --arg marker "$CURRENT_MARKER" --arg prefix "$(jq -r '.metadata.prefix' "$CURRENT_MANIFEST")" --arg name "$expected_name" '
    (tostring | contains($marker)) or
    ([.. | strings] | any(. == $name or startswith($prefix)))
  ' <<<"$response" >/dev/null
}

remote_has_leroy_identity() {
  jq -e 'tostring | contains("Managed by Leroy demo:") or ([.. | strings] | any(startswith("leroy-")))' <<<"$1" >/dev/null
}

find_remote() {
  local spec="$1" type scope name path token response encoded
  type="$(jq -r '.type' <<<"$spec")"; scope="$(jq -r '.scope' <<<"$spec")"; name="$(jq -r '.name' <<<"$spec")"
  if [[ "$type" == cypher ]]; then cypher_find "$(jq -r '.spec.path' <<<"$spec")" 2>/dev/null || true; return; fi
  path="$(resource_path "$type")"; token="$(resource_token "$scope")"; encoded="$(urlencode "$name")"
  response="$(api_request GET "${path}?max=100&name=${encoded}" '' "$token" 2>/dev/null)" || return 0
  jq -c --arg name "$name" '[.. | objects | select(.id? and ((.name?==$name) or (.username?==$name) or (.code?==$name)))][0] // empty' <<<"$response"
}

role_permissions() {
  case "$1" in
    platform-operator) jq -nc '[{pattern:"provisioning.*instances|instances[[:space:]]*$|provisioning.*apps|provisioning.*tasks|tasks.*script engines|library",access:"full"},{pattern:"infrastructure",access:"read"}]' ;;
    service-consumer) jq -nc '[{pattern:"catalog|service catalog",access:"full"}]' ;;
    *) printf '[]\n' ;;
  esac
}

configure_role_permissions() {
  local profile="$1" role_id="$2" rules available rule pattern access matches permission code
  rules="$(role_permissions "$profile")"; [[ "$(jq 'length' <<<"$rules")" -gt 0 ]] || return 0
  available="$(api_request GET "/api/roles/${BASE_USER_ROLE_ID}?includeDefaultAccess=true" '' "$MASTER_TOKEN")" || return
  while IFS= read -r rule; do
    pattern="$(jq -r '.pattern' <<<"$rule")"; access="$(jq -r '.access' <<<"$rule")"
    matches="$(jq -c --arg pattern "$pattern" '[.. | objects | select(.code? and (((.name? // "")+" "+.code) | test($pattern;"i")))] | unique_by(.code)[]' <<<"$available")"
    [[ -n "$matches" ]] || { die "$EXIT_VERIFY" "no Morpheus permission matched $profile rule: $pattern"; return; }
    while IFS= read -r permission; do
      code="$(jq -r '.code' <<<"$permission")"
      api_request PUT "/api/roles/${role_id}/update-permission" "$(jq -nc --arg code "$code" --arg access "$access" '{permissionCode:$code,access:$access}')" "$MASTER_TOKEN" >/dev/null || return
    done <<<"$matches"
  done < <(jq -c '.[]' <<<"$rules")
}

configure_catalog_access() {
  local catalog_id="$1" role_key role_id
  for role_key in admin operator consumer; do
    role_id="$(resource_id "role:${role_key}")"
    api_request PUT "/api/roles/${role_id}/update-catalog-item-type" "$(jq -nc --argjson id "$catalog_id" '{catalogItemTypeId:$id,access:"full"}')" "$MASTER_TOKEN" >/dev/null || return
  done
}

resolve_policy_type() {
  local semantic="$1" response pattern match
  case "$semantic" in
    motd) pattern='message of the day|motd' ;;
    instance-name) pattern='instance name' ;;
    expiration) pattern='expiration' ;;
    cypher) pattern='cypher access|cypher' ;;
    *) return "$EXIT_USAGE" ;;
  esac
  response="$(api_request GET '/api/policy-types?max=200' '' "$(resource_token tenant)")" || return
  match="$(jq -c --arg pattern "$pattern" '[.. | objects | select(.id? and (((.name? // "")+" "+(.code? // "")) | test($pattern;"i")))][0] // empty' <<<"$response")"
  [[ -n "$match" ]] || { die "$EXIT_VERIFY" "required Morpheus policy type is unavailable: $semantic"; return; }
  jq -c '{id,code,name}' <<<"$match"
}

build_payload() {
  local spec="$1" type logical profile tenant_id role_id cypher_key password task_id input_id workflow_id marker policy_type group_ids
  type="$(jq -r '.type' <<<"$spec")"; logical="$(jq -c '.spec' <<<"$spec")"; marker="$CURRENT_MARKER"
  case "$type" in
    role)
      profile="$(jq -r '.profile' <<<"$logical")"
      if [[ "$(jq -r '.kind' <<<"$logical")" == account ]]; then
        jq -n --arg name "$(jq -r '.name' <<<"$spec")" --arg marker "$marker" --argjson base "$BASE_ACCOUNT_ROLE_ID" '{role:{name:$name,authority:($name|ascii_downcase|gsub(" ";"-")),description:$marker,roleType:"account",baseRoleId:$base}}'
      else
        tenant_id="$(resource_id tenant)"
        if [[ "$profile" == tenant-admin ]]; then
          jq -n --arg name "$(jq -r '.name' <<<"$spec")" --arg marker "$marker" --argjson account "$tenant_id" --argjson base "$BASE_USER_ROLE_ID" '{role:{name:$name,authority:($name|ascii_downcase|gsub(" ";"-")),description:$marker,roleType:"user",accountId:$account,baseRoleId:$base}}'
        else
          jq -n --arg name "$(jq -r '.name' <<<"$spec")" --arg marker "$marker" --argjson account "$tenant_id" '{role:{name:$name,authority:($name|ascii_downcase|gsub(" ";"-")),description:$marker,roleType:"user",accountId:$account}}'
        fi
      fi
      ;;
    tenant)
      role_id="$(resource_id 'role:tenant')"
      jq -n --argjson account "$logical" --argjson role "$role_id" '$account + {role:{id:$role}} | {account:.}'
      ;;
    cypher) printf '{}\n' ;;
    user)
      profile="$(jq -r '.key' <<<"$logical")"; role_id="$(resource_id "role:${profile}")"; cypher_key="$(resource_id "cypher:${profile}")"
      password="$(api_request GET "/api/cypher/${cypher_key}" '' "$MASTER_TOKEN" | jq -r '.data // .cypher.data // empty')"
      [[ -n "$password" ]] || { die "$EXIT_RESPONSE" "Cypher did not return a password for $profile"; return; }
      jq -n --argjson user "$logical" --arg password "$password" --argjson role "$role_id" --arg marker "$marker" '{user:{username:$user.username,email:$user.email,firstName:"Leroy",lastName:($user.key|ascii_upcase),password:$password,roles:[{id:$role}],description:$marker}}'
      ;;
    environment) jq -n --argjson value "$logical" --arg marker "$marker" '{environment:($value + {description:$marker})}' ;;
    group) jq -n --argjson value "$logical" --arg marker "$marker" '{group:($value + {description:$marker})}' ;;
    policy)
      tenant_id="$(resource_id tenant)"
      policy_type="$(resolve_policy_type "$(jq -r '.type' <<<"$logical")")" || return
      group_ids="$(jq '[.resources[] | select(.type=="group") | {id:(.id|tonumber)}]' "$STATE_FILE")"
      jq -n --argjson value "$logical" --arg marker "$marker" --argjson account "$tenant_id" --argjson policyType "$policy_type" --argjson groups "$group_ids" '{policy:{name:$value.name,code:$value.code,description:$marker,policyType:$policyType,account:{id:$account},sites:(if $value.scope=="groups" then $groups else [] end),config:$value.config}}'
      ;;
    input) jq -n --argjson value "$logical" --arg marker "$marker" '{optionType:($value + {description:$marker,fieldContext:"customOptions",editable:true,displayOrder:0})}' ;;
    task) jq -n --argjson value "$logical" --arg marker "$marker" --arg label "$CURRENT_DEMO_ID" '{task:{name:$value.name,code:$value.code,description:$marker,taskType:{code:"groovyTask"},executeTarget:"local",resultType:$value.resultType,file:{sourceType:"local",content:$value.content},labels:[$label]}}' ;;
    workflow)
      task_id="$(resource_id "task:$(jq -r '.task' <<<"$logical")")"; input_id="$(resource_id "input:$(jq -r '.input' <<<"$logical")")"
      jq -n --argjson value "$logical" --arg marker "$marker" --arg label "$CURRENT_DEMO_ID" --argjson task "$task_id" --argjson input "$input_id" '{taskSet:{name:$value.name,code:$value.code,description:$marker,type:"operation",labels:[$label],optionTypes:[{id:$input}],tasks:[{task:{id:$task},taskPhase:"operation",taskOrder:0}]}}'
      ;;
    catalog)
      workflow_id="$(resource_id "workflow:$(jq -r '.workflow' <<<"$logical")")"; input_id="$(resource_id "input:$(jq -r '.input' <<<"$logical")")"
      jq -n --argjson value "$logical" --arg marker "$marker" --arg label "$CURRENT_DEMO_ID" --argjson workflow "$workflow_id" --argjson input "$input_id" '{catalogItemType:{name:$value.name,code:$value.code,description:$marker,type:"workflow",category:$value.category,enabled:$value.enabled,featured:$value.featured,visibility:$value.visibility,context:$value.context,workflow:{id:$workflow},optionTypes:[{id:$input}],labels:[$label]}}'
      ;;
  esac
}

extract_id() {
  local type="$1"
  case "$type" in
    tenant) jq -r '.account.id // .id // empty' ;;
    role) jq -r '.role.id // .id // empty' ;;
    user) jq -r '.user.id // .id // empty' ;;
    environment) jq -r '.environment.id // .id // empty' ;;
    group) jq -r '.group.id // .id // empty' ;;
    policy) jq -r '.policy.id // .id // empty' ;;
    input) jq -r '.optionType.id // .id // empty' ;;
    task) jq -r '.task.id // .id // empty' ;;
    workflow) jq -r '.taskSet.id // .id // empty' ;;
    catalog) jq -r '.catalogItemType.id // .id // empty' ;;
  esac
}

ensure_tenant_token() {
  [[ -z "$TENANT_TOKEN" ]] || return 0
  local cypher_path password username subdomain login tokens
  cypher_path="$(resource_id 'cypher:admin')"; TENANT_ADMIN_USER_ID="$(resource_id 'user:admin')"
  [[ -n "$cypher_path" && -n "$TENANT_ADMIN_USER_ID" ]] || { die "$EXIT_PARTIAL" 'tenant administrator is not ready; rerun apply'; return; }
  password="$(api_request GET "/api/cypher/${cypher_path}" '' "$MASTER_TOKEN" | jq -r '.data // .cypher.data // empty')"
  username="$(jq -r '.personas[] | select(.key=="admin") | .username' "$CURRENT_MANIFEST")"
  subdomain="$(jq -r '.tenant.subdomain' "$CURRENT_MANIFEST")"
  login="$(oauth_login "${subdomain}\\${username}" "$password")" || return
  TENANT_TOKEN="$(jq -r '.access_token' <<<"$login")"
  TENANT_TOKEN_ID="$(jq -r '.id // .token.id // empty' <<<"$login")"
  if [[ -z "$TENANT_TOKEN_ID" ]]; then
    tokens="$(api_request GET "/api/tokens?userId=${TENANT_ADMIN_USER_ID}&max=100&sort=dateCreated&direction=desc" '' "$MASTER_TOKEN" 2>/dev/null || true)"
    TENANT_TOKEN_ID="$(jq -r '[.. | objects | select(.id? and .dateCreated?)][0].id // empty' <<<"${tokens:-{}}")"
  fi
}

desired_action() {
  local spec="$1" key type scope name saved remote saved_spec wanted_spec found expected
  key="$(jq -r '.key' <<<"$spec")"; type="$(jq -r '.type' <<<"$spec")"; scope="$(jq -r '.scope' <<<"$spec")"; name="$(jq -r '.name' <<<"$spec")"
  saved="$(state_resource "$key")"
  if [[ -n "$saved" ]]; then
    if ! remote="$(resource_get "$saved" 2>/dev/null)"; then printf 'conflict'; return; fi
    expected="$(jq -r '.spec.path // .name' <<<"$saved")"
    if ! remote_is_owned "$type" "$remote" "$expected"; then printf 'conflict'; return; fi
    saved_spec="$(jq -Sc '.spec' <<<"$saved")"; wanted_spec="$(jq -Sc '.spec' <<<"$spec")"
    if [[ "$saved_spec" != "$wanted_spec" ]]; then printf 'update'
    elif [[ "$type" == role || "$type" == catalog ]] && [[ "$(jq -r '.configured // false' <<<"$saved")" != true ]]; then printf 'update'
    else printf 'unchanged'
    fi
    return
  fi
  if [[ "$type" == user || "$scope" == tenant ]] && [[ -z "$(resource_id tenant)" ]]; then printf 'create'; return; fi
  found="$(find_remote "$spec")"
  [[ -z "$found" ]] && printf 'create' || printf 'conflict'
}

emit_plan() {
  local results="$1"
  if [[ "$LEROY_OUTPUT" == json ]]; then jq -s '{changes:.}' "$results"
  else
    printf '%-10s %-18s %s\n' ACTION TYPE NAME
    jq -r '. | [.action,.type,.name] | @tsv' "$results" | while IFS=$'\t' read -r action type name; do printf '%-10s %-18s %s\n' "$action" "$type" "$name"; done
  fi
}

demo_plan() {
  local results spec action conflicts=0
  preflight || return
  state_assert_appliance || return
  results="$(mktemp "${TMPDIR:-/tmp}/leroy-plan.XXXXXX")" || return "$EXIT_API"
  while IFS= read -r spec; do
    action="$(desired_action "$spec")"
    jq -nc --arg action "$action" --arg type "$(jq -r '.type' <<<"$spec")" --arg name "$(jq -r '.name' <<<"$spec")" --arg key "$(jq -r '.key' <<<"$spec")" '{action:$action,type:$type,name:$name,key:$key}' >>"$results"
    [[ "$action" != conflict ]] || conflicts=$((conflicts + 1))
  done < <(resource_stream)
  emit_plan "$results"; rm -f "$results"
  ((conflicts == 0)) || return "$EXIT_CONFLICT"
}

apply_one() {
  local spec="$1" action key type scope name path token payload response id saved entry
  key="$(jq -r '.key' <<<"$spec")"; type="$(jq -r '.type' <<<"$spec")"; scope="$(jq -r '.scope' <<<"$spec")"; name="$(jq -r '.name' <<<"$spec")"
  action="$(desired_action "$spec")"
  case "$action" in
    unchanged)
      saved="$(state_resource "$key")"
      if [[ "$type" == role || "$type" == catalog ]] && [[ "$(jq -r '.configured // false' <<<"$saved")" != true ]]; then
        id="$(jq -r '.id' <<<"$saved")"
        if [[ "$type" == role ]]; then configure_role_permissions "$(jq -r '.spec.profile' <<<"$spec")" "$id" || return; fi
        if [[ "$type" == catalog ]]; then configure_catalog_access "$id" || return; fi
        state_record "$(jq '.configured=true' <<<"$saved")"
      fi
      log_info "unchanged $type: $name"; return 0
      ;;
    conflict) die "$EXIT_CONFLICT" "resource conflicts with Leroy ownership: $type $name"; return ;;
  esac
  if [[ "$type" == cypher ]]; then
    path="$(jq -r '.spec.path' <<<"$spec")"
    response="$(api_request GET "/api/cypher/${path}" '' "$MASTER_TOKEN")" || return
    [[ -n "$(jq -r '.data // .cypher.data // empty' <<<"$response")" ]] || return "$EXIT_RESPONSE"
    id="$path"
  else
    path="$(resource_path "$type")"; token="$(resource_token "$scope")"; payload="$(build_payload "$spec")" || return
    if [[ "$action" == update ]]; then
      saved="$(state_resource "$key")"; id="$(jq -r '.id' <<<"$saved")"
      response="$(api_request PUT "${path}/${id}" "$payload" "$token")" || return
    else
      response="$(api_request POST "$path" "$payload" "$token")" || return
      id="$(printf '%s' "$response" | extract_id "$type")"
      [[ -n "$id" && "$id" != null ]] || { die "$EXIT_RESPONSE" "create response did not contain an ID for $type $name"; return; }
    fi
  fi
  entry="$(jq -nc --arg key "$key" --arg type "$type" --arg scope "$scope" --arg name "$name" --arg id "$id" --arg marker "$CURRENT_MARKER" --argjson logical "$(jq -c '.spec' <<<"$spec")" '{key:$key,type:$type,scope:$scope,name:$name,id:$id,marker:$marker,spec:$logical}')"
  state_record "$entry"
  if [[ "$type" == role ]]; then configure_role_permissions "$(jq -r '.spec.profile' <<<"$spec")" "$id" || return; fi
  if [[ "$type" == catalog ]]; then configure_catalog_access "$id" || return; fi
  if [[ "$type" == role || "$type" == catalog ]]; then state_record "$(jq '.configured=true' <<<"$entry")"; fi
  log_info "$action $type: $name"
}

demo_apply() {
  local spec current apply_rc
  preflight || return
  state_assert_appliance || return
  state_init || return
  current="$(jq --slurpfile manifest "$CURRENT_MANIFEST" --arg build "$APPLIANCE_BUILD" '.manifest=$manifest[0] | .applianceBuild=$build' "$STATE_FILE")"
  state_write "$current"
  while IFS= read -r spec; do
    if apply_one "$spec"; then
      :
    else
      apply_rc=$?
      log_error 'apply stopped; completed resources were retained and can be resumed'
      [[ "$apply_rc" != "$EXIT_CONFLICT" ]] || return "$EXIT_CONFLICT"
      return "$EXIT_PARTIAL"
    fi
  done < <(resource_stream)
  demo_verify false
}

resource_delete() {
  local entry="$1" force="$2" type scope name id path token remote expected key
  type="$(jq -r '.type' <<<"$entry")"; scope="$(jq -r '.scope' <<<"$entry")"; name="$(jq -r '.name' <<<"$entry")"; id="$(jq -r '.id' <<<"$entry")"; key="$(jq -r '.key' <<<"$entry")"
  if [[ "$type" == cypher ]]; then
    [[ "$id" == password/*/"$CURRENT_DEMO_ID"/* ]] || { die "$EXIT_CONFLICT" "unsafe Cypher path: $id"; return; }
    if ! remote="$(cypher_find "$id" 2>/dev/null)"; then log_warn "already absent cypher: $name"; state_remove "$key"; return 0; fi
    remote_is_owned "$type" "$remote" "$id" || { die "$EXIT_CONFLICT" "Cypher ownership mismatch: $id"; return; }
    api_request DELETE "/api/cypher/${id}" '' "$MASTER_TOKEN" >/dev/null || return
  else
    if ! remote="$(resource_get "$entry" 2>/dev/null)"; then
      log_warn "already absent $type: $name"; state_remove "$key"; return 0
    fi
    expected="$(jq -r '.spec.path // .name' <<<"$entry")"
    if ! remote_is_owned "$type" "$remote" "$expected"; then
      remote_has_leroy_identity "$remote" || { die "$EXIT_CONFLICT" "resource has no Leroy identity and cannot be deleted: $type $name"; return; }
      [[ "$force" == true ]] || { die "$EXIT_CONFLICT" "remote ownership mismatch for $type $name; inspect it or use --force"; return; }
    fi
    path="$(resource_path "$type")"; token="$(resource_token "$scope")"
    api_request DELETE "${path}/${id}" '' "$token" >/dev/null || return
  fi
  state_remove "$key"; log_info "deleted $type: $name"
}

demo_destroy() {
  local demo_id="$1" yes="$2" force="$3" entry state_name
  [[ "$yes" == true ]] || { die "$EXIT_USAGE" 'destroy requires --yes'; return; }
  CURRENT_DEMO_ID="$demo_id"; STATE_FILE="${LEROY_STATE_DIR}/${demo_id}.json"
  [[ -r "$STATE_FILE" ]] || { die "$EXIT_NOT_FOUND" "state not found for demo: $demo_id"; return; }
  state_assert_appliance || return
  CURRENT_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/leroy-manifest.XXXXXX")"; jq -S '.manifest' "$STATE_FILE" >"$CURRENT_MANIFEST"
  CURRENT_MARKER="Managed by Leroy demo:${demo_id}"; state_name="$(jq -r '.manifest.metadata.name' "$STATE_FILE")"
  [[ -n "$state_name" ]] || return "$EXIT_RESPONSE"
  preflight || return
  while IFS= read -r entry; do resource_delete "$entry" "$force" || return; done < <(jq -c '.resources | reverse[]' "$STATE_FILE")
  rm -f "$STATE_FILE"; log_info "destroyed demo: $state_name"
}

find_token_id() {
  local user_id="$1" response
  response="$(api_request GET "/api/tokens?userId=${user_id}&max=100&sort=dateCreated&direction=desc" '' "$MASTER_TOKEN" 2>/dev/null || true)"
  jq -r '[.. | objects | select(.id? and .dateCreated?)][0].id // empty' <<<"${response:-{}}"
}

revoke_token() {
  local token_id="$1" user_id="$2"
  [[ -z "$token_id" ]] || api_request DELETE "/api/tokens/${token_id}?userId=${user_id}" '' "$MASTER_TOKEN" >/dev/null 2>&1 || true
}

verify_persona() {
  local persona="$1" key username subdomain cypher_path password login token token_id user_id allowed_path
  key="$(jq -r '.key' <<<"$persona")"; username="$(jq -r '.username' <<<"$persona")"; subdomain="$(jq -r '.tenant.subdomain' "$CURRENT_MANIFEST")"
  cypher_path="$(resource_id "cypher:${key}")"; user_id="$(resource_id "user:${key}")"
  password="$(api_request GET "/api/cypher/${cypher_path}" '' "$MASTER_TOKEN" | jq -r '.data // .cypher.data // empty')"
  login="$(oauth_login "${subdomain}\\${username}" "$password")" || return
  token="$(jq -r '.access_token' <<<"$login")"; token_id="$(jq -r '.id // .token.id // empty' <<<"$login")"
  TEMP_TOKEN_USERS+=("$user_id"); TEMP_TOKEN_IDS+=("$token_id")
  [[ -n "$token_id" ]] || token_id="$(find_token_id "$user_id")"
  TEMP_TOKEN_IDS[$((${#TEMP_TOKEN_IDS[@]} - 1))]="$token_id"
  case "$key" in
    admin) allowed_path='/api/whoami' ;;
    operator) allowed_path='/api/tasks?max=1' ;;
    consumer) allowed_path='/api/catalog-item-types?max=1' ;;
  esac
  if ! api_request GET "$allowed_path" '' "$token" >/dev/null; then revoke_token "$token_id" "$user_id"; return "$EXIT_VERIFY"; fi
  if [[ "$key" == consumer ]] && api_request GET '/api/tasks?max=1' '' "$token" >/dev/null 2>&1; then
    revoke_token "$token_id" "$user_id"; die "$EXIT_VERIFY" 'service consumer unexpectedly has task administration access'; return
  fi
  revoke_token "$token_id" "$user_id"
}

demo_verify() {
  local deep="${1:-false}" entry remote expected failures=0 workflow_id result operator persona
  [[ -r "$STATE_FILE" ]] || { die "$EXIT_NOT_FOUND" 'demo state does not exist'; return; }
  state_assert_appliance || return
  jq -e --slurpfile manifest "$CURRENT_MANIFEST" '.manifest == $manifest[0]' "$STATE_FILE" >/dev/null || { log_error 'state manifest differs from the requested manifest'; failures=$((failures + 1)); }
  while IFS= read -r entry; do
    if ! remote="$(resource_get "$entry" 2>/dev/null)"; then log_error "missing $(jq -r '.type+":"+.name' <<<"$entry")"; failures=$((failures + 1)); continue; fi
    expected="$(jq -r '.spec.path // .name' <<<"$entry")"
    remote_is_owned "$(jq -r '.type' <<<"$entry")" "$remote" "$expected" || { log_error "ownership mismatch: $(jq -r '.name' <<<"$entry")"; failures=$((failures + 1)); }
  done < <(jq -c '.resources[]' "$STATE_FILE")
  if [[ "$deep" == true && "$failures" -eq 0 ]]; then
    while IFS= read -r persona; do verify_persona "$persona" || failures=$((failures + 1)); done < <(jq -c '.personas[]' "$CURRENT_MANIFEST")
    operator="$(jq -c '.personas[] | select(.key=="operator")' "$CURRENT_MANIFEST")"
    local op_key op_path op_password op_login op_token op_token_id op_user
    op_key="$(jq -r '.key' <<<"$operator")"; op_path="$(resource_id "cypher:${op_key}")"; op_user="$(resource_id "user:${op_key}")"
    op_password="$(api_request GET "/api/cypher/${op_path}" '' "$MASTER_TOKEN" | jq -r '.data // .cypher.data // empty')"
    op_login="$(oauth_login "$(jq -r '.tenant.subdomain' "$CURRENT_MANIFEST")\\$(jq -r '.username' <<<"$operator")" "$op_password")" || return "$EXIT_VERIFY"
    op_token="$(jq -r '.access_token' <<<"$op_login")"; op_token_id="$(jq -r '.id // .token.id // empty' <<<"$op_login")"; [[ -n "$op_token_id" ]] || op_token_id="$(find_token_id "$op_user")"
    TEMP_TOKEN_USERS+=("$op_user"); TEMP_TOKEN_IDS+=("$op_token_id")
    workflow_id="$(resource_id "workflow:$(jq -r '.automation.workflows[0].code' "$CURRENT_MANIFEST")")"
    result="$(api_request POST "/api/task-sets/${workflow_id}/execute" '{"job":{"customOptions":{"demoMessage":"Verified by Leroy"}}}' "$op_token" 2>/dev/null || true)"
    jq -e '(.success // true) != false' <<<"${result:-null}" >/dev/null || failures=$((failures + 1))
    revoke_token "$op_token_id" "$op_user"
  fi
  if ((failures > 0)); then die "$EXIT_VERIFY" "$failures verification check(s) failed"; return; fi
  if [[ "$LEROY_OUTPUT" == json ]]; then jq -n --arg id "$CURRENT_DEMO_ID" --argjson deep "$deep" '{verified:true,demoId:$id,deep:$deep}'
  else printf 'Demo %s verified%s.\n' "$CURRENT_DEMO_ID" "$([[ "$deep" == true ]] && printf ' (deep)' || true)"; fi
}

wizard_manifest() {
  [[ -t 0 && -t 1 ]] || { die "$EXIT_USAGE" 'wizard requires an interactive terminal'; return; }
  local id name subdomain output answer generated
  printf 'Demo ID [leroy-demo]: '; read -r id; id="${id:-leroy-demo}"
  printf 'Organization name [Leroy Demo Organization]: '; read -r name; name="${name:-Leroy Demo Organization}"
  printf 'Tenant subdomain [%s]: ' "$id"; read -r subdomain; subdomain="${subdomain:-$id}"
  printf 'Output file [%s.json]: ' "$id"; read -r output; output="${output:-${id}.json}"
  generated="$(preset_manifest | jq --arg id "$id" --arg name "$name" --arg subdomain "$subdomain" '
    .metadata.id=$id | .metadata.name=$name | .metadata.prefix=$id |
    .tenant.name=$name | .tenant.subdomain=$subdomain |
    .tenant.description=("Managed by Leroy demo:"+$id) |
    .personas |= map(.username=($id+"-"+.key) | .email=($id+"-"+.key+"@example.invalid")) |
    .environments[0].code=($id+"-dev") | .environments[1].code=($id+"-stg") | .environments[2].code=($id+"-prod") |
    .groups[0].code=($id+"-development") | .groups[1].code=($id+"-production") |
    .policies |= map(.code=($id+"-"+.type)) |
    .policies[] |= if .type=="cypher" then .config.keyPattern=("password/24/"+$id+"/*") elif .type=="instance-name" then .config.namingPattern=($id+"-${userInitials}-${sequence}") else . end |
    .automation.inputs[0].fieldName=($id+"Message") |
    .automation.tasks[0].code=($id+"-hello") | .automation.tasks[0].content |= gsub("leroy-demo";$id) |
    .automation.workflows[0].code=($id+"-welcome") | .automation.workflows[0].task=($id+"-hello") | .automation.workflows[0].input=($id+"Message") |
    .automation.catalogItems[0].code=($id+"-catalog") | .automation.catalogItems[0].workflow=($id+"-welcome") | .automation.catalogItems[0].input=($id+"Message") |
    walk(if type=="string" then gsub("Managed by Leroy demo:leroy-demo";"Managed by Leroy demo:"+$id) else . end)
  ')"
  printf '\n%s\n\nSave this manifest to %s? [y/N]: ' "$(jq . <<<"$generated")" "$output"; read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0
  [[ ! -e "$output" ]] || { die "$EXIT_CONFLICT" "file already exists: $output"; return; }
  printf '%s\n' "$generated" | jq -S . >"$output"; chmod 600 "$output"; printf 'Saved %s\n' "$output"
}

status_command() {
  local response
  response="$(api_request GET '/api/whoami' '' "$MASTER_TOKEN")" || return
  if [[ "$LEROY_OUTPUT" == json ]]; then printf '%s\n' "$response"
  else printf 'Connected to %s\n' "$MORPHEUS_URL"; jq -r '"Authenticated as: \(.user.username // .user.displayName // .user.email // "unknown")"' <<<"$response"; fi
}

environments_list() {
  local response; response="$(api_request GET '/api/environments' '' "$MASTER_TOKEN")" || return
  if [[ "$LEROY_OUTPUT" == json ]]; then printf '%s\n' "$response"
  else jq -r '["ID","NAME","CODE","VISIBILITY"],(.environments[]?|[.id,.name,.code,(.visibility//"-")])|@tsv' <<<"$response"; fi
}

environments_get() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || { die "$EXIT_USAGE" 'environment ID must be a positive integer'; return; }
  api_request GET "/api/environments/$1" '' "$MASTER_TOKEN"
}

tui_init_palette() {
  TUI_RESET='' TUI_BOLD='' TUI_DIM='' TUI_ACCENT='' TUI_MUTED=''
  TUI_SUCCESS='' TUI_WARNING='' TUI_DANGER='' TUI_SELECTED=''
  if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
    TUI_RESET=$'\033[0m'; TUI_BOLD=$'\033[1m'; TUI_DIM=$'\033[2m'
    TUI_ACCENT=$'\033[38;5;81m'; TUI_MUTED=$'\033[38;5;245m'
    TUI_SUCCESS=$'\033[38;5;78m'; TUI_WARNING=$'\033[38;5;221m'
    TUI_DANGER=$'\033[38;5;203m'; TUI_SELECTED=$'\033[48;5;24m\033[38;5;231m'
  fi
}

tui_enter_screen() {
  TUI_ACTIVE=true
  printf '\033[?1049h\033[?25l'
}

tui_leave_screen() {
  [[ "$TUI_ACTIVE" == true ]] || return 0
  printf '\033[?25h\033[0m\033[?1049l'
  TUI_ACTIVE=false
}

tui_clear() { printf '\033[2J\033[H'; }

tui_columns() {
  local columns
  columns="$(tput cols 2>/dev/null || printf '80')"
  [[ "$columns" =~ ^[0-9]+$ ]] || columns=80
  ((columns > 0)) || columns=80
  ((columns > 96)) && columns=96
  printf '%s\n' "$columns"
}

tui_crop() {
  local text="$1" width="$2"
  ((width > 0)) || width=1
  if ((${#text} > width)); then
    ((width > 3)) && printf '%s...' "${text:0:width-3}" || printf '%s' "${text:0:width}"
  else
    printf '%s' "$text"
  fi
}

tui_rule() {
  local width="$1" rule
  printf -v rule '%*s' "$width" ''
  printf '%s\n' "${rule// /-}"
}

tui_state_summary() {
  local file="${LEROY_STATE_DIR}/leroy-demo.json" count expected=24
  if [[ ! -r "$file" ]]; then
    printf 'Not created'
    return
  fi
  count="$(jq -r '.resources | length' "$file" 2>/dev/null || printf '?')"
  if [[ "$count" == "$expected" ]]; then printf 'Ready (%s/%s resources)' "$count" "$expected"
  else printf 'Partial (%s/%s resources)' "$count" "$expected"; fi
}

tui_menu_row() {
  local index="$1" selected="$2" width="$3" key label hint lead text available gap
  key="${TUI_KEYS[$index]}"; label="${TUI_LABELS[$index]}"; hint="${TUI_HINTS[$index]}"
  if ((index == selected)); then lead=' > '; else lead='   '; fi
  text="${lead}[${key}] ${label}"
  if ((width >= 76)); then
    available=$((width - ${#text} - ${#hint} - 2))
    ((available < 1)) && available=1
    printf -v gap '%*s' "$available" ''
    text="${text}${gap}${hint}"
  fi
  text="$(tui_crop "$text" "$width")"
  if ((index == selected)); then printf '%s%-*s%s\n' "$TUI_SELECTED" "$width" "$text" "$TUI_RESET"
  else printf '%-*s\n' "$width" "$text"; fi
}

tui_render() {
  local selected="$1" width endpoint state header
  width="$(tui_columns)"; endpoint="${MORPHEUS_URL:-Not configured}"; state="$(tui_state_summary)"
  tui_clear
  header="  LEROY ${LEROY_VERSION}  Morpheus 9 demo builder"
  printf '%s%s%s%s\n' "$TUI_ACCENT" "$TUI_BOLD" "$(tui_crop "$header" "$width")" "$TUI_RESET"
  tui_rule "$width"
  printf '  %-14s %s\n' 'Appliance' "$(tui_crop "$endpoint" "$((width - 18))")"
  printf '  %-14s %s\n' 'Connection' "$TUI_CONNECTION_STATE"
  printf '  %-14s %s\n' 'Demo' "$state"
  printf '  %-14s %s\n' 'Last result' "$(tui_crop "$TUI_LAST_RESULT" "$((width - 18))")"
  tui_rule "$width"
  printf '%s  INSPECT%s\n' "$TUI_MUTED" "$TUI_RESET"
  tui_menu_row 0 "$selected" "$width"
  tui_menu_row 1 "$selected" "$width"
  printf '%s  BUILD%s\n' "$TUI_MUTED" "$TUI_RESET"
  tui_menu_row 2 "$selected" "$width"
  printf '%s  VALIDATE%s\n' "$TUI_MUTED" "$TUI_RESET"
  tui_menu_row 3 "$selected" "$width"
  tui_menu_row 4 "$selected" "$width"
  printf '%s  LIFECYCLE%s\n' "$TUI_MUTED" "$TUI_RESET"
  tui_menu_row 5 "$selected" "$width"
  tui_menu_row 6 "$selected" "$width"
  printf '%s  CONFIGURE%s\n' "$TUI_MUTED" "$TUI_RESET"
  tui_menu_row 7 "$selected" "$width"
  tui_menu_row 8 "$selected" "$width"
  if ((width < 60)); then
    printf '\n%s  j/k move  Enter select  q quit%s\n' "$TUI_DIM" "$TUI_RESET"
  else
    printf '\n%s  Up/Down or j/k move  Enter select  shortcut keys run  q quit%s\n' "$TUI_DIM" "$TUI_RESET"
  fi
}

tui_read_key() {
  local key rest=''
  IFS= read -rsn1 key || key='q'
  if [[ "$key" == $'\033' ]]; then
    IFS= read -rsn2 -t 0.1 rest || true
    case "$rest" in '[A' | OA) key='up' ;; '[B' | OB) key='down' ;; *) key='escape' ;; esac
  elif [[ -z "$key" ]]; then key='enter'
  else key="${key,,}"; fi
  printf '%s\n' "$key"
}

tui_wait() {
  printf '\n%sPress any key to return to the dashboard.%s' "$TUI_DIM" "$TUI_RESET"
  IFS= read -rsn1 _ || true
}

tui_action_header() {
  local title="$1" width
  width="$(tui_columns)"; tui_clear
  printf '%s%s  %s%s\n' "$TUI_ACCENT" "$TUI_BOLD" "$title" "$TUI_RESET"
  tui_rule "$width"
  printf '\n'
}

tui_run_action() {
  local title="$1" rc
  shift; tui_action_header "$title"
  printf '%sRunning...%s\n\n' "$TUI_DIM" "$TUI_RESET"
  if "$@"; then
    rc=0; TUI_LAST_RESULT="Success: $title"
    printf '\n%sCompleted successfully.%s\n' "$TUI_SUCCESS" "$TUI_RESET"
  else
    rc=$?; TUI_LAST_RESULT="Failed ($rc): $title"
    printf '\n%sAction failed with exit code %s.%s\n' "$TUI_DANGER" "$rc" "$TUI_RESET"
  fi
  tui_wait
  return 0
}

tui_status_action() {
  if status_command; then TUI_CONNECTION_STATE='Connected'; return 0; fi
  TUI_CONNECTION_STATE='Connection failed'; return 1
}

tui_plan_action() { manifest_to_temp && demo_plan; }
tui_apply_action() { manifest_to_temp && demo_apply; }
tui_verify_action() { manifest_to_temp && preflight && state_assert_appliance && demo_verify false; }
tui_deep_verify_action() { manifest_to_temp && preflight && state_assert_appliance && demo_verify true; }

tui_confirm() {
  local title="$1" phrase="$2" detail="$3" typed
  tui_action_header "$title"
  printf '%s%s%s\n\n' "$TUI_WARNING" "$detail" "$TUI_RESET"
  printf 'This operation is protected. Type the organization name exactly:\n\n  %s%s%s\n\n> ' "$TUI_BOLD" "$phrase" "$TUI_RESET"
  printf '\033[?25h'; IFS= read -r typed || true; printf '\033[?25l'
  if [[ "$typed" == "$phrase" ]]; then return 0; fi
  TUI_LAST_RESULT="Cancelled: $title"
  printf '\n%sConfirmation did not match. Nothing was changed.%s\n' "$TUI_WARNING" "$TUI_RESET"
  tui_wait
  return 1
}

tui_destroy_action() { demo_destroy leroy-demo true false; }
tui_recreate_action() { demo_destroy leroy-demo true false && manifest_to_temp && demo_apply; }
tui_wizard_action() {
  local rc
  printf '\033[?25h'
  if wizard_manifest; then rc=0; else rc=$?; fi
  printf '\033[?25l'
  return "$rc"
}

run_tui() {
  [[ -t 0 && -t 1 ]] || { die "$EXIT_USAGE" 'TUI requires an interactive terminal'; return; }
  local selected=0 key index
  local -a TUI_KEYS=(s p a v d r x w q)
  local -a TUI_LABELS=('Check connection' 'Preview plan' 'Build default demo' 'Verify structure' 'Deep persona verification' 'Recreate default demo' 'Destroy default demo' 'Create custom manifest' 'Quit')
  local -a TUI_HINTS=('Authenticate and inspect appliance' 'Show intended changes' 'Create or resume 24 resources' 'Check resources and ownership' 'Test RBAC and execute workflow' 'Destroy, then rebuild' 'Remove owned demo resources' 'Guided JSON manifest wizard' 'Return to shell')
  tui_init_palette; tui_enter_screen
  while true; do
    tui_render "$selected"; key="$(tui_read_key)"
    case "$key" in
      up | k) selected=$(((selected + 8) % 9)); continue ;;
      down | j) selected=$(((selected + 1) % 9)); continue ;;
      enter) index="$selected" ;;
      s) index=0 ;; p) index=1 ;; a) index=2 ;; v) index=3 ;; d) index=4 ;;
      r) index=5 ;; x) index=6 ;; w) index=7 ;; q | escape) index=8 ;;
      *) continue ;;
    esac
    selected="$index"
    case "$index" in
      0) tui_run_action 'Connection status' tui_status_action ;;
      1) tui_run_action 'Plan default demo' tui_plan_action ;;
      2) tui_run_action 'Build default demo' tui_apply_action ;;
      3) tui_run_action 'Verify demo structure' tui_verify_action ;;
      4) tui_run_action 'Deep persona verification' tui_deep_verify_action ;;
      5)
        if tui_confirm 'Recreate default demo' 'Leroy Demo Organization' 'All Leroy-owned demo resources will be deleted and rebuilt.'; then
          tui_run_action 'Recreate default demo' tui_recreate_action
        fi
        ;;
      6)
        if tui_confirm 'Destroy default demo' 'Leroy Demo Organization' 'All Leroy-owned demo resources will be permanently deleted.'; then
          tui_run_action 'Destroy default demo' tui_destroy_action
        fi
        ;;
      7) tui_run_action 'Create custom manifest' tui_wizard_action ;;
      8) tui_leave_screen; return 0 ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage:
  leroy.sh [global options] [tui|status]
  leroy.sh [global options] environments {list|get ID}
  leroy.sh demo preset
  leroy.sh demo wizard
  leroy.sh [global options] demo plan|apply|verify [--file FILE] [--deep]
  leroy.sh [global options] demo destroy --demo-id ID --yes [--force]
  leroy.sh [global options] demo recreate [--file FILE] --yes [--force]

Global options: --config FILE, --output table|json, -h|--help, -V|--version
EOF
}

main() {
  local config_file="" output_override="" command="" action="" manifest_file="" demo_id="leroy-demo"
  local yes=false force=false deep=false demo_id_set=false saved_manifest
  while (($#)); do
    case "$1" in
      --config) (($# >= 2)) || return "$EXIT_USAGE"; config_file="$2"; shift 2 ;;
      --output) (($# >= 2)) || return "$EXIT_USAGE"; output_override="$2"; shift 2 ;;
      -h | --help) usage; return 0 ;;
      -V | --version) printf 'leroy %s\n' "$LEROY_VERSION"; return 0 ;;
      *) break ;;
    esac
  done
  command="${1:-tui}"; [[ $# -eq 0 ]] || shift

  if [[ "$command" == demo ]]; then
    action="${1:-}"; [[ $# -eq 0 ]] || shift
    while (($#)); do
      case "$1" in
        --file) (($# >= 2)) || { die "$EXIT_USAGE" '--file requires a path'; return; }; manifest_file="$2"; shift 2 ;;
        --demo-id) (($# >= 2)) || { die "$EXIT_USAGE" '--demo-id requires a value'; return; }; demo_id="$2"; demo_id_set=true; shift 2 ;;
        --yes) yes=true; shift ;;
        --force) force=true; shift ;;
        --deep) deep=true; shift ;;
        *) die "$EXIT_USAGE" "unknown demo option: $1"; return ;;
      esac
    done
    case "$action" in
      preset) require_command jq; preset_manifest | jq -S .; return ;;
      wizard) require_command jq; wizard_manifest; return ;;
    esac
  fi

  load_config "$config_file" || return
  [[ -z "$output_override" ]] || LEROY_OUTPUT="$output_override"
  validate_runtime_config || return

  case "$command" in
    tui) run_tui ;;
    status) status_command ;;
    environments)
      case "${1:-}" in list) environments_list ;; get) environments_get "${2:-}" ;; *) die "$EXIT_USAGE" 'usage: leroy.sh environments {list|get ID}' ;; esac
      ;;
    demo)
      case "$action" in
        plan) manifest_to_temp "$manifest_file"; demo_plan ;;
        apply) manifest_to_temp "$manifest_file"; demo_apply ;;
        verify) manifest_to_temp "$manifest_file"; preflight; state_assert_appliance; demo_verify "$deep" ;;
        destroy) [[ "$demo_id_set" == true ]] || { die "$EXIT_USAGE" 'destroy requires --demo-id ID'; return; }; demo_destroy "$demo_id" "$yes" "$force" ;;
        recreate)
          [[ "$yes" == true ]] || { die "$EXIT_USAGE" 'recreate requires --yes'; return; }
          manifest_to_temp "$manifest_file"; saved_manifest="$(command cat "$CURRENT_MANIFEST")"; demo_id="$CURRENT_DEMO_ID"
          demo_destroy "$demo_id" true "$force" || return
          CURRENT_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/leroy-manifest.XXXXXX")"; printf '%s\n' "$saved_manifest" >"$CURRENT_MANIFEST"
          CURRENT_DEMO_ID="$demo_id"; CURRENT_MARKER="Managed by Leroy demo:${demo_id}"; STATE_FILE="${LEROY_STATE_DIR}/${demo_id}.json"
          demo_apply
          ;;
        *) die "$EXIT_USAGE" 'usage: leroy.sh demo {preset|wizard|plan|apply|verify|destroy|recreate}' ;;
      esac
      ;;
    *) die "$EXIT_USAGE" "unknown command: $command" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
