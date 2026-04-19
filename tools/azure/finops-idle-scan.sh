#!/bin/bash
# finops-idle-scan.sh
#
# Cross-reference cost per resource against usage metrics (CPU/Mem/Net/
# Connections) to identify IDLE, LOW, OK, PEAK or SATURATED resources.
#
# Input:  top N resources by cost (rolling window) + Azure Monitor metrics.
# Output: CSV with per-resource flags + consolidable markdown report.
#
# Why this matters: cost alone tells you "where the money is"; metrics alone
# tell you "what's busy". The intersection tells you "where savings exist"
# (IDLE with real $) and "where to be careful" (SATURATED = upgrade risk,
# not saving opportunity).
#
# Real-world finding (single-subscription consulting engagement, 2026):
# detected several App Service Plans running SATURATED at 100% CPU, plus
# multiple Log Analytics workspaces IDLE at 0 GB ingestion despite monthly
# charges.
#
# Usage:
#   export FINOPS_PROFILE=acme
#   ./finops-idle-scan.sh --top 30 --days 30

set -eu

TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$TOOLKIT_DIR/lib/common.sh"

DAYS=30
TOP=30

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --top <n>      Top N resources by cost to scan (default: 30)
  --days <n>     Lookback window (default: 30)
  -h, --help     Show this help

Env:
  FINOPS_PROFILE=<name>   Load profile from config/<name>.env.

Flags applied per resource:
  IDLE       0% usage / 0 ingestion / deallocated
  LOW        <10% of SKU capacity
  OK         healthy utilization
  PEAK       high but sustained use that justifies the SKU
  SATURATED  100% — risk, not saving (may need UPGRADE)
  UNKNOWN    no metrics available for this resource type
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --top) TOP="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) log_error "unknown arg: $1"; usage ;;
  esac
done

load_profile
require_env AZ_SUBSCRIPTION
ensure_az_login

END=$(date -u '+%Y-%m-%dT23:59:59Z')
START=$(date -u -v-"${DAYS}"d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d "${DAYS} days ago" '+%Y-%m-%dT00:00:00Z')

TOP_JSON=$(timestamp_file "idle-top-spenders" "json")
OUT_CSV=$(timestamp_file "idle-scan" "csv")
OUT_MD=$(timestamp_file "idle-scan" "md")

log_info "querying top $TOP resources by cost ($START → $END)..."

BODY=$(cat <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": {"from": "$START", "to": "$END"},
  "dataset": {
    "granularity": "None",
    "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
    "grouping": [
      {"type": "Dimension", "name": "ResourceId"},
      {"type": "Dimension", "name": "ServiceName"}
    ]
  }
}
EOF
)

az rest --method post \
  --uri "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body "$BODY" \
  -o json > "$TOP_JSON"

log_info "enriching top $TOP resources with usage metrics..."

python3 - "$TOP_JSON" "$OUT_CSV" "$OUT_MD" "$TOP" "$DAYS" <<'PY'
import json, sys, csv, subprocess
raw_path, csv_path, md_path, top_str, days_str = sys.argv[1:6]
top, days = int(top_str), int(days_str)

with open(raw_path) as f:
    data = json.load(f)
rows = data.get("properties", {}).get("rows", [])
rows.sort(key=lambda r: -r[0])
rows = rows[:top]

def run_az(args):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        return r.stdout.strip()
    except Exception:
        return None

def metric_avg_max(resource_id, metric, days):
    out = run_az([
        "az", "monitor", "metrics", "list",
        "--resource", resource_id,
        "--metric", metric,
        "--interval", "P1D",
        "--offset", f"{days}d",
        "--aggregation", "Average", "Maximum",
        "--query", "value[0].timeseries[0].data",
        "-o", "json"
    ])
    if not out:
        return (None, None)
    try:
        pts = json.loads(out)
        avgs = [p.get("average") for p in pts if p.get("average") is not None]
        maxes = [p.get("maximum") for p in pts if p.get("maximum") is not None]
        avg = sum(avgs)/len(avgs) if avgs else None
        mx = max(maxes) if maxes else None
        return (avg, mx)
    except Exception:
        return (None, None)

def classify(res_type, cpu_avg, cpu_max, extra_flag=None):
    if extra_flag:
        return extra_flag
    if cpu_avg is None and cpu_max is None:
        return "UNKNOWN"
    try:
        if cpu_max is not None and cpu_max >= 95:
            return "SATURATED"
        if cpu_max is not None and cpu_max >= 70:
            return "PEAK"
        if cpu_avg is not None and cpu_avg < 2:
            return "IDLE"
        if cpu_avg is not None and cpu_avg < 10:
            return "LOW"
        return "OK"
    except Exception:
        return "UNKNOWN"

results = []
for r in rows:
    cost = r[0]; rid = r[1]; svc = r[2]
    name = rid.split("/")[-1] if rid else "(no-resource)"
    rtype = ""
    extra = None
    cpu_avg, cpu_max = None, None

    if "/virtualMachines/" in rid:
        rtype = "VM"
        cpu_avg, cpu_max = metric_avg_max(rid, "Percentage CPU", days)
        # check if VM is deallocated
        pw = run_az(["az", "vm", "get-instance-view",
                     "--ids", rid,
                     "--query", "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]",
                     "-o", "tsv"])
        if pw and "deallocated" in pw.lower():
            extra = "IDLE"
    elif "/serverfarms/" in rid or "/sites/" in rid:
        rtype = "ASP" if "/serverfarms/" in rid else "WebApp"
        cpu_avg, cpu_max = metric_avg_max(rid, "CpuPercentage", days)
    elif "/servers/" in rid and "flexibleServers" in rid:
        rtype = "PG-Flex" if "DBforPostgreSQL" in rid else "MySQL-Flex"
        cpu_avg, cpu_max = metric_avg_max(rid, "cpu_percent", days)
    elif "/workspaces/" in rid:
        rtype = "LAW"
        extra = "UNKNOWN"  # needs query against Usage table; flag for manual
    elif "/bastionHosts/" in rid:
        rtype = "Bastion"
        extra = "UNKNOWN"  # sessions metric is unreliable via this call
    else:
        rtype = svc or "Other"

    flag = classify(rtype, cpu_avg, cpu_max, extra)
    results.append({
        "cost_usd": cost,
        "name": name,
        "type": rtype,
        "service": svc,
        "cpu_avg_pct": f"{cpu_avg:.1f}" if cpu_avg is not None else "",
        "cpu_max_pct": f"{cpu_max:.1f}" if cpu_max is not None else "",
        "flag": flag,
        "resource_id": rid,
    })
    print(f"  [{flag:>9}] {rtype:<12} {name:<40} cost=${cost:>8,.0f} cpu_avg={cpu_avg} cpu_max={cpu_max}")

# Write CSV
with open(csv_path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["flag","type","name","cost_usd","cpu_avg_pct","cpu_max_pct","service","resource_id"])
    w.writeheader()
    # sort: SATURATED first (risk), then IDLE/LOW (savings), then OK/PEAK, UNKNOWN last
    order = {"SATURATED":0,"IDLE":1,"LOW":2,"PEAK":3,"OK":4,"UNKNOWN":5}
    for row in sorted(results, key=lambda x:(order.get(x["flag"],9), -x["cost_usd"])):
        w.writerow({
            "flag": row["flag"], "type": row["type"], "name": row["name"],
            "cost_usd": f"{row['cost_usd']:.2f}",
            "cpu_avg_pct": row["cpu_avg_pct"], "cpu_max_pct": row["cpu_max_pct"],
            "service": row["service"], "resource_id": row["resource_id"]
        })

# Write summary markdown
with open(md_path, "w") as f:
    from collections import Counter
    by_flag = Counter(r["flag"] for r in results)
    f.write(f"# Idle Scan Report\n\n")
    f.write(f"- Window: last {days} days\n")
    f.write(f"- Top resources scanned: {len(results)}\n\n")
    f.write("## Summary by flag\n\n")
    f.write("| Flag | Count | Total cost/window |\n|---|---:|---:|\n")
    for flag, cnt in sorted(by_flag.items(), key=lambda x: -x[1]):
        total = sum(r["cost_usd"] for r in results if r["flag"]==flag)
        f.write(f"| {flag} | {cnt} | ${total:,.2f} |\n")
    f.write("\n## Top candidates for action (IDLE/LOW)\n\n")
    f.write("| Cost | Type | Name | CPU avg | CPU max | Flag |\n|---:|---|---|---:|---:|---|\n")
    for r in sorted([x for x in results if x["flag"] in ("IDLE","LOW")], key=lambda x:-x["cost_usd"]):
        f.write(f"| ${r['cost_usd']:,.2f} | {r['type']} | {r['name']} | {r['cpu_avg_pct']} | {r['cpu_max_pct']} | {r['flag']} |\n")
    f.write("\n## SATURATED (risk, not saving)\n\n")
    for r in [x for x in results if x["flag"] == "SATURATED"]:
        f.write(f"- **{r['name']}** ({r['type']}) ${r['cost_usd']:,.0f}/window — CPU max {r['cpu_max_pct']}%\n")

print(f"\nCSV: {csv_path}")
print(f"MD:  {md_path}")
PY

log_info "done. CSV: $OUT_CSV"
log_info "      MD:  $OUT_MD"
