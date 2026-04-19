#!/bin/bash
# finops-drift-weekly.sh
#
# Detects weekly drift in an Azure subscription:
#   - new resource groups not in the known list
#   - new resources since the last baseline
#   - removed resources
#   - resources missing mandatory tags
#
# Produces a markdown report and the new baseline snapshot.
#
# Usage:
#   FINOPS_PROFILE=acme ./finops-drift-weekly.sh
#   # or
#   AZ_SUBSCRIPTION=<sub-id> FINOPS_REQUIRED_TAGS="env app" FINOPS_KNOWN_RGS="rg-a rg-b" ./finops-drift-weekly.sh

set -e
TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TOOLKIT_DIR
SCRIPT_DIR="$TOOLKIT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_profile
require_env AZ_SUBSCRIPTION FINOPS_REQUIRED_TAGS
ensure_az_login

OUT_DIR="$(output_dir)"
BASELINE="$OUT_DIR/drift-baseline.json"
NEW_SNAPSHOT="$(timestamp_file drift-snapshot json)"
REPORT="$(timestamp_file drift-report md)"

log_info "snapshotting current resources..."
az resource list --query "[].{id:id, name:name, type:type, rg:resourceGroup, sku:sku.name, tags:tags}" -o json > "$NEW_SNAPSHOT"
TOTAL=$(jq 'length' "$NEW_SNAPSHOT")
log_info "total resources: $TOTAL"

# ---------- compare vs baseline ----------
NEW_IDS=""
REMOVED_IDS=""
NEW_COUNT=0
REMOVED_COUNT=0
if [ -f "$BASELINE" ]; then
  NEW_IDS=$(jq -r --slurpfile old "$BASELINE" '
    . as $cur
    | ($old[0] | map(.id)) as $oldIds
    | $cur | map(select(.id as $i | $oldIds | index($i) | not)) | .[].id
  ' "$NEW_SNAPSHOT")
  REMOVED_IDS=$(jq -r --slurpfile new "$NEW_SNAPSHOT" '
    . as $old
    | ($new[0] | map(.id)) as $newIds
    | $old | map(select(.id as $i | $newIds | index($i) | not)) | .[].id
  ' "$BASELINE")
  NEW_COUNT=$(echo "$NEW_IDS" | grep -c . || true)
  REMOVED_COUNT=$(echo "$REMOVED_IDS" | grep -c . || true)
else
  log_warn "no baseline found — this run becomes the baseline"
fi

# ---------- untagged scan ----------
MISSING_TAGS_CSV="$(timestamp_file drift-missing-tags csv)"
echo "resource_id,resource_name,resource_group,type,missing_tags" > "$MISSING_TAGS_CSV"
for tag in $FINOPS_REQUIRED_TAGS; do
  # shellcheck disable=SC2016
  jq -r --arg t "$tag" '
    .[] | select(.tags[$t] == null) | [.id, .name, .rg, .type, $t] | @csv
  ' "$NEW_SNAPSHOT" >> "$MISSING_TAGS_CSV" || true
done
MISSING_COUNT=$(( $(wc -l < "$MISSING_TAGS_CSV") - 1 ))

# ---------- unknown RGs ----------
UNKNOWN_RGS=""
if [ -n "${FINOPS_KNOWN_RGS:-}" ]; then
  CURRENT_RGS=$(jq -r '[.[].rg] | unique | .[]' "$NEW_SNAPSHOT")
  for rg in $CURRENT_RGS; do
    # shellcheck disable=SC2076
    if ! [[ " $FINOPS_KNOWN_RGS " =~ " $rg " ]]; then
      UNKNOWN_RGS+="$rg"$'\n'
    fi
  done
fi

# ---------- render report ----------
{
  md_title "Azure FinOps Drift Report"
  md_kv "Generated" "$(_ts)"
  md_kv "Subscription" "$(az account show --query name -o tsv)"
  md_kv "Total resources" "$TOTAL"
  md_kv "Baseline comparison" "$( [ -f "$BASELINE" ] && echo "vs previous snapshot" || echo "N/A (first run)" )"
  echo

  md_h2 "Summary"
  md_kv "New resources since last run" "$NEW_COUNT"
  md_kv "Removed resources since last run" "$REMOVED_COUNT"
  md_kv "Resources missing mandatory tags (occurrences)" "$MISSING_COUNT"
  md_kv "Unknown resource groups" "$(echo -n "$UNKNOWN_RGS" | grep -c . || echo 0)"
  echo

  if [ "$NEW_COUNT" -gt 0 ]; then
    md_h2 "New resources"
    md_table_header "Name|Type|Resource Group"
    echo "$NEW_IDS" | while read -r id; do
      [ -z "$id" ] && continue
      row=$(jq -r --arg i "$id" '.[] | select(.id==$i) | "| \(.name) | \(.type) | \(.rg) |"' "$NEW_SNAPSHOT")
      echo "$row"
    done
    echo
  fi

  if [ "$REMOVED_COUNT" -gt 0 ]; then
    md_h2 "Removed resources"
    echo "$REMOVED_IDS" | sed 's|^|- |'
    echo
  fi

  if [ -n "$UNKNOWN_RGS" ]; then
    md_h2 "Unknown resource groups (not in FINOPS_KNOWN_RGS)"
    echo "$UNKNOWN_RGS" | grep . | sed 's|^|- |'
    echo
  fi

  md_h2 "Tag compliance hotspots"
  md_kv "Full detail" "$(basename "$MISSING_TAGS_CSV")"
  echo
  echo "Top 10 resource groups with missing tags:"
  echo
  md_table_header "Resource Group|Missing tag occurrences"
  tail -n +2 "$MISSING_TAGS_CSV" | awk -F',' '{gsub(/"/,"",$3); print $3}' | sort | uniq -c | sort -rn | head -10 \
    | awk '{count=$1; $1=""; sub(/^ /,""); printf "| %s | %d |\n", $0, count}'
  echo

  md_h2 "Next steps"
  echo "1. Review new resources above — confirm they are expected (tagged, sized, approved)."
  echo "2. Validate removed resources are intentional (check changelog)."
  echo "3. For missing-tags hotspots, run \`finops-tag-compliance.sh\` for full backfill plan."
  echo "4. If a tagging policy initiative is deployed, trigger remediation tasks in Azure Portal."
} > "$REPORT"

# promote snapshot to new baseline
cp "$NEW_SNAPSHOT" "$BASELINE"

log_info "report:   $REPORT"
log_info "baseline: $BASELINE (updated)"
log_info "missing-tags CSV: $MISSING_TAGS_CSV"
echo "$REPORT"
