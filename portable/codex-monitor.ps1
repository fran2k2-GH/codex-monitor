[CmdletBinding()]
param()

# Local, portable prototype.  It deliberately never reads Codex credentials or its real SQLite files.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CodexMonitorNative {
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern bool DestroyIcon(IntPtr handle);
}
'@
Add-Type -ReferencedAssemblies @([Drawing.Color].Assembly.Location,[Windows.Forms.ProfessionalColorTable].Assembly.Location) @'
using System.Drawing;
using System.Windows.Forms;
public sealed class CodexMonitorColorTable : ProfessionalColorTable {
  public override Color ToolStripDropDownBackground { get { return Color.FromArgb(250, 250, 252); } }
  public override Color ImageMarginGradientBegin { get { return Color.FromArgb(250, 250, 252); } }
  public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(250, 250, 252); } }
  public override Color ImageMarginGradientEnd { get { return Color.FromArgb(250, 250, 252); } }
  public override Color MenuItemSelected { get { return Color.FromArgb(229, 239, 251); } }
  public override Color MenuItemBorder { get { return Color.FromArgb(229, 239, 251); } }
  public override Color SeparatorLight { get { return Color.FromArgb(232, 232, 235); } }
  public override Color SeparatorDark { get { return Color.FromArgb(232, 232, 235); } }
}
'@

$script:mutex = $null; $script:server = $null; $script:sqliteRoot = $null; $script:stderrTask = $null
$script:closing = $false; $script:updating = $false; $script:icons = @{}
$script:manualTimer = $null
$script:staleAfter = [TimeSpan]::FromMinutes(5)
$script:state = [ordered]@{
  fiveHour=$null; weekly=$null; gptReserve=$null; otherRateLimits=@(); credits=$null; resetCredits=$null
  usage=$null; lastAttempt=$null; lastSuccessfulRateLimitsUpdate=$null; lastSuccessfulUsageUpdate=$null
  rateLimitsError=$null; usageError=$null; runtimeError=$null
}
$script:alertState = [ordered]@{
  baselineInitialized=$false; fiveHourColor=$null; weeklyColor=$null
  fiveHourSnapshot=$null; weeklySnapshot=$null
}

function Get-OfficialRuntime {
  $bin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if (-not (Test-Path -LiteralPath $bin -PathType Container)) { return $null }
  $candidates = @(Get-ChildItem -LiteralPath $bin -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { Join-Path $_.FullName 'codex.exe' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
  foreach ($candidate in $candidates) {
    try {
      $si = [Diagnostics.ProcessStartInfo]::new($candidate, '--version'); $si.UseShellExecute=$false
      $si.RedirectStandardOutput=$true; $si.RedirectStandardError=$true; $si.CreateNoWindow=$true
      $p=[Diagnostics.Process]::Start($si); $output=$p.StandardOutput.ReadToEnd().Trim(); $null=$p.StandardError.ReadToEnd(); $p.WaitForExit(5000)|Out-Null
      if ($p.HasExited -and $p.ExitCode -eq 0 -and $output -match '^codex-cli\s') { return $candidate }
    } catch { }
  }
  return $null
}

function Get-StartupShortcutPath {
  $startup=[Environment]::GetFolderPath('Startup'); if([string]::IsNullOrWhiteSpace($startup)){return $null}; Join-Path $startup 'Codex Monitor.lnk'
}
function Get-MonitorLauncherPath { Join-Path $PSScriptRoot 'iniciar-monitor.bat' }
function Get-AutostartState {
  $path=Get-StartupShortcutPath; $launcher=Get-MonitorLauncherPath
  if($null -eq $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{Exists=$false;Valid=$false;Conflict=$false;Path=$path}}
  $shell=$null; $shortcut=$null
  try {
    $shell=New-Object -ComObject WScript.Shell; $shortcut=$shell.CreateShortcut($path); $target=[IO.Path]::GetFullPath([string]$shortcut.TargetPath); $expected=[IO.Path]::GetFullPath($launcher)
    $valid=[string]::Equals($target,$expected,[StringComparison]::OrdinalIgnoreCase)
    return [pscustomobject]@{Exists=$true;Valid=$valid;Conflict=(-not $valid);Path=$path}
  } catch { return [pscustomobject]@{Exists=$true;Valid=$false;Conflict=$true;Path=$path} }
  finally { if($null -ne $shortcut){[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)|Out-Null};if($null -ne $shell){[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)|Out-Null} }
}
function Set-Autostart([bool]$Enable) {
  $path=Get-StartupShortcutPath; $launcher=Get-MonitorLauncherPath
  if($null -eq $path){throw 'No se pudo obtener la carpeta Startup del usuario.'}
  $current=Get-AutostartState
  if($Enable){
    if(-not (Test-Path -LiteralPath $launcher -PathType Leaf)){throw 'No se encontró iniciar-monitor.bat junto al monitor.'}
    if($current.Conflict){throw 'Ya existe Codex Monitor.lnk pero apunta a un destino incompatible.'}
    $shell=$null;$shortcut=$null
    try { $shell=New-Object -ComObject WScript.Shell; $shortcut=$shell.CreateShortcut($path);$shortcut.TargetPath=$launcher;$shortcut.WorkingDirectory=(Split-Path -Parent $launcher);$shortcut.Description='Iniciar Codex Monitor';$iconPath=Join-Path $PSScriptRoot '..\assets\codex-monitor.ico';if(Test-Path -LiteralPath $iconPath -PathType Leaf){$shortcut.IconLocation=([IO.Path]::GetFullPath($iconPath)+',0')};$shortcut.Save() }
    finally {if($null -ne $shortcut){[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)|Out-Null};if($null -ne $shell){[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)|Out-Null}}
    $verify=Get-AutostartState;if(-not $verify.Valid){throw 'No se pudo verificar el acceso directo de inicio.'};return $true
  }
  if($current.Conflict){throw 'Codex Monitor.lnk existe pero no pertenece a este monitor.'}
  if($current.Exists){Remove-Item -LiteralPath $path -Force}
  if(Test-Path -LiteralPath $path){throw 'No se pudo eliminar el acceso directo de inicio.'};return $false
}
function Toggle-Autostart {
  try { $current=Get-AutostartState; if($current.Valid){Set-Autostart $false|Out-Null}else{Set-Autostart $true|Out-Null};$actual=Get-AutostartState;if(-not $actual.Valid -and $current.Valid){$message='Inicio con Windows desactivado'}elseif($actual.Valid -and -not $current.Valid){$message='Inicio con Windows activado'}else{throw 'No se pudo verificar el nuevo estado de inicio.'};try{$script:notify.ShowBalloonTip(3000,'Codex Monitor',$message,[Windows.Forms.ToolTipIcon]::Info)}catch{};Refresh-Ui }
  catch { try{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Codex Monitor',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)|Out-Null}catch{};Refresh-Ui }
}

function Send-JsonLine($Writer, [hashtable]$Message) { $Writer.WriteLine(($Message | ConvertTo-Json -Compress -Depth 20)); $Writer.Flush() }
function Read-Response($Reader, [int]$RequestId, [int]$TimeoutSeconds=25) {
  $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $task=$Reader.ReadLineAsync(); $remaining=[Math]::Max(1,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds)
    if (-not $task.Wait($remaining)) { throw 'Tiempo de espera agotado al consultar Codex.' }
    $line=$task.Result; if ($null -eq $line) { throw 'El proceso auxiliar de Codex se cerró.' }
    try { $message=$line | ConvertFrom-Json -Depth 40 } catch { continue }
    if ([string]$message.id -eq [string]$RequestId) { return $message }
  }; throw 'Tiempo de espera agotado al consultar Codex.'
}
function To-LocalTime($unix) { if ($null -eq $unix) { return $null }; try { [DateTimeOffset]::FromUnixTimeSeconds([int64]$unix).ToLocalTime() } catch { $null } }
function Get-Used($bucket) { if ($null -eq $bucket -or $null -eq $bucket.usedPercent) { return $null }; [Math]::Round([double]$bucket.usedPercent,0) }
function New-Limit($group, $slot, $kind) {
  $bucket=$group.$slot; if ($null -eq $bucket) { return $null }
  [pscustomobject]@{ kind=$kind; used=Get-Used $bucket; reset=To-LocalTime $bucket.resetsAt; readAt=Get-Date; duration=$bucket.windowDurationMins; slot=$slot; limitName=$group.limitName }
}
function Set-RateLimits($response) {
  $five=$null; $week=$null; $reserve=$null; $other=@(); $groups=@()
  if ($null -ne $response.result.rateLimitsByLimitId) { foreach($prop in $response.result.rateLimitsByLimitId.PSObject.Properties) { $groups += [pscustomobject]@{key=$prop.Name; value=$prop.Value} } }
  elseif ($null -ne $response.result.rateLimits) { $groups += [pscustomobject]@{key='legacy'; value=$response.result.rateLimits} }
  foreach($entry in $groups) {
    $g=$entry.value; $isReserve=([string]$g.limitName -eq 'gpt-reserve')
    foreach($slot in @('primary','secondary')) {
      $b=$g.$slot; if ($null -eq $b) { continue }; $limit=New-Limit $g $slot 'other'
      if ($isReserve -and $slot -eq 'primary') { $limit.kind='gptReserve'; $reserve=$limit }
      elseif (([string]$g.limitId -eq 'codex' -or [string]$entry.key -eq 'codex') -and $slot -eq 'primary' -and [int]$b.windowDurationMins -eq 300) { $limit.kind='fiveHour'; $five=$limit }
      elseif (([string]$g.limitId -eq 'codex' -or [string]$entry.key -eq 'codex') -and $slot -eq 'secondary' -and [int]$b.windowDurationMins -eq 10080) { $limit.kind='weekly'; $week=$limit }
      else { $other += $limit }
    }
  }
  # A group can omit limitId but still explicitly identify itself as Codex.
  if ($null -eq $five -or $null -eq $week) { foreach($entry in $groups) { if ([string]$entry.value.limitName -ne 'codex') { continue }; foreach($slot in @('primary','secondary')) { $b=$entry.value.$slot; if($null -eq $b){continue}; if($slot -eq 'primary' -and [int]$b.windowDurationMins -eq 300){$five=New-Limit $entry.value $slot 'fiveHour'}; if($slot -eq 'secondary' -and [int]$b.windowDurationMins -eq 10080){$week=New-Limit $entry.value $slot 'weekly'} } } }
  $script:state.fiveHour=$five; $script:state.weekly=$week; $script:state.gptReserve=$reserve; $script:state.otherRateLimits=@($other)
  $credits=$null; foreach($entry in $groups) { if($null -ne $entry.value.credits) {$credits=$entry.value.credits; break} }; $script:state.credits=$credits
  $script:state.resetCredits=$response.result.rateLimitResetCredits
}
function Start-Server {
  if ($null -ne $script:server -and -not $script:server.HasExited) { return $true }
  Stop-Server
  $runtime=Get-OfficialRuntime; if($null -eq $runtime) { throw 'No se encontró un runtime oficial de Codex Desktop válido.' }
  $script:sqliteRoot=Join-Path ([IO.Path]::GetTempPath()) ('codex-monitor-sqlite-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $script:sqliteRoot | Out-Null
  $si=[Diagnostics.ProcessStartInfo]::new($runtime,'app-server --listen stdio://'); $si.UseShellExecute=$false; $si.RedirectStandardInput=$true; $si.RedirectStandardOutput=$true; $si.RedirectStandardError=$true; $si.CreateNoWindow=$true
  if ($null -ne $si.PSObject.Properties['Environment']) { $si.Environment['CODEX_SQLITE_HOME']=$script:sqliteRoot } else { $si.EnvironmentVariables['CODEX_SQLITE_HOME']=$script:sqliteRoot }
  $script:server=[Diagnostics.Process]::new(); $script:server.StartInfo=$si; if(-not $script:server.Start()){throw 'No se pudo iniciar el proceso auxiliar de Codex.'}
  # Drain stderr without persisting it, so a noisy child cannot block on a full pipe.
  $script:stderrTask=$script:server.StandardError.ReadToEndAsync()
  Send-JsonLine $script:server.StandardInput @{jsonrpc='2.0';method='initialize';id=1;params=@{clientInfo=@{name='codex-monitor';title='Codex Monitor';version='1'}}}
  $init=Read-Response $script:server.StandardOutput 1; if($null -ne $init.error){throw 'initialize devolvió un error.'}; Send-JsonLine $script:server.StandardInput @{jsonrpc='2.0';method='initialized'}
  return $true
}
function Stop-Server {
  $p=$script:server; $script:server=$null
  if($null -ne $p) { try{$p.StandardInput.Close()}catch{}; try{if(-not $p.WaitForExit(5000)){ $p.Kill(); $p.WaitForExit(3000)|Out-Null }}catch{}; try{$p.Dispose()}catch{} }; $script:stderrTask=$null
  if($null -ne $script:sqliteRoot) { $path=$script:sqliteRoot; $script:sqliteRoot=$null; try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{} }
}
function Get-Remaining($limit) {
  if($null -eq $limit -or $null -eq $limit.used){return $null}
  try { $remaining=100-[double]$limit.used; if($remaining -lt 0 -or $remaining -gt 100){return $null}; return [Math]::Round($remaining,0) } catch { return $null }
}
function Get-ColorName($limit) {
  $remaining=Get-Remaining $limit; if($null -eq $remaining){return 'gray'}
  if($remaining -gt 50){return 'green'}; if($remaining -gt 20){return 'yellow'}; 'red'
}
function Test-AlertTransition($kind, $previous, $current) {
  if($null -eq $previous -or $current -notin @('green','yellow','red')){return $false}
  if($kind -eq 'weekly'){return ($previous -eq 'green' -and $current -in @('yellow','red')) -or ($previous -eq 'yellow' -and $current -eq 'red')}
  return $previous -in @('green','yellow') -and $current -eq 'red'
}
function Get-HistoryLimitRecord($current, $previous) {
  $remaining=Get-Remaining $current; if($null -eq $remaining){return $null}
  $record=[ordered]@{}
  if($null -ne $previous -and $null -ne (Get-Remaining $previous)){$record.previousRemainingPercent=Get-Remaining $previous;$record.previousLevel=Get-ColorName $previous}
  $record.remainingPercent=$remaining; if($null -ne $current.used){$record.usedPercent=$current.used}; $record.level=Get-ColorName $current
  if($null -ne $current.reset){$record.resetAt=$current.reset.ToUniversalTime().ToString('o')}; if($null -ne $current.duration){$record.durationMinutes=$current.duration}; if($null -ne $current.slot){$record.slot=[string]$current.slot}
  [pscustomobject]$record
}
function Get-HistoryReserveRecord($limit) {
  $remaining=Get-Remaining $limit; if($null -eq $remaining){return $null}; $record=[ordered]@{remainingPercent=$remaining}
  if($null -ne $limit.used){$record.usedPercent=$limit.used}; if($null -ne $limit.reset){$record.resetAt=$limit.reset.ToUniversalTime().ToString('o')}; if($null -ne $limit.duration){$record.durationMinutes=$limit.duration}; [pscustomobject]$record
}
function Get-HistoryCreditsRecord($credits, $resetCredits) {
  if($null -eq $credits -and $null -eq $resetCredits){return $null}; $record=[ordered]@{}
  if($null -ne $credits){foreach($name in @('balance','hasCredits','unlimited')){if($null -ne $credits.PSObject.Properties[$name] -and $null -ne $credits.$name){$record[$name]=$credits.$name}}}
  if($null -ne $resetCredits){$reset=[ordered]@{};if($null -ne $resetCredits.PSObject.Properties['availableCount'] -and $null -ne $resetCredits.availableCount){$reset.availableCount=$resetCredits.availableCount};if($reset.Count){$record.resetCredits=[pscustomobject]$reset};$expirations=@($resetCredits.credits|ForEach-Object{if($null -ne $_.expiresAt){To-LocalTime $_.expiresAt}}|Where-Object{$_}|Sort-Object);if($expirations.Count){$record.expiration=$expirations[0].ToUniversalTime().ToString('o')}}
  if($record.Count -eq 0){return $null}; [pscustomobject]$record
}
function New-UsageHistoryEvent($eventType, $changedLimits, $updateSource, $fiveHour, $previousFiveHour, $weekly, $previousWeekly) {
  $event=[ordered]@{schemaVersion=1;observedAt=[DateTime]::UtcNow.ToString('o');updateSource=$updateSource;eventType=$eventType;changedLimits=@($changedLimits)}
  $fiveRecord=Get-HistoryLimitRecord $fiveHour $previousFiveHour; if($null -ne $fiveRecord){$event.fiveHour=$fiveRecord};$weeklyRecord=Get-HistoryLimitRecord $weekly $previousWeekly;if($null -ne $weeklyRecord){$event.weekly=$weeklyRecord}
  $reserveRecord=Get-HistoryReserveRecord $script:state.gptReserve;if($null -ne $reserveRecord){$event.gptReserve=$reserveRecord};$creditsRecord=Get-HistoryCreditsRecord $script:state.credits $script:state.resetCredits;if($null -ne $creditsRecord){$event.credits=$creditsRecord}; [pscustomobject]$event
}
function Get-UsageHistoryPath {
  $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData); if([string]::IsNullOrWhiteSpace($local)){return $null}; Join-Path (Join-Path $local 'CodexMonitor') 'logs\usage-history.jsonl'
}
function Test-UsageHistoryExists($path) {
  if([string]::IsNullOrWhiteSpace($path)){return $false}; try { Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop } catch { $false }
}
function Get-HistoryProperty($Object, [string]$Name) {
  if($null -eq $Object){return $null}; $property=$Object.PSObject.Properties[$Name]; if($null -eq $property){return $null}; $property.Value
}
function Format-HistoryPercent($Value) {
  if($null -eq $Value){return $null}; try{$number=[double]$Value}catch{return $null}; if([double]::IsNaN($number) -or [double]::IsInfinity($number)){return $null}; if([Math]::Truncate($number) -eq $number){return ('{0:0}%' -f $number)}; '{0:0.##}%' -f $number
}
function Format-HistoryDate($Value, [bool]$WithSeconds=$true) {
  if($null -eq $Value){return $null}; try{if($Value -is [DateTimeOffset]){$date=$Value.ToLocalTime()}elseif($Value -is [DateTime]){if($Value.Kind -eq [DateTimeKind]::Utc){$date=[DateTimeOffset]::new($Value,[TimeSpan]::Zero).ToLocalTime()}else{$date=[DateTimeOffset]::new($Value).ToLocalTime()}}else{$date=[DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()};$format=if($WithSeconds){'dd/MM/yyyy HH:mm:ss'}else{'dd/MM/yyyy HH:mm'};$date.ToString($format,[Globalization.CultureInfo]::CurrentCulture)}catch{$null}
}
function Get-HistoryEventLabel($Value) {
  $labels=@{baseline='Inicio';percentage_change='Cambio';reset_or_increase='Reset / aumento'};$key=[string]$Value; if($labels.ContainsKey($key)){return $labels[$key]}; if([string]::IsNullOrWhiteSpace($key)){return 'Evento'}; $key
}
function Get-HistoryOriginLabel($Value) {
  $labels=@{automatic='automático';manual='manual'};$key=[string]$Value; if($labels.ContainsKey($key)){return $labels[$key]}; if([string]::IsNullOrWhiteSpace($key)){return $null}; $key
}
function Get-HistoryLimitLabel($Value) {
  $labels=@{fiveHour='5 horas';weekly='Semana'};$key=[string]$Value; if($labels.ContainsKey($key)){return $labels[$key]}; if([string]::IsNullOrWhiteSpace($key)){return $null}; $key
}
function Get-HistoryLevelLabel($Value) {
  $labels=@{green='verde';yellow='amarillo';red='rojo';gray='gris'};$key=[string]$Value; if($labels.ContainsKey($key)){return $labels[$key]}; if([string]::IsNullOrWhiteSpace($key)){return $null}; $key
}
function Format-HistoryDuration($Value) {
  if($null -eq $Value){return $null}; try{$minutes=[int]$Value}catch{return $null}; if($minutes -le 0){return $null}; if($minutes % 1440 -eq 0){return ('{0} d' -f ($minutes/1440))}; if($minutes % 60 -eq 0){return ('{0} h' -f ($minutes/60))}; '{0} min' -f $minutes
}
function Get-HistoryChangedLimits($Event) {
  $changed=Get-HistoryProperty $Event 'changedLimits'; if($null -eq $changed){return @()}; @($changed|ForEach-Object{[string]$_})
}
function Add-HistoryLimitSection([Collections.Generic.List[string]]$Lines, [string]$Title, $Record, [bool]$ShowChange) {
  if($null -eq $Record){return}; $section=[Collections.Generic.List[string]]::new();$section.Add($Title)
  $current=Format-HistoryPercent (Get-HistoryProperty $Record 'remainingPercent');$previous=Format-HistoryPercent (Get-HistoryProperty $Record 'previousRemainingPercent')
  if($null -ne $current){if($ShowChange -and $null -ne $previous){$section.Add(('  Restante: {0} -> {1}' -f $previous,$current))}else{$section.Add(('  Restante: '+$current))}}
  $used=Format-HistoryPercent (Get-HistoryProperty $Record 'usedPercent');if($null -ne $used){$section.Add(('  Usado:    '+$used))};$level=Get-HistoryLevelLabel (Get-HistoryProperty $Record 'level');if($null -ne $level){$section.Add(('  Nivel:    '+$level))};$reset=Format-HistoryDate (Get-HistoryProperty $Record 'resetAt') $false;if($null -ne $reset){$section.Add(('  Reset:    '+$reset))};$duration=Format-HistoryDuration (Get-HistoryProperty $Record 'durationMinutes');if($null -ne $duration){$section.Add(('  Ventana:  '+$duration))}
  if($section.Count -gt 1){foreach($line in $section){$Lines.Add($line)};$Lines.Add('')}
}
function Add-HistoryCreditsSection([Collections.Generic.List[string]]$Lines, $Credits) {
  if($null -eq $Credits){return};$section=[Collections.Generic.List[string]]::new();$section.Add('Créditos');$balance=Get-HistoryProperty $Credits 'balance';if($null -ne $balance -and -not [string]::IsNullOrWhiteSpace([string]$balance)){$section.Add(('  Saldo: '+[string]$balance))};$hasCredits=Get-HistoryProperty $Credits 'hasCredits';if($hasCredits -is [bool]){if($hasCredits){$section.Add('  Tiene créditos: sí')}elseif($null -eq $balance){$section.Add('  Tiene créditos: no')}};$unlimited=Get-HistoryProperty $Credits 'unlimited';if($unlimited -is [bool] -and $unlimited){$section.Add('  Sin límite')};$resetCredits=Get-HistoryProperty $Credits 'resetCredits';$available=Format-HistoryPercent (Get-HistoryProperty $resetCredits 'availableCount');if($null -ne $available){$section.Add(('  Reset disponibles: '+$available.TrimEnd('%')))};$expiration=Format-HistoryDate (Get-HistoryProperty $Credits 'expiration') $false;if($null -ne $expiration){$section.Add(('  Expiración: '+$expiration))};if($section.Count -gt 1){foreach($line in $section){$Lines.Add($line)};$Lines.Add('')}
}
function Format-HistoryEvent($Event) {
  $lines=[Collections.Generic.List[string]]::new();$observed=Format-HistoryDate (Get-HistoryProperty $Event 'observedAt');$eventLabel=Get-HistoryEventLabel (Get-HistoryProperty $Event 'eventType');$heading=if($null -ne $observed){'{0} · {1}' -f $observed,$eventLabel}else{$eventLabel};$lines.Add($heading);$origin=Get-HistoryOriginLabel (Get-HistoryProperty $Event 'updateSource');if($null -ne $origin){$lines.Add(('Origen: '+$origin))};$lines.Add('')
  $changed=Get-HistoryChangedLimits $Event;$showFive=$changed -contains 'fiveHour';$showWeekly=$changed -contains 'weekly';Add-HistoryLimitSection $lines '5 horas' (Get-HistoryProperty $Event 'fiveHour') ($showFive);Add-HistoryLimitSection $lines 'Semana' (Get-HistoryProperty $Event 'weekly') ($showWeekly);Add-HistoryLimitSection $lines 'GPT Reserve' (Get-HistoryProperty $Event 'gptReserve') $false;Add-HistoryCreditsSection $lines (Get-HistoryProperty $Event 'credits')
  if($changed.Count -gt 0){$labels=@($changed|ForEach-Object{Get-HistoryLimitLabel $_}|Where-Object{$_});if($labels.Count -gt 0){$lines.Add('Cambio detectado:');$lines.Add(('  '+($labels -join ', ')));$lines.Add('')}}
  while($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count-1])){$lines.RemoveAt($lines.Count-1)}; $lines.ToArray()
}
function New-UsageHistoryView($SourcePath, $ViewPath) {
  $directory=Split-Path -Parent $ViewPath;if(-not (Test-Path -LiteralPath $directory -PathType Container)){New-Item -ItemType Directory -Path $directory -Force|Out-Null};$staging=Join-Path $directory ('usage-history-view-'+[guid]::NewGuid().ToString('N')+'.tmp');$writer=$null
  try {
    $writer=[IO.StreamWriter]::new($staging,$false,[Text.UTF8Encoding]::new($false));$writer.WriteLine('Codex Monitor - Histórico de consumo');$writer.WriteLine('Fuente: usage-history.jsonl');$writer.WriteLine(('Generado: '+(Get-Date).ToString('dd/MM/yyyy HH:mm:ss')));$writer.WriteLine('');$separator='------------------------------------------------------------';$writer.WriteLine($separator);$first=$true
    foreach($line in [IO.File]::ReadLines($SourcePath,[Text.Encoding]::UTF8)){
      if([string]::IsNullOrWhiteSpace($line)){continue}
      try{$event=$line|ConvertFrom-Json;if($null -eq $event){throw 'Registro vacío'};$eventLines=@(Format-HistoryEvent $event);if(-not $first){$writer.WriteLine('');$writer.WriteLine($separator)};foreach($eventLine in $eventLines){$writer.WriteLine($eventLine)};$first=$false}
      catch{$writer.WriteLine('');$writer.WriteLine('[Registro no interpretable omitido]');$first=$false}
    }
    $writer.Flush();$writer.Dispose();$writer=$null;Move-Item -LiteralPath $staging -Destination $ViewPath -Force
  } catch { if($null -ne $writer){try{$writer.Dispose()}catch{}};if(Test-Path -LiteralPath $staging -PathType Leaf){try{Remove-Item -LiteralPath $staging -Force}catch{}};throw }
}
function Open-UsageHistory {
  $path=Get-UsageHistoryPath
  if(-not (Test-UsageHistoryExists $path)) { try{[Windows.Forms.MessageBox]::Show('Todavía no hay histórico disponible.','Codex Monitor',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)|Out-Null}catch{};return }
  $viewPath=Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'CodexMonitor') 'usage-history-view.txt'
  try { New-UsageHistoryView $path $viewPath } catch { try{[Windows.Forms.MessageBox]::Show('No se pudo abrir el histórico de consumo.','Codex Monitor',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)|Out-Null}catch{};return }
  try { Start-Process -FilePath $viewPath -ErrorAction Stop }
  catch { try { Start-Process -FilePath 'notepad.exe' -ArgumentList @($viewPath) -ErrorAction Stop } catch { try{[Windows.Forms.MessageBox]::Show('No se pudo abrir el histórico de consumo.','Codex Monitor',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)|Out-Null}catch{} } }
}
function Write-UsageHistory($event) {
  try {$path=Get-UsageHistoryPath;if($null -eq $path){return};$directory=Split-Path -Parent $path;if(-not (Test-Path -LiteralPath $directory -PathType Container)){New-Item -ItemType Directory -Path $directory -Force|Out-Null};$json=$event|ConvertTo-Json -Compress -Depth 8;[IO.File]::AppendAllText($path,$json+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))}catch{}
}
function Update-RateLimitAlerts([bool]$ResetBaseline, [string]$UpdateSource='automatic') {
  $fiveHour=$script:state.fiveHour;$weekly=$script:state.weekly;$fiveRemaining=Get-Remaining $fiveHour;$weeklyRemaining=Get-Remaining $weekly;$currentValid=$null -ne $fiveRemaining -and $null -ne $weeklyRemaining
  $previousReady=$script:alertState.baselineInitialized -and $null -ne $script:alertState.fiveHourSnapshot -and $null -ne $script:alertState.weeklySnapshot;$previousFive=if($previousReady){$script:alertState.fiveHourSnapshot}else{$null};$previousWeekly=if($previousReady){$script:alertState.weeklySnapshot}else{$null};$alerts=@();$historyEvent=$null
  if($currentValid){
    $fiveChanged=$previousReady -and -not $ResetBaseline -and $fiveRemaining -ne (Get-Remaining $previousFive);$weeklyChanged=$previousReady -and -not $ResetBaseline -and $weeklyRemaining -ne (Get-Remaining $previousWeekly);$changed=@();if($fiveChanged){$changed+='fiveHour'};if($weeklyChanged){$changed+='weekly'}
    if($previousReady -and -not $ResetBaseline){if($changed.Count){$increased=($fiveChanged -and $fiveRemaining -gt (Get-Remaining $previousFive)) -or ($weeklyChanged -and $weeklyRemaining -gt (Get-Remaining $previousWeekly));$eventType=if($increased){'reset_or_increase'}else{'percentage_change'};$historyEvent=New-UsageHistoryEvent $eventType $changed $UpdateSource $fiveHour $previousFive $weekly $previousWeekly}}
    else {$historyEvent=New-UsageHistoryEvent 'baseline' @() $UpdateSource $fiveHour $null $weekly $null}
    if($null -ne $historyEvent){Write-UsageHistory $historyEvent}
    $canAlert=$previousReady -and -not $ResetBaseline
    if($canAlert){$fiveColor=Get-ColorName $fiveHour;$weeklyColor=Get-ColorName $weekly;if(Test-AlertTransition 'fiveHour' $script:alertState.fiveHourColor $fiveColor){$alerts += [pscustomobject]@{kind='fiveHour';text=("5 horas: {0}% restante" -f $fiveRemaining)}};if(Test-AlertTransition 'weekly' $script:alertState.weeklyColor $weeklyColor){$alerts += [pscustomobject]@{kind='weekly';text=("Semana: {0}% restante" -f $weeklyRemaining)}}}
    $script:alertState.fiveHourColor=Get-ColorName $fiveHour;$script:alertState.weeklyColor=Get-ColorName $weekly;$script:alertState.fiveHourSnapshot=$fiveHour;$script:alertState.weeklySnapshot=$weekly;$script:alertState.baselineInitialized=$true
  } else {$script:alertState.baselineInitialized=$false;$script:alertState.fiveHourColor=$null;$script:alertState.weeklyColor=$null;$script:alertState.fiveHourSnapshot=$null;$script:alertState.weeklySnapshot=$null}
  [pscustomobject]@{alerts=@($alerts);historyEvent=$historyEvent}
}
function Is-Stale { $t=$script:state.lastSuccessfulRateLimitsUpdate; return $null -eq $t -or ((Get-Date)-$t -gt $script:staleAfter) }
function New-StatusIcon($top,$bottom) {
  $colors=@{green=[Drawing.Color]::FromArgb(46,160,67);yellow=[Drawing.Color]::FromArgb(220,170,0);red=[Drawing.Color]::FromArgb(210,55,45);gray=[Drawing.Color]::FromArgb(125,125,125)}
  $bmp=[Drawing.Bitmap]::new(16,16); $g=[Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::Transparent)
  $g.FillRectangle([Drawing.SolidBrush]::new($colors[$top]),1,1,14,6); $g.FillRectangle([Drawing.SolidBrush]::new($colors[$bottom]),1,9,14,6)
  $pen=[Drawing.Pen]::new([Drawing.Color]::FromArgb(60,60,60)); $g.DrawRectangle($pen,1,1,13,13); $g.DrawLine($pen,1,8,14,8); $pen.Dispose(); $g.Dispose()
  $h=$bmp.GetHicon(); $temp=[Drawing.Icon]::FromHandle($h); $icon=[Drawing.Icon]$temp.Clone(); $temp.Dispose(); [CodexMonitorNative]::DestroyIcon($h)|Out-Null; $bmp.Dispose(); return $icon
}
function Get-Icon($top,$bottom) { $key="$top/$bottom"; if(-not $script:icons.ContainsKey($key)){$script:icons[$key]=New-StatusIcon $top $bottom}; $script:icons[$key] }
function Format-Limit($item) {
  if($null -eq $item){return @('No disponible')}
  $remaining=Get-Remaining $item
  $remainingText=if($null -ne $remaining){"$remaining % restante"}else{'Restante: --'}
  $reset=if($null -ne $item.reset){$item.reset.ToString('g')}else{'--'}
  @($remainingText,"Reset $reset")
}
function Add-MenuLabel($text, $font, $padding) {
  $item=[Windows.Forms.ToolStripLabel]::new($text); $item.Font=$font; $item.ForeColor=[Drawing.Color]::FromArgb(45,45,48); $item.Padding=$padding; $item.Margin=[Windows.Forms.Padding]::Empty; $null=$script:menu.Items.Add($item); return $item
}
function Add-MenuSeparator {
  $separator=[Windows.Forms.ToolStripSeparator]::new(); $separator.Margin=[Windows.Forms.Padding]::new(10,6,10,6); $null=$script:menu.Items.Add($separator)
}
function Add-LimitBlock($title,$item) {
  Add-MenuLabel $title $script:menuHeaderFont ([Windows.Forms.Padding]::new(12,8,12,1)) | Out-Null
  foreach($line in (Format-Limit $item)){ Add-MenuLabel $line $script:menuDetailFont ([Windows.Forms.Padding]::new(18,2,12,2)) | Out-Null }
}
function Refresh-Ui {
  $stale=Is-Stale; $top=if($stale){'gray'}else{Get-ColorName $script:state.fiveHour}; $bottom=if($stale){'gray'}else{Get-ColorName $script:state.weekly}
  $script:notify.Icon=Get-Icon $top $bottom; $a=Get-Remaining $script:state.fiveHour; if($null -eq $a){$a='--'}else{$a="$a%"}; $b=Get-Remaining $script:state.weekly; if($null -eq $b){$b='--'}else{$b="$b%"}; $when=if($null -ne $script:state.lastSuccessfulRateLimitsUpdate){$script:state.lastSuccessfulRateLimitsUpdate.ToString('HH:mm')}else{'--'}; $tooltip="Codex · 5h $a · Sem $b | Act. $when"; $script:notify.Text=$tooltip.Substring(0,[Math]::Min(63,$tooltip.Length))
  $menu=$script:menu; $menu.Items.Clear(); Add-MenuLabel 'Codex Monitor' $script:menuTitleFont ([Windows.Forms.Padding]::new(12,9,12,7)) | Out-Null; Add-MenuSeparator
  Add-LimitBlock '5 horas' $script:state.fiveHour; Add-MenuSeparator; Add-LimitBlock 'Semana' $script:state.weekly
  if($null -ne $script:state.gptReserve){Add-MenuSeparator; Add-LimitBlock 'GPT Reserve' $script:state.gptReserve}
  if($null -ne $script:state.credits -or $null -ne $script:state.resetCredits){Add-MenuSeparator; Add-MenuLabel 'Créditos' $script:menuHeaderFont ([Windows.Forms.Padding]::new(12,8,12,1)) | Out-Null;if($null -ne $script:state.credits -and $null -ne $script:state.credits.balance){Add-MenuLabel "Saldo créditos: $($script:state.credits.balance)" $script:menuDetailFont ([Windows.Forms.Padding]::new(18,2,12,2)) | Out-Null};if($null -ne $script:state.resetCredits){Add-MenuLabel "Reset credits: $($script:state.resetCredits.availableCount)" $script:menuDetailFont ([Windows.Forms.Padding]::new(18,2,12,2)) | Out-Null;$dates=@($script:state.resetCredits.credits|ForEach-Object{To-LocalTime $_.expiresAt}|Where-Object{$_});if($dates.Count){Add-MenuLabel ('Expira: '+(($dates|Sort-Object|Select-Object -First 1).ToString('g'))) $script:menuDetailFont ([Windows.Forms.Padding]::new(18,2,12,2)) | Out-Null}}}
  Add-MenuSeparator; $status=if($stale){'Datos desactualizados'}elseif($null -ne $script:state.lastSuccessfulRateLimitsUpdate){'Actualizado: '+$script:state.lastSuccessfulRateLimitsUpdate.ToString('T')}else{'Sin datos actuales'}; Add-MenuLabel $status $script:menuDetailFont ([Windows.Forms.Padding]::new(12,3,12,3)) | Out-Null
  if($script:state.rateLimitsError){Add-MenuLabel ('Error: '+$script:state.rateLimitsError) $script:menuDetailFont ([Windows.Forms.Padding]::new(12,3,12,3)) | Out-Null};Add-MenuSeparator;$historyPath=Get-UsageHistoryPath;$history=$menu.Items.Add('Ver histórico');$history.Padding=[Windows.Forms.Padding]::new(12,5,12,5);$history.Enabled=Test-UsageHistoryExists $historyPath;$history.Add_Click({Open-UsageHistory});$autostartState=Get-AutostartState;$autostartText=if($autostartState.Valid){'Inicio con Windows activado'}else{'Activar inicio con Windows'};$autostart=$menu.Items.Add($autostartText);$autostart.Checked=$autostartState.Valid;$autostart.CheckOnClick=$false;$autostart.Padding=[Windows.Forms.Padding]::new(12,5,12,5);$autostart.Add_Click({Toggle-Autostart});$refresh=$menu.Items.Add('Actualizar ahora');$refresh.Padding=[Windows.Forms.Padding]::new(12,7,12,7);$refresh.Enabled=-not $script:updating;$refresh.Add_Click({Start-ManualUpdate});$exit=$menu.Items.Add('Salir');$exit.Padding=[Windows.Forms.Padding]::new(12,7,12,9);$exit.Add_Click({Close-Monitor})
}
function Invoke-Update([ValidateSet('automatic','manual')][string]$UpdateSource='automatic') {
  if($script:closing -or $script:updating){return $false}; $script:updating=$true; $script:state.lastAttempt=Get-Date; $rateOk=$false; $alerts=@(); $staleBeforeRead=Is-Stale
  try { Start-Server|Out-Null; Send-JsonLine $script:server.StandardInput @{jsonrpc='2.0';method='account/rateLimits/read';id=2}; $r=Read-Response $script:server.StandardOutput 2; if($null -ne $r.error){throw 'La lectura de límites devolvió un error.'}; Set-RateLimits $r; $processed=Update-RateLimitAlerts $staleBeforeRead $UpdateSource; $alerts=@($processed.alerts); $script:state.lastSuccessfulRateLimitsUpdate=Get-Date; $script:state.rateLimitsError=$null; $rateOk=$true }
  catch { $script:alertState.baselineInitialized=$false; $script:alertState.fiveHourColor=$null; $script:alertState.weeklyColor=$null; $script:alertState.fiveHourSnapshot=$null; $script:alertState.weeklySnapshot=$null; $script:state.rateLimitsError=$_.Exception.Message; Stop-Server }
  try { if($null -ne $script:server -and -not $script:server.HasExited){Send-JsonLine $script:server.StandardInput @{jsonrpc='2.0';method='account/usage/read';id=3};$u=Read-Response $script:server.StandardOutput 3;if($null -ne $u.error){throw 'La lectura de uso devolvió un error.'};$script:state.usage=$u.result;$script:state.lastSuccessfulUsageUpdate=Get-Date;$script:state.usageError=$null} } catch {$script:state.usageError=$_.Exception.Message}
  $script:updating=$false; Refresh-Ui; if($alerts.Count -gt 0){try{$script:notify.ShowBalloonTip(3000,'Codex Monitor',(($alerts|ForEach-Object{$_.text}) -join ' · '),[Windows.Forms.ToolTipIcon]::Info)}catch{}}; return $rateOk
}
function Start-ManualUpdate {
  if($script:closing -or $script:updating -or ($null -ne $script:manualTimer -and $script:manualTimer.Enabled)){return}; $script:notify.Icon=Get-Icon 'gray' 'gray'; $script:notify.Text='Codex · Actualizando...'; $script:manualTimer.Start()
}
function Complete-ManualUpdate {
  if($script:closing){return}; $ok=Invoke-Update 'manual'; if(-not $ok){try{$script:notify.ShowBalloonTip(3000,'Codex Monitor','No se pudo actualizar',[Windows.Forms.ToolTipIcon]::Warning)}catch{}}
}
function Close-Monitor { if($script:closing){return};$script:closing=$true;try{$script:timer.Stop();$script:timer.Dispose();$script:manualTimer.Stop();$script:manualTimer.Dispose()}catch{};Stop-Server;try{$script:notify.Visible=$false;$script:notify.Dispose()}catch{};foreach($icon in $script:icons.Values){$icon.Dispose()};try{$script:menuTitleFont.Dispose();$script:menuHeaderFont.Dispose();$script:menuDetailFont.Dispose()}catch{};try{$script:mutex.ReleaseMutex()}catch{};try{$script:mutex.Dispose()}catch{};[Windows.Forms.Application]::Exit() }

$created=$false; $script:mutex=[Threading.Mutex]::new($true,'Local\CodexMonitor',[ref]$created); if(-not $created){try{[Windows.Forms.MessageBox]::Show('Codex Monitor ya está en ejecución.','Codex Monitor',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)|Out-Null}catch{};try{$script:mutex.Dispose()}catch{};exit 0}
$script:menuTitleFont=[Drawing.Font]::new('Segoe UI',10,[Drawing.FontStyle]::Bold);$script:menuHeaderFont=[Drawing.Font]::new('Segoe UI',9,[Drawing.FontStyle]::Bold);$script:menuDetailFont=[Drawing.Font]::new('Segoe UI',9,[Drawing.FontStyle]::Regular)
$script:menu=[Windows.Forms.ContextMenuStrip]::new();$script:menu.RenderMode=[Windows.Forms.ToolStripRenderMode]::Professional;$script:menu.Renderer=[Windows.Forms.ToolStripProfessionalRenderer]::new([CodexMonitorColorTable]::new());$script:menu.ShowImageMargin=$false;$script:menu.ShowCheckMargin=$true;$script:menu.MinimumSize=[Drawing.Size]::new(250,0);$script:notify=[Windows.Forms.NotifyIcon]::new();$script:notify.ContextMenuStrip=$script:menu;$script:notify.Visible=$true
$script:timer=[Windows.Forms.Timer]::new();$script:timer.Interval=60000;$script:timer.Add_Tick({Invoke-Update 'automatic';Refresh-Ui})
$script:manualTimer=[Windows.Forms.Timer]::new();$script:manualTimer.Interval=1;$script:manualTimer.Add_Tick({$script:manualTimer.Stop();Complete-ManualUpdate})
Refresh-Ui; Invoke-Update 'automatic'; $script:timer.Start(); [Windows.Forms.Application]::Run()
