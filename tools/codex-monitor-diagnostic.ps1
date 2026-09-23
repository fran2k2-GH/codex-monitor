[CmdletBinding()]
param(
    [string]$CodexExe
)

$ErrorActionPreference = 'Stop'

function Test-CodexRuntime {
    param([string]$Candidate)
    if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return $false }
    try {
        $si = [Diagnostics.ProcessStartInfo]::new($Candidate, '--version')
        $si.UseShellExecute = $false
        $si.RedirectStandardOutput = $true
        $si.RedirectStandardError = $true
        $si.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($si)
        $output = $process.StandardOutput.ReadToEnd().Trim()
        $null = $process.StandardError.ReadToEnd()
        $process.WaitForExit(5000) | Out-Null
        return $process.HasExited -and $process.ExitCode -eq 0 -and $output -match '^codex-cli\s'
    } catch {
        return $false
    }
}

function Get-OfficialRuntime {
    $bin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (-not (Test-Path -LiteralPath $bin -PathType Container)) { return $null }
    $candidates = @(Get-ChildItem -LiteralPath $bin -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { Join-Path $_.FullName 'codex.exe' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    foreach ($candidate in $candidates) {
        if (Test-CodexRuntime $candidate) { return $candidate }
    }
    return $null
}

$runtime = if ([string]::IsNullOrWhiteSpace($CodexExe)) { Get-OfficialRuntime } else { $CodexExe }
if (-not (Test-CodexRuntime $runtime)) {
    throw 'No se encontró un runtime oficial de Codex válido.'
}

$sqliteRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-monitor-sqlite-" + [guid]::NewGuid().ToString('N'))
$process = $null
$stderrTask = $null
$created = $false
$report = [ordered]@{
    runtime = [ordered]@{ path = $runtime; version = $null }
    sqliteIsolation = [ordered]@{ temporaryPath = $sqliteRoot; initiallyEmpty = $false; filesCreated = @(); observed = $false; cleanup = $false }
    handshake = 'NO_PROBADO'
    rateLimits = [ordered]@{ status = 'NO_PROBADO'; snapshot1 = @(); snapshot2 = @() }
    credits = [ordered]@{ classification = 'NO_CONFIRMADO'; functionalValues = @(); otherFieldNames = @(); resetCredits = 'NO_CONFIRMADO'; availableCount = $null; expirations = @() }
    usage = [ordered]@{ status = 'NO_PROBADO'; todayBucket = 'TODAY_BUCKET_NO_DEVUELTO'; today = $null }
    reuse = 'NO_PROBADO'
    cleanup = [ordered]@{ processId = $null; terminated = $false; forcedKill = $false }
    stoppedReason = $null
}

function Send-JsonLine {
    param($Writer, [hashtable]$Message)
    $Writer.WriteLine(($Message | ConvertTo-Json -Compress -Depth 12))
    $Writer.Flush()
}

function Read-Response {
    param($Reader, [int]$RequestId)
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    while ([DateTime]::UtcNow -lt $deadline) {
        $task = $Reader.ReadLineAsync()
        if (-not $task.Wait(25000)) { throw 'Timeout esperando stdout.' }
        $line = $task.Result
        if ($null -eq $line) { throw 'stdout cerrado por app-server.' }
        $message = $line | ConvertFrom-Json -Depth 30
        if ([string]$message.id -eq [string]$RequestId) { return $message }
    }
    throw 'Timeout esperando la respuesta solicitada.'
}

function To-LocalResetTime {
    param($UnixSeconds)
    if ($null -eq $UnixSeconds) { return $null }
    try { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixSeconds).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') }
    catch { return $null }
}

function Safe-FunctionalLimitId {
    param($Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ($text -match '^(codex|codex_[a-z0-9_]+|primary|secondary|weekly)$') { return $text }
    return 'IDENTIFICADOR_NO_FUNCIONAL_REDACTADO'
}

function Convert-RateLimitSnapshot {
    param($Response)
    $rows = @()
    # Prefer the multi-limit view. The legacy rateLimits field mirrors one group.
    $groups = @()
    if ($null -ne $Response.result.rateLimitsByLimitId) {
        foreach ($property in $Response.result.rateLimitsByLimitId.PSObject.Properties) {
            $groups += [ordered]@{ source = 'rateLimitsByLimitId'; mapKey = $property.Name; value = $property.Value }
        }
    } elseif ($null -ne $Response.result.rateLimits) {
        $groups += [ordered]@{ source = 'rateLimits_legacy'; mapKey = $null; value = $Response.result.rateLimits }
    }
    $index = 0
    foreach ($entry in $groups) {
        $group = $entry.value
        $identifier = Safe-FunctionalLimitId $(if ($null -ne $group.limitId) { $group.limitId } else { $entry.mapKey })
        foreach ($slot in @('primary', 'secondary')) {
            $bucket = $group.$slot
            if ($null -eq $bucket -or $null -eq $bucket.windowDurationMins) { continue }
            $index++
            $rows += [ordered]@{
                index = $index
                functionalIdentifier = $identifier
                limitName = $group.limitName
                slot = $slot
                planType = $group.planType
                rateLimitReachedType = $group.rateLimitReachedType
                durationMins = $bucket.windowDurationMins
                usedPercent = $bucket.usedPercent
                remainingPercent = if ($null -ne $bucket.usedPercent) { 100 - [double]$bucket.usedPercent } else { $null }
                resetsAtLocal = To-LocalResetTime $bucket.resetsAt
            }
        }
    }
    return $rows
}

function Get-CreditsObject {
    param($Response)
    if ($null -ne $Response.result.rateLimits.credits) { return $Response.result.rateLimits.credits }
    if ($null -ne $Response.result.rateLimitsByLimitId) {
        foreach ($property in $Response.result.rateLimitsByLimitId.PSObject.Properties) {
            if ($null -ne $property.Value.credits) { return $property.Value.credits }
        }
    }
    return $null
}

try {
    $versionInfo = [Diagnostics.ProcessStartInfo]::new($runtime, '--version')
    $versionInfo.UseShellExecute = $false
    $versionInfo.RedirectStandardOutput = $true
    $versionInfo.RedirectStandardError = $true
    $versionInfo.CreateNoWindow = $true
    $versionProcess = [Diagnostics.Process]::Start($versionInfo)
    $report.runtime.version = $versionProcess.StandardOutput.ReadToEnd().Trim()
    $null = $versionProcess.StandardError.ReadToEnd()
    $versionProcess.WaitForExit(5000) | Out-Null

    New-Item -ItemType Directory -Path $sqliteRoot | Out-Null
    $created = $true
    $report.sqliteIsolation.initiallyEmpty = @((Get-ChildItem -LiteralPath $sqliteRoot -Force)).Count -eq 0

    $startInfo = [Diagnostics.ProcessStartInfo]::new($runtime, 'app-server --listen stdio://')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    # Only the auxiliary process receives this temporary SQLite location.
    $startInfo.Environment['CODEX_SQLITE_HOME'] = $sqliteRoot

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'No se pudo iniciar app-server.' }
    $report.cleanup.processId = $process.Id
    $stderrTask = $process.StandardError.ReadToEndAsync()

    Send-JsonLine $process.StandardInput @{ jsonrpc = '2.0'; method = 'initialize'; id = 1; params = @{ clientInfo = @{ name = 'codex-monitor-diagnostic'; title = 'Codex Monitor Diagnostic'; version = '0D' } } }
    $initialize = Read-Response $process.StandardOutput 1
    if ($null -ne $initialize.error) { throw 'initialize devolvió un error.' }

    $report.sqliteIsolation.filesCreated = @(Get-ChildItem -LiteralPath $sqliteRoot -Recurse -File -Force | ForEach-Object { [ordered]@{ name = $_.Name; length = $_.Length } })
    $report.sqliteIsolation.observed = @($report.sqliteIsolation.filesCreated).Count -gt 0
    if (-not $report.sqliteIsolation.observed) {
        $report.stoppedReason = 'TEMP_SQLITE_UNUSED_STOPPED: no se consultó la cuenta para evitar usar SQLite no aislado.'
        return
    }

    Send-JsonLine $process.StandardInput @{ jsonrpc = '2.0'; method = 'initialized' }
    $report.handshake = 'PASS'

    Send-JsonLine $process.StandardInput @{ jsonrpc = '2.0'; method = 'account/rateLimits/read'; id = 2 }
    $firstRateLimits = Read-Response $process.StandardOutput 2
    if ($null -ne $firstRateLimits.error) { throw 'account/rateLimits/read devolvió un error.' }
    $report.rateLimits.status = 'PASS'

    $report.rateLimits.snapshot1 = @(Convert-RateLimitSnapshot $firstRateLimits)

    $creditsObject = Get-CreditsObject $firstRateLimits
    if ($null -eq $creditsObject) {
        $report.credits.classification = 'SALDO_CREDITOS_NO_EXPUESTO'
    } else {
        $safeNames = @('balance', 'remaining', 'used', 'limit', 'currency', 'unit', 'unlimited', 'hasCredits', 'amount', 'available')
        foreach ($property in $creditsObject.PSObject.Properties) {
            if ($safeNames -contains $property.Name) {
                $report.credits.functionalValues += [ordered]@{ name = $property.Name; value = $property.Value }
            } else {
                $report.credits.otherFieldNames += $property.Name
            }
        }
        $hasBalance = $null -ne $creditsObject.PSObject.Properties['balance']
        $hasUnit = $null -ne $creditsObject.PSObject.Properties['currency'] -or $null -ne $creditsObject.PSObject.Properties['unit']
        if ($hasBalance -and $hasUnit) { $report.credits.classification = 'BALANCE_COMPLETO' }
        elseif ($hasBalance) { $report.credits.classification = 'BALANCE_NUMERICO_SIN_UNIDAD' }
        else { $report.credits.classification = 'SOLO_ESTADO_CREDITOS' }
    }
    $resetCredits = $firstRateLimits.result.rateLimitResetCredits
    if ($null -ne $resetCredits) {
        $report.credits.resetCredits = 'DISPONIBLE'
        $report.credits.availableCount = $resetCredits.availableCount
        foreach ($credit in @($resetCredits.credits)) {
            $report.credits.expirations += To-LocalResetTime $credit.expiresAt
        }
    } else { $report.credits.resetCredits = 'NO_DEVUELTO' }

    Send-JsonLine $process.StandardInput @{ jsonrpc = '2.0'; method = 'account/usage/read'; id = 3 }
    $usage = Read-Response $process.StandardOutput 3
    if ($null -ne $usage.error) { throw 'account/usage/read devolvió un error.' }
    $report.usage.status = 'PASS'
    foreach ($name in @('lifetimeTokens', 'peakDailyTokens', 'longestRunningTurnSec', 'currentStreakDays', 'longestStreakDays')) {
        if ($null -ne $usage.result.summary.PSObject.Properties[$name]) {
            $report.usage.summary += [ordered]@{ metric = $name; value = $usage.result.summary.$name }
        }
    }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    foreach ($bucket in @($usage.result.dailyUsageBuckets)) {
        if ($bucket.startDate -eq $today) {
            $report.usage.todayBucket = 'TODAY_BUCKET_DISPONIBLE'
            $report.usage.today = [ordered]@{ date = $bucket.startDate; tokens = $bucket.tokens }
        }
    }

    Send-JsonLine $process.StandardInput @{ jsonrpc = '2.0'; method = 'account/rateLimits/read'; id = 4 }
    $secondRateLimits = Read-Response $process.StandardOutput 4
    $report.reuse = if ($null -eq $secondRateLimits.error) { 'REUTILIZACION_PASS' } else { 'REUTILIZACION_FAIL' }
    if ($null -eq $secondRateLimits.error) { $report.rateLimits.snapshot2 = @(Convert-RateLimitSnapshot $secondRateLimits) }
}
catch {
    $report.stoppedReason = $_.Exception.Message
}
finally {
    if ($null -ne $process) {
        try { $process.StandardInput.Close() } catch {}
        if (-not $process.WaitForExit(8000)) {
            try { $process.Kill(); $report.cleanup.forcedKill = $true; $process.WaitForExit(5000) | Out-Null } catch {}
        }
        $report.cleanup.terminated = $process.HasExited
    }
    if ($created -and (Test-Path -LiteralPath $sqliteRoot)) {
        Remove-Item -LiteralPath $sqliteRoot -Recurse -Force
        $report.sqliteIsolation.cleanup = -not (Test-Path -LiteralPath $sqliteRoot)
    }
    $report | ConvertTo-Json -Depth 12
}
