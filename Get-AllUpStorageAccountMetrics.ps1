# Requires: Az.Accounts, Az.Resources, Az.Storage, Az.Monitor
# Reader RBAC is usually enough because this is control-plane metrics, not data-plane enumeration.

$ErrorActionPreference = "Stop"

Connect-AzAccount | Out-Null

function Get-LatestMetricAverage {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$MetricName,
        [int]$LookbackHours = 48
    )

    $start = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
    $end   = (Get-Date).ToUniversalTime()

    try {
        $m = Get-AzMetric `
            -ResourceId $ResourceId `
            -MetricName $MetricName `
            -TimeGrain 01:00:00 `
            -StartTime $start `
            -EndTime $end `
            -AggregationType Average

        $dp = $m.Data |
            Where-Object { $null -ne $_.Average } |
            Sort-Object TimeStamp -Descending |
            Select-Object -First 1

        if (-not $dp) { return $null }
        return [double]$dp.Average
    }
    catch {
        # Metric not available for that resource type or no permission in that scope
        return $null
    }
}

function BytesToGiB {
    param($bytes)
    if ($null -eq $bytes) { return $null }
    return [Math]::Round([double]$bytes / 1GB, 2)
}

$results = New-Object System.Collections.Generic.List[object]

$subs = Get-AzSubscription
foreach ($sub in $subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # List storage accounts via ARM (Reader-safe)
    $storageAccounts = Get-AzResource -ResourceType "Microsoft.Storage/storageAccounts"

    foreach ($sa in $storageAccounts) {
        $saId = $sa.ResourceId

        # Service resourceIds
        $blobId  = "$saId/blobServices/default"
        $fileId  = "$saId/fileServices/default"
        $queueId = "$saId/queueServices/default"
        $tableId = "$saId/tableServices/default"

        $usedCapacityBytes = Get-LatestMetricAverage -ResourceId $saId -MetricName "UsedCapacity"

        $blobCapacityBytes  = Get-LatestMetricAverage -ResourceId $blobId  -MetricName "BlobCapacity"
        $blobProvBytes      = Get-LatestMetricAverage -ResourceId $blobId  -MetricName "BlobProvisionedSize"
        $fileCapacityBytes  = Get-LatestMetricAverage -ResourceId $fileId  -MetricName "FileCapacity"
        $queueCapacityBytes = Get-LatestMetricAverage -ResourceId $queueId -MetricName "QueueCapacity"
        $tableCapacityBytes = Get-LatestMetricAverage -ResourceId $tableId -MetricName "TableCapacity"

        # File share provisioned quota via ARM (Reader-safe)
        $fileProvisionedGiB = $null
        try {
            $shares = Get-AzRmStorageShare -ResourceGroupName $sa.ResourceGroupName `
                -StorageAccountName $sa.Name -ErrorAction SilentlyContinue
            if ($shares) {
                $fileProvisionedGiB = ($shares | Measure-Object -Property QuotaGiB -Sum).Sum
            }
        }
        catch { }

        # Optional "what is being used" counts
        $blobCount      = Get-LatestMetricAverage -ResourceId $blobId  -MetricName "BlobCount"
        $containerCount = Get-LatestMetricAverage -ResourceId $blobId  -MetricName "ContainerCount"
        $fileCount      = Get-LatestMetricAverage -ResourceId $fileId  -MetricName "FileCount"
        $fileShareCount = Get-LatestMetricAverage -ResourceId $fileId  -MetricName "FileShareCount"
        $queueCount     = Get-LatestMetricAverage -ResourceId $queueId -MetricName "QueueCount"
        $queueMsgCount  = Get-LatestMetricAverage -ResourceId $queueId -MetricName "QueueMessageCount"
        $tableCount     = Get-LatestMetricAverage -ResourceId $tableId -MetricName "TableCount"
        $tableEntityCount = Get-LatestMetricAverage -ResourceId $tableId -MetricName "TableEntityCount"

        # "Unconsumed" only makes sense where provisioned/quota exists
        $blobUnconsumedBytes = $null
        if ($null -ne $blobProvBytes -and $null -ne $blobCapacityBytes -and $blobProvBytes -gt 0) {
            $blobUnconsumedBytes = [Math]::Max(0, $blobProvBytes - $blobCapacityBytes)
        }

        $fileCapGiB = BytesToGiB $fileCapacityBytes
        $fileUnconsumedGiB = $null
        if ($null -ne $fileProvisionedGiB -and $null -ne $fileCapGiB -and $fileProvisionedGiB -gt 0) {
            $fileUnconsumedGiB = [Math]::Round([Math]::Max(0, $fileProvisionedGiB - $fileCapGiB), 2)
        }

        $results.Add([PSCustomObject]@{
            SubscriptionName   = $sub.Name
            StorageAccount     = $sa.Name
            ResourceGroup      = $sa.ResourceGroupName
            Location           = $sa.Location

            UsedCapacityGiB    = BytesToGiB $usedCapacityBytes

            BlobCapacityGiB    = BytesToGiB $blobCapacityBytes
            BlobProvisionedGiB = BytesToGiB $blobProvBytes
            BlobUnconsumedGiB  = BytesToGiB $blobUnconsumedBytes

            FileCapacityGiB    = BytesToGiB $fileCapacityBytes
            FileProvisionedGiB = $fileProvisionedGiB
            FileUnconsumedGiB  = $fileUnconsumedGiB

            QueueCapacityGiB   = BytesToGiB $queueCapacityBytes
            TableCapacityGiB   = BytesToGiB $tableCapacityBytes

            BlobCount          = if ($null -ne $blobCount) { [int]$blobCount } else { $null }
            ContainerCount     = if ($null -ne $containerCount) { [int]$containerCount } else { $null }
            FileCount          = if ($null -ne $fileCount) { [int]$fileCount } else { $null }
            FileShareCount     = if ($null -ne $fileShareCount) { [int]$fileShareCount } else { $null }
            QueueCount         = if ($null -ne $queueCount) { [int]$queueCount } else { $null }
            QueueMessageCount  = if ($null -ne $queueMsgCount) { [int]$queueMsgCount } else { $null }
            TableCount         = if ($null -ne $tableCount) { [int]$tableCount } else { $null }
            TableEntityCount   = if ($null -ne $tableEntityCount) { [int]$tableEntityCount } else { $null }
        })
    }
}

# Per-account output
$results | Sort-Object SubscriptionName, StorageAccount | Format-Table -AutoSize

# Totals across all accounts you can see
$totals = [PSCustomObject]@{
    TotalUsedGiB     = [Math]::Round(($results | Measure-Object UsedCapacityGiB -Sum).Sum, 2)
    TotalBlobGiB     = [Math]::Round(($results | Measure-Object BlobCapacityGiB -Sum).Sum, 2)
    TotalBlobProvGiB = [Math]::Round(($results | Measure-Object BlobProvisionedGiB -Sum).Sum, 2)
    TotalFileGiB     = [Math]::Round(($results | Measure-Object FileCapacityGiB -Sum).Sum, 2)
    TotalFileProvGiB = [Math]::Round(($results | Measure-Object FileProvisionedGiB -Sum).Sum, 2)
    TotalQueueGiB    = [Math]::Round(($results | Measure-Object QueueCapacityGiB -Sum).Sum, 2)
    TotalTableGiB    = [Math]::Round(($results | Measure-Object TableCapacityGiB -Sum).Sum, 2)
}
$totals | Format-List

# Export
$results | Export-Csv -NoTypeInformation -Path ".\storage-capacity-report.csv"
