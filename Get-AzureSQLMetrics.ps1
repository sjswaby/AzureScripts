<#
.SYNOPSIS
  Azure SQL inventory across all subscriptions (Reader-friendly).
  Covers:
    - Azure SQL Database (PaaS) — servers, databases, elastic pools
    - Azure SQL Managed Instance
    - SQL Server on Azure VMs (IaaS via SqlVirtualMachine resource provider)
  Exports: azure-sql-inventory.csv

.NOTES
  Requires: Az.Accounts, Az.Sql, Az.Compute
  Optional: Az.SqlVirtualMachine (for SQL IaaS VM discovery)
  Only ARM Reader access is needed. Consumed storage uses the Azure Monitor REST API
  via Invoke-AzRestMethod (no Az.Monitor module dependency).
  SQL IaaS VMs only appear if the SQL IaaS Agent extension is registered on the VM.
#>

$ErrorActionPreference = "Stop"

# Use existing context (CloudShell / already-authenticated session)
$ctx = Get-AzContext
if (-not $ctx -or -not $ctx.Tenant) {
    throw "No Azure context found. Please run Connect-AzAccount or launch from CloudShell."
}
$tenantId = $ctx.Tenant.Id

$outFile = ".\azure-sql-inventory.csv"

# Retrieve the most recent hourly average via the Azure Monitor REST API.
# Uses Invoke-AzRestMethod (Az.Accounts) so there is no dependency on Az.Monitor.
function Get-LatestMetricAverage {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$MetricName,
        [int]$LookbackHours = 48
    )

    $start = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $end   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $path = "${ResourceId}/providers/microsoft.insights/metrics" +
            "?api-version=2024-02-01" +
            "&metricnames=$MetricName" +
            "&timespan=${start}/${end}" +
            "&interval=PT1H" +
            "&aggregation=Average"

    try {
        $response = Invoke-AzRestMethod -Path $path -Method GET
        if ($response.StatusCode -ne 200) { return $null }

        $body       = $response.Content | ConvertFrom-Json
        $timeseries = $body.value[0].timeseries
        if (-not $timeseries -or $timeseries.Count -eq 0) { return $null }

        $dp = $timeseries[0].data |
            Where-Object { $null -ne $_.average } |
            Sort-Object timeStamp -Descending |
            Select-Object -First 1

        if (-not $dp) { return $null }
        return [double]$dp.average
    }
    catch { return $null }
}

$results = New-Object System.Collections.Generic.List[object]

$subs = Get-AzSubscription -TenantId $tenantId
$subIndex = 0
foreach ($sub in $subs) {
    $subIndex++
    Write-Host "[$subIndex/$($subs.Count)] Subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan

    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "  Skipping subscription '$($sub.Name)' — unable to set context: $_"
        continue
    }

    # ── Azure SQL Database servers ──────────────────────────────────────────────
    $sqlServers = @()
    try { $sqlServers = Get-AzSqlServer -ErrorAction Stop } catch { }

    $serverIndex = 0
    foreach ($server in $sqlServers) {
        $serverIndex++
        Write-Host "  [$serverIndex/$($sqlServers.Count)] SQL Server: $($server.ServerName)" -ForegroundColor White
        $serverRg = $server.ResourceGroupName

        # ── Elastic Pools on this server ──
        $pools = @()
        try { $pools = Get-AzSqlElasticPool -ServerName $server.ServerName -ResourceGroupName $serverRg -ErrorAction Stop } catch { }

        foreach ($pool in $pools) {
            $poolStorageBytes = Get-LatestMetricAverage -ResourceId $pool.ResourceId -MetricName "storage_used"
            $poolAllocBytes   = Get-LatestMetricAverage -ResourceId $pool.ResourceId -MetricName "allocated_data_storage"

            $results.Add([PSCustomObject]@{
                SubscriptionName     = $sub.Name
                ResourceGroup        = $serverRg
                SqlType              = "Elastic Pool"
                ServerName           = $server.ServerName
                ResourceName         = $pool.ElasticPoolName
                Location             = $pool.Location
                Edition              = $pool.Edition
                ServiceTier          = $pool.SkuName
                Capacity             = $pool.Capacity
                Family               = $pool.Family
                MaxSizeGB            = if ($pool.StorageMB) { [Math]::Round($pool.StorageMB / 1024, 2) } else { $null }
                StorageUsedGB        = if ($null -ne $poolStorageBytes) { [Math]::Round($poolStorageBytes / 1GB, 2) } else { $null }
                StorageAllocatedGB   = if ($null -ne $poolAllocBytes)  { [Math]::Round($poolAllocBytes / 1GB, 2) }  else { $null }
                LicenseType          = $pool.LicenseType
                ZoneRedundant        = $pool.ZoneRedundant
                Status               = $pool.State
                ElasticPoolName      = $null
                VmResourceId         = $null
            })
        }

        # ── Databases on this server ──
        $dbs = @()
        try {
            $dbs = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $serverRg -ErrorAction Stop |
                Where-Object { $_.DatabaseName -ne 'master' }
        } catch { }

        foreach ($db in $dbs) {
            # storage = used data space (bytes); allocated_data_storage = allocated data files (bytes)
            $storageBytes   = Get-LatestMetricAverage -ResourceId $db.ResourceId -MetricName "storage"
            $allocatedBytes = Get-LatestMetricAverage -ResourceId $db.ResourceId -MetricName "allocated_data_storage"

            $capacity = $null
            $family   = $null
            if ($db.CurrentSku) {
                $capacity = $db.CurrentSku.Capacity
                $family   = $db.CurrentSku.Family
            }

            $results.Add([PSCustomObject]@{
                SubscriptionName     = $sub.Name
                ResourceGroup        = $serverRg
                SqlType              = "Azure SQL Database"
                ServerName           = $server.ServerName
                ResourceName         = $db.DatabaseName
                Location             = $db.Location
                Edition              = $db.Edition
                ServiceTier          = $db.CurrentServiceObjectiveName
                Capacity             = $capacity
                Family               = $family
                MaxSizeGB            = if ($db.MaxSizeBytes) { [Math]::Round($db.MaxSizeBytes / 1GB, 2) } else { $null }
                StorageUsedGB        = if ($null -ne $storageBytes)   { [Math]::Round($storageBytes / 1GB, 2) }   else { $null }
                StorageAllocatedGB   = if ($null -ne $allocatedBytes) { [Math]::Round($allocatedBytes / 1GB, 2) } else { $null }
                LicenseType          = $db.LicenseType
                ZoneRedundant        = $db.ZoneRedundant
                Status               = $db.Status
                ElasticPoolName      = $db.ElasticPoolName
                VmResourceId         = $null
            })
        }
    }

    # ── Azure SQL Managed Instances ─────────────────────────────────────────────
    $managedInstances = @()
    try { $managedInstances = Get-AzSqlInstance -ErrorAction Stop } catch { }

    $miIndex = 0
    foreach ($mi in $managedInstances) {
        $miIndex++
        Write-Host "  [$miIndex/$($managedInstances.Count)] Managed Instance: $($mi.ManagedInstanceName)" -ForegroundColor White
        $miStorageUsedMB = Get-LatestMetricAverage -ResourceId $mi.Id -MetricName "storage_space_used_mb"

        $results.Add([PSCustomObject]@{
            SubscriptionName     = $sub.Name
            ResourceGroup        = $mi.ResourceGroupName
            SqlType              = "Managed Instance"
            ServerName           = $mi.ManagedInstanceName
            ResourceName         = "(instance)"
            Location             = $mi.Location
            Edition              = $mi.Sku.Tier
            ServiceTier          = $mi.Sku.Name
            Capacity             = $mi.VCores
            Family               = $mi.Sku.Family
            MaxSizeGB            = $mi.StorageSizeInGB
            StorageUsedGB        = if ($null -ne $miStorageUsedMB) { [Math]::Round($miStorageUsedMB / 1024, 2) } else { $null }
            StorageAllocatedGB   = $mi.StorageSizeInGB
            LicenseType          = $mi.LicenseType
            ZoneRedundant        = $mi.ZoneRedundant
            Status               = $mi.State
            ElasticPoolName      = $null
            VmResourceId         = $null
        })

        # MI databases (skip system databases)
        $miDbs = @()
        try {
            $miDbs = Get-AzSqlInstanceDatabase -InstanceName $mi.ManagedInstanceName `
                -ResourceGroupName $mi.ResourceGroupName -ErrorAction Stop
        } catch { }

        foreach ($miDb in $miDbs) {
            if ($miDb.Name -in @('master', 'msdb', 'model', 'tempdb')) { continue }

            $results.Add([PSCustomObject]@{
                SubscriptionName     = $sub.Name
                ResourceGroup        = $mi.ResourceGroupName
                SqlType              = "Managed Instance DB"
                ServerName           = $mi.ManagedInstanceName
                ResourceName         = $miDb.Name
                Location             = $mi.Location
                Edition              = $mi.Sku.Tier
                ServiceTier          = $mi.Sku.Name
                Capacity             = $mi.VCores
                Family               = $mi.Sku.Family
                MaxSizeGB            = $null
                StorageUsedGB        = $null
                StorageAllocatedGB   = $null
                LicenseType          = $mi.LicenseType
                ZoneRedundant        = $mi.ZoneRedundant
                Status               = $miDb.Status
                ElasticPoolName      = $null
                VmResourceId         = $null
            })
        }
    }

    # ── SQL on IaaS VMs (requires Az.SqlVirtualMachine module) ──────────────────
    $sqlVMs = @()
    try { $sqlVMs = Get-AzSqlVM -ErrorAction Stop }
    catch {
        if ("$_" -match 'not recognized|not loaded') {
            Write-Warning "Az.SqlVirtualMachine module not available. Install with: Install-Module Az.SqlVirtualMachine"
        }
    }

    $sqlVmIndex = 0
    foreach ($sqlvm in $sqlVMs) {
        $sqlVmIndex++
        Write-Host "  [$sqlVmIndex/$($sqlVMs.Count)] SQL IaaS VM: $($sqlvm.Name)" -ForegroundColor White
        $vmResId     = $sqlvm.VirtualMachineResourceId
        $vmSize      = $null
        $totalDiskGB = $null

        # Pull VM size and total provisioned disk from the underlying VM
        if ($vmResId) {
            try {
                $vmSeg    = $vmResId -split '/'
                $vmRgIdx  = [array]::IndexOf($vmSeg, 'resourceGroups')
                $vmNmIdx  = [array]::IndexOf($vmSeg, 'virtualMachines')
                $vmObj    = Get-AzVM -ResourceGroupName $vmSeg[$vmRgIdx + 1] -Name $vmSeg[$vmNmIdx + 1] -ErrorAction Stop
                $vmSize   = $vmObj.HardwareProfile.VmSize

                # Sum provisioned disk sizes from managed disk objects
                $allDiskIds = @()
                if ($vmObj.StorageProfile.OsDisk.ManagedDisk.Id) {
                    $allDiskIds += $vmObj.StorageProfile.OsDisk.ManagedDisk.Id
                }
                foreach ($dd in $vmObj.StorageProfile.DataDisks) {
                    if ($dd.ManagedDisk.Id) { $allDiskIds += $dd.ManagedDisk.Id }
                }

                $sumGB = 0
                foreach ($did in $allDiskIds) {
                    try {
                        $seg  = $did -split '/'
                        $ri   = [array]::IndexOf($seg, 'resourceGroups')
                        $di   = [array]::IndexOf($seg, 'disks')
                        $dObj = Get-AzDisk -ResourceGroupName $seg[$ri + 1] -DiskName $seg[$di + 1] -ErrorAction Stop
                        $sumGB += $dObj.DiskSizeGB
                    }
                    catch { }
                }
                if ($sumGB -gt 0) { $totalDiskGB = $sumGB }
            }
            catch { }
        }

        $sqlEdition = if ($sqlvm.SqlImageSku)   { $sqlvm.SqlImageSku }
                      elseif ($sqlvm.Sku)        { $sqlvm.Sku }
                      else                       { $null }
        $sqlOffer   = if ($sqlvm.SqlImageOffer)  { $sqlvm.SqlImageOffer }
                      elseif ($sqlvm.Offer)      { $sqlvm.Offer }
                      else                       { $null }

        $results.Add([PSCustomObject]@{
            SubscriptionName     = $sub.Name
            ResourceGroup        = $sqlvm.ResourceGroupName
            SqlType              = "SQL IaaS VM"
            ServerName           = $sqlvm.Name
            ResourceName         = $sqlvm.Name
            Location             = $sqlvm.Location
            Edition              = $sqlEdition
            ServiceTier          = $vmSize
            Capacity             = $null
            Family               = $sqlOffer
            MaxSizeGB            = $totalDiskGB
            StorageUsedGB        = $null    # Not available via ARM — requires in-OS access
            StorageAllocatedGB   = $totalDiskGB
            LicenseType          = $sqlvm.SqlServerLicenseType
            ZoneRedundant        = $null
            Status               = $null
            ElasticPoolName      = $null
            VmResourceId         = $vmResId
        })
    }
}

Write-Host "`nProcessing complete. $($results.Count) SQL resources found." -ForegroundColor Green

# Export and display
$results | Sort-Object SubscriptionName, SqlType, ServerName, ResourceName |
    Export-Csv -NoTypeInformation -Path $outFile

Write-Host "Exported: $outFile" -ForegroundColor Green
$results | Format-Table SubscriptionName, SqlType, ServerName, ResourceName, Edition, ServiceTier, Capacity, MaxSizeGB, StorageUsedGB -AutoSize
