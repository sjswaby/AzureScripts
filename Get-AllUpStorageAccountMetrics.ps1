# Requires: Az.Accounts, Az.Resources, Az.Storage
# Reader RBAC is usually enough because this is control-plane metrics, not data-plane enumeration.

$ErrorActionPreference = "Stop"

# Authenticate — try interactive login, fall back to existing session (e.g. CloudShell)
try { Connect-AzAccount -ErrorAction Stop | Out-Null }
catch { Write-Host "Interactive login unavailable, using existing context." }

$ctx = Get-AzContext
if (-not $ctx -or -not $ctx.Tenant) {
    throw "No Azure context found. Please run Connect-AzAccount or launch from CloudShell."
}
$tenantId = $ctx.Tenant.Id

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

$subs = Get-AzSubscription -TenantId $tenantId
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

            BlobCount          = if ($null -ne $blobCount) { [long]$blobCount } else { $null }
            ContainerCount     = if ($null -ne $containerCount) { [long]$containerCount } else { $null }
            FileCount          = if ($null -ne $fileCount) { [long]$fileCount } else { $null }
            FileShareCount     = if ($null -ne $fileShareCount) { [long]$fileShareCount } else { $null }
            QueueCount         = if ($null -ne $queueCount) { [long]$queueCount } else { $null }
            QueueMessageCount  = if ($null -ne $queueMsgCount) { [long]$queueMsgCount } else { $null }
            TableCount         = if ($null -ne $tableCount) { [long]$tableCount } else { $null }
            TableEntityCount   = if ($null -ne $tableEntityCount) { [long]$tableEntityCount } else { $null }
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
