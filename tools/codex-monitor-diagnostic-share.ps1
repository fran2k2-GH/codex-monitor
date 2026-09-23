[CmdletBinding()]
param(
    [string]$CodexExe
)

$ErrorActionPreference = 'Stop'

$diagnostic = Join-Path $PSScriptRoot 'codex-monitor-diagnostic.ps1'
if (-not (Test-Path -LiteralPath $diagnostic -PathType Leaf)) {
    throw 'No se encontró codex-monitor-diagnostic.ps1 junto al diagnóstico compartible.'
}

$invokeParams = @{}
if (-not [string]::IsNullOrWhiteSpace($CodexExe)) {
    $invokeParams.CodexExe = $CodexExe
}

$raw = (& $diagnostic @invokeParams | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($raw)) {
    throw 'El diagnóstico no devolvió salida.'
}

try {
    $report = $raw | ConvertFrom-Json -Depth 30
} catch {
    throw 'No se pudo interpretar la salida JSON del diagnóstico.'
}

function Redact-LocalPathText {
    param($Value)
    if ($null -eq $Value) { return $null }

    $text = [string]$Value
    foreach ($entry in @(
        @{ Value = $env:USERPROFILE; Replacement = '%USERPROFILE%' },
        @{ Value = $env:LOCALAPPDATA; Replacement = '%LOCALAPPDATA%' },
        @{ Value = $env:TEMP; Replacement = '%TEMP%' },
        @{ Value = $env:TMP; Replacement = '%TEMP%' }
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            $text = $text -replace [regex]::Escape([string]$entry.Value), [string]$entry.Replacement
        }
    }
    return $text
}

$report | Add-Member -NotePropertyName sanitizedForSharing -NotePropertyValue $true -Force

if ($null -ne $report.runtime) {
    $report.runtime.path = 'REDACTED_LOCAL_PATH'
}

if ($null -ne $report.sqliteIsolation) {
    $report.sqliteIsolation.temporaryPath = 'REDACTED_LOCAL_PATH'
    foreach ($file in @($report.sqliteIsolation.filesCreated)) {
        if ($null -ne $file -and $null -ne $file.PSObject.Properties['name']) {
            $file.name = 'REDACTED_FILE_NAME'
        }
    }
}

if ($null -ne $report.cleanup) {
    $report.cleanup.processId = $null
}

foreach ($snapshotName in @('snapshot1', 'snapshot2')) {
    $snapshot = $report.rateLimits.$snapshotName
    foreach ($row in @($snapshot)) {
        if ($null -eq $row) { continue }
        if ($null -ne $row.PSObject.Properties['usedPercent']) { $row.usedPercent = $null }
        if ($null -ne $row.PSObject.Properties['remainingPercent']) { $row.remainingPercent = $null }
        if ($null -ne $row.PSObject.Properties['resetsAtLocal']) { $row.resetsAtLocal = $null }
        if ($null -ne $row.PSObject.Properties['planType']) { $row.planType = $null }
        if ($null -ne $row.PSObject.Properties['rateLimitReachedType']) { $row.rateLimitReachedType = $null }
    }
}

if ($null -ne $report.credits) {
    foreach ($item in @($report.credits.functionalValues)) {
        if ($null -ne $item -and $null -ne $item.PSObject.Properties['value']) {
            $item.value = 'REDACTED_ACCOUNT_VALUE'
        }
    }
    $report.credits.availableCount = $null
    $report.credits.expirations = @()
}

if ($null -ne $report.usage) {
    foreach ($item in @($report.usage.summary)) {
        if ($null -ne $item -and $null -ne $item.PSObject.Properties['value']) {
            $item.value = 'REDACTED_ACCOUNT_VALUE'
        }
    }
    if ($null -ne $report.usage.today -and $null -ne $report.usage.today.PSObject.Properties['tokens']) {
        $report.usage.today.tokens = 'REDACTED_ACCOUNT_VALUE'
    }
}

if ($null -ne $report.stoppedReason) {
    $report.stoppedReason = Redact-LocalPathText $report.stoppedReason
}

$report | ConvertTo-Json -Depth 12
