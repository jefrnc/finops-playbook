# FinOps Toolkit — Azure

A small collection of bash utilities that turn the Azure CLI + Cost Management
API + Resource Graph into weekly/monthly FinOps reports without any SaaS in
the middle.

> Azure-specific. For AWS / GCP equivalents see sibling folders under
> [`tools/`](../README.md) (contributions welcome).

All scripts are **read-only**: they query Azure and write CSV + Markdown to
`output/`. Nothing is mutated. Safe to run on any subscription you have reader
access to.

## What's included

| Script | What it does |
|---|---|
| `finops-drift-weekly.sh` | Compares current inventory vs. a local baseline — flags new/removed resources, unknown resource groups, and tag drift. |
| `finops-waste-hunter.sh` | Finds common waste: orphan managed disks, unattached NICs, unused public IPs, old snapshots, empty App Service Plans. |
| `finops-tag-compliance.sh` | Scores coverage for each mandatory tag, lists the top resource groups / types missing tags, and produces a backfill CSV. |
| `finops-cost-by-tag.sh` | Queries Cost Management grouped by a tag dimension (e.g. `env`, `app`) and renders a breakdown with ASCII bar charts. |
| `finops-cost-breakdown-by-meter.sh` | Decomposes a single resource's (or RG's) cost down to `MeterCategory/MeterSubCategory/Meter`. Reveals embedded licenses, cross-region bandwidth and other "hidden" charges that don't match the expected metric. |
| `finops-idle-scan.sh` | Cross-references the top N spenders against Azure Monitor CPU/memory metrics. Produces per-resource flags: `IDLE` / `LOW` / `OK` / `PEAK` / `SATURATED` / `UNKNOWN`. |
| `finops-monthly-report.sh` | Orchestrator: runs all of the above and consolidates a single executive monthly report with subscription-level KPIs. |

## Requirements

- `az` (Azure CLI) logged in — `az login`
- `jq`
- Bash 3.2+ (works on macOS default shell)
- Reader (or Cost Management Reader) on the target subscription

The scripts auto-install the `resource-graph` extension on first use.

## Usage

Create a profile under `config/` (copy `config/example.env`), set the
subscription, required tags, known RGs and budgets — then pass the profile
name via `FINOPS_PROFILE`:

```bash
cp config/example.env config/acme.env
vim config/acme.env

FINOPS_PROFILE=acme ./finops-drift-weekly.sh
FINOPS_PROFILE=acme ./finops-waste-hunter.sh
FINOPS_PROFILE=acme ./finops-tag-compliance.sh
FINOPS_PROFILE=acme ./finops-cost-by-tag.sh env 30
FINOPS_PROFILE=acme ./finops-monthly-report.sh
```

Or skip profiles entirely and use plain env vars:

```bash
AZ_SUBSCRIPTION=<id> FINOPS_REQUIRED_TAGS="env app owner" ./finops-tag-compliance.sh
```

## Output

All scripts write to `./output/` with a timestamped filename:

```
output/
  drift-weekly-20260419-143022.md
  drift-baseline.json                    # maintained by drift-weekly
  waste-report-20260419-143530.md
  waste-orphan-disks-20260419-143530.csv
  tag-compliance-20260419-144001.md
  cost-by-env-20260419-144130.md
  finops-monthly-2026-04.md              # consolidated report
```

The directory is gitignored except for a `.gitkeep`.

## Configuration reference

| Variable | Purpose | Default |
|---|---|---|
| `AZ_SUBSCRIPTION` | Target subscription ID | **required** |
| `FINOPS_REQUIRED_TAGS` | Space-separated list of mandatory tags | `env app cost_center owner criticality` |
| `FINOPS_KNOWN_RGS` | Space-separated list of expected resource groups | empty (all RGs treated as known) |
| `FINOPS_BUDGET_TOTAL` | Monthly budget USD — enables % consumed in monthly report | unset |
| `FINOPS_COST_DAYS` | Lookback window for cost queries | 30 |
| `FINOPS_SNAPSHOT_AGE_DAYS` | Age cutoff for "old" snapshot detection | 90 |
| `FINOPS_PROFILE` | Profile name — loads `config/<name>.env` | unset |

## Design notes

- **No mutations.** Every Azure call is a `get`/`list`/`query`. Any actions
  (deleting orphan disks, backfilling tags, etc.) are left to the operator
  reviewing the report — the tool suggests, the human decides.
- **Local state only.** The drift baseline lives in `output/drift-baseline.json`
  next to the reports. No database, no remote storage, no vendor lock-in.
- **Cost Management API is rate-limited.** The monthly report sleeps 5s
  between consecutive queries to avoid 429s on smaller tenants.
- **Locale.** Scripts force `LC_ALL=C` so `awk printf` uses `.` as decimal
  separator regardless of the operator's locale.

## Typical cadence

- **Weekly (Monday morning):** `finops-drift-weekly.sh` — catches new
  resources before they compound.
- **Monthly (1st of month):** `finops-monthly-report.sh` — executive summary
  for the FinOps review.
- **Ad-hoc:** `finops-waste-hunter.sh` before any cleanup campaign,
  `finops-cost-by-tag.sh` when someone asks "where is the money going?",
  `finops-idle-scan.sh` when "where do we cut?" needs a metrics-grounded answer,
  `finops-cost-breakdown-by-meter.sh` when a single resource shows a cost that
  doesn't match what it should cost (the "it says bandwidth but we barely moved
  data" moment).

## Investigation workflow

When the monthly report surfaces something surprising:

1. `finops-idle-scan.sh --top 30` → identify top spenders that are underused
   (IDLE/LOW) or over-stretched (SATURATED).
2. For anything in the output whose cost doesn't obviously match its role,
   run `finops-cost-breakdown-by-meter.sh --resource-id <id>` — the meter-level
   view frequently reveals an embedded SQL/Windows license, cross-region
   egress, or a backup tier you didn't know was on.
3. Only after those two steps, decide between rightsize / stop / delete /
   schedule. Never downsize production based on CPU average alone — pair it
   with the app owner's input.
