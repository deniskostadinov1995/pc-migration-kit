<#
  PC Migration Kit - RESTORE
  --------------------------
  Run on the NEW Windows (fresh install), signed in as the account that will
  use the PC. Puts back, in order: drive letters, Windows features, apps
  (winget), your files and profile, app data, your apps' registry settings,
  environment variables, services, scheduled tasks, startup items, WSL,
  drivers, Wi-Fi/hosts/power plan/fonts, taskbar pins, the media server and
  folders from other drives. The steps themselves are in RestoreSteps.ps1.

  Every step skips what is already in place, and finished steps are remembered,
  so running RESTORE again (after a reboot, or after installing an app by hand)
  is safe - it never overwrites newer files with a second copy of the backup
  unless you explicitly pick that step again. While it runs, Windows Update is
  kept from restarting the PC; if the PC restarts anyway, RESTORE opens again
  by itself after you sign in.

  The account may have another name than the old one (backup made as "Plex",
  restored as "Jellyfin"): whatever still names the old account - C:\Users\Plex
  in app settings files, shortcuts, registry values, environment variables,
  services, scheduled tasks, startup items and the scripts they run - is
  rewritten for the new one on the way.

  -BackupPath  which backup (default: the one this copy sits in, else the newest in ..\Backups)
  -DryRun      show what would happen, change nothing
  -Force       allow running on the same Windows the backup was taken from
  -Steps       run only these step numbers, e.g. -Steps 3,9 (or a selection's Steps.Include)
  -Selection   a JSON file from the PC Migration Kit app: which items to restore

  Written by Claude 2026-09-27.
#>
param(
  [string]$BackupPath,
  [switch]$DryRun,
  [switch]$Force,
  [string[]]$Steps,
  [switch]$NoPause,
  [string]$Selection
)

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
. (Join-Path $PSScriptRoot 'MediaServer.ps1')
. (Join-Path $PSScriptRoot 'RestoreSteps.ps1')
Set-ConsoleUtf8
$KitRoot = Split-Path $PSScriptRoot -Parent
if ($script:Gui) { $NoPause = $true }

# -------------------------------------------- a restart in the middle of a run ---
# On 2026-09-30 Windows Update restarted the fresh Windows at 00:43, in the middle of
# step 12. Steps 12-15 never ran - the media server among them, so Jellyfin stayed
# down - and nothing said so. Now, while RESTORE runs, Windows Update may not restart
# the PC for the next 18 hours (its "active hours"), and should the PC restart anyway,
# RESTORE opens again by itself after you sign in.
$script:ResumeValue = 'PC Migration Kit - finish RESTORE'
$script:RunOnceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$script:WuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

function Register-KitResume {
  # the app (the one that started this run, else one next to the kit), else the RESTORE launcher
  $exe = if ($env:PCMK_APP_EXE) { $env:PCMK_APP_EXE } else { Join-Path $KitRoot 'PC Migration Kit.exe' }
  $cmd = $null
  if (Test-Path -LiteralPath $exe) { $cmd = '"{0}" --page restore --backup "{1}"' -f $exe, $script:B }
  else {
    $bat = @(Get-ChildItem -LiteralPath $KitRoot -Filter '*.bat' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)RESTORE' }) | Select-Object -First 1
    if ($bat) { $cmd = '"{0}"' -f $bat.FullName }
  }
  if (-not $cmd) { return }
  try { New-ItemProperty -LiteralPath $script:RunOnceKey -Name $script:ResumeValue -Value $cmd -PropertyType String -Force | Out-Null } catch {}
}

function Unregister-KitResume { Remove-ItemProperty -LiteralPath $script:RunOnceKey -Name $script:ResumeValue -ErrorAction SilentlyContinue }

function Suspend-KitUpdateRestart {
  $saved = Join-Path $script:StateDir 'update-policy-before.json'
  try {
    if (-not (Test-Path -LiteralPath $saved)) {   # a resumed run keeps the values from before the first one
      $cur = Get-ItemProperty -LiteralPath $script:WuPolicyKey -ErrorAction SilentlyContinue
      Save-Json @{ SetActiveHours = $cur.SetActiveHours; ActiveHoursStart = $cur.ActiveHoursStart; ActiveHoursEnd = $cur.ActiveHoursEnd } $saved
    }
    $from = (Get-Date).Hour
    $to = ($from + 18) % 24
    if (-not (Test-Path -LiteralPath $script:WuPolicyKey)) { New-Item -Path $script:WuPolicyKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $script:WuPolicyKey -Name SetActiveHours -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $script:WuPolicyKey -Name ActiveHoursStart -Value $from -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $script:WuPolicyKey -Name ActiveHoursEnd -Value $to -PropertyType DWord -Force | Out-Null
    Say-Info ('Windows Update will not restart the PC between {0}:00 and {1}:00 while RESTORE runs.' -f $from, $to)
  } catch { Write-KitLog ('Could not hold off Windows Update restarts: ' + $_.Exception.Message) }
}

function Resume-KitUpdateRestart {
  $saved = Join-Path $script:StateDir 'update-policy-before.json'
  $before = Read-Json $saved
  if (-not $before) { return }
  foreach ($n in 'SetActiveHours', 'ActiveHoursStart', 'ActiveHoursEnd') {
    if ($null -ne $before.$n) { New-ItemProperty -LiteralPath $script:WuPolicyKey -Name $n -Value ([int]$before.$n) -PropertyType DWord -Force | Out-Null }
    else { Remove-ItemProperty -LiteralPath $script:WuPolicyKey -Name $n -ErrorAction SilentlyContinue }
  }
  Remove-Item -LiteralPath $saved -Force -ErrorAction SilentlyContinue
}

# ================================================================= main ====
Show-Banner 'RESTORE' 'Run this on the NEW Windows, signed in as the account you will use.'
if ($DryRun) { Say '  DRY RUN - nothing will be changed.' 'Yellow' }

$admin = Test-IsAdmin
if (-not $admin -and -not $DryRun) {
  Say-Fail 'RESTORE needs administrator rights. Start it with "3 - RESTORE (run on NEW Windows).bat" (or the PC Migration Kit app) and click Yes when Windows asks.'
  Exit-Kit 1 -NoPause:$NoPause
}
Update-ProcessPath

# ---- find the backup
if (-not (Initialize-KitBackup -BackupPath $BackupPath -KitRoot $KitRoot -Pick)) {
  Say-Fail ('No backup found ({0}).' -f $(if ($BackupPath) { $BackupPath } else { Join-Path $KitRoot 'Backups' }))
  Exit-Kit 1 -NoPause:$NoPause
}
Read-KitSelection $Selection
# "-Steps 3,9" arrives as one string when started with -File; the app passes the steps in the selection
$stepNums = @($Steps | ForEach-Object { ([string]$_) -split '[,;\s]+' } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
if (-not $stepNums.Count -and $script:Sel -and $script:Sel.Steps -and $script:Sel.Steps.Include) { $stepNums = @($script:Sel.Steps.Include | ForEach-Object { [int]$_ }) }

$statePath = Join-Path $script:StateDir ('restore-state-{0}.json' -f $script:M.BackupId)
if (-not $DryRun) { Start-KitLog (Join-Path $script:StateDir ('restore-{0}\restore.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))) }
$state = Read-Json $statePath
$done = @{}; $attempted = @{}
if ($state) {
  if ($state.Done) { foreach ($p in $state.Done.PSObject.Properties) { $done[$p.Name] = [string]$p.Value } }
  if ($state.Attempted) { foreach ($p in $state.Attempted.PSObject.Properties) { $attempted[$p.Name] = [string]$p.Value } }
}

Say ('  Backup   : {0}' -f $script:B) 'White'
Say ('  From     : {0}, user {1}, taken {2}' -f $script:M.System.ComputerName, $script:M.System.UserName, $script:M.CreatedAt) 'White'
Say ('  Restoring: {0}, user {1}' -f $env:COMPUTERNAME, $env:USERNAME) 'White'

# ---- safety checks
$myGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction SilentlyContinue).MachineGuid
if ($myGuid -and $myGuid -eq $script:M.System.MachineGuid -and -not $Force -and -not $DryRun) {
  Say-Fail 'This is the SAME Windows installation the backup was taken from. RESTORE is meant for the new Windows after the SSD swap.'
  Say-Info '(If you really want to run it here, start Restore.ps1 with -Force.)'
  Exit-Kit 1 -NoPause:$NoPause
}
if ($script:M.System.UserName -ne $env:USERNAME -or (Get-KitRename)) {
  Say ('  The backup is from account "{0}" ({1}); you are signed in as "{2}" ({3}).' -f $script:M.System.UserName, $script:OldProfile, $env:USERNAME, $script:NewProfile) 'Yellow'
  Say '  Everything goes into your account, and whatever still names the old one - paths in app settings,' 'Yellow'
  Say '  shortcuts, registry values, services, scheduled tasks, startup items and their scripts - is rewritten for it.' 'Yellow'
  if (-not $NoPause -and -not $DryRun) { if ((Read-Host ('  Restore "{0}" into "{1}"? (Y/n)' -f $script:M.System.UserName, $env:USERNAME)) -match '^[nN]') { Exit-Kit 1 } }
}
if ($script:M.TestMode) { Say-Warn 'This backup was made in test mode (settings and a tiny file sample only).' }

# ---- step menu
$defs = @(Get-KitRestoreSteps)
Send-KitEvent @{ t = 'steps'; steps = @($defs | ForEach-Object { @{ n = $_.N; key = $_.Key; title = $_.Title; done = $(if ($done.ContainsKey($_.Key)) { $done[$_.Key] } else { $null }) } }) }
if (-not $script:Gui) {
  Write-Host ''
  Write-Host '   #   Step                                                      Status' -ForegroundColor Gray
  foreach ($d in $defs) {
    $status = 'to do'; $color = 'White'
    if ($done.ContainsKey($d.Key)) { $status = 'done ' + $done[$d.Key]; $color = 'DarkGray' }
    Write-Host ('  {0,2}   {1,-57} {2}' -f $d.N, $d.Title, $status) -ForegroundColor $color
  }
  Write-Host ''
}
$run = @()
if ($stepNums.Count) { $run = @($defs | Where-Object { $stepNums -contains $_.N }) }
elseif ($NoPause) { $run = @($defs | Where-Object { -not $done.ContainsKey($_.Key) }) }
else {
  Say '  Press ENTER to run every step that is still "to do",' 'White'
  Say '  or type step numbers to run just those (e.g. "3" or "9 10"), or Q to quit.' 'White'
  $ans = Read-Host '  Your choice'
  if ($ans -match '^[qQ]') { Exit-Kit 0 }
  if ($ans.Trim()) { $nums = @($ans -split '[\s,]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }); $run = @($defs | Where-Object { $nums -contains $_.N }) }
  else { $run = @($defs | Where-Object { -not $done.ContainsKey($_.Key) }) }
}
if (-not $run.Count) { Say-Ok 'Nothing left to do.'; Exit-Kit 0 -NoPause:$NoPause }
if (-not $DryRun) { Register-KitResume; Suspend-KitUpdateRestart }

# the backup drive itself may get a new letter in step 1
$backupVolume = $null
try { $backupVolume = (Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter -and $script:B.StartsWith($_.DriveLetter, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1).DeviceID } catch {}

$k = 0
foreach ($d in $run) {
  $k++
  Say-Step ('Step {0} - {1}' -f $d.N, $d.Title)
  Send-KitEvent @{ t = 'step'; n = $d.N; key = $d.Key; state = 'start'; index = $k; of = $run.Count }
  $issuesBefore = $script:Issues.Count
  $script:SkipNewer = $attempted.ContainsKey($d.Key)
  if ($script:SkipNewer -and $d.Key -in 'files', 'appdata', 'explorer') { Say-Info ('This step already ran on {0}; files you changed since then are kept.' -f $attempted[$d.Key]) }
  if (-not $DryRun) { $attempted[$d.Key] = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
  try { & $d.Fn } catch { Say-Fail ('Step {0} stopped: {1}' -f $d.N, $_.Exception.Message) }
  if ($d.Key -eq 'letters' -and $backupVolume -and -not $DryRun) {
    $nv = Get-CimInstance Win32_Volume | Where-Object { $_.DeviceID -eq $backupVolume } | Select-Object -First 1
    if ($nv -and $nv.DriveLetter -and -not $script:B.StartsWith($nv.DriveLetter, [StringComparison]::OrdinalIgnoreCase)) {
      $oldLetter = $script:B.Substring(0, 2)
      $script:B = $nv.DriveLetter + $script:B.Substring(2)
      $script:SrcProfile = P ('files\C\' + $script:OldProfile.Substring(3))
      $script:RestoreExcludes = $null
      if ($KitRoot.StartsWith($oldLetter, [StringComparison]::OrdinalIgnoreCase)) { $KitRoot = $nv.DriveLetter + $KitRoot.Substring(2); Register-KitResume }
      Say-Info ('The backup drive is now {0} - continuing from {1}' -f $nv.DriveLetter, $script:B)
    }
  }
  $ok = ($script:Issues.Count -eq $issuesBefore)
  if (-not $DryRun -and $ok) { $done[$d.Key] = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
  elseif (-not $DryRun) { Say-Info ('Step {0} finished with warnings - it stays "to do" so you can run it again.' -f $d.N) }
  Send-KitEvent @{ t = 'step'; n = $d.N; key = $d.Key; state = $(if ($ok) { 'done' } else { 'warn' }); index = $k; of = $run.Count }
  if (-not $DryRun) { Save-Json @{ BackupId = $script:M.BackupId; Done = $done; Attempted = $attempted } $statePath }
}

if (@($run | Where-Object { $_.Key -in 'files', 'appdata', 'services', 'registry' }).Count) {
  Say-Step 'Starting services again'
  Start-KitServices
}

# ---- summary
Say-Step 'RESTORE finished'
$left = @($defs | Where-Object { -not $done.ContainsKey($_.Key) })
$resumes = $false
if (-not $DryRun) {
  Resume-KitUpdateRestart
  # the restart asked for below brings RESTORE back by itself; otherwise this run is over
  $resumes = $script:NeedReboot -and $left.Count -gt 0
  if ($resumes) { Register-KitResume } else { Unregister-KitResume }
}
if ($DryRun) { Say '  Dry run only - nothing was changed.' 'Yellow' }
elseif ($left.Count) { Say ('  Steps still to do: ' + (($left | ForEach-Object { $_.N }) -join ', ') + '  - run RESTORE again after fixing the warnings above.') 'Yellow' }
else { Say '  All steps done.' 'Green' 'ok' }
if ($script:PathFixCount -and -not $DryRun) { Say ('  {0} -> {1} was rewritten inside {2} file(s) - each one is listed in {3}' -f $script:OldProfile, $script:NewProfile, $script:PathFixCount, $script:LogPath) 'Gray' }
if ($script:Missing.Count) {
  Say '' ; Say '  Still needs you:' 'Yellow' 'warn'
  foreach ($m in $script:Missing) { Say ('   - ' + $m) 'Yellow' 'warn' }
}
Send-KitEvent @{ t = 'summary'; left = @($left | ForEach-Object { $_.N }); missing = @($script:Missing); reboot = [bool]$script:NeedReboot; resumes = $resumes }
if ($resumes) { Say ''; Say '  RESTART the PC now. After you sign in, RESTORE opens again by itself (click Yes) to finish what is left.' 'Cyan' 'info' }
elseif ($script:NeedReboot) { Say ''; Say '  RESTART the PC now, then run RESTORE again to finish anything left (WSL, services).' 'Cyan' 'info' }
else { Say ''; Say '  Restart the PC once so every app, service and startup item comes up cleanly. Afterwards, VERIFY checks that everything is back.' 'Cyan' 'info' }
$report = P 'Report.html'
if ((Test-Path -LiteralPath $report) -and -not $NoPause -and -not $DryRun) {
  Say '  The report just opened - its section "What you will still do by hand" is your checklist.' 'Gray'
  Open-AsUser $report
}
Exit-Kit 0 -NoPause:$NoPause
