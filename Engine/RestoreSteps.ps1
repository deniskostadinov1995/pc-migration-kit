<#
  PC Migration Kit - the restore steps
  ------------------------------------
  Every step RESTORE runs, as functions, so Restore.ps1 (the steps in order)
  and Verify.ps1 (puts back single items that went missing later) share them.

  The caller sets up the backup first (Initialize-KitBackup) and may pass a
  selection (Read-KitSelection) - then only the ticked items are restored.
  $DryRun / $NoPause come from the calling script.

  Written by Claude 2026-09-27, split out of Restore.ps1 on 2026-10-02.
#>

$script:NeedReboot = $false
$script:Missing = New-Object System.Collections.Generic.List[string]
$script:ClosedApps = $false
$script:SkipNewer = $false

# ------------------------------------------------------------ helpers ------
function P([string]$Rel) { return (Join-Path $script:B $Rel) }

function Add-Missing([string]$Text) { if (-not $script:Missing.Contains($Text)) { $script:Missing.Add($Text) } }

# Finds the backup and reads what RESTORE needs from it. $KitRoot is the folder
# the kit (or the backup itself) sits in.
function Initialize-KitBackup([string]$BackupPath, [string]$KitRoot, [switch]$Pick) {
  if ($BackupPath) { $script:B = (Resolve-Path -LiteralPath $BackupPath).Path }
  elseif (Test-Path -LiteralPath (Join-Path $KitRoot 'manifest.json')) { $script:B = $KitRoot }
  else {
    $cands = @(Get-ChildItem -LiteralPath (Join-Path $KitRoot 'Backups') -Directory -ErrorAction SilentlyContinue |
               Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending)
    if (-not $cands.Count) { return $false }
    $script:B = $cands[0].FullName
    if ($Pick -and $cands.Count -gt 1 -and -not $NoPause -and -not $script:Gui) {
      for ($i = 0; $i -lt $cands.Count; $i++) { Say ('  {0}) {1}' -f ($i + 1), $cands[$i].Name) 'White' }
      $a = Read-Host '  Which backup? (ENTER = 1, the newest)'
      if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $cands.Count) { $script:B = $cands[[int]$a - 1].FullName }
    }
  }
  $script:M = Read-Json (P 'manifest.json')
  if (-not $script:M) { return $false }
  $script:OldProfile = [string]$script:M.System.UserProfile
  $script:NewProfile = $env:USERPROFILE
  $script:OldSysDrive = [string]$script:M.System.SystemDrive
  $script:SrcProfile = P ('files\C\' + $script:OldProfile.Substring(3))
  $script:MsFacts = Read-Json (P 'settings\mediaserver\mediaserver.json')
  $script:StateDir = New-Dir (Join-Path $env:ProgramData 'PCMigrationKit')
  return $true
}

# First run of a step: the backup wins (it replaces fresh-install defaults).
# Any later run: files that are newer on this PC are kept, so work done since
# the first restore is never rolled back. In a renamed account the settings
# files and shortcuts just copied get the new profile path.
# Folders the person unticked in the app (Files.ExcludeRel, relative to the
# backup) are left out.
function Restore-Tree([string]$Src, [string]$Dst, [string]$Label, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @(), [string[]]$Files = @('*.*'), [switch]$NoSubdirs, [switch]$MergeOnly) {
  if (-not (Test-Path -LiteralPath $Src)) { return }
  $excludes = @(Get-KitRestoreExcludes)
  if ($excludes.Count -and (Test-KitUnder $Src $excludes)) { Say-Info ('{0}: not selected - skipped' -f $Label); return }
  $ExcludeDirs = @($ExcludeDirs) + @($excludes | Where-Object { Test-KitUnder $_ @($Src) })
  if ($DryRun) { Say ('  [dry-run] copy {0}  ->  {1}{2}' -f $Src, $Dst, $(if ($MergeOnly) { '  (only files not there yet)' } elseif ($script:SkipNewer) { '  (keeping newer files)' } else { '' })) 'DarkGray'; return }
  $collect = if (Get-KitRename) { $script:PathFixFiles } else { $null }
  $r = Invoke-KitCopy -Source $Src -Destination $Dst -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles -Label $Label -Files $Files -NoSubdirs:$NoSubdirs -SkipNewer:$script:SkipNewer -MergeOnly:$MergeOnly -Threads 8 -Collect $collect
  Write-CopyResult $r
  Update-KitCopiedFiles $r
}

# Folders inside the backup that the person chose not to restore, as full paths.
function Get-KitRestoreExcludes {
  if ($null -ne $script:RestoreExcludes) { return $script:RestoreExcludes }
  $script:RestoreExcludes = @(Get-KitSelList 'Files' 'ExcludeRel' | ForEach-Object { P $_ })
  return $script:RestoreExcludes
}

function Get-FreeLetter([string[]]$Avoid) {
  $used = @(Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter.Substring(0, 1).ToUpper() })
  $used += @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpper() })
  foreach ($c in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') { $l = [string]$c; if ($used -notcontains $l -and $Avoid -notcontains $l) { return $l } }
  return $null
}

function Set-VolumeLetter([string]$DeviceId, [string]$Letter) {
  $v = Get-CimInstance Win32_Volume -Filter ("DeviceID='{0}'" -f $DeviceId.Replace('\', '\\'))
  Set-CimInstance -InputObject $v -Property @{ DriveLetter = ($Letter + ':') } -ErrorAction Stop
}

# Registry PATH changes don't reach an already running process; re-read them so
# later steps (e.g. tasks that run "pythonw") can find what was just restored.
function Update-ProcessPath {
  $parts = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }
  if ($parts) { $env:Path = ($parts -join ';') }
}

# Internal drives of the old PC (USB sticks and the installer drive are not part of the setup).
function Get-KitBackupVolumes { @($script:M.Volumes | Where-Object { $_ -and -not $_.IsSystemDrive -and $_.DriveType -eq 3 -and $_.BusType -ne 'USB' }) }

# ----------------------------------------------------- step 1: letters -----
function Restore-DriveLetters {
  $want = @(Get-KitBackupVolumes | Where-Object { Test-KitSelected 'Letters' $_.Letter })
  if (-not $want.Count) { Say-Info 'No extra drives in the backup.'; return }
  $vols = @(Get-CimInstance Win32_Volume)
  $parts = @(Get-Partition -ErrorAction SilentlyContinue)
  $sys = $env:SystemDrive.Substring(0, 1).ToUpper()
  $moves = @()
  foreach ($w in $want) {
    $match = $null
    if ($w.PartitionGuid) {
      $p = $parts | Where-Object { [string]$_.Guid -eq $w.PartitionGuid } | Select-Object -First 1
      if ($p) { $match = $vols | Where-Object { $p.AccessPaths -contains $_.DeviceID } | Select-Object -First 1 }
    }
    if (-not $match -and $w.SerialNumber) { $match = $vols | Where-Object { $_.SerialNumber -eq $w.SerialNumber } | Select-Object -First 1 }
    if (-not $match) { Say-Warn ('{0}: ({1}, {2}) is not connected - plug it in and run this step again.' -f $w.Letter, $w.Label, $w.DiskModel); continue }
    $cur = $null
    if ($match.DriveLetter) { $cur = $match.DriveLetter.Substring(0, 1).ToUpper() }
    if ($cur -eq $sys) { Say-Warn ('The partition that used to be {0}: is now the Windows drive - skipped.' -f $w.Letter); continue }
    if ($cur -eq $w.Letter) { Say-Ok ('{0}: {1} - already correct' -f $w.Letter, $w.Label); continue }
    $moves += [pscustomobject]@{ DeviceId = $match.DeviceID; From = $cur; To = [string]$w.Letter; Label = $w.Label }
  }
  if (-not $moves.Count) { return }
  $targets = @($moves | ForEach-Object { $_.To })
  $movingIds = @($moves | ForEach-Object { $_.DeviceId })

  # 1) park every volume that has to move on a temporary letter (handles swaps like D<->E)
  foreach ($m in @($moves | Where-Object { $_.From })) {
    $tmp = Get-FreeLetter ($targets)
    [void](Invoke-Change ('Temporarily move {0}: ({1}) to {2}:' -f $m.From, $m.Label, $tmp) { Set-VolumeLetter $m.DeviceId $tmp })
  }
  # 2) move anything else that sits on a letter we need (USB sticks, the old SSD ...)
  foreach ($t in $targets) {
    $occ = Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter.Substring(0, 1).ToUpper() -eq $t } | Select-Object -First 1
    if ($occ -and ($movingIds -notcontains $occ.DeviceID)) {
      $tmp = Get-FreeLetter ($targets)
      [void](Invoke-Change ('Move {0}: ({1}) out of the way to {2}:' -f $t, $occ.Label, $tmp) { Set-VolumeLetter $occ.DeviceID $tmp })
    }
  }
  # 3) final letters
  foreach ($m in $moves) {
    [void](Invoke-Change ('{0} -> {1}:' -f $m.Label, $m.To) { Set-VolumeLetter $m.DeviceId $m.To })
  }
}

# ---------------------------------------------------- step 2: features -----
function Restore-Features {
  $f = Read-Json (P 'settings\system\features.json')
  if (-not $f -or -not $f.Features) { Say-Info 'The backup has no list of Windows features.'; return }
  if (-not (Test-IsAdmin)) { Say-Info 'Windows features can only be read with administrator rights - skipped in this run.'; return }
  Say-Info 'Checking Windows features (takes a moment)...'
  $now = @{}
  Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | ForEach-Object { $now[$_.FeatureName] = [string]$_.State }
  $todo = @($f.Features | Where-Object { $now.ContainsKey($_) -and $now[$_] -ne 'Enabled' -and (Test-KitSelected 'Features' $_) })
  # SMB1 stays off on purpose - a note, not a problem that keeps the step "to do" forever
  if ($todo -match '^SMB1Protocol') { Say-Info 'SMB1 was on in the old Windows. It is insecure and was left off on purpose - turn it on yourself only if an old device needs it.' }
  $todo = @($todo | Where-Object { $_ -notmatch '^SMB1Protocol' })
  if (-not $todo.Count) { Say-Ok 'All features you used are already on.'; return }
  foreach ($x in $todo) {
    [void](Invoke-Change "Turn on Windows feature: $x" {
      $r = Enable-WindowsOptionalFeature -Online -FeatureName $x -All -NoRestart -WarningAction SilentlyContinue
      if ($r.RestartNeeded) { $script:NeedReboot = $true }
    })
  }
}

# -------------------------------------------------------- step 3: apps -----
function Get-InstallList {
  $file = P 'settings\apps\install-list.txt'
  if (-not (Test-Path -LiteralPath $file)) { return @() }
  @(Get-Content -LiteralPath $file -Encoding UTF8 | ForEach-Object {
    $line = [string]$_
    $l = ($line -replace '#.*$', '').Trim()
    if (-not $l) { return }
    $a = $l -split '\s+'
    # notes after the #:  "version 24.14.1; matched by name: Node.js"
    $name = $null; $ver = $null
    $m = [regex]::Match($line, 'matched by name:\s*([^;]+?)\s*(;|$)')
    if ($m.Success) { $name = $m.Groups[1].Value }
    $m = [regex]::Match($line, '#.*?\bversion\s+([^\s;]+)')
    if ($m.Success) { $ver = $m.Groups[1].Value }
    [pscustomobject]@{ Id = $a[0]; Source = $(if ($a.Count -gt 1) { $a[1] } else { $null }); Name = $name; Version = $ver }
  })
}

# Visual Studio installs come back bare from winget; hand the installer the
# .vsconfig saved at backup time so the same workloads are selected.
function Get-VsConfigFor([string]$Id) {
  if ($Id -notmatch '^Microsoft\.VisualStudio\.(?:(\d{4})\.)?(BuildTools|Community|Professional|Enterprise)$') { return $null }
  $year = $Matches[1]; $product = $Matches[2]
  $channel = '18'
  if ($year) { $channel = @{ '2017' = '15'; '2019' = '16'; '2022' = '17' }[$year] }
  if (-not $channel) { return $null }
  $src = P ('settings\apps\vs\{0}-{1}.vsconfig' -f $product, $channel)
  if (-not (Test-Path -LiteralPath $src)) { return $null }
  $dst = Join-Path $env:ProgramData ('PCMigrationKit\{0}-{1}.vsconfig' -f $product, $channel)   # a path without spaces for --override
  if (-not $DryRun) { New-Dir (Split-Path $dst -Parent) | Out-Null; Copy-Item -LiteralPath $src -Destination $dst -Force }
  return $dst
}

# Language runtimes come back at the version the old PC had: on 2026-09-29 winget
# put Node.js 26 in place of 24, and Small Panda's native database module (built
# for 24) stopped loading. Everything else gets the newest version.
$script:KitRuntimes = @(
  @{ Id = '^OpenJS\.NodeJS(\.LTS)?$';                 Name = '^Node\.js$';                               Hint = 'Node projects with native add-ons may need "npm rebuild"' }
  @{ Id = '^Python\.Python\.\d+(\.\d+)?$';            Name = '^Python \d+\.\d+\.\d+ \((64|32)-bit\)$';   Hint = 'virtual environments may need to be created again' }
  @{ Id = '^(Oracle\.JDK\.\d+|EclipseAdoptium\.Temurin\.\d+\.(JDK|JRE)|Microsoft\.OpenJDK\.\d+)$'; Name = '^(Java\(TM\) SE Development Kit|Eclipse Temurin|Microsoft Build of OpenJDK)'; Hint = 'Java programs may need the old version' }
  @{ Id = '^GoLang\.Go$';                             Name = '^Go Programming Language';                 Hint = '' }
)

function Get-KitOldVersion($App, $Programs) {
  foreach ($rt in $script:KitRuntimes) {
    if ($App.Id -notmatch $rt.Id) { continue }
    if ($App.Version) { return [pscustomobject]@{ Version = $App.Version; Hint = $rt.Hint } }
    $hit = @($Programs | Where-Object { $_.Name -match $rt.Name -or ($App.Name -and $_.Name -eq $App.Name) }) | Select-Object -First 1
    if ($hit -and $hit.Version) { return [pscustomobject]@{ Version = [string]$hit.Version; Hint = $rt.Hint } }
  }
  return $null
}

# What a winget exit code means, in words.
function Get-KitWingetReason([int]$Code) {
  switch ($Code) {
    -2145844844 { return 'its download link is broken at the vendor (HTTP 404) - install it from the maker''s website' }
    -1978335215 { return 'the installer changed after winget''s record of it was made (hash mismatch) - try again in a day or two, or install it from the maker''s website' }
    -1978335216 { return 'there is no installer for this Windows or processor' }
    -1978335212 { return 'winget does not know this package (any more)' }
    -1978334975 { return 'the program is open - close it and try again' }
    -1978334972 { return 'not enough disk space' }
    -1978334969 { return 'no internet connection' }
    -1978335226 { return 'its installer failed' }
    default     { return ('winget code {0}' -f $Code) }
  }
}

# Is a program with this name (as Apps & Features shows it) installed?
function Test-KitProgramInstalled([string]$Name) {
  if (-not $Name) { return $false }
  $want = (($Name -replace '\s*\((64-bit|32-bit|x64|x86|remove only)\)', '') -replace '\s+v?\d+(\.\d+){1,3}\b.*$', '').Trim()
  foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
    foreach ($e in Get-ItemProperty "$root\*" -ErrorAction SilentlyContinue) {
      $n = [string]$e.DisplayName
      if (-not $n) { continue }
      $c = (($n -replace '\s*\((64-bit|32-bit|x64|x86|remove only)\)', '') -replace '\s+v?\d+(\.\d+){1,3}\b.*$', '').Trim()
      if ($c -ieq $want) { return $true }
    }
  }
  return $false
}

# The name a winget package goes by ("Revo Uninstaller Pro" for XP8JG6MNM5Z4X1), cached.
$script:KitWingetNames = @{}
function Get-KitWingetPackageName([string]$Id, [string]$Source) {
  if (-not $Id) { return $null }
  if ($script:KitWingetNames.ContainsKey($Id)) { return $script:KitWingetNames[$Id] }
  $a = 'show --id {0} --exact --accept-source-agreements --disable-interactivity' -f $Id
  if ($Source) { $a += ' --source ' + $Source }
  $r = Invoke-Native 'winget.exe' $a
  # first line: "Found Revo Uninstaller Pro [XP8JG6MNM5Z4X1]" ("Found" is localized)
  $m = [regex]::Match($r.StdOut, '(?m)^\S+ (.+?) \[' + [regex]::Escape($Id) + '\]')
  $name = $null
  if ($m.Success) { $name = $m.Groups[1].Value.Trim() }
  $script:KitWingetNames[$Id] = $name
  return $name
}

function Test-KitWingetInstalled([string]$Id) {
  $r = Invoke-Native 'winget.exe' ('list --id {0} --exact --accept-source-agreements --disable-interactivity' -f $Id)
  return ($r.ExitCode -eq 0)
}

$script:KitAntivirus = '(?i)\b(AVG|Avast|Norton|McAfee|Kaspersky|ESET|Malwarebytes|Bitdefender|Avira|Sophos|Panda Dome|Trend Micro)\b'

function Install-KitWingetApp([string]$Id, [string]$Source, [string]$Version, [string]$VsConfig, [string]$Label) {
  $wargs = @('install', '--id', $Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
  if ($Source) { $wargs += @('--source', $Source) }
  if ($Version) { $wargs += @('--version', $Version) }
  if ($VsConfig) { $wargs += @('--override', ('--passive --wait --norestart --config ' + $VsConfig)) }
  Write-KitLog ('winget ' + ($wargs -join ' '))
  if ($script:Gui) {
    # winget's spinner and progress bars are no use as text lines
    & winget @wargs 2>&1 | ForEach-Object {
      $s = ([string]$_).Trim()
      if ($s -and $s -notmatch '^[\s\-\\\|/]+$' -and $s.IndexOf([char]0x2588) -lt 0 -and $s.IndexOf([char]0x2592) -lt 0) { Send-KitEvent @{ t = 'raw'; text = $s } }
    }
  }
  else { & winget @wargs }
  return $LASTEXITCODE
}

function Restore-Apps {
  $list = @(Get-InstallList)
  $appsJson = Read-Json (P 'settings\apps\apps.json')
  $programs = @(); if ($appsJson) { $programs = @($appsJson.Programs) }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    [void](Invoke-Change 'Register winget (App Installer)' { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe })
    $env:Path = $env:Path + ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
  }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Say-Fail 'winget is not available yet. Open Microsoft Store, update "App Installer", then run RESTORE again and pick step 3.'
    return
  }
  $have = @{}
  $tmp = Join-Path $env:TEMP ('pcmk-installed-{0}.json' -f (Get-Random))
  $null = & winget export -o $tmp --accept-source-agreements --disable-interactivity 2>&1
  $j = Read-Json $tmp
  if ($j) { foreach ($s in $j.Sources) { foreach ($pk in $s.Packages) { $have[$pk.PackageIdentifier] = $true } } }
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

  $okCodes = @(0, -1978335189, -1978334963)            # installed / already there / already installed
  $rebootCodes = @(-1978334967, -1978334966, 3010, 1641)
  $i = 0; $failed = @()
  $todo = @($list | Where-Object { Test-KitSelected 'Apps' $_.Id })
  $skippedSel = $list.Count - $todo.Count
  if ($skippedSel) { Say-Info ('{0} app(s) not selected - skipped' -f $skippedSel) }
  foreach ($a in $todo) {
    $i++
    Show-KitProgress 'Installing apps' ('{0} of {1}: {2}' -f $i, $todo.Count, $a.Id) ([int](100 * ($i - 1) / [Math]::Max(1, $todo.Count)))
    if ($have.ContainsKey($a.Id)) { Say-Ok ('{0} already installed' -f $a.Id); continue }
    if ($a.Source -eq 'msstore') {
      # the same program can be listed twice - under its winget id and its Store id (Revo Uninstaller Pro)
      $wn = Get-KitWingetPackageName $a.Id $a.Source
      if ($wn -and (Test-KitProgramInstalled $wn)) { Say-Ok ('{0} ({1}) already installed' -f $wn, $a.Id); continue }
    }
    $vsConfig = Get-VsConfigFor $a.Id
    $old = Get-KitOldVersion $a $programs
    if ($DryRun) { Say ('  [dry-run] winget install {0}{1}{2}' -f $a.Id, $(if ($old) { ' --version ' + $old.Version } else { '' }), $(if ($vsConfig) { '  (with workloads from ' + $vsConfig + ')' } else { '' })) 'DarkGray'; continue }
    Say ('  -> ({0}/{1}) installing {2} ...' -f $i, $todo.Count, $a.Id) 'White' 'info'
    $code = $null
    if ($old) {
      $code = Install-KitWingetApp $a.Id $a.Source $old.Version $vsConfig $a.Id
      if ($okCodes -contains $code -or $rebootCodes -contains $code) { Say-Info ('{0}: the same version as before ({1})' -f $a.Id, $old.Version) }
      else {
        Say-Warn ('{0} {1} (the version the old PC had) is not available any more - installing the newest instead. {2}.' -f $a.Id, $old.Version, $old.Hint)
        $code = $null
      }
    }
    if ($null -eq $code) { $code = Install-KitWingetApp $a.Id $a.Source $null $vsConfig $a.Id }
    if ($okCodes -contains $code) { Say-Ok ('{0} installed' -f $a.Id) }
    elseif ($rebootCodes -contains $code) { Say-Ok ('{0} installed (needs a restart)' -f $a.Id); $script:NeedReboot = $true }
    elseif ((Test-KitWingetInstalled $a.Id) -or ($a.Name -and (Test-KitProgramInstalled $a.Name))) { Say-Ok ('{0} is installed already (not through winget)' -f $a.Id) }
    else { Say-Warn ('{0} did not install: {1}. Later: winget install --id {0}' -f $a.Id, (Get-KitWingetReason $code)); $failed += $a.Id }
  }
  Show-KitProgress 'Installing apps' '' -Completed

  # Microsoft Store apps: best effort through winget's msstore source
  $store = @()
  if ($appsJson -and $appsJson.StoreApps) { $store = @($appsJson.StoreApps | Where-Object { $_ -and $_.Name -and $_.Name -notmatch '(?i)NVIDIA|Realtek|Intel' -and (Test-KitSelected 'Apps' ('store:' + $_.PackageName)) }) }
  foreach ($s in $store) {
    if (Get-AppxPackage -Name $s.PackageName -ErrorAction SilentlyContinue) { Say-Ok ('{0} already installed' -f $s.Name); continue }
    if ($DryRun) { Say ('  [dry-run] Microsoft Store: {0}' -f $s.Name) 'DarkGray'; continue }
    Say ('  -> installing {0} from the Microsoft Store ...' -f $s.Name) 'White' 'info'
    $wargs = @('install', '--name', $s.Name, '--exact', '--source', 'msstore', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($script:Gui) { & winget @wargs 2>&1 | Out-Null } else { & winget @wargs }
    if ($okCodes -contains $LASTEXITCODE) { Say-Ok ('{0} installed' -f $s.Name) }
    else { Say-Warn ('{0}: install it from Microsoft Store -> Library, then run step 5 again for its data' -f $s.Name); $failed += $s.Name }
  }

  # Programs BACKUP found no installer for: look again (winget learns new apps, and
  # "Hard Disk Sentinel PRO" is "Hard Disk Sentinel Professional" there).
  $manual = @()
  if ($appsJson -and $appsJson.Plan -and $appsJson.Plan.Manual) { $manual = @($appsJson.Plan.Manual | Where-Object { $_ -and $_.Name -and (Test-KitSelected 'Apps' ('manual:' + $_.Name)) }) }
  foreach ($m in $manual) {
    if (Test-KitProgramInstalled $m.Name) { Say-Ok ('{0} already installed' -f $m.Name); continue }
    if ($m.Name -match $script:KitAntivirus) { Add-Missing ('{0}: antivirus programs are left to you - Windows Security protects the PC meanwhile' -f $m.Name); continue }
    $hit = Find-KitAppByName $m.Name
    if (-not $hit) { Add-Missing ('Install by hand: {0}{1}' -f $m.Name, $(if ($m.Version -and $m.Name -notlike ('*' + $m.Version + '*')) { ' ' + $m.Version } else { '' })); continue }
    if ($DryRun) { Say ('  [dry-run] winget install {0} ({1}, found by name for "{2}")' -f $hit.Id, $hit.Source, $m.Name) 'DarkGray'; continue }
    Say ('  -> installing {0} ({1}, found by name) ...' -f $m.Name, $hit.Id) 'White' 'info'
    $code = Install-KitWingetApp $hit.Id $hit.Source $null $null $m.Name
    if ($okCodes -contains $code -or $rebootCodes -contains $code -or (Test-KitProgramInstalled $m.Name)) { Say-Ok ('{0} installed ({1})' -f $m.Name, $hit.Id); if ($rebootCodes -contains $code) { $script:NeedReboot = $true } }
    else { Say-Warn ('{0} ({1}) did not install: {2}' -f $m.Name, $hit.Id, (Get-KitWingetReason $code)); $failed += $m.Name }
  }
  if ($failed.Count) { Add-Missing ('Apps that failed to install: ' + ($failed -join ', ')) }
}

# ------------------------------------------ before copying: close things ---
function Stop-KitApps {
  if ($script:ClosedApps) { return }
  $script:ClosedApps = $true
  Say-Info 'Closing programs and services that would lock the files about to be restored...'
  # only services whose files are about to be overwritten: ProgramData app folders, the profile, your C:\ folders
  $svcNames = New-Object System.Collections.Generic.List[string]
  foreach ($t in $script:M.ProgramDataRestore) { foreach ($s in $t.Services) { $svcNames.Add($s) } }
  $dataRoots = @($env:ProgramData, $script:NewProfile) + @($script:M.RootFolders | ForEach-Object { Join-Path ($env:SystemDrive + '\') $_ })
  foreach ($s in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) {
    $pn = ([string]$s.PathName).Replace('/', '\')
    if ($pn -match '(?i)\\ProgramData\\Microsoft\\') { continue }   # Windows Defender and friends
    if (@($dataRoots | Where-Object { $_ -and $pn.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count) { $svcNames.Add($s.Name) }
  }
  $dontTouch = '(?i)AVG|Avast|Norton|McAfee|Kaspersky|ESET|Malwarebytes|Bitdefender|Defender|NVIDIA'
  $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $svcNames -contains $_.Name -and $_.Status -eq 'Running' -and ($_.Name + ' ' + $_.DisplayName) -notmatch $dontTouch })

  $protect = @('explorer', 'powershell', 'pwsh', 'cmd', 'conhost', 'WindowsTerminal', 'OpenConsole', 'dwm', 'ctfmon', 'sihost', 'svchost',
               'RuntimeBroker', 'SearchApp', 'SearchUI', 'ShellExperienceHost', 'StartMenuExperienceHost', 'TextInputHost', 'SystemSettings',
               'ApplicationFrameHost', 'taskhostw', 'fontdrvhost', 'dllhost', 'backgroundTaskHost', 'LockApp', 'robocopy', 'winget', 'AppInstallerCLI',
               'claude', 'Claude', 'PC Migration Kit')
  $ancestors = @()
  $cur = $PID
  for ($n = 0; $n -lt 10 -and $cur; $n++) {
    $ancestors += $cur
    $cur = (Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue).ParentProcessId
  }
  $roots = @((Join-Path $script:NewProfile 'AppData'), $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}) +
           @($script:M.RootFolders | ForEach-Object { Join-Path ($env:SystemDrive + '\') $_ })
  $mySession = (Get-Process -Id $PID).SessionId
  $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $pth = $_.Path
    $pth -and $_.SessionId -eq $mySession -and $ancestors -notcontains $_.Id -and $protect -notcontains $_.ProcessName -and
    $pth -notmatch '\\WindowsApps\\' -and $pth -notmatch '(?i)\\(AVG|Avast|Norton|McAfee|Kaspersky|ESET|Malwarebytes|Bitdefender)' -and
    (@($roots | Where-Object { $_ -and $pth.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
  })
  if ($procs.Count) {
    $names = @($procs | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    Say-Info ('Programs to close: ' + ($names -join ', '))
    $close = $true
    if (-not $DryRun -and -not $NoPause) {
      $ans = Read-KitAnswer 'closeapps' 'These programs keep files open that are about to be restored. Save any open work in them, then continue - they will be closed.' 'close' @('close', 'keep') $names
      if (-not $script:Gui -and $ans -eq '') { $ans = 'close' }
      $close = ($ans -ne 'keep')
    }
    if ($close) { [void](Invoke-Change ('Close {0} program(s)' -f $procs.Count) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue }) }
    else { Say-Info 'Programs left open - files they use may be skipped (run this step again later to fill them in).' }
  }
  if ($services.Count) { [void](Invoke-Change ('Stop services: ' + (($services | ForEach-Object { $_.Name }) -join ', ')) { $services | Stop-Service -Force -ErrorAction SilentlyContinue }) }
  if (Test-Path -LiteralPath (Join-Path $env:windir 'System32\wsl.exe')) { [void](Invoke-Change 'Shut down WSL (frees the Docker and Linux disk files)' { $null = & wsl.exe --shutdown 2>&1 }) }
}

# ------------------------------------------------------- step 4: files -----
# Files in the profile that belong to a program that is running right now and
# would be broken by an older copy: the sign-in of Claude Code. They are only put
# back when this PC does not have them yet.
$script:KitProfileMergeOnly = @('.claude\.credentials.json', '.claude.json')
# Windows' own stores - locked while Windows runs, and rebuilt by it.
$script:KitProfileNeverRestore = @('AppData\Local\Comms', 'AppData\Local\ConnectedDevicesPlatform', 'AppData\Local\Microsoft', 'AppData\Roaming\Microsoft', 'AppData\LocalLow\Microsoft', 'AppData\Local\Packages')

function Restore-Files {
  Stop-KitApps
  $shellNames = @{ Desktop = 'Desktop'; Documents = 'Personal'; Pictures = 'My Pictures'; Music = 'My Music'; Videos = 'My Video'; Downloads = '{374DE290-123F-4565-9164-39C4925E467B}' }
  $nowKnown = Get-KnownFolderMap
  foreach ($name in 'Desktop', 'Documents', 'Pictures', 'Music', 'Downloads', 'Videos') {
    $src = P "files\KnownFolders\$name"
    if (Test-Path -LiteralPath $src) { Restore-Tree $src $nowKnown[$name] "Your $name folder"; continue }
    # the old folder lived on another drive: point Windows at it again
    $old = [string]$script:M.System.KnownFolders.$name
    if ($old -and -not $old.StartsWith($script:OldSysDrive, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $old) -and $old -ne $nowKnown[$name]) {
      [void](Invoke-Change "Point your $name folder at $old" {
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name $shellNames[$name] -Value $old -Type ExpandString
      })
    }
  }
  $src = $script:SrcProfile
  $skip = @($script:KitProfileNeverRestore | ForEach-Object { Join-Path $src $_ })
  $mergeFiles = @($script:KitProfileMergeOnly | Where-Object { Test-Path -LiteralPath (Join-Path $src $_) -PathType Leaf })
  $exFiles = @($mergeFiles | ForEach-Object { Join-Path $src $_ })
  Restore-Tree $src $script:NewProfile 'Your profile (AppData, app settings, dot-folders)' -ExcludeDirs $skip -ExcludeFiles $exFiles
  foreach ($f in $mergeFiles) {
    $dir = Split-Path $f -Parent
    Restore-Tree (Join-Path $src $dir) (Join-Path $script:NewProfile $dir) ('{0} (only if this PC has none yet)' -f $f) -Files @(Split-Path $f -Leaf) -NoSubdirs -MergeOnly
  }
  # the useful parts of the Microsoft folders
  foreach ($rel in 'AppData\Roaming\Microsoft\Windows\Start Menu', 'AppData\Roaming\Microsoft\Windows\SendTo', 'AppData\Roaming\Microsoft\Windows\PowerShell',
                   'AppData\Roaming\Microsoft\Signatures', 'AppData\Roaming\Microsoft\Templates', 'AppData\Roaming\Microsoft\UProof') {
    $ex = @(Join-Path $src 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup')
    Restore-Tree (Join-Path $src $rel) (Join-Path $script:NewProfile $rel) ($rel -replace '^AppData\\Roaming\\Microsoft\\', '') -ExcludeDirs $ex
  }
  $pub = P 'files\C\Users\Public'
  Restore-Tree $pub (Join-Path (Split-Path $script:NewProfile -Parent) 'Public') 'Public folders' -ExcludeDirs @(Join-Path $pub 'Desktop')
  foreach ($r in $script:M.RootFolders) { Restore-Tree (P "files\C\$r") (Join-Path ($env:SystemDrive + '\') $r) "$env:SystemDrive\$r" }
}

# ----------------------------------------------------- step 5: app data -----
function Test-KitPackageRunning([string]$FamilyName) {
  $parts = $FamilyName -split '_'
  if ($parts.Count -lt 2) { return $false }
  $name = $parts[0]; $pub = $parts[-1]
  return [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -match ('(?i)\\WindowsApps\\' + [regex]::Escape($name) + '_[^\\]*__' + [regex]::Escape($pub) + '\\') } | Select-Object -First 1)
}

function Restore-AppData {
  Stop-KitApps
  foreach ($t in $script:M.ProgramDataRestore) {
    $src = P "files\C\ProgramData\$($t.Folder)"
    if (-not (Test-Path -LiteralPath $src)) { continue }
    foreach ($sn in $t.Services) {
      $s = Get-Service -Name $sn -ErrorAction SilentlyContinue
      if ($s -and $s.Status -eq 'Running') { [void](Invoke-Change "Stop service $sn" { Stop-Service -Name $sn -Force }) }
    }
    Restore-Tree $src (Join-Path $env:ProgramData $t.Folder) "ProgramData\$($t.Folder)"
  }
  foreach ($rule in $script:M.ProgramFilesRules) {
    $src = P ('files\C\' + $rule.Rel)
    $dst = Join-Path ($env:SystemDrive + '\') $rule.Rel
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if (-not (Test-Path -LiteralPath $dst)) {
      # the app may have come back in the other Program Files folder
      $other = $null
      if ($dst.StartsWith(${env:ProgramFiles(x86)}, [StringComparison]::OrdinalIgnoreCase)) { $other = $env:ProgramFiles + $dst.Substring(${env:ProgramFiles(x86)}.Length) }
      elseif ($dst.StartsWith($env:ProgramFiles, [StringComparison]::OrdinalIgnoreCase)) { $other = ${env:ProgramFiles(x86)} + $dst.Substring($env:ProgramFiles.Length) }
      if ($other -and (Test-Path -LiteralPath $other)) { $dst = $other }
      else { Say-Info ('{0}: the app is not installed yet - install it, then run step 5 again.' -f $rule.Name); Add-Missing ('Re-run step 5 after installing: ' + $rule.Name); continue }
    }
    foreach ($pn in $rule.Processes) { Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    foreach ($d in $rule.Dirs) { Restore-Tree (Join-Path $src $d) (Join-Path $dst $d) ('{0} - {1}' -f $rule.Name, $d) }
    # never the old installer's own records (unins000.dat): the new install's uninstaller needs its own
    if (@($rule.Files).Count) { Restore-Tree $src $dst $rule.Name -Files @($rule.Files) -NoSubdirs -ExcludeFiles @('unins*.*') }
  }
  # data of Store / packaged apps that are installed again
  $pkgs = Join-Path $script:SrcProfile 'AppData\Local\Packages'
  $notYet = @()
  foreach ($d in Get-ChildItem -LiteralPath $pkgs -Directory -ErrorAction SilentlyContinue) {
    if ($d.Name -match '^(Microsoft|MicrosoftWindows|windows|Windows)\.' -or $d.Name -match '^(c5e2524a|E2A4F912|F46D4000|1527c705|DesktopView|InputApp|MicrosoftCorporationII)') { continue }
    $dst = Join-Path $script:NewProfile "AppData\Local\Packages\$($d.Name)"
    if (-not (Test-Path -LiteralPath $dst)) { $notYet += $d.Name; continue }
    # The Claude app keeps its list of chats in here, next to its sign-in and settings.
    # It is open while this runs (it may be what started RESTORE), so the old list is
    # added to the new one - chats, projects, Cowork sessions - and nothing it has now
    # is replaced. On 2026-09-29 this folder was held back by hand, and the 53 old
    # chats never showed up in the app.
    $merge = ($d.Name -like 'Claude_*') -or (Test-KitPackageRunning $d.Name)
    if ($merge -and $d.Name -notlike 'Claude_*') { Say-Info ('{0} is running - only its files this PC does not have yet are added.' -f $d.Name) }
    foreach ($sub in 'LocalState', 'LocalCache', 'RoamingState') {
      $ex = @()
      if ($d.Name -like 'Claude_*') { $ex = @('Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'Crashpad', 'sentry', 'logs', 'blob_storage', 'Shared Dictionary', 'VideoDecodeStats') | ForEach-Object { Join-Path $d.FullName "$sub\Roaming\Claude\$_" } }
      Restore-Tree (Join-Path $d.FullName $sub) (Join-Path $dst $sub) ("Store app data: $($d.Name) $sub") -ExcludeDirs $ex -MergeOnly:$merge
    }
  }
  if ($notYet.Count) { Say-Info ('Store apps not installed yet (their data will be restored if you run step 5 again after installing them): ' + ($notYet -join ', ')) }
  # the classic (non-Store) Claude app keeps the same things in Roaming\Claude
  $roamClaude = Join-Path $script:SrcProfile 'AppData\Roaming\Claude'
  if (Test-Path -LiteralPath $roamClaude) { Restore-Tree $roamClaude (Join-Path $script:NewProfile 'AppData\Roaming\Claude') 'Claude app (chat list, settings)' -MergeOnly }
}

# ----------------------------------------------------- step 6: registry -----
# Keys that only make sense on the PC that wrote them (integrity checks, crash
# counters, an updater's own state). Importing them did nothing useful at best;
# Chrome would even treat its settings as tampered with and reset them.
$script:KitRegSkip = @(
  'HKEY_CURRENT_USER\Software\Google\Chrome\PreferenceMACs', 'HKEY_CURRENT_USER\Software\Google\Chrome\BLBeacon',
  'HKEY_CURRENT_USER\Software\Google\Chrome\StabilityMetrics', 'HKEY_CURRENT_USER\Software\Google\Chrome\IncidentsSent',
  'HKEY_CURRENT_USER\Software\Google\Update', 'HKEY_CURRENT_USER\Software\Google\GoogleUpdater', 'HKEY_CURRENT_USER\Software\Google\Common\Rlz',
  'HKEY_CURRENT_USER\Software\BraveSoftware\Brave-Browser\PreferenceMACs', 'HKEY_CURRENT_USER\Software\Chromium\PreferenceMACs'
)

# A .reg export cut into its keys ("[HKEY_...]" sections), without the keys above.
function Split-KitRegText([string]$Text) {
  $sections = New-Object System.Collections.Generic.List[object]
  $cur = $null
  foreach ($ln in ($Text -split "`r`n")) {
    if ($ln -match '^\[(-?)(HKEY_[^\]]+)\]\s*$') {
      $cur = [pscustomobject]@{ Key = $Matches[2]; Lines = New-Object System.Collections.Generic.List[string] }
      $sections.Add($cur)
    }
    if ($cur) { $cur.Lines.Add($ln) }
  }
  @($sections | Where-Object { $k = $_.Key; -not @($script:KitRegSkip | Where-Object { $k -ieq $_ -or $k.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count })
}

function Invoke-KitRegImport([string]$Text) {
  $tmp = Join-Path $env:TEMP ('pcmk-reg-{0}.reg' -f (Get-Random))
  [IO.File]::WriteAllText($tmp, $Text, [Text.Encoding]::Unicode)
  try { return (Invoke-Native 'reg.exe' ('import "{0}"' -f $tmp)) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# Imports a .reg export (with the old profile rewritten). If Windows refuses the
# file as a whole - one locked or protected key is enough - the keys go in one by
# one, so a single bad key no longer costs the whole app its settings (Google's
# keys failed like that on 2026-09-30).
function Import-RegFile([string]$File, [string]$What) {
  $text = [IO.File]::ReadAllText($File, [Text.Encoding]::Unicode)
  if (Get-KitRename) { $text = Convert-KitRegText $text }
  $sections = @(Split-KitRegText $text)
  if (-not $sections.Count) { Say-Info "$What - nothing to import"; return }
  $header = 'Windows Registry Editor Version 5.00'
  [void](Invoke-Change $What {
    $all = $header + "`r`n`r`n" + ((@($sections | ForEach-Object { ($_.Lines -join "`r`n").TrimEnd() })) -join "`r`n`r`n") + "`r`n"
    $r = Invoke-KitRegImport $all
    if ($r.ExitCode -eq 0) { return }
    $bad = @()
    foreach ($s in $sections) {
      $one = Invoke-KitRegImport ($header + "`r`n`r`n" + ($s.Lines -join "`r`n").TrimEnd() + "`r`n")
      if ($one.ExitCode -ne 0) { $bad += $s.Key }
    }
    if ($bad.Count -eq $sections.Count) { throw ('reg import failed: ' + $r.Output.Trim()) }
    if ($bad.Count) { Write-KitLog ('keys Windows refused: ' + ($bad -join '; ')); Say-Info ('{0}: {1} of {2} keys imported; Windows refused {3} (protected or in use) - see the log' -f $What, ($sections.Count - $bad.Count), $sections.Count, $bad.Count) }
  })
}

function Restore-Registry {
  $files = @(Get-ChildItem -LiteralPath (P 'settings\registry\hkcu') -Filter *.reg -ErrorAction SilentlyContinue | Where-Object { Test-KitSelected 'Registry' $_.BaseName })
  foreach ($f in $files) { Import-RegFile $f.FullName ('App settings: ' + $f.BaseName) }
  $apps = Read-Json (P 'settings\apps\apps.json')
  $pyReg = P 'settings\registry\special\python-hklm.reg'
  if ($apps -and (Test-Path -LiteralPath $pyReg)) {
    $restored = @($apps.Python | Where-Object { $_.Hive -eq 'HKLM' -and (Test-Path -LiteralPath (Join-Path $_.InstallPath 'python.exe')) })
    if ($restored.Count) { Import-RegFile $pyReg ('Register Python ' + (($restored | ForEach-Object { $_.Version }) -join ', ') + ' so "py" finds it') }
  }
  $md = P 'settings\registry\special\mapped-drives.reg'
  if ((Test-Path -LiteralPath $md) -and (Get-Item -LiteralPath $md).Length -gt 200 -and (Test-KitSelected 'Settings' 'mappeddrives')) { Import-RegFile $md 'Mapped network drives (they reconnect at next sign-in)' }
}

# -------------------------------------------------- step 7: environment -----
$script:KitEnvSkip = @('TEMP', 'TMP', 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial', 'USERNAME', 'USERPROFILE', 'ComSpec', 'DriverData',
                       'NUMBER_OF_PROCESSORS', 'OS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION',
                       'windir', 'PSModulePath', 'PATHEXT', 'ChocolateyLastPathUpdate')
$script:KitEnvKeys = @{ User = 'HKCU:\Environment'; Machine = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }

function Restore-Environment {
  $data = Read-Json (P 'settings\env\environment.json')
  if (-not $data) { return }
  $keys = $script:KitEnvKeys
  $changed = $false
  foreach ($scope in 'User', 'Machine') {
    $k = Get-Item -LiteralPath $keys[$scope]
    foreach ($v in @($data.Variables | Where-Object { $_.Scope -eq $scope })) {
      if ($script:KitEnvSkip -contains $v.Name) { continue }
      if (-not (Test-KitSelected 'Env' ('{0}|{1}' -f $scope, $v.Name))) { continue }
      $value = Convert-KitPath $v.Value
      $type = 'String'
      if ($v.Kind -eq 'ExpandString') { $type = 'ExpandString' }
      $existing = $k.GetValue($v.Name, $null, 'DoNotExpandEnvironmentNames')
      if ($v.Name -eq 'Path') {
        $cur = @(([string]$existing) -split ';' | Where-Object { $_.Trim() })
        $norm = { param($x) ([Environment]::ExpandEnvironmentVariables($x.Trim())).TrimEnd('\').ToLower() }
        $curN = @($cur | ForEach-Object { & $norm $_ })
        $add = @(($value -split ';') | Where-Object { $_.Trim() } | Where-Object {
          $n = & $norm $_
          ($curN -notcontains $n) -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($_.Trim())))
        })
        if ($add.Count) {
          $newPath = (@($cur) + @($add)) -join ';'
          $scopeName = $scope
          if (Invoke-Change ('{0} PATH: add {1}' -f $scopeName, ($add -join '; ')) { Set-ItemProperty -LiteralPath $keys[$scopeName] -Name 'Path' -Value $newPath -Type ExpandString }) { $changed = $true }
        }
        continue
      }
      if ($null -ne $existing) { continue }
      # e.g. CUDA_PATH for a toolkit that is not installed (yet) - would only confuse tools
      $expanded = [Environment]::ExpandEnvironmentVariables($value)
      if ($expanded -match '^[A-Za-z]:\\[^;]*$' -and -not (Test-Path -LiteralPath $expanded)) {
        Add-Missing ('Variable {0} was not set because {1} does not exist yet - run step 7 again after installing its app' -f $v.Name, $expanded); continue
      }
      if (Invoke-Change ('{0} variable {1}' -f $scope, $v.Name) { New-ItemProperty -LiteralPath $keys[$scope] -Name $v.Name -Value $value -PropertyType $type -Force }) { $changed = $true }
    }
  }
  if ($changed -and -not $DryRun) { Send-EnvironmentChanged; Update-ProcessPath }
}

# ----------------------------------------------------- step 8: services -----
function Restore-Services {
  $data = Read-Json (P 'settings\services\services.json')
  if (-not $data) { return }
  foreach ($s in @($data.Services | Where-Object { $_.Origin -eq 'app' -and (Test-KitSelected 'Services' $_.Name) })) {
    $cur = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $s.Name) -ErrorAction SilentlyContinue
    if ($cur) {
      # Reinstalling the app (step 3) can register its service again, bare: winget's Radarr came
      # back as plain Radarr.Console.exe, without "-nobrowser -data=C:\ProgramData\Radarr".
      # Same program, but the old command line had switches -> put them back.
      $want = Convert-KitPath ([string]$s.PathName)
      $have = [string]$cur.PathName
      $haveExe = Get-CommandKey (Get-CommandExe $have)
      if ($want -and (Get-CommandKey $have) -eq $haveExe -and (Get-CommandKey $want) -ne (Get-CommandKey (Get-CommandExe $want)) -and
          $haveExe -eq (Get-CommandKey (Get-CommandExe $want))) {
        $name = $s.Name
        $wasRunning = $cur.State -eq 'Running'
        if ((Invoke-Change ('Service {0}: put back its old command line ({1})' -f $s.DisplayName, $want) { Set-ServiceCommand $name $want }) -and $wasRunning) {
          [void](Invoke-Change "Restart service $name" { Restart-Service -Name $name -Force })
        }
      }
      continue
    }
    $exe = Convert-KitPath $s.Exe
    if (-not $exe) { continue }
    # updaters come back with their program; an antivirus that is not installed is the person's choice
    if (($s.Name + ' ' + $s.DisplayName) -match '(?i)update|updater|wondershare|nativepush' -or ($s.Name + ' ' + $s.DisplayName + ' ' + $s.Company + ' ' + $s.Exe) -match $script:KitAntivirus) {
      if (-not (Test-Path -LiteralPath $exe)) { Write-KitLog ('Service {0}: its program is not installed - left out' -f $s.Name); continue }
    }
    $pathName = Convert-KitPath $s.PathName
    if (-not (Test-Path -LiteralPath $exe)) {
      $moved = Resolve-KitMovedExe $exe
      if ($moved) { $pathName = Update-KitCommandExe $pathName $exe $moved; $exe = $moved }
    }
    if (-not (Test-Path -LiteralPath $exe)) { Add-Missing ('Service "{0}" comes back when its app is installed ({1}) - or run step 8 again after that' -f $s.DisplayName, $exe); continue }
    if (($s.Name + ' ' + $s.DisplayName) -match '(?i)update|updater|wondershare|nativepush') { continue }
    $acct = [string]$s.StartName
    if ($acct -and $acct -notmatch '^(LocalSystem|NT AUTHORITY\\(LocalService|NetworkService|SYSTEM))$') {
      Add-Missing ('Service "{0}" ran as {1} - recreate it by hand (it needs that account''s password)' -f $s.DisplayName, $acct); continue
    }
    $startup = 'Manual'
    if ($s.StartMode -eq 'Auto') { $startup = 'Automatic' } elseif ($s.StartMode -eq 'Disabled') { $startup = 'Disabled' }
    [void](Invoke-Change ('Recreate service {0} ({1})' -f $s.DisplayName, $s.Name) {
      $p = @{ Name = $s.Name; BinaryPathName = $pathName; DisplayName = $s.DisplayName; StartupType = $startup }
      if ($s.Description) { $p.Description = [string]$s.Description }
      New-Service @p | Out-Null
      if ($s.DelayedAutoStart) { Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)" -Name DelayedAutostart -Value 1 -Type DWord }
      if ($acct -match 'LocalService|NetworkService') {
        $w = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $s.Name)
        Invoke-CimMethod -InputObject $w -MethodName Change -Arguments @{ StartName = $acct; StartPassword = '' } | Out-Null
      }
    })
  }
}

# ------------------------------------------------- step 9: scheduled tasks ---
function Restore-Tasks {
  $data = Read-Json (P 'settings\tasks\tasks.json')
  if (-not $data) { return }
  foreach ($t in @($data.Tasks)) {
    if (-not $t -or -not $t.XmlFile) { continue }
    if (-not (Test-KitSelected 'Tasks' ($t.Path + $t.Name))) { continue }
    $name = Convert-KitTaskName $t.Name
    $full = $t.Path + $name
    if (Get-ScheduledTask -TaskName $name -TaskPath $t.Path -ErrorAction SilentlyContinue) { Say-Ok "$full already exists"; continue }
    if ($t.IsVendor) { Say-Info "$full is recreated by its own app - skipped"; continue }
    $exe = Convert-KitPath $t.Exe
    $moved = $null
    if ($exe -and -not (Test-CommandExists $exe)) {
      $moved = Resolve-KitMovedExe $exe
      if (-not $moved -and ($full + ' ' + $exe) -match $script:KitAntivirus) { Write-KitLog ('Task {0}: its antivirus is not installed - left out' -f $full); continue }
      if (-not $moved) { Add-Missing ('Scheduled task "{0}" needs {1} - run step 9 again once it exists' -f $full, $exe); continue }
    }
    [void](Register-KitTaskFromBackup $t (P "settings\tasks\$($t.XmlFile)") -OldExe $exe -NewExe $moved)
  }
  Update-KitAutomationScripts @(@($data.Tasks) | Where-Object { $_ -and -not $_.IsVendor } | ForEach-Object { [string]$_.Command }) 'Scripts your scheduled tasks run'
}

# ----------------------------------------------------- step 10: startup -----
$script:KitRunKeys = @{ HKCU = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; HKLM = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; HKLM32 = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }

function Get-KitStartupKey($Item) { return ('{0}|{1}' -f $Item.Hive, $Item.Name) }

function Restore-Startup {
  $data = Read-Json (P 'settings\startup\startup.json')
  if (-not $data) { return }
  $runKeys = $script:KitRunKeys
  $approved = @{ HKCU = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; HKLM = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
                 HKLM32 = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; User = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
                 Common = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
  foreach ($it in @($data.Items)) {
    if (-not (Test-KitSelected 'Startup' (Get-KitStartupKey $it))) { continue }
    $added = $false
    if ($it.Type -eq 'Run') {
      $key = $runKeys[[string]$it.Hive]
      if (-not $key) { continue }
      $k = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
      if ($k -and ($k.GetValueNames() -contains $it.Name)) { continue }
      $cmd = Convert-KitPath $it.Command
      $exe = Get-CommandExe $cmd
      if ($exe -match '(?i)\\DriverStore\\') { continue }   # driver helpers come back with the driver
      if (($it.Name + ' ' + $exe) -match $script:KitAntivirus -or ($it.Name + ' ' + $exe) -match '(?i)wondershare') { if (-not (Test-CommandExists $exe)) { Write-KitLog ('Startup item {0}: its program is not installed - left out' -f $it.Name); continue } }
      if ($exe -and -not (Test-CommandExists $exe)) {
        # moved by its reinstall: Epic Games now lives in "Program Files", not "Program Files (x86)"
        $moved = Resolve-KitMovedExe $exe
        if ($moved) { Say-Info ('{0}: {1} is now at {2}' -f $it.Name, $exe, $moved); $cmd = Update-KitCommandExe $cmd $exe $moved; $exe = $moved }
        else { Add-Missing ('Startup item "{0}" needs {1} - run step 10 again once it is installed' -f $it.Name, $exe); continue }
      }
      $type = 'String'
      if ($it.Kind -eq 'ExpandString') { $type = 'ExpandString' }
      $added = Invoke-Change ('Startup item: {0}' -f $it.Name) { New-ItemProperty -LiteralPath $key -Name $it.Name -Value $cmd -PropertyType $type -Force }
    } else {
      $dir = [Environment]::GetFolderPath('Startup')
      if ($it.Hive -eq 'Common') { $dir = [Environment]::GetFolderPath('CommonStartup') }
      $dst = Join-Path $dir $it.Name
      if (Test-Path -LiteralPath $dst) { continue }
      $exe = Convert-KitPath ([string]$it.Exe)
      # a script kept in the Startup folder itself (caddy-jellyfin.vbs) is its own program and arrives with this copy
      $self = $exe -and ($exe -eq (Convert-KitPath ([string]$it.File)))
      $moved = $null
      if ($exe -and -not $self -and -not (Test-CommandExists $exe)) {
        $moved = Resolve-KitMovedExe $exe
        if (-not $moved) { Add-Missing ('Startup shortcut "{0}" needs {1} - run step 10 again once it is installed' -f $it.Name, $exe); continue }
      }
      $src = P ("settings\startup\files\{0}\{1}" -f $it.Hive, $it.Name)
      if (-not (Test-Path -LiteralPath $src)) { continue }
      $added = Invoke-Change ('Startup shortcut: {0}' -f $it.Name) { New-Dir $dir | Out-Null; Copy-Item -LiteralPath $src -Destination $dst -Force }
      if ($added -and -not $DryRun) {
        [void](Update-KitFilePaths @($dst) ('Startup shortcut: ' + $it.Name))
        if ($moved -and $dst -match '(?i)\.lnk$') {
          try {
            $sh = New-Object -ComObject WScript.Shell
            $l = $sh.CreateShortcut($dst)
            $l.TargetPath = $moved
            if ($l.WorkingDirectory -and -not (Test-Path -LiteralPath $l.WorkingDirectory)) { $l.WorkingDirectory = Split-Path $moved -Parent }
            $l.Save()
            Say-Info ('{0} now points at {1}' -f $it.Name, $moved)
          } catch { Say-Warn ('Could not point {0} at {1}: {2}' -f $it.Name, $moved, $_.Exception.Message) }
        }
      }
    }
    if ($added -and -not $it.Enabled) {
      $ak = $approved[[string]$it.Hive]
      [void](Invoke-Change ('Keep "{0}" disabled, as it was' -f $it.Name) {
        if (-not (Test-Path -LiteralPath $ak)) { New-Item -Path $ak -Force | Out-Null }
        New-ItemProperty -LiteralPath $ak -Name $it.Name -Value ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -PropertyType Binary -Force
      })
    }
  }
  Update-KitAutomationScripts @(@($data.Items) | ForEach-Object { [string]$_.Command }) 'Scripts your startup items run'
}

# --------------------------------------------------------- step 11: WSL -----
function Restore-Wsl {
  $data = Read-Json (P 'settings\wsl\wsl.json')
  $distros = @()
  if ($data) { $distros = @($data.Distros | Where-Object { -not $_.IsDocker -and (Test-KitSelected 'Wsl' $_.Name) }) }
  if (-not $distros.Count) { Say-Info 'No WSL distros in the backup.'; return }
  $env:WSL_UTF8 = '1'   # wsl.exe writes UTF-16 into a pipe otherwise, and its messages end up garbled
  $st = Invoke-Native 'wsl.exe' '--status'
  if ($st.ExitCode -ne 0) {
    Say-Warn 'WSL is not installed yet. Run  wsl --install --no-distribution  in an admin window, restart, then run RESTORE step 11 again.'
    return
  }
  $registered = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath).DistributionName })
  foreach ($d in $distros) {
    if ($registered -contains $d.Name) { Say-Ok ('WSL {0} is already registered' -f $d.Name); continue }
    $vhdx = Convert-KitPath $d.Vhdx
    if (-not (Test-Path -LiteralPath $vhdx)) { Say-Warn ('WSL {0}: disk file {1} not found - run step 4 (files) first.' -f $d.Name, $vhdx); continue }
    [void](Invoke-Change ('Register WSL distro {0} from {1}' -f $d.Name, $vhdx) {
      $r = Invoke-Native 'wsl.exe' ('--import-in-place "{0}" "{1}"' -f $d.Name, $vhdx)
      if ($r.ExitCode -ne 0) { throw ('wsl --import-in-place failed (exit {0}): {1}' -f $r.ExitCode, $r.Output.Trim()) }
      $k = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' | Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath).DistributionName -eq $d.Name } | Select-Object -First 1
      if ($k -and $null -ne $d.DefaultUid) { Set-ItemProperty -LiteralPath $k.PSPath -Name DefaultUid -Value ([int]$d.DefaultUid) -Type DWord }
    })
  }

  # "wsl" should open the same distro as before. A fresh Windows has Docker Desktop's
  # internal distro as the default (Docker registers the first one), so a backup that
  # did not record the default gets its own distro back as the default instead.
  $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  $curGuid = (Get-ItemProperty -LiteralPath $lxss -ErrorAction SilentlyContinue).DefaultDistribution
  $curName = $null
  if ($curGuid) { $curName = (Get-ItemProperty -LiteralPath (Join-Path $lxss $curGuid) -ErrorAction SilentlyContinue).DistributionName }
  $want = $null
  if (@($data.Distros | Where-Object { $null -ne $_.IsDefault }).Count) { $want = @($distros | Where-Object { $_.IsDefault }) | Select-Object -First 1 }
  elseif (-not $curName -or $curName -like 'docker-desktop*') { $want = $distros | Select-Object -First 1 }
  $now = @(Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath).DistributionName })
  if ($want -and $want.Name -ne $curName -and ($DryRun -or $now -contains $want.Name)) {
    $wantName = $want.Name
    # set where WSL keeps it, as "wsl --set-default" does - that command, run from this
    # elevated window right after the import, answered WSL_E_DISTRO_NOT_FOUND (2026-09-30)
    [void](Invoke-Change ('Make {0} the default WSL distro (what "wsl" opens)' -f $wantName) {
      $k = Get-ChildItem $lxss | Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath).DistributionName -eq $wantName } | Select-Object -First 1
      if (-not $k) { throw "$wantName is not registered" }
      Set-ItemProperty -LiteralPath $lxss -Name DefaultDistribution -Value $k.PSChildName
    })
  }
}

# ----------------------------------------------------- step 12: drivers -----
function Restore-Drivers {
  $dir = P 'settings\drivers'
  $n = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue).Count
  if (-not $n) { Say-Info 'No drivers in the backup.'; return }
  Say-Info 'Adding drivers - Windows installs only the ones that match your hardware (a few minutes)...'
  [void](Invoke-Change "Add $n driver packages" {
    $r = Invoke-Native 'pnputil.exe' ('/add-driver "{0}\*.inf" /subdirs /install' -f $dir)
    if ($r.ExitCode -eq 3010) { $script:NeedReboot = $true }
    elseif ($r.ExitCode -ne 0 -and $r.ExitCode -ne 259) { throw ('pnputil exit code {0}' -f $r.ExitCode) }
  })
}

# ------------------------------------ step 13: Wi-Fi, hosts, power, fonts ---
# The lines of the old hosts file that are the person's own: the sections Tailscale
# and Docker Desktop keep there hold the old PC's addresses and are rewritten by
# those apps - copied back, they would go stale for good.
function Get-KitOldHostsLines {
  $old = @()
  $managed = $false
  foreach ($ln in @(Get-Content -LiteralPath (P 'settings\network\hosts') -ErrorAction SilentlyContinue)) {
    $t = $ln.Trim()
    if ($t -match '^#\s*(TailscaleHostsSectionStart|Added by Docker Desktop)') { $managed = $true; continue }
    if ($t -match '^#\s*(TailscaleHostsSectionEnd|End of section)') { $managed = $false; continue }
    if (-not $managed -and $t -and -not $t.StartsWith('#')) { $old += $ln }
  }
  return $old
}

function Get-KitHostsNorm([string]$Line) { return ((($Line -replace '#.*$', '').Trim() -replace '\s+', ' ').ToLower()) }

function Restore-System {
  if (Test-KitSelected 'Settings' 'wifi') {
    foreach ($f in Get-ChildItem -LiteralPath (P 'settings\network\wifi') -Filter *.xml -ErrorAction SilentlyContinue) {
      $wifiName = $f.BaseName
      try { $wifiName = ([xml](Get-Content -LiteralPath $f.FullName -Raw)).WLANProfile.name } catch {}
      if (-not (Test-KitSelected 'Wifi' $wifiName)) { continue }
      [void](Invoke-Change ('Wi-Fi network: ' + $wifiName) {
        $r = Invoke-Native 'netsh.exe' ('wlan add profile filename="{0}" user=all' -f $f.FullName)
        if ($r.ExitCode -ne 0) { throw $r.Output.Trim() }
      })
    }
  }

  if (Test-KitSelected 'Settings' 'hosts') {
    $hostsFile = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $old = @(Get-KitOldHostsLines)
    if ($old.Count) {
      $cur = @(Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue | ForEach-Object { Get-KitHostsNorm $_ })
      $add = @($old | Where-Object { $cur -notcontains (Get-KitHostsNorm $_) })
      if ($add.Count) {
        [void](Invoke-Change ('hosts file: add {0} entr(y/ies)' -f $add.Count) {
          Add-Content -LiteralPath $hostsFile -Value (@('', ('# restored by PC Migration Kit ' + (Get-Date -Format 'yyyy-MM-dd'))) + $add) -Encoding ASCII
        })
      }
    }
  }

  if (Test-KitSelected 'Settings' 'power') { Restore-KitPowerPlan }

  if (Test-KitSelected 'Settings' 'fonts') {
    $fj = Read-Json (P 'settings\fonts\fonts.json')
    if ($fj) {
      $fontKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
      foreach ($f in @($fj.Machine)) {
        $dst = Join-Path $env:windir "Fonts\$($f.File)"
        $src = P "settings\fonts\machine\$($f.File)"
        if ((Test-Path -LiteralPath $dst) -or -not (Test-Path -LiteralPath $src)) { continue }
        [void](Invoke-Change "Font: $($f.File)" {
          Copy-Item -LiteralPath $src -Destination $dst -Force
          $name = $f.RegName
          if (-not $name -and $f.File -match '\.(ttf|otf|ttc|fon)$') { $name = [IO.Path]::GetFileNameWithoutExtension($f.File) + ' (TrueType)' }
          if ($name) { New-ItemProperty -LiteralPath $fontKey -Name $name -Value $f.File -PropertyType String -Force | Out-Null }
        })
      }
      $userFontDir = Join-Path $script:NewProfile 'AppData\Local\Microsoft\Windows\Fonts'
      $userKey = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
      foreach ($f in @($fj.User)) {
        $dst = Join-Path $userFontDir $f.File
        $src = Join-Path $script:SrcProfile "AppData\Local\Microsoft\Windows\Fonts\$($f.File)"
        if ((Test-Path -LiteralPath $dst) -or -not (Test-Path -LiteralPath $src)) { continue }
        [void](Invoke-Change "Font (just for you): $($f.File)" {
          New-Dir $userFontDir | Out-Null
          Copy-Item -LiteralPath $src -Destination $dst -Force
          if (-not (Test-Path -LiteralPath $userKey)) { New-Item -Path $userKey -Force | Out-Null }
          $name = $f.RegName
          if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($f.File) + ' (TrueType)' }
          New-ItemProperty -LiteralPath $userKey -Name $name -Value $dst -PropertyType String -Force | Out-Null
        })
      }
    }
  }
}

# The power plan the old PC used. A Windows feature update (10 -> 11 on 2026-09-30)
# quietly switches back to Balanced, so Verify checks this too.
function Restore-KitPowerPlan {
  $pj = Read-Json (P 'settings\power\power.json')
  if (-not $pj -or -not $pj.ActiveScheme) { return }
  $guid = [string]$pj.ActiveScheme
  $current = (& powercfg.exe /getactivescheme | Out-String)
  if ($current -match [regex]::Escape($guid)) { Say-Ok 'Power plan is already the one you used'; return }
  [void](Invoke-Change 'Power plan' {
    if ((& powercfg.exe /list | Out-String) -notmatch [regex]::Escape($guid)) {
      $r = Invoke-Native 'powercfg.exe' ('/import "{0}" {1}' -f (P 'settings\power\scheme.pow'), $guid)
      if ($r.ExitCode -ne 0) { throw 'import failed' }
    }
    $r = Invoke-Native 'powercfg.exe' "/setactive $guid"
    if ($r.ExitCode -ne 0) { throw 'could not activate it' }
  })
}

# ---------------------------------------------------- step 14: explorer -----
function Restore-Explorer {
  $oldBuild = [int]$script:M.System.Build
  $newBuild = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
  if (($oldBuild -ge 22000) -ne ($newBuild -ge 22000)) { Say-Info 'Taskbar layout differs between Windows 10 and 11 - pins not restored.'; return }
  $rel = 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch'
  Restore-Tree (Join-Path $script:SrcProfile $rel) (Join-Path $script:NewProfile $rel) 'Taskbar pins'
  $tb = P 'settings\registry\special\taskband.reg'
  if (Test-Path -LiteralPath $tb) { Import-RegFile $tb 'Taskbar pin order' }
  $qa = 'AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations'
  Restore-Tree (Join-Path $script:SrcProfile $qa) (Join-Path $script:NewProfile $qa) 'Quick Access pins' -Files @('f01b4d95cf55d32a.automaticDestinations-ms') -NoSubdirs
  [void](Invoke-Change 'Restart Explorer to show them' { Stop-Process -Name explorer -Force })
}

# ------------------------------------------- step 16: folders on other drives ---
# Folders from other drives the person ticked in the app when backing up
# (D:\Projects, a games folder ...). They go back where they were; files that
# are already there and newer are kept.
function Restore-ExtraFolders {
  $extra = @($script:M.ExtraFolders | Where-Object { $_ -and $_.Path -and $_.Dest })
  if (-not $extra.Count) { Say-Info 'The backup has no extra folders.'; return }
  $old = $script:SkipNewer
  $script:SkipNewer = $true
  try {
    foreach ($x in $extra) {
      if (-not (Test-KitSelected 'Extra' $x.Path)) { Say-Info ('{0}: not selected - skipped' -f $x.Path); continue }
      $target = Convert-KitPath ([string]$x.Path)
      $root = [IO.Path]::GetPathRoot($target)
      if (-not (Test-Path -LiteralPath $root)) { Say-Warn ('{0}: drive {1} is not connected - plug it in and run this step again.' -f $x.Path, $root); continue }
      Restore-Tree (P $x.Dest) $target $x.Path
    }
  } finally { $script:SkipNewer = $old }
}

# step 15: every part of the media server that is ticked (all of them without a selection)
function Restore-KitMediaServer {
  $all = @(Get-MsDefinitions | ForEach-Object { $_.Key })
  $only = @($all | Where-Object { Test-KitSelected 'Media' $_ })
  if (-not $only.Count) { Say-Info 'No part of the media server was selected.'; return }
  if ($only.Count -lt $all.Count) { [void](Invoke-MsRepair -Only $only -Interactive:(-not $NoPause -and -not $script:Gui)) }
  else { [void](Invoke-MsRepair -Interactive:(-not $NoPause -and -not $script:Gui)) }
}

function Start-KitServices {
  $data = Read-Json (P 'settings\services\services.json')
  if (-not $data) { return }
  foreach ($s in @($data.Services | Where-Object { $_.State -eq 'Running' -and $_.StartMode -eq 'Auto' })) {
    $x = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
    if ($x -and $x.Status -ne 'Running') { [void](Invoke-Change "Start service $($s.Name)" { Start-Service -Name $s.Name }) }
  }
}

# The numbered steps. Restore.ps1 runs them in this order; Verify.ps1 uses the keys.
function Get-KitRestoreSteps {
  $apps = @(Get-InstallList)
  $tasksData = Read-Json (P 'settings\tasks\tasks.json')
  $taskCount = 0
  if ($tasksData -and $tasksData.Tasks) { $taskCount = @($tasksData.Tasks | Where-Object { $_ -and -not $_.IsVendor }).Count }
  $letters = @(Get-KitBackupVolumes | ForEach-Object { $_.Letter + ':' }) -join ' '
  $defs = @(
    [pscustomobject]@{ N = 1;  Key = 'letters';  Title = "Drive letters ($letters)";                                   Fn = { Restore-DriveLetters } }
    [pscustomobject]@{ N = 2;  Key = 'features'; Title = 'Windows features (WSL, Hyper-V ...)';                        Fn = { Restore-Features } }
    [pscustomobject]@{ N = 3;  Key = 'apps';     Title = ('Install {0} apps with winget (takes a while)' -f $apps.Count); Fn = { Restore-Apps } }
    [pscustomobject]@{ N = 4;  Key = 'files';    Title = 'Your files + profile (Desktop, Documents, AppData ...)';     Fn = { Restore-Files } }
    [pscustomobject]@{ N = 5;  Key = 'appdata';  Title = 'App data (ProgramData, Steam, licences, Store apps, Claude chats)'; Fn = { Restore-AppData } }
    [pscustomobject]@{ N = 6;  Key = 'registry'; Title = 'Your apps'' registry settings';                                Fn = { Restore-Registry } }
    [pscustomobject]@{ N = 7;  Key = 'env';      Title = 'Environment variables (PATH, tokens)';                        Fn = { Restore-Environment } }
    [pscustomobject]@{ N = 8;  Key = 'services'; Title = 'Services (recreate missing ones)';                            Fn = { Restore-Services } }
    [pscustomobject]@{ N = 9;  Key = 'tasks';    Title = ('Your scheduled tasks ({0})' -f $taskCount);                   Fn = { Restore-Tasks } }
    [pscustomobject]@{ N = 10; Key = 'startup';  Title = 'Startup items';                                                Fn = { Restore-Startup } }
    [pscustomobject]@{ N = 11; Key = 'wsl';      Title = 'WSL Linux distros';                                            Fn = { Restore-Wsl } }
    [pscustomobject]@{ N = 12; Key = 'drivers';  Title = 'Drivers';                                                      Fn = { Restore-Drivers } }
    [pscustomobject]@{ N = 13; Key = 'system';   Title = 'Wi-Fi, hosts file, power plan, fonts';                         Fn = { Restore-System } }
    [pscustomobject]@{ N = 14; Key = 'explorer'; Title = 'Taskbar pins + Quick Access';                                  Fn = { Restore-Explorer } }
    [pscustomobject]@{ N = 15; Key = 'mediaserver'; Title = 'Media server + smart home: set up and check every part';    Fn = { Restore-KitMediaServer } }
  )
  $extra = @($script:M.ExtraFolders | Where-Object { $_ })   # @($null).Count is 1 in Windows PowerShell
  if ($extra.Count) {
    $defs += [pscustomobject]@{ N = 16; Key = 'extra'; Title = ('Folders from other drives ({0})' -f $extra.Count); Fn = { Restore-ExtraFolders } }
  }
  return $defs
}
