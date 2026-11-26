#!/usr/bin/env bash
# Refresh the 'Display Mode' and 'Theme Colours' tables in deployed semantic
# models. Bulk import deploys model definitions without data, so until these
# import tables are refreshed the Mode toggle has no Light/Dark buttons.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=scripts/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=scripts/lib/fabric_api.sh
source "${SCRIPT_DIR}/lib/fabric_api.sh"

POWERBI_API_BASE_URL="${POWERBI_API_BASE_URL:-https://api.powerbi.com/v1.0/myorg}"
POWERBI_RESOURCE="${POWERBI_RESOURCE:-https://analysis.windows.net/powerbi/api}"
THEME_TABLES=("Display Mode" "Theme Colours")

usage() {
  cat <<'EOF'
Refresh the Theme Colours tables in deployed semantic models.

Finds every semantic model in the source folder that has a 'Display Mode'
table, then runs an enhanced refresh of only the 'Display Mode' and
'Theme Colours' tables in the matching deployed model. Other tables are not
touched. Run it after import_workspace.sh.

Usage:
  refresh_theme_tables.sh --env <name> [options]

Options:
  --env <name>        Environment to load from config/<name>.env (required).
  --source <dir>      Folder holding item definitions (default: fabric).
  --dry-run           List the models that would be refreshed, then exit.
  -h, --help          Show this help.

The identity needs Contributor (or higher) on the workspace, and the tenant
must allow service principals to use Power BI APIs.
EOF
}

# Authenticated call to the Power BI REST API.
# Sets __PBI_STATUS and __PBI_BODY. Args: <method> <url> [data] [headers_out]
pbi_call() {
  local method="$1" url="$2" data="${3:-}" headers_out="${4:-/dev/null}" response
  local -a args=(-sS -w $'\n%{http_code}' -X "$method" "$url"
    -H "Authorization: Bearer ${PBI_TOKEN}" -D "$headers_out")
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data-binary "$data")
  response="$(curl "${args[@]}")" || die "Request to ${url} failed (network error)"
  __PBI_STATUS="$(printf '%s\n' "$response" | tail -n1 | tr -d '\r')"
  __PBI_BODY="$(printf '%s\n' "$response" | sed '$d')"
}

# Echo the display names of local semantic models that have a Display Mode table.
local_theme_models() {
  local source_dir="$1" model name
  for model in "${source_dir}"/*.SemanticModel; do
    [[ -f "${model}/definition/tables/Display Mode.tmdl" ]] || continue
    name="$(jq -r '.metadata.displayName // empty' "${model}/.platform" 2>/dev/null | tr -d '\r')"
    echo "${name:-$(basename "$model" .SemanticModel)}"
  done
}

# Start an enhanced refresh of the theme tables and wait for it to finish.
# Args: <workspace_id> <dataset_id> <display_name>
refresh_model() {
  local ws_id="$1" ds_id="$2" name="$3"
  local url="${POWERBI_API_BASE_URL}/groups/${ws_id}/datasets/${ds_id}/refreshes"
  local body headers request_id
  body="$(jq -nc '$ARGS.positional | {type: "full", commitMode: "transactional",
                  retryCount: 1, objects: map({table: .})}' --args "${THEME_TABLES[@]}")"
  headers="$(mktemp)"
  pbi_call POST "$url" "$body" "$headers"
  if [[ "$__PBI_STATUS" != "202" ]]; then
    rm -f "$headers"
    log_error "Refresh of '${name}' was not accepted (HTTP ${__PBI_STATUS}): $(jq -r '.error.message // .error.code // .' <<<"$__PBI_BODY" 2>/dev/null | head -c 300)"
    return 1
  fi
  # The request ID is the last segment of the Location header.
  request_id="$(__fabric_header "$headers" "Location")"
  request_id="${request_id##*/}"
  [[ -z "$request_id" ]] && request_id="$(__fabric_header "$headers" "x-ms-request-id")"
  rm -f "$headers"
  log_info "Refreshing ${THEME_TABLES[*]} in '${name}' (request ${request_id})"

  local attempt=0 status
  while (( attempt < FABRIC_LRO_MAX_ATTEMPTS )); do
    sleep "$FABRIC_LRO_DEFAULT_DELAY"
    pbi_call GET "${url}/${request_id}"
    status="$(jq -r '.extendedStatus // .status // empty' <<<"$__PBI_BODY" 2>/dev/null)"
    log_debug "Refresh ${request_id}: ${status:-unknown}"
    case "$status" in
      Completed) log_info "Refreshed '${name}'"; return 0 ;;
      Failed|Cancelled|Disabled|TimedOut)
        log_error "Refresh of '${name}' ${status}: $(jq -c '.messages // .serviceExceptionJson // empty' <<<"$__PBI_BODY" | head -c 500)"
        return 1 ;;
    esac
    attempt=$((attempt + 1))
  done
  log_error "Refresh of '${name}' did not finish within ${FABRIC_LRO_MAX_ATTEMPTS} polls"
  return 1
}

main() {
  local env_name="" source_dir="" dry_run="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) env_name="${2:-}"; shift 2 ;;
      --source) source_dir="${2:-}"; shift 2 ;;
      --dry-run) dry_run="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
  [[ -z "$env_name" ]] && { usage; die "Missing required --env"; }
  source_dir="${source_dir:-${FABRIC_REPO_ROOT}/fabric}"

  local -a models=()
  mapfile -t models < <(local_theme_models "$source_dir")
  if [[ ${#models[@]} -eq 0 ]]; then
    log_info "No semantic models with a 'Display Mode' table; nothing to refresh"
    return 0
  fi
  log_info "Models with theme tables: $(printf "'%s' " "${models[@]}")"
  [[ "$dry_run" == "true" ]] && return 0

  fabric::load_config "$env_name"
  FABRIC_TOKEN="$(fabric::get_token)"
  export FABRIC_TOKEN
  PBI_TOKEN="$(fabric::get_token "$POWERBI_RESOURCE")"

  local ws_id
  ws_id="$(fabric::resolve_workspace_id "$FABRIC_WORKSPACE_NAME")"
  __fabric_call GET "${FABRIC_API_BASE_URL}/workspaces/${ws_id}/semanticModels"
  [[ "$__API_LAST_STATUS" -ge 400 ]] && die "Failed to list semantic models (HTTP ${__API_LAST_STATUS})"
  local deployed="$__API_LAST_BODY"

  local name ds_id failed=0
  for name in "${models[@]}"; do
    ds_id="$(jq -r --arg n "$name" '.value[] | select(.displayName == $n) | .id' <<<"$deployed" | head -n1 | tr -d '\r')"
    if [[ -z "$ds_id" ]]; then
      log_warn "'${name}' is not deployed to '${FABRIC_WORKSPACE_NAME}'; skipping"
      continue
    fi
    refresh_model "$ws_id" "$ds_id" "$name" || failed=$((failed + 1))
  done

  [[ "$failed" -gt 0 ]] && die "${failed} model refresh(es) failed"
  log_info "Theme tables refreshed"
}

main "$@"
