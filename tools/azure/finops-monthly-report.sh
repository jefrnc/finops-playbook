#!/bin/bash
# finops-monthly-report.sh
#
# Orchestrator: runs drift, waste, tag-compliance and cost-by-tag,
# then consolidates the results into a single executive monthly report.
#
# Usage:
#   FINOPS_PROFILE=acme ./finops-monthly-report.sh
#   AZ_SUBSCRIPTION=<id> FINOPS_REQUIRED_TAGS="env app" ./finops-monthly-report.sh

set -e
# force C locale so awk printf uses "." as decimal separator
export LC_ALL=C LC_NUMERIC=C
TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TOOLKIT_DIR
SCRIPT_DIR="$TOOLKIT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_profile
require_env AZ_SUBSCRIPTION FINOPS_REQUIRED_TAGS
ensure_az_login

MONTH=$(date '+%Y-%m')
REPORT="$(output_dir)/finops-monthly-${MONTH}.md"

log_info "running drift..."
DRIFT_REPORT=$(bash "$SCRIPT_DIR/finops-drift-weekly.sh" | tail -1)

log_info "running waste hunter..."
WASTE_REPORT=$(bash "$SCRIPT_DIR/finops-waste-hunter.sh" | tail -1)

log_info "running tag compliance..."
TAG_REPORT=$(bash "$SCRIPT_DIR/finops-tag-compliance.sh" | tail -1)

log_info "running cost-by-tag (env)..."
COST_ENV_REPORT=$(bash "$SCRIPT_DIR/finops-cost-by-tag.sh" env 30 | tail -1)

# Cost Management API rate-limits aggressively; pause between consecutive queries
sleep 5

log_info "running cost-by-tag (app)..."
COST_APP_REPORT=$(bash "$SCRIPT_DIR/finops-cost-by-tag.sh" app 30 | tail -1)

# ---------- subscription-level KPIs ----------
SUB_NAME=$(az account show --query name -o tsv)
TOTAL_RES=$(az resource list --query "length(@)" -o tsv)
TOTAL_RGS=$(az group list --query "length(@)" -o tsv)

# cost last 30d
FROM=$(date -u -v-30d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d "-30 days" '+%Y-%m-%dT00:00:00Z')
TO=$(date -u '+%Y-%m-%dT23:59:59Z')
COST_BODY=$(cat <<EOF
{ "type":"ActualCost", "timeframe":"Custom",
  "timePeriod":{"from":"$FROM","to":"$TO"},
  "dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"Cost","function":"Sum"}}} }
EOF
)
COST_30D=$(az rest --method post \
  --url "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body "$COST_BODY" --headers "Content-Type=application/json" \
  | jq -r '.properties.rows[0][0] // 0')

# ---------- render master ----------
{
  md_title "FinOps Monthly Report — $MONTH"
  md_kv "Generated" "$(_ts)"
  md_kv "Subscription" "$SUB_NAME"
  md_kv "Resources" "$TOTAL_RES in $TOTAL_RGS resource groups"
  COST_30D_FMT=$(awk -v v="$COST_30D" 'BEGIN{printf "%.2f", v+0}')
  md_kv "Last 30d spend" "USD $COST_30D_FMT"
  if [ -n "${FINOPS_BUDGET_TOTAL:-}" ]; then
    PCT=$(awk -v s="$COST_30D" -v b="$FINOPS_BUDGET_TOTAL" 'BEGIN{printf "%.1f", (s+0)/(b+0)*100}')
    md_kv "Budget (total)" "USD $FINOPS_BUDGET_TOTAL ($PCT% consumed)"
  fi
  echo

  md_h2 "1. Drift since last baseline"
  sed -n '/^## Summary/,/^## /p' "$DRIFT_REPORT" | sed '$d'
  echo
  echo "Full: \`$(basename "$DRIFT_REPORT")\`"
  echo

  md_h2 "2. Waste hunter"
  sed -n '/^## Summary/,/^## /p' "$WASTE_REPORT" | sed '$d'
  echo
  echo "Full: \`$(basename "$WASTE_REPORT")\`"
  echo

  md_h2 "3. Tag compliance"
  sed -n '/^## Coverage per tag/,/^## /p' "$TAG_REPORT" | sed '$d'
  echo
  echo "Full: \`$(basename "$TAG_REPORT")\`"
  echo

  md_h2 "4. Cost allocation by tag — \`env\`"
  sed -n '/^## Breakdown/,/^## /p' "$COST_ENV_REPORT" | sed '$d'
  echo
  echo "Full: \`$(basename "$COST_ENV_REPORT")\`"
  echo

  md_h2 "5. Cost allocation by tag — \`app\`"
  sed -n '/^## Breakdown/,/^## /p' "$COST_APP_REPORT" | sed '$d'
  echo
  echo "Full: \`$(basename "$COST_APP_REPORT")\`"
  echo

  md_h2 "Executive recommendations"
  echo "1. Review drift: investigate any new resource group or untracked resource before it compounds cost."
  echo "2. Quick-win the waste list: orphaned disks and unattached public IPs are low-risk, immediate savings."
  echo "3. Backfill missing tags using the plan in the tag compliance report — this unlocks accurate cost allocation."
  echo "4. Validate the cost allocation per env/app with the business owners. Anything >20% under \`(untagged)\` is a blind spot."
  echo "5. Trend this file month-over-month: drift volume, waste count, tag coverage % and cost share per env are the 4 KPIs to watch."
} > "$REPORT"

log_info "monthly report: $REPORT"
echo "$REPORT"
