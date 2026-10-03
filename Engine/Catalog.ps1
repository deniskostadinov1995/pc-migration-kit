<#
  PC Migration Kit - CATALOG (for the app)
  ----------------------------------------
  Reads the PC the same way BACKUP does (Inventory.ps1 + the media server
  module) and writes it as one JSON file: programs and how each comes back,
  services, scheduled tasks, startup items, environment variables (secret
  values hidden), Wi-Fi networks, fonts, WSL, Docker, drives, the copy plan
  with its exclusions, and the media server parts. The app shows this as the
  list of things you can keep or leave out; nothing is changed or copied.

  -Out      where to write the JSON (required)
  -Quick    skip looking up apps winget did not recognise by name (faster)

  Written by Claude 2026-10-02.
#>
param(
  [Parameter(Mandatory = $true)][string]$Out,
  [switch]$Quick,
  [switch]$NoPause
)

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
. (Join-Path $PSScriptRoot 'MediaServer.ps1')
Set-ConsoleUtf8
if ($script:Gui) { $NoPause = $true }

# a value that is a path (or a list of them) is shown; anything else may be a token
function Get-KitShownValue([string]$Value) {
  if (-not $Value) { return '' }
  if ($Value -match '^(%[^%]+%|[A-Za-z]:\\|\\\\)') { return $Value }
  if ($Value.Contains(';') -and $Value.Contains('\')) { return $Value }   # a list of folders
  if ($Value -match '^\d{1,6}$' -or $Value -match '^(true|false|on|off|yes|no)$') { return $Value }
  return ('(hidden - {0} characters)' -f $Value.Length)
}

Show-Banner 'SCAN' 'Reading this PC for the app. Nothing is changed.'
$started = Get-Date
$wj = Join-Path $env:TEMP ('pcmk-catalog-winget-{0}.json' -f (Get-Random))
$inv = Get-KitInventory -WingetExportPath $wj -Quick:$Quick
Remove-Item -LiteralPath $wj -Force -ErrorAction SilentlyContinue

Say-Info 'Working out what a backup would copy...'
$plan = @(Get-KitCopyPlan $inv)
Say-Info 'Media server + smart home: checking every part...'
$msFacts = $null; $msStates = @(); $msJobs = @()
try { $msFacts = Get-MsFacts; $msStates = @(Test-MsAll); $msJobs = @(Get-MsCopyJobs $msFacts) } catch { Say-Warn ('Media server check: ' + $_.Exception.Message) }

# the names winget uses for the packages it knows (the app shows names, not ids)
Say-Info 'Program names...'
$wingetNames = @{}
if (Get-Command winget -ErrorAction SilentlyContinue) {
  try {
    foreach ($row in @(ConvertFrom-WingetTable @(& winget list --accept-source-agreements --disable-interactivity 2>$null))) {
      if ($row.Id -and $row.Name -and -not $wingetNames.ContainsKey($row.Id)) { $wingetNames[$row.Id] = ([string]$row.Name).TrimEnd([char]0x2026).Trim() }
    }
  } catch {}
}

$skipReg = @('Microsoft', 'Classes', 'Policies', 'Wow6432Node', 'RegisteredApplications', 'Clients', 'AppDataLow', 'IM Providers', 'ODBC', 'Python')
$regApps = @(Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | Where-Object { $skipReg -notcontains $_.PSChildName } | ForEach-Object { $_.PSChildName })

$catalog = [ordered]@{
  KitVersion   = $script:KitVersion
  CreatedAt    = (Get-Date).ToString('s')
  Seconds      = [int]((Get-Date) - $started).TotalSeconds
  IsAdmin      = (Test-IsAdmin)
  System       = $inv.System
  Disks        = @($inv.Disks)
  Volumes      = @($inv.Volumes)
  Boot         = $inv.Boot
  Programs     = @($inv.Programs)
  StoreApps    = @($inv.StoreApps)
  AppPlan      = $inv.AppPlan
  WingetNames  = $wingetNames
  WingetError  = $inv.Winget.Error
  Choco        = @($inv.Choco)
  Python       = @($inv.Python)
  VsInstances  = @($inv.VsInstances | ForEach-Object { [pscustomobject]@{ Product = $_.Product; Version = $_.Version; Path = $_.Path; Components = @($_.Components).Count } })
  Services     = @($inv.Services)
  Tasks        = @($inv.Tasks)
  Startup      = @($inv.Startup)
  Environment  = @($inv.Environment | ForEach-Object { [pscustomobject]@{ Scope = $_.Scope; Name = $_.Name; Kind = $_.Kind; Value = (Get-KitShownValue $_.Value) } })
  Wsl          = @($inv.Wsl)
  Docker       = $inv.Docker
  HyperV       = @($inv.HyperV)
  Fonts        = $inv.Fonts
  Printers     = @($inv.Printers)
  Wifi         = @($inv.Wifi)
  MappedDrives = @($inv.MappedDrives)
  Credentials  = @($inv.Credentials)
  Hosts        = @($inv.Hosts)
  Features     = @($inv.Features)
  RootFolders  = @($inv.RootFolders)
  OtherUsers   = @($inv.OtherUsers)
  DriveRefs    = @($inv.DriveRefs)
  RegistryApps = $regApps
  Plan         = @($plan | ForEach-Object { [pscustomobject]@{ Label = $_.Label; Rel = $_.Rel; Dest = $_.Dest; ExcludeRel = @($_.ExcludeRel); ExcludeNames = @($_.ExcludeNames); ExcludeFiles = @($_.ExcludeFiles); Phase = $_.Phase } })
  Rules        = [ordered]@{
    SystemRootFolders = $script:SystemRootFolders; ProgramDataAllow = $script:ProgramDataAllow; ProgramDataSkip = $script:ProgramDataSkip
    ProgramFilesSkip = $script:ProgramFilesSkip; ProgramFilesRules = $script:ProgramFilesRules; ProfileBigDirs = $script:ProfileBigDirs
    ProfileSkipRel = $script:ProfileSkipRel; ProfileSkipNames = $script:ProfileSkipNames; ProfileSkipFiles = $script:ProfileSkipFiles
  }
  Media        = [ordered]@{
    States = @($msStates | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Name = $_.Name; Status = $_.Status; Detail = $_.Detail } })
    Jobs   = @($msJobs | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Label = $_.Label; Path = $_.Path; Files = $_.Files } })
    HasDocker = [bool]($msFacts -and $msFacts.Docker)
    HasHomeAssistant = [bool]($msFacts -and $msFacts.HomeAssistant)
  }
}
Save-Json $catalog $Out 8
Say-Ok ('Scan finished in {0} s: {1} programs, {2} services, {3} scheduled tasks, {4} startup items.' -f [int]((Get-Date) - $started).TotalSeconds, @($inv.Programs).Count, @($inv.Services).Count, @($inv.Tasks).Count, @($inv.Startup).Count)
Send-KitEvent @{ t = 'catalog'; path = $Out }
Exit-Kit 0 -NoPause:$NoPause
