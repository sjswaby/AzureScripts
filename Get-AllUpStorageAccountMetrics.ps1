# Requires: Az.Accounts, Az.Resources, Az.Monitor
# Reader RBAC is usually enough because this is control-plane metrics, not data-plane enumeration.

$ErrorActionPreference = "Stop"

function Get-LatestMetricAverage {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$MetricName,
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
            Where-Object { $_.Average -ne $null } |
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

function BytesToGiB([double]$bytes) {
    if ($bytes -eq $null) { return $null }
    return [Math]::Round($bytes / 1GB, 2)
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

        $blobCapacityBytes = Get-LatestMetricAverage -ResourceId $blobId -MetricName "BlobCapacity"
        $blobProvBytes     = Get-LatestMetricAverage -ResourceId $blobId -MetricName "BlobProvisionedSize"
        $fileCapacityBytes = Get-LatestMetricAverage -ResourceId $fileId -MetricName "FileCapacity"
        $queueCapacityBytes= Get-LatestMetricAverage -ResourceId $queueId -MetricName "QueueCapacity"
        $tableCapacityBytes= Get-LatestMetricAverage -ResourceId $tableId -MetricName "TableCapacity"

        # Optional “what is being used” counts
        $blobCount         = Get-LatestMetricAverage -ResourceId $blobId  -MetricName "BlobCount"
        $containerCount    = Get-LatestMetricAverage -ResourceId $blobId  -MetricName "ContainerCount"
        $fileCount         = Get-LatestMetricAverage -ResourceId $fileId  -MetricName "FileCount"
        $fileShareCount    = Get-LatestMetricAverage -ResourceId $fileId  -MetricName "FileShareCount"
        $queueCount        = Get-LatestMetricAverage -ResourceId $queueId -MetricName "QueueCount"
        $queueMsgCount     = Get-LatestMetricAverage -ResourceId $queueId -MetricName "QueueMessageCount"
        $tableCount        = Get-LatestMetricAverage -ResourceId $tableId -MetricName "TableCount"
        $tableEntityCount  = Get-LatestMetricAverage -ResourceId $tableId -MetricName "TableEntityCount"

        # “Unconsumed” only makes sense where provisioned/quota exists
        $blobUnconsumedBytes = $null
        if ($blobProvBytes -ne $null -and $blobCapacityBytes -ne $null -and $blobProvBytes -gt 0) {
            $blobUnconsumedBytes = [Math]::Max(0, $blobProvBytes - $blobCapacityBytes)
        }

        $results.Add([PSCustomObject]@{
            SubscriptionName   = $sub.Name
            StorageAccount     = $sa.Name
            ResourceGroup      = $sa.ResourceGroupName
            Location           = $sa.Location

            UsedCapacityGiB    = BytesToGiB $usedCapacityBytes

            BlobCapacityGiB    = BytesToGiB $blobCapacityBytes
            FileCapacityGiB    = BytesToGiB $fileCapacityBytes
            QueueCapacityGiB   = BytesToGiB $queueCapacityBytes
            TableCapacityGiB   = BytesToGiB $tableCapacityBytes

            BlobProvisionedGiB = BytesToGiB $blobProvBytes
            BlobUnconsumedGiB  = BytesToGiB $blobUnconsumedBytes

            BlobCount          = if ($blobCount -ne $null) { [int]$blobCount } else { $null }
            ContainerCount     = if ($containerCount -ne $null) { [int]$containerCount } else { $null }
            FileCount          = if ($fileCount -ne $null) { [int]$fileCount } else { $null }
            FileShareCount     = if ($fileShareCount -ne $null) { [int]$fileShareCount } else { $null }
            QueueCount         = if ($queueCount -ne $null) { [int]$queueCount } else { $null }
            QueueMessageCount  = if ($queueMsgCount -ne $null) { [int]$queueMsgCount } else { $null }
            TableCount         = if ($tableCount -ne $null) { [int]$tableCount } else { $null }
            TableEntityCount   = if ($tableEntityCount -ne $null) { [int]$tableEntityCount } else { $null }
        })
    }
}

# Per-account output
$results | Sort-Object SubscriptionName, StorageAccount | Format-Table -AutoSize

# Totals across all accounts you can see
$totals = [PSCustomObject]@{
    TotalUsedGiB  = [Math]::Round(($results | Measure-Object UsedCapacityGiB -Sum).Sum, 2)
    TotalBlobGiB  = [Math]::Round(($results | Measure-Object BlobCapacityGiB -Sum).Sum, 2)
    TotalFileGiB  = [Math]::Round(($results | Measure-Object FileCapacityGiB -Sum).Sum, 2)
    TotalQueueGiB = [Math]::Round(($results | Measure-Object QueueCapacityGiB -Sum).Sum, 2)
    TotalTableGiB = [Math]::Round(($results | Measure-Object TableCapacityGiB -Sum).Sum, 2)
}
$totals | Format-List

# Optional export

$results | Export-Csv -NoTypeInformation -Path ".\storage-capacity-report.csv"