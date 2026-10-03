<#
  PC Migration Kit - BACKUP
  -------------------------
  Run on the OLD Windows, before the SSD swap.

  1. Scans the PC (programs, services, scheduled tasks, startup items, drives ...).
  2. Exports everything that lives *inside* Windows: the winget app list, task
     XML, service definitions, startup entries, environment variables, your
     apps' registry settings, Wi-Fi profiles, drivers, fonts, power plan, hosts.
  3. Copies every file on C: that is not Windows itself (your profile incl.
     AppData, ProgramData app data, Program Files, your own C:\ folders) from a
     shadow-copy snapshot, so open databases (Plex, *arr, Docker, WSL) are
     captured in a consistent state.
  4. Writes manifest.json + Report.html and puts a RESTORE launcher next to it.

  -ScanOnly   only writes the report (reads the PC, copies nothing)
  -TestMode   developer check: settings + a tiny file sample, no snapshot
  -Selection  a JSON file from the PC Migration Kit app: what to keep (see
              Apply-KitFileSelection and Common.ps1 - Test-KitSelected)
  -Update     with -Destination: refresh that existing backup in place

  Written by Claude 2026-09-27.
#>
param(
  [switch]$ScanOnly,
  [string]$Destination,
  [switch]$TestMode,
  [switch]$NoPause,
  [string]$Selection,
  [switch]$Update
)

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
. (Join-Path $PSScriptRoot 'MediaServer.ps1')
Set-ConsoleUtf8
$KitRoot = Split-Path $PSScriptRoot -Parent
if ($script:Gui) { $NoPause = $true }
Read-KitSelection $Selection

# ------------------------------------------------------- what was ticked ---
# Applies the app's file choices to the copy plan:
#   Files.ExcludePaths - folders (full paths) to leave out, wherever they fall in the plan
#   Files.Extra        - folders anywhere (other drives too) to copy as well
# Returns the extra copy jobs; the plan jobs are changed in place.
function Apply-KitFileSelection([ref]$Plan) {
  $sysRoot = $env:SystemDrive + '\'
  $ex = @(Get-KitSelList 'Files' 'ExcludePaths' | ForEach-Object { ([string]$_).TrimEnd('\') })
  if ($ex.Count) {
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($job in $Plan.Value) {
      $src = (Join-Path $sysRoot $job.Rel).TrimEnd('\')
      if (Test-KitUnder $src $ex) { Say-Info ('Not selected: {0}' -f $job.Label); continue }
      $inside = @($ex | Where-Object { Test-KitUnder $_ @($src) })
      if ($inside.Count) { $job.ExcludeRel = @($job.ExcludeRel) + @($inside | ForEach-Object { $_.Substring($sysRoot.Length) }) }
      $kept.Add($job)
    }
    $Plan.Value = $kept.ToArray()
  }
  $extra = New-Object System.Collections.Generic.List[object]
  foreach ($x in @(Get-KitSelList 'Files' 'Extra')) {
    $path = ([string]$(if ($x.Path) { $x.Path } else { $x })).TrimEnd('\')
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
    if ($path -match '^[A-Za-z]:$') { Say-Warn ('A whole drive ({0}) cannot be added as one folder - tick its folders instead.' -f $path); continue }
    # already part of the plan (and not left out)?
    $covered = $false
    foreach ($job in $Plan.Value) {
      $src = (Join-Path $sysRoot $job.Rel).TrimEnd('\')
      if ((Test-KitUnder $path @($src)) -and -not (Test-KitUnder $path @($job.ExcludeRel | ForEach-Object { Join-Path $sysRoot $_ }))) { $covered = $true; break }
    }
    if ($covered) { continue }
    if ($Destination -and (Test-KitUnder $Destination @($path))) { Say-Warn ('{0} holds the backup folder itself - left out.' -f $path); continue }
    $letter = $path.Substring(0, 1).ToUpper()
    $extra.Add([pscustomobject]@{ Label = $path; Path = $path; Dest = ('files\{0}\{1}' -f $letter, $path.Substring(3)); ExcludeRel = @(); ExcludeNames = @(); ExcludeFiles = @(); Files = $null; Extra = $true
                                  ExcludeAbs = @($ex | Where-Object { Test-KitUnder $_ @($path) }) })
  }
  return $extra.ToArray()
}

# ------------------------------------------------------------ helpers ------
function Get-KitProgramDataTargets($Inv) {
  $pd = $env:ProgramData.TrimEnd('\')
  $map = @{}
  foreach ($s in $Inv.Services) {
    foreach ($m in [regex]::Matches([string]$s.PathName, [regex]::Escape($pd) + '\\([^\\"\s]+)', 'IgnoreCase')) {
      $f = $m.Groups[1].Value
      if ($script:ProgramDataSkip -contains $f) { continue }
      if (-not $map.ContainsKey($f)) { $map[$f] = New-Object System.Collections.Generic.List[string] }
      if (-not $map[$f].Contains($s.Name)) { $map[$f].Add($s.Name) }
    }
  }
  foreach ($f in $script:ProgramDataAllow) {
    if ((Test-Path -LiteralPath (Join-Path $pd $f)) -and -not $map.ContainsKey($f)) { $map[$f] = New-Object System.Collections.Generic.List[string] }
  }
  $extra = @{ 'RealVNC-Service' = 'vncserver' }
  foreach ($f in @($map.Keys)) {
    foreach ($s in $Inv.Services) {
      if (($s.PathName -match [regex]::Escape($f)) -and -not $map[$f].Contains($s.Name)) { $map[$f].Add($s.Name) }
    }
    if ($extra.ContainsKey($f) -and -not $map[$f].Contains($extra[$f])) { $map[$f].Add($extra[$f]) }
  }
  @($map.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Folder = $_; Services = @($map[$_]) } })
}

function Write-InstallList($Inv, [string]$Path) {
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# PC Migration Kit - apps that RESTORE installs with winget, one per line.')
  $lines.Add('# To skip an app, put # in front of its line. Format: <winget id> [source]')
  $lines.Add('')
  $off = New-Object System.Collections.Generic.List[string]
  # runtimes and WSL first - Docker Desktop and friends expect them
  $first = '^(Microsoft\.WSL|Microsoft\.VCRedist|Microsoft\.DotNet\.(Runtime|DesktopRuntime)|Oracle\.JavaRuntimeEnvironment)'
  $ordered = @($Inv.AppPlan.Install | Where-Object { $_.Id -match $first }) + @($Inv.AppPlan.Install | Where-Object { $_.Id -notmatch $first })
  foreach ($a in $ordered) {
    $reason = $a.Skip
    if (-not $reason -and -not (Test-KitSelected 'Apps' $a.Id)) { $reason = 'not selected when this backup was made' }
    $entry = $a.Id
    if ($a.Source -and $a.Source -ne 'winget') { $entry += ' ' + $a.Source }
    $notes = @()
    if ($a.Version) { $notes += 'version ' + $a.Version }
    if ($a.How -eq 'matched by name') { $notes += 'matched by name: ' + $a.Name }
    if ($reason) { $off.Add(('# {0,-44} ({1})' -f $entry, $reason)) }
    elseif ($notes.Count) { $lines.Add(('{0,-46} # {1}' -f $entry, ($notes -join '; '))) }
    else { $lines.Add($entry) }
  }
  if ($off.Count) { $lines.Add(''); $lines.Add('# --- deliberately not installed ---'); foreach ($o in $off) { $lines.Add($o) } }
  [IO.File]::WriteAllLines($Path, $lines.ToArray(), (New-Object Text.UTF8Encoding($false)))
}

function Export-KitSettings($Inv, [string]$Dir, [bool]$Admin) {
  # ---- apps (the install list marks apps that were not ticked)
  $apps = New-Dir (Join-Path $Dir 'apps')
  Write-InstallList $Inv (Join-Path $apps 'install-list.txt')
  $plan = $Inv.AppPlan
  if ($script:Sel) {
    $plan = [pscustomobject]@{ Install = $Inv.AppPlan.Install; System = $Inv.AppPlan.System; OtherDrive = $Inv.AppPlan.OtherDrive
                               Manual = @($Inv.AppPlan.Manual | Where-Object { Test-KitSelected 'Apps' ('manual:' + $_.Name) })
                               Store = @($Inv.AppPlan.Store | Where-Object { Test-KitSelected 'Apps' ('store:' + ($_.FamilyName -split '_')[0]) }) }
  }
  $storeApps = @($Inv.StoreApps | Where-Object { Test-KitSelected 'Apps' ('store:' + $_.PackageName) })
  Save-Json @{ Programs = $Inv.Programs; StoreApps = $storeApps; Plan = $plan; Choco = $Inv.Choco; Python = $Inv.Python } (Join-Path $apps 'apps.json')
  foreach ($vs in $Inv.VsInstances) {
    $name = Get-SafeName ('{0}-{1}' -f ($vs.Product -replace '^Microsoft\.VisualStudio\.Product\.', ''), ($vs.Channel -replace '^VisualStudio\.', '' -replace '\.Release$', ''))
    Save-Json ([ordered]@{ version = '1.0'; components = @($vs.Components) }) (Join-Path $apps "vs\$name.vsconfig")
  }
  Say-Ok ('App list: {0} winget apps, {1} to install by hand' -f @($Inv.AppPlan.Install | Where-Object { -not $_.Skip -and (Test-KitSelected 'Apps' $_.Id) }).Count, @($plan.Manual).Count)

  # ---- scheduled tasks
  $tdir = New-Dir (Join-Path $Dir 'tasks')
  $i = 0; $saved = 0
  $meta = @(foreach ($t in @($Inv.Tasks | Where-Object { Test-KitSelected 'Tasks' ($_.Path + $_.Name) })) {
    $i++
    $file = 'task{0:D3}.xml' -f $i
    $ok = $false
    try {
      $xml = Export-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop
      [IO.File]::WriteAllText((Join-Path $tdir $file), $xml, [Text.Encoding]::Unicode)
      $ok = $true; $saved++
    } catch { Say-Warn ('Could not export scheduled task {0}{1}' -f $t.Path, $t.Name) }
    $t | Select-Object *, @{ n = 'XmlFile'; e = { if ($ok) { $file } else { $null } } }
  })
  Save-Json @{ Tasks = $meta } (Join-Path $tdir 'tasks.json')
  Say-Ok "Scheduled tasks: $saved"

  # ---- services
  $services = @($Inv.Services | Where-Object { Test-KitSelected 'Services' $_.Name })
  Save-Json @{ Services = $services } (Join-Path $Dir 'services\services.json')
  Say-Ok ('Services: {0}' -f $services.Count)

  # ---- startup
  $sdir = New-Dir (Join-Path $Dir 'startup')
  $startup = @($Inv.Startup | Where-Object { Test-KitSelected 'Startup' ('{0}|{1}' -f $_.Hive, $_.Name) })
  foreach ($it in @($startup | Where-Object { $_.Type -eq 'Folder' })) {
    $to = New-Dir (Join-Path $sdir ('files\' + $it.Hive))
    Copy-Item -LiteralPath $it.File -Destination $to -Force -ErrorAction SilentlyContinue
  }
  [void](Export-RegKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved' (Join-Path $sdir 'StartupApproved-HKCU.reg'))
  [void](Export-RegKey 'HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved' (Join-Path $sdir 'StartupApproved-HKLM.reg'))
  Save-Json @{ Items = $startup } (Join-Path $sdir 'startup.json')
  Say-Ok ('Startup items: {0}' -f $startup.Count)

  # ---- environment
  $envVars = @($Inv.Environment | Where-Object { Test-KitSelected 'Env' ('{0}|{1}' -f $_.Scope, $_.Name) })
  Save-Json @{ Variables = $envVars } (Join-Path $Dir 'env\environment.json')
  Say-Ok ('Environment variables: {0}' -f $envVars.Count)

  # ---- registry: every app's own HKCU key (restored), machine-wide keys (reference only)
  $rdir = New-Dir (Join-Path $Dir 'registry')
  $skip = @('Microsoft', 'Classes', 'Policies', 'Wow6432Node', 'RegisteredApplications', 'Clients', 'AppDataLow', 'IM Providers', 'ODBC', 'Python')
  $n = 0
  foreach ($k in Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue) {
    if ($skip -contains $k.PSChildName) { continue }
    if (-not (Test-KitSelected 'Registry' $k.PSChildName)) { continue }
    if (Export-RegKey ('HKCU\Software\' + $k.PSChildName) (Join-Path $rdir ('hkcu\' + (Get-SafeName $k.PSChildName) + '.reg'))) { $n++ }
  }
  if (Test-KitSelected 'Settings' 'registry-reference') {
    foreach ($root in @(@{ Key = 'HKLM\SOFTWARE'; Ps = 'HKLM:\SOFTWARE'; Prefix = '' }, @{ Key = 'HKLM\SOFTWARE\WOW6432Node'; Ps = 'HKLM:\SOFTWARE\WOW6432Node'; Prefix = 'wow64-' })) {
      foreach ($k in Get-ChildItem $root.Ps -ErrorAction SilentlyContinue) {
        if ($skip -contains $k.PSChildName -or $k.PSChildName -eq 'WOW6432Node') { continue }
        [void](Export-RegKey ($root.Key + '\' + $k.PSChildName) (Join-Path $rdir ('hklm-reference\' + $root.Prefix + (Get-SafeName $k.PSChildName) + '.reg')))
      }
    }
    [void](Export-RegKey 'HKCU\Software' (Join-Path $rdir 'reference\HKCU-Software-everything.reg'))
  }
  [void](Export-RegKey 'HKLM\SOFTWARE\Python' (Join-Path $rdir 'special\python-hklm.reg'))
  if (Test-KitSelected 'Settings' 'mappeddrives') { [void](Export-RegKey 'HKCU\Network' (Join-Path $rdir 'special\mapped-drives.reg')) }
  if (Test-KitSelected 'Settings' 'taskbar') { [void](Export-RegKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' (Join-Path $rdir 'special\taskband.reg')) }
  Say-Ok "Registry settings of $n apps"

  # ---- network
  $ndir = New-Dir (Join-Path $Dir 'network')
  if (Test-KitSelected 'Settings' 'hosts') { Copy-Item -LiteralPath (Join-Path $env:windir 'System32\drivers\etc\hosts') -Destination (Join-Path $ndir 'hosts') -Force -ErrorAction SilentlyContinue }
  $wdir = New-Dir (Join-Path $ndir 'wifi')
  if ($Admin -and (Test-KitSelected 'Settings' 'wifi')) {
    [void](Invoke-Native 'netsh.exe' ('wlan export profile key=clear folder="{0}"' -f $wdir))
    Say-Ok ('Wi-Fi profiles: {0} (passwords included - keep this backup private)' -f @(Get-ChildItem -LiteralPath $wdir -Filter *.xml -ErrorAction SilentlyContinue).Count)
  }
  Save-Json @{ Printers = $Inv.Printers; MappedDrives = $Inv.MappedDrives; Credentials = $Inv.Credentials } (Join-Path $ndir 'network.json')

  # ---- power plan
  if (Test-KitSelected 'Settings' 'power') {
    $pdir = New-Dir (Join-Path $Dir 'power')
    $guid = [regex]::Match((& powercfg.exe /getactivescheme | Out-String), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    if ($guid) {
      [void](Invoke-Native 'powercfg.exe' ('/export "{0}" {1}' -f (Join-Path $pdir 'scheme.pow'), $guid))
      Save-Json @{ ActiveScheme = $guid } (Join-Path $pdir 'power.json')
      Say-Ok 'Power plan'
    }
  }

  # ---- fonts (per-user fonts travel with the profile copy)
  if (Test-KitSelected 'Settings' 'fonts') {
    $fdir = New-Dir (Join-Path $Dir 'fonts\machine')
    foreach ($f in $Inv.Fonts.Machine) { Copy-Item -LiteralPath (Join-Path $env:windir "Fonts\$($f.File)") -Destination $fdir -Force -ErrorAction SilentlyContinue }
    Save-Json @{ Machine = $Inv.Fonts.Machine; User = $Inv.Fonts.User } (Join-Path $Dir 'fonts\fonts.json')
    Say-Ok ('Extra fonts: {0}' -f (@($Inv.Fonts.Machine).Count + @($Inv.Fonts.User).Count))
  }

  # ---- WSL, Docker, Windows features
  Save-Json @{ Distros = @($Inv.Wsl | Where-Object { $_.IsDocker -or (Test-KitSelected 'Wsl' $_.Name) }) } (Join-Path $Dir 'wsl\wsl.json')
  Save-Json @{ Docker = $Inv.Docker; HyperV = $Inv.HyperV } (Join-Path $Dir 'docker\docker.json')
  if (Test-KitSelected 'Settings' 'features') { Save-Json @{ Features = $Inv.Features } (Join-Path $Dir 'system\features.json') }

  # ---- drivers (same motherboard -> saves hunting for network/audio/chipset drivers)
  if ($Admin -and (Test-KitSelected 'Settings' 'drivers')) {
    Say-Info 'Exporting drivers (a minute or two)...'
    $ddir = New-Dir (Join-Path $Dir 'drivers')
    $r = Invoke-Native 'pnputil.exe' ('/export-driver * "{0}"' -f $ddir)
    $cnt = @(Get-ChildItem -LiteralPath $ddir -Directory -ErrorAction SilentlyContinue).Count
    if ($cnt -gt 0) { Say-Ok "Drivers: $cnt packages" } else { Say-Warn ('Driver export failed (pnputil exit {0})' -f $r.ExitCode) }
  }
}

function New-KitSnapshot([string]$Volume) {
  if (-not $Volume) { $Volume = $env:SystemDrive + '\' }
  $r = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = $Volume; Context = 'ClientAccessible' } -ErrorAction Stop
  if ($r.ReturnValue -ne 0) { throw ('Windows returned code {0}' -f $r.ReturnValue) }
  $sc = Get-CimInstance -ClassName Win32_ShadowCopy -Filter ("ID='{0}'" -f $r.ShadowID)
  $link = '{0}\PCMK-snap-{1}' -f $env:SystemDrive, (Get-Random -Maximum 99999)
  [void](Invoke-Native 'cmd.exe' ('/c mklink /d {0} {1}\' -f $link, $sc.DeviceObject))
  $snap = [pscustomobject]@{ Id = $r.ShadowID; Link = $link }
  $opened = $false
  try { [void][IO.Directory]::GetFileSystemEntries($link); $opened = $true } catch {}
  if (-not $opened) { Remove-KitSnapshot $snap; throw 'the snapshot could not be opened' }
  return $snap
}

function Remove-KitSnapshot($Snap) {
  if (-not $Snap) { return }
  # rmdir removes only the link itself, never the snapshot contents behind it
  if ($Snap.Link -and (Test-Path -LiteralPath $Snap.Link)) { [void](Invoke-Native 'cmd.exe' ('/c rmdir {0}' -f $Snap.Link)) }
  try { Get-CimInstance -ClassName Win32_ShadowCopy -Filter ("ID='{0}'" -f $Snap.Id) | Remove-CimInstance -ErrorAction Stop }
  catch { Say-Warn ('Could not remove the temporary snapshot {0}: {1}' -f $Snap.Id, $_.Exception.Message) }
}

# ================================================================= main ====
if ($ScanOnly) { Show-Banner 'SCAN' 'Looks at this PC and writes a report. Changes nothing, copies nothing.' }
else { Show-Banner 'BACKUP' 'Run this on the OLD Windows, before you swap the SSD.' }

$admin = Test-IsAdmin
if (-not $admin -and -not $ScanOnly -and -not $TestMode) {
  Say-Fail 'The backup needs administrator rights. Start it with "2 - BACKUP (run on OLD Windows).bat" (or the PC Migration Kit app) and click Yes when Windows asks.'
  Exit-Kit 1 -NoPause:$NoPause
}

$me = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
$consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
if ($consoleUser -and $consoleUser -ne $me) {
  Say-Warn ('You are signed in to Windows as {0}, but this window runs as {1}. Only {1}''s files and settings would be captured.' -f $consoleUser, $me)
  if (-not $NoPause) { if ((Read-Host 'Continue anyway? (y/N)') -notmatch '^[yY]') { Exit-Kit 1 } }
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$sysLetter = $env:SystemDrive.Substring(0, 1).ToUpper()
$previousManifest = $null

if (-not $ScanOnly) {
  if (-not $Destination) {
    $base = Join-Path $KitRoot 'Backups'
    if ($KitRoot.Substring(0, 1).ToUpper() -eq $sysLetter) {
      Say-Warn "This kit sits on $env:SystemDrive - the drive you are replacing. Choose a folder on another drive."
      $base = Select-Folder 'Where should the backup go? Pick a folder on a drive that is NOT C:'
      if (-not $base) { Exit-Kit 1 -NoPause:$NoPause }
    }
    $Destination = Join-Path $base ('{0}_{1}' -f $env:COMPUTERNAME, $stamp)
    # a second run (e.g. right before the swap) can refresh the last backup instead of copying everything again
    $previous = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "$($env:COMPUTERNAME)_*" -and (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')) } | Sort-Object Name -Descending)
    if ($previous.Count -and -not $NoPause) {
      Say ('  Found an earlier backup: {0}' -f $previous[0].Name) 'White'
      $ans = Read-Host '  [U]pdate it (copies only what changed - minutes, not an hour) or make a [N]ew one? (U/n)'
      if ($ans -notmatch '^[nN]') { $Destination = $previous[0].FullName; Say-Info 'Updating the earlier backup.' }
    }
  } elseif (-not $Update -and (Test-Path -LiteralPath (Join-Path $Destination 'manifest.json'))) {
    # the app picked a folder that already is a backup without asking for an update: a new one next to it
    $Destination = Join-Path (Split-Path $Destination -Parent) ('{0}_{1}' -f $env:COMPUTERNAME, $stamp)
  }
  if (-not $TestMode -and $Destination.Substring(0, 1).ToUpper() -eq $sysLetter) {
    Say-Fail "The backup cannot be stored on $env:SystemDrive - that is the drive being replaced."
    Exit-Kit 1 -NoPause:$NoPause
  }
  # an update keeps the backup's id, so a restore that already started from it carries on where it was
  $previousManifest = Read-Json (Join-Path $Destination 'manifest.json')
  New-Dir $Destination | Out-Null
  Start-KitLog (Join-Path $Destination 'backup.log')
  Send-KitEvent @{ t = 'destination'; path = $Destination; update = [bool]$previousManifest }
}

Say-Step 'Scanning this PC'
if ($ScanOnly) { $wingetJson = Join-Path $env:TEMP "pcmk-winget-$stamp.json" }
else { $wingetJson = Join-Path $Destination 'settings\apps\winget-export.json' }
$inv = Get-KitInventory -WingetExportPath $wingetJson
$plan = @(Get-KitCopyPlan $inv)
if ($TestMode) { $plan = @($plan | Where-Object { $_.Label -eq 'Your Desktop folder' -or $_.Rel -eq 'ngrok' -or $_.Rel -eq 'Users\Public' }) }
$extraJobs = @(Apply-KitFileSelection ([ref]$plan))
Say-Info 'Media server + smart home: checking every part...'
$msFacts = Get-MsFacts
$msStates = @(Test-MsAll)
$msJobs = @(Get-MsCopyJobs $msFacts)
if ($TestMode) { $msJobs = @($msJobs | Where-Object { $_.Label -match 'Docker compose|Caddy' }) }
# folders unticked in the app's drive view also apply to the media server's folders
$exSel = @(Get-KitSelList 'Files' 'ExcludePaths' | ForEach-Object { ([string]$_).TrimEnd('\') })
if ($exSel.Count) {
  $msJobs = @($msJobs | Where-Object { -not (Test-KitUnder $_.Path $exSel) })
  foreach ($j in $msJobs) { $j | Add-Member -NotePropertyName ExcludeAbs -NotePropertyValue @($exSel | Where-Object { Test-KitUnder $_ @($j.Path) }) -Force }
}
# a folder ticked in the app that the media server copies anyway is copied once
$extraJobs = @($extraJobs | Where-Object { $x = $_.Path; -not @($msJobs | Where-Object { Test-KitUnder $x @($_.Path) }).Count })
Say-Info 'Measuring how much data needs copying...'
$total = Measure-KitCopyPlan $plan
foreach ($j in @($msJobs) + @($extraJobs)) {
  if ($j.Files) {
    $bytes = [double](@($j.Files | ForEach-Object { $f = Join-Path $j.Path $_; if (Test-Path -LiteralPath $f) { (Get-Item -LiteralPath $f).Length } }) | Measure-Object -Sum).Sum
  } else {
    $ex = @($j.ExcludeRel | Where-Object { $_ } | ForEach-Object { Join-Path $j.Path $_ }) + @($j.ExcludeNames | Where-Object { $_ }) + @($j.ExcludeAbs | Where-Object { $_ })
    $bytes = (Measure-Tree $j.Path $ex @($j.ExcludeFiles | Where-Object { $_ })).Bytes
  }
  $j | Add-Member -NotePropertyName EstimatedBytes -NotePropertyValue $bytes -Force
  $total += $bytes
}
$inv | Add-Member -NotePropertyName EstimatedBytes -NotePropertyValue $total -Force
$inv | Add-Member -NotePropertyName MediaStates -NotePropertyValue $msStates -Force
Say-Ok ('{0} programs ({1} reinstall automatically), {2} scheduled tasks, {3} startup items, {4} services, about {5} of files.' -f
  @($inv.Programs).Count, @($inv.AppPlan.Install | Where-Object { -not $_.Skip }).Count, @($inv.Tasks).Count, @($inv.Startup).Count, @($inv.Services).Count, (Format-Bytes $total))
if ($inv.Boot.Split) { Say-Warn ('Boot files are on a different disk ({0}) than Windows ({1}). See the report.' -f $inv.Boot.EspDisks, $inv.Boot.WindowsDisk) }

if ($ScanOnly) {
  Show-MsTable $msStates
  $report = Join-Path $KitRoot ('Scan report - {0} - {1}.html' -f $env:COMPUTERNAME, $stamp)
  try { New-KitReport $inv $report 'Scan' $null; Say-Ok "Report: $report"; if (-not $NoPause) { Open-AsUser $report } }
  catch { Say-Fail ('Could not write the report: ' + $_.Exception.Message) }
  Exit-Kit 0 -NoPause:$NoPause
}

# ---- space check + go
$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Destination))
$need = $total * 1.05 + 6GB
if ($previousManifest) { $need = 6GB }   # an update only adds what changed
Say ''
Say ('  Backup folder : {0}' -f $Destination) 'White'
Say ('  To copy       : about {0}   (free space there: {1})' -f (Format-Bytes $total), (Format-Bytes $drive.AvailableFreeSpace)) 'White'
Send-KitEvent @{ t = 'plan'; total = $total; free = $drive.AvailableFreeSpace; jobs = (@($plan).Count + @($msJobs).Count + @($extraJobs).Count) }
if ($drive.AvailableFreeSpace -lt $need) {
  Say-Fail ('Not enough free space on {0} - need about {1}.' -f $drive.Name, (Format-Bytes $need))
  Exit-Kit 1 -NoPause:$NoPause
}
Say '  You can keep using the PC while it runs, but close games and virtual machines first.' 'Gray'
if (-not $NoPause) { [void](Read-Host "`n  Press ENTER to start the backup (or close this window to cancel)") }
$started = Get-Date

Say-Step 'Step 1 of 3 - settings that live inside Windows'
$settingsDir = New-Dir (Join-Path $Destination 'settings')
Export-KitSettings $inv $settingsDir $admin
[void](Save-MsSnapshot $settingsDir -Facts $msFacts -TestMode:$TestMode)

Say-Step 'Step 2 of 3 - copying files'
$copies = @()
$srcRoot = $env:SystemDrive + '\'
$snap = $null
if ($admin -and -not $TestMode) {
  foreach ($d in @($inv.Wsl | Where-Object { -not $_.IsDocker })) { $null = & wsl.exe --terminate $d.Name 2>&1 }   # clean copy of the Linux disk
  Say-Info 'Taking a snapshot of C: so files that are open right now are copied consistently...'
  try { $snap = New-KitSnapshot; $srcRoot = $snap.Link + '\'; Say-Ok 'Snapshot ready' }
  catch { Say-Warn ('Snapshot failed ({0}). Copying the live drive instead - files that are open right now may be skipped.' -f $_.Exception.Message) }
}
$sysExtra = @($extraJobs | Where-Object { $_.Path.Substring(0, 1).ToUpper() -eq $sysLetter })
$jobCount = @($plan).Count + @($msJobs).Count + @($extraJobs).Count
$n = 0
try {
  foreach ($job in $plan) {
    $n++
    Say-Info ('[{0}/{1}] {2}' -f $n, $jobCount, $job.Label)
    Send-KitEvent @{ t = 'job'; n = $n; of = $jobCount; label = $job.Label; expected = $job.EstimatedBytes }
    $src = Join-Path $srcRoot $job.Rel
    $dst = Join-Path $Destination $job.Dest
    $ex = @($job.ExcludeRel | ForEach-Object { Join-Path $srcRoot $_ }) + @($job.ExcludeNames)
    $res = Invoke-KitCopy -Source $src -Destination $dst -ExcludeDirs $ex -ExcludeFiles $job.ExcludeFiles -Label $job.Label -ExpectedBytes $job.EstimatedBytes -BackupMode:$admin
    Write-CopyResult $res
    $copies += $res
  }
  # folders on C: ticked in the app that the plan does not cover (another user's folder, Windows.old ...)
  foreach ($job in $sysExtra) {
    $n++
    Say-Info ('[{0}/{1}] {2}' -f $n, $jobCount, $job.Label)
    Send-KitEvent @{ t = 'job'; n = $n; of = $jobCount; label = $job.Label; expected = $job.EstimatedBytes }
    $src = Join-Path $srcRoot $job.Path.Substring(3)
    $ex = @($job.ExcludeAbs | Where-Object { $_ } | ForEach-Object { Join-Path $srcRoot $_.Substring(3) })
    $res = Invoke-KitCopy -Source $src -Destination (Join-Path $Destination $job.Dest) -ExcludeDirs $ex -Label $job.Label -ExpectedBytes $job.EstimatedBytes -BackupMode:$admin
    Write-CopyResult $res
    $copies += $res
  }
} finally {
  if ($snap) { Remove-KitSnapshot $snap }
}

# media server folders and folders ticked in the app on the other drives, each drive from
# its own snapshot so running databases and the HA disk are captured consistently
$otherJobs = @($msJobs) + @($extraJobs | Where-Object { $_.Path.Substring(0, 1).ToUpper() -ne $sysLetter })
foreach ($grp in @($otherJobs | Group-Object { $_.Path.Substring(0, 1).ToUpper() })) {
  $letter = $grp.Name
  $root = $letter + ':\'
  $vsnap = $null
  $isBackupDrive = ($Destination.Substring(0, 1).ToUpper() -eq $letter)
  if ($admin -and -not $TestMode) {
    try { $vsnap = New-KitSnapshot $root; $root = $vsnap.Link + '\'; Say-Ok ('Snapshot of {0}: ready' -f $letter) }
    catch { Say-Warn ('Snapshot of {0}: failed ({1}) - copying the live files instead.' -f $letter, $_.Exception.Message) }
  }
  try {
    foreach ($job in $grp.Group) {
      $n++
      Say-Info ('[{0}/{1}] {2}' -f $n, $jobCount, $job.Label)
      Send-KitEvent @{ t = 'job'; n = $n; of = $jobCount; label = $job.Label; expected = $job.EstimatedBytes }
      $src = Join-Path $root $job.Path.Substring(3)
      $dst = Join-Path $Destination $job.Dest
      $ex = @($job.ExcludeRel | Where-Object { $_ } | ForEach-Object { Join-Path $src $_ }) + @($job.ExcludeNames | Where-Object { $_ }) +
            @($job.ExcludeAbs | Where-Object { $_ } | ForEach-Object { Join-Path $root $_.Substring(3) })
      # never copy the backup into itself
      if ($isBackupDrive) { $ex += (Join-Path $root $Destination.Substring(3)) }
      $only = @{}
      if ($job.Files) { $only = @{ Files = @($job.Files); NoSubdirs = $true } }
      $res = Invoke-KitCopy -Source $src -Destination $dst -ExcludeDirs $ex -ExcludeFiles @($job.ExcludeFiles | Where-Object { $_ }) -Label $job.Label -ExpectedBytes $job.EstimatedBytes -BackupMode:$admin @only
      Write-CopyResult $res
      $copies += $res
    }
  } finally {
    if ($vsnap) { Remove-KitSnapshot $vsnap }
  }
}

Say-Step 'Step 3 of 3 - manifest, report and restore launcher'
$bytes = ($copies | Measure-Object -Property Bytes -Sum).Sum
$files = ($copies | Measure-Object -Property Files -Sum).Sum
$backupId = [guid]::NewGuid().ToString()
if ($previousManifest -and $previousManifest.BackupId) { $backupId = [string]$previousManifest.BackupId }
# folders ticked in the app keep coming back on later updates of the same backup
$extraList = New-Object System.Collections.Generic.List[object]
if ($previousManifest) { foreach ($x in @($previousManifest.ExtraFolders | Where-Object { $_ })) { $extraList.Add($x) } }
foreach ($j in $extraJobs) {
  if (@($extraList | Where-Object { $_.Path -ieq $j.Path }).Count) { continue }
  $extraList.Add([pscustomobject]@{ Path = $j.Path; Dest = $j.Dest; Bytes = $j.EstimatedBytes })
}
$manifest = [ordered]@{
  KitVersion         = $script:KitVersion
  BackupId           = $backupId
  CreatedAt          = (Get-Date).ToString('s')
  FirstCreatedAt     = $(if ($previousManifest -and $previousManifest.CreatedAt) { $(if ($previousManifest.FirstCreatedAt) { $previousManifest.FirstCreatedAt } else { $previousManifest.CreatedAt }) } else { (Get-Date).ToString('s') })
  TestMode           = [bool]$TestMode
  UsedSnapshot       = [bool]$snap
  System             = $inv.System
  Volumes            = $inv.Volumes
  Disks              = $inv.Disks
  Boot               = $inv.Boot
  RootFolders        = $inv.RootFolders
  ProgramDataRestore = @(Get-KitProgramDataTargets $inv)
  ProgramFilesRules  = $script:ProgramFilesRules
  ExtraFolders       = $extraList.ToArray()
  Selection          = $script:Sel
  Copies             = @($copies | ForEach-Object { [pscustomobject]@{ Label = $_.Label; Source = $_.Source; Destination = $_.Destination; Files = $_.Files; Bytes = $_.Bytes; ExitCode = $_.ExitCode; Errors = $_.Errors; Skipped = $_.Skipped } })
  Issues             = @($script:Issues)
}
Save-Json $manifest (Join-Path $Destination 'manifest.json')

Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination (New-Dir (Join-Path $Destination 'Engine')) -Recurse -Force
$restoreBat = Get-ChildItem -LiteralPath $KitRoot -Filter '3 - RESTORE*.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($restoreBat) { Copy-Item -LiteralPath $restoreBat.FullName -Destination (Join-Path $Destination 'RESTORE this backup.bat') -Force }
# the app travels with the backup, so the new PC only needs this folder
$appExe = if ($env:PCMK_APP_EXE) { $env:PCMK_APP_EXE } else { Join-Path $KitRoot 'PC Migration Kit.exe' }
if (Test-Path -LiteralPath $appExe) { Copy-Item -LiteralPath $appExe -Destination (Join-Path $Destination 'PC Migration Kit.exe') -Force }

$report = Join-Path $Destination 'Report.html'
try { New-KitReport $inv $report 'Backup' ([pscustomobject]@{ Path = $Destination; UsedSnapshot = [bool]$snap; Copies = $copies; Issues = @($script:Issues) }) }
catch { Say-Fail ('Could not write the report: ' + $_.Exception.Message) }

$mins = [int]((Get-Date) - $started).TotalMinutes
Say-Step 'Backup finished'
if ($files -gt 0) { Say ('  {0:N0} files copied ({1}) in {2} min' -f $files, (Format-Bytes $bytes), $mins) 'White' }
else { Say '  Everything was already up to date - no files needed copying.' 'White' }
Say ('  Saved to: {0}' -f $Destination) 'White'
if ($script:Issues.Count) { Say ('  {0} warning(s) - listed at the bottom of Report.html' -f $script:Issues.Count) 'Yellow' 'warn' }
else { Say '  No problems.' 'Green' 'ok' }
Say '  This folder contains Wi-Fi passwords and app tokens - keep it private.' 'Gray'
Send-KitEvent @{ t = 'summary'; path = $Destination; files = $files; bytes = $bytes; minutes = $mins; report = $report; issues = @($script:Issues) }
if (-not $NoPause) { Open-AsUser $report }
Exit-Kit 0 -NoPause:$NoPause
