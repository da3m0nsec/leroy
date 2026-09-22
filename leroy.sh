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
MORPHEUS_VERIFY_TLS="${MORPHEUS_VERIFY_TLS:-false}"
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
VERIFY_RESULTS=""
TEMP_TOKEN_USERS=()
TEMP_TOKEN_IDS=()
TUI_ACTIVE=false
TUI_FEATURES_JSON=""
TUI_MANIFEST_FILE=""
TUI_MANIFEST_LABEL="Built-in preset"
TUI_MANIFEST_ORIGIN=""
TUI_MANIFEST_KIND="preset"
TUI_STATE_FILE=""
TUI_DEMO_ID=""
TUI_DEMO_NAME=""
TUI_RESOURCE_COUNT="0"
TUI_IDENTITY=""
TUI_BUILD=""
TUI_CONNECTION_STATE="Not checked"
TUI_LAST_RESULT="No actions run in this session"
TUI_LAST_RC=0
TUI_LAST_FORCEABLE=false
TUI_MANIFEST_TEMP=""
LAST_WIZARD_FILE=""
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
  [[ -z "$VERIFY_RESULTS" ]] || rm -f "$VERIFY_RESULTS"
  [[ -z "$TUI_MANIFEST_TEMP" ]] || rm -f "$TUI_MANIFEST_TEMP"
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

# Reads KEY=VALUE settings from a project-local environment file. The file is
# parsed, never sourced: it is picked up from the working directory, so it must
# not be able to execute anything. Only Leroy's own settings are honored, and
# everything else in the file is ignored.
load_env_file() {
  local file="$1" line key value loaded=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" && "$line" != '#'* ]] || continue
    line="${line#export }"
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
      '"'*'"') value="${value:1:${#value}-2}" ;;
      "'"*"'") value="${value:1:${#value}-2}" ;;
      *) value="${value%"${value##*[![:space:]]}"}" ;;
    esac
    case "$key" in
      MORPHEUS_URL | MORPHEUS_API_TOKEN | MORPHEUS_VERIFY_TLS | MORPHEUS_CONNECT_TIMEOUT | \
        MORPHEUS_REQUEST_TIMEOUT | LEROY_OUTPUT | LEROY_LOG_LEVEL | LEROY_STATE_DIR)
        printf -v "$key" '%s' "$value"
        loaded=$((loaded + 1))
        ;;
    esac
  done <"$file"
  ((loaded == 0)) || log_info "loaded $loaded setting(s) from $file"
}

load_config() {
  local explicit="${1:-}" default="${XDG_CONFIG_HOME:-${HOME}/.config}/leroy/config"
  local env_file="${LEROY_ENV_FILE-.env}"
  local e_url="$MORPHEUS_URL" e_token="$MORPHEUS_API_TOKEN" e_tls="$MORPHEUS_VERIFY_TLS"
  local e_connect="$MORPHEUS_CONNECT_TIMEOUT" e_request="$MORPHEUS_REQUEST_TIMEOUT"
  local e_output="$LEROY_OUTPUT" e_log="$LEROY_LOG_LEVEL" e_state="$LEROY_STATE_DIR"
  [[ -z "$env_file" || ! -r "$env_file" ]] || load_env_file "$env_file"
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

prompt_runtime_config() {
  if [[ -z "$MORPHEUS_URL" ]]; then
    printf 'Morpheus appliance URL: ' >&2
    IFS= read -r MORPHEUS_URL || { die "$EXIT_USAGE" 'Morpheus appliance URL is required'; return; }
  fi
  if [[ -z "$MORPHEUS_API_TOKEN" ]]; then
    printf 'Morpheus API token (input hidden): ' >&2
    if ! IFS= read -rs MORPHEUS_API_TOKEN; then
      printf '\n' >&2
      die "$EXIT_USAGE" 'Morpheus API token is required'
      return
    fi
    printf '\n' >&2
  fi
  MORPHEUS_URL="${MORPHEUS_URL%/}"
  MASTER_TOKEN="$MORPHEUS_API_TOKEN"
}

prompt_missing_runtime_config() {
  [[ -z "$MORPHEUS_URL" || -z "$MORPHEUS_API_TOKEN" ]] || return 0
  [[ -t 0 && -t 1 ]] || return 0
  printf 'Leroy is not configured yet. Enter connection details for this session.\n' >&2
  prompt_runtime_config
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

# Fetches a complete Morpheus collection. Morpheus answers list endpoints one
# page at a time, so every consumer follows max/offset instead of trusting that
# a single response body holds every record. The collection key is detected from
# the first page when the caller does not name it.
api_collection() {
  local path="$1" key="${2:-}" token="${3:-$MASTER_TOKEN}"
  local offset=0 page items count total source_key="$key" merged='[]' separator='&'
  local -r max=100 limit=10000
  [[ "$path" == *'?'* ]] || separator='?'
  while true; do
    page="$(api_request GET "${path}${separator}max=${max}&offset=${offset}" '' "$token")" || return
    if [[ -z "$source_key" ]] || ! jq -e --arg key "$source_key" '(.[$key] // null) | type == "array"' <<<"$page" >/dev/null; then
      source_key="$(jq -r 'to_entries | map(select((.key != "meta") and (.value | type == "array"))) | .[0].key // empty' <<<"$page")"
      [[ -n "$source_key" ]] || { printf '%s\n' "$page"; return 0; }
      [[ -n "$key" ]] || key="$source_key"
    fi
    items="$(jq -c --arg key "$source_key" '.[$key] // []' <<<"$page")"
    count="$(jq 'length' <<<"$items")"
    merged="$(jq -nc --argjson merged "$merged" --argjson items "$items" '$merged + $items')"
    total="$(jq -r '.meta.total // empty' <<<"$page")"
    ((count == max)) || break
    offset=$((offset + max))
    [[ ! "$total" =~ ^[0-9]+$ ]] || ((offset < total)) || break
    ((offset <= limit)) || { log_warn "collection truncated at ${limit} records: ${path}"; break; }
  done
  jq -nc --arg key "$key" --argjson items "$merged" '{($key): $items, meta: {total: ($items | length)}}'
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
    features: {multitenancy:true, roles:true, environments:true, groups:true, policies:true, automation:true, catalog:true},
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

# Schema 2 equivalent of the built-in demo. The permission rules and the access
# checks that schema 1 keeps inside this script become manifest data here, which
# is what lets the builder edit them.
preset_manifest_v2() {
  preset_manifest | jq '
    .schemaVersion = 2 |
    .personas = [
      (.personas[] | select(.key == "admin") + {
        permissions: [],
        verify: {allow: "/api/whoami"},
        catalogAccess: true
      }),
      (.personas[] | select(.key == "operator") + {
        permissions: [
          {pattern: "provisioning.*instances|instances[[:space:]]*$|provisioning.*apps|provisioning.*tasks|tasks.*script engines|library", access: "source"},
          {pattern: "infrastructure", access: "source"}
        ],
        verify: {allow: "/api/tasks?max=1"},
        catalogAccess: true,
        runsWorkflow: true
      }),
      (.personas[] | select(.key == "consumer") + {
        permissions: [{pattern: "catalog|service catalog", access: "source"}],
        verify: {allow: "/api/catalog-item-types?max=1", deny: "/api/tasks?max=1"},
        catalogAccess: true
      })
    ]
  '
}

feature_defaults() {
  jq -nc '{multitenancy:true,roles:true,environments:true,groups:true,policies:true,automation:true,catalog:true}'
}

feature_total() { feature_defaults | jq -r 'length'; }

manifest_features() {
  local file="$1"
  jq -c --argjson defaults "$(feature_defaults)" '$defaults * (.features // {})' "$file"
}

feature_enabled() {
  local key="$1"
  jq -e --arg key "$key" --argjson defaults "$(feature_defaults)" '($defaults * (.features // {}))[$key] == true' "$CURRENT_MANIFEST" >/dev/null
}

deployment_scope() {
  if feature_enabled multitenancy; then printf 'tenant'; else printf 'master'; fi
}

# Feature-flag rules are identical in both schema versions. $features is a jq
# variable bound by the caller, not a shell expansion.
# shellcheck disable=SC2016
FEATURE_RULES_JQ='
  ([ $features[] ] | all(type == "boolean")) and
  ($features.roles == $features.multitenancy) and
  ($features.policies == false or $features.groups == true) and
  ($features.catalog == false or $features.automation == true)
'
IDENTITY_RULES_JQ='
  (.metadata.id | test("^[a-z][a-z0-9-]{2,40}$")) and
  (.metadata.name | length > 0) and .metadata.language == "en" and
  (.tenant.name | length > 0) and (.tenant.subdomain | test("^[a-z][a-z0-9-]+$")) and
  (.environments | type == "array") and (.groups | type == "array") and
  (.policies | type == "array") and (.automation | type == "object")
'
readonly FEATURE_RULES_JQ IDENTITY_RULES_JQ

# Schema 1 fixes the persona set: three personas with known keys and profiles,
# whose permissions and verification paths live in this script.
validate_manifest_v1() {
  jq -e --argjson defaults "$(feature_defaults)" "
    (\$defaults * (.features // {})) as \$features |
    .schemaVersion == 1 and
    ${IDENTITY_RULES_JQ} and
    (.personas | length == 3) and
    ([.personas[].key] | sort == [\"admin\",\"consumer\",\"operator\"]) and
    ([.personas[].profile] | sort == [\"platform-operator\",\"service-consumer\",\"tenant-admin\"]) and
    ([.personas[].username] | unique | length == 3) and
    ${FEATURE_RULES_JQ}
  " "$1" >/dev/null
}

# Schema 2 lets the manifest carry its own personas, their Morpheus permission
# rules, and the access each one must and must not have. A tenant administrator
# is still required whenever persona roles are deployed, because the tenant
# token is obtained by logging in as that persona.
validate_manifest_v2() {
  jq -e --argjson defaults "$(feature_defaults)" "
    (\$defaults * (.features // {})) as \$features |
    .schemaVersion == 2 and
    ${IDENTITY_RULES_JQ} and
    (.personas | type == \"array\") and (.personas | length >= 1) and
    all(.personas[];
      (.key | type) == \"string\" and (.key | test(\"^[a-z][a-z0-9-]{0,30}\$\")) and
      (.role | type) == \"string\" and (.role | length) > 0 and
      (.username | type) == \"string\" and (.username | length) > 0 and
      (.email | type) == \"string\" and (.email | length) > 0 and
      (.profile | type) == \"string\" and (.profile | length) > 0) and
    ([.personas[].key] | unique | length) == (.personas | length) and
    ([.personas[].username] | unique | length) == (.personas | length) and
    (\$features.roles == false or ([.personas[] | select(.profile == \"tenant-admin\")] | length) == 1) and
    ([.personas[] | select(.runsWorkflow == true)] | length) <= 1 and
    all(.personas[] | (.permissions // [])[];
      (.pattern | type) == \"string\" and (.pattern | length) > 0 and
      (.access | type) == \"string\" and (.access | length) > 0) and
    all(.personas[] | select(has(\"verify\")) | .verify;
      (.allow | type) == \"string\" and (.allow | startswith(\"/api/\")) and
      ((.deny // \"\") | type) == \"string\") and
    ${FEATURE_RULES_JQ}
  " "$1" >/dev/null
}

validate_manifest() {
  local file="$1" version
  version="$(jq -r '.schemaVersion // empty' "$file" 2>/dev/null || true)"
  case "$version" in
    1) validate_manifest_v1 "$file" || { die "$EXIT_USAGE" 'manifest is invalid for schema version 1'; return; } ;;
    2) validate_manifest_v2 "$file" || { die "$EXIT_USAGE" 'manifest is invalid for schema version 2'; return; } ;;
    *) die "$EXIT_USAGE" 'manifest is invalid or uses an unsupported schema'; return ;;
  esac
  if jq -e '[.. | objects | keys[]] | any(. == "password" or . == "token" or . == "access_token")' "$file" >/dev/null; then
    die "$EXIT_USAGE" 'manifest must not contain passwords or tokens'; return
  fi
}

# Persona lookups. Every one of these reduces to the schema 1 arrangement when
# the manifest does not state a preference, so v1 deployments are unaffected.
persona_permissions() {
  jq -c --arg key "$1" '[.personas[] | select(.key == $key) | .permissions // []] | first // []' "$CURRENT_MANIFEST" 2>/dev/null || printf '[]\n'
}

tenant_admin_key() {
  jq -r '([.personas[] | select(.profile == "tenant-admin")][0].key) // "admin"' "$CURRENT_MANIFEST" 2>/dev/null || printf 'admin\n'
}

catalog_persona_keys() {
  jq -r '.personas[] | select(.catalogAccess != false) | .key' "$CURRENT_MANIFEST" 2>/dev/null || true
}

# The persona that executes the demonstration workflow: whichever one asks for
# it, else the operator that schema 1 always defines.
workflow_persona() {
  jq -c '
    ([.personas[] | select(.runsWorkflow == true)] +
     [.personas[] | select(.key == "operator")] +
     [.personas[] | select(.profile == "platform-operator")])[0] // empty
  ' "$CURRENT_MANIFEST" 2>/dev/null || true
}

manifest_to_temp() {
  local source="${1:-}"
  [[ -z "$CURRENT_MANIFEST" || ! -f "$CURRENT_MANIFEST" ]] || rm -f "$CURRENT_MANIFEST"
  CURRENT_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/leroy-manifest.XXXXXX")" || return "$EXIT_API"
  if [[ -n "$source" ]]; then jq -S . "$source" >"$CURRENT_MANIFEST"; else preset_manifest | jq -S . >"$CURRENT_MANIFEST"; fi
  if [[ -n "$TUI_FEATURES_JSON" ]]; then
    jq -S --argjson features "$TUI_FEATURES_JSON" '.features=$features' "$CURRENT_MANIFEST" >"${CURRENT_MANIFEST}.selected"
    mv -f "${CURRENT_MANIFEST}.selected" "$CURRENT_MANIFEST"
  fi
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

state_assert_features() {
  local wanted saved defaults
  [[ ! -f "$STATE_FILE" ]] && return 0
  defaults="$(feature_defaults)"
  wanted="$(manifest_features "$CURRENT_MANIFEST" | jq -Sc .)"
  saved="$(jq -Sc --argjson defaults "$defaults" '$defaults * (.manifest.features // {})' "$STATE_FILE")"
  [[ "$wanted" == "$saved" ]] || { die "$EXIT_CONFLICT" 'deployment component selection differs from existing state; use recreate to apply the new selection'; return; }
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
  local -a capabilities=()
  whoami="$(api_request GET '/api/whoami' '' "$MASTER_TOKEN")" || return
  jq -e '.isMasterAccount == true' <<<"$whoami" >/dev/null || { die "$EXIT_AUTH" 'a Master Tenant administrator token is required'; return; }
  version="$(jq -r '[.. | objects | (.buildVersion?,.applianceVersion?,.version?)] | map(select(type=="string" and test("^9([. -]|$)"))) | first // empty' <<<"$whoami")"
  [[ -n "$version" ]] || { die "$EXIT_VERIFY" 'Morpheus major version 9 is required'; return; }
  APPLIANCE_BUILD="$version"
  if feature_enabled roles; then
    roles="$(api_collection '/api/roles?includeDefaultAccess=true' roles "$MASTER_TOKEN")" || return
    BASE_ACCOUNT_ROLE_ID="$(jq -r '[.. | objects | select((.roleType? == "account") and (.name? | test("Tenant Admin|Account Admin";"i")))][0].id // empty' <<<"$roles")"
    BASE_USER_ROLE_ID="$(jq -r '[.. | objects | select((.roleType? == "user") and (.name? | test("Admin";"i")))][0].id // empty' <<<"$roles")"
    [[ -n "$BASE_ACCOUNT_ROLE_ID" && -n "$BASE_USER_ROLE_ID" ]] || { die "$EXIT_VERIFY" 'required built-in Morpheus 9 base roles were not found'; return; }
    capabilities+=(accounts cypher)
  fi
  feature_enabled environments && capabilities+=(environments)
  feature_enabled groups && capabilities+=(groups)
  feature_enabled policies && capabilities+=(policies policy-types)
  feature_enabled automation && capabilities+=(tasks task-sets library/option-types)
  feature_enabled catalog && capabilities+=(catalog-item-types)
  for capability in "${capabilities[@]}"; do
    api_request GET "/api/${capability}?max=1" '' "$MASTER_TOKEN" >/dev/null || { die "$EXIT_VERIFY" "required API capability is unavailable: $capability"; return; }
  done
  export BASE_ACCOUNT_ROLE_ID BASE_USER_ROLE_ID
}

RESOURCE_STREAM_JQ="$(
  cat <<'JQ'
. as $root |
({multitenancy:true,roles:true,environments:true,groups:true,policies:true,automation:true,catalog:true} * (.features // {})) as $features |
(if $features.multitenancy then "tenant" else "master" end) as $scope |
(if $features.multitenancy then
  {key:"role:tenant",type:"role",scope:"master",name:(.metadata.name+" Tenant Role"),spec:{kind:"account",profile:"tenant-root"}},
  {key:"tenant",type:"tenant",scope:"master",name:.tenant.name,spec:.tenant}
else empty end),
(if $features.roles then
  (.personas[] | {key:("role:"+.key),type:"role",scope:"master",name:.role,spec:{kind:"user",profile:.profile}}),
  (.personas[] | {key:("cypher:"+.key),type:"cypher",scope:"master",name:.username,spec:{path:("password/24/"+$root.metadata.id+"/"+.username)}}),
  (.personas[] | {key:("user:"+.key),type:"user",scope:"master",name:.username,spec:.})
else empty end),
(if $features.environments then (.environments[] | {key:("environment:"+.code),type:"environment",scope:$scope,name:.name,spec:.}) else empty end),
(if $features.groups then (.groups[] | {key:("group:"+.code),type:"group",scope:$scope,name:.name,spec:.}) else empty end),
(if $features.policies then (.policies[] | {key:("policy:"+.code),type:"policy",scope:$scope,name:.name,spec:.}) else empty end),
(if $features.automation then
  (.automation.inputs[] | {key:("input:"+.fieldName),type:"input",scope:$scope,name:.name,spec:.}),
  (.automation.tasks[] | {key:("task:"+.code),type:"task",scope:$scope,name:.name,spec:.}),
  (.automation.workflows[] | {key:("workflow:"+.code),type:"workflow",scope:$scope,name:.name,spec:.})
else empty end),
(if $features.catalog then (.automation.catalogItems[] | {key:("catalog:"+.code),type:"catalog",scope:$scope,name:.name,spec:.}) else empty end)
JQ
)"
readonly RESOURCE_STREAM_JQ

resource_stream() { jq -c "$RESOURCE_STREAM_JQ" "$CURRENT_MANIFEST"; }

# Counts the resources a manifest expands to. The manifest JSON is read from
# standard input so the same rule serves a live manifest and a saved state file.
resource_count() { jq -c "$RESOURCE_STREAM_JQ" | wc -l | tr -d ' \n'; }

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
  response="$(api_request GET "/api/cypher?list=true&key=$(urlencode "$path")" '' "$MASTER_TOKEN")" || return
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

# Decides whether a resource that failed the ownership check still looks like
# Leroy's, which is what --force is allowed to delete. The tostring arm must be
# parenthesized: piping into it hides every other value from the name check.
remote_has_leroy_identity() {
  local prefix
  prefix="$(jq -r '.metadata.prefix // empty' "$CURRENT_MANIFEST" 2>/dev/null || true)"
  [[ -n "$prefix" && "$prefix" != null ]] || prefix='leroy-'
  jq -e --arg prefix "$prefix" '
    (tostring | contains("Managed by Leroy demo:")) or
    ([.. | strings] | any(startswith($prefix)))
  ' <<<"$1" >/dev/null
}

find_remote() {
  local spec="$1" type scope name path token response encoded
  type="$(jq -r '.type' <<<"$spec")"; scope="$(jq -r '.scope' <<<"$spec")"; name="$(jq -r '.name' <<<"$spec")"
  if [[ "$type" == cypher ]]; then cypher_find "$(jq -r '.spec.path' <<<"$spec")" 2>/dev/null || true; return; fi
  path="$(resource_path "$type")"; token="$(resource_token "$scope")"; encoded="$(urlencode "$name")"
  response="$(api_collection "${path}?name=${encoded}" '' "$token" 2>/dev/null)" || return 0
  jq -c --arg name "$name" '[.. | objects | select(.id? and ((.name?==$name) or (.username?==$name) or (.code?==$name)))][0] // empty' <<<"$response"
}

role_permissions() {
  case "$1" in
    platform-operator) jq -nc '[{pattern:"provisioning.*instances|instances[[:space:]]*$|provisioning.*apps|provisioning.*tasks|tasks.*script engines|library",access:"source"},{pattern:"infrastructure",access:"source"}]' ;;
    service-consumer) jq -nc '[{pattern:"catalog|service catalog",access:"source"}]' ;;
    *) printf '[]\n' ;;
  esac
}

configure_role_permissions() {
  local profile="$1" role_id="$2" persona="${3:-}" rules available rule pattern access matches permission code effective_access
  rules='[]'
  [[ -z "$persona" ]] || rules="$(persona_permissions "$persona")"
  [[ "$(jq 'length' <<<"$rules")" -gt 0 ]] || rules="$(role_permissions "$profile")"
  [[ "$(jq 'length' <<<"$rules")" -gt 0 ]] || return 0
  available="$(api_request GET "/api/roles/${BASE_USER_ROLE_ID}?includeDefaultAccess=true" '' "$MASTER_TOKEN")" || return
  while IFS= read -r rule; do
    pattern="$(jq -r '.pattern' <<<"$rule")"; access="$(jq -r '.access' <<<"$rule")"
    matches="$(jq -c --arg pattern "$pattern" '[.. | objects | select(.code? and (((.name? // "")+" "+.code) | test($pattern;"i")))] | unique_by(.code)[]' <<<"$available")"
    [[ -n "$matches" ]] || { die "$EXIT_VERIFY" "no Morpheus permission matched $profile rule: $pattern"; return; }
    while IFS= read -r permission; do
      code="$(jq -r '.code' <<<"$permission")"
      if [[ "$access" == source ]]; then effective_access="$(jq -r '.access // "full"' <<<"$permission")"; else effective_access="$access"; fi
      api_request PUT "/api/roles/${role_id}/update-permission" "$(jq -nc --arg code "$code" --arg access "$effective_access" '{permissionCode:$code,access:$access}')" "$MASTER_TOKEN" >/dev/null || return
    done <<<"$matches"
  done < <(jq -c '.[]' <<<"$rules")
}

configure_catalog_access() {
  local catalog_id="$1" role_key role_id
  feature_enabled roles || return 0
  while IFS= read -r role_key; do
    [[ -n "$role_key" ]] || continue
    role_id="$(resource_id "role:${role_key}")"
    [[ -n "$role_id" ]] || { die "$EXIT_PARTIAL" "catalog access role is not ready: $role_key"; return; }
    api_request PUT "/api/roles/${role_id}/update-catalog-item-type" "$(jq -nc --argjson id "$catalog_id" '{catalogItemTypeId:$id,access:"full"}')" "$MASTER_TOKEN" >/dev/null || return
  done < <(catalog_persona_keys)
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
  response="$(api_collection '/api/policy-types' '' "$(resource_token "$(deployment_scope)")")" || return
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
      jq -n --argjson value "$logical" --arg marker "$marker" --arg account "$tenant_id" --argjson policyType "$policy_type" --argjson groups "$group_ids" '{policy:({name:$value.name,code:$value.code,description:$marker,policyType:$policyType,sites:(if $value.scope=="groups" then $groups else [] end),config:$value.config} + (if $account=="" then {} else {account:{id:($account|tonumber)}} end))}'
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
  local cypher_path password username subdomain login tokens admin_key
  admin_key="$(tenant_admin_key)"
  cypher_path="$(resource_id "cypher:${admin_key}")"; TENANT_ADMIN_USER_ID="$(resource_id "user:${admin_key}")"
  [[ -n "$cypher_path" && -n "$TENANT_ADMIN_USER_ID" ]] || { die "$EXIT_PARTIAL" 'tenant administrator is not ready; rerun apply'; return; }
  password="$(api_request GET "/api/cypher/${cypher_path}" '' "$MASTER_TOKEN" | jq -r '.data // .cypher.data // empty')"
  username="$(jq -r --arg key "$admin_key" '.personas[] | select(.key == $key) | .username' "$CURRENT_MANIFEST")"
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
  if [[ -z "$found" ]]; then printf 'create'
  elif [[ "$type" == cypher ]] && remote_is_owned "$type" "$found" "$(jq -r '.spec.path' <<<"$spec")"; then printf 'adopt'
  else printf 'conflict'
  fi
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
  state_assert_features || return
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
        if [[ "$type" == role ]]; then configure_role_permissions "$(jq -r '.spec.profile' <<<"$spec")" "$id" "$(jq -r '.key | sub("^role:"; "")' <<<"$spec")" || return; fi
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
  if [[ "$type" == role ]]; then configure_role_permissions "$(jq -r '.spec.profile' <<<"$spec")" "$id" "$(jq -r '.key | sub("^role:"; "")' <<<"$spec")" || return; fi
  if [[ "$type" == catalog ]]; then configure_catalog_access "$id" || return; fi
  if [[ "$type" == role || "$type" == catalog ]]; then state_record "$(jq '.configured=true' <<<"$entry")"; fi
  log_info "$action $type: $name"
}

demo_apply() {
  local spec current apply_rc
  preflight || return
  state_assert_appliance || return
  state_assert_features || return
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
  select_state "$demo_id" || return
  [[ -r "$STATE_FILE" ]] || { die "$EXIT_NOT_FOUND" "state not found for demo: $demo_id"; return; }
  state_assert_appliance || return
  CURRENT_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/leroy-manifest.XXXXXX")"; jq -S '.manifest' "$STATE_FILE" >"$CURRENT_MANIFEST"
  state_name="$(jq -r '.manifest.metadata.name' "$STATE_FILE")"
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

# Appends one verification outcome. Results are collected in a file so the
# report can list every check instead of only a failure count.
verify_record() {
  local check="$1" target="$2" status="$3" detail="${4:-}"
  jq -nc --arg check "$check" --arg target "$target" --arg status "$status" --arg detail "$detail" \
    '{check:$check,target:$target,status:$status,detail:$detail}' >>"$VERIFY_RESULTS"
  [[ "$status" != fail ]] || log_error "${check} ${target}${detail:+: $detail}"
}

verify_failures() { jq -s '[.[] | select(.status == "fail")] | length' "$VERIFY_RESULTS"; }

emit_verify_report() {
  local deep="$1" failed total
  failed="$(verify_failures)"; total="$(jq -s 'length' "$VERIFY_RESULTS")"
  if [[ "$LEROY_OUTPUT" == json ]]; then
    jq -s --arg id "$CURRENT_DEMO_ID" --argjson deep "$deep" '{
      verified: all(.[]; .status != "fail"),
      demoId: $id, deep: $deep,
      checked: length, failed: ([.[] | select(.status == "fail")] | length),
      checks: .
    }' "$VERIFY_RESULTS"
  else
    printf '%-7s %-10s %s\n' RESULT CHECK TARGET
    jq -r '[.status,.check,.target,.detail] | @tsv' "$VERIFY_RESULTS" |
      while IFS=$'\t' read -r status check target detail; do
        printf '%-7s %-10s %s\n' "$status" "$check" "${target}${detail:+ (${detail})}"
      done
    printf '%s checks, %s failed%s\n' "$total" "$failed" "$([[ "$deep" == true ]] && printf ' (deep)')"
  fi
}

verify_persona() {
  local persona="$1" key username subdomain cypher_path password login token token_id user_id allowed_path denied_path=''
  key="$(jq -r '.key' <<<"$persona")"; username="$(jq -r '.username' <<<"$persona")"; subdomain="$(jq -r '.tenant.subdomain' "$CURRENT_MANIFEST")"
  cypher_path="$(resource_id "cypher:${key}")"; user_id="$(resource_id "user:${key}")"
  password="$(api_request GET "/api/cypher/${cypher_path}" '' "$MASTER_TOKEN" 2>/dev/null | jq -r '.data // .cypher.data // empty' || true)"
  if [[ -z "$password" ]]; then verify_record persona "$username" fail 'generated password is unavailable'; return 0; fi
  if ! login="$(oauth_login "${subdomain}\\${username}" "$password" 2>/dev/null)"; then
    verify_record persona "$username" fail 'temporary persona login failed'; return 0
  fi
  token="$(jq -r '.access_token' <<<"$login")"; token_id="$(jq -r '.id // .token.id // empty' <<<"$login")"
  TEMP_TOKEN_USERS+=("$user_id"); TEMP_TOKEN_IDS+=("$token_id")
  [[ -n "$token_id" ]] || token_id="$(find_token_id "$user_id")"
  TEMP_TOKEN_IDS[${#TEMP_TOKEN_IDS[@]} - 1]="$token_id"
  if jq -e 'has("verify")' <<<"$persona" >/dev/null 2>&1; then
    allowed_path="$(jq -r '.verify.allow // "/api/whoami"' <<<"$persona")"
    denied_path="$(jq -r '.verify.deny // empty' <<<"$persona")"
  else
    case "$key" in
      operator) allowed_path='/api/tasks?max=1' ;;
      consumer) allowed_path='/api/catalog-item-types?max=1'; denied_path='/api/tasks?max=1' ;;
      *) allowed_path='/api/whoami' ;;
    esac
  fi
  if ! api_request GET "$allowed_path" '' "$token" >/dev/null 2>&1; then
    verify_record persona "$username" fail "expected access was denied: $allowed_path"
  elif [[ -n "$denied_path" ]] && api_request GET "$denied_path" '' "$token" >/dev/null 2>&1; then
    verify_record persona "$username" fail "access that must be denied is allowed: $denied_path"
  else
    verify_record persona "$username" pass "$allowed_path"
  fi
  revoke_token "$token_id" "$user_id"
}

demo_verify() {
  local deep="${1:-false}" entry remote expected type name failures workflow_id result persona execution_token
  local operator op_key op_path op_password op_login op_token_id="" op_user="" workflow_code
  [[ -r "$STATE_FILE" ]] || { die "$EXIT_NOT_FOUND" 'demo state does not exist'; return; }
  state_assert_appliance || return
  VERIFY_RESULTS="$(mktemp "${TMPDIR:-/tmp}/leroy-verify.XXXXXX")" || return "$EXIT_API"
  : >"$VERIFY_RESULTS"
  if jq -e --slurpfile manifest "$CURRENT_MANIFEST" '.manifest == $manifest[0]' "$STATE_FILE" >/dev/null; then
    verify_record manifest "$CURRENT_DEMO_ID" pass
  else
    verify_record manifest "$CURRENT_DEMO_ID" fail 'state manifest differs from the requested manifest'
  fi
  while IFS= read -r entry; do
    type="$(jq -r '.type' <<<"$entry")"; name="$(jq -r '.name' <<<"$entry")"
    if ! remote="$(resource_get "$entry" 2>/dev/null)"; then
      verify_record resource "${type}:${name}" fail 'resource is missing on the appliance'; continue
    fi
    expected="$(jq -r '.spec.path // .name' <<<"$entry")"
    if remote_is_owned "$type" "$remote" "$expected"; then
      verify_record resource "${type}:${name}" pass
    else
      verify_record resource "${type}:${name}" fail 'ownership marker does not match'
    fi
  done < <(jq -c '.resources[]' "$STATE_FILE")
  failures="$(verify_failures)"
  if [[ "$deep" == true ]] && ((failures == 0)); then
    if feature_enabled roles; then
      while IFS= read -r persona; do verify_persona "$persona"; done < <(jq -c '.personas[]' "$CURRENT_MANIFEST")
    fi
    if feature_enabled automation && (($(verify_failures) == 0)); then
      execution_token="$MASTER_TOKEN"
      workflow_code="$(jq -r '.automation.workflows[0].code' "$CURRENT_MANIFEST")"
      if feature_enabled roles; then
        operator="$(workflow_persona)"
        if [[ -z "$operator" ]]; then
          op_login="skipped"
        else
        op_key="$(jq -r '.key' <<<"$operator")"; op_path="$(resource_id "cypher:${op_key}")"; op_user="$(resource_id "user:${op_key}")"
        op_password="$(api_request GET "/api/cypher/${op_path}" '' "$MASTER_TOKEN" 2>/dev/null | jq -r '.data // .cypher.data // empty' || true)"
        if ! op_login="$(oauth_login "$(jq -r '.tenant.subdomain' "$CURRENT_MANIFEST")\\$(jq -r '.username' <<<"$operator")" "$op_password" 2>/dev/null)"; then
          verify_record workflow "$workflow_code" fail 'operator login for workflow execution failed'
          op_login=""
        else
          execution_token="$(jq -r '.access_token' <<<"$op_login")"; op_token_id="$(jq -r '.id // .token.id // empty' <<<"$op_login")"; [[ -n "$op_token_id" ]] || op_token_id="$(find_token_id "$op_user")"
          TEMP_TOKEN_USERS+=("$op_user"); TEMP_TOKEN_IDS+=("$op_token_id")
        fi
        fi
      else
        op_login="skipped"
      fi
      if [[ -n "$op_login" ]]; then
        workflow_id="$(resource_id "workflow:${workflow_code}")"
        result="$(api_request POST "/api/task-sets/${workflow_id}/execute" '{"job":{"customOptions":{"demoMessage":"Verified by Leroy"}}}' "$execution_token" 2>/dev/null || true)"
        if jq -e '.success != false' <<<"${result:-null}" >/dev/null 2>&1; then
          verify_record workflow "$workflow_code" pass 'executed as the operator persona'
        else
          verify_record workflow "$workflow_code" fail 'workflow execution was rejected'
        fi
      fi
      [[ -z "$op_token_id" ]] || revoke_token "$op_token_id" "$op_user"
    fi
  elif [[ "$deep" == true ]]; then
    verify_record deep "$CURRENT_DEMO_ID" skip 'structural checks failed first'
  fi
  emit_verify_report "$deep"
  failures="$(verify_failures)"
  rm -f "$VERIFY_RESULTS"; VERIFY_RESULTS=""
  ((failures == 0)) || { die "$EXIT_VERIFY" "$failures verification check(s) failed"; return; }
}

# Points the lifecycle globals at a saved deployment without loading a manifest
# from disk, so read-only commands can inspect recorded state.
select_state() {
  local demo_id="$1"
  [[ "$demo_id" =~ ^[a-z][a-z0-9-]{2,40}$ ]] || { die "$EXIT_USAGE" "invalid demo ID: $demo_id"; return; }
  CURRENT_DEMO_ID="$demo_id"
  CURRENT_MARKER="Managed by Leroy demo:${demo_id}"
  STATE_FILE="${LEROY_STATE_DIR}/${demo_id}.json"
}

# Reports what Leroy recorded for one deployment: the resources it owns, their
# Morpheus IDs, and whether the record is complete for its component selection.
demo_state_report() {
  local expected recorded
  [[ -r "$STATE_FILE" ]] || { die "$EXIT_NOT_FOUND" "state not found for demo: $CURRENT_DEMO_ID"; return; }
  expected="$(jq -c '.manifest' "$STATE_FILE" | resource_count)"
  recorded="$(jq -r '.resources | length' "$STATE_FILE")"
  if [[ "$LEROY_OUTPUT" == json ]]; then
    jq --argjson defaults "$(feature_defaults)" --argjson expected "$expected" '{
      demoId: .manifest.metadata.id,
      name: .manifest.metadata.name,
      applianceUrl: .applianceUrl,
      applianceBuild: (.applianceBuild // ""),
      features: ($defaults * (.manifest.features // {})),
      expectedResources: $expected,
      recordedResources: (.resources | length),
      complete: ((.resources | length) == $expected),
      resources: [.resources[] | {key, type, scope, name, id, configured: (.configured // false)}]
    }' "$STATE_FILE"
    return
  fi
  printf 'Demo:       %s (%s)\n' "$(jq -r '.manifest.metadata.id' "$STATE_FILE")" "$(jq -r '.manifest.metadata.name' "$STATE_FILE")"
  printf 'Appliance:  %s\n' "$(jq -r '.applianceUrl' "$STATE_FILE")"
  printf 'Build:      %s\n' "$(jq -r '.applianceBuild // "unknown"' "$STATE_FILE")"
  printf 'Components: %s\n' "$(jq -r --argjson defaults "$(feature_defaults)" '($defaults * (.manifest.features // {})) | to_entries | map(select(.value) | .key) | join(", ")' "$STATE_FILE")"
  printf 'Resources:  %s recorded of %s expected\n\n' "$recorded" "$expected"
  printf '%-12s %-10s %-8s %s\n' TYPE ID SCOPE NAME
  jq -r '.resources[] | [.type, .id, .scope, .name] | @tsv' "$STATE_FILE" |
    while IFS=$'\t' read -r type id scope name; do
      printf '%-12s %-10s %-8s %s\n' "$type" "$id" "$scope" "$name"
    done
}

# Lists every deployment recorded in the state directory. An operator who
# returns to a machine needs this before any destructive action.
demo_list() {
  local file demos='[]' entry expected
  if [[ -d "$LEROY_STATE_DIR" ]]; then
    for file in "$LEROY_STATE_DIR"/*.json; do
      [[ -r "$file" ]] || continue
      jq -e '.stateVersion == 1 and (.manifest.metadata.id | type == "string")' "$file" >/dev/null 2>&1 || continue
      expected="$(jq -c '.manifest' "$file" | resource_count)"
      entry="$(jq -c --argjson defaults "$(feature_defaults)" --argjson expected "$expected" '{
        demoId: .manifest.metadata.id,
        name: .manifest.metadata.name,
        applianceUrl: .applianceUrl,
        applianceBuild: (.applianceBuild // ""),
        expectedResources: $expected,
        recordedResources: (.resources | length),
        complete: ((.resources | length) == $expected),
        components: [($defaults * (.manifest.features // {})) | to_entries[] | select(.value) | .key]
      }' "$file")"
      demos="$(jq -nc --argjson demos "$demos" --argjson entry "$entry" '$demos + [$entry]')"
    done
  fi
  if [[ "$LEROY_OUTPUT" == json ]]; then
    jq -n --argjson demos "$demos" '{demos: $demos}'
    return
  fi
  printf '%-20s %-11s %-11s %s\n' 'DEMO ID' RESOURCES COMPONENTS APPLIANCE
  jq -r --argjson total "$(feature_total)" '.[] |
    [.demoId,
     ((.recordedResources | tostring) + "/" + (.expectedResources | tostring)),
     ((.components | length | tostring) + "/" + ($total | tostring)),
     .applianceUrl] | @tsv' <<<"$demos" |
    while IFS=$'\t' read -r id resources components appliance; do
      printf '%-20s %-11s %-11s %s\n' "$id" "$resources" "$components" "$appliance"
    done
}

# Summarizes a manifest read from standard input. The wizard writes the whole
# document to the file; printing it to the terminal scrolls the prompt away.
manifest_summary() {
  local manifest
  manifest="$(cat)"
  jq -r --argjson defaults "$(feature_defaults)" '
    "Demo ID:      \(.metadata.id)",
    "Organization: \(.metadata.name)",
    "Subdomain:    \(.tenant.subdomain)",
    "Components:   \(($defaults * (.features // {})) | to_entries | map(select(.value) | .key) | join(", "))",
    "Personas:     \([.personas[].username] | join(", "))",
    "Environments: \(.environments | length), groups: \(.groups | length), policies: \(.policies | length)",
    "Cypher keys:  password/24/\(.metadata.id)/*"
  ' <<<"$manifest"
  printf 'Resources:    %s\n' "$(resource_count <<<"$manifest")"
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
  if [[ -n "$TUI_FEATURES_JSON" ]]; then generated="$(jq --argjson features "$TUI_FEATURES_JSON" '.features=$features' <<<"$generated")"; fi
  printf '\n'
  manifest_summary <<<"$generated"
  printf '\nThe complete manifest is written to the file.\n'
  printf '\nSave this manifest to %s? [y/N]: ' "$output"; read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || return 0
  [[ ! -e "$output" ]] || { die "$EXIT_CONFLICT" "file already exists: $output"; return; }
  printf '%s\n' "$generated" | jq -S . >"$output"; chmod 600 "$output"; printf 'Saved %s\n' "$output"
  LAST_WIZARD_FILE="$output"
}

status_command() {
  local response
  response="$(api_request GET '/api/whoami' '' "$MASTER_TOKEN")" || return
  if [[ "$LEROY_OUTPUT" == json ]]; then printf '%s\n' "$response"
  else printf 'Connected to %s\n' "$MORPHEUS_URL"; jq -r '"Authenticated as: \(.user.username // .user.displayName // .user.email // "unknown")"' <<<"$response"; fi
}

environments_list() {
  local response; response="$(api_collection '/api/environments' environments "$MASTER_TOKEN")" || return
  if [[ "$LEROY_OUTPUT" == json ]]; then printf '%s\n' "$response"
  else jq -r '["ID","NAME","CODE","VISIBILITY"],(.environments[]?|[.id,.name,(.code//"-"),(.visibility//"-")])|@tsv' <<<"$response"; fi
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

tui_lines() {
  local lines
  lines="$(tput lines 2>/dev/null || printf '24')"
  [[ "$lines" =~ ^[1-9][0-9]*$ ]] || lines=24
  printf '%s\n' "$lines"
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

# Reports the saved deployment that belongs to the manifest currently selected
# in the TUI, so the dashboard never describes a different demo.
tui_state_summary() {
  local count expected
  if [[ -z "$TUI_STATE_FILE" || ! -r "$TUI_STATE_FILE" ]]; then
    printf 'Not created'
    return
  fi
  count="$(jq -r '.resources | length' "$TUI_STATE_FILE" 2>/dev/null || printf '?')"
  expected="$(jq -c '.manifest' "$TUI_STATE_FILE" 2>/dev/null | resource_count || printf '?')"
  if [[ "$count" == "$expected" ]]; then printf 'Ready (%s/%s resources)' "$count" "$expected"
  else printf 'Partial (%s/%s resources)' "$count" "$expected"; fi
}

tui_deployed_features() {
  [[ -n "$TUI_STATE_FILE" && -r "$TUI_STATE_FILE" ]] || return 0
  jq -Sc --argjson defaults "$(feature_defaults)" '$defaults * (.manifest.features // {})' "$TUI_STATE_FILE" 2>/dev/null || true
}

tui_selected_feature_count() {
  jq -r '[.[] | select(. == true)] | length' <<<"$TUI_FEATURES_JSON"
}


# True when the operator changed the selection after a deployment was recorded.
# Plan and apply refuse that combination, so the dashboard has to say it.
tui_feature_drift() {
  local deployed
  deployed="$(tui_deployed_features)"
  [[ -n "$deployed" ]] || return 1
  [[ "$deployed" != "$(jq -Sc . <<<"$TUI_FEATURES_JSON")" ]]
}

tui_component_summary() {
  local total deployed
  total="$(feature_total)"
  if tui_feature_drift; then
    deployed="$(tui_deployed_features)"
    printf '%s/%s selected, deployed %s/%s - recreate required' \
      "$(tui_selected_feature_count)" "$total" \
      "$(jq -r '[.[] | select(. == true)] | length' <<<"$deployed")" "$total"
  else
    printf '%s/%s selected' "$(tui_selected_feature_count)" "$total"
  fi
}

# Rebuilds the effective manifest from the selected source plus the selected
# components, then republishes the demo identity the dashboard and the
# lifecycle actions rely on.
tui_sync_manifest() {
  manifest_to_temp "$TUI_MANIFEST_FILE" || return
  TUI_DEMO_ID="$CURRENT_DEMO_ID"
  TUI_DEMO_NAME="$(jq -r '.metadata.name' "$CURRENT_MANIFEST")"
  TUI_STATE_FILE="$STATE_FILE"
  TUI_RESOURCE_COUNT="$(resource_count <"$CURRENT_MANIFEST")"
}

tui_bootstrap_manifest() {
  tui_use_preset
  tui_sync_manifest || return
  if [[ -r "$TUI_STATE_FILE" ]]; then
    TUI_FEATURES_JSON="$(tui_deployed_features)"
    tui_sync_manifest || return
  fi
}

tui_apply_identity() {
  local response="$1" user
  user="$(jq -r '.user.username // .user.displayName // .user.email // "unknown"' <<<"$response")"
  TUI_BUILD="$(jq -r '[.. | objects | (.buildVersion?, .applianceVersion?, .version?)] | map(select(type == "string")) | first // empty' <<<"$response")"
  TUI_IDENTITY="$user"
  TUI_CONNECTION_STATE="Connected as ${user}${TUI_BUILD:+ (Morpheus ${TUI_BUILD})}"
}

tui_probe_connection() {
  local response
  if ! response="$(api_request GET '/api/whoami' '' "$MASTER_TOKEN" 2>/dev/null)"; then
    TUI_CONNECTION_STATE='Not reachable'
    TUI_IDENTITY=''
    TUI_BUILD=''
    return 1
  fi
  tui_apply_identity "$response"
}

tui_toggle_component() {
  local key="$1" target
  target="$(jq -r --arg key "$key" '(.[$key] | not)' <<<"$TUI_FEATURES_JSON")"
  TUI_COMPONENT_NOTICE='Selection updated.'
  case "$key" in
    multitenancy | roles)
      TUI_FEATURES_JSON="$(jq -Sc --argjson value "$target" '.multitenancy=$value | .roles=$value' <<<"$TUI_FEATURES_JSON")"
      TUI_COMPONENT_NOTICE='Multitenancy and persona roles are deployed together.'
      ;;
    groups)
      TUI_FEATURES_JSON="$(jq -Sc --argjson value "$target" '.groups=$value | if $value then . else .policies=false end' <<<"$TUI_FEATURES_JSON")"
      [[ "$target" == true ]] || TUI_COMPONENT_NOTICE='Policies were also disabled because they require groups.'
      ;;
    policies)
      TUI_FEATURES_JSON="$(jq -Sc --argjson value "$target" '.policies=$value | if $value then .groups=true else . end' <<<"$TUI_FEATURES_JSON")"
      [[ "$target" == false ]] || TUI_COMPONENT_NOTICE='Groups were also enabled because policies require them.'
      ;;
    automation)
      TUI_FEATURES_JSON="$(jq -Sc --argjson value "$target" '.automation=$value | if $value then . else .catalog=false end' <<<"$TUI_FEATURES_JSON")"
      [[ "$target" == true ]] || TUI_COMPONENT_NOTICE='Catalog was also disabled because it requires automation.'
      ;;
    catalog)
      TUI_FEATURES_JSON="$(jq -Sc --argjson value "$target" '.catalog=$value | if $value then .automation=true else . end' <<<"$TUI_FEATURES_JSON")"
      [[ "$target" == false ]] || TUI_COMPONENT_NOTICE='Automation was also enabled because catalog requires it.'
      ;;
    *) TUI_FEATURES_JSON="$(jq -Sc --arg key "$key" --argjson value "$target" '.[$key]=$value' <<<"$TUI_FEATURES_JSON")" ;;
  esac
}

# Emits one "<checked><changed>" pair per component, in order. One jq call keeps
# the selector responsive; a call per checkbox made every redraw visibly slow.
tui_component_flags() {
  jq -rn --argjson selected "$TUI_FEATURES_JSON" \
    --argjson deployed "${1:-null}" --argjson keys "$TUI_COMPONENT_KEYS_JSON" '
    $keys[] |
      (if $selected[.] == true then "x" else " " end) +
      (if ($deployed != null and $selected[.] != $deployed[.]) then "*" else " " end)'
}

tui_render_components() {
  local selected="$1" width index key checked row description available gap deployed marker
  local -a flags=()
  width="$(tui_columns)"
  deployed="$(tui_deployed_features)"
  mapfile -t flags < <(tui_component_flags "${deployed:-null}")
  tui_clear
  printf '%s%s  DEPLOYMENT COMPONENTS%s\n' "$TUI_ACCENT" "$TUI_BOLD" "$TUI_RESET"
  tui_rule "$width"
  printf '  %s\n' "$(tui_crop 'Everything is selected by default. Deselected platform content is not created.' "$((width - 2))")"
  printf '  %s\n\n' "$(tui_crop "Resources for this selection: ${TUI_RESOURCE_COUNT:-?}" "$((width - 2))")"
  for index in "${!TUI_COMPONENT_KEYS[@]}"; do
    key="${TUI_COMPONENT_KEYS[$index]}"
    description="${TUI_COMPONENT_HINTS[$index]}"
    checked="${flags[$index]:0:1}"
    marker="${flags[$index]:1:1}"
    [[ "$marker" != '*' ]] || description="changed - ${description}"
    row="  [${checked}]${marker}${TUI_COMPONENT_LABELS[$index]}"
    if ((width >= 76)); then
      available=$((width - ${#row} - ${#description} - 2))
      ((available < 1)) && available=1
      printf -v gap '%*s' "$available" ''
      row="${row}${gap}${description}"
    fi
    row="$(tui_crop "$row" "$width")"
    if ((index == selected)); then printf '%s%-*s%s\n' "$TUI_SELECTED" "$width" "$row" "$TUI_RESET"; else printf '%-*s\n' "$width" "$row"; fi
  done
  printf '\n%s  %s%s\n' "$TUI_WARNING" "$(tui_crop "$TUI_COMPONENT_NOTICE" "$((width - 2))")" "$TUI_RESET"
  printf '%s  Space toggle  a all  n none  Enter save  Esc cancel%s\n' "$TUI_DIM" "$TUI_RESET"
}

tui_select_components() {
  local selected=0 key original="$TUI_FEATURES_JSON" count dirty=false
  local TUI_COMPONENT_NOTICE='An asterisk marks a component that differs from the saved deployment.'
  local -a TUI_COMPONENT_KEYS=(multitenancy roles environments groups policies automation catalog)
  local TUI_COMPONENT_KEYS_JSON
  local -a TUI_COMPONENT_LABELS=('Multitenancy' 'Persona roles & users' 'Environments' 'Groups' 'Policies' 'Automation' 'Service catalog')
  local -a TUI_COMPONENT_HINTS=('Tenant and tenant role' 'Admin, operator and consumer personas' 'Development, staging and production' 'Development and production scopes' 'MOTD, naming, expiry and Cypher' 'Input, task and workflow' 'Self-service catalog item')
  count="${#TUI_COMPONENT_KEYS[@]}"
  TUI_COMPONENT_KEYS_JSON="$(printf '%s\n' "${TUI_COMPONENT_KEYS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  while true; do
    if [[ "$dirty" == true ]]; then
      tui_sync_manifest >/dev/null 2>&1 || true
      dirty=false
    fi
    tui_render_components "$selected"
    key="$(tui_read_key)"
    case "$key" in
      up | k) selected=$(((selected + count - 1) % count)) ;;
      down | j) selected=$(((selected + 1) % count)) ;;
      home) selected=0 ;;
      end) selected=$((count - 1)) ;;
      ' ') tui_toggle_component "${TUI_COMPONENT_KEYS[$selected]}"; dirty=true ;;
      a)
        TUI_FEATURES_JSON="$(feature_defaults | jq -Sc .)"
        TUI_COMPONENT_NOTICE='All deployment components selected.'
        dirty=true
        ;;
      n)
        TUI_FEATURES_JSON="$(jq -Sc 'map_values(false)' <<<"$(feature_defaults)")"
        TUI_COMPONENT_NOTICE='All deployment components cleared.'
        dirty=true
        ;;
      enter)
        tui_sync_manifest || true
        TUI_LAST_RESULT="Components saved: $(tui_selected_feature_count)/$(feature_total) selected"
        return 0
        ;;
      q | escape)
        TUI_FEATURES_JSON="$original"
        tui_sync_manifest || true
        TUI_LAST_RESULT='Component selection cancelled'
        return 0
        ;;
    esac
  done
}

# Lists the deployments recorded in the state directory. Each state file embeds
# the manifest it was built from, so a saved deployment can be selected in the
# TUI without the operator still holding its manifest file.
tui_saved_demos() {
  local file
  [[ -d "$LEROY_STATE_DIR" ]] || return 0
  for file in "$LEROY_STATE_DIR"/*.json; do
    [[ -r "$file" ]] || continue
    jq -e '.stateVersion == 1 and (.manifest.metadata.id | type == "string")' "$file" >/dev/null 2>&1 || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(jq -r '.manifest.metadata.id' "$file")" \
      "$file" \
      "$(jq -c '.manifest' "$file" | resource_count)" \
      "$(jq -r '.resources | length' "$file")" \
      "$(jq -r '.applianceUrl // ""' "$file")"
  done
}

tui_use_preset() {
  TUI_MANIFEST_FILE=""
  TUI_MANIFEST_ORIGIN=""
  TUI_MANIFEST_KIND='preset'
  TUI_MANIFEST_LABEL='Built-in preset'
  TUI_FEATURES_JSON="$(feature_defaults)"
}

tui_use_manifest_file() {
  local path="$1"
  TUI_MANIFEST_FILE="$path"
  TUI_MANIFEST_ORIGIN="$path"
  TUI_MANIFEST_KIND='file'
  TUI_MANIFEST_LABEL="${path##*/}"
  TUI_FEATURES_JSON="$(manifest_features "$path" 2>/dev/null | jq -Sc . 2>/dev/null || feature_defaults)"
}

tui_use_saved_demo() {
  local state="$1" temp
  temp="$(mktemp "${TMPDIR:-/tmp}/leroy-saved.XXXXXX")" || return "$EXIT_API"
  jq -S '.manifest' "$state" >"$temp" || { rm -f "$temp"; return "$EXIT_RESPONSE"; }
  [[ -z "$TUI_MANIFEST_TEMP" ]] || rm -f "$TUI_MANIFEST_TEMP"
  TUI_MANIFEST_TEMP="$temp"
  TUI_MANIFEST_FILE="$temp"
  TUI_MANIFEST_ORIGIN="$state"
  TUI_MANIFEST_KIND='saved'
  TUI_MANIFEST_LABEL='Saved deployment'
  TUI_FEATURES_JSON="$(manifest_features "$temp" | jq -Sc .)"
}

tui_render_manifest_sources() {
  local selected="$1" width index row hint available gap marker
  width="$(tui_columns)"
  tui_clear
  printf '%s%s  MANIFEST SOURCE%s\n' "$TUI_ACCENT" "$TUI_BOLD" "$TUI_RESET"
  tui_rule "$width"
  printf '  %s\n\n' "$(tui_crop 'The selected source drives the demo ID, the components, and every action.' "$((width - 2))")"
  for index in "${!TUI_SOURCE_LABELS[@]}"; do
    if [[ "${TUI_SOURCE_ORIGINS[$index]}" == "$TUI_MANIFEST_ORIGIN" ]]; then marker='o'; else marker=' '; fi
    row="  (${marker}) ${TUI_SOURCE_LABELS[$index]}"
    hint="${TUI_SOURCE_HINTS[$index]}"
    if ((width >= 76)) && [[ -n "$hint" ]]; then
      available=$((width - ${#row} - ${#hint} - 2))
      ((available < 1)) && available=1
      printf -v gap '%*s' "$available" ''
      row="${row}${gap}${hint}"
    fi
    row="$(tui_crop "$row" "$width")"
    if ((index == selected)); then printf '%s%-*s%s\n' "$TUI_SELECTED" "$width" "$row" "$TUI_RESET"; else printf '%-*s\n' "$width" "$row"; fi
  done
  printf '\n%s  %s%s\n' "$TUI_WARNING" "$(tui_crop "$TUI_SOURCE_NOTICE" "$((width - 2))")" "$TUI_RESET"
  printf '%s  Enter select  Esc cancel%s\n' "$TUI_DIM" "$TUI_RESET"
}

tui_prompt_manifest_path() {
  local path
  tui_action_header 'Manifest file'
  printf 'Enter a manifest path, or leave it empty to cancel.\n\n> '
  printf '\033[?25h'
  IFS= read -r path || path=''
  printf '\033[?25l'
  [[ -n "$path" ]] || return 1
  if [[ ! -r "$path" ]]; then
    TUI_LAST_RESULT="Manifest is not readable: $path"
    printf '\n%sManifest file is not readable: %s%s\n' "$TUI_DANGER" "$path" "$TUI_RESET"
    tui_wait
    return 1
  fi
  printf '%s\n' "$path"
}

tui_select_manifest() {
  local selected=0 key count index id state expected recorded appliance
  local previous_file="$TUI_MANIFEST_FILE" previous_origin="$TUI_MANIFEST_ORIGIN"
  local previous_kind="$TUI_MANIFEST_KIND" previous_label="$TUI_MANIFEST_LABEL"
  local previous_features="$TUI_FEATURES_JSON" path
  local TUI_SOURCE_NOTICE='Saved deployments are read from the state directory.'
  local -a TUI_SOURCE_LABELS=('Built-in preset') TUI_SOURCE_HINTS=('') TUI_SOURCE_KINDS=(preset) TUI_SOURCE_ORIGINS=('')
  TUI_SOURCE_HINTS[0]="$(preset_manifest | resource_count) resources"
  while IFS=$'\t' read -r id state expected recorded appliance; do
    [[ -n "$id" ]] || continue
    TUI_SOURCE_LABELS+=("$id")
    TUI_SOURCE_KINDS+=(saved)
    TUI_SOURCE_ORIGINS+=("$state")
    if [[ -n "$appliance" && "$appliance" != "$MORPHEUS_URL" ]]; then
      TUI_SOURCE_HINTS+=("${recorded}/${expected} recorded, other appliance")
    else
      TUI_SOURCE_HINTS+=("${recorded}/${expected} recorded")
    fi
  done < <(tui_saved_demos)
  TUI_SOURCE_LABELS+=('Manifest file...')
  TUI_SOURCE_KINDS+=(file)
  TUI_SOURCE_ORIGINS+=($'\x01none')
  TUI_SOURCE_HINTS+=('Type a path')
  count="${#TUI_SOURCE_LABELS[@]}"
  for index in "${!TUI_SOURCE_ORIGINS[@]}"; do
    [[ "${TUI_SOURCE_ORIGINS[$index]}" == "$TUI_MANIFEST_ORIGIN" ]] && selected="$index"
  done
  while true; do
    tui_render_manifest_sources "$selected"
    key="$(tui_read_key)"
    case "$key" in
      up | k) selected=$(((selected + count - 1) % count)) ;;
      down | j) selected=$(((selected + 1) % count)) ;;
      home) selected=0 ;;
      end) selected=$((count - 1)) ;;
      q | escape) TUI_LAST_RESULT='Manifest source unchanged'; return 0 ;;
      enter)
        case "${TUI_SOURCE_KINDS[$selected]}" in
          preset) tui_use_preset ;;
          saved) tui_use_saved_demo "${TUI_SOURCE_ORIGINS[$selected]}" || { TUI_SOURCE_NOTICE='That saved deployment could not be read.'; continue; } ;;
          file)
            path="$(tui_prompt_manifest_path)" || { TUI_SOURCE_NOTICE='No manifest file was selected.'; continue; }
            tui_use_manifest_file "$path"
            ;;
        esac
        if tui_sync_manifest; then
          TUI_LAST_RESULT="Manifest source: ${TUI_MANIFEST_LABEL} (${TUI_DEMO_ID})"
          return 0
        fi
        TUI_MANIFEST_FILE="$previous_file"
        TUI_MANIFEST_ORIGIN="$previous_origin"
        TUI_MANIFEST_KIND="$previous_kind"
        TUI_MANIFEST_LABEL="$previous_label"
        TUI_FEATURES_JSON="$previous_features"
        tui_sync_manifest || true
        TUI_SOURCE_NOTICE='That manifest is invalid; the previous source is still active.'
        ;;
    esac
  done
}

tui_menu_row() {
  local index="$1" selected="$2" width="$3" show_hint="$4" key label hint lead text available gap
  key="${TUI_KEYS[$index]}"
  label="${TUI_LABELS[$index]}"
  hint="${TUI_HINTS[$index]}"
  if ((index == selected)); then lead=' > '; else lead='   '; fi
  text="${lead}[${key}] ${label}"
  if [[ "$show_hint" == true ]] && ((width >= 76)) && [[ -n "$hint" ]]; then
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
  local selected="$1" width height items compact=false index group previous='' manifest
  width="$(tui_columns)"
  height="$(tui_lines)"
  items="${#TUI_KEYS[@]}"
  ((height >= items + 16)) || compact=true
  manifest="$TUI_MANIFEST_LABEL"
  [[ "$TUI_DEMO_ID" == "" ]] || manifest="${manifest} (${TUI_DEMO_ID})"
  tui_clear
  printf '%s%s%s%s\n' "$TUI_ACCENT" "$TUI_BOLD" "$(tui_crop "  LEROY ${LEROY_VERSION}  Morpheus 9 demo builder" "$width")" "$TUI_RESET"
  tui_rule "$width"
  printf '  %-14s %s\n' 'Appliance' "$(tui_crop "${MORPHEUS_URL:-Not configured}" "$((width - 18))")"
  printf '  %-14s %s\n' 'Connection' "$(tui_crop "$TUI_CONNECTION_STATE" "$((width - 18))")"
  printf '  %-14s %s\n' 'Manifest' "$(tui_crop "$manifest" "$((width - 18))")"
  printf '  %-14s %s\n' 'Components' "$(tui_crop "$(tui_component_summary)" "$((width - 18))")"
  printf '  %-14s %s\n' 'Demo' "$(tui_crop "$(tui_state_summary)" "$((width - 18))")"
  printf '  %-14s %s\n' 'Last result' "$(tui_crop "$TUI_LAST_RESULT" "$((width - 18))")"
  tui_rule "$width"
  for index in "${!TUI_KEYS[@]}"; do
    group="${TUI_GROUPS[$index]}"
    if [[ "$compact" != true && "$group" != "$previous" ]]; then
      printf '%s  %s%s\n' "$TUI_MUTED" "$group" "$TUI_RESET"
    fi
    previous="$group"
    tui_menu_row "$index" "$selected" "$width" "$([[ "$compact" == true ]] && printf 'false' || printf 'true')"
  done
  if ((width < 60)); then
    printf '%s  j/k move  Enter select  q quit%s\n' "$TUI_DIM" "$TUI_RESET"
  else
    printf '%s  Up/Down or j/k move  Enter select  shortcut keys run  q quit%s\n' "$TUI_DIM" "$TUI_RESET"
  fi
}

# Recognizes complete escape sequences so an unmapped special key is ignored
# instead of leaking its tail into the next read or quitting the dashboard.
tui_read_key() {
  local key sequence='' char
  IFS= read -rsn1 key || { printf 'q\n'; return 0; }
  if [[ "$key" == $'\033' ]]; then
    if ! IFS= read -rsn1 -t 0.05 char; then printf 'escape\n'; return 0; fi
    if [[ "$char" != '[' && "$char" != 'O' ]]; then printf 'unknown\n'; return 0; fi
    while IFS= read -rsn1 -t 0.05 char; do
      sequence+="$char"
      if [[ "$char" == [A-Za-z~] ]]; then break; fi
    done
    case "$sequence" in
      A) key='up' ;;
      B) key='down' ;;
      C) key='right' ;;
      D) key='left' ;;
      H | '1~' | '7~') key='home' ;;
      F | '4~' | '8~') key='end' ;;
      '5~') key='pageup' ;;
      '6~') key='pagedown' ;;
      *) key='unknown' ;;
    esac
  elif [[ -z "$key" ]]; then
    key='enter'
  else
    key="${key,,}"
  fi
  printf '%s\n' "$key"
}

tui_wait() {
  printf '\n%sPress any key to return to the dashboard.%s' "$TUI_DIM" "$TUI_RESET"
  IFS= read -rsn1 _ || true
}

tui_action_header() {
  local title="$1" width
  width="$(tui_columns)"
  tui_clear
  printf '%s%s  %s%s\n' "$TUI_ACCENT" "$TUI_BOLD" "$title" "$TUI_RESET"
  tui_rule "$width"
  printf '\n'
}

# Scrolls action output that does not fit the terminal instead of relying on
# scrollback, which the alternate screen does not keep.
tui_pager() {
  local file="$1" title="$2" top=0 total height width key last shown
  total="$(wc -l <"$file")"
  while true; do
    width="$(tui_columns)"
    height=$(($(tui_lines) - 5))
    ((height >= 3)) || height=3
    last=$((total - height))
    ((last >= 0)) || last=0
    ((top <= last)) || top=$last
    tui_clear
    printf '%s%s  %s%s\n' "$TUI_ACCENT" "$TUI_BOLD" "$title" "$TUI_RESET"
    tui_rule "$width"
    sed -n "$((top + 1)),$((top + height))p" "$file" | while IFS= read -r shown; do
      printf '%s\n' "$(tui_crop "$shown" "$width")"
    done
    tui_rule "$width"
    shown=$((top + height))
    ((shown <= total)) || shown=$total
    printf '%s  lines %s-%s of %s   j/k scroll   Space page   q close%s\n' "$TUI_DIM" "$((top + 1))" "$shown" "$total" "$TUI_RESET"
    key="$(tui_read_key)"
    case "$key" in
      down | j) if ((top < last)); then top=$((top + 1)); fi ;;
      up | k) if ((top > 0)); then top=$((top - 1)); fi ;;
      ' ' | pagedown) top=$((top + height)) ;;
      pageup) top=$((top - height)); ((top >= 0)) || top=0 ;;
      home | g) top=0 ;;
      end) top=$last ;;
      q | escape | enter) return 0 ;;
    esac
  done
}

# Runs an action with live output and a copy on disk for scrolling. The copy is
# made through a FIFO rather than a pipeline, because a pipeline would run the
# action in a subshell and discard the session state it updates.
# Runs a command with live output and a copy in "$1" for scrolling, and returns
# the command's status. The copy is made through a FIFO rather than a pipeline,
# because a pipeline would run the command in a subshell and discard the session
# state it updates. An empty path, or no mkfifo, means live output only.
tui_capture() {
  local output="$1" rc=0 fifo="" tee_pid
  shift
  if [[ -n "$output" ]] && command -v mkfifo >/dev/null 2>&1; then
    fifo="${output}.fifo"
    mkfifo -m 600 "$fifo" 2>/dev/null || fifo=""
  fi
  if [[ -n "$fifo" ]]; then
    tee "$output" <"$fifo" &
    tee_pid=$!
    "$@" >"$fifo" 2>&1 || rc=$?
    wait "$tee_pid" 2>/dev/null || true
    rm -f "$fifo"
  else
    "$@" || rc=$?
  fi
  return "$rc"
}

tui_capture_file() {
  local file
  command -v mkfifo >/dev/null 2>&1 || return 0
  file="$(mktemp "${TMPDIR:-/tmp}/leroy-output.XXXXXX")" || return 0
  printf '%s\n' "$file"
}

tui_output_exceeds_screen() {
  local output="$1" visible
  [[ -n "$output" && -r "$output" ]] || return 1
  visible=$(($(tui_lines) - 7))
  ((visible >= 1)) || visible=1
  (($(wc -l <"$output") > visible))
}

tui_finish_output() {
  local output="$1" title="$2"
  if tui_output_exceeds_screen "$output"; then
    printf '\n%sOutput is longer than this screen. Press any key to scroll it.%s' "$TUI_DIM" "$TUI_RESET"
    IFS= read -rsn1 _ || true
    tui_pager "$output" "$title"
  else
    tui_wait
  fi
  [[ -z "$output" ]] || rm -f "$output"
}

tui_run_action() {
  local title="$1" rc=0 output
  shift
  tui_action_header "$title"
  printf '%sRunning...%s\n\n' "$TUI_DIM" "$TUI_RESET"
  output="$(tui_capture_file)"
  tui_capture "$output" "$@" || rc=$?
  TUI_LAST_RC="$rc"
  TUI_LAST_FORCEABLE=false
  [[ -z "$output" ]] || ! grep -q -- '--force' "$output" || TUI_LAST_FORCEABLE=true
  if ((rc == 0)); then
    TUI_LAST_RESULT="Success: $title"
    [[ -z "$output" ]] || printf '\nCompleted successfully.\n' >>"$output"
    printf '\n%sCompleted successfully.%s\n' "$TUI_SUCCESS" "$TUI_RESET"
  else
    TUI_LAST_RESULT="Failed ($rc): $title"
    [[ -z "$output" ]] || printf '\nAction failed with exit code %s.\n' "$rc" >>"$output"
    printf '\n%sAction failed with exit code %s.%s\n' "$TUI_DANGER" "$rc" "$TUI_RESET"
  fi
  tui_finish_output "$output" "$title"
  tui_sync_manifest >/dev/null 2>&1 || true
  return 0
}

tui_status_action() {
  local response rc=0
  response="$(api_request GET '/api/whoami' '' "$MASTER_TOKEN")" || rc=$?
  if ((rc != 0)); then
    TUI_CONNECTION_STATE="Not reachable (exit ${rc})"
    TUI_IDENTITY=''
    TUI_BUILD=''
    return "$rc"
  fi
  tui_apply_identity "$response"
  printf 'Appliance:    %s\n' "$MORPHEUS_URL"
  printf 'Identity:     %s\n' "$TUI_IDENTITY"
  printf 'Build:        %s\n' "${TUI_BUILD:-unknown}"
  printf 'Master admin: %s\n' "$(jq -r 'if .isMasterAccount == true then "yes" else "no" end' <<<"$response")"
  printf 'Tenant:       %s\n' "$(jq -r '.user.account.name // .account.name // "unknown"' <<<"$response")"
  printf 'TLS verify:   %s\n' "$MORPHEUS_VERIFY_TLS"
}

tui_plan_action() { tui_sync_manifest && demo_plan; }
tui_apply_action() { tui_sync_manifest && demo_apply; }
tui_verify_action() { tui_sync_manifest && preflight && state_assert_appliance && demo_verify false; }
tui_deep_verify_action() { tui_sync_manifest && preflight && state_assert_appliance && demo_verify true; }
tui_inventory_action() { tui_sync_manifest && demo_state_report; }

tui_plan_counts() {
  awk '
    $1 == "create" || $1 == "update" || $1 == "adopt" || $1 == "unchanged" || $1 == "conflict" { count[$1]++ }
    END { printf "%d %d %d %d %d\n", count["create"] + 0, count["update"] + 0, count["adopt"] + 0, count["unchanged"] + 0, count["conflict"] + 0 }
  ' "$1"
}

# Build previews the plan and asks for confirmation before it mutates Morpheus,
# so the operator sees what an apply will do while it can still be refused.
tui_build_screen() {
  local rc=0 output key created updated adopted unchanged conflicts mutations
  tui_action_header 'Build selected demo'
  printf '%sPreviewing changes...%s\n\n' "$TUI_DIM" "$TUI_RESET"
  output="$(tui_capture_file)"
  tui_capture "$output" tui_plan_action || rc=$?
  TUI_LAST_RC="$rc"
  if ((rc != 0)); then
    TUI_LAST_RESULT="Failed ($rc): Preview before build"
    printf '\n%sPreview failed with exit code %s. Nothing was changed.%s\n' "$TUI_DANGER" "$rc" "$TUI_RESET"
    tui_finish_output "$output" 'Preview before build'
    return 0
  fi
  if tui_output_exceeds_screen "$output"; then
    printf '\n%sThe plan is longer than this screen. Press any key to review it.%s' "$TUI_DIM" "$TUI_RESET"
    IFS= read -rsn1 _ || true
    tui_pager "$output" 'Plan before build'
    tui_action_header 'Build selected demo'
  fi
  created=0 updated=0 adopted=0 unchanged=0 conflicts=0
  if [[ -n "$output" && -r "$output" ]]; then
    read -r created updated adopted unchanged conflicts < <(tui_plan_counts "$output") || true
  fi
  rm -f "$output"
  mutations=$((created + updated + adopted))
  printf '\n%sPlan: %s create, %s update, %s adopt, %s unchanged%s\n' \
    "$TUI_BOLD" "$created" "$updated" "$adopted" "$unchanged" "$TUI_RESET"
  if ((conflicts > 0)); then
    printf '%s%s conflicting resource(s); build would stop.%s\n' "$TUI_DANGER" "$conflicts" "$TUI_RESET"
  elif ((mutations == 0)); then
    printf '%sNothing to create or update. Building only reapplies role and catalog access.%s\n' "$TUI_DIM" "$TUI_RESET"
  fi
  printf '\nBuild %s on %s?\n' "$TUI_DEMO_ID" "$(tui_crop "$MORPHEUS_URL" 60)"
  printf '%sPress y to build, any other key to cancel.%s\n\n> ' "$TUI_DIM" "$TUI_RESET"
  key="$(tui_read_key)"
  if [[ "$key" != y ]]; then
    TUI_LAST_RESULT='Build cancelled at the preview'
    printf '\n%sCancelled. Nothing was changed.%s\n' "$TUI_WARNING" "$TUI_RESET"
    tui_wait
    return 0
  fi
  tui_run_action 'Build selected demo' tui_apply_action
}

# A destroy that stops on an ownership mismatch can be retried with force, which
# still refuses any resource that carries no Leroy identity at all.
tui_force_retry() {
  local title="$1" typed
  shift
  ((TUI_LAST_RC == EXIT_CONFLICT)) || return 0
  [[ "$TUI_LAST_FORCEABLE" == true ]] || return 0
  tui_action_header "$title"
  printf '%sA resource no longer matches the ownership marker Leroy recorded.%s\n\n' "$TUI_WARNING" "$TUI_RESET"
  printf 'Forcing removes resources that still carry a Leroy identity but whose\n'
  printf 'marker has changed. A resource with no Leroy identity is never removed.\n\n'
  printf 'Type %sforce%s to continue, or anything else to stop:\n\n> ' "$TUI_BOLD" "$TUI_RESET"
  printf '\033[?25h'
  IFS= read -r typed || true
  printf '\033[?25l'
  if [[ "$typed" != force ]]; then
    TUI_LAST_RESULT="Cancelled: $title"
    printf '\n%sNothing further was changed.%s\n' "$TUI_WARNING" "$TUI_RESET"
    tui_wait
    return 0
  fi
  tui_run_action "$title (forced)" "$@"
}

tui_destroy_phrase() {
  if [[ -n "$TUI_STATE_FILE" && -r "$TUI_STATE_FILE" ]]; then
    jq -r '.manifest.metadata.name' "$TUI_STATE_FILE"
  else
    printf '%s' "$TUI_DEMO_NAME"
  fi
}

tui_confirm() {
  local title="$1" phrase="$2" detail="$3" typed
  tui_action_header "$title"
  printf '%s%s%s\n\n' "$TUI_WARNING" "$detail" "$TUI_RESET"
  printf 'This operation is protected. Type the organization name exactly:\n\n  %s%s%s\n\n> ' "$TUI_BOLD" "$phrase" "$TUI_RESET"
  printf '\033[?25h'
  IFS= read -r typed || true
  printf '\033[?25l'
  if [[ "$typed" == "$phrase" ]]; then return 0; fi
  TUI_LAST_RESULT="Cancelled: $title"
  printf '\n%sConfirmation did not match. Nothing was changed.%s\n' "$TUI_WARNING" "$TUI_RESET"
  tui_wait
  return 1
}

tui_destroy_action() { demo_destroy "$TUI_DEMO_ID" true false; }
tui_destroy_force_action() { demo_destroy "$TUI_DEMO_ID" true true; }
tui_recreate_action() { demo_destroy "$TUI_DEMO_ID" true false && tui_sync_manifest && demo_apply; }
tui_recreate_force_action() { demo_destroy "$TUI_DEMO_ID" true true && tui_sync_manifest && demo_apply; }

# The wizard is interactive and refuses a non-terminal stdout, so it runs on its
# own screen instead of through the captured action runner.
tui_wizard_screen() {
  local rc=0
  tui_action_header 'Create custom manifest'
  LAST_WIZARD_FILE=""
  printf '\033[?25h'
  wizard_manifest || rc=$?
  printf '\033[?25l'
  if ((rc != 0)); then
    TUI_LAST_RESULT="Failed ($rc): Create custom manifest"
    printf '\n%sThe wizard failed with exit code %s.%s\n' "$TUI_DANGER" "$rc" "$TUI_RESET"
  elif [[ -z "$LAST_WIZARD_FILE" || ! -r "$LAST_WIZARD_FILE" ]]; then
    TUI_LAST_RESULT='Manifest was not saved'
  else
    tui_use_manifest_file "$LAST_WIZARD_FILE"
    if tui_sync_manifest; then
      TUI_LAST_RESULT="Manifest saved and activated: ${TUI_MANIFEST_LABEL}"
      printf '\n%sThe saved manifest is now the active TUI source (demo %s).%s\n' "$TUI_SUCCESS" "$TUI_DEMO_ID" "$TUI_RESET"
    else
      TUI_LAST_RESULT='Saved manifest was rejected'
    fi
  fi
  tui_wait
  return 0
}

tui_requires_state() {
  local title="$1"
  [[ -n "$TUI_STATE_FILE" && -r "$TUI_STATE_FILE" ]] && return 0
  TUI_LAST_RESULT="${title}: no saved deployment for ${TUI_DEMO_ID}"
  return 1
}

run_tui() {
  [[ -t 0 && -t 1 ]] || { die "$EXIT_USAGE" 'TUI requires an interactive terminal'; return; }
  local selected=0 key index items
  local -a TUI_KEYS=(s i p a v d r x c m w q)
  local -a TUI_LABELS=(
    'Check connection' 'Deployment inventory' 'Preview plan' 'Build selected demo'
    'Verify structure' 'Deep verification' 'Recreate selected demo' 'Destroy selected demo'
    'Select deployment components' 'Choose manifest source' 'Create custom manifest' 'Quit')
  local -a TUI_GROUPS=(
    INSPECT INSPECT INSPECT BUILD VALIDATE VALIDATE LIFECYCLE LIFECYCLE
    CONFIGURE CONFIGURE CONFIGURE SESSION)
  local -a TUI_HINTS=(
    'Authenticate and inspect appliance' 'Show recorded resources and IDs' 'Show intended changes' ''
    'Check resources and ownership' 'Test selected personas and workflow' 'Destroy, then rebuild selection' 'Remove owned demo resources'
    'Choose platform capabilities' 'Preset or a manifest file' 'Guided JSON manifest wizard' 'Return to shell')
  items="${#TUI_KEYS[@]}"
  tui_init_palette
  tui_bootstrap_manifest || return
  tui_enter_screen
  TUI_CONNECTION_STATE='Checking...'
  tui_render "$selected"
  tui_probe_connection || true
  while true; do
    TUI_HINTS[3]="Create or resume ${TUI_RESOURCE_COUNT} resources"
    tui_render "$selected"
    key="$(tui_read_key)"
    case "$key" in
      up | k) selected=$(((selected + items - 1) % items)); continue ;;
      down | j) selected=$(((selected + 1) % items)); continue ;;
      home) selected=0; continue ;;
      end) selected=$((items - 1)); continue ;;
      enter) index="$selected" ;;
      s) index=0 ;; i) index=1 ;; p) index=2 ;; a) index=3 ;; v) index=4 ;; d) index=5 ;;
      r) index=6 ;; x) index=7 ;; c) index=8 ;; m) index=9 ;; w) index=10 ;;
      q | escape) index=11 ;;
      *) continue ;;
    esac
    selected="$index"
    case "$index" in
      0) tui_run_action 'Connection status' tui_status_action ;;
      1)
        if tui_requires_state 'Deployment inventory'; then
          tui_run_action 'Deployment inventory' tui_inventory_action
        fi
        ;;
      2) tui_run_action 'Plan selected demo' tui_plan_action ;;
      3) tui_build_screen ;;
      4)
        if tui_requires_state 'Verify demo structure'; then
          tui_run_action 'Verify demo structure' tui_verify_action
        fi
        ;;
      5)
        if tui_requires_state 'Deep verification'; then
          tui_run_action 'Deep verification' tui_deep_verify_action
        fi
        ;;
      6)
        if tui_requires_state 'Recreate selected demo' &&
          tui_confirm 'Recreate selected demo' "$(tui_destroy_phrase)" "All Leroy-owned resources of ${TUI_DEMO_ID} will be deleted, then the current selection will be built."; then
          tui_run_action 'Recreate selected demo' tui_recreate_action
          tui_force_retry 'Recreate selected demo' tui_recreate_force_action
        fi
        ;;
      7)
        if tui_requires_state 'Destroy selected demo' &&
          tui_confirm 'Destroy selected demo' "$(tui_destroy_phrase)" "All Leroy-owned resources of ${TUI_DEMO_ID} will be permanently deleted."; then
          tui_run_action 'Destroy selected demo' tui_destroy_action
          tui_force_retry 'Destroy selected demo' tui_destroy_force_action
        fi
        ;;
      8) tui_select_components ;;
      9) tui_select_manifest ;;
      10) tui_wizard_screen ;;
      11) tui_leave_screen; return 0 ;;
    esac
  done
}
usage() {
  cat <<'EOF'
Usage:
  leroy.sh [global options] [tui|status]
  leroy.sh [global options] environments {list|get ID}
  leroy.sh demo preset [--schema 1|2]
  leroy.sh demo wizard
  leroy.sh [global options] demo list
  leroy.sh [global options] demo state [--demo-id ID] [--file FILE]
  leroy.sh [global options] demo plan|apply|verify [--file FILE] [--deep]
  leroy.sh [global options] demo destroy --demo-id ID --yes [--force]
  leroy.sh [global options] demo recreate [--file FILE] --yes [--force]

Global options: --config FILE, --output table|json, -h|--help, -V|--version

demo list and demo state read local state only and need no appliance credentials.
EOF
}

main() {
  local config_file="" output_override="" command="" action="" manifest_file="" demo_id="leroy-demo"
  local yes=false force=false deep=false demo_id_set=false saved_manifest schema=1
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
        --schema) (($# >= 2)) || { die "$EXIT_USAGE" '--schema requires a value'; return; }; schema="$2"; shift 2 ;;
        *) die "$EXIT_USAGE" "unknown demo option: $1"; return ;;
      esac
    done
    case "$action" in
      preset)
        require_command jq || return
        case "$schema" in
          1) preset_manifest | jq -S . ;;
          2) preset_manifest_v2 | jq -S . ;;
          *) die "$EXIT_USAGE" 'schema must be 1 or 2'; return ;;
        esac
        return
        ;;
      wizard) require_command jq; wizard_manifest; return ;;
    esac
  fi

  load_config "$config_file" || return
  [[ -z "$output_override" ]] || LEROY_OUTPUT="$output_override"

  if [[ "$command" == demo ]]; then
    case "$action" in
      list)
        require_command jq || return
        demo_list
        return
        ;;
      state)
        require_command jq || return
        if [[ -n "$manifest_file" ]]; then manifest_to_temp "$manifest_file" || return; else select_state "$demo_id" || return; fi
        demo_state_report
        return
        ;;
    esac
  fi

  prompt_missing_runtime_config
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
        *) die "$EXIT_USAGE" 'usage: leroy.sh demo {preset|wizard|list|state|plan|apply|verify|destroy|recreate}' ;;
      esac
      ;;
    *) die "$EXIT_USAGE" "unknown command: $command" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
