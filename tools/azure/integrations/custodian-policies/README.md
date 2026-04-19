# Cloud Custodian policy pack — Azure FinOps starter

Eight policies covering the highest-ROI waste patterns on Azure. All policies
start in **report-only mode** (tag + notify). Turn the destructive action on
only after a review cycle.

## Contents

| # | Policy | What it does |
|---|---|---|
| 01 | `stop-untagged-nonprod-vms.yml` | Reports (then optionally stops) VMs without the `env` tag |
| 02 | `delete-orphan-disks.yml` | Tags orphan disks, deletes after 14-day cooldown |
| 03 | `delete-orphan-public-ips.yml` | Deletes public IPs without `ipConfiguration` |
| 04 | `delete-old-snapshots.yml` | Deletes disk snapshots older than 90 days |
| 05 | `enforce-required-tags.yml` | Reports RGs missing any mandatory tag |
| 06 | `shutdown-nonprod-night.yml` | Stops dev/qa/test VMs left running overnight |
| 07 | `delete-empty-asps.yml` | Deletes App Service Plans with zero sites |
| 08 | `report-premium-disks-nonprod.yml` | Flags Premium SSDs on non-prod VMs for review |

## Requirements

- Custodian 0.9+ installed: `pipx install c7n-azure`
- Azure CLI logged in (`az login`) **or** service principal env vars

## Usage

### Dry run (safe — no mutations)

```bash
AZURE_SUBSCRIPTION_ID=<your-sub-id> \
  custodian run -s ./out/ ./01-stop-untagged-nonprod-vms.yml --dryrun
```

Output lands in `./out/<policy-name>/resources.json` with every matched resource.

### Real run

Drop `--dryrun`. Custodian writes a run log and the list of resources
affected to `./out/`.

### Scheduling

For unattended execution, wrap policies in a Logic App / Azure Function /
cron job. Custodian also supports Azure Functions deployment out of the box:

```bash
custodian run --mode azure-periodic policies.yml
```

## Tuning guide

- **01** — adjust `location op: not-in` to include your production regions.
- **02** — the 14-day cooldown is a safety net; do not shorten below 7 days.
- **06** — `shutdown-nonprod-night` assumes the job runs at your target
  off-hour (e.g. 8 PM). Schedule accordingly.
- **08** — `Premium_LRS` filter can be extended to `UltraSSD_LRS` for
  stricter non-prod policy.

## Recommended rollout

1. **Week 1:** run all 8 policies with `--dryrun`. Review the matched
   resources. Tune exclusions.
2. **Week 2:** enable the *reporting* actions (`tag`, `notify`) — no
   mutations yet. Let the organization see what would be touched.
3. **Week 3:** enable the *soft* actions (`stop`) on 06 and 01.
4. **Week 4+:** enable the *destructive* actions (`delete`) on 02, 03, 04,
   07 after explicit owner sign-off.
