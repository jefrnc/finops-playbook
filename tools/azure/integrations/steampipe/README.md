# Steampipe FinOps query pack — Azure

15 SQL queries that surface the highest-ROI FinOps findings on an Azure
subscription. Runs 100% locally; no agent installed on the subscription.

## Requirements

```bash
brew install turbot/tap/steampipe      # or curl install script on Linux
steampipe plugin install azure
az login
```

## Usage

Interactive:

```bash
steampipe query
# then paste any SELECT from finops-queries.sql
```

One-shot to CSV:

```bash
steampipe query --output csv "$(cat finops-queries.sql | sed -n '/-- Q01/,/-- Q02/p' | head -n -1)" > Q01-orphan-disks.csv
```

Or use the included helper:

```bash
./run-all.sh /path/to/output-dir
```

## What's in the pack

| Query | Answers |
|---|---|
| Q01 | Which managed disks are orphan? |
| Q02 | Which public IPs are unattached (billed for nothing)? |
| Q03 | Which VMs lack the mandatory `env` tag? |
| Q04 | Which VMs have been deallocated for 30+ days? |
| Q05 | Which App Service Plans have zero sites? |
| Q06 | Which Premium SSDs are attached to non-prod resources? |
| Q07 | Which storage accounts use GRS/RAGRS (2x LRS cost)? |
| Q08 | Which resource groups have multiple Log Analytics workspaces? |
| Q09 | Recovery Services Vault inventory |
| Q10 | Disk snapshots older than 90 days |
| Q11 | VPN Gateway inventory with SKU |
| Q12 | NAT + App Gateway inventory |
| Q13 | Resource count per RG + untagged count |
| Q14 | SQL databases by service tier |
| Q15 | Tag coverage score across subscription |

## Design notes

- Each query is self-contained and delimited by a `-- Qxx:` marker so they
  can be extracted with `sed -n '/-- Q05/,/-- Q06/p'`.
- Column names come from the Steampipe Azure plugin, **not** from the raw
  Azure API response — check `information_schema.columns` if you need a
  field that isn't listed here.
- The `azure_resource` table aggregates all resource types but has limited
  fields; use specific tables (`azure_compute_virtual_machine`, etc.) for
  detailed attributes.
