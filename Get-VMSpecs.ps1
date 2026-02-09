<#
.SYNOPSIS
  VM + Disk inventory across all subscriptions (Reader-friendly).
  Exports:
    - vm-summary.csv (per VM)
    - vm-disks.csv (per disk per VM)

.NOTES
  Requires: Az.Accounts, Az.Compute
  "Consumed disk space" inside the OS is NOT available from ARM with Reader alone.
  This script reports provisioned managed disk size (DiskSizeGB), which is typically what backup scoping starts from.
#>

$ErrorActionPreference = "Stop"

Connect-AzAccount | Out-Null

# Output paths
$outVmSummary = ".\vm-summary.csv"
$outVmDisks   = ".\vm-disks.csv"

function BytesToGiB {
    param($bytes)
    if ($null -eq $bytes) { return $null }
    return [Math]::Round([double]$bytes / 1GB, 2)
}

# Cache VM sizes per location to avoid hammering the API
$vmSizeCache = @{}   # key: location -> hashtable(vmSizeName -> sizeObj)

function Get-AzVmSizeInfoCached {
    param(
        [Parameter(Mandatory=$true)][string]$Location,
        [Parameter(Mandatory=$true)][string]$VmSizeName
    )

    if (-not $vmSizeCache.ContainsKey($Location)) {
        $map = @{}
        try {
            $sizes = Get-AzVMSize -Location $Location -ErrorAction Stop
            foreach ($s in $sizes) { $map[$s.Name] = $s }
        }
        catch {
            # Get-AzVMSize may be deprecated in newer Az.Compute; fall back to resource SKUs
            try {
                $skus = Get-AzComputeResourceSku -Location $Location |
                    Where-Object { $_.ResourceType -eq 'virtualMachines' }
                foreach ($sku in $skus) {
                    $caps = @{}
                    foreach ($c in $sku.Capabilities) { $caps[$c.Name] = $c.Value }
                    $vcpu = 0
                    if ($caps['vCPUs'])          { $vcpu = [int]$caps['vCPUs'] }
                    elseif ($caps['vCPUsAvailable']) { $vcpu = [int]$caps['vCPUsAvailable'] }
                    $memMB = 0
                    if ($caps['MemoryGB']) { $memMB = [int](([double]$caps['MemoryGB']) * 1024) }
                    $map[$sku.Name] = [PSCustomObject]@{
                        Name          = $sku.Name
                        NumberOfCores = $vcpu
                        MemoryInMB    = $memMB
                    }
                }
            }
            catch {
                Write-Warning "Could not retrieve VM sizes for location $Location"
            }
        }
        $vmSizeCache[$Location] = $map
    }

    $locMap = $vmSizeCache[$Location]
    if ($locMap.ContainsKey($VmSizeName)) { return $locMap[$VmSizeName] }
    return $null
}

# Cache disks by resource ID
$diskCache = @{}  # key: diskResourceId -> diskObj

function Get-DiskSafe {
    param([string]$DiskId)

    if ([string]::IsNullOrWhiteSpace($DiskId)) { return $null }

    if ($diskCache.ContainsKey($DiskId)) { return $diskCache[$DiskId] }

    try {
        # Parse resource ID: /subscriptions/.../resourceGroups/<rg>/providers/Microsoft.Compute/disks/<name>
        $segments = $DiskId -split '/'
        $rgIdx   = [array]::IndexOf($segments, 'resourceGroups')
        $dIdx    = [array]::IndexOf($segments, 'disks')
        $rg      = $segments[$rgIdx + 1]
        $dName   = $segments[$dIdx + 1]

        $d = Get-AzDisk -ResourceGroupName $rg -DiskName $dName -ErrorAction Stop
        $diskCache[$DiskId] = $d
        return $d
    }
    catch {
        $diskCache[$DiskId] = $null
        return $null
    }
}

$vmSummaryRows = New-Object System.Collections.Generic.List[object]
$vmDiskRows    = New-Object System.Collections.Generic.List[object]

$subs = Get-AzSubscription
foreach ($sub in $subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Get VMs with instance view (power state)
    $vms = Get-AzVM -Status

    foreach ($vm in $vms) {
        $vmName = $vm.Name
        $rgName = $vm.ResourceGroupName
        $loc    = $vm.Location
        $size   = $vm.HardwareProfile.VmSize

        $sizeInfo = Get-AzVmSizeInfoCached -Location $loc -VmSizeName $size
        $vcpus = if ($sizeInfo) { $sizeInfo.NumberOfCores } else { $null }
        $ramGiB = if ($sizeInfo) { [Math]::Round($sizeInfo.MemoryInMB / 1024, 2) } else { $null }

        # PowerState - handle both current ($vm.PowerState) and legacy ($vm.Statuses) formats
        $powerState = $vm.PowerState
        if (-not $powerState) {
            $psStatus = $vm.Statuses |
                Where-Object { $_.Code -like "PowerState/*" } |
                Select-Object -First 1
            if ($psStatus) { $powerState = $psStatus.DisplayStatus }
        }

        $osType = $vm.StorageProfile.OsDisk.OsType
        $osDisk = $vm.StorageProfile.OsDisk
        $dataDisks = $vm.StorageProfile.DataDisks

        # VM summary row (one per VM)
        $vmSummaryRows.Add([PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            ResourceGroup    = $rgName
            VMName           = $vmName
            Location         = $loc
            VmSizeSku        = $size
            vCPUs            = $vcpus
            RAMGiB           = $ramGiB
            PowerState       = $powerState
            OsType           = $osType
            OsDiskName       = $osDisk.Name
            DataDiskCount    = if ($dataDisks) { $dataDisks.Count } else { 0 }
        })

        # ---- OS Disk row ----
        $osDiskId = $osDisk.ManagedDisk.Id
        $osManaged = Get-DiskSafe -DiskId $osDiskId

        $vmDiskRows.Add([PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            ResourceGroup    = $rgName
            VMName           = $vmName
            Location         = $loc
            VmSizeSku        = $size
            vCPUs            = $vcpus
            RAMGiB           = $ramGiB
            PowerState       = $powerState
            OsType           = $osType

            DiskRole         = "OS"
            Lun              = $null
            Caching          = $osDisk.Caching
            WriteAccelerator = $osDisk.WriteAcceleratorEnabled

            DiskName         = if ($osManaged) { $osManaged.Name } else { $osDisk.Name }
            DiskId           = $osDiskId
            DiskSku          = if ($osManaged) { $osManaged.Sku.Name } else { $null }
            DiskTier         = if ($osManaged) { $osManaged.Tier } else { $null }
            EncryptionType   = if ($osManaged) { $osManaged.Encryption.Type } else { $null }
            ProvisionedGiB   = if ($osManaged) { $osManaged.DiskSizeGB } else { $osDisk.DiskSizeGB }

            # This is NOT guest used space. Azure doesn't expose that via ARM.
            ConsumedGiB      = $null
        })

        # ---- Data Disks rows ----
        foreach ($dd in $dataDisks) {
            $ddId = $dd.ManagedDisk.Id
            $ddManaged = Get-DiskSafe -DiskId $ddId

            $vmDiskRows.Add([PSCustomObject]@{
                SubscriptionName = $sub.Name
                SubscriptionId   = $sub.Id
                ResourceGroup    = $rgName
                VMName           = $vmName
                Location         = $loc
                VmSizeSku        = $size
                vCPUs            = $vcpus
                RAMGiB           = $ramGiB
                PowerState       = $powerState
                OsType           = $osType

                DiskRole         = "Data"
                Lun              = $dd.Lun
                Caching          = $dd.Caching
                WriteAccelerator = $dd.WriteAcceleratorEnabled

                DiskName         = if ($ddManaged) { $ddManaged.Name } else { $dd.Name }
                DiskId           = $ddId
                DiskSku          = if ($ddManaged) { $ddManaged.Sku.Name } else { $null }
                DiskTier         = if ($ddManaged) { $ddManaged.Tier } else { $null }
                EncryptionType   = if ($ddManaged) { $ddManaged.Encryption.Type } else { $null }
                ProvisionedGiB   = if ($ddManaged) { $ddManaged.DiskSizeGB } else { $dd.DiskSizeGB }

                # Not available via ARM without guest telemetry.
                ConsumedGiB      = $null
            })
        }
    }
}

$vmSummaryRows | Sort-Object SubscriptionName, ResourceGroup, VMName |
    Export-Csv -NoTypeInformation -Path $outVmSummary

$vmDiskRows | Sort-Object SubscriptionName, ResourceGroup, VMName, DiskRole, Lun |
    Export-Csv -NoTypeInformation -Path $outVmDisks

Write-Host "Exported:" -ForegroundColor Green
Write-Host "  $outVmSummary"
Write-Host "  $outVmDisks"
