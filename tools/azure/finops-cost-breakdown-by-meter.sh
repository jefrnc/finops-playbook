#!/bin/bash
# finops-cost-breakdown-by-meter.sh
#
# Decomposes Azure Cost Management data for a single resource (or resource
# group) down to the MeterCategory / MeterSubCategory / Meter level.
#
# Use case: when a resource shows an unexpectedly high cost that doesn't
# match its expected metric (e.g. "$4,750 of bandwidth" on a VM that only
# pushed 388 GB of egress), this script reveals what meter is actually
# charging — embedded licenses, cross-region bandwidth, hidden services.
#
# Real-world finding (single-subscription consulting engagement, 2026):
# unmasked $62,000/year of SQL Server Enterprise PAYG license that was
# being grouped under the generic "Bandwidth" category in other views.
#
# Usage:
#   export FINOPS_PROFILE=acme
#   ./finops-cost-breakdown-by-meter.sh --resource-id /subscriptions/.../virtualMachines/vm-example
#   ./finops-cost-breakdown-by-meter.sh --resource-group rg-example
#   ./finops-cost-breakdown-by-meter.sh --days 30 --resource-id <id>

set -eu

TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$TOOLKIT_DIR/lib/common.sh"

DAYS=30
RESOURCE_ID=""
RESOURCE_GROUP=""
TOP=50

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --resource-id <id>      Azure resource ID to break down (full path)
  --resource-group <rg>   Alternative: all resources in an RG (aggregated per resource)
  --days <n>              Lookback window in days (default: 30)
  --top <n>               Max rows to display (default: 50)
  -h, --help              Show this help

Env:
  FINOPS_PROFILE=<name>   Load config/<name>.env for subscription/tenant defaults.

Example:
  FINOPS_PROFILE=acme $0 \\
    --resource-id /subscriptions/xxx/resourceGroups/rg-example/providers/Microsoft.Compute/virtualMachines/vm-sql-01 \\
    --days 30
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --resource-id) RESOURCE_ID="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --top) TOP="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) log_error "unknown arg: $1"; usage ;;
  esac
done

load_profile
require_env AZ_SUBSCRIPTION
ensure_az_login

if [ -z "$RESOURCE_ID" ] && [ -z "$RESOURCE_GROUP" ]; then
  log_error "must provide --resource-id OR --resource-group"
  usage
fi

END=$(date -u '+%Y-%m-%dT23:59:59Z')
START=$(date -u -v-"${DAYS}"d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d "${DAYS} days ago" '+%Y-%m-%dT00:00:00Z')

OUT=$(timestamp_file "cost-by-meter" "csv")
OUT_RAW=$(timestamp_file "cost-by-meter-raw" "json")

log_info "window: $START → $END (${DAYS} days)"
log_info "subscription: $AZ_SUBSCRIPTION"

# Build query body
if [ -n "$RESOURCE_ID" ]; then
  log_info "scope: resource-id (single resource)"
  FILTER_JSON=$(cat <<EOF
{"dimensions": {"name": "ResourceId", "operator": "In", "values": ["$RESOURCE_ID"]}}
EOF
)
  GROUPING='[
    {"type": "Dimension", "name": "MeterCategory"},
    {"type": "Dimension", "name": "MeterSubCategory"},
    {"type": "Dimension", "name": "Meter"}
  ]'
else
  log_info "scope: resource-group $RESOURCE_GROUP"
  FILTER_JSON=$(cat <<EOF
{"dimensions": {"name": "ResourceGroup", "operator": "In", "values": ["$RESOURCE_GROUP"]}}
EOF
)
  GROUPING='[
    {"type": "Dimension", "name": "ResourceId"},
    {"type": "Dimension", "name": "MeterCategory"},
    {"type": "Dimension", "name": "MeterSubCategory"},
    {"type": "Dimension", "name": "Meter"}
  ]'
fi

BODY=$(cat <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": {"from": "$START", "to": "$END"},
  "dataset": {
    "granularity": "None",
    "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
    "grouping": $GROUPING,
    "filter": $FILTER_JSON
  }
}
EOF
)

log_info "querying Cost Management API..."
az rest --method post \
  --uri "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body "$BODY" \
  -o json > "$OUT_RAW" 2>&1 || {
    log_error "Cost Management query failed; see $OUT_RAW"
    exit 4
  }

# Parse rows into CSV
python3 - "$OUT_RAW" "$OUT" "$RESOURCE_ID" "$TOP" <<'PY'
import json, sys, csv
raw_path, out_path, single_res, top_str = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
top = int(top_str)

with open(raw_path) as f:
    data = json.load(f)

rows = data.get("properties", {}).get("rows", [])
cols = [c["name"] for c in data.get("properties", {}).get("columns", [])]

# Sort by Cost desc (first col is Cost)
rows.sort(key=lambda r: -r[0])
rows = rows[:top]

with open(out_path, "w", newline="") as f:
    w = csv.writer(f)
    if single_res:
        w.writerow(["cost_usd", "meter_category", "meter_subcategory", "meter", "currency"])
        for r in rows:
            cost = r[0]; mc = r[1]; msc = r[2]; meter = r[3]; cur = r[-1]
            w.writerow([f"{cost:.4f}", mc, msc, meter, cur])
    else:
        w.writerow(["cost_usd", "resource_id", "meter_category", "meter_subcategory", "meter", "currency"])
        for r in rows:
            cost = r[0]; rid = r[1]; mc = r[2]; msc = r[3]; meter = r[4]; cur = r[-1]
            w.writerow([f"{cost:.4f}", rid.split("/")[-1], mc, msc, meter, cur])

print(f"wrote {len(rows)} rows -> {out_path}")

# Console summary
print()
print(f"{'COST':>12} | CATEGORY / SUBCATEGORY / METER")
print("-" * 90)
for r in rows[:20]:
    if single_res:
        cost, mc, msc, meter = r[0], r[1], r[2], r[3]
        print(f"{cost:>12,.2f} | {mc} / {msc} / {meter}")
    else:
        cost, rid, mc, msc, meter = r[0], r[1], r[2], r[3], r[4]
        print(f"{cost:>12,.2f} | {rid.split('/')[-1]:<30} | {mc} / {msc} / {meter}")

total = sum(r[0] for r in rows)
print("-" * 90)
print(f"{total:>12,.2f} | TOTAL shown")
PY

log_info "CSV: $OUT"
log_info "Raw JSON: $OUT_RAW"
