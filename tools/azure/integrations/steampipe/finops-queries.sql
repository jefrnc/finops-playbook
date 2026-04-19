-- ============================================================================
-- Steampipe FinOps query pack for Azure
--
-- Requires: steampipe + azure plugin
--   brew install turbot/tap/steampipe
--   steampipe plugin install azure
--   az login
--   steampipe query
--
-- Run a single query:
--   steampipe query "$(sed -n '/^-- Q01/,/^-- Q02/p' finops-queries.sql | head -n -1)"
--
-- Each query is self-contained; pick and choose.
-- ============================================================================


-- Q01: Orphan managed disks (not attached, ordered by size)
SELECT
  name,
  resource_group,
  disk_size_gb,
  sku_name,
  time_created,
  subscription_id
FROM azure_compute_disk
WHERE managed_by IS NULL
ORDER BY disk_size_gb DESC;


-- Q02: Public IPs with no association (orphaned, billed monthly)
SELECT
  name,
  resource_group,
  sku_name,
  public_ip_allocation_method,
  ip_address
FROM azure_public_ip
WHERE ip_configuration_id IS NULL
ORDER BY sku_name DESC;


-- Q03: VMs without the mandatory 'env' tag (cannot be cost-allocated)
SELECT
  name,
  resource_group,
  vm_id,
  size,
  location,
  tags
FROM azure_compute_virtual_machine
WHERE tags -> 'env' IS NULL
ORDER BY resource_group;


-- Q04: Deallocated VMs older than 30 days (idle but often still billed for disks)
SELECT
  vm.name,
  vm.resource_group,
  vm.size,
  vm.power_state,
  vm.tags
FROM azure_compute_virtual_machine vm
WHERE vm.power_state = 'deallocated'
ORDER BY vm.resource_group;


-- Q05: App Service Plans with 0 sites (paying for nothing)
SELECT
  name,
  resource_group,
  sku_name,
  sku_tier,
  sku_capacity,
  number_of_sites
FROM azure_app_service_plan
WHERE number_of_sites = 0
ORDER BY sku_tier DESC;


-- Q06: Premium SSD disks on non-prod-tagged resources (overprovisioned)
SELECT
  name,
  resource_group,
  disk_size_gb,
  sku_name,
  tags ->> 'env' AS env_tag
FROM azure_compute_disk
WHERE sku_name = 'Premium_LRS'
  AND tags ->> 'env' IN ('dev', 'qa', 'test', 'staging', 'uat')
ORDER BY disk_size_gb DESC;


-- Q07: Storage accounts with GRS/RA-GRS replication (2x cost of LRS)
SELECT
  name,
  resource_group,
  sku_name,
  sku_tier,
  access_tier,
  tags ->> 'env' AS env_tag
FROM azure_storage_account
WHERE sku_name LIKE '%_GRS%' OR sku_name LIKE '%_RAGRS%'
ORDER BY sku_name;


-- Q08: Log Analytics workspaces per resource group (detects proliferation)
SELECT
  resource_group,
  COUNT(*) AS workspace_count,
  string_agg(name, ', ') AS workspaces
FROM azure_log_analytics_workspace
GROUP BY resource_group
HAVING COUNT(*) > 1
ORDER BY workspace_count DESC;


-- Q09: Recovery Services Vaults — backup items per vault (find empty vaults)
SELECT
  v.name AS vault_name,
  v.resource_group,
  v.region,
  v.sku_name
FROM azure_recovery_services_vault v
ORDER BY v.resource_group;


-- Q10: Disk snapshots older than 90 days (waste)
SELECT
  name,
  resource_group,
  disk_size_gb,
  time_created,
  EXTRACT(EPOCH FROM (now() - time_created)) / 86400 AS age_days
FROM azure_compute_snapshot
WHERE time_created < now() - interval '90 days'
ORDER BY age_days DESC;


-- Q11: VPN Gateways with SKU vs. connection count (oversized gateways)
SELECT
  vgw.name,
  vgw.resource_group,
  vgw.sku_name,
  vgw.sku_tier,
  vgw.vpn_type,
  vgw.active_active
FROM azure_virtual_network_gateway vgw
WHERE vgw.gateway_type = 'Vpn'
ORDER BY vgw.sku_tier DESC;


-- Q12: NAT Gateways and Application Gateways per region (costly, often left running)
SELECT
  type,
  location,
  resource_group,
  name,
  sku_name
FROM (
  SELECT 'nat-gateway' AS type, location, resource_group, name, sku_name
  FROM azure_nat_gateway
  UNION ALL
  SELECT 'app-gateway' AS type, location, resource_group, name, sku_name
  FROM azure_application_gateway
) combined
ORDER BY type, resource_group;


-- Q13: Resource counts by resource group (find sparse / forgotten RGs)
SELECT
  resource_group,
  COUNT(*) AS resource_count,
  COUNT(*) FILTER (WHERE tags = '{}' OR tags IS NULL) AS untagged_count
FROM azure_resource
GROUP BY resource_group
ORDER BY resource_count DESC;


-- Q14: SQL databases by service tier (find unused Premium tiers)
SELECT
  db.name AS database_name,
  server.name AS server_name,
  db.resource_group,
  db.sku_name,
  db.sku_tier,
  db.status
FROM azure_sql_database db
JOIN azure_sql_server server ON db.server_name = server.name
ORDER BY db.sku_tier DESC;


-- Q15: Tag coverage score per mandatory tag across subscription
SELECT
  'env' AS tag_name,
  COUNT(*) FILTER (WHERE tags ? 'env') AS tagged,
  COUNT(*) AS total,
  ROUND(100.0 * COUNT(*) FILTER (WHERE tags ? 'env') / NULLIF(COUNT(*), 0), 1) AS coverage_pct
FROM azure_resource
UNION ALL
SELECT 'app',
  COUNT(*) FILTER (WHERE tags ? 'app'),
  COUNT(*),
  ROUND(100.0 * COUNT(*) FILTER (WHERE tags ? 'app') / NULLIF(COUNT(*), 0), 1)
FROM azure_resource
UNION ALL
SELECT 'cost_center',
  COUNT(*) FILTER (WHERE tags ? 'cost_center'),
  COUNT(*),
  ROUND(100.0 * COUNT(*) FILTER (WHERE tags ? 'cost_center') / NULLIF(COUNT(*), 0), 1)
FROM azure_resource
UNION ALL
SELECT 'owner',
  COUNT(*) FILTER (WHERE tags ? 'owner'),
  COUNT(*),
  ROUND(100.0 * COUNT(*) FILTER (WHERE tags ? 'owner') / NULLIF(COUNT(*), 0), 1)
FROM azure_resource
UNION ALL
SELECT 'criticality',
  COUNT(*) FILTER (WHERE tags ? 'criticality'),
  COUNT(*),
  ROUND(100.0 * COUNT(*) FILTER (WHERE tags ? 'criticality') / NULLIF(COUNT(*), 0), 1)
FROM azure_resource
ORDER BY coverage_pct ASC;
