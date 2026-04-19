#!/bin/bash
# finops-cost-dashboard.sh
#
# Pulls Azure Cost Management data and renders a self-contained HTML dashboard
# with daily/monthly trends, top-N by tag, and a naive next-month forecast.
#
# Zero infrastructure: does NOT deploy anything in Azure. Output is a single
# HTML file the operator can open locally or email to stakeholders.
#
# Usage:
#   FINOPS_PROFILE=acme ./finops-cost-dashboard.sh
#   FINOPS_PROFILE=acme FINOPS_COST_DAYS=180 ./finops-cost-dashboard.sh
#   AZ_SUBSCRIPTION=<id> ./finops-cost-dashboard.sh

set -e
export LC_ALL=C LC_NUMERIC=C
TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TOOLKIT_DIR
SCRIPT_DIR="$TOOLKIT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_profile
require_env AZ_SUBSCRIPTION
ensure_az_login

DAYS="${FINOPS_COST_DAYS:-180}"
TO_DATE=$(date -u '+%Y-%m-%dT23:59:59Z')
FROM_DATE=$(date -u -v-"${DAYS}"d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d "-${DAYS} days" '+%Y-%m-%dT00:00:00Z')

HTML="$(timestamp_file cost-dashboard html)"
DAILY_JSON="$(timestamp_file cost-daily-raw json)"
ENV_JSON="$(timestamp_file cost-env-raw json)"
APP_JSON="$(timestamp_file cost-app-raw json)"

log_info "querying daily cost series for $DAYS days..."

DAILY_BODY=$(cat <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": { "from": "$FROM_DATE", "to": "$TO_DATE" },
  "dataset": {
    "granularity": "Daily",
    "aggregation": { "totalCost": { "name": "Cost", "function": "Sum" } }
  }
}
EOF
)

az rest --method post \
  --url "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body "$DAILY_BODY" --headers "Content-Type=application/json" > "$DAILY_JSON"

sleep 3

log_info "querying cost by tag 'env'..."
ENV_BODY=$(cat <<EOF
{
  "type": "ActualCost", "timeframe": "Custom",
  "timePeriod": { "from": "$FROM_DATE", "to": "$TO_DATE" },
  "dataset": {
    "granularity": "None",
    "aggregation": { "totalCost": { "name": "Cost", "function": "Sum" } },
    "grouping": [ { "type": "TagKey", "name": "env" } ]
  }
}
EOF
)
az rest --method post \
  --url "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body "$ENV_BODY" --headers "Content-Type=application/json" > "$ENV_JSON"

sleep 3

log_info "querying cost by tag 'app'..."
APP_BODY=$(cat <<EOF
{
  "type": "ActualCost", "timeframe": "Custom",
  "timePeriod": { "from": "$FROM_DATE", "to": "$TO_DATE" },
  "dataset": {
    "granularity": "None",
    "aggregation": { "totalCost": { "name": "Cost", "function": "Sum" } },
    "grouping": [ { "type": "TagKey", "name": "app" } ]
  }
}
EOF
)
az rest --method post \
  --url "https://management.azure.com/subscriptions/$AZ_SUBSCRIPTION/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body "$APP_BODY" --headers "Content-Type=application/json" > "$APP_JSON"

# ---------- transform ----------
DAILY_JS=$(jq '[ .properties.rows // [] | .[] | { date: (.[1]|tostring | .[0:4] + "-" + .[4:6] + "-" + .[6:8]), cost: (.[0]|tonumber) } ] | sort_by(.date)' "$DAILY_JSON")

ENV_JS=$(jq '[ .properties.rows // [] | .[] | { label: ((.[2] // "(untagged)") | gsub("^\""; "") | gsub("\"$"; "") | (if . == "" or . == null then "(untagged)" else . end)), value: (.[0]|tonumber) } ] | sort_by(-.value)' "$ENV_JSON")

APP_JS=$(jq '[ .properties.rows // [] | .[] | { label: ((.[2] // "(untagged)") | gsub("^\""; "") | gsub("\"$"; "") | (if . == "" or . == null then "(untagged)" else . end)), value: (.[0]|tonumber) } ] | sort_by(-.value)' "$APP_JSON")

TOTAL=$(echo "$DAILY_JS" | jq '[.[].cost] | add // 0' )
AVG_DAILY=$(awk -v t="$TOTAL" -v d="$DAYS" 'BEGIN{printf "%.2f", t/d}')
FORECAST_30D=$(awk -v a="$AVG_DAILY" 'BEGIN{printf "%.2f", a*30}')
LATEST_30D=$(echo "$DAILY_JS" | jq '[.[-30:][].cost] | add // 0')
PREV_30D=$(echo "$DAILY_JS" | jq '[.[-60:-30][].cost] | add // 0')
DELTA_PCT=$(awk -v a="$LATEST_30D" -v b="$PREV_30D" 'BEGIN{if(b>0) printf "%.1f", (a-b)/b*100; else print "n/a"}')

SUB_NAME=$(az account show --query name -o tsv)

# ---------- render HTML ----------
log_info "rendering HTML dashboard..."

cat > "$HTML" <<HTML_HEAD
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>FinOps Cost Dashboard — $SUB_NAME</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 1200px; margin: 2rem auto; padding: 0 1rem; color: #222; }
  header { border-bottom: 2px solid #0078d4; padding-bottom: 1rem; margin-bottom: 2rem; }
  h1 { margin: 0; color: #0078d4; }
  .meta { color: #666; font-size: 0.9rem; margin-top: 0.5rem; }
  .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 2rem; }
  .kpi { background: #f3f2f1; padding: 1rem; border-radius: 6px; border-left: 4px solid #0078d4; }
  .kpi .label { font-size: 0.85rem; color: #605e5c; text-transform: uppercase; letter-spacing: 0.5px; }
  .kpi .value { font-size: 1.8rem; font-weight: 600; color: #323130; }
  .kpi .sub { font-size: 0.8rem; color: #605e5c; margin-top: 0.25rem; }
  .kpi.delta-up { border-left-color: #d13438; }
  .kpi.delta-down { border-left-color: #107c10; }
  section { margin-bottom: 3rem; }
  h2 { color: #323130; border-bottom: 1px solid #e1dfdd; padding-bottom: 0.5rem; }
  canvas { max-height: 400px; }
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 2rem; }
  @media (max-width: 800px) { .grid-2 { grid-template-columns: 1fr; } }
  footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #e1dfdd; color: #605e5c; font-size: 0.85rem; }
  table { width: 100%; border-collapse: collapse; margin-top: 1rem; }
  th, td { text-align: left; padding: 0.5rem; border-bottom: 1px solid #e1dfdd; }
  th { background: #f3f2f1; font-weight: 600; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
</style>
</head><body>

<header>
  <h1>FinOps Cost Dashboard</h1>
  <div class="meta">
    Subscription: <strong>$SUB_NAME</strong> &middot;
    Window: $FROM_DATE → $TO_DATE ($DAYS days) &middot;
    Generated: $(_ts)
  </div>
</header>

<section class="kpis">
  <div class="kpi">
    <div class="label">Total spend</div>
    <div class="value">USD $(awk -v v="$TOTAL" 'BEGIN{printf "%.0f", v}')</div>
    <div class="sub">last $DAYS days</div>
  </div>
  <div class="kpi">
    <div class="label">Daily average</div>
    <div class="value">USD $AVG_DAILY</div>
    <div class="sub">&nbsp;</div>
  </div>
  <div class="kpi">
    <div class="label">Forecast next 30d</div>
    <div class="value">USD $FORECAST_30D</div>
    <div class="sub">linear projection</div>
  </div>
  <div class="kpi $(awk -v d="$DELTA_PCT" 'BEGIN{if(d+0>0) print "delta-up"; else if(d+0<0) print "delta-down"}')">
    <div class="label">30d vs previous 30d</div>
    <div class="value">$DELTA_PCT%</div>
    <div class="sub">USD $(awk -v v="$LATEST_30D" 'BEGIN{printf "%.0f", v}') vs $(awk -v v="$PREV_30D" 'BEGIN{printf "%.0f", v}')</div>
  </div>
</section>

<section>
  <h2>Daily cost trend</h2>
  <canvas id="dailyChart"></canvas>
</section>

<section class="grid-2">
  <div>
    <h2>Cost by env</h2>
    <canvas id="envChart"></canvas>
  </div>
  <div>
    <h2>Cost by app</h2>
    <canvas id="appChart"></canvas>
  </div>
</section>

<section>
  <h2>Breakdown — env</h2>
  <table id="envTable"><thead><tr><th>env</th><th class="num">USD</th><th class="num">share</th></tr></thead><tbody></tbody></table>
</section>

<section>
  <h2>Breakdown — app</h2>
  <table id="appTable"><thead><tr><th>app</th><th class="num">USD</th><th class="num">share</th></tr></thead><tbody></tbody></table>
</section>

<footer>
  Generated by <code>finops-cost-dashboard.sh</code> from the <a href="https://github.com/jefrnc/finops-playbook">FinOps Playbook</a>.
  Source data pulled via Azure Cost Management API; no agent, no deployed infrastructure.
</footer>

<script>
const daily = $DAILY_JS;
const envData = $ENV_JS;
const appData = $APP_JS;
const total = $TOTAL;

new Chart(document.getElementById('dailyChart'), {
  type: 'line',
  data: {
    labels: daily.map(d => d.date),
    datasets: [{
      label: 'Daily cost (USD)',
      data: daily.map(d => d.cost),
      borderColor: '#0078d4', backgroundColor: 'rgba(0,120,212,0.1)',
      fill: true, tension: 0.2, pointRadius: 0
    }]
  },
  options: { responsive: true, plugins: { legend: { display: false } },
             scales: { y: { beginAtZero: true } } }
});

const palette = ['#0078d4','#107c10','#d13438','#ca5010','#5c2d91','#038387','#c239b3','#498205'];

new Chart(document.getElementById('envChart'), {
  type: 'doughnut',
  data: {
    labels: envData.map(d => d.label),
    datasets: [{ data: envData.map(d => d.value), backgroundColor: palette }]
  },
  options: { responsive: true, plugins: { legend: { position: 'right' } } }
});

new Chart(document.getElementById('appChart'), {
  type: 'doughnut',
  data: {
    labels: appData.map(d => d.label),
    datasets: [{ data: appData.map(d => d.value), backgroundColor: palette }]
  },
  options: { responsive: true, plugins: { legend: { position: 'right' } } }
});

function fillTable(id, data) {
  const tb = document.querySelector(id + ' tbody');
  data.forEach(d => {
    const tr = document.createElement('tr');
    const pct = (d.value / total * 100).toFixed(1);
    tr.innerHTML = '<td>' + d.label + '</td>' +
                   '<td class="num">' + d.value.toFixed(2) + '</td>' +
                   '<td class="num">' + pct + '%</td>';
    tb.appendChild(tr);
  });
}
fillTable('#envTable', envData);
fillTable('#appTable', appData);
</script>

</body></html>
HTML_HEAD

log_info "dashboard: $HTML"
echo "$HTML"
