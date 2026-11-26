#!/usr/bin/env bash
# Apply the 'Theme Colours' light/dark conditional formatting from a template
# report to every other report in the fabric/ tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

THEME_JQ="${SCRIPT_DIR}/lib/theme_colours.jq"
FABRIC_REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Apply 'Theme Colours' conditional formatting to reports.

For each report (other than the template) the script:
  1. Copies the 'Theme Colours' and 'Display Mode' tables from the template
     semantic model into the report's semantic model, if they are missing.
     Measures that depend on template-only measures are left out.
  2. Copies the template's custom theme (fonts, palette) into the report,
     if the report has no custom theme.
  3. Binds visual colours (background, border, title, axis labels, data
     labels, card text, table cells) to the Theme Colours measures.

Colours that are already bound to a measure, rule or gradient are left alone.
Hard-coded hex colours are replaced unless --keep-literals is given. Running
the script twice changes nothing the second time.

Usage:
  apply_theme_colours.sh [options]

Options:
  --source <dir>      Folder holding item definitions (default: fabric).
  --template <name>   Report whose model and theme are the source of truth
                      (default: "BT Theme Demo").
  --report <name>     Only process this report (repeatable). Default: all.
  --keep-literals     Do not replace hard-coded hex colours.
  --check             Change nothing; exit 1 if any report needs updating.
  -h, --help          Show this help.
EOF
}

CHECK="false"
# write_if_changed usually runs at the end of a pipeline (a subshell), so the
# count of changed files is kept in a file rather than a variable.
PENDING_FILE="$(mktemp)"
trap 'rm -f "$PENDING_FILE"' EXIT
pending_count() { wc -l <"$PENDING_FILE" | tr -d ' '; }

# Write stdin to <target> when its content differs. JSON files are compared
# semantically so formatting-only differences are not rewritten.
# Args: <target> <kind:json|text>
write_if_changed() {
  local target="$1" kind="$2" tmp
  tmp="$(mktemp)"
  # jq on Windows emits CRLF; keep the repo's LF line endings.
  tr -d '\r' >"$tmp"
  if [[ -f "$target" ]]; then
    if [[ "$kind" == "json" ]]; then
      if [[ "$(jq -S . "$target")" == "$(jq -S . "$tmp")" ]]; then rm -f "$tmp"; return 0; fi
    elif cmp -s "$target" "$tmp"; then
      rm -f "$tmp"; return 0
    fi
  fi
  echo "$target" >>"$PENDING_FILE"
  if [[ "$CHECK" == "true" ]]; then
    log_warn "Needs update: ${target#"${FABRIC_REPO_ROOT}/"}"
    rm -f "$tmp"
  else
    mkdir -p "$(dirname "$target")"
    mv "$tmp" "$target"
    log_info "Updated ${target#"${FABRIC_REPO_ROOT}/"}"
  fi
}

# Read the light/dark hex pair of every simple colour measure in the template's
# Theme Colours table, e.g.
#   measure 'Colour Text' = IF ( [Display Mode Selected] = "Dark", "#F7F7F7", "#2A2A2A" )
# Echoes {"Colour Text": {"dark": "#F7F7F7", "light": "#2A2A2A"}, ...}
read_colours() {
  local tmdl="$1"
  tr -d '\r' <"$tmdl" \
    | sed -nE "s/^[[:space:]]*measure '([^']+)'[[:space:]]*=[[:space:]]*IF[[:space:]]*\([[:space:]]*\[Display Mode Selected\][[:space:]]*=[[:space:]]*\"Dark\"[[:space:]]*,[[:space:]]*\"(#[0-9A-Fa-f]{6})\"[[:space:]]*,[[:space:]]*\"(#[0-9A-Fa-f]{6})\".*/\1\t\2\t\3/p" \
    | jq -Rn '[inputs | split("\t") | {key: .[0], value: {dark: .[1], light: .[2]}}] | from_entries'
}

# Print a TMDL table file without the measures that reference a measure
# defined outside that table (e.g. 'Colour Variance' -> [Variance vs Target %]),
# so the copied table still validates in a model that lacks them.
# Dropped measure names are written to stderr as "DROPPED <name>".
strip_unresolved_measures() {
  tr -d '\r' <"$1" | awk '
    # Pass 1 (first copy of the input): collect measure and column names.
    NR == FNR {
      if (match($0, /^\t(measure|column) /)) {
        n = substr($0, RLENGTH + 1)
        if (n ~ /^'\''/) { sub(/^'\''/, "", n); sub(/'\''.*/, "", n) } else { sub(/[ =].*/, "", n) }
        known[n] = 1
      }
      next
    }
    function unresolved(text,   s, ref) {
      s = text
      # Unqualified [Name] references only; Table[Column] is left alone.
      while (match(s, /(^|[^]'\''A-Za-z0-9_])\[[^]]+\]/)) {
        ref = substr(s, RSTART, RLENGTH)
        sub(/^[^[]*\[/, "", ref); sub(/\]$/, "", ref)
        if (!(ref in known)) return 1
        s = substr(s, RSTART + RLENGTH)
      }
      return 0
    }
    function flush() {
      if (block != "") {
        if (is_measure && unresolved(block)) print "DROPPED " name > "/dev/stderr"
        else printf "%s", block
      }
      block = ""; has_member = 0; is_measure = 0; name = ""
    }
    /^\t\/\/\// { if (has_member) flush(); block = block $0 "\n"; next }
    /^\t[^\t]/ {
      if (has_member) flush()
      has_member = 1
      if ($0 ~ /^\tmeasure /) {
        is_measure = 1
        name = $0; sub(/^\tmeasure '\''?/, "", name); sub(/'\''? *=.*/, "", name)
      }
      block = block $0 "\n"; next
    }
    /^\t\t/ || /^[[:space:]]*$/ { if (block != "") { block = block $0 "\n"; next } }
    { flush(); print }
    END { flush() }
  ' - <(tr -d '\r' <"$1")
}

# Ensure the report's semantic model has the Theme Colours and Display Mode tables.
# Args: <model_dir> <template_model_dir>
sync_model() {
  local model_dir="$1" template_model="$2"
  local table src dst model_tmdl
  model_tmdl="${model_dir}/definition/model.tmdl"
  [[ -f "$model_tmdl" ]] || { log_warn "No TMDL model at ${model_dir}; skipping model update"; return 1; }

  for table in "Display Mode" "Theme Colours"; do
    src="${template_model}/definition/tables/${table}.tmdl"
    dst="${model_dir}/definition/tables/${table}.tmdl"
    if [[ ! -f "$dst" ]]; then
      local dropped
      dropped="$(mktemp)"
      strip_unresolved_measures "$src" 2>"$dropped" | write_if_changed "$dst" text
      while read -r _ measure; do
        log_info "  Left out measure '${measure}' (depends on measures only in the template model)"
      done <"$dropped"
      rm -f "$dropped"
    fi
    if ! tr -d '\r' <"$model_tmdl" | grep -Fxq "ref table '${table}'"; then
      { tr -d '\r' <"$model_tmdl" | sed -e '$a\'; echo "ref table '${table}'"; } | write_if_changed "$model_tmdl" text
    fi
  done
}

# Copy the template's custom theme into the report when it has none.
# Args: <report_dir> <template_report_dir>
sync_theme() {
  local report_dir="$1" template_report="$2"
  local report_json="${report_dir}/definition/report.json"
  local template_json="${template_report}/definition/report.json"
  [[ -f "$report_json" ]] || return 0

  if [[ "$(jq -r '.themeCollection.customTheme.name // empty' "$report_json")" != "" ]]; then
    log_debug "  Report already has a custom theme; leaving it"
    return 0
  fi

  local theme_name theme_path
  theme_name="$(jq -r '.themeCollection.customTheme.name // empty' "$template_json" | tr -d '\r')"
  [[ -z "$theme_name" ]] && return 0
  theme_path="$(jq -r --arg n "$theme_name" \
    '.resourcePackages[]? | select(.type == "RegisteredResources") | .items[] | select(.name == $n) | .path' \
    "$template_json" | tr -d '\r')"

  tr -d '\r' <"${template_report}/StaticResources/RegisteredResources/${theme_path}" \
    | write_if_changed "${report_dir}/StaticResources/RegisteredResources/${theme_path}" text

  jq --slurpfile tpl "$template_json" --arg n "$theme_name" --arg p "$theme_path" '
    .themeCollection.customTheme = $tpl[0].themeCollection.customTheme
    | .resourcePackages = (.resourcePackages // [])
    | if any(.resourcePackages[]; .type == "RegisteredResources") then .
      else .resourcePackages += [{name: "RegisteredResources", type: "RegisteredResources", items: []}] end
    | .resourcePackages |= map(
        if .type == "RegisteredResources" and (any(.items[]; .name == $n) | not)
        then .items += [{name: $n, path: $p, type: "CustomTheme"}] else . end)
  ' "$report_json" | write_if_changed "$report_json" json
}

# Bind every visual in the report to the Theme Colours measures.
# Args: <report_dir> <colours_json>
sync_visuals() {
  local report_dir="$1" colours="$2" keep_literals="$3" visual out
  while IFS= read -r -d '' visual; do
    out="$(jq --argjson colours "$colours" --argjson keep_literals "$keep_literals" \
      -f "$THEME_JQ" "$visual")" || die "Failed to process ${visual}"
    printf '%s' "$out" | write_if_changed "$visual" json
  done < <(find "${report_dir}/definition/pages" -name visual.json -print0 2>/dev/null | sort -z)
}

main() {
  local source_dir="" template="BT Theme Demo" keep_literals="false"
  local -a only_reports=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) source_dir="${2:-}"; shift 2 ;;
      --template) template="${2:-}"; shift 2 ;;
      --report) only_reports+=("${2:-}"); shift 2 ;;
      --keep-literals) keep_literals="true"; shift ;;
      --check) CHECK="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  command -v jq >/dev/null || die "jq is required"
  source_dir="${source_dir:-${FABRIC_REPO_ROOT}/fabric}"
  source_dir="$(cd "$source_dir" && pwd)"

  local template_report="${source_dir}/${template}.Report"
  local template_model="${source_dir}/${template}.SemanticModel"
  local template_tmdl="${template_model}/definition/tables/Theme Colours.tmdl"
  [[ -d "$template_report" ]] || die "Template report not found: ${template_report}"
  [[ -f "$template_tmdl" ]] || die "Template model has no 'Theme Colours' table: ${template_tmdl}"

  local colours
  colours="$(read_colours "$template_tmdl")"
  [[ "$(jq 'length' <<<"$colours")" -gt 0 ]] || die "No colour measures found in ${template_tmdl}"
  log_info "Loaded $(jq 'length' <<<"$colours") colour measures from '${template}'"

  local report_dir name pbir model_path model_dir processed=0
  for report_dir in "${source_dir}"/*.Report; do
    [[ -d "$report_dir" ]] || continue
    name="$(basename "$report_dir" .Report)"
    [[ "$name" == "$template" ]] && continue
    if [[ ${#only_reports[@]} -gt 0 ]] && ! printf '%s\n' "${only_reports[@]}" | grep -Fxq "$name"; then
      continue
    fi

    log_info "Report '${name}'"
    pbir="${report_dir}/definition.pbir"
    model_path="$(jq -r '.datasetReference.byPath.path // empty' "$pbir" | tr -d '\r')"
    if [[ -z "$model_path" ]]; then
      log_warn "  Bound to a model outside this repo (byConnection); cannot add the Theme Colours tables. Skipping."
      continue
    fi
    model_dir="$(cd "${report_dir}/${model_path}" 2>/dev/null && pwd)" \
      || { log_warn "  Semantic model '${model_path}' not found. Skipping."; continue; }

    sync_model "$model_dir" "$template_model" || continue
    sync_theme "$report_dir" "$template_report"
    sync_visuals "$report_dir" "$colours" "$keep_literals"
    processed=$((processed + 1))
  done

  log_info "Processed ${processed} report(s)"
  local pending
  pending="$(pending_count)"
  if [[ "$CHECK" == "true" && "$pending" -gt 0 ]]; then
    die "${pending} file(s) need Theme Colours formatting. Run scripts/apply_theme_colours.sh and commit the result."
  fi
  [[ "$pending" -eq 0 ]] && log_info "All reports already use Theme Colours"
  return 0
}

main "$@"
