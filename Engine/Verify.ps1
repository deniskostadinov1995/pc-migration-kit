<#
  PC Migration Kit - VERIFY
  -------------------------
  Compares this PC with a backup and lists what is not back (or went missing
  later): apps, services, scheduled tasks, startup items, environment
  variables, power plan, hosts entries, fonts, Windows features, WSL, drive
  letters, Docker containers and the media server. Anything it can put back
  is marked "fixable"; -Fix puts back the items you name (or -FixAll: all of
  them) with the same code RESTORE uses.

  Why it exists: after the restore of 2026-09-29 the PC was upgraded from
  Windows 10 to 11, and the upgrade quietly dropped a scheduled task
  (RemoteAccessWatchdog), a service (SignalRGB) and the power plan. Nothing
  said so - this does.

  -BackupPath  which backup (default: the one this copy sits in, else the newest in ..\Backups)
  -Out         write the results as JSON (the app reads them)
  -Fix         ids of items to put back, as listed by a check (e.g. task|\RemoteAccessWatchdog);
               several: -Fix "id1,id2" (one string, commas between)
  -FixFile     a JSON file with { "Fix": [ids] } - how the app passes them
  -FixAll      put back everything fixable
  -DryRun      with -Fix: only say what would be done

  Written by Claude 2026-10-02.
#>
param(
  [string]$BackupPath,
  [string]$Out,
  [string[]]$Fix,
  [string]$FixFile,
  [switch]$FixAll,
  [switch]$DryRun,
  [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
. (Join-Path $PSScriptRoot 'MediaServer.ps1')
. (Join-Path $PSScriptRoot 'RestoreSteps.ps1')
Set-ConsoleUtf8
$KitRoot = Split-Path $PSScriptRoot -Parent
if ($script:Gui) { $NoPause = $true }

$script:Checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Area, [string]$Name, [string]$Status, [string]$Detail, [string]$FixId, [string]$FixText) {
  $c = [pscustomobject]@{ Area = $Area; Name = $Name; Status = $Status; Detail = $Detail; FixId = $FixId; FixText = $FixText }
  $script:Checks.Add($c)
  Send-KitEvent @{ t = 'check'; area = $Area; name = $Name; status = $Status; detail = $Detail; fixId = $FixId; fixText = $FixText }
}

# ------------------------------------------------------------------ checks ---
function Test-VerifySteps {
  $statePath = Join-Path $script:StateDir ('restore-state-{0}.json' -f $script:M.BackupId)
  $st = Read-Json $statePath
  if (-not $st) { Add-Check 'Restore' 'RESTORE has not run on this PC for this backup' 'info' 'Nothing to compare the steps with - the checks below still apply.' $null $null; return }
  $done = @(); if ($st.Done) { $done = @($st.Done.PSObject.Properties | ForEach-Object { $_.Name }) }
  foreach ($d in @(Get-KitRestoreSteps)) {
    if ($done -contains $d.Key) { continue }
    Add-Check 'Restore' ('Step {0} - {1}' -f $d.N, $d.Title) 'warn' 'still "to do" - it finished with warnings or never ran' ('step|' + $d.N) ('Run step ' + $d.N + ' again')
  }
}

function Get-VerifyWingetIds {
  $ids = @{}
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }
  $tmp = Join-Path $env:TEMP ('pcmk-verify-{0}.json' -f (Get-Random))
  $null = & winget export -o $tmp --accept-source-agreements --disable-interactivity 2>&1
  $j = Read-Json $tmp
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  if ($j) { foreach ($s in $j.Sources) { foreach ($pk in $s.Packages) { $ids[[string]$pk.PackageIdentifier] = $true } } }
  return $ids
}

function Test-VerifyApps {
  Show-KitProgress 'Checking' 'Apps (asking winget what is installed)...'
  $have = Get-VerifyWingetIds
  $apps = Read-Json (P 'settings\apps\apps.json')
  foreach ($a in @(Get-InstallList)) {
    if ($null -eq $have) { break }
    if ($have.ContainsKey($a.Id)) { Add-Check 'Apps' $a.Id 'ok' 'installed' $null $null; continue }
    if ($a.Name -and (Test-KitProgramInstalled $a.Name)) { Add-Check 'Apps' $a.Id 'ok' ('installed (as "{0}", not through winget)' -f $a.Name) $null $null; continue }
    $label = $a.Id
    $wn = Get-KitWingetPackageName $a.Id $a.Source
    if ($wn) {
      $label = '{0} ({1})' -f $wn, $a.Id
      if (Test-KitProgramInstalled $wn) { Add-Check 'Apps' $label 'ok' 'installed (under another package id)' $null $null; continue }
    }
    Add-Check 'Apps' $label 'missing' 'not installed' ('app|' + $a.Id) ('winget install ' + $a.Id)
  }
  if ($apps) {
    foreach ($s in @($apps.StoreApps | Where-Object { $_ -and $_.PackageName })) {
      if (Get-AppxPackage -Name $s.PackageName -ErrorAction SilentlyContinue) { Add-Check 'Apps' $s.Name 'ok' 'Store app installed' $null $null }
      else { Add-Check 'Apps' $s.Name 'missing' 'Store app not installed - Microsoft Store -> Library' ('store|' + $s.PackageName) 'Install from the Microsoft Store' }
    }
    foreach ($m in @($apps.Plan.Manual | Where-Object { $_ -and $_.Name })) {
      if (Test-KitProgramInstalled $m.Name) { Add-Check 'Apps' $m.Name 'ok' 'installed' $null $null; continue }
      if ($m.Name -match $script:KitAntivirus) { Add-Check 'Apps' $m.Name 'info' 'antivirus - left to you (Windows Security protects the PC meanwhile)' $null $null; continue }
      Add-Check 'Apps' $m.Name 'missing' ('not installed (version {0} on the old PC); the fix looks it up in winget and the Store by name' -f $m.Version) ('manual|' + $m.Name) 'Find and install it'
    }
  }
}

function Test-VerifyServices {
  $data = Read-Json (P 'settings\services\services.json')
  if (-not $data) { return }
  foreach ($s in @($data.Services | Where-Object { $_.Origin -eq 'app' })) {
    $label = '{0} ({1})' -f $s.DisplayName, $s.Name
    $cur = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $s.Name) -ErrorAction SilentlyContinue
    if ($cur) {
      if ($s.State -eq 'Running' -and $s.StartMode -eq 'Auto' -and $cur.State -ne 'Running') { Add-Check 'Services' $label 'warn' ('{0} (it was running on the old PC)' -f $cur.State) ('svcstart|' + $s.Name) 'Start it' }
      else { Add-Check 'Services' $label 'ok' ('{0}, {1}' -f $cur.State, $cur.StartMode) $null $null }
      continue
    }
    if (($s.Name + ' ' + $s.DisplayName + ' ' + $s.Company + ' ' + $s.Exe) -match $script:KitAntivirus) { Add-Check 'Services' $label 'info' 'belongs to an antivirus that is not installed' $null $null; continue }
    if (($s.Name + ' ' + $s.DisplayName) -match '(?i)update|updater|wondershare|nativepush') { Add-Check 'Services' $label 'info' 'an updater - comes back with its app' $null $null; continue }
    $exe = Convert-KitPath $s.Exe
    $where = $exe
    if (-not (Test-Path -LiteralPath $exe)) { $where = Resolve-KitMovedExe $exe }
    if ($where) { Add-Check 'Services' $label 'missing' ('missing - its program is here: {0}' -f $where) ('service|' + $s.Name) 'Recreate the service' }
    else { Add-Check 'Services' $label 'info' ('comes back when its app is installed ({0} is not there)' -f $exe) $null $null }
  }
}

function Test-VerifyTasks {
  $data = Read-Json (P 'settings\tasks\tasks.json')
  if (-not $data) { return }
  foreach ($t in @($data.Tasks | Where-Object { $_ -and -not $_.IsVendor -and $_.XmlFile })) {
    $name = Convert-KitTaskName $t.Name
    $full = $t.Path + $name
    $cur = Get-ScheduledTask -TaskName $name -TaskPath $t.Path -ErrorAction SilentlyContinue
    # Without administrator rights Windows hides tasks that run as SYSTEM (RemoteAccessWatchdog
    # looked "missing" on 2026-10-02 although it was there) - say so instead of guessing.
    if (-not $cur -and -not (Test-IsAdmin) -and ([string]$t.UserId -match '^(SYSTEM|S-1-5-18|LocalSystem|NT AUTHORITY\\SYSTEM)$' -or [string]$t.RunLevel -eq 'Highest')) {
      Add-Check 'Scheduled tasks' $full 'info' 'runs as SYSTEM - only visible with administrator rights; check as administrator to be sure' $null $null
      continue
    }
    if (-not $cur) {
      $exe = Convert-KitPath $t.Exe
      if ($exe -and -not (Test-CommandExists $exe) -and -not (Resolve-KitMovedExe $exe)) {
        if (($full + ' ' + $exe) -match $script:KitAntivirus) { Add-Check 'Scheduled tasks' $full 'info' 'belongs to an antivirus that is not installed' $null $null }
        else { Add-Check 'Scheduled tasks' $full 'info' ('comes back when its app is installed ({0} is not there)' -f $exe) $null $null }
      }
      else { Add-Check 'Scheduled tasks' $full 'missing' ('missing - runs: {0}' -f $t.Command) ('task|' + $t.Path + $t.Name) 'Recreate the task' }
      continue
    }
    $was = [string]$t.State; $now = [string]$cur.State
    if ($now -eq 'Disabled' -and $was -ne 'Disabled') { Add-Check 'Scheduled tasks' $full 'info' 'switched off now (it was on before) - turned off on purpose?' $null $null; continue }
    $info = $cur | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    $res = if ($info) { $info.LastTaskResult } else { 0 }
    # 0 = success, 0x41301 running, 0x41303 not run yet, 0x41306 terminated by the user/system
    if ($now -ne 'Disabled' -and $res -notin 0, 267009, 267011, 267014, 267045) { Add-Check 'Scheduled tasks' $full 'warn' ('present, but its last run ended with code 0x{0:X} ({1})' -f $res, $info.LastRunTime) $null $null }
    else { Add-Check 'Scheduled tasks' $full 'ok' $now $null $null }
  }
}

function Test-VerifyStartup {
  $data = Read-Json (P 'settings\startup\startup.json')
  if (-not $data) { return }
  foreach ($it in @($data.Items)) {
    $label = '{0} ({1} {2})' -f $it.Name, $it.Type, $it.Hive
    $have = $false
    if ($it.Type -eq 'Run') {
      $k = Get-Item -LiteralPath $script:KitRunKeys[[string]$it.Hive] -ErrorAction SilentlyContinue
      $have = $k -and ($k.GetValueNames() -contains $it.Name)
    } else {
      $dir = if ($it.Hive -eq 'Common') { [Environment]::GetFolderPath('CommonStartup') } else { [Environment]::GetFolderPath('Startup') }
      $have = Test-Path -LiteralPath (Join-Path $dir $it.Name)
    }
    if ($have) { Add-Check 'Startup' $label 'ok' 'present' $null $null; continue }
    $exe = Convert-KitPath ([string]$it.Exe)
    if ($exe -match '(?i)\\DriverStore\\') { Add-Check 'Startup' $label 'info' 'a driver helper - comes back with its driver' $null $null; continue }
    if (($it.Name + ' ' + $exe) -match $script:KitAntivirus -or ($it.Name + ' ' + $exe) -match '(?i)wondershare') { Add-Check 'Startup' $label 'info' 'belongs to an app that is not installed on purpose' $null $null; continue }
    $self = $exe -and ($exe -eq (Convert-KitPath ([string]$it.File)))
    $where = if (-not $exe -or $self -or (Test-CommandExists $exe)) { $exe } else { Resolve-KitMovedExe $exe }
    if ($where) { Add-Check 'Startup' $label 'missing' ('missing - starts {0}' -f $where) ('startup|' + (Get-KitStartupKey $it)) 'Add it back' }
    else { Add-Check 'Startup' $label 'info' ('comes back when its app is installed ({0} is not there)' -f $exe) $null $null }
  }
}

function Test-VerifyEnvironment {
  $data = Read-Json (P 'settings\env\environment.json')
  if (-not $data) { return }
  foreach ($scope in 'User', 'Machine') {
    $k = Get-Item -LiteralPath $script:KitEnvKeys[$scope]
    foreach ($v in @($data.Variables | Where-Object { $_.Scope -eq $scope -and $script:KitEnvSkip -notcontains $_.Name })) {
      $existing = $k.GetValue($v.Name, $null, 'DoNotExpandEnvironmentNames')
      $label = '{0} variable {1}' -f $scope, $v.Name
      if ($v.Name -eq 'Path') {
        $norm = { param($x) ([Environment]::ExpandEnvironmentVariables($x.Trim())).TrimEnd('\').ToLower() }
        $curN = @((([string]$existing) -split ';') | Where-Object { $_.Trim() } | ForEach-Object { & $norm $_ })
        $miss = @(((Convert-KitPath $v.Value) -split ';') | Where-Object { $_.Trim() -and $curN -notcontains (& $norm $_) -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($_.Trim()))) })
        if ($miss.Count) { Add-Check 'Environment' ('{0} PATH' -f $scope) 'missing' ('missing folders: ' + ($miss -join '; ')) ('env|' + $scope + '|Path') 'Add them to PATH' }
        else { Add-Check 'Environment' ('{0} PATH' -f $scope) 'ok' 'every folder from before that exists is on it' $null $null }
        continue
      }
      if ($null -ne $existing) { Add-Check 'Environment' $label 'ok' 'set' $null $null; continue }
      $expanded = [Environment]::ExpandEnvironmentVariables((Convert-KitPath $v.Value))
      if ($expanded -match '^[A-Za-z]:\\[^;]*$' -and -not (Test-Path -LiteralPath $expanded)) { Add-Check 'Environment' $label 'info' ('not set - it pointed at {0}, which does not exist here' -f $expanded) $null $null; continue }
      Add-Check 'Environment' $label 'missing' 'not set (value hidden - it may be a token)' ('env|' + $scope + '|' + $v.Name) 'Set it again'
    }
  }
}

function Test-VerifySystem {
  $pj = Read-Json (P 'settings\power\power.json')
  if ($pj -and $pj.ActiveScheme) {
    $cur = (& powercfg.exe /getactivescheme | Out-String)
    $name = [regex]::Match($cur, '\(([^)]+)\)').Groups[1].Value
    if ($cur -match [regex]::Escape([string]$pj.ActiveScheme)) { Add-Check 'Windows settings' 'Power plan' 'ok' $name $null $null }
    else { Add-Check 'Windows settings' 'Power plan' 'changed' ('now "{0}" - the old PC used another plan (Windows upgrades reset it)' -f $name) 'power' 'Switch back to the old plan' }
  }
  $old = @(Get-KitOldHostsLines)
  if ($old.Count) {
    $cur = @(Get-Content -LiteralPath (Join-Path $env:windir 'System32\drivers\etc\hosts') -ErrorAction SilentlyContinue | ForEach-Object { Get-KitHostsNorm $_ })
    $miss = @($old | Where-Object { $cur -notcontains (Get-KitHostsNorm $_) })
    if ($miss.Count) { Add-Check 'Windows settings' 'hosts file' 'missing' ('{0} entr(y/ies) missing: {1}' -f $miss.Count, (($miss | ForEach-Object { $_.Trim() }) -join ' | ')) 'hosts' 'Add them back' }
    else { Add-Check 'Windows settings' 'hosts file' 'ok' ('{0} entr(y/ies) present' -f $old.Count) $null $null }
  }
  $fj = Read-Json (P 'settings\fonts\fonts.json')
  if ($fj -and @($fj.Machine).Count) {
    $miss = @($fj.Machine | Where-Object { -not (Test-Path -LiteralPath (Join-Path $env:windir "Fonts\$($_.File)")) })
    if ($miss.Count) { Add-Check 'Windows settings' 'Fonts' 'missing' (($miss | ForEach-Object { $_.File }) -join ', ') 'fonts' 'Install them' }
    else { Add-Check 'Windows settings' 'Fonts' 'ok' ('{0} extra font(s) installed' -f @($fj.Machine).Count) $null $null }
  }
  $f = Read-Json (P 'settings\system\features.json')
  if ($f -and $f.Features -and (Test-IsAdmin)) {
    $now = @{}
    Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | ForEach-Object { $now[$_.FeatureName] = [string]$_.State }
    foreach ($x in @($f.Features | Where-Object { $now.ContainsKey($_) -and $now[$_] -ne 'Enabled' })) {
      if ($x -match '^SMB1Protocol') { Add-Check 'Windows features' $x 'info' 'left off on purpose (insecure) - turn it on only if an old device needs it' $null $null }
      else { Add-Check 'Windows features' $x 'missing' 'switched off (it was on before)' ('feature|' + $x) 'Turn it on' }
    }
  }
}

function Test-VerifyWsl {
  $data = Read-Json (P 'settings\wsl\wsl.json')
  $distros = @(); if ($data) { $distros = @($data.Distros | Where-Object { -not $_.IsDocker }) }
  if (-not $distros.Count) { return }
  $registered = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath).DistributionName })
  foreach ($d in $distros) {
    if ($registered -contains $d.Name) { Add-Check 'WSL' $d.Name 'ok' 'registered' $null $null }
    else { Add-Check 'WSL' $d.Name 'missing' 'not registered' ('wsl|' + $d.Name) 'Register it from its disk file' }
  }
}

function Test-VerifyLetters {
  $vols = @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue)
  $parts = @(Get-Partition -ErrorAction SilentlyContinue)
  foreach ($w in @(Get-KitBackupVolumes)) {
    $match = $null
    if ($w.PartitionGuid) {
      $p = $parts | Where-Object { [string]$_.Guid -eq $w.PartitionGuid } | Select-Object -First 1
      if ($p) { $match = $vols | Where-Object { $p.AccessPaths -contains $_.DeviceID } | Select-Object -First 1 }
    }
    if (-not $match -and $w.SerialNumber) { $match = $vols | Where-Object { $_.SerialNumber -eq $w.SerialNumber } | Select-Object -First 1 }
    $label = '{0}: {1}' -f $w.Letter, $w.Label
    if (-not $match) { Add-Check 'Drives' $label 'warn' ('not connected ({0})' -f $w.DiskModel) $null $null; continue }
    $cur = if ($match.DriveLetter) { $match.DriveLetter.Substring(0, 1).ToUpper() } else { '' }
    if ($cur -eq $w.Letter) { Add-Check 'Drives' $label 'ok' 'same letter as before' $null $null }
    else { Add-Check 'Drives' $label 'changed' ('it is {0} now' -f $(if ($cur) { $cur + ':' } else { 'without a letter' })) ('letter|' + $w.Letter) ('Give it ' + $w.Letter + ': back') }
  }
}

function Test-VerifyDocker {
  $dj = Read-Json (P 'settings\docker\docker.json')
  if (-not $dj -or -not $dj.Docker -or -not $dj.Docker.Reachable) { return }
  $docker = Get-MsDockerExe
  if (-not $docker) { Add-Check 'Docker' 'Docker Desktop' 'missing' 'not installed' $null $null; return }
  if (-not (Test-MsDockerUp)) { Add-Check 'Docker' 'Docker Desktop' 'warn' 'installed, but its engine is not running - start Docker Desktop' $null $null; return }
  $msNames = @('seerr', 'jellystat', 'jellystat-db')
  foreach ($c in @($dj.Docker.Containers | Where-Object { $_ -and $_.Name })) {
    if ($msNames -contains $c.Name) { continue }   # the media server check covers these
    $running = Get-MsContainerRunning $c.Name
    $was = [string]$c.Status
    if ($null -eq $running) {
      if ($c.ComposeDir -and (Test-Path -LiteralPath $c.ComposeDir)) { Add-Check 'Docker' $c.Name 'missing' ('container missing - its compose project is in {0}' -f $c.ComposeDir) ('compose|' + $c.ComposeDir) 'docker compose up -d' }
      else { Add-Check 'Docker' $c.Name 'missing' ('container missing ({0})' -f $c.Image) $null $null }
    } elseif (-not $running -and $was -eq 'running') { Add-Check 'Docker' $c.Name 'warn' 'stopped (it was running before)' ('dstart|' + $c.Name) 'Start it' }
    elseif ($running) { Add-Check 'Docker' $c.Name 'ok' 'running' $null $null }
    else { Add-Check 'Docker' $c.Name 'ok' ('stopped, as before ({0})' -f $was) $null $null }
  }
}

function Test-VerifyMedia {
  if (-not $script:MsFacts) { return }
  Show-KitProgress 'Checking' 'Media server + smart home...'
  foreach ($s in @(Test-MsAll)) {
    $status = switch ($s.Status) { 'OK' { 'ok' } 'WARN' { 'warn' } default { 'missing' } }
    $fix = $null; $ft = $null
    if ($s.Status -ne 'OK' -and $s.Key -and $s.Key -ne 'network') { $fix = 'media|' + $s.Key; $ft = 'Set up / repair it' }
    if ($s.Status -ne 'OK' -and $s.Key -eq 'network') { $fix = 'media|network'; $ft = 'Make the home network Private' }
    Add-Check 'Media server' $s.Name $status $s.Detail $fix $ft
  }
}

function Invoke-VerifyChecks {
  $script:Checks.Clear()
  $parts = @(
    @{ Name = 'Restore steps'; Fn = { Test-VerifySteps } }, @{ Name = 'Drives'; Fn = { Test-VerifyLetters } },
    @{ Name = 'Apps'; Fn = { Test-VerifyApps } }, @{ Name = 'Services'; Fn = { Test-VerifyServices } },
    @{ Name = 'Scheduled tasks'; Fn = { Test-VerifyTasks } }, @{ Name = 'Startup items'; Fn = { Test-VerifyStartup } },
    @{ Name = 'Environment'; Fn = { Test-VerifyEnvironment } }, @{ Name = 'Windows settings'; Fn = { Test-VerifySystem } },
    @{ Name = 'WSL'; Fn = { Test-VerifyWsl } }, @{ Name = 'Docker'; Fn = { Test-VerifyDocker } }, @{ Name = 'Media server'; Fn = { Test-VerifyMedia } }
  )
  $i = 0
  foreach ($p in $parts) {
    $i++
    Show-KitProgress 'Checking' $p.Name ([int](100 * ($i - 1) / $parts.Count))
    Send-KitEvent @{ t = 'phase'; name = $p.Name; state = 'start' }
    try { & $p.Fn } catch { Add-Check $p.Name ('Could not check: ' + $_.Exception.Message) 'warn' '' $null $null }
    Send-KitEvent @{ t = 'phase'; name = $p.Name; state = 'done' }
  }
  Show-KitProgress 'Checking' '' -Completed
}

# -------------------------------------------------------------------- fixes ---
function Invoke-VerifyFixes([string[]]$Ids) {
  $byKind = @{}
  foreach ($id in $Ids) {
    $kind, $rest = $id -split '\|', 2
    if (-not $byKind.ContainsKey($kind)) { $byKind[$kind] = New-Object System.Collections.Generic.List[string] }
    $byKind[$kind].Add([string]$rest)
  }
  $inc = { param($k) @(if ($byKind.ContainsKey($k)) { $byKind[$k] }) }
  # only the named items: every section of the selection gets an Include list
  $script:Sel = [pscustomobject]@{
    Apps = [pscustomobject]@{ Include = @(& $inc 'app') + @(& $inc 'manual' | ForEach-Object { 'manual:' + $_ }) + @(& $inc 'store' | ForEach-Object { 'store:' + $_ }) }
    Services = [pscustomobject]@{ Include = @(& $inc 'service') }
    Tasks = [pscustomobject]@{ Include = @(& $inc 'task') }
    Startup = [pscustomobject]@{ Include = @(& $inc 'startup') }
    Env = [pscustomobject]@{ Include = @(& $inc 'env') }
    Features = [pscustomobject]@{ Include = @(& $inc 'feature') }
    Wsl = [pscustomobject]@{ Include = @(& $inc 'wsl') }
    Letters = [pscustomobject]@{ Include = @(& $inc 'letter') }
    Settings = [pscustomobject]@{ Include = @(@('hosts', 'fonts', 'power') | Where-Object { $byKind.ContainsKey($_) }) }
    Wifi = [pscustomobject]@{ Include = @() }
  }
  $script:SkipNewer = $true
  $run = @(
    @{ Kinds = @('letter');                  Title = 'Drive letters';      Fn = { Restore-DriveLetters } }
    @{ Kinds = @('feature');                 Title = 'Windows features';   Fn = { Restore-Features } }
    @{ Kinds = @('app', 'manual', 'store');  Title = 'Apps';               Fn = { Restore-Apps } }
    @{ Kinds = @('env');                     Title = 'Environment';        Fn = { Restore-Environment } }
    @{ Kinds = @('service');                 Title = 'Services';           Fn = { Restore-Services } }
    @{ Kinds = @('task');                    Title = 'Scheduled tasks';    Fn = { Restore-Tasks } }
    @{ Kinds = @('startup');                 Title = 'Startup items';      Fn = { Restore-Startup } }
    @{ Kinds = @('wsl');                     Title = 'WSL';                Fn = { Restore-Wsl } }
    @{ Kinds = @('hosts', 'fonts', 'power'); Title = 'Windows settings';   Fn = { Restore-System } }
  )
  foreach ($r in $run) {
    if (-not @($r.Kinds | Where-Object { $byKind.ContainsKey($_) }).Count) { continue }
    Say-Step $r.Title
    try { & $r.Fn } catch { Say-Fail ('{0}: {1}' -f $r.Title, $_.Exception.Message) }
  }
  foreach ($name in (& $inc 'svcstart')) { [void](Invoke-Change "Start service $name" { Set-Service -Name $name -StartupType Automatic; Start-Service -Name $name }) }
  foreach ($name in (& $inc 'dstart')) { [void](Invoke-Change "Start container $name" { $r = Invoke-MsDocker ('start ' + $name); if ($r.ExitCode -ne 0) { throw $r.Output.Trim() } }) }
  foreach ($dir in (& $inc 'compose')) {
    [void](Invoke-Change "docker compose up -d in $dir" {
      $r = Invoke-Native (Get-MsDockerExe) ('compose --project-directory "{0}" up -d' -f $dir)
      if ($r.ExitCode -ne 0) { throw $r.Output.Trim() }
    })
  }
  $media = @(& $inc 'media')
  if ($media.Count) {
    Say-Step 'Media server + smart home'
    $parts = @($media | Where-Object { $_ -ne 'network' })
    if ($media -contains 'network') { Set-MsNetworkPrivate (Test-MsNetworkProfile) }
    if ($parts.Count) { [void](Invoke-MsRepair -Only $parts -Force $parts) }
  }
  $steps = @(& $inc 'step' | ForEach-Object { [int]$_ })
  if ($steps.Count) { Say-Info ('Steps {0}: run RESTORE for those (the app''s Restore page, or "3 - RESTORE" -> type {0}).' -f ($steps -join ' ')) }
}

# ================================================================= main ====
Show-Banner 'VERIFY' 'Checks that everything from the backup is back on this PC.'
if (-not (Initialize-KitBackup -BackupPath $BackupPath -KitRoot $KitRoot)) {
  Say-Fail ('No backup found ({0}).' -f $(if ($BackupPath) { $BackupPath } else { Join-Path $KitRoot 'Backups' }))
  Exit-Kit 1 -NoPause:$NoPause
}
Update-ProcessPath
Say ('  Backup: {0}  ({1}, user {2}, {3})' -f $script:B, $script:M.System.ComputerName, $script:M.System.UserName, $script:M.CreatedAt) 'White'

# with -File, "-Fix a,b" arrives as one string
$wantFix = @($Fix | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($FixFile) { $ff = Read-Json $FixFile; if ($ff) { $wantFix += @($ff.Fix | Where-Object { $_ }) } }
if ($wantFix.Count -or $FixAll) {
  if (-not (Test-IsAdmin) -and -not $DryRun) { Say-Fail 'Putting things back needs administrator rights.'; Exit-Kit 1 -NoPause:$NoPause }
  if (-not $DryRun) { Start-KitLog (Join-Path $script:StateDir ('verify-{0}\verify.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))) }
  if ($FixAll) {
    Say-Step 'Checking'
    Invoke-VerifyChecks
    $wantFix = @($script:Checks | Where-Object { $_.FixId -and $_.Status -ne 'ok' -and $_.FixId -notlike 'step|*' } | ForEach-Object { $_.FixId })
  }
  Say-Step ('Putting back {0} item(s)' -f $wantFix.Count)
  Invoke-VerifyFixes $wantFix
  if (-not $DryRun) { Update-ProcessPath }
}

Say-Step 'Checking'
Invoke-VerifyChecks
$bad = @($script:Checks | Where-Object { $_.Status -in 'missing', 'changed', 'warn' })
$fixable = @($bad | Where-Object { $_.FixId })
if ($Out) { Save-Json @{ Backup = $script:B; CheckedAt = (Get-Date).ToString('s'); Checks = $script:Checks.ToArray() } $Out }

if (-not $script:Gui) {
  foreach ($grp in @($script:Checks | Group-Object Area)) {
    $probs = @($grp.Group | Where-Object { $_.Status -ne 'ok' })
    $okN = $grp.Count - $probs.Count
    Write-Host ''
    Write-Host ('  {0}  ({1} ok{2})' -f $grp.Name, $okN, $(if ($probs.Count) { ', ' + $probs.Count + ' to look at' } else { '' })) -ForegroundColor Cyan
    foreach ($c in $probs) {
      $col = switch ($c.Status) { 'info' { 'Gray' } 'warn' { 'Yellow' } default { 'Red' } }
      Write-Host ('    [{0,-7}] {1} - {2}{3}' -f $c.Status, $c.Name, $c.Detail, $(if ($c.FixId) { '   fix: ' + $c.FixId } else { '' })) -ForegroundColor $col
    }
  }
  Write-Host ''
}
Send-KitEvent @{ t = 'verified'; total = $script:Checks.Count; problems = $bad.Count; fixable = $fixable.Count; out = $Out }
if ($bad.Count) { Say ('  {0} thing(s) to look at, {1} of them can be put back automatically (Verify -FixAll, or the app''s Verify page).' -f $bad.Count, $fixable.Count) 'Yellow' 'warn' }
else { Say '  Everything from the backup is in place.' 'Green' 'ok' }
Exit-Kit $(if ($bad.Count) { 2 } else { 0 }) -NoPause:$NoPause
