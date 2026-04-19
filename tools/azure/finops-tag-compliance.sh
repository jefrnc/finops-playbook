#!/bin/bash
# finops-tag-compliance.sh
#
# Reports tag compliance across the subscription for the list of mandatory tags.
# Output:
#   - CSV of every non-compliant resource (one row per missing tag)
#   - CSV "backfill plan" suggesting `env` / `app` inheritance from the resource group
#   - markdown executive summary with coverage by tag, by resource type, by RG
#
# Usage:
#   FINOPS_PROFILE=acme ./finops-tag-compliance.sh
#   FINOPS_REQUIRED_TAGS="env app owner" AZ_SUBSCRIPTION=<id> ./finops-tag-compliance.sh

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
REPORT="$(timestamp_file tag-compliance-report md)"
NC_CSV="$(timestamp_file tag-noncompliant csv)"
BACKFILL_CSV="$(timestamp_file tag-backfill-plan csv)"
SNAPSHOT="$(timestamp_file tag-snapshot json)"

log_info "fetching resources and resource groups..."
az resource list --query "[].{id:id, name:name, type:type, rg:resourceGroup, tags:tags}" -o json > "$SNAPSHOT"
RG_TAGS=$(az group list --query "[].{name:name, tags:tags}" -o json)

TOTAL=$(jq 'length' "$SNAPSHOT")

# ---------- non-compliance matrix ----------
echo "resource_id,resource_name,resource_group,type,missing_tag" > "$NC_CSV"
for tag in $FINOPS_REQUIRED_TAGS; do
  jq -r --arg t "$tag" '.[] | select(.tags[$t] == null) | [.id, .name, .rg, .type, $t] | @csv' "$SNAPSHOT" >> "$NC_CSV"
done

# helper: count missing occurrences for a tag (reads from CSV)
_miss_count() {
  awk -F',' -v t="$1" 'NR>1 { gsub(/"/,"",$5); if ($5==t) c++ } END{ print c+0 }' "$NC_CSV"
}

# ---------- backfill plan: suggest inherit-from-RG for env / app ----------
echo "resource_id,resource_name,resource_group,type,tag_to_apply,suggested_value,source" > "$BACKFILL_CSV"
for tag in $FINOPS_REQUIRED_TAGS; do
  jq -r --arg t "$tag" --argjson rgTags "$RG_TAGS" '
    .[]
    | select(.tags[$t] == null)
    | . as $r
    | ($rgTags | map(select(.name == $r.rg)) | .[0].tags[$t]) as $rgVal
    | select($rgVal != null)
    | [.id, .name, .rg, .type, $t, $rgVal, "inherit-from-rg"] | @csv
  ' "$SNAPSHOT" >> "$BACKFILL_CSV"
done
BACKFILL_COUNT=$(( $(wc -l < "$BACKFILL_CSV") - 1 ))

# ---------- render report ----------
{
  md_title "Azure Tag Compliance Report"
  md_kv "Generated" "$(_ts)"
  md_kv "Subscription" "$(az account show --query name -o tsv)"
  md_kv "Total resources" "$TOTAL"
  md_kv "Mandatory tags" "$FINOPS_REQUIRED_TAGS"
  echo

  md_h2 "Coverage per tag"
  md_table_header "Tag|With tag|Without tag|Coverage %"
  for tag in $FINOPS_REQUIRED_TAGS; do
    MISS=$(_miss_count "$tag")
    HAVE=$(( TOTAL - MISS ))
    PCT=$(awk "BEGIN{printf \"%.1f\", ($HAVE/$TOTAL)*100}")
    BAR=$(awk -v p="$PCT" 'BEGIN{ n=int(p/5); for(i=0;i<n;i++) printf "#"; for(i=n;i<20;i++) printf "."; }')
    echo "| $tag | $HAVE | $MISS | $PCT%  \`$BAR\` |"
  done
  echo

  md_h2 "Top 15 resource groups with missing tags"
  md_table_header "Resource Group|Missing occurrences"
  tail -n +2 "$NC_CSV" | awk -F',' '{gsub(/"/,"",$3); print $3}' | sort | uniq -c | sort -rn | head -15 \
    | awk '{count=$1; $1=""; sub(/^ /,""); printf "| %s | %d |\n", $0, count}'
  echo

  md_h2 "Top 10 resource types with missing tags"
  md_table_header "Resource Type|Missing occurrences"
  tail -n +2 "$NC_CSV" | awk -F',' '{gsub(/"/,"",$4); print $4}' | sort | uniq -c | sort -rn | head -10 \
    | awk '{count=$1; $1=""; sub(/^ /,""); printf "| %s | %d |\n", $0, count}'
  echo

  md_h2 "Backfill plan"
  md_kv "Auto-fixable by inheriting from RG" "$BACKFILL_COUNT"
  md_kv "Plan CSV" "$(basename "$BACKFILL_CSV")"
  echo
  echo "To apply the backfill plan:"
  echo
  echo '```bash'
  echo "# preview (dry-run)"
  echo "tail -n +2 $(basename "$BACKFILL_CSV") | awk -F',' '{printf \"az tag update --resource-id %s --operation merge --tags %s=%s\\n\", \$1, \$5, \$6}'"
  echo ""
  echo "# or: trigger Azure Policy remediation task in the Portal if the tagging initiative is assigned."
  echo '```'
  echo

  md_h2 "Detail files"
  md_kv "Non-compliance detail" "$(basename "$NC_CSV")"
  md_kv "Backfill plan" "$(basename "$BACKFILL_CSV")"
  md_kv "Source snapshot" "$(basename "$SNAPSHOT")"
} > "$REPORT"

log_info "report: $REPORT"
echo "$REPORT"
