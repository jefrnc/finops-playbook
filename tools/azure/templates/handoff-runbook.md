# Post-Engagement Handoff Runbook — Template

> **This is a template.** Fork it into your engagement repo, replace the
> `{{PLACEHOLDERS}}`, and leave it with the operator who inherits the
> subscription. The goal: they can operate the FinOps layer you set up
> **on their own** the day after you leave.
>
> The structure below was distilled from a real 4-month Azure consulting
> engagement. The sections aren't arbitrary — each one closed a specific
> gap we discovered in handoffs.

**Audience:** IT team inheriting the FinOps layer (and/or the consultant
who continues).
**Written by:** {{CONSULTANT_NAME}} · **Date:** {{HANDOFF_DATE}}
**Scope:** everything deployed or configured during the engagement and how
to operate, roll back, and monitor it from day one.

---

## Index

- [0. Start here (Day 1)](#0-start-here-day-1)
- [1. Active changes inventory](#1-active-changes-inventory)
- [2. Rollback procedures (per change)](#2-rollback-procedures-per-change)
- [3. Monitoring checklist](#3-monitoring-checklist)
- [4. Monthly FinOps cadence](#4-monthly-finops-cadence)
- [5. Anomaly escalation tree](#5-anomaly-escalation-tree)
- [6. Cookbook — "If you see X, do Y"](#6-cookbook--if-you-see-x-do-y)
- [7. Success KPIs](#7-success-kpis)
- [8. Gotchas learned during the engagement](#8-gotchas-learned-during-the-engagement)
- [9. Contacts and references](#9-contacts-and-references)

---

## 0. Start here (Day 1)

If you're new to operating this, do these **7 steps in order** before
touching anything.

### 0.1 Local environment (~20 min)

```bash
brew install azure-cli jq bash        # macOS
sudo apt install azure-cli jq         # Ubuntu

az login --tenant {{TENANT_ID}}
az account set --subscription {{SUBSCRIPTION_ID}}
az account show --query "{sub:name, id:id, tenant:tenantId}" -o table

git clone {{REPO_URL}} && cd {{REPO_NAME}}
export FINOPS_PROFILE={{PROFILE_NAME}}
```

### 0.2 Validate RBAC (~5 min)

```bash
az role assignment list --assignee <your-email> \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

You need **Reader** on the subscription (minimum), **Contributor** on the
RGs you'll be touching, and **Tag Contributor** if you'll be modifying
tags.

### 0.3 Required reading (~45 min, in order)

1. This runbook (read it once end-to-end).
2. `{{BASELINE_KIT_README}}` — deliverables map.
3. `{{LESSONS_LEARNED}}` — what worked, what didn't.
4. `{{CHANGELOG}}` — full history of applied changes.
5. `{{LAST_AUDIT_REPORT}}` — most recent cost × usage analysis.

### 0.4 Run the toolkit in read-only mode (~15 min)

```bash
cd scripts/toolkit
FINOPS_PROFILE={{PROFILE_NAME}} ./finops-drift-weekly.sh
FINOPS_PROFILE={{PROFILE_NAME}} ./finops-waste-hunter.sh
FINOPS_PROFILE={{PROFILE_NAME}} ./finops-tag-compliance.sh
FINOPS_PROFILE={{PROFILE_NAME}} ./finops-idle-scan.sh --top 20
ls -lht output/ | head -10
```

If any of these fail → permissions or subscription problem. Fix before
moving on.

### 0.5 Verify you're in the alert group (~2 min)

```bash
az monitor action-group show -g {{ACTION_GROUP_RG}} \
  -n {{ACTION_GROUP_NAME}} \
  --query "emailReceivers[].emailAddress" -o tsv
```

Add yourself if missing.

### 0.6 Know your first Monday

1. Run `finops-drift-weekly.sh` → the output compares against the baseline
   left by the previous operator (`output/drift-baseline.json`).
2. The first drift will likely be large (covers a full week of activity).
   Ignore the volume; focus on whether any unfamiliar resources appeared.
3. Commit the regenerated baseline.

### 0.7 Month 1 — suggested plan

| Week | Activity | Time |
|---|---|---|
| 1 | Onboarding + required reading + first weekly cycle | 4-6 h |
| 2 | Full monthly run + review meeting with sponsor | 3-4 h |
| 3 | Pick up deferred optimizations from the pipeline | 6-10 h |
| 4 | Consolidate month's savings, adjust budgets if needed | 2-3 h |

---

## 1. Active changes inventory

Everything deployed in subscription `{{SUBSCRIPTION_ID}}` that is producing
effect today.

| # | Change | Scope | Reversible | Monthly savings | Status |
|---|---|---|---|---:|---|
| 1 | {{BUDGET_ALERTS}} | Subscription + N RGs | Yes | N/A (alerting) | Active |
| 2 | {{POLICY_INITIATIVE}} (Audit + Inherit) | Sub-scope | Yes | N/A (governance) | Active — **Audit mode** (not Deny) |
| 3 | {{TAGGING_PASS}} | Cross-RG | Partial (snapshots available) | N/A (governance) | Active |
| 4 | {{AUTO_SHUTDOWN}} | N non-prod VMs | Yes | ${{AMOUNT}}/mo | Active |
| 5 | {{RIGHTSIZING_1}} | ... | Yes | ${{AMOUNT}}/mo | Active |
| ... | | | | | |

**Changes NOT executed but documented for whoever continues:**

| Opportunity | Estimated savings | Blocker | Doc |
|---|---:|---|---|
| {{OPPORTUNITY_1}} | ${{AMOUNT}}/mo | {{BLOCKER}} | `{{DOC_PATH}}` |

**Total pipeline pending: ~${{TOTAL_PIPELINE}}/mo** if all are executed.

---

## 2. Rollback procedures (per change)

For each active change: **what it does**, **when to revert**, **exact
command ready to copy-paste**.

### 2.1 Budgets + Action Group

**What it does:** alerts at 80/100/110% of the monthly budget to the
recipients of the action group.

**Actual objects deployed:**
- Action group: `{{ACTION_GROUP_NAME}}` in RG `{{ACTION_GROUP_RG}}`
- Current recipients: {{RECIPIENTS}}
- Budgets: {{LIST_OF_BUDGETS_WITH_AMOUNTS}}

**Check current state:**
```bash
az consumption budget list \
  --query "[].{name:name, amount:amount, spend:currentSpend.amount, pct:(currentSpend.amount/amount)*\`100\`}" -o table
```

**Add/remove an email from the action group:**
```bash
az monitor action-group update -g {{ACTION_GROUP_RG}} -n {{ACTION_GROUP_NAME}} \
  --remove-action <alias>
az monitor action-group update -g {{ACTION_GROUP_RG}} -n {{ACTION_GROUP_NAME}} \
  --add-action email new@company.com
```

**Full rollback (delete everything):**
```bash
for b in {{LIST_OF_BUDGET_NAMES}}; do
  az consumption budget delete --budget-name "$b"
done
az monitor action-group delete -g {{ACTION_GROUP_RG}} -n {{ACTION_GROUP_NAME}}
```

### 2.2 Policy Initiative

**What it does:** `Audit` mode (doesn't block, only reports) over resources
missing required tags. An `inherit` policy copies tags from RG to new
resources via a managed identity with Tag Contributor role.

**Do NOT change to `enforcementMode=DoNotEnforce`** without a reason — it
disables everything. Do **NOT** change effect to `deny` without first
testing on a subset — it blocks legitimate deploys.

**Check compliance:**
```bash
az policy state summarize --policy-assignment {{POLICY_ASSIGNMENT_NAME}}
```

**Full rollback:** `bash {{POLICY_ROLLBACK_SCRIPT}}`

### 2.3 Bulk tagging pass

**What it did:** applied `env` and `app` tags to N resources with clear
naming patterns (`*-prod-*`, `*-qa-*`, etc.). Coverage went from X% to Y%.

**Snapshots before change:** `{{SNAPSHOT_DIR}}/<resource>.json` (one per
resource, full state — not just tags).

**Rollback a single resource:**
```bash
RID=<resource-id>
NAME=$(basename "$RID")
OLD_TAGS=$(jq -r '.tags | to_entries | map("\(.key)=\(.value)") | join(" ")' \
  {{SNAPSHOT_DIR}}/${NAME}.json)
az tag update --resource-id "$RID" --operation Replace --tags $OLD_TAGS
```

### 2.4 Auto-shutdown on non-prod VMs

```bash
# Disable on a single VM
az vm auto-shutdown -g <rg> -n <vm-name> --off

# Change the hour (e.g. to 22:00)
az vm auto-shutdown -g <rg> -n <vm-name> --time 2200

# Add to a new VM
az vm auto-shutdown -g <rg> -n <vm-name> --time 2000 \
  --email "owner@company.com"
```

### 2.5+ Remaining changes

(Follow the same pattern — one block per change.)

---

## 3. Monitoring checklist

### 3.1 Daily (5 min)

- [ ] Check inbox for budget alerts.
- [ ] 80% alert → confirm it's a legitimate driver (new deploy, seasonal
      spike). If not → §5.
- [ ] 100% / 110% alert → immediate escalation (§5.2).

### 3.2 Weekly — Monday AM (~20 min)

```bash
cd scripts/toolkit
FINOPS_PROFILE={{PROFILE_NAME}} ./finops-drift-weekly.sh
FINOPS_PROFILE={{PROFILE_NAME}} ./finops-waste-hunter.sh
FINOPS_PROFILE={{PROFILE_NAME}} ./finops-tag-compliance.sh
```

**Review outputs in `./output/`:**

| Output | What to check | Red flag |
|---|---|---|
| `drift-<date>.md` | New/removed resources, unknown RGs | RG without context → investigate owner |
| `waste-hunter-<date>.md` | Orphan disks/NICs/IPs, old snapshots | orphan > 0 → evaluate delete |
| `tag-compliance-<date>.md` | Coverage of required tags | Drop > 5pp week-on-week → inherit policy not applying |

**Minimum weekly action:** commit the regenerated baseline.

### 3.3 Monthly — 1st business day (~60 min)

See §4.

### 3.4 Quarterly

- [ ] Review Reserved Instances — any new candidates? Any expiring soon?
- [ ] Review Software Assurance renewal dates if you use AHB.
- [ ] Compliance report — target >70% for required tags.
- [ ] Archive snapshots older than 1 year. **Don't delete** — move to cold
      storage.

---

## 4. Monthly FinOps cadence

### 4.1 Step 1 — orchestrate

```bash
cd scripts/toolkit
FINOPS_PROFILE={{PROFILE_NAME}} ./finops-monthly-report.sh
# output/monthly-<YYYY-MM>.md
```

### 4.2 Step 2 — complementary manual analysis

1. **Cost by tag env** — target non-prod < 30% of total.
2. **Idle scan** — flag new SATURATED (risk) and new IDLE with high $ (saving).
3. **Cost-by-meter** when something doesn't match — it regularly reveals
   embedded licenses or cross-region egress hiding under generic labels.

### 4.3 Step 3 — distribution

| Report | Recipient | Channel | When |
|---|---|---|---|
| Monthly executive summary | Sponsor | Email / Teams | D+2 |
| Raw drift/waste outputs | IT team | Repo / shared folder | Day of close |
| Budget alerts | Action group | Automatic | On-event |
| Policy compliance | IT team | Portal review | Monthly |

### 4.4 Step 4 — monthly meeting (30 min)

Fixed agenda:
1. Cost vs budget (5 min).
2. Top 3 findings from idle scan (10 min).
3. Status of pipeline pending optimizations (10 min).
4. Next proposed changes + approvals (5 min).

---

## 5. Anomaly escalation tree

### 5.1 Daily cost > 20% above 7-day average

1. (2 min) `finops-drift-weekly.sh` → any new resources?
2. (5 min) Portal → Cost Management → Daily view → Group by `ResourceId` →
   top 3 spenders on the anomalous day.
3. (10 min) For each top spender:
   ```bash
   FINOPS_PROFILE={{PROFILE_NAME}} \
     ./scripts/toolkit/finops-cost-breakdown-by-meter.sh \
     --resource-id <id> --days 7
   ```
4. (3 min) Decide:
   - Compute up → someone scaled without a ticket?
   - Storage up → new buckets / egress / mis-scheduled snapshots?
   - "Bandwidth" up unexpectedly → **possibly an embedded license**
     (see gotcha 8.1).

### 5.2 Budget alert at 100% / 110%

Immediate (today):
1. Validate it's not a month of legitimate extraordinary spend.
2. If it's a surprise:
   - Apply §5.1.
   - Communicate to sponsor within 24 h with preliminary diagnosis.
   - Optional aggressive: deploy a temporary deny-create policy.

### 5.3 Resource in `SATURATED` state (CPU >95% sustained)

**Not a saving — an operational risk.**

- Prod → coordinate upgrade with workload owner before impact.
- Non-prod → validate SKU fit or find the mis-scheduled batch job.

### 5.4 `IDLE` resource with high cost

Threshold of attention: IDLE + cost > ${{IDLE_THRESHOLD}}/mo.

- Validate with owner (could be DR, nightly schedule, etc.).
- If confirmed unused: evaluate delete / stop / downgrade / schedule.

### 5.5 Tag compliance drops <50%

- Check if the initiative's managed identity lost the Tag Contributor role.
- Check if any new RG is outside the initiative scope.
- 0% for >30 days → initiative is broken, rollback + redeploy.

---

## 6. Cookbook — "If you see X, do Y"

| Symptom | Likely cause | Immediate action |
|---|---|---|
| Budget 80% alert before day 20 of month | New resource, ascending auto-scale, or delayed billing | `finops-drift-weekly.sh` + `cost-by-tag env` |
| Drift shows an unknown RG | Someone deployed without announcing | Email IT asking for owner; if none → tag `owner=unknown-<date>` |
| `tag-compliance` drops 10pp in one week | Someone created 20+ resources without `env` | Check last 7 days of ActivityLog → talk to the deployer |
| VM at CPU >95% sustained for 3h | Runaway process or badly scheduled batch | Alert app owner; evaluate temporary upgrade |
| VM runs SQL but not registered as SqlVirtualMachine | Common in custom-image lifts | Check if AHB is an option; register and apply |
| "Bandwidth" of a resource 10x up without traffic change | Possibly an embedded license (SQL, Windows) mis-classified | `finops-cost-breakdown-by-meter.sh --resource-id <id>` |
| VPN connection `NotConnected` after an overnight resize | IKE re-negotiation failed (typical post-resize) | Check peer logs; `az network vpn-connection reset` if urgent |
| Policy compliance 0% a month after deploy | Managed identity lost Tag Contributor | Re-assign; `az policy state trigger-scan` |
| `finops-drift-weekly.sh` errors "baseline missing" | Someone deleted `output/drift-baseline.json` | Recreate from `git log` or previous monthly snapshot |
| Cost by tag env shows `null` >50% | Inherit policy not applying | See §5.5 |

---

## 7. Success KPIs

Measure quarterly. Baseline at handoff: {{HANDOFF_DATE}}.

| KPI | Baseline | Target Q+1 | Target EOY |
|---|---:|---:|---:|
| Monthly total cost (avg) | ${{BASELINE}} | ${{TARGET_Q1}} | ${{TARGET_EOY}} |
| Compliance `env` tag | X% | 95% | 98% |
| Compliance `app` tag | X% | 60% | 85% |
| Orphan disks count | 0 | 0 | 0 |
| Non-prod VMs without auto-shutdown | 0 | 0 | 0 |
| Resources in `SATURATED` state | N | 0 | 0 |
| `IDLE` resources > $100/mo | N | ≤2 | 0 |
| Cumulative executed savings | ${{BASELINE_SAVINGS}}/mo | +${{Q1_TARGET}}/mo | +${{EOY_TARGET}}/mo |

---

## 8. Gotchas learned during the engagement

Things that surprised us during the 4 months and are worth knowing up
front.

### 8.1 "Bandwidth" may not actually be bandwidth

Seen in a real engagement: a SQL VM had thousands of dollars/month tagged
as "Bandwidth" in some Cost Management views. Drilling down by
`MeterCategory/MeterSubCategory/Meter` revealed the charge was really **SQL
Server Enterprise PAYG license embedded via custom image metadata**.

**Lesson:** for any unexplained high cost that doesn't match the resource's
expected metric, run `finops-cost-breakdown-by-meter.sh` before anything
else. Grouped categories in the default views can hide embedded licenses
and surprise egress.

### 8.2 Client-declared exceptions are non-negotiable

Some apparent "cost anomalies" are intentional configurations by the
client (e.g. a non-prod resource backed up to a prod vault for a specific
business reason). Document these exceptions in the engagement and **never
propose to "fix" them** without talking to the sponsor.

### 8.3 Reservations usually live outside the FinOps operator's scope

RIs are typically procured by a licensing partner or a centralized account
team. When you identify RI candidates, the output is a recommendation
email to that team, not a `az reservations` command.

### 8.4 Rightsizing prod based on CPU average alone will bite you

A real P3v3 → P2v3 App Service downsize was executed based on low CPU
average. It caused perf degradation and was rolled back in under 4 hours.

**Lesson:** for prod rightsizing, always pair `idle-scan` (30+ day window)
with the app owner's input. Never downsize on metrics alone.

### 8.5 A tagging initiative with `effect=audit` won't raise compliance

You also need to activate the **inherit** policy (copies tags from the RG
to its resources) AND give the managed identity the **Tag Contributor**
role. Without both, the initiative only reports — it doesn't fix.

### 8.6 Azure CLI + Cost Management API — filter syntax gotcha

The POST body filter doesn't accept `"or"` as a wrapper around a single
dimension. Passing `{"or": [{"dimensions": {...}}]}` with one element
returns HTTP 400. Use `{"dimensions": {...}}` directly.

### 8.7 Backup protected items stuck in "Deleting"

Common pattern: items whose container has `healthStatus=Deleted` but the
item itself stays in `Protected`. Requires
`az backup protection disable --delete-backup-data Yes` for real cleanup.
Regular `delete` won't remove it.

### 8.8 App Service Free tier (F1) breaks custom domains with SSL

If you downgrade an App Service Plan to F1 to save money, custom domain
bindings with SSL certificates stop working. Always validate the site's
bindings before downgrading.

---

## 9. Contacts and references

### 9.1 Stakeholders

| Role | Name | Email | Responsibility |
|---|---|---|---|
| Sponsor | {{SPONSOR_NAME}} | {{SPONSOR_EMAIL}} | GO/NO-GO on changes > ${{THRESHOLD}}/mo |
| IT team | — | {{IT_EMAIL}} | Day-to-day execution |
| Licensing / RI | {{LICENSING_PARTNER}} | {{LICENSING_EMAIL}} | Reserved Instances, SA, AHB |
| Outgoing consultant | {{CONSULTANT_NAME}} | {{CONSULTANT_EMAIL}} | Reachable for ~90 days post-handoff |

### 9.2 Deliverables map

| What | Where |
|---|---|
| Technical reports from the engagement | `reports/` |
| Baseline kit | `entregables/baseline-kit-<date>/` |
| FinOps operational scripts | `scripts/toolkit/` |
| Historical changelog | `changes.md` |
| Pre-change snapshots | `snapshots/` |
| Lessons learned | `entregables/baseline-kit-<date>/docs/lessons-learned.md` |
| Original project plan | `docs/plan-proyecto-finops.md` |

### 9.3 External references

- Subscription: `{{SUBSCRIPTION_ID}}`
- Tenant: `{{TENANT_ID}}`
- Azure Cost Management: Portal → Cost Management + Billing
- Azure Policy compliance: Portal → Policy → Compliance

---

## Appendix A — Survival commands (top 15)

```bash
# 1. Spend last 7 days
az consumption usage list \
  --start-date "$(date -u -v-7d '+%Y-%m-%d')" \
  --end-date "$(date -u '+%Y-%m-%d')" \
  --query "sum([].pretaxCost)" -o tsv

# 2. Resources without env tag
az resource list --query "[?tags.env==null].{name:name, type:type, rg:resourceGroup}" -o table

# 3. Top 20 resources by cost, last 30 days
FINOPS_PROFILE={{PROFILE_NAME}} ./scripts/toolkit/finops-cost-by-tag.sh ResourceId | head -25

# 4. Weekly drift
FINOPS_PROFILE={{PROFILE_NAME}} ./scripts/toolkit/finops-drift-weekly.sh

# 5. Waste hunter
FINOPS_PROFILE={{PROFILE_NAME}} ./scripts/toolkit/finops-waste-hunter.sh

# 6. Idle / saturated scan
FINOPS_PROFILE={{PROFILE_NAME}} ./scripts/toolkit/finops-idle-scan.sh --top 30

# 7. Cost of 1 resource by meter
FINOPS_PROFILE={{PROFILE_NAME}} ./scripts/toolkit/finops-cost-breakdown-by-meter.sh --resource-id <id>

# 8. Policy initiative compliance
az policy state summarize --policy-assignment {{POLICY_ASSIGNMENT_NAME}}

# 9. Budget status
az consumption budget list \
  --query "[].{name:name, amount:amount, spend:currentSpend.amount, pct:(currentSpend.amount/amount)*\`100\`}" -o table

# 10. Historical changelog
grep -E "^### " changes.md | head -20

# 11. Action group recipients
az monitor action-group show -g {{ACTION_GROUP_RG}} -n {{ACTION_GROUP_NAME}} \
  --query "emailReceivers[].{name:name, email:emailAddress}" -o table

# 12. List auto-shutdown schedules
az resource list --resource-type "Microsoft.DevTestLab/schedules" \
  --query "[].{name:name, rg:resourceGroup}" -o table

# 13. See tags of a resource
az tag list --resource-id <id>

# 14. Last deploy per RG (activity log)
az monitor activity-log list --resource-group <rg> \
  --offset 7d --max-events 20 \
  --query "[?operationName.value=='Microsoft.Resources/deployments/write'].{when:eventTimestamp, who:caller}" -o table

# 15. Force policy re-evaluation after scope changes
az policy state trigger-scan --resource-group <rg>
```

---

## Appendix B — What NOT to do

- ❌ Don't delete `output/drift-baseline.json` — it's the reference state
  for the weekly drift.
- ❌ Don't switch the tagging initiative to `Deny` without testing first —
  it blocks legitimate deploys from RGs that aren't compliant yet.
- ❌ Don't delete `snapshots/` — it's the safety net for every change.
  Archive after a year, don't delete.
- ❌ Don't run Custodian policies with `delete` action without going
  through `--dryrun` → `tag` → 14-day observation first.
- ❌ Don't assume a high "bandwidth" charge is actually bandwidth — it can
  be an embedded license (gotcha 8.1).
- ❌ Don't rightsize prod based on CPU average alone (gotcha 8.4).
- ❌ Don't run changes in production on Friday afternoon or the day before
  a holiday without on-call coverage on the peer side (applies especially
  to VPN, DNS, firewalls).
- ❌ Don't create new budgets without adding them to the action group —
  alerts won't reach anyone.
- ❌ Don't disable auto-shutdown "for one day" without re-enabling it
  after — people forget.

---

## Appendix C — Quick glossary

- **AHB** (Azure Hybrid Benefit): letting you use on-prem Windows/SQL
  licenses (with SA) on Azure VMs to reduce cost.
- **ASP** (App Service Plan): the "server" that hosts Web Apps. You pay
  for the plan, not the sites.
- **AZ** (Availability Zones): suffix in SKUs like `VpnGw1AZ`. Zone-aware
  redundancy. Costs more, tolerates zone outages.
- **Cost Management API**: the Azure API that exposes billing data. Used
  by `finops-cost-*.sh` via `az rest`.
- **Drift**: unplanned changes in the subscription vs. the last baseline.
- **IDLE / LOW / OK / PEAK / SATURATED**: flags from `finops-idle-scan.sh`.
  IDLE = unused resource with real $. SATURATED = sustained 100% CPU (risk,
  not saving).
- **MeterCategory/SubCategory/Meter**: levels of billing granularity. The
  meter-level view typically reveals embedded licenses when a cost
  "doesn't match" what it should be.
- **Orphan (disk/NIC/IP)**: a managed resource that survived its parent
  VM deletion and keeps costing money.
- **PAYG** (Pay As You Go): hourly/daily billing with no commitment.
- **Policy initiative**: a group of policies assigned together.
- **RI** (Reserved Instance): 1-3 year commitment for a 30-70% discount.
- **SA** (Software Assurance): Microsoft licensing benefit that unlocks
  AHB, mobility, etc.
- **SKU**: tier/size of a resource (e.g. `Standard_D4s_v3`, `VpnGw2AZ`,
  `B1`).
- **Tag inherit**: policy that copies tags from the RG to resources
  inside.

---

**End of runbook template.**

If something isn't here, look in `changes.md` (history) → `reports/`
(detailed analyses) → `entregables/<kit>/README.md` (deliverables map).
