# FinOps pipeline — from visibility to automation

A practical, opinionated pipeline for running FinOps on Azure (and adaptable
to AWS / GCP) **without deploying anything in the customer subscription**.
Everything runs locally or as CI jobs; the cloud account stays untouched
except for the resources being optimized.

The pipeline follows the FinOps Foundation's three-capability model —
**Inform → Optimize → Operate** — and maps concrete open-source tools to
each stage. It assumes a single engineer/consultant can drive the whole
loop; no platform team required.

## The three capabilities

```
                      ┌────────────────────────────┐
                      │  INFORM                    │
                      │  visibility, allocation,   │
                      │  anomaly detection         │
                      └─────────────┬──────────────┘
                                    │ cost data
                                    ▼
                      ┌────────────────────────────┐
                      │  OPTIMIZE                  │
                      │  waste detection,          │
                      │  rightsizing, commitments  │
                      └─────────────┬──────────────┘
                                    │ validated actions
                                    ▼
                      ┌────────────────────────────┐
                      │  OPERATE                   │
                      │  policy-as-code,           │
                      │  enforcement, drift        │
                      └────────────────────────────┘
```

## Tool mapping

For each stage, this repo includes a **primary tool** (opinionated default)
and notes **alternatives** if the primary is not applicable.

### INFORM

Goal: know what is being spent, by whom, for what.

| Tool | Purpose | When |
|---|---|---|
| **[Microsoft FinOps Toolkit](https://github.com/microsoft/finops-toolkit)** (optional) | FinOps Hub + Power BI templates; exports Cost Management to a FOCUS-normalized dataset | When the client can host the hub infrastructure |
| **`tools/azure/finops-cost-dashboard.sh`** | Local, zero-infra HTML dashboard built from Cost Management API | When "deploy nothing in the sub" is a constraint (typical consulting engagement) |
| **`tools/azure/finops-cost-by-tag.sh`** | Tactical drill-down by tag dimension (env, app, cost_center) | Ad-hoc "where is the money going" conversations |
| **[Steampipe](https://steampipe.io/) + azure plugin** | SQL over Azure API for ad-hoc queries | Anything the shell scripts can't answer in one line |

Alternatives by cloud:
- **AWS:** Cost Explorer CSV export → `aws ce get-cost-and-usage` + custom dashboard
- **GCP:** BigQuery billing export + Looker Studio

### OPTIMIZE

Goal: translate spend into concrete, validated actions.

| Tool | Purpose | When |
|---|---|---|
| **`tools/azure/finops-waste-hunter.sh`** | Orphan disks, NICs, public IPs, old snapshots, empty App Service Plans | Every week, and before any cleanup campaign |
| **`tools/azure/finops-tag-compliance.sh`** | Score coverage per mandatory tag, emit a backfill CSV | Before exposing any cost breakdown that relies on tags |
| **Azure Advisor** (native) | Rightsizing + RI recommendations | Always — cross-reference with waste hunter output |
| **[Azure Optimization Engine](https://github.com/helderpinto/AzureOptimizationEngine)** | Scheduled collection + recommendations (part of MS FinOps Toolkit) | When the client wants a persistent recommendation store |
| **[Prowler](https://github.com/prowler-cloud/prowler)** | Security + compliance scan; catches many FinOps-adjacent issues (overprovisioned SKUs flagged by CIS) | Monthly, or after architecture changes |

### OPERATE

Goal: make the optimized state stick.

| Tool | Purpose | When |
|---|---|---|
| **Azure Policy + Initiatives** (native) | Enforce tagging, SKU limits, allowed regions at deploy time | Always — the floor of governance |
| **[Cloud Custodian](https://github.com/cloud-custodian/cloud-custodian)** | YAML-first rules engine for remediation (tag, stop, delete) | When you need actions beyond what native policy supports |
| **`tools/azure/finops-drift-weekly.sh`** | Weekly drift report — new RGs, removed resources, untagged additions | Every Monday morning |
| **`tools/azure/finops-monthly-report.sh`** | Orchestrator: consolidates drift + waste + tag compliance + cost-by-tag | First of the month |

Alternatives by cloud:
- **AWS:** AWS Config rules + Lambda remediation (or Cloud Custodian)
- **GCP:** Organization Policy Service + Cloud Custodian

## A minimal viable pipeline

If you only have one day to bootstrap this, do this in order:

### Day 1 — Inform (2 hours)

```bash
cp tools/azure/config/example.env tools/azure/config/myclient.env
vim tools/azure/config/myclient.env              # subscription ID, tags, RGs

FINOPS_PROFILE=myclient ./tools/azure/finops-cost-dashboard.sh
FINOPS_PROFILE=myclient ./tools/azure/finops-cost-by-tag.sh env 30
FINOPS_PROFILE=myclient ./tools/azure/finops-tag-compliance.sh
```

**Output:** an HTML dashboard the CFO can open, a tag coverage score,
a backfill CSV for the untagged resources.

### Week 1 — Optimize (4 hours)

```bash
FINOPS_PROFILE=myclient ./tools/azure/finops-waste-hunter.sh
./tools/azure/integrations/steampipe/run-all.sh ./findings/
prowler azure --az-cli-auth --output-formats html csv
```

**Output:** consolidated waste list (orphan disks, unattached IPs, empty
ASPs), 15 SQL-style findings, a CIS 3.0 Azure compliance scan.

### Month 1 — Operate (8 hours spread across the month)

1. Deploy the Azure Policy tagging initiative (`tools/azure/policies/`).
2. Review the Cloud Custodian policy pack in `tools/azure/integrations/custodian-policies/`
   with stakeholders — start all rules in `--dryrun`.
3. Add `finops-drift-weekly.sh` to a cron / GitHub Action running Monday at 8 AM.
4. First monthly report on day 30:
   ```bash
   FINOPS_PROFILE=myclient ./tools/azure/finops-monthly-report.sh
   ```

## What to measure

Four KPIs, checked weekly. Numbers that don't move tell you the pipeline
isn't running; numbers that move in the wrong direction tell you the
pipeline is running but nobody is acting on the output.

| KPI | How to compute |
|---|---|
| **Drift count** | `finops-drift-weekly.sh` — new resources this week |
| **Waste count** | `finops-waste-hunter.sh` — orphan disks + unattached IPs + empty ASPs |
| **Tag coverage** | `finops-tag-compliance.sh` — % of resources with every mandatory tag |
| **Untagged cost share** | `finops-cost-by-tag.sh env` — `%` under `(untagged)` |

Track month-over-month. The goal is not to hit zero, it's to keep the slope negative.

## Principles that keep the pipeline honest

- **Read-only by default.** Every detection tool queries the cloud and writes
  local reports. Humans decide what to act on.
- **No agents in the target subscription.** Nothing to uninstall when the
  engagement ends. The customer keeps the scripts and the data; the
  consultant keeps the know-how.
- **FOCUS-ready.** Cost data is queried from the native API, but the output
  schema mirrors [FOCUS](https://focus.finops.org/) so switching to a
  multi-cloud normalization later is a rename, not a rewrite.
- **Policy as code, not as clickops.** Every enforcement decision lives in
  a YAML (Custodian) or JSON (Azure Policy) file under version control.
  If it's not in git, it doesn't exist.
- **Document the why, not the what.** The scripts say what; the PR / ADR
  says why. A future engineer can read the commit and understand the
  tradeoff, not just the change.

## Further reading

- FinOps Foundation framework — <https://www.finops.org/framework/>
- FOCUS specification — <https://github.com/FinOps-Open-Cost-and-Usage-Spec/FOCUS_Spec>
- Microsoft FinOps Toolkit — <https://github.com/microsoft/finops-toolkit>
- Cloud Custodian docs — <https://cloudcustodian.io/docs/>
- Steampipe Azure plugin — <https://hub.steampipe.io/plugins/turbot/azure>
- Prowler — <https://github.com/prowler-cloud/prowler>
