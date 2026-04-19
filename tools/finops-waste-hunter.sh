#!/bin/bash
# finops-waste-hunter.sh
#
# Detects common FinOps waste patterns in an Azure subscription:
#   - orphaned managed disks (not attached)
#   - unattached network interfaces
#   - public IPs not associated with any resource
#   - managed disk snapshots older than N days (default 90)
#   - app service plans with zero sites
#   - deallocated VMs older than N days (informational)
#
# Output: CSV per category + consolidated markdown summary.
#
# Usage:
#   FINOPS_PROFILE=ecipsa ./finops-waste-hunter.sh
#   FINOPS_SNAPSHOT_AGE_DAYS=60 ./finops-waste-hunter.sh

set -e
TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TOOLKIT_DIR
SCRIPT_DIR="$TOOLKIT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_profile
require_env AZ_SUBSCRIPTION
ensure_az_login

AGE_DAYS="${FINOPS_SNAPSHOT_AGE_DAYS:-90}"
CUTOFF_ISO=$(date -u -v-"${AGE_DAYS}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "-${AGE_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')

OUT_DIR="$(output_dir)"
REPORT="$(timestamp_file waste-report md)"
DISKS_CSV="$(timestamp_file waste-orphan-disks csv)"
NICS_CSV="$(timestamp_file waste-orphan-nics csv)"
PIPS_CSV="$(timestamp_file waste-orphan-pips csv)"
SNAPS_CSV="$(timestamp_file waste-old-snapshots csv)"
ASP_CSV="$(timestamp_file waste-empty-asps csv)"

# Uses Azure Resource Graph to run cross-RG queries (az disk/nic/pip list
# require --resource-group in some tenants). Requires the resource-graph
# extension (installed automatically on first use).

# ---------- orphaned disks ----------
log_info "scanning orphaned managed disks..."
{
  echo "name,resource_group,sizeGB,sku,created_utc"
  az graph query -q "Resources | where type =~ 'microsoft.compute/disks' | where isnull(managedBy) or managedBy == '' | project name, resourceGroup, sizeGB=tostring(properties.diskSizeGB), sku=tostring(sku.name), created=tostring(properties.timeCreated)" --first 1000 -o json \
    | jq -r '.data[] | [.name, .resourceGroup, .sizeGB, .sku, .created] | @csv'
} > "$DISKS_CSV"
DISKS_COUNT=$(( $(wc -l < "$DISKS_CSV") - 1 ))

# ---------- orphaned NICs ----------
log_info "scanning unattached NICs..."
{
  echo "name,resource_group,location"
  az graph query -q "Resources | where type =~ 'microsoft.network/networkinterfaces' | where isnull(properties.virtualMachine) | project name, resourceGroup, location" --first 1000 -o json \
    | jq -r '.data[] | [.name, .resourceGroup, .location] | @csv'
} > "$NICS_CSV"
NICS_COUNT=$(( $(wc -l < "$NICS_CSV") - 1 ))

# ---------- orphaned public IPs ----------
log_info "scanning unattached public IPs..."
{
  echo "name,resource_group,sku,allocation,ip"
  az graph query -q "Resources | where type =~ 'microsoft.network/publicipaddresses' | where isnull(properties.ipConfiguration) | project name, resourceGroup, sku=tostring(sku.name), allocation=tostring(properties.publicIPAllocationMethod), ip=tostring(properties.ipAddress)" --first 1000 -o json \
    | jq -r '.data[] | [.name, .resourceGroup, .sku, .allocation, (.ip // "")] | @csv'
} > "$PIPS_CSV"
PIPS_COUNT=$(( $(wc -l < "$PIPS_CSV") - 1 ))

# ---------- old snapshots ----------
log_info "scanning disk snapshots older than $AGE_DAYS days..."
{
  echo "name,resource_group,sizeGB,created_utc"
  az graph query -q "Resources | where type =~ 'microsoft.compute/snapshots' | where properties.timeCreated < datetime('$CUTOFF_ISO') | project name, resourceGroup, sizeGB=tostring(properties.diskSizeGB), created=tostring(properties.timeCreated)" --first 1000 -o json \
    | jq -r '.data[] | [.name, .resourceGroup, .sizeGB, .created] | @csv'
} > "$SNAPS_CSV"
SNAPS_COUNT=$(( $(wc -l < "$SNAPS_CSV") - 1 ))

# ---------- empty ASPs ----------
log_info "scanning app service plans with zero sites..."
{
  echo "name,resource_group,sku,tier,capacity"
  az appservice plan list --query "[].{name:name, rg:resourceGroup, sku:sku.name, tier:sku.tier, capacity:sku.capacity, sites:numberOfSites}" -o json \
    | jq -r '.[] | select(.sites == 0 or .sites == null) | [.name, .rg, .sku, .tier, .capacity] | @csv'
} > "$ASP_CSV"
ASP_COUNT=$(( $(wc -l < "$ASP_CSV") - 1 ))

# ---------- render ----------
{
  md_title "Azure FinOps Waste Hunter"
  md_kv "Generated" "$(_ts)"
  md_kv "Subscription" "$(az account show --query name -o tsv)"
  md_kv "Snapshot age cutoff" "$AGE_DAYS days (before $CUTOFF_ISO)"
  echo

  md_h2 "Summary"
  md_table_header "Category|Count|CSV"
  echo "| Orphaned managed disks | $DISKS_COUNT | $(basename "$DISKS_CSV") |"
  echo "| Unattached NICs | $NICS_COUNT | $(basename "$NICS_CSV") |"
  echo "| Unattached public IPs | $PIPS_COUNT | $(basename "$PIPS_CSV") |"
  echo "| Old disk snapshots | $SNAPS_COUNT | $(basename "$SNAPS_CSV") |"
  echo "| App Service Plans with 0 sites | $ASP_COUNT | $(basename "$ASP_CSV") |"
  echo

  md_h2 "Quick wins — orphaned managed disks"
  if [ "$DISKS_COUNT" -gt 0 ]; then
    md_table_header "Disk|RG|Size (GB)|SKU"
    tail -n +2 "$DISKS_CSV" | awk -F'\t|,' '{printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}' | head -20
  else
    echo "None detected."
  fi
  echo

  md_h2 "Quick wins — unattached public IPs"
  if [ "$PIPS_COUNT" -gt 0 ]; then
    md_table_header "Name|RG|SKU|Allocation|IP"
    tail -n +2 "$PIPS_CSV" | awk -F'\t|,' '{printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5}' | head -20
  else
    echo "None detected."
  fi
  echo

  md_h2 "Empty App Service Plans"
  if [ "$ASP_COUNT" -gt 0 ]; then
    md_table_header "Plan|RG|SKU|Tier|Capacity"
    tail -n +2 "$ASP_CSV" | awk -F',' '{gsub(/"/,""); printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5}' | head -20
  else
    echo "None detected."
  fi
  echo

  md_h2 "Next steps"
  echo "1. Validate each item — an \"orphan\" may be a scheduled swap (e.g. blue/green)."
  echo "2. For confirmed waste, delete with \`az disk delete\` / \`az network public-ip delete\` / etc. — ALWAYS after snapshotting the state."
  echo "3. Review ASPs: either consolidate or downsize unused plans."
} > "$REPORT"

log_info "report: $REPORT"
echo "$REPORT"
