#!/usr/bin/env bash
# Authentication for the Fabric REST API.
# Supports two modes:
#   1. Service principal (client-credentials) — when FABRIC_CLIENT_SECRET is set.
#   2. Azure CLI user token — when FABRIC_CLIENT_SECRET is NOT set.
# Source this file; do not execute it directly.

if [[ -n "${__FABRIC_AUTH_SH_LOADED:-}" ]]; then
  return 0
fi
__FABRIC_AUTH_SH_LOADED=1

# Resolve the directory of this file so we can source siblings reliably.
__AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${__AUTH_DIR}/log.sh"

# Acquire a bearer token for the Fabric API.
# Mode is auto-detected:
#   - If FABRIC_CLIENT_SECRET is set: uses SPN client-credentials flow via curl.
#   - Otherwise: uses `az account get-access-token` (requires prior `az login`).
# Args: [resource] API to request a token for (default: the Fabric API).
#   Pass https://analysis.windows.net/powerbi/api for the Power BI REST API.
# Echoes the access token to stdout.
fabric::get_token() {
  local resource="${1:-https://api.fabric.microsoft.com}"
  if [[ -n "${FABRIC_CLIENT_SECRET:-}" ]]; then
    __fabric_get_token_spn "$resource"
  else
    __fabric_get_token_azcli "$resource"
  fi
}

# Internal: SPN client-credentials token acquisition.
__fabric_get_token_spn() {
  log_info "Acquiring token via SPN client-credentials flow (FABRIC_CLIENT_SECRET is set)"
  local authority_host="${FABRIC_AUTHORITY_HOST:-https://login.microsoftonline.com}"
  local scope="${1%/}/.default"

  : "${FABRIC_TENANT_ID:?FABRIC_TENANT_ID is required}"
  : "${FABRIC_CLIENT_ID:?FABRIC_CLIENT_ID is required for SPN auth}"
  : "${FABRIC_CLIENT_SECRET:?FABRIC_CLIENT_SECRET is required for SPN auth}"

  local token_url="${authority_host}/${FABRIC_TENANT_ID}/oauth2/v2.0/token"
  log_debug "Requesting token for client $(mask_secret "$FABRIC_CLIENT_ID") from ${token_url}"
  
  local response token    
  response="$(curl -sS -X POST "$token_url" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${FABRIC_CLIENT_ID}" \
    --data-urlencode "client_secret=${FABRIC_CLIENT_SECRET}" \
    --data-urlencode "scope=${scope}" \
    --data-urlencode "grant_type=client_credentials")" \
    || die "Token request failed (network error)"

  token="$(jq -r '.access_token // empty' <<<"$response")"
  if [[ -z "$token" ]]; then
    local err
    err="$(jq -r '.error_description // .error // "unknown error"' <<<"$response" 2>/dev/null || echo "unparseable response")"
    die "Failed to acquire token: ${err}"
  fi

  log_debug "Acquired bearer token (SPN)"
  printf '%s' "$token"
}

# Internal: Azure CLI user-token acquisition.
__fabric_get_token_azcli() {
  log_info "Acquiring token via Azure CLI (FABRIC_CLIENT_SECRET is NOT set)"
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required for user-token auth but not found in PATH"
  : "${FABRIC_TENANT_ID:?FABRIC_TENANT_ID is required for az-cli auth}"

  local resource="$1"
  log_debug "Requesting token via Azure CLI for resource ${resource}"

  local token
  token="$(az account get-access-token \
    --resource "${resource}" \
    --tenant "${FABRIC_TENANT_ID}" \
    --query "accessToken" \
    -o tsv 2>/dev/null | tr -d '\r')" \
    || die "Failed to acquire token via Azure CLI. Run 'az login --tenant ${FABRIC_TENANT_ID}' first."

  if [[ -z "$token" ]]; then
    die "az account get-access-token returned an empty token. Run 'az login --tenant ${FABRIC_TENANT_ID}' first."
  fi

  log_debug "Acquired bearer token (az cli)"
  printf '%s' "$token"
}
