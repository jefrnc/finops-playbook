# Case study — Azure FinOps on a single-subscription client

> Generic writeup distilled from a 4-month consulting engagement on a
> mid-sized Azure tenant (~500 resources, ~USD 15K/month baseline spend,
> single subscription, no AKS, mixed workloads: CRM, WordPress, RPA, a
> Portal and integration services). Names, numbers and clients are
> abstracted. The point is the **process** and the **lessons learned**.

## Context

- **Engagement:** 160 hours over 4 months, remote consulting via a
  boutique consultancy.
- **Scope:** single Azure subscription, ~23 VMs, ~30 resource groups, ~500
  resources total.
- **Starting point:** 82% of resources untagged; zero budgets configured;
  zero cost governance policies; one legacy "ASC Default" Defender
  assignment.
- **Client profile:** small IT team (no dedicated FinOps role), external
  hosting provider (Nexsys), Microsoft Partner relationship for
  licensing / Reserved Instances.
- **Outcome target:** 30% cost reduction.

## The four months in shape

| Month | Focus | Outcome |
|---|---|---|
| 1 | Inform — visibility + budgets + tagging strategy | Cost Management configured, budgets set, tagging proposal accepted |
| 2 | Optimize — non-prod rightsizing, auto-shutdown, security baseline | ~$600/mo non-prod savings, auto-shutdown automation on dev/QA |
| 3 | Optimize + validate — production rightsizing, storage lifecycle, ASP consolidation | ~$800/mo prod savings after careful rollbacks on two attempts |
| 4 | Operate — governance initiative, quick wins, handoff | Azure Policy tagging initiative deployed, custodian policies left as pack, pipeline documented |

Net realized savings at handoff: **~USD 27K/year** (conservative,
excluding Reserved Instance purchases outside our scope).

## What worked

### 1. Tagging as the foundation, not the finale

A cost report without tagging is just an opinion. We built the tagging
strategy in week 2, published a CSV for the client to complete, and
treated every subsequent recommendation as "blocked until tags are in."
This forced the conversation about ownership and cost centers early
instead of at the end.

The mandatory tag set ended up being: `env`, `app`, `cost_center`,
`owner`, `criticality`. Every optimization recommendation cited which
tag justified the action.

### 2. Snapshots before every change

We wrote a small "resource snapshot" utility that captured the current
state of any resource (VM, disk, storage account, ASP) as JSON plus a
shell script that could re-apply it. Every change in the changelog
references a snapshot ID. This turned two near-incidents into 10-minute
rollbacks instead of escalations.

Key insight: **the cost of maintaining the snapshot tooling is trivial
compared to the psychological safety it gives the consultant and the
client.** If rollback is one command away, conversations about "can we
try X" stop being about blast radius.

### 3. Validation against live telemetry before every rightsizing

An initial rightsizing recommendation ("Rightsizing de VMs" from the
assessment) turned out to be partially wrong when we checked actual
metrics at execution time:
- One VM flagged as "10% CPU avg — downsize" actually peaked RAM to zero
  during scheduled RPA runs. Target SKU had to stay the same memory
  tier, only CPU was reduced.
- Another VM's "3 data disks unused" recommendation hid the fact that
  the disks had 100% IOPS throttle — the bottleneck was disk IOPS, not
  compute. Downsizing would have crashed the workload.

Takeaway: **validate every recommendation against live metrics
immediately before execution.** Assessment-phase data goes stale in
weeks, not months.

### 4. Separating what we execute vs. what we recommend

The engagement mixed three categories of optimizations:
- **Autonomous** — we could execute without explicit sign-off (tagging,
  orphan cleanup, snapshot deletion). Snapshot + rollback available.
- **Sign-off required** — non-prod rightsizing, auto-shutdown schedules.
  Client approved batches.
- **Out of scope** — Reserved Instances (Microsoft Partner's job),
  Defender plan changes (security team).

We kept these rigidly separated in the reports. Blurring them erodes
trust: if the client sees "we did the RI analysis" they assume we did
the RI purchase.

### 5. Read-only toolkit the client keeps

We delivered a set of bash scripts (drift, waste hunter, tag compliance,
cost-by-tag, monthly report) that the client can run from their own
workstation with `az login`. Zero deployed infrastructure in the
subscription, zero recurring cost, zero vendor lock-in.

When the engagement ends, the client has a set of files and a README.
Not a dashboard they can't log into, not a SaaS trial that expires.

## What did not work

### Production freeze until a specific date

The contract froze production changes until month 4. In practice, this
meant we could not validate some optimization hypotheses on prod data
(only on non-prod which had different load patterns). By the time prod
was unfrozen, consulting hours were running out, so we had to
**recommend without executing** for several high-value optimizations.

Retrospectively: production freezes should allow for **observability
work** (telemetry, sampling, synthetic metrics) even when mutations are
locked. Otherwise the first 3 months of non-mutation work produces
recommendations that haven't been calibrated against the real workload.

### ASP rightsizing cascade failure

One App Service Plan downgrade (P3v3 → P2v3) looked safe based on CPU
metrics but failed due to memory pressure — the app was using RAM that
was not visible in the Azure-reported metric. We rolled back within 20
minutes (snapshot worked as intended), but the announced $245/mo
savings never materialized.

Lesson: **for memory-sensitive SKUs, use a memory-optimized variant of
the same tier (e.g. P2mv3) instead of dropping tiers.** And always
instrument the application before the change, not just Azure Monitor.

### Waiting for client input

Early in the engagement we waited for the client to validate each
recommendation before executing. This created 2-week feedback loops
that wasted calendar time. Month 3 onwards we switched to **"execute
autonomously with snapshot + rollback, notify after"** for low-risk
changes (non-prod tagging, orphan cleanup, snapshot deletion). This
compressed the feedback loop and let the client focus their attention
on the 20% of changes that actually needed their input.

## Deliverables at handoff

This is roughly what a "bastante" final deliverable looks like for this
kind of engagement — not exhaustive, but concrete:

1. **Executive report** — savings realized, savings pending, open risks
2. **Consolidated findings** — 1 document per month with the hypotheses
   evaluated, with explicit "overrides" when live data invalidated
   earlier recommendations
3. **FinOps toolkit** — 5-6 bash scripts the client runs weekly
4. **Cost dashboard (HTML, self-contained)** — single file openable in
   any browser, renders Chart.js locally
5. **Security baseline** — Prowler CIS scan HTML + CSV
6. **Steampipe query pack** — 15 SQL queries for ad-hoc investigations
7. **Cloud Custodian policy pack** — 8 YAML rules for the next
   engineering team to enable progressively
8. **Governance** — Azure Policy initiative deployed (tagging +
   inherit), budgets configured
9. **Runbooks** — step-by-step execution guides for any remaining
   high-impact change the client will run without the consultant
10. **Public-facing writeup** — this document + the tooling in a public
    repo, sanitized

The public repo half is important: it compounds the consultant's value
across engagements. Client-specific context stays private; generic
patterns (tagging strategy, rightsizing methodology, snapshot/rollback
pattern) land in the public playbook.

## A note on open-source tooling selection

We evaluated roughly a dozen open-source FinOps / CSPM tools and
narrowed to four:

- **Microsoft FinOps Toolkit** — native integration, FOCUS exports,
  Power BI templates. Good fit when the client can host the Hub infra.
- **Prowler** — security-focused but catches many FinOps-adjacent
  issues (overprovisioned SKUs flagged by CIS 3.0 Azure). Ran it as
  a one-shot deliverable.
- **Cloud Custodian** — YAML rules engine. We left policies as a pack
  for the client to enable progressively (not deployed during the
  engagement — zero mutations was a constraint).
- **Steampipe** — SQL over Azure API. Solved the "I need to answer this
  ad-hoc question fast" problem that shell scripts were bad at.

Discarded:
- **OptScale / Kubecost / OpenCost** — no K8s, overkill for single sub.
- **ScoutSuite** — Prowler has a better release cadence.
- **OptScale as platform** — too heavy for the operating model.

Rule of thumb: the fewer tools you deploy, the more likely the handoff
sticks. Every agent you install is a future uninstall conversation.

## What this case study is not

- Not a product pitch — these tools are all open source.
- Not a claim that 30% savings is reproducible in your environment.
- Not a substitute for your own assessment — every tenant has its own
  historical decisions that resist generic recommendations.

The pattern that reproduces is the **process**, not the numbers.
