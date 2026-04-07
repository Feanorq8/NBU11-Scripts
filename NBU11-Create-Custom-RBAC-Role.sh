#!/bin/bash

# NetBackup 11 - Create a custom RBAC role and assign permissions
# Supports:
#   --dry-run     Show requests only, do not execute
#   --pause       Pause before each POST
#   --insecure    Skip TLS certificate validation
#
# Based on NetBackup access-control APIs used in Veritas' public API samples.

set -euo pipefail

########################################
# User-editable variables
########################################

NB_MASTER="nbu-master.example.com"
NB_PORT="1556"

USERNAME="adminuser"
PASSWORD=""                    # Leave blank to prompt
DOMAIN_TYPE="unixpwd"          # unixpwd | nt | ldap
DOMAIN_NAME=""                 # e.g. cohesitylabs.az for ldap/nt, blank for unixpwd

ROLE_NAME="Custom Storage Viewer"
ROLE_DESCRIPTION="Custom role to view storage units, storage servers, jobs, and trusted master servers."

# Permission map:
# key   = managed object ID
# value = comma-separated operation IDs
#
# These managed object / operation identifiers are taken from Veritas' public
# RBAC template sample.
declare -A ROLE_PERMISSIONS=(
  ["|STORAGE|STORAGE-UNITS|"]="|OPERATIONS|VIEW|"
  ["|STORAGE|STORAGE-SERVERS|"]="|OPERATIONS|VIEW|"
  ["|STORAGE|TARGET-STORAGE-SERVERS|"]="|OPERATIONS|VIEW|"
  ["|MANAGE|JOBS|"]="|OPERATIONS|VIEW|"
  ["|MANAGE|SERVERS|TRUSTED-MASTER-SERVERS|"]="|OPERATIONS|VIEW|"
)

# Execution controls
DRY_RUN=false
PAUSE=false
INSECURE=false
DEBUG=false

########################################
# Parse arguments
########################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --pause)
      PAUSE=true
      shift
      ;;
    --insecure)
      INSECURE=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--dry-run] [--pause] [--insecure] [--debug]"
      exit 1
      ;;
  esac
done

########################################
# Helpers
########################################

BASE_URL="https://${NB_MASTER}:${NB_PORT}/netbackup"
TOKEN=""
API_VERSION=""
MEDIA_TYPE=""

curl_tls_opts=()
if $INSECURE; then
  curl_tls_opts+=(-k)
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

debug() {
  if $DEBUG; then
    echo "[DEBUG] $*"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1"
    exit 1
  }
}

pause_if_needed() {
  if $PAUSE; then
    read -r -p "Press Enter to continue or Ctrl+C to cancel..."
  fi
}

print_request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"

  echo
  echo "==== REQUEST PREVIEW ===="
  echo "Method : $method"
  echo "URL    : $url"
  echo "Accept : $MEDIA_TYPE"
  if [[ -n "$TOKEN" ]]; then
    echo "Auth   : Bearer/JWT token present"
  fi
  if [[ -n "$body" ]]; then
    echo "Body   :"
    echo "$body" | jq .
  fi
  echo "========================="
  echo
}

api_call() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local response_file
  local headers_file
  local http_code

  response_file=$(mktemp)
  headers_file=$(mktemp)

  print_request "$method" "$url" "$body"

  if $DRY_RUN; then
    echo "[DRY-RUN] Request not executed."
    rm -f "$response_file" "$headers_file"
    return 0
  fi

  pause_if_needed

  if [[ "$method" == "GET" ]]; then
    http_code=$(curl -sS "${curl_tls_opts[@]}" \
      -D "$headers_file" \
      -o "$response_file" \
      -w "%{http_code}" \
      -X GET \
      -H "Accept: $MEDIA_TYPE" \
      -H "Authorization: $TOKEN" \
      "$url")
  else
    http_code=$(curl -sS "${curl_tls_opts[@]}" \
      -D "$headers_file" \
      -o "$response_file" \
      -w "%{http_code}" \
      -X "$method" \
      -H "Accept: $MEDIA_TYPE" \
      -H "Content-Type: $MEDIA_TYPE" \
      -H "Authorization: $TOKEN" \
      --data "$body" \
      "$url")
  fi

  debug "HTTP code: $http_code"
  debug "Response headers:"
  debug "$(cat "$headers_file")"
  debug "Response body:"
  debug "$(cat "$response_file")"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "ERROR: API call failed with HTTP $http_code"
    echo "Response body:"
    cat "$response_file"
    rm -f "$response_file" "$headers_file"
    exit 1
  fi

  cat "$response_file"

  rm -f "$response_file" "$headers_file"
}

########################################
# Checks
########################################

require_cmd curl
require_cmd jq

########################################
# Get password if needed
########################################

if [[ -z "$PASSWORD" ]]; then
  read -rsp "Enter NetBackup password for ${USERNAME}: " PASSWORD
  echo
fi

########################################
# 1) Ping NetBackup and detect API version
########################################

log "Pinging NetBackup master ${NB_MASTER}..."

PING_HEADERS=$(mktemp)
PING_BODY=$(mktemp)

PING_CODE=$(curl -sS "${curl_tls_opts[@]}" \
  -D "$PING_HEADERS" \
  -o "$PING_BODY" \
  -w "%{http_code}" \
  "${BASE_URL}/ping")

if [[ "$PING_CODE" -lt 200 || "$PING_CODE" -ge 300 ]]; then
  echo "ERROR: Ping failed with HTTP $PING_CODE"
  cat "$PING_BODY"
  rm -f "$PING_HEADERS" "$PING_BODY"
  exit 1
fi

API_VERSION=$(awk -F': ' 'tolower($1)=="x-netbackup-api-version" {gsub("\r","",$2); print $2}' "$PING_HEADERS")

rm -f "$PING_HEADERS" "$PING_BODY"

if [[ -z "$API_VERSION" ]]; then
  echo "ERROR: Could not determine NetBackup API version from ping response."
  exit 1
fi

MEDIA_TYPE="application/vnd.netbackup+json;version=${API_VERSION}"
log "Detected NetBackup API version: ${API_VERSION}"

########################################
# 2) Login and get token
########################################

log "Logging in to NetBackup..."

if [[ -n "$DOMAIN_NAME" ]]; then
  LOGIN_JSON=$(jq -n \
    --arg user "$USERNAME" \
    --arg pass "$PASSWORD" \
    --arg dtype "$DOMAIN_TYPE" \
    --arg dname "$DOMAIN_NAME" \
    '{
      userName: $user,
      password: $pass,
      domainType: $dtype,
      domainName: $dname
    }')
else
  LOGIN_JSON=$(jq -n \
    --arg user "$USERNAME" \
    --arg pass "$PASSWORD" \
    --arg dtype "$DOMAIN_TYPE" \
    '{
      userName: $user,
      password: $pass,
      domainType: $dtype
    }')
fi

print_request "POST" "${BASE_URL}/login" "$LOGIN_JSON"

if $DRY_RUN; then
  echo "[DRY-RUN] Login not executed, so role creation and validation requests are shown only."
  TOKEN="DRY_RUN_TOKEN"
else
  pause_if_needed
  LOGIN_RESPONSE=$(curl -sS "${curl_tls_opts[@]}" \
    -X POST \
    -H "Content-Type: $MEDIA_TYPE" \
    --data "$LOGIN_JSON" \
    "${BASE_URL}/login")

  TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token // empty')

  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "ERROR: Login succeeded but token was not returned."
    echo "$LOGIN_RESPONSE"
    exit 1
  fi
fi

########################################
# 3) Create the role
########################################

ROLE_CREATE_JSON=$(jq -n \
  --arg name "$ROLE_NAME" \
  --arg desc "$ROLE_DESCRIPTION" \
  '{
    data: {
      type: "accessControlRole",
      attributes: {
        name: $name,
        description: $desc
      }
    }
  }')

ROLE_URL="${BASE_URL}/access-control/roles"

log "Creating RBAC role: ${ROLE_NAME}"

ROLE_ID=""
if $DRY_RUN; then
  print_request "POST" "$ROLE_URL" "$ROLE_CREATE_JSON"
  echo "[DRY-RUN] Role creation not executed."
  ROLE_ID="DRY_RUN_ROLE_ID"
else
  ROLE_RESPONSE=$(api_call "POST" "$ROLE_URL" "$ROLE_CREATE_JSON")
  ROLE_ID=$(echo "$ROLE_RESPONSE" | jq -r '.data.id // empty')

  if [[ -z "$ROLE_ID" || "$ROLE_ID" == "null" ]]; then
    echo "ERROR: Role created but role ID was not returned."
    echo "$ROLE_RESPONSE"
    exit 1
  fi

  log "Role created successfully with ID: ${ROLE_ID}"
fi

########################################
# 4) Create access definitions (permissions)
########################################

log "Creating access definitions..."

for MANAGED_OBJECT in "${!ROLE_PERMISSIONS[@]}"; do
  OPS_CSV="${ROLE_PERMISSIONS[$MANAGED_OBJECT]}"

  IFS=',' read -r -a OPS_ARRAY <<< "$OPS_CSV"

  OPS_JSON_ITEMS=()
  for OP in "${OPS_ARRAY[@]}"; do
    OPS_JSON_ITEMS+=("{\"type\":\"accessControlOperation\",\"id\":\"${OP}\"}")
  done

  OPS_JSON=$(printf '%s\n' "${OPS_JSON_ITEMS[@]}" | jq -s '.')

  ACCESS_DEF_JSON=$(jq -n \
    --arg role_id "$ROLE_ID" \
    --arg mo "$MANAGED_OBJECT" \
    --argjson ops "$OPS_JSON" \
    '{
      data: {
        type: "accessDefinition",
        attributes: {
          propagation: "OBJECT_AND_CHILDREN"
        },
        relationships: {
          role: {
            data: {
              type: "accessControlRole",
              id: $role_id
            }
          },
          operations: {
            data: $ops
          },
          managed_object: {
            data: {
              type: "managedObject",
              id: $mo
            }
          }
        }
      }
    }')

  ACCESS_DEF_URL="${BASE_URL}/access-control/managed-objects/${MANAGED_OBJECT}/access-definitions"

  log "Assigning permissions on managed object: ${MANAGED_OBJECT}"

  if $DRY_RUN; then
    print_request "POST" "$ACCESS_DEF_URL" "$ACCESS_DEF_JSON"
    echo "[DRY-RUN] Access definition not executed."
  else
    api_call "POST" "$ACCESS_DEF_URL" "$ACCESS_DEF_JSON" >/dev/null
    log "Access definition created successfully for ${MANAGED_OBJECT}"
  fi
done

########################################
# 5) Validation checks
########################################

log "Running validation checks..."

# List all roles
VALIDATE_ROLES_URL="${BASE_URL}/access-control/roles"
if $DRY_RUN; then
  print_request "GET" "$VALIDATE_ROLES_URL"
  echo "[DRY-RUN] Validation GET not executed."
else
  api_call "GET" "$VALIDATE_ROLES_URL" >/dev/null
  log "Role listing check passed."
fi

# Validate the specific role if real run
if ! $DRY_RUN; then
  ROLE_DETAILS_URL="${BASE_URL}/access-control/roles/${ROLE_ID}"
  api_call "GET" "$ROLE_DETAILS_URL" >/dev/null
  log "Role detail check passed for role ID ${ROLE_ID}."
fi

echo
echo "=============================================="
if $DRY_RUN; then
  echo "DRY-RUN COMPLETE"
  echo "No changes were made."
else
  echo "SUCCESS"
  echo "Role Name : ${ROLE_NAME}"
  echo "Role ID   : ${ROLE_ID}"
fi
echo "=============================================="