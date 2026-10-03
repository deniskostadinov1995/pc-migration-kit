<#
  PC Migration Kit - inventory
  ----------------------------
  A read-only look at the current PC: disks, programs, services, scheduled
  tasks, startup items, WSL/Docker, fonts, environment ... plus the copy plan
  (what gets backed up) and the HTML report. Nothing in here changes the system.

  Written by Claude 2026-09-27.
#>

# Root folders of C:\ that belong to Windows or are junk; everything else at the
# root (C:\Python314, C:\ngrok ...) is treated as the user's own and backed up.
$script:SystemRootFolders = @('Boot','Config.Msi','Documents and Settings','inetpub','Intel','AMD','NVIDIA','MSOCache',
  'OneDriveTemp','PerfLogs','Program Files','Program Files (x86)','ProgramData','Recovery','System Volume Information',
  'Users','Windows','Windows.old','AVG sandbox','ESD','SWSetup','XboxGames')

# ProgramData folders whose contents are app state worth putting back.
$script:ProgramDataAllow = @('Jackett','Radarr','Radarr4K','Sonarr','Prowlarr','Lidarr','Readarr','Bazarr','Whisparr',
  'Tailscale','AnyDesk','RealVNC-Service','SteelSeries','Epic','VS Revo Group','Fingagent','ssh')

$script:ProgramDataSkip = @('Microsoft','Package Cache','Packages','SoftwareDistribution','USOPrivate','USOShared','NVIDIA',
  'NVIDIA Corporation','ChocolateyHttpCache','Windows App Certification Kit','WindowsHolographicDevices',
  'regid.1991-06.com.microsoft','AVG','Avast Software','Norton','McAfee','Kaspersky Lab','ESET','Malwarebytes','Bitdefender')

$script:ProgramFilesSkip = @('WindowsApps','ModifiableWindowsApps','Windows Defender','Windows Defender Advanced Threat Protection',
  'Windows Mail','Windows Media Player','Windows Multimedia Platform','Windows NT','Windows Photo Viewer','Windows Portable Devices',
  'Windows Security','Windows Sidebar','WindowsPowerShell','Internet Explorer','Uninstall Information','Microsoft Update Health Tools',
  'Reference Assemblies','MSBuild','dotnet','Windows Kits','Microsoft SDKs','Microsoft Visual Studio','NVIDIA GPU Computing Toolkit','AVG')

# Bits of app state that live inside Program Files.
$script:ProgramFilesRules = @(
  @{ Name = 'Steam (library list, settings, per-user data)'; Rel = 'Program Files (x86)\Steam'; Dirs = @('config','userdata','steamapps'); Files = @(); Processes = @('steam','steamwebhelper') },
  @{ Name = 'WinRAR licence';                                Rel = 'Program Files\WinRAR';     Dirs = @(); Files = @('rarreg.key'); Processes = @('WinRAR') },
  @{ Name = 'Hard Disk Sentinel settings + disk history';     Rel = 'Program Files (x86)\Hard Disk Sentinel'; Dirs = @(); Files = @('HDSentinel.ini','DISKDATA_*.dat'); Processes = @('HDSentinel') },
  @{ Name = 'DesktopOK saved icon layouts';                   Rel = 'Program Files\DesktopOK';  Dirs = @(); Files = @('*.ini','*.dok'); Processes = @('DesktopOK_x64','DesktopOK') }
)

# Folders inside the profile that are big enough to copy last (after everything
# irreplaceable is safe), relative to the profile.
$script:ProfileBigDirs = @('.ollama','AppData\Local\Google\Play Games','AppData\Local\Docker','AppData\Local\wsl','VirtualBox VMs','.cache')

$script:ProfileSkipRel = @('AppData\Local\Temp','AppData\Local\Microsoft\Windows\INetCache','AppData\Local\Microsoft\Windows\WebCache',
  'AppData\Local\Microsoft\Windows\Explorer','AppData\Local\Microsoft\Windows\Caches','AppData\Local\Microsoft\WindowsApps',
  'AppData\Local\CrashDumps','AppData\Local\D3DSCache','AppData\Local\NVIDIA\DXCache','AppData\Local\NVIDIA\GLCache',
  'AppData\Local\NVIDIA Corporation\NV_Cache','AppData\Local\AMD\DxCache','AppData\LocalLow\Microsoft\CryptnetUrlCache',
  # Windows' own mail/people store and device sync - locked while Windows runs, rebuilt by it
  'AppData\Local\Comms','AppData\Local\ConnectedDevicesPlatform')
$script:ProfileSkipNames = @('Code Cache','GPUCache','GrShaderCache','DawnCache','DawnGraphiteCache','DawnWebGPUCache')
$script:ProfileSkipFiles = @('NTUSER.DAT*','UsrClass.dat*')

# Programs that come back with Windows, a driver or a parent app - never offered for install.
$script:SystemAppPatterns = @('^Microsoft Visual C\+\+','Redistributable','^Update for','\(KB\d+\)','^Microsoft Update Health Tools',
  '^Windows Software Development Kit','^Windows SDK','^vs_','^Microsoft Visual Studio Installer','^Windows Driver Package',
  '^NVIDIA (Graphics Driver|HD Audio Driver|FrameView|PhysX|Nsight|USBC)','^Intel\(R\)','^Windows Subsystem for Linux',
  '^Microsoft Edge','^Windows 10 Update Assistant','^Microsoft \.NET','^Epic Online Services','^Python Launcher','^Npcap OEM',
  '^Java Auto Updater','^Microsoft Advertising','^Microsoft\.UI\.Xaml','^Microsoft\.VCLibs','^Realtek')

# winget ids that are frameworks or would do something unwanted on a fresh install.
$script:WingetNoInstall = @{
  'Microsoft.AppInstaller'         = 'already part of Windows'
  'Microsoft.UpdateAssistant'      = 'Windows 10 Update Assistant - would try to upgrade Windows'
  'Microsoft.Edge'                 = 'already part of Windows'
  'EpicGames.EpicOnlineServices'   = 'installed by the Epic launcher itself'
}
$script:WingetFrameworkPattern = '^(Microsoft\.UI\.Xaml|Microsoft\.VCLibs|Microsoft\.WindowsAppRuntime|Microsoft\.DotNet\.Native|Microsoft\.NET\.Native)'

# ---------------------------------------------------------------- system ---
function Get-KitSystemInfo {
  $os = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  $known = Get-KnownFolderMap
  [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    MachineGuid  = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction SilentlyContinue).MachineGuid
    OS           = $os.Caption
    Version      = $os.Version
    Build        = $os.BuildNumber
    DisplayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
    InstallDate  = $os.InstallDate.ToString('yyyy-MM-dd')
    Manufacturer = $cs.Manufacturer
    Model        = $cs.Model
    RamGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    ConsoleUser  = $cs.UserName
    UserName     = $env:USERNAME
    UserDomain   = $env:USERDOMAIN
    UserSid      = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    UserProfile  = $env:USERPROFILE
    KnownFolders = [pscustomobject]$known
    SystemDrive  = $env:SystemDrive
    Firmware     = $env:firmware_type
    IsAdmin      = (Test-IsAdmin)
  }
}

function Get-KitDisks {
  $admin = Test-IsAdmin
  $parts = @(Get-Partition -ErrorAction SilentlyContinue)
  $esp = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
  foreach ($pd in Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object { [int]$_.DeviceId }) {
    $rel = $null
    if ($admin) { try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {} }
    $num = [int]$pd.DeviceId
    $mine = @($parts | Where-Object { $_.DiskNumber -eq $num })
    $letters = @($mine | Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter + ':' })
    [pscustomobject]@{
      Number      = $num
      Model       = $pd.FriendlyName
      Serial      = ([string]$pd.SerialNumber).Trim()
      Media       = [string]$pd.MediaType
      Bus         = [string]$pd.BusType
      SizeGB      = [math]::Round($pd.Size / 1GB, 1)
      Health      = [string]$pd.HealthStatus
      Wear        = $(if ($rel) { $rel.Wear } else { $null })
      TempC       = $(if ($rel) { $rel.Temperature } else { $null })
      PowerOnHours= $(if ($rel) { $rel.PowerOnHours } else { $null })
      ReadErrors  = $(if ($rel) { $rel.ReadErrorsUncorrected } else { $null })
      Letters     = ($letters -join ' ')
      HasWindows  = [bool]($mine | Where-Object { [string]$_.DriveLetter -eq $env:SystemDrive.Substring(0,1) })
      HasEsp      = [bool]($mine | Where-Object { [string]$_.GptType -eq $esp })
    }
  }
}

function Get-KitVolumes {
  $sys = $env:SystemDrive.Substring(0, 1).ToUpper()
  foreach ($v in Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }) {
    $letter = ([string]$v.DriveLetter).Substring(0, 1).ToUpper()
    $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    $disk = $null
    if ($part) { $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue }
    [pscustomobject]@{
      Letter        = $letter
      Label         = $v.Label
      FileSystem    = $v.FileSystem
      DriveType     = [int]$v.DriveType
      SizeGB        = [math]::Round($v.Capacity / 1GB, 1)
      FreeGB        = [math]::Round($v.FreeSpace / 1GB, 1)
      SerialNumber  = $v.SerialNumber
      DeviceId      = $v.DeviceID
      PartitionGuid = $(if ($part) { [string]$part.Guid } else { $null })
      DiskNumber    = $(if ($part) { $part.DiskNumber } else { $null })
      DiskModel     = $(if ($disk) { $disk.FriendlyName } else { $null })
      DiskSerial    = $(if ($disk) { ([string]$disk.SerialNumber).Trim() } else { $null })
      BusType       = $(if ($disk) { [string]$disk.BusType } else { $null })
      IsSystemDrive = ($letter -eq $sys)
    }
  }
}

function Get-KitBootLayout($Disks) {
  $win = @($Disks | Where-Object { $_.HasWindows }) | Select-Object -First 1
  $esp = @($Disks | Where-Object { $_.HasEsp })
  $split = $false
  if ($win -and $esp.Count -gt 0 -and -not ($esp | Where-Object { $_.Number -eq $win.Number })) { $split = $true }
  [pscustomobject]@{
    WindowsDisk  = $(if ($win) { '{0} (disk {1})' -f $win.Model, $win.Number } else { $null })
    EspDisks     = (($esp | ForEach-Object { '{0} (disk {1}{2})' -f $_.Model, $_.Number, $(if ($_.Letters) { ', ' + $_.Letters } else { '' }) }) -join '; ')
    Split        = $split
  }
}

# -------------------------------------------------------------- programs ---
# Where a program really lives. Many installers leave InstallLocation empty, so
# fall back to the folder of the uninstaller or icon (Jellyfin on G:\ is one).
function Get-ProgramHome($Entry) {
  $loc = ([string]$Entry.InstallLocation).Trim('"', ' ')
  if ($loc) { return $loc }
  foreach ($v in @($Entry.UninstallString, $Entry.DisplayIcon)) {
    $exe = Get-CommandExe (([string]$v) -replace ',\s*-?\d+$', '')
    if ($exe -and $exe -match '^[A-Za-z]:\\' -and $exe -notmatch '(?i)\\(msiexec|rundll32)\.exe$' -and
        $exe -notmatch '(?i)^[A-Za-z]:\\(ProgramData\\Package Cache|Windows)\\') { return (Split-Path $exe -Parent) }
  }
  return ''
}

function Get-KitPrograms {
  $paths = @(
    @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Scope = 'Machine' },
    @{ P = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine' },
    @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Scope = 'User' }
  )
  $seen = @{}
  foreach ($x in $paths) {
    foreach ($e in Get-ItemProperty $x.P -ErrorAction SilentlyContinue) {
      if (-not $e.DisplayName) { continue }
      if ($e.SystemComponent -eq 1 -or $e.ParentKeyName) { continue }
      if ($e.ReleaseType -in 'Update','Hotfix','Security Update') { continue }
      $name = ([string]$e.DisplayName).Trim()
      if ($seen.ContainsKey($name)) { continue }
      $seen[$name] = $true
      [pscustomobject]@{
        Name            = $name
        Version         = [string]$e.DisplayVersion
        Publisher       = [string]$e.Publisher
        InstallLocation = ([string]$e.InstallLocation).Trim('"', ' ')
        Home            = (Get-ProgramHome $e)
        Scope           = $x.Scope
      }
    }
  }
}

function Get-KitStoreApps {
  foreach ($p in Get-AppxPackage -ErrorAction SilentlyContinue) {
    if ($p.IsFramework -or $p.NonRemovable -or $p.IsResourcePackage) { continue }
    if ($p.SignatureKind -eq 'System') { continue }
    if ($p.Publisher -match 'CN=Microsoft (Corporation|Windows)') { continue }
    $display = $p.Name
    try {
      $m = Get-AppxPackageManifest $p -ErrorAction Stop
      $d = [string]$m.Package.Properties.DisplayName
      if ($d -and $d -notlike 'ms-resource:*') { $display = $d }
    } catch {}
    [pscustomobject]@{ Name = $display; PackageName = $p.Name; FamilyName = $p.PackageFamilyName; Version = [string]$p.Version; SignatureKind = [string]$p.SignatureKind }
  }
}

# Runs "winget export" and works out which installed programs it could NOT
# match. The message text is localized, so the program name is taken from the
# end of each message line and checked against the real program list.
function Invoke-KitWingetExport([string]$OutFile, $Programs, $StoreApps) {
  $r = [pscustomobject]@{ Available = $false; Packages = @(); Unmatched = @(); Error = $null }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { $r.Error = 'winget is not installed'; return $r }
  $r.Available = $true
  New-Dir (Split-Path $OutFile -Parent) | Out-Null
  $lines = @(& winget export -o $OutFile --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { [string]$_ })
  $names = @{}
  foreach ($ln in $lines) {
    $m = [regex]::Match($ln, '^[^:]*:\s+(.+?)\s*$')
    if ($m.Success) { $names[$m.Groups[1].Value] = $true }
  }
  $r.Unmatched = @(@($Programs | ForEach-Object { $_.Name }) + @($StoreApps | ForEach-Object { $_.Name }) | Where-Object { $names.ContainsKey($_) } | Sort-Object -Unique)
  $j = Read-Json $OutFile
  if ($j) {
    $r.Packages = @(foreach ($s in $j.Sources) { foreach ($pk in $s.Packages) { [pscustomobject]@{ Id = $pk.PackageIdentifier; Source = $s.SourceDetails.Name; Version = [string]$pk.Version } } })
  } else { $r.Error = 'winget export produced no file' }
  # the versions, for runtimes that must come back at the same version (see RestoreSteps.ps1)
  $vf = [IO.Path]::ChangeExtension($OutFile, '.versions.json')
  $null = & winget export -o $vf --include-versions --accept-source-agreements --disable-interactivity 2>&1
  $jv = Read-Json $vf
  if ($jv) {
    $ver = @{}
    foreach ($s in $jv.Sources) { foreach ($pk in $s.Packages) { if ($pk.Version) { $ver[$pk.PackageIdentifier] = [string]$pk.Version } } }
    foreach ($p in $r.Packages) { if ($ver.ContainsKey($p.Id)) { $p.Version = $ver[$p.Id] } }
  }
  return $r
}

function ConvertFrom-WingetTable($Lines) {
  $clean = @($Lines | ForEach-Object { $s = [string]$_; $i = $s.LastIndexOf("`r"); if ($i -ge 0) { $s.Substring($i + 1) } else { $s } })
  $sep = -1
  for ($i = 0; $i -lt $clean.Count; $i++) { if ($clean[$i] -match '^\s*-{8,}\s*$') { $sep = $i; break } }
  if ($sep -lt 1) { return @() }
  $header = $clean[$sep - 1]
  $starts = @([regex]::Matches($header, '(?:^|(?<=\s))\S') | ForEach-Object { $_.Index })
  if ($starts.Count -lt 2) { return @() }
  $rows = @()
  for ($i = $sep + 1; $i -lt $clean.Count; $i++) {
    $ln = $clean[$i]
    if ($ln.Trim().Length -eq 0 -or $ln.Length -le $starts[1]) { continue }
    $end = $ln.Length
    if ($starts.Count -gt 2) { $end = [Math]::Min($starts[2], $ln.Length) }
    $id = $ln.Substring($starts[1], $end - $starts[1]).Trim()
    if ($id -match '^\S+$') { $rows += [pscustomobject]@{ Name = $ln.Substring(0, $starts[1]).Trim(); Id = $id } }
  }
  return $rows
}

function Find-KitWingetIdByName([string]$Name) {
  $hit = Find-KitAppByName $Name -WingetOnly
  if ($hit) { return $hit.Id }
  return $null
}

# A program name as Apps & Features shows it, without version, bitness and edition noise.
function Get-KitCleanAppName([string]$Name) {
  $c = $Name -replace '\s*\((64-bit|32-bit|x64|x86|remove only)\)', '' -replace ('[' + [char]0x00AE + [char]0x2122 + ']'), ''
  return (($c -replace '\s+v?\d+(\.\d+){1,3}\b.*$', '').Trim())
}

# Finds the winget (or Microsoft Store) package for an installed program, by name.
# Exact names first; then the name without its edition word, keeping only a result
# of the same edition - "Hard Disk Sentinel PRO" is "Hard Disk Sentinel Professional"
# in winget (found on 2026-10-02), "NVIDIA App" only exists in the Store.
function Find-KitAppByName([string]$Name, [switch]$WingetOnly) {
  $clean = Get-KitCleanAppName $Name
  if ($clean.Length -lt 3) { return $null }
  $notWanted = '(?i)beta|\.dev|canary|nightly|preview|portable|insider|\.exe$'
  $search = {
    param([string]$Text, [string]$Source, [switch]$Exact)
    $a = @('search', '--name', $Text, '--source', $Source, '--accept-source-agreements', '--disable-interactivity')
    if ($Exact) { $a += '--exact' }
    @(ConvertFrom-WingetTable @(& winget @a 2>$null))
  }
  $hits = @(& $search $clean 'winget' -Exact)
  if ($hits.Count -gt 1) { $hits = @($hits | Where-Object { $_.Id -notmatch $notWanted }) }
  if ($hits.Count -eq 1) { return [pscustomobject]@{ Id = $hits[0].Id; Source = 'winget'; Name = $hits[0].Name } }

  $editions = @{ 'pro' = 'pro|professional'; 'professional' = 'pro|professional'; 'free' = 'free'; 'standard' = 'standard'; 'home' = 'home'
                 'premium' = 'premium'; 'ultimate' = 'ultimate'; 'community' = 'community'; 'enterprise' = 'enterprise'; 'plus' = 'plus'; 'lite' = 'lite' }
  $m = [regex]::Match($clean, '^(?<base>.+?)\s+(?<ed>[A-Za-z]+)$')
  if ($m.Success -and $editions.ContainsKey($m.Groups['ed'].Value.ToLower())) {
    $base = $m.Groups['base'].Value
    $edRx = '(?i)^' + [regex]::Escape($base) + '\s+(' + $editions[$m.Groups['ed'].Value.ToLower()] + ')$'
    $cands = @(& $search $base 'winget' | Where-Object { $_.Name -match $edRx -and $_.Id -notmatch $notWanted })
    if ($cands.Count -eq 1) { return [pscustomobject]@{ Id = $cands[0].Id; Source = 'winget'; Name = $cands[0].Name } }
  }
  if ($WingetOnly) { return $null }
  $store = @(& $search $clean 'msstore' -Exact | Where-Object { $_.Name -ieq $clean })
  if ($store.Count -eq 1) { return [pscustomobject]@{ Id = $store[0].Id; Source = 'msstore'; Name = $store[0].Name } }
  return $null
}

function Test-SystemApp([string]$Name) {
  foreach ($pat in $script:SystemAppPatterns) { if ($Name -match $pat) { return $true } }
  return $false
}

# Decides, per installed program, how it comes back after a fresh install.
function Resolve-KitAppPlan($Programs, $StoreApps, $Winget, [switch]$SearchUnmatched) {
  $sysLetter = $env:SystemDrive.Substring(0, 1).ToUpper()
  $install = New-Object System.Collections.Generic.List[object]
  $seenIds = @{}
  foreach ($pk in $Winget.Packages) {
    if ($seenIds.ContainsKey($pk.Id)) { continue }
    $seenIds[$pk.Id] = $true
    $skip = $null
    if ($script:WingetNoInstall.ContainsKey($pk.Id)) { $skip = $script:WingetNoInstall[$pk.Id] }
    elseif ($pk.Id -match $script:WingetFrameworkPattern) { $skip = 'framework - installed automatically when an app needs it' }
    $install.Add([pscustomobject]@{ Id = $pk.Id; Source = $pk.Source; How = 'winget export'; Skip = $skip; Name = $null; Version = $pk.Version })
  }

  $manual = New-Object System.Collections.Generic.List[object]
  $system = New-Object System.Collections.Generic.List[object]
  $otherDrive = New-Object System.Collections.Generic.List[object]
  $unmatched = @{}
  foreach ($n in $Winget.Unmatched) { $unmatched[$n] = $true }
  $toSearch = @()

  foreach ($p in $Programs) {
    if ($p.Home -match '^([A-Za-z]):\\' -and $Matches[1].ToUpper() -ne $sysLetter) {
      # lives on a drive that is being kept; if winget knows it, a reinstall would
      # put a second, empty copy on C: next to it - take it off the list
      $otherDrive.Add($p)
      if (-not $unmatched.ContainsKey($p.Name) -and $Winget.Available -and $SearchUnmatched) {
        $id = Find-KitWingetIdByName $p.Name
        $hit = @($install | Where-Object { $_.Id -eq $id -and -not $_.Skip }) | Select-Object -First 1
        if ($hit) { $hit.Skip = 'lives on ' + $p.Home.Substring(0, 2) + ' and is kept there - a second copy on C: would clash with it' }
      }
      continue
    }
    if (-not $unmatched.ContainsKey($p.Name) -and $Winget.Available) { continue }
    if (Test-SystemApp $p.Name) { $system.Add($p); continue }
    if ($p.Publisher -in 'Google\Chrome', 'Microsoft\Edge') { $system.Add($p); continue }   # web apps installed from the browser
    $toSearch += $p
  }

  if ($SearchUnmatched -and $Winget.Available -and $toSearch.Count) {
    Say-Info ('Looking up {0} more apps in winget by name...' -f $toSearch.Count)
    $i = 0
    foreach ($p in $toSearch) {
      $i++
      Show-KitProgress 'Looking up apps by name' $p.Name ([int](100 * $i / $toSearch.Count))
      # antivirus programs are left to the person (they take over the firewall and Windows Security)
      $hit = $null
      if ($p.Name -notmatch '(?i)\b(AVG|Avast|Norton|McAfee|Kaspersky|ESET|Malwarebytes|Bitdefender|Avira|Sophos)\b') { $hit = Find-KitAppByName $p.Name }
      if ($hit -and -not $seenIds.ContainsKey($hit.Id)) {
        $seenIds[$hit.Id] = $true
        $install.Add([pscustomobject]@{ Id = $hit.Id; Source = $hit.Source; How = 'matched by name'; Skip = $null; Name = $p.Name; Version = $p.Version })
      } elseif ($hit) {
        # already on the list under the same id
      } else { $manual.Add($p) }
    }
    Show-KitProgress 'Looking up apps by name' '' -Completed
  } else { foreach ($p in $toSearch) { $manual.Add($p) } }

  $store = @($StoreApps | ForEach-Object {
    $viaWinget = -not $unmatched.ContainsKey($_.Name)
    [pscustomobject]@{ Name = $_.Name; FamilyName = $_.FamilyName; Version = $_.Version; ViaWinget = $viaWinget }
  })

  [pscustomobject]@{
    Install    = $install.ToArray()
    Manual     = $manual.ToArray()
    System     = $system.ToArray()
    OtherDrive = $otherDrive.ToArray()
    Store      = $store
  }
}

# ---------------------------------------------------- automations & system ---
function Get-KitServices {
  foreach ($s in Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) {
    $exe = Get-CommandExe $s.PathName
    if (-not $exe -or $exe -match '\\svchost\.exe$') { continue }
    $company = ''
    if (Test-Path -LiteralPath $exe) { try { $company = [string](Get-Item -LiteralPath $exe).VersionInfo.CompanyName } catch {} }
    if ($company -match 'Microsoft') { continue }
    if (-not $company -and $exe -match '^[A-Za-z]:\\Windows\\') { continue }
    $origin = 'app'
    if ($exe -match '\\DriverStore\\') { $origin = 'driver' }
    elseif ($exe -match '\\WindowsApps\\') { $origin = 'store' }
    elseif ($exe -match '^[A-Za-z]:\\Windows\\') { $origin = 'driver' }
    $delayed = $false
    try { $delayed = [bool](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)" -Name DelayedAutostart -ErrorAction Stop).DelayedAutostart } catch {}
    [pscustomobject]@{
      Name = $s.Name; DisplayName = $s.DisplayName; PathName = $s.PathName; Exe = $exe; StartMode = $s.StartMode
      DelayedAutoStart = $delayed; StartName = $s.StartName; State = $s.State; Description = $s.Description
      Company = $company; Origin = $origin
    }
  }
}

function Test-VendorTask([string]$Path, [string]$Name, [string]$Exe) {
  $inProgramFiles = ($Exe -match '^[A-Za-z]:\\Program Files' -or $Exe -match '\\WindowsApps\\')
  return ($inProgramFiles -and (($Path + $Name) -match '(?i)update|updater|notifier|telemetry|experiencehelper|crashreport|watchdog'))
}

function Get-KitTasks {
  foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
    if ($t.TaskPath -like '\Microsoft\*') { continue }
    $acts = @($t.Actions | Where-Object { $_.Execute } | ForEach-Object { [pscustomobject]@{ Execute = $_.Execute; Arguments = $_.Arguments; WorkingDirectory = $_.WorkingDirectory } })
    $firstExe = $null
    if ($acts.Count) { $firstExe = Get-CommandExe ('"' + $acts[0].Execute.Trim('"') + '"') }
    [pscustomobject]@{
      Path      = $t.TaskPath
      Name      = $t.TaskName
      State     = [string]$t.State
      UserId    = $t.Principal.UserId
      LogonType = [string]$t.Principal.LogonType
      RunLevel  = [string]$t.Principal.RunLevel
      Actions   = $acts
      Exe       = $firstExe
      Command   = (($acts | ForEach-Object { ($_.Execute + ' ' + $_.Arguments).Trim() }) -join ' ; ')
      IsVendor  = (Test-VendorTask $t.TaskPath $t.TaskName $firstExe)
    }
  }
}

function Get-StartupApprovedState([string]$Key, [string]$Name) {
  try {
    $v = (Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop).$Name
    if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
  } catch {}
  return $true
}

function Get-KitStartup {
  $runKeys = @(
    @{ Hive = 'HKCU';   Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Hive = 'HKLM';   Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Hive = 'HKLM32'; Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
  )
  foreach ($rk in $runKeys) {
    $k = Get-Item -LiteralPath $rk.Key -ErrorAction SilentlyContinue
    if (-not $k) { continue }
    foreach ($n in $k.GetValueNames()) {
      if (-not $n) { continue }
      $v = [string]$k.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
      [pscustomobject]@{ Type = 'Run'; Hive = $rk.Hive; Name = $n; Command = $v; Kind = [string]$k.GetValueKind($n)
                         Enabled = (Get-StartupApprovedState $rk.Approved $n); Exe = (Get-CommandExe $v); File = $null }
    }
  }
  $folders = @(
    @{ Scope = 'User';   Path = [Environment]::GetFolderPath('Startup');       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
    @{ Scope = 'Common'; Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
  )
  $sh = New-Object -ComObject WScript.Shell
  foreach ($f in $folders) {
    if (-not $f.Path) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
      $cmd = $file.FullName; $exe = $file.FullName
      if ($file.Extension -eq '.lnk') {
        try { $l = $sh.CreateShortcut($file.FullName); $cmd = ('"{0}" {1}' -f $l.TargetPath, $l.Arguments).Trim(); $exe = $l.TargetPath } catch {}
      }
      [pscustomobject]@{ Type = 'Folder'; Hive = $f.Scope; Name = $file.Name; Command = $cmd; Kind = 'File'
                         Enabled = (Get-StartupApprovedState $f.Approved $file.Name); Exe = $exe; File = $file.FullName }
    }
  }
}

function Get-KitEnvironment {
  $scopes = @(
    @{ Scope = 'User';    Key = 'HKCU:\Environment' },
    @{ Scope = 'Machine'; Key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
  )
  foreach ($s in $scopes) {
    $k = Get-Item -LiteralPath $s.Key -ErrorAction SilentlyContinue
    if (-not $k) { continue }
    foreach ($n in $k.GetValueNames()) {
      if (-not $n) { continue }
      [pscustomobject]@{ Scope = $s.Scope; Name = $n; Value = [string]$k.GetValue($n, $null, 'DoNotExpandEnvironmentNames'); Kind = [string]$k.GetValueKind($n) }
    }
  }
}

function Get-KitWsl {
  $default = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue).DefaultDistribution
  foreach ($k in Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue) {
    $p = Get-ItemProperty -LiteralPath $k.PSPath
    if (-not $p.DistributionName) { continue }
    $base = ([string]$p.BasePath) -replace '^\\\\\?\\', ''
    $vhdx = Join-Path $base 'ext4.vhdx'
    $size = 0
    if (Test-Path -LiteralPath $vhdx) { $size = (Get-Item -LiteralPath $vhdx).Length }
    [pscustomobject]@{ Name = $p.DistributionName; Guid = $k.PSChildName; BasePath = $base; Vhdx = $vhdx; VhdxBytes = $size
                       DefaultUid = $p.DefaultUid; Version = $p.Version; IsDocker = ($p.DistributionName -like 'docker-desktop*')
                       IsDefault = ($k.PSChildName -eq $default) }
  }
}

function Get-KitDocker {
  $r = [pscustomobject]@{ Installed = $false; Reachable = $false; Containers = @(); Volumes = @(); ComposeDirs = @() }
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $r }
  $r.Installed = $true
  $ids = @(& docker ps -aq 2>$null)
  if ($LASTEXITCODE -ne 0) { return $r }
  $r.Reachable = $true
  if ($ids.Count) {
    try {
      $info = (& docker inspect $ids 2>$null) -join "`n" | ConvertFrom-Json
      $r.Containers = @($info | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name.TrimStart('/'); Image = $_.Config.Image; Status = $_.State.Status
                           ComposeDir = $_.Config.Labels.'com.docker.compose.project.working_dir' }
      })
      $r.ComposeDirs = @($r.Containers | Where-Object { $_.ComposeDir } | ForEach-Object { $_.ComposeDir } | Sort-Object -Unique)
    } catch {}
  }
  $r.Volumes = @(& docker volume ls -q 2>$null)
  return $r
}

function Get-KitWifiNames {
  $out = @(& netsh.exe wlan show profiles 2>$null)
  return @($out | ForEach-Object { if ([string]$_ -match '^\s{2,}\S.*?\s:\s(.+)$') { $Matches[1].Trim() } } | Where-Object { $_ })
}

function Get-KitPrinters {
  @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(Microsoft Print to PDF|Microsoft XPS Document Writer|Fax|OneNote|Send To OneNote)' } |
    ForEach-Object { [pscustomobject]@{ Name = $_.Name; Driver = $_.DriverName; Port = $_.PortName; Type = [string]$_.Type } })
}

function Get-KitMappedDrives {
  @(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ Letter = $_.PSChildName; RemotePath = (Get-ItemProperty -LiteralPath $_.PSPath).RemotePath }
  })
}

function Get-KitFonts {
  $fontDir = Join-Path $env:windir 'Fonts'
  $map = @{}
  $reg = Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction SilentlyContinue
  if ($reg) { foreach ($n in $reg.GetValueNames()) { $f = [string]$reg.GetValue($n); if ($f) { $map[[IO.Path]::GetFileName($f).ToLower()] = $n } } }
  $machine = @(foreach ($f in Get-ChildItem -LiteralPath $fontDir -File -Force -ErrorAction SilentlyContinue) {
    if ($f.Name -eq 'desktop.ini') { continue }
    $owner = ''
    try { $owner = (Get-Acl -LiteralPath $f.FullName).Owner } catch {}
    if ($owner -match 'TrustedInstaller') { continue }
    [pscustomobject]@{ File = $f.Name; RegName = $map[$f.Name.ToLower()]; Bytes = $f.Length }
  })
  $umap = @{}
  $ureg = Get-Item 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction SilentlyContinue
  if ($ureg) { foreach ($n in $ureg.GetValueNames()) { $f = [string]$ureg.GetValue($n); if ($f) { $umap[[IO.Path]::GetFileName($f).ToLower()] = $n } } }
  $user = @(foreach ($f in Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts') -File -Force -ErrorAction SilentlyContinue) {
    [pscustomobject]@{ File = $f.Name; RegName = $umap[$f.Name.ToLower()]; Bytes = $f.Length }
  })
  [pscustomobject]@{ Machine = $machine; User = $user }
}

function Get-KitRootFolders([string]$Root) {
  if (-not $Root) { $Root = $env:SystemDrive + '\' }
  @(foreach ($d in Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue) {
    if ($d.Name.StartsWith('$') -or $d.Name -like 'PCMK-snap-*') { continue }
    if ($script:SystemRootFolders -contains $d.Name) { continue }
    if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    if (($d.Attributes -band [IO.FileAttributes]::Hidden) -and ($d.Attributes -band [IO.FileAttributes]::System)) { continue }
    $d.Name
  })
}

function Get-KitCredentialTargets {
  $out = @(& cmdkey.exe /list 2>$null)
  @($out | ForEach-Object {
    $m = [regex]::Match([string]$_, '(?i)(?:LegacyGeneric|Domain|Generic)[^=\s]*=(.+)$')
    if ($m.Success) { $m.Groups[1].Value.Trim() }
  } | Sort-Object -Unique)
}

function Get-KitChoco {
  if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { return @() }
  $ver = [string](& choco --version 2>$null | Select-Object -First 1)
  if ($ver -match '^[01]\.') { $out = & choco list --local-only --limit-output 2>$null } else { $out = & choco list --limit-output 2>$null }
  @($out | Where-Object { [string]$_ -match '^[^|]+\|[^|]+$' } | ForEach-Object { $a = ([string]$_) -split '\|'; [pscustomobject]@{ Id = $a[0]; Version = $a[1] } })
}

function Get-KitVsInstances {
  $root = Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages\_Instances'
  @(foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
    $f = Join-Path $d.FullName 'state.json'
    if (-not (Test-Path -LiteralPath $f)) { continue }
    try { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    $comps = @($j.selectedPackages | Where-Object { $_.type -in 'Workload', 'Component' } | ForEach-Object { $_.id } | Sort-Object -Unique)
    [pscustomobject]@{ InstanceId = $d.Name; Product = $j.product.id; Version = $j.product.version; Channel = $j.channelId; Path = $j.installationPath; Components = $comps }
  })
}

function Get-KitOptionalFeatures {
  if (-not (Test-IsAdmin)) { return $null }
  try { return @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' } | ForEach-Object { $_.FeatureName } | Sort-Object) }
  catch { return $null }
}

function Get-KitHyperVVms {
  if (-not (Test-IsAdmin) -or -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return @() }
  try { return @(Get-VM -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = [string]$_.State; Path = $_.Path } }) } catch { return @() }
}

function Get-KitPythonInstalls {
  foreach ($root in 'HKLM:\SOFTWARE\Python\PythonCore', 'HKCU:\SOFTWARE\Python\PythonCore') {
    foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
      $ip = (Get-ItemProperty -LiteralPath "$($k.PSPath)\InstallPath" -ErrorAction SilentlyContinue).'(default)'
      if ($ip) { [pscustomobject]@{ Version = $k.PSChildName; InstallPath = ([string]$ip).TrimEnd('\'); Hive = $root.Substring(0, 4) } }
    }
  }
}

function Get-KitHostsEntries {
  $f = Join-Path $env:windir 'System32\drivers\etc\hosts'
  # plain strings: lines from Get-Content carry PSDrive/PSProvider notes that ConvertTo-Json follows forever
  @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { [string]$_ })
}

function Get-KitDriveReferences($Inv) {
  $sys = $env:SystemDrive.Substring(0, 1).ToUpper()
  $refs = @{}
  $add = {
    param($Text, $What)
    foreach ($m in [regex]::Matches([string]$Text, '(?<![A-Za-z])([A-Za-z]):\\')) {
      $l = $m.Groups[1].Value.ToUpper()
      if ($l -eq $sys) { continue }
      if (-not $refs.ContainsKey($l)) { $refs[$l] = New-Object System.Collections.Generic.List[string] }
      if (-not $refs[$l].Contains($What)) { $refs[$l].Add($What) }
    }
  }
  foreach ($t in $Inv.Tasks)       { & $add $t.Command ('Scheduled task: ' + $t.Name) }
  foreach ($s in $Inv.Startup)     { & $add $s.Command ('Startup: ' + $s.Name) }
  foreach ($s in $Inv.Services)    { & $add $s.PathName ('Service: ' + $s.Name) }
  foreach ($e in $Inv.Environment) { & $add $e.Value ('Environment: ' + $e.Name) }
  foreach ($p in $Inv.Programs)    { & $add $p.Home ('Installed on it: ' + $p.Name) }
  foreach ($c in $Inv.Docker.ComposeDirs) { & $add $c ('Docker compose project') }
  @($refs.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Letter = $_; Uses = @($refs[$_]) } })
}

# ------------------------------------------------------------ copy plan ----
# What the backup copies, as paths relative to the system drive root so the
# same plan works against the live C:\ or a shadow-copy snapshot of it.
function Get-KitCopyPlan($Inv) {
  $sysRoot = $env:SystemDrive + '\'
  $userProfile = $Inv.System.UserProfile.TrimEnd('\')
  $profileRel = $userProfile.Substring(3)
  $jobs = New-Object System.Collections.Generic.List[object]
  $knownRel = @()

  $order = @('Desktop', 'Documents', 'Pictures', 'Music', 'Downloads', 'Videos')
  $known = @{}
  foreach ($name in $order) {
    $path = [string]$Inv.System.KnownFolders.$name
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
    if (-not $path.StartsWith($sysRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $rel = $path.Substring(3)
    $knownRel += $rel
    $known[$name] = [pscustomobject]@{ Label = "Your $name folder"; Rel = $rel; Dest = "files\KnownFolders\$name"; ExcludeRel = @(); ExcludeNames = @(); ExcludeFiles = @(); Phase = $(if ($name -in 'Downloads', 'Videos') { 3 } else { 1 }) }
  }
  foreach ($name in $order) { if ($known.ContainsKey($name) -and $known[$name].Phase -eq 1) { $jobs.Add($known[$name]) } }

  $bigRel = @($script:ProfileBigDirs | ForEach-Object { Join-Path $profileRel $_ })
  $skipRel = @($script:ProfileSkipRel | ForEach-Object { Join-Path $profileRel $_ })
  $oneDrive = @(Get-ChildItem -LiteralPath $userProfile -Directory -Force -Filter 'OneDrive*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $profileRel $_.Name })
  $jobs.Add([pscustomobject]@{ Label = 'Your profile (AppData, settings, dot-folders)'; Rel = $profileRel; Dest = "files\C\$profileRel"
                               ExcludeRel = @($knownRel + $bigRel + $skipRel + $oneDrive); ExcludeNames = $script:ProfileSkipNames; ExcludeFiles = $script:ProfileSkipFiles; Phase = 1 })

  foreach ($r in $Inv.RootFolders) {
    $jobs.Add([pscustomobject]@{ Label = "C:\$r"; Rel = $r; Dest = "files\C\$r"; ExcludeRel = @(); ExcludeNames = @(); ExcludeFiles = @(); Phase = 1 })
  }
  $jobs.Add([pscustomobject]@{ Label = 'ProgramData (service and app data)'; Rel = 'ProgramData'; Dest = 'files\C\ProgramData'
                               ExcludeRel = @($script:ProgramDataSkip | ForEach-Object { Join-Path 'ProgramData' $_ }); ExcludeNames = @(); ExcludeFiles = @(); Phase = 2 })
  $jobs.Add([pscustomobject]@{ Label = 'Public user folder'; Rel = 'Users\Public'; Dest = 'files\C\Users\Public'; ExcludeRel = @(); ExcludeNames = @(); ExcludeFiles = @('desktop.ini'); Phase = 2 })
  foreach ($pf in 'Program Files', 'Program Files (x86)') {
    $jobs.Add([pscustomobject]@{ Label = $pf; Rel = $pf; Dest = "files\C\$pf"
                                 ExcludeRel = @($script:ProgramFilesSkip | ForEach-Object { Join-Path $pf $_ }); ExcludeNames = @(); ExcludeFiles = @(); Phase = 2 })
  }
  foreach ($name in $order) { if ($known.ContainsKey($name) -and $known[$name].Phase -eq 3) { $jobs.Add($known[$name]) } }
  foreach ($b in $script:ProfileBigDirs) {
    $rel = Join-Path $profileRel $b
    if (Test-Path -LiteralPath (Join-Path $sysRoot $rel)) {
      $jobs.Add([pscustomobject]@{ Label = "Big folder: $b"; Rel = $rel; Dest = "files\C\$rel"; ExcludeRel = @(); ExcludeNames = @(); ExcludeFiles = @(); Phase = 3 })
    }
  }
  return $jobs.ToArray()
}

function Measure-KitCopyPlan($Plan) {
  $root = $env:SystemDrive + '\'
  $total = 0.0
  foreach ($j in $Plan) {
    $src = Join-Path $root $j.Rel
    $ex = @($j.ExcludeRel | ForEach-Object { Join-Path $root $_ }) + @($j.ExcludeNames)
    $m = Measure-Tree $src $ex $j.ExcludeFiles
    $j | Add-Member -NotePropertyName EstimatedBytes -NotePropertyValue $m.Bytes -Force
    $j | Add-Member -NotePropertyName EstimatedFiles -NotePropertyValue $m.Files -Force
    $total += $m.Bytes
  }
  return $total
}

# ------------------------------------------------------------ orchestrator ---
function Get-KitInventory([string]$WingetExportPath, [switch]$Quick) {
  $inv = [ordered]@{}
  Say-Info 'Windows, disks and drive letters...'
  $inv.System   = Get-KitSystemInfo
  $inv.Disks    = @(Get-KitDisks)
  $inv.Volumes  = @(Get-KitVolumes)
  $inv.Boot     = Get-KitBootLayout $inv.Disks
  Say-Info 'Installed programs and Store apps...'
  $inv.Programs  = @(Get-KitPrograms | Sort-Object Name)
  $inv.StoreApps = @(Get-KitStoreApps | Sort-Object Name)
  Say-Info 'Asking winget which programs it can reinstall automatically (about a minute)...'
  if (-not $WingetExportPath) { $WingetExportPath = Join-Path $env:TEMP ('pcmk-winget-{0}.json' -f (Get-Random)) }
  $inv.Winget  = Invoke-KitWingetExport $WingetExportPath $inv.Programs $inv.StoreApps
  $inv.AppPlan = Resolve-KitAppPlan $inv.Programs $inv.StoreApps $inv.Winget -SearchUnmatched:(-not $Quick)
  Say-Info 'Services, scheduled tasks, startup items, environment...'
  $inv.Services    = @(Get-KitServices | Sort-Object Name)
  $inv.Tasks       = @(Get-KitTasks | Sort-Object Path, Name)
  $inv.Startup     = @(Get-KitStartup)
  $inv.Environment = @(Get-KitEnvironment)
  Say-Info 'WSL, Docker, Visual Studio, Chocolatey...'
  $inv.Wsl         = @(Get-KitWsl)
  $inv.Docker      = Get-KitDocker
  $inv.VsInstances = @(Get-KitVsInstances)
  $inv.Choco       = @(Get-KitChoco)
  $inv.HyperV      = @(Get-KitHyperVVms)
  Say-Info 'Fonts, printers, Wi-Fi, network drives, saved credentials...'
  $inv.Fonts       = Get-KitFonts
  $inv.Printers    = @(Get-KitPrinters)
  $inv.Wifi        = @(Get-KitWifiNames)
  $inv.MappedDrives= @(Get-KitMappedDrives)
  $inv.Credentials = @(Get-KitCredentialTargets)
  $inv.Hosts       = @(Get-KitHostsEntries)
  $inv.RootFolders = @(Get-KitRootFolders)
  $inv.Python      = @(Get-KitPythonInstalls)
  # A Python that lives in its own C:\ folder comes back as files (with every
  # pip package) - a fresh winget install would be empty.
  foreach ($a in $inv.AppPlan.Install) {
    if ($a.Skip) { continue }
    if ($a.Id -match '^Python\.Python\.(\d+\.\d+)$') {
      $ver = $Matches[1]
      $hit = @($inv.Python | Where-Object { $_.Version -eq $ver -and $_.InstallPath -match '^[A-Za-z]:\\[^\\]+$' }) | Select-Object -First 1
      if ($hit -and ($inv.RootFolders -contains $hit.InstallPath.Substring(3))) { $a.Skip = 'restored from the backup files at ' + $hit.InstallPath + ', with your pip packages' }
    }
  }
  $inv.Features    = Get-KitOptionalFeatures
  $inv.OtherUsers  = @(Get-ChildItem (Split-Path $env:USERPROFILE -Parent) -Directory -Force -ErrorAction SilentlyContinue |
                       Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.Name -notin @('Public', 'Default', $env:USERNAME) } |
                       ForEach-Object { $_.Name })
  $obj = [pscustomobject]$inv
  $obj | Add-Member -NotePropertyName DriveRefs -NotePropertyValue @(Get-KitDriveReferences $obj)
  return $obj
}

# ------------------------------------------------------------------ report ---
function Get-KitSignInApps($Inv) {
  $known = [ordered]@{
    'Chrome' = 'Google Chrome'; 'Steam' = 'Steam'; 'Epic Games' = 'Epic Games Launcher'; 'Telegram' = 'Telegram'; 'Plex Media Server' = 'Plex (the server may need to be claimed again)'
    'Tailscale' = 'Tailscale'; 'AnyDesk' = 'AnyDesk'; 'RealVNC' = 'RealVNC'; 'Logitech G HUB' = 'Logitech G HUB'; 'SteelSeries' = 'SteelSeries GG'
    'Bambu' = 'Bambu Studio'; 'Google Play Games' = 'Google Play Games'; 'NVIDIA App' = 'NVIDIA App'; 'Docker Desktop' = 'Docker Desktop (Docker Hub)'
    'Nanoleaf' = 'Nanoleaf'; 'SignalRgb' = 'SignalRGB'; 'Fing' = 'Fing'; 'Ollama' = 'Ollama'; 'Jellyfin' = 'Jellyfin'
  }
  $names = @($Inv.Programs | ForEach-Object { $_.Name }) + @($Inv.StoreApps | ForEach-Object { $_.Name })
  @(foreach ($k in $known.Keys) { if ($names | Where-Object { $_ -like "*$k*" }) { $known[$k] } })
}

function New-KitTable([string[]]$Headers, $Rows) {
  # A single row arrives unrolled into its cells; re-wrap it.
  $list = @()
  if ($null -ne $Rows) { $list = @($Rows) }
  if ($list.Count -gt 0 -and -not ($list[0] -is [System.Array])) { $list = @(, $list) }
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('<div class="tbl"><table><thead><tr>')
  foreach ($h in $Headers) { [void]$sb.Append('<th>' + (HtmlEnc $h) + '</th>') }
  [void]$sb.Append('</tr></thead><tbody>')
  if ($list.Count -eq 0) { [void]$sb.Append('<tr><td colspan="' + $Headers.Count + '" class="sub">none</td></tr>') }
  foreach ($r in $list) {
    [void]$sb.Append('<tr>')
    foreach ($cell in $r) { [void]$sb.Append('<td>' + [string]$cell + '</td>') }
    [void]$sb.Append('</tr>')
  }
  [void]$sb.Append('</tbody></table></div>')
  return $sb.ToString()
}

function New-KitReport($Inv, [string]$Path, [string]$Mode, $Backup) {
  $s = $Inv.System
  $plan = $Inv.AppPlan
  $installs = @($plan.Install | Where-Object { -not $_.Skip })
  $customTasks = @($Inv.Tasks | Where-Object { -not $_.IsVendor })
  $appServices = @($Inv.Services | Where-Object { $_.Origin -eq 'app' })
  $sb = New-Object Text.StringBuilder
  $title = 'PC Migration Report - ' + $s.ComputerName
  [void]$sb.Append(@"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(HtmlEnc $title)</title>
<style>
:root{--bg:#f5f6f8;--card:#fff;--text:#1c2230;--muted:#5d6678;--line:#e2e5ea;--accent:#2457d6;--ok:#157a3a;--warn:#a85a00;--bad:#b42318;--chip:#eef1f6}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#171a21;--text:#e7e9ee;--muted:#9aa3b3;--line:#2a2f3a;--accent:#7aa7ff;--ok:#5bd68a;--warn:#f4b740;--bad:#ff7a70;--chip:#222734}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.55 "Segoe UI",system-ui,sans-serif}
main{max-width:1120px;margin:0 auto;padding:28px 16px 72px}h1{font-size:25px;margin:0 0 4px}h2{font-size:18px;margin:34px 0 10px}h3{font-size:15px;margin:18px 0 6px}
.sub{color:var(--muted)}.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:12px 0}
.callout{border-left:4px solid var(--accent)}.callout.warn{border-left-color:var(--warn)}.callout.bad{border-left-color:var(--bad)}.callout.ok{border-left-color:var(--ok)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px}.stat .n{display:block;font-size:24px;font-weight:600}.stat .l{color:var(--muted);font-size:13px}
.tbl{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600;white-space:nowrap}
.chip{display:inline-block;padding:1px 8px;border-radius:999px;background:var(--chip);font-size:12px;white-space:nowrap}.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}
code{font-family:Consolas,monospace;font-size:12px;word-break:break-all}details{margin:8px 0}summary{cursor:pointer;font-weight:600}ul{margin:6px 0;padding-left:22px}li{margin:3px 0}
</style></head><body><main>
<h1>$(HtmlEnc $title)</h1>
<div class="sub">$(HtmlEnc ('{0} {1} (build {2}) - {3} {4} - {5} GB RAM - user {6} - {7} on {8:yyyy-MM-dd HH:mm}' -f $s.OS, $s.DisplayVersion, $s.Build, $s.Manufacturer, $s.Model, $s.RamGB, $s.UserName, $(if ($Mode -eq 'Backup') { 'backed up' } else { 'scanned' }), (Get-Date)))</div>
"@)

  # ---- callouts
  if ($Inv.Boot.Split) {
    [void]$sb.Append('<div class="card callout warn"><b>Heads-up about how this PC boots.</b> Windows is on <b>' + (HtmlEnc $Inv.Boot.WindowsDisk) + '</b>, but the boot files (EFI partition) are on <b>' + (HtmlEnc $Inv.Boot.EspDisks) + '</b>. ' +
      'A plain disk-to-disk clone of the Windows drive alone will <b>not</b> boot on its own. Use a <i>system</i> backup/clone that picks up both partitions, and when reinstalling Windows, unplug the other drives so setup puts the boot files on the new SSD.</div>')
  }
  $worn = @($Inv.Disks | Where-Object { $_.Wear -ne $null -and $_.Wear -ge 50 })
  foreach ($d in $worn) { [void]$sb.Append('<div class="card callout bad"><b>' + (HtmlEnc $d.Model) + '</b> reports <b>' + $d.Wear + '% wear</b>. Back it up soon.</div>') }
  if (-not $s.IsAdmin) { [void]$sb.Append('<div class="card callout">This scan ran without administrator rights, so SSD wear/temperature and Windows features are not shown. The BACKUP always runs as administrator.</div>') }

  # ---- at a glance
  $dataLine = ''
  if ($Inv.PSObject.Properties.Name -contains 'EstimatedBytes' -and $Inv.EstimatedBytes) { $dataLine = '<div class="card stat"><span class="n">' + (Format-Bytes $Inv.EstimatedBytes) + '</span><span class="l">of files to back up from ' + $s.SystemDrive + '</span></div>' }
  [void]$sb.Append('<h2>At a glance</h2><div class="grid">')
  [void]$sb.Append('<div class="card stat"><span class="n">' + $installs.Count + '</span><span class="l">apps reinstall automatically (winget)</span></div>')
  [void]$sb.Append('<div class="card stat"><span class="n">' + @($plan.Manual).Count + '</span><span class="l">apps to reinstall by hand</span></div>')
  [void]$sb.Append('<div class="card stat"><span class="n">' + $customTasks.Count + ' / ' + @($Inv.Startup).Count + '</span><span class="l">your scheduled tasks / startup items</span></div>')
  [void]$sb.Append('<div class="card stat"><span class="n">' + $appServices.Count + '</span><span class="l">third-party services</span></div>')
  [void]$sb.Append($dataLine + '</div>')

  # ---- disks
  [void]$sb.Append('<h2>Disks</h2>')
  $rows = foreach ($d in $Inv.Disks) {
    $roles = @()
    if ($d.HasWindows) { $roles += '<span class="chip">Windows</span>' }
    if ($d.HasEsp) { $roles += '<span class="chip">boot files</span>' }
    $wear = '-'; if ($d.Wear -ne $null) { $cls = 'ok'; if ($d.Wear -ge 50) { $cls = 'warn' }; if ($d.Wear -ge 80) { $cls = 'bad' }; $wear = '<span class="' + $cls + '">' + $d.Wear + '%</span>' }
    ,@($d.Number, (HtmlEnc $d.Model), (HtmlEnc ($d.Bus + ' ' + $d.Media)), ('{0:N0} GB' -f $d.SizeGB), (HtmlEnc $d.Letters), ($roles -join ' '), (HtmlEnc $d.Health), $wear,
       $(if ($d.TempC) { "$($d.TempC) C" } else { '-' }), $(if ($d.PowerOnHours) { '{0:N0}' -f $d.PowerOnHours } else { '-' }))
  }
  [void]$sb.Append((New-KitTable @('#', 'Model', 'Type', 'Size', 'Letters', 'Role', 'Health', 'Wear', 'Temp', 'Power-on h') $rows))

  # ---- apps
  [void]$sb.Append('<h2>Programs</h2>')
  [void]$sb.Append('<h3>Reinstalled automatically by RESTORE (' + $installs.Count + ')</h3><div class="card">' +
    (($installs | ForEach-Object { '<span class="chip">' + (HtmlEnc $_.Id) + '</span>' }) -join ' ') + '</div>')
  $skipped = @($plan.Install | Where-Object { $_.Skip })
  if ($skipped.Count) {
    [void]$sb.Append('<details><summary>Known to winget but deliberately not reinstalled (' + $skipped.Count + ')</summary>' +
      (New-KitTable @('winget id', 'Why') ($skipped | ForEach-Object { ,@((HtmlEnc $_.Id), (HtmlEnc $_.Skip)) })) + '</details>')
  }
  [void]$sb.Append('<h3>Reinstall by hand (' + @($plan.Manual).Count + ')</h3>')
  [void]$sb.Append((New-KitTable @('Program', 'Version', 'Publisher') ($plan.Manual | ForEach-Object { ,@((HtmlEnc $_.Name), (HtmlEnc $_.Version), (HtmlEnc $_.Publisher)) })))
  if (@($plan.OtherDrive).Count) {
    [void]$sb.Append('<h3>Installed on another drive - nothing to do (' + @($plan.OtherDrive).Count + ')</h3><div class="sub">These live on a drive you are keeping. Steam/Epic find them again once the library folders are back.</div>')
    [void]$sb.Append((New-KitTable @('Program', 'Location') ($plan.OtherDrive | ForEach-Object { ,@((HtmlEnc $_.Name), ('<code>' + (HtmlEnc $_.Home) + '</code>')) })))
  }
  [void]$sb.Append('<details><summary>Come back with Windows, drivers or their parent app (' + @($plan.System).Count + ')</summary>' +
    (New-KitTable @('Component', 'Version') ($plan.System | ForEach-Object { ,@((HtmlEnc $_.Name), (HtmlEnc $_.Version)) })) + '</details>')
  if (@($plan.Store).Count) {
    [void]$sb.Append('<h3>Microsoft Store / packaged apps (' + @($plan.Store).Count + ')</h3><div class="sub">Reinstall from Microsoft Store &rarr; Library if they are not back after RESTORE.</div>')
    [void]$sb.Append((New-KitTable @('App', 'Package family') ($plan.Store | ForEach-Object { ,@((HtmlEnc $_.Name), ('<code>' + (HtmlEnc $_.FamilyName) + '</code>')) })))
  }
  if (@($Inv.Choco).Count) {
    [void]$sb.Append('<h3>Chocolatey packages (' + @($Inv.Choco).Count + ')</h3>' + (New-KitTable @('Package', 'Version') ($Inv.Choco | ForEach-Object { ,@((HtmlEnc $_.Id), (HtmlEnc $_.Version)) })))
  }

  # ---- automations
  [void]$sb.Append('<h2>Automations</h2><h3>Scheduled tasks (' + @($Inv.Tasks).Count + ')</h3>')
  [void]$sb.Append((New-KitTable @('Task', 'State', 'Runs', 'Restore') ($Inv.Tasks | ForEach-Object {
    $how = '<span class="chip">recreated by RESTORE</span>'
    if ($_.IsVendor) { $how = '<span class="chip">recreated by its app</span>' }
    ,@((HtmlEnc ($_.Path + $_.Name)), (HtmlEnc $_.State), ('<code>' + (HtmlEnc $_.Command) + '</code>'), $how)
  })))
  [void]$sb.Append('<h3>Startup items (' + @($Inv.Startup).Count + ')</h3>')
  [void]$sb.Append((New-KitTable @('Name', 'Where', 'Enabled', 'Command') ($Inv.Startup | ForEach-Object {
    ,@((HtmlEnc $_.Name), (HtmlEnc ($_.Type + ' ' + $_.Hive)), $(if ($_.Enabled) { 'yes' } else { '<span class="warn">no</span>' }), ('<code>' + (HtmlEnc $_.Command) + '</code>'))
  })))
  [void]$sb.Append('<h3>Services (' + @($Inv.Services).Count + ')</h3>')
  [void]$sb.Append((New-KitTable @('Service', 'Start', 'State', 'Command', 'Comes back via') ($Inv.Services | ForEach-Object {
    $via = switch ($_.Origin) { 'driver' { 'driver install' } 'store' { 'Store app' } default { 'app reinstall, or recreated by RESTORE' } }
    ,@((HtmlEnc ($_.DisplayName + ' (' + $_.Name + ')')), (HtmlEnc ($_.StartMode + $(if ($_.DelayedAutoStart) { ' (delayed)' } else { '' }))), (HtmlEnc $_.State), ('<code>' + (HtmlEnc $_.PathName) + '</code>'), $via)
  })))

  # ---- drive letters
  if (@($Inv.DriveRefs).Count) {
    $allLetters = (@($Inv.Volumes | Where-Object { -not $_.IsSystemDrive -and $_.DriveType -eq 3 -and $_.BusType -ne 'USB' } | ForEach-Object { $_.Letter + ':' }) -join ' ')
    [void]$sb.Append('<h2>Drive letters your setup depends on</h2><div class="sub">RESTORE gives every drive its old letter back (' + $allLetters + ', matched by partition ID) - this also covers paths stored inside app databases, like Plex/Radarr/Sonarr libraries. These are the uses it could see directly:</div>')
    [void]$sb.Append((New-KitTable @('Letter', 'Volume', 'Used by') ($Inv.DriveRefs | ForEach-Object {
      $l = $_.Letter
      $v = $Inv.Volumes | Where-Object { $_.Letter -eq $l } | Select-Object -First 1
      $vol = '(not connected now)'
      if ($v) { $vol = '{0} - {1} ({2})' -f $v.Label, $v.DiskModel, ('{0:N0} GB' -f $v.SizeGB) }
      ,@("<b>$l`:</b>", (HtmlEnc $vol), ((@($_.Uses) | ForEach-Object { HtmlEnc $_ }) -join '<br>'))
    })))
  }

  # ---- wsl / docker / vs
  if (@($Inv.Wsl).Count -or $Inv.Docker.Installed) {
    [void]$sb.Append('<h2>WSL and Docker</h2>')
    if (@($Inv.Wsl).Count) {
      [void]$sb.Append((New-KitTable @('WSL distro', 'Disk file', 'Size', 'Handling') ($Inv.Wsl | ForEach-Object {
        $h = 'disk file copied with your profile; RESTORE re-registers it'
        if ($_.IsDocker) { $h = 'recreated by Docker Desktop' }
        ,@((HtmlEnc $_.Name), ('<code>' + (HtmlEnc $_.Vhdx) + '</code>'), (Format-Bytes $_.VhdxBytes), $h)
      })))
    }
    if ($Inv.Docker.Reachable) {
      [void]$sb.Append('<div class="card">Containers: ' + ((@($Inv.Docker.Containers) | ForEach-Object { '<span class="chip">' + (HtmlEnc ($_.Name + ' - ' + $_.Status)) + '</span>' }) -join ' ') +
        '<br>Volumes: ' + ((@($Inv.Docker.Volumes) | ForEach-Object { '<span class="chip">' + (HtmlEnc $_) + '</span>' }) -join ' ') +
        $(if (@($Inv.Docker.ComposeDirs).Count) { '<br>Compose projects: ' + ((@($Inv.Docker.ComposeDirs) | ForEach-Object { '<code>' + (HtmlEnc $_) + '</code>' }) -join ', ') } else { '' }) + '</div>')
    }
  }

  # ---- media server + smart home
  if ($Inv.PSObject.Properties.Name -contains 'MediaStates' -and @($Inv.MediaStates).Count) {
    [void]$sb.Append('<h2>Media server + smart home</h2><div class="sub">State of each part when this report was made. RESTORE step 15 - or "4 - MEDIA SERVER" at any time - sets up whatever is not OK and checks it again.</div>')
    [void]$sb.Append((New-KitTable @('Part', 'Status', 'Details') (@($Inv.MediaStates) | ForEach-Object {
      $cls = switch ($_.Status) { 'OK' { 'ok' } 'WARN' { 'warn' } default { 'bad' } }
      ,@((HtmlEnc $_.Name), ('<span class="' + $cls + '">' + (HtmlEnc $_.Status) + '</span>'), (HtmlEnc $_.Detail))
    })))
  }

  # ---- other settings
  [void]$sb.Append('<h2>Other settings captured</h2><div class="card"><ul>')
  $envNames = @($Inv.Environment | Where-Object { $_.Scope -eq 'User' } | ForEach-Object { $_.Name })
  [void]$sb.Append('<li>Environment variables: ' + @($Inv.Environment).Count + ' (your own: ' + (HtmlEnc ($envNames -join ', ')) + ')</li>')
  [void]$sb.Append('<li>Wi-Fi networks: ' + $(if (@($Inv.Wifi).Count) { HtmlEnc (@($Inv.Wifi) -join ', ') } else { 'none found' }) + '</li>')
  [void]$sb.Append('<li>Extra fonts: ' + (@($Inv.Fonts.Machine).Count + @($Inv.Fonts.User).Count) + '</li>')
  [void]$sb.Append('<li>Hosts file entries: ' + @($Inv.Hosts).Count + '</li>')
  [void]$sb.Append('<li>Your folders at the root of ' + $s.SystemDrive + ': ' + (HtmlEnc (($Inv.RootFolders | ForEach-Object { $s.SystemDrive + '\' + $_ }) -join ', ')) + '</li>')
  if ($Inv.Features) { [void]$sb.Append('<li>Windows features switched on: ' + @($Inv.Features).Count + '</li>') }
  if (@($Inv.Printers).Count) { [void]$sb.Append('<li>Printers (re-add by hand): ' + (HtmlEnc ((@($Inv.Printers) | ForEach-Object { $_.Name }) -join ', ')) + '</li>') }
  if (@($Inv.MappedDrives).Count) { [void]$sb.Append('<li>Mapped network drives: ' + (HtmlEnc ((@($Inv.MappedDrives) | ForEach-Object { $_.Letter + ': ' + $_.RemotePath }) -join ', ')) + '</li>') }
  if (@($Inv.OtherUsers).Count) { [void]$sb.Append('<li class="warn">Other user accounts on this PC are NOT included: ' + (HtmlEnc (@($Inv.OtherUsers) -join ', ')) + '</li>') }
  if (@($Inv.HyperV).Count) { [void]$sb.Append('<li class="warn">Hyper-V virtual machines (export them in Hyper-V Manager before switching): ' + (HtmlEnc ((@($Inv.HyperV) | ForEach-Object { $_.Name + ' (' + $_.Path + ')' }) -join ', ')) + '</li>') }
  [void]$sb.Append('</ul></div>')

  # ---- manual checklist
  [void]$sb.Append('<h2 id="manual">What you will still do by hand</h2><div class="card"><ul>')
  $signIn = Get-KitSignInApps $Inv
  if ($signIn.Count) { [void]$sb.Append('<li><b>Sign in again</b> to: ' + (HtmlEnc ($signIn -join ', ')) + '.</li>') }
  [void]$sb.Append('<li><b>Browser passwords:</b> Windows encrypts saved passwords per installation, so a fresh Windows cannot read the old ones. Make sure Chrome sync is on (or export passwords to a file) <i>before</i> you switch.</li>')
  if (@($Inv.Credentials).Count) { [void]$sb.Append('<li><b>Saved Windows credentials</b> (Credential Manager) must be re-entered: ' + (HtmlEnc (@($Inv.Credentials) -join ', ')) + '</li>') }
  if (@($plan.Manual).Count) { [void]$sb.Append('<li><b>Install by hand:</b> ' + (HtmlEnc ((@($plan.Manual) | ForEach-Object { $_.Name }) -join ', ')) + '</li>') }
  $lic = @($Inv.Programs | Where-Object { $_.Name -match '(?i)\bpro\b|sentinel|revo|winrar|realvnc' } | ForEach-Object { $_.Name })
  if ($lic.Count) { [void]$sb.Append('<li><b>Licence keys</b> may be needed for: ' + (HtmlEnc ($lic -join ', ')) + '</li>') }
  if (@($Inv.VsInstances).Count) { [void]$sb.Append('<li><b>Visual Studio Build Tools</b> are reinstalled with your saved workloads. If a workload is missing, open Visual Studio Installer &rarr; More &rarr; Import configuration and pick the <code>.vsconfig</code> file in <code>settings\apps\vs</code>.</li>') }
  if ($Inv.Docker.Installed) { [void]$sb.Append('<li><b>Docker:</b> images, containers and volumes come back with Docker''s data disk. If they do not, run <code>docker compose up -d</code> in your compose folder and restore data from your own backups.</li>') }
  [void]$sb.Append('<li><b>Windows activation:</b> the digital licence is tied to the motherboard, so it re-activates by itself once online.</li>')
  [void]$sb.Append('</ul></div>')

  # ---- backup details
  if ($Backup) {
    [void]$sb.Append('<h2>Backup details</h2><div class="card">Saved to <code>' + (HtmlEnc $Backup.Path) + '</code><br>Snapshot (consistent copy of open files): ' + $(if ($Backup.UsedSnapshot) { '<span class="ok">yes</span>' } else { '<span class="warn">no - files that were open may be missing</span>' }) + '</div>')
    [void]$sb.Append((New-KitTable @('What', 'Files', 'Size', 'Result') (@($Backup.Copies) | ForEach-Object {
      $r = '<span class="ok">ok</span>'
      if ($_.Skipped) { $r = 'not present' } elseif (-not $_.Ok -or $_.Errors -gt 0) { $r = '<span class="warn">' + [Math]::Max(1, $_.Errors) + ' file(s) skipped - see log</span>' }
      ,@((HtmlEnc $_.Label), ('{0:N0}' -f $_.Files), (Format-Bytes $_.Bytes), $r)
    })))
    if (@($Backup.Issues).Count) { [void]$sb.Append('<h3>Warnings</h3><div class="card"><ul>' + ((@($Backup.Issues) | ForEach-Object { '<li>' + (HtmlEnc $_) + '</li>' }) -join '') + '</ul></div>') }
  }

  [void]$sb.Append('<p class="sub">PC Migration Kit ' + $script:KitVersion + '</p></main></body></html>')
  [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
}
