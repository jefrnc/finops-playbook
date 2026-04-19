#!/bin/bash
# finops-cost-by-tag.sh
#
# Queries Azure Cost Management and groups the last N days of cost by tag dimension.
# Produces CSV + markdown with ASCII bar charts.
#
# Usage:
#   FINOPS_PROFILE=ecipsa ./finops-cost-by-tag.sh env
#   FINOPS_PROFILE=ecipsa FINOPS_COST_DAYS=60 ./finops-cost-by-tag.sh app
#   AZ_SUBSCRIPTION=<id> ./finops-cost-by-tag.sh env 30

set -e
export LC_ALL=C LC_NUMERIC=C
TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TOOLKIT_DIR
SCRIPT_DIR="$TOOLKIT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TAG_NAME="${1:-env}"
DAYS="${2:-${FINOPS_COST_DAYS:-30}}"

load_profile
require_env AZ_SUBSCRIPTION
ensure_az_login

TO_DATE=$(date -u '+%Y-%m-%dT23:59:59Z')
FROM_DATE=$(date -u -v-"${DAYS}"d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d "-${DAYS} days" '+%Y-%m-%dT00:00:00Z')

REPORT="$(timestamp_file cost-by-${TAG_NAME} md)"
CSV="$(timestamp_file cost-by-${TAG_NAME} csv)"
RAW_JSON="$(timestamp_file cost-by-${TAG_NAME}-raw json)"

log_info "querying Cost Management API for tag '$TAG_NAME' from $FROM_DATE to $TO_DATE..."

BODY=$(cat <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": { "from": "$FROM_DATE", "to": "$TO_DATE" },
  "dataset": {
    "granularity": "None",
    "aggregation": { "totalCost": { "name": "Cost", "function": "Sum" } },
    "grouping": [ { "type": "TagKey", "name": "$TAG_NAME" } ]
  }
}
EOF
)

az rest --method post \
  --url "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body "$BODY" \
  --headers "Content-Type=application/json" > "$RAW_JSON"

# Cost Mgmt API columns when grouping by TagKey: [Cost, TagKey, TagValue, Currency]
jq -r '
  .properties.rows // []
  | .[]
  | [
      (.[0]|tostring),
      ((.[2] // "") | gsub("^\""; "") | gsub("\"$"; "") | (if . == "" or . == null then "(untagged)" else . end)),
      (.[3] // "USD")
    ]
  | @csv
' "$RAW_JSON" > "${CSV}.tmp"

# header + sort descending by cost
echo "cost,${TAG_NAME}_value,currency" > "$CSV"
sort -t',' -k1 -gr "${CSV}.tmp" >> "$CSV"
rm "${CSV}.tmp"

TOTAL=$(awk -F',' 'NR>1 { c=$1; gsub(/"/,"",c); s+=c } END{printf "%.2f", s+0}' "$CSV")
if [ -z "$TOTAL" ] || [ "$TOTAL" = "0.00" ]; then
  log_warn "no cost data returned by Cost Management API for the window $FROM_DATE → $TO_DATE"
fi

# ---------- render ----------
{
  md_title "Cost by tag: \`$TAG_NAME\`"
  md_kv "Generated" "$(_ts)"
  md_kv "Subscription" "$(az account show --query name -o tsv)"
  md_kv "Window" "$FROM_DATE → $TO_DATE ($DAYS days)"
  md_kv "Total cost" "USD $TOTAL"
  echo

  md_h2 "Breakdown"
  md_table_header "${TAG_NAME} value|Cost (USD)|Share|Bar"
  awk -F',' -v total="$TOTAL" 'NR>1 {
    gsub(/"/,"")
    cost=$1+0; val=$2
    pct = (total+0 > 0) ? (cost/total)*100 : 0
    barlen = int(pct/2)
    bar=""
    for (i=0;i<barlen;i++) bar=bar"#"
    printf "| %s | %.2f | %.1f%% | `%s` |\n", val, cost, pct, bar
  }' "$CSV"
  echo

  md_h2 "Notes"
  echo "- \`(untagged)\` represents cost of resources without the tag — which means the cost cannot be attributed."
  echo "- Cost comes from actual billed usage in the window, not forecasted."
  echo "- Retry after running \`finops-tag-compliance.sh\` and applying the backfill plan to improve allocation."
} > "$REPORT"

log_info "report: $REPORT"
log_info "csv:    $CSV"
echo "$REPORT"
