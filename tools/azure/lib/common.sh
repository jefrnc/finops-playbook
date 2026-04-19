#!/bin/bash
# common.sh — shared helpers for the FinOps toolkit
# Source this file from every utility script: `source "$(dirname "$0")/lib/common.sh"`

set -o pipefail
# force C locale so awk printf uses "." as decimal separator (not locale-dependent)
export LC_ALL="${LC_ALL:-C}"
export LC_NUMERIC="${LC_NUMERIC:-C}"

# ---------- config loading ----------
# Scripts must export TOOLKIT_DIR before sourcing this file.
# TOOLKIT_DIR is the directory containing the utility script (and lib/, config/, output/).
_toolkit_dir() {
  echo "${TOOLKIT_DIR:-$(pwd)}"
}

load_profile() {
  local profile="${FINOPS_PROFILE:-}"
  if [ -n "$profile" ]; then
    local dir
    dir="$(_toolkit_dir)"
    local cfg="$dir/config/${profile}.env"
    if [ -f "$cfg" ]; then
      # shellcheck disable=SC1090
      source "$cfg"
      log_info "loaded profile: $profile"
    else
      log_warn "profile file not found: $cfg"
    fi
  fi
}

# ---------- required vars ----------
require_env() {
  local missing=0
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo "ERROR: env var $v is required. Set via export or a profile file." >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 2
}

# ---------- logging ----------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "[$(_ts)] INFO  $*" >&2; }
log_warn()  { echo "[$(_ts)] WARN  $*" >&2; }
log_error() { echo "[$(_ts)] ERROR $*" >&2; }

# ---------- output paths ----------
output_dir() {
  local d
  d="$(_toolkit_dir)/output"
  mkdir -p "$d"
  echo "$d"
}

timestamp_file() {
  # usage: timestamp_file prefix ext  -> /.../output/prefix-YYYYMMDD-HHMMSS.ext
  local prefix="$1" ext="$2"
  echo "$(output_dir)/${prefix}-$(date '+%Y%m%d-%H%M%S').${ext}"
}

# ---------- azure cli helpers ----------
ensure_az_login() {
  if ! az account show >/dev/null 2>&1; then
    log_error "not logged into Azure. Run: az login"
    exit 3
  fi
  if [ -n "${AZ_SUBSCRIPTION:-}" ]; then
    az account set --subscription "$AZ_SUBSCRIPTION" 2>/dev/null || {
      log_error "cannot switch to subscription $AZ_SUBSCRIPTION"
      exit 3
    }
  fi
  local cur
  cur=$(az account show --query "name" -o tsv)
  log_info "subscription: $cur"
}

# ---------- markdown helpers ----------
md_title() { echo "# $1"; echo; }
md_h2()    { echo "## $1"; echo; }
md_kv()    { echo "- **$1:** $2"; }
md_table_header() {
  # usage: md_table_header "Col1|Col2|Col3"
  local IFS='|'
  read -ra cols <<< "$1"
  local line="|"
  local sep="|"
  for c in "${cols[@]}"; do line+=" $c |"; sep+=" --- |"; done
  echo "$line"
  echo "$sep"
}

# ---------- csv helpers ----------
csv_escape() {
  # minimal CSV escape: quote if contains comma or quote, double internal quotes
  local s="$1"
  if [[ "$s" == *,* || "$s" == *\"* ]]; then
    printf '"%s"' "${s//\"/\"\"}"
  else
    printf '%s' "$s"
  fi
}
