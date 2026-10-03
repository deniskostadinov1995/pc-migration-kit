<#
  PC Migration Kit - MEDIA SERVER + SMART HOME
  --------------------------------------------
  Checks, and on request repairs, the media server and smart home on this PC:
  qBittorrent, Radarr, Radarr 4K, Sonarr, Jackett, Prowlarr, Jellyfin, Caddy +
  DuckDNS, Docker (Seerr, Jellystat) and the Home Assistant VM.

  A repair installs what is missing (winget), puts data back from the newest
  backup, registers each part the way it ran before and starts it. Parts that
  work are left alone, so it is safe to run any time.

  -Mode    Menu (default) | Check | Repair
  -Only    limit a repair to these parts, e.g. -Only jellyfin,prowlarr
  -Force   set these parts up again even if they look fine
  -DryRun  show what a repair would do, change nothing

  Written by Claude 2026-09-29.
#>
param(
  [ValidateSet('Menu', 'Check', 'Repair')][string]$Mode = 'Menu',
  [string]$BackupPath,
  [string[]]$Only,
  [string[]]$Force,
  [switch]$DryRun,
  [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'MediaServer.ps1')
Set-ConsoleUtf8
$KitRoot = Split-Path $PSScriptRoot -Parent
if ($script:Gui) { $NoPause = $true; if ($Mode -eq 'Menu') { $Mode = 'Check' } }
# with -File, "-Only jellyfin,seerr" arrives as one string
$Only = @($Only | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Force = @($Force | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

Show-Banner 'MEDIA SERVER + SMART HOME' 'Checks and repairs Jellyfin, the *arr apps, Seerr, Jellystat and Home Assistant.'
if ($DryRun) { Say '  DRY RUN - nothing will be changed.' 'Yellow' }

# the newest backup is where a repair takes data from (a check does not need one)
$script:B = $null
if ($BackupPath) { $script:B = (Resolve-Path -LiteralPath $BackupPath).Path }
elseif (Test-Path -LiteralPath (Join-Path $KitRoot 'manifest.json')) { $script:B = $KitRoot }
else {
  $cand = @(Get-ChildItem -LiteralPath (Join-Path $KitRoot 'Backups') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending) | Select-Object -First 1
  if ($cand) { $script:B = $cand.FullName }
}
$script:M = $null
if ($script:B) {
  $script:M = Read-Json (Join-Path $script:B 'manifest.json')
  $script:MsFacts = Read-Json (Join-Path $script:B 'settings\mediaserver\mediaserver.json')
  Say ('  Backup used for repairs: {0}' -f $script:B) 'White'
  if (-not $script:MsFacts) { Say-Info 'That backup is older than this feature, so built-in settings are used. Run BACKUP again (U = update) to capture everything.' }
} else { Say-Warn 'No backup found next to the kit - a repair can install and start things, but cannot put data back.' }
$script:NewProfile = $env:USERPROFILE
$script:OldProfile = $env:USERPROFILE
if ($script:M -and $script:M.System -and $script:M.System.UserProfile) { $script:OldProfile = [string]$script:M.System.UserProfile }

$admin = Test-IsAdmin
if ($Mode -eq 'Repair' -and -not $admin -and -not $DryRun) {
  Say-Fail 'A repair needs administrator rights - start it with "4 - MEDIA SERVER (check or repair).bat".'
  Exit-Kit 1 -NoPause:$NoPause
}
if ($Mode -ne 'Check' -and -not $DryRun) { Start-KitLog (Join-Path $env:ProgramData ('PCMigrationKit\server-{0}\server.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))) }

function Show-MsSummary($States) {
  $bad = @($States | Where-Object { $_.Status -ne 'OK' })
  if (-not $bad.Count) { Say ('  Everything is running ({0} parts checked).' -f @($States).Count) 'Green' }
  else { Say ('  {0} of {1} parts need attention.' -f $bad.Count, @($States).Count) 'Yellow' }
}

if ($Mode -eq 'Check') {
  Say-Step 'Checking'
  $st = @(Test-MsAll)
  Show-MsTable $st
  Show-MsSummary $st
  Exit-Kit $(if (@($st | Where-Object { $_.Status -in 'DOWN', 'MISSING' }).Count) { 1 } else { 0 }) -NoPause:$NoPause
}

if ($Mode -eq 'Repair') {
  Say-Step 'Repair'
  $st = @(Invoke-MsRepair -Only $(if ($Only.Count) { $Only } else { $null }) -Force $Force -Interactive:(-not $NoPause))
  Show-MsSummary $st
  Exit-Kit 0 -NoPause:$NoPause
}

while ($true) {
  Say-Step 'Checking'
  $st = @(Test-MsAll)
  Show-MsTable $st
  Show-MsSummary $st
  $bad = @($st | Where-Object { $_.Status -ne 'OK' })
  if ($bad.Count) { Say '  R = repair what is not OK    C = check again    Q = quit' 'White' }
  else { Say '  C = check again    Q = quit' 'White' }
  $a = Read-Host '  Your choice'
  if ($a -match '^[qQ]') { break }
  if ($a -match '^[rR]' -and $bad.Count) {
    if (-not $admin) { Say-Fail 'A repair needs administrator rights.'; continue }
    Say-Step 'Repair'
    [void](Invoke-MsRepair -Interactive)
    [void](Read-Host '  Press ENTER to continue')
  }
}
Exit-Kit 0 -NoPause
