<#
  PC Migration Kit - media server + smart home
  --------------------------------------------
  Knows how this PC's media server and smart home fit together, and can check,
  back up and rebuild each part:

    qBittorrent, DuckDNS                        apps
    Radarr, Radarr 4K, Sonarr, Jackett          Windows services, data in ProgramData
    Prowlarr (G:), Jellyfin (G:), Caddy (D:)    portable, started at sign-in
    Seerr, Jellystat                            Docker compose project in D:\Docker
    Home Assistant                              VirtualBox VM, disks on G:

  Check  - is each part installed, running and answering on its port? (Caddy:
           does every site hand out a valid certificate?)
  Repair - for every part that is NOT fine: install it (winget), put its data back
           from the backup, register it the way it ran before (service, startup
           entry, container, VM), start it and check again. Parts that already
           work are never touched. Firewall ports are opened for all of them
           when Windows Firewall (not a third-party one) is in charge.

  Needs Common.ps1. Entry scripts set $script:B (backup folder, optional),
  $script:OldProfile / $script:NewProfile and $DryRun.

  Written by Claude 2026-09-29.
#>

$script:MsDefaultPorts = @{ qbittorrent = 8080; radarr = 7878; radarr4k = 7879; sonarr = 8989; jackett = 9117; prowlarr = 9696
                            jellyfin = 8096; caddy = 8444; seerr = 5055; jellystat = 8888; homeassistant = 8123 }
$script:MsFacts = $null   # what BACKUP recorded (settings\mediaserver\mediaserver.json)

function Get-MsDefinitions {
  $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}; $pd = $env:ProgramData
  @(
    @{ Key = 'qbittorrent'; Name = 'qBittorrent (download client)'; Kind = 'App'; Winget = 'qBittorrent.qBittorrent'
       Exe = "$pf\qBittorrent\qbittorrent.exe"; Process = 'qbittorrent'; StartFile = "$pf\qBittorrent\qbittorrent.exe"
       Launcher = @{ Type = 'Run'; Name = 'qBittorrent' }; Health = '/'; Firewall = @('TCP:{port}', 'TCP:{listen}', 'UDP:{listen}')
       ProfileData = @('AppData\Roaming\qBittorrent', 'AppData\Local\qBittorrent') }
    @{ Key = 'radarr'; Name = 'Radarr'; Kind = 'Service'; Winget = 'TeamRadarr.Radarr'; Service = 'Radarr'
       DataDir = "$pd\Radarr"; Marker = "$pd\Radarr\radarr.db"; Exe = "$pd\Radarr\bin\Radarr.Console.exe"
       DefaultBin = "`"$pd\Radarr\bin\Radarr.Console.exe`" -nobrowser -nosingleinstancecheck -data=$pd\Radarr"; Health = '/ping'; Firewall = @('TCP:{port}') }
    @{ Key = 'radarr4k'; Name = 'Radarr 4K'; Kind = 'Service'; Winget = 'TeamRadarr.Radarr'; Service = 'Radarr4K'
       DataDir = "$pd\Radarr4K"; Marker = "$pd\Radarr4K\radarr.db"; Exe = "$pd\Radarr\bin\Radarr.Console.exe"
       DefaultBin = "`"$pd\Radarr\bin\Radarr.Console.exe`" -nobrowser -nosingleinstancecheck -data=$pd\Radarr4K"; Health = '/ping'; Firewall = @('TCP:{port}') }
    @{ Key = 'sonarr'; Name = 'Sonarr'; Kind = 'Service'; Winget = 'TeamSonarr.Sonarr'; Service = 'Sonarr'
       DataDir = "$pd\Sonarr"; Marker = "$pd\Sonarr\sonarr.db"; Exe = "$pd\Sonarr\bin\Sonarr.Console.exe"
       DefaultBin = "`"$pd\Sonarr\bin\Sonarr.Console.exe`""; Health = '/ping'; Firewall = @('TCP:{port}') }
    @{ Key = 'jackett'; Name = 'Jackett'; Kind = 'Service'; Winget = 'Jackett.Jackett'; Service = 'Jackett'
       DataDir = "$pd\Jackett"; Marker = "$pd\Jackett\ServerConfig.json"; Exe = "$pd\Jackett\JackettService.exe"
       DefaultBin = "`"$pd\Jackett\JackettService.exe`""; Health = '/UI/Login'; Firewall = @('TCP:{port}') }
    @{ Key = 'prowlarr'; Name = 'Prowlarr'; Kind = 'Portable'; Root = 'G:\Prowlarr'; Exe = 'G:\Prowlarr\Prowlarr\Prowlarr.exe'
       Marker = 'G:\Prowlarr\data\prowlarr.db'; Process = 'Prowlarr'; StartFile = 'G:\Prowlarr\start-prowlarr.vbs'
       Launcher = @{ Type = 'Run'; Name = 'Prowlarr' }; Health = '/ping'; Firewall = @('TCP:{port}')
       ExcludeRel = @('data\logs'); ExcludeNames = @(); ExcludeFiles = @() }
    @{ Key = 'jellyfin'; Name = 'Jellyfin'; Kind = 'Portable'; Root = 'G:\Jellyfin'; Exe = 'G:\Jellyfin\Server\jellyfin.exe'
       Marker = 'G:\Jellyfin\data\jellyfin.db'; Process = 'jellyfin'; StartFile = 'G:\Jellyfin\start-jellyfin.vbs'
       Launcher = @{ Type = 'Run'; Name = 'JellyfinTray' }; Health = '/health'; Firewall = @('TCP:{port}', 'UDP:7359')
       ExcludeRel = @('cache', 'log', 'temp', 'Transcode'); ExcludeNames = @('*-backup-*'); ExcludeFiles = @()
       Registry = @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\Jellyfin\Server'
                     Values = [ordered]@{ InstallFolder = 'G:\Jellyfin\Server'; DataFolder = 'G:\Jellyfin'; ServiceAccountType = 'None' } } }
    @{ Key = 'caddy'; Name = 'Caddy (HTTPS for Jellyfin + Seerr)'; Kind = 'Portable'; Root = 'D:\Caddy'; Exe = 'D:\Caddy\caddy.exe'
       Marker = 'D:\Caddy\Caddyfile'; Process = 'caddy'; StartFile = '<Startup>\caddy-jellyfin.vbs'
       Launcher = @{ Type = 'Folder'; Name = 'caddy-jellyfin.vbs'; Scope = 'User' }; Health = 'tls'; RestartIfDown = $true; Firewall = @('TCP:{port}')
       ExcludeRel = @(); ExcludeNames = @(); ExcludeFiles = @('*.log', '*.log.gz'); EnvVars = @('DUCKDNS_API_TOKEN') }
    # DuckDns.exe only starts Java: the updater runs as javaw.exe -jar ...\DuckDns.exe
    @{ Key = 'duckdns'; Name = 'DuckDNS updater'; Kind = 'App'; Winget = 'ETXSoftwareInc.DuckDns'; Exe = "$pf86\DuckDNS\DuckDns.exe"
       Process = 'DuckDns'; RunsAs = 'javaw.exe'; StartFile = "$pf86\DuckDNS\DuckDns.exe"; Launcher = @{ Type = 'Folder'; Name = 'DuckDns.lnk'; Scope = 'Common' } }
    @{ Key = 'docker'; Name = 'Docker Desktop'; Kind = 'Docker'; Winget = 'Docker.DockerDesktop'; Exe = "$pf\Docker\Docker\Docker Desktop.exe" }
    @{ Key = 'seerr'; Name = 'Seerr'; Kind = 'Container'; Containers = @('seerr'); Health = '/api/v1/status'; Firewall = @('TCP:{port}') }
    @{ Key = 'jellystat'; Name = 'Jellystat'; Kind = 'Container'; Containers = @('jellystat-db', 'jellystat'); Health = '/'; Firewall = @('TCP:{port}') }
    @{ Key = 'homeassistant'; Name = 'Home Assistant (VirtualBox VM)'; Kind = 'VM'; Winget = 'Oracle.VirtualBox'; VmName = 'HomeAssistant'
       Launcher = @{ Type = 'Folder'; Name = 'HomeAssistant.lnk'; Scope = 'User' } }
  )
}

# ------------------------------------------------------------------ helpers ---
function Get-MsBackupPath([string]$Rel) {
  if (-not $script:B -or -not $Rel) { return $null }
  $p = Join-Path $script:B $Rel
  if (Test-Path -LiteralPath $p) { return $p }
  return $null
}

# Where BACKUP keeps a copy of a path: G:\Jellyfin -> files\G\Jellyfin. Profile
# paths use the old user folder, the same way the rest of the kit stores them.
function Get-MsFilesRel([string]$Path) {
  if (-not $Path) { return $null }
  if ($script:NewProfile -and $script:OldProfile -and $Path.StartsWith($script:NewProfile, [StringComparison]::OrdinalIgnoreCase)) {
    $Path = $script:OldProfile + $Path.Substring($script:NewProfile.Length)
  }
  if ($Path -match '^([A-Za-z]):\\(.*)$') { return ('files\{0}\{1}' -f $Matches[1].ToUpper(), $Matches[2]) }
  return $null
}

function Resolve-MsPath([string]$Path) {
  if (-not $Path) { return $Path }
  $p = $Path.Replace('<Startup>', [Environment]::GetFolderPath('Startup')).Replace('<CommonStartup>', [Environment]::GetFolderPath('CommonStartup'))
  return (Convert-KitPath $p)
}

function Get-MsFact([string]$Key) {
  if (-not $script:MsFacts) { return $null }
  return (@($script:MsFacts.Components) | Where-Object { $_ -and $_.Key -eq $Key } | Select-Object -First 1)
}

function Get-MsXmlValue([string]$File, [string]$Tag) {
  if (-not (Test-Path -LiteralPath $File)) { return $null }
  $m = [regex]::Match([IO.File]::ReadAllText($File), "<$Tag>(.*?)</$Tag>")
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-MsIniValue([string]$File, [string]$Name) {
  if (-not (Test-Path -LiteralPath $File)) { return $null }
  foreach ($ln in [IO.File]::ReadAllLines($File)) { if ($ln -match ('^' + [regex]::Escape($Name) + '=(.*)$')) { return $Matches[1].Trim() } }
  return $null
}

function Get-MsEnvFileValue([string]$File, [string]$Name) {
  if (-not (Test-Path -LiteralPath $File)) { return $null }
  foreach ($ln in [IO.File]::ReadAllLines($File)) { if ($ln -match ('^\s*' + [regex]::Escape($Name) + '\s*=\s*(.*)$')) { return $Matches[1].Trim().Trim('"') } }
  return $null
}

function Get-MsLivePort($C) {
  switch ($C.Key) {
    { $_ -in 'radarr', 'radarr4k', 'sonarr' } { return (Get-MsXmlValue (Join-Path $C.DataDir 'config.xml') 'Port') }
    'prowlarr' { return (Get-MsXmlValue (Join-Path $C.Root 'data\config.xml') 'Port') }
    'jackett' { try { return (Get-Content -LiteralPath (Join-Path $C.DataDir 'ServerConfig.json') -Raw | ConvertFrom-Json).Port } catch { return $null } }
    'jellyfin' { return (Get-MsXmlValue (Join-Path $C.Root 'config\network.xml') 'InternalHttpPort') }
    'qbittorrent' { return (Get-MsIniValue (Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini') 'WebUI\Port') }
    'caddy' {
      $f = Join-Path $C.Root 'Caddyfile'
      if (Test-Path -LiteralPath $f) { $m = [regex]::Match([IO.File]::ReadAllText($f), '(?m)^\s*https?://[^\s{#]+:(\d+)'); if ($m.Success) { return $m.Groups[1].Value } }
      return $null
    }
    { $_ -in 'seerr', 'jellystat' } {
      $f = Join-Path (Get-MsDockerFacts).ProjectDir 'compose.yml'
      $inner = if ($C.Key -eq 'seerr') { '5055' } else { '3000' }
      if (Test-Path -LiteralPath $f) { $m = [regex]::Match([IO.File]::ReadAllText($f), '(\d+):' + $inner + '\b'); if ($m.Success) { return $m.Groups[1].Value } }
      return $null
    }
  }
  return $null
}

function Get-MsPort($C) {
  $live = Get-MsLivePort $C
  if ($live) { return [int]$live }
  $f = Get-MsFact $C.Key
  if ($f -and $f.Port) { return [int]$f.Port }
  return $script:MsDefaultPorts[$C.Key]
}

function Get-MsHttpCode([string]$Url, [int]$TimeoutSec = 5) {
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect = $false
    $req.Timeout = $TimeoutSec * 1000
    $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close(); return $code
  } catch [Net.WebException] {
    $r = $_.Exception.Response
    if ($r) { $code = [int]$r.StatusCode; $r.Close(); return $code }
    return 0
  } catch { return 0 }
}

# 2xx, 3xx (login redirects) and 4xx (asks for a password) all mean "it answers".
function Test-MsHttpUp([string]$Url) { $c = Get-MsHttpCode $Url; return ($c -ge 200 -and $c -lt 500) }
function Test-MsTcpListen([int]$Port) { return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) }

# Running = its process exists. A program that hands over to another one and quits
# (DuckDns.exe -> javaw.exe) is found by its file name in that one's command line.
function Test-MsRunning($C) {
  if ($C.Process -and (Get-Process -Name $C.Process -ErrorAction SilentlyContinue)) { return $true }
  if (-not $C.RunsAs) { return $false }
  $leaf = Split-Path $C.Exe -Leaf
  return [bool](@(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $C.RunsAs) -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($leaf, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count)
}

# Radarr and Radarr 4K run the same Radarr.Console.exe, and the *arr apps quit when
# another copy of themselves already runs ("Another instance is already running").
# At boot the service that starts second stays down - Radarr did after the
# 2026-09-29 restore - unless both carry -nosingleinstancecheck.
function Test-MsSharedExe($C) {
  return [bool](@(Get-MsDefinitions | Where-Object { $_.Kind -eq 'Service' -and $_.Key -ne $C.Key -and $_.Exe -eq $C.Exe }).Count)
}

# The command line a service should have: the old PC's (or the built-in one), plus
# -nosingleinstancecheck when it shares its program with another service.
function Get-MsServiceBin($C) {
  $bin = $C.DefaultBin
  $f = Get-MsFact $C.Key
  if ($f -and $f.BinPath) { $bin = Convert-KitPath ([string]$f.BinPath) }
  if ((Test-MsSharedExe $C) -and $bin -notmatch '(?i)[-/]nosingleinstancecheck\b') { $bin = $bin.TrimEnd() + ' -nosingleinstancecheck' }
  return $bin
}

# Same program and the same switches, in any order.
function Test-MsSameCommand([string]$A, [string]$B) {
  return ((@((Get-CommandKey $A) -split ' ' | Sort-Object) -join ' ') -eq (@((Get-CommandKey $B) -split ' ' | Sort-Object) -join ' '))
}

# The sites in the Caddyfile (https://name:port {).
function Get-MsCaddySites($C) {
  $f = Join-Path $C.Root 'Caddyfile'
  if (-not (Test-Path -LiteralPath $f)) { return @() }
  return @([regex]::Matches([IO.File]::ReadAllText($f), '(?m)^\s*https://([^\s{:/#,]+):(\d+)') |
           ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; Port = [int]$_.Groups[2].Value } })
}

# A TLS handshake the way a TV or browser makes one: to this PC, asking for the
# site's name. Returns '' when a trusted certificate comes back, else what failed.
# A Caddy without its certificates - started without the DuckDNS token, or as
# SYSTEM, whose certificate store is empty - keeps the port open but fails here.
function Test-MsTls([string]$Name, [int]$Port) {
  $tcp = New-Object Net.Sockets.TcpClient
  $ssl = $null
  try {
    try { if (-not $tcp.ConnectAsync('127.0.0.1', $Port).Wait(5000)) { return 'no answer' } } catch { return 'port closed' }
    $seen = @{ Errors = $null }
    $check = { param($s, $cert, $chain, $errors) $seen.Errors = $errors; $true }.GetNewClosure()
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, [Net.Security.RemoteCertificateValidationCallback]$check)
    $ssl.ReadTimeout = 10000; $ssl.WriteTimeout = 10000
    try { $ssl.AuthenticateAsClient($Name, $null, [Security.Authentication.SslProtocols]::Tls12, $false) }
    catch { return 'no certificate (Caddy has no DuckDNS token, or runs as another account)' }
    if ($seen.Errors -ne [Net.Security.SslPolicyErrors]::None) { return ('certificate not trusted ({0})' -f $seen.Errors) }
    return ''
  } finally { if ($ssl) { $ssl.Dispose() }; $tcp.Close() }
}

function Wait-MsUp([scriptblock]$Test, [int]$Seconds) {
  if ($DryRun) { return [bool](& $Test) }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) { if (& $Test) { return $true }; Start-Sleep -Seconds 3 }
  return [bool](& $Test)
}

function Install-MsPackage([string]$Id) {
  if (-not $Id) { return $false }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Say-Fail "winget is not available, so $Id cannot be installed automatically."; return $false }
  if ($DryRun) { Say ('  [dry-run] winget install {0}' -f $Id) 'DarkGray'; return $true }
  Say ('  -> installing {0} ...' -f $Id) 'White'
  & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
  $code = $LASTEXITCODE
  if (@(0, -1978335189, -1978334967, -1978334966, 3010, 1641) -contains $code) { Say-Ok "$Id installed"; return $true }
  Say-Fail ('{0} did not install (winget code {1})' -f $Id, $code); return $false
}

function Restore-MsTree([string]$Src, [string]$Dst, [string]$Label) {
  if ($DryRun) { Say ('  [dry-run] copy {0}  ->  {1}' -f $Src, $Dst) 'DarkGray'; return $true }
  $root = [IO.Path]::GetPathRoot($Dst)
  if (-not (Test-Path -LiteralPath $root)) { Say-Fail ('Drive {0} does not exist. Connect that disk (or give a new one the letter {0}), then run repair again.' -f $root); return $false }
  $collect = if (Get-KitRename) { $script:PathFixFiles } else { $null }
  $r = Invoke-KitCopy -Source $Src -Destination $Dst -Label $Label -Collect $collect
  Write-CopyResult $r
  Update-KitCopiedFiles $r
  return $r.Ok
}

function Test-MsWindowsFirewallInCharge {
  return (@(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue).Count -eq 0)
}

function Ensure-MsFirewall($C) {
  if (-not $C.Firewall) { return }
  if ($C.Key -eq 'jackett') {
    $f = Get-MsFact 'jackett'
    $ext = $null
    try { $ext = (Get-Content -LiteralPath (Join-Path $C.DataDir 'ServerConfig.json') -Raw | ConvertFrom-Json).AllowExternal } catch {}
    if ($null -eq $ext -and $f) { $ext = $f.AllowExternal }
    if ($ext -eq $false) { return }   # Jackett only listens to this PC
  }
  $port = Get-MsPort $C
  $listen = $null
  if ($C.Key -eq 'qbittorrent') {
    $listen = Get-MsIniValue (Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini') 'Session\Port'
    if (-not $listen) { $f = Get-MsFact 'qbittorrent'; if ($f) { $listen = $f.ListenPort } }
  }
  foreach ($spec in $C.Firewall) {
    $proto, $p = $spec -split ':'
    if ($p -eq '{listen}' -and -not $listen) { continue }
    $p = $p.Replace('{port}', [string]$port).Replace('{listen}', [string]$listen)
    $name = 'PC Migration Kit - {0} ({1} {2})' -f $C.Name, $proto, $p
    if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) { continue }
    [void](Invoke-Change ('Firewall: let other devices reach {0} ({1} {2})' -f $C.Name, $proto, $p) {
      New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol $proto -LocalPort $p -Profile Private, Domain | Out-Null
    })
  }
}

# The saved startup entry (Run value or Startup-folder file) for a component.
function Ensure-MsLauncher($C) {
  $l = $C.Launcher
  if (-not $l) { return }
  $items = @()
  $sj = Read-Json (Get-MsBackupPath 'settings\startup\startup.json')
  if ($sj -and $sj.Items) { $items = @($sj.Items) }
  $saved = $items | Where-Object { $_ -and $_.Name -eq $l.Name } | Select-Object -First 1
  if ($l.Type -eq 'Run') {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($saved -and $saved.Hive -eq 'HKLM') { $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' }
    $k = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
    if ($k -and ($k.GetValueNames() -contains $l.Name)) { return }
    $start = Resolve-MsPath $C.StartFile
    $cmd = if ($saved) { Convert-KitPath $saved.Command } elseif ($start -like '*.vbs') { 'wscript.exe "{0}"' -f $start } else { '"{0}"' -f $start }
    [void](Invoke-Change ('Start {0} when you sign in' -f $C.Name) { New-ItemProperty -LiteralPath $key -Name $l.Name -Value $cmd -PropertyType String -Force | Out-Null })
    return
  }
  $scope = $l.Scope
  if ($saved) { $scope = $saved.Hive }
  $dir = if ($scope -eq 'Common') { [Environment]::GetFolderPath('CommonStartup') } else { [Environment]::GetFolderPath('Startup') }
  $dst = Join-Path $dir $l.Name
  if (Test-Path -LiteralPath $dst) { return }
  $src = Get-MsBackupPath ('settings\startup\files\{0}\{1}' -f $scope, $l.Name)
  if ($src) { [void](Invoke-Change ('Start {0} when you sign in' -f $C.Name) { Copy-Item -LiteralPath $src -Destination $dst -Force }); return }
  # nothing saved: build the launcher the way it was set up on the old PC
  if ($C.Key -eq 'caddy') {
    $vbs = "' Starts Caddy hidden at logon (recreated by PC Migration Kit).`r`nCreateObject(`"WScript.Shell`").Run `"`"`"$($C.Exe)`"`" run --config `"`"$(Join-Path $C.Root 'Caddyfile')`"`"`", 0, False`r`n"
    [void](Invoke-Change 'Start Caddy when you sign in' { [IO.File]::WriteAllText($dst, $vbs, [Text.Encoding]::ASCII) })
  } elseif ($C.Key -eq 'homeassistant') {
    $vb = Get-MsVBoxDir
    $vmName = Get-MsVmName
    if ($vb) { [void](Invoke-Change 'Start the Home Assistant VM when you sign in' { New-MsShortcut $dst (Join-Path $vb 'VirtualBoxVM.exe') ('--comment "{0}" --startvm "{0}"' -f $vmName) }) }
  } elseif ($C.Exe) {
    [void](Invoke-Change ('Start {0} when you sign in' -f $C.Name) { New-MsShortcut $dst $C.Exe '' })
  }
}

function New-MsShortcut([string]$Path, [string]$Target, [string]$Arguments) {
  $sh = New-Object -ComObject WScript.Shell
  $l = $sh.CreateShortcut($Path)
  $l.TargetPath = $Target
  $l.Arguments = $Arguments
  $l.WorkingDirectory = Split-Path $Target -Parent
  $l.Save()
}

function Start-MsAsUser([string]$What, [string]$File) {
  if (-not $File) { return }
  [void](Invoke-Change ('Start {0}' -f $What) {
    if (-not (Test-Path -LiteralPath $File)) { throw "$File not found" }
    Open-AsUser $File   # through Explorer, so it runs with your normal rights - not as administrator
  })
}

# ------------------------------------------------------------------ docker ---
function Get-MsDockerExe {
  $c = Get-Command docker.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $p = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
  if (Test-Path -LiteralPath $p) { return $p }
  return $null
}

function Invoke-MsDocker([string]$Arguments) {
  $d = Get-MsDockerExe
  if (-not $d) { return [pscustomobject]@{ ExitCode = -1; Output = 'docker.exe not found' } }
  return (Invoke-Native $d $Arguments)
}

function Invoke-MsDockerOrThrow([string]$Arguments) {
  $r = Invoke-MsDocker $Arguments
  if ($r.ExitCode -ne 0) { throw ('docker {0} failed: {1}' -f ($Arguments -split ' ')[0], $r.Output.Trim()) }
  return $r
}

function Test-MsDockerUp { return ((Invoke-MsDocker 'info').ExitCode -eq 0) }

function Get-MsContainerRunning([string]$Name) {
  $r = Invoke-MsDocker ('inspect -f "{{{{.State.Running}}}}" {0}' -f $Name)
  if ($r.ExitCode -ne 0) { return $null }          # container does not exist
  return ($r.StdOut.Trim() -eq 'true')
}

function Get-MsDockerFacts {
  $d = $null
  if ($script:MsFacts) { $d = $script:MsFacts.Docker }
  if ($d -and $d.ProjectDir) { return $d }
  return [pscustomobject]@{ ProjectDir = 'D:\Docker'; ProjectName = 'docker'; ComposeFile = 'compose.yml'; SeerrUid = '1000'; SeerrGid = '1000'
                            Volumes = @([pscustomobject]@{ Container = 'seerr'; Name = 'seerr-data'; Destination = '/app/config'; External = $true },
                                        [pscustomobject]@{ Container = 'jellystat-db'; Name = 'docker_jellystat-db'; Destination = '/var/lib/postgresql/data'; External = $false },
                                        [pscustomobject]@{ Container = 'jellystat'; Name = 'docker_jellystat-backup'; Destination = '/app/backend/backup-data'; External = $false }) }
}

# -------------------------------------------------------------- virtualbox ---
function Get-MsVBoxDir {
  $dir = (Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction SilentlyContinue).InstallDir
  if (-not $dir) { $dir = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\' }
  if (Test-Path -LiteralPath (Join-Path $dir 'VBoxManage.exe')) { return $dir }
  return $null
}

function Get-MsVBoxManage { $d = Get-MsVBoxDir; if ($d) { return (Join-Path $d 'VBoxManage.exe') }; return $null }

function Get-MsVmName {
  if ($script:MsFacts -and $script:MsFacts.HomeAssistant -and $script:MsFacts.HomeAssistant.Name) { return [string]$script:MsFacts.HomeAssistant.Name }
  return 'HomeAssistant'
}

function Get-MsVmInfo([string]$VBox, [string]$Vm) {
  $r = Invoke-Native $VBox ('showvminfo "{0}" --machinereadable' -f $Vm)
  if ($r.ExitCode -ne 0) { return $null }
  $h = @{}
  foreach ($ln in ($r.Output -split "`r?`n")) {
    $m = [regex]::Match($ln, '^"?([^"=]+)"?="?(.*?)"?$')
    if ($m.Success) { $h[$m.Groups[1].Value] = $m.Groups[2].Value.Replace('\\', '\') }
  }
  return $h
}

function Get-MsHaAddress {
  $ha = $null
  if ($script:MsFacts) { $ha = $script:MsFacts.HomeAssistant }
  $ips = @()
  if ($ha -and $ha.Mac) {
    $mac = ($ha.Mac -replace '[^0-9A-Fa-f]', '').ToUpper() -replace '(..)(?!$)', '$1-'
    $ips += @(Get-NetNeighbor -LinkLayerAddress $mac -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
  }
  if ($ha -and $ha.Ip) { $ips += $ha.Ip }
  $ips += 'homeassistant.local'
  foreach ($ip in ($ips | Select-Object -Unique)) { if (Test-MsHttpUp ('http://{0}:8123/' -f $ip)) { return $ip } }
  return $null
}

function Get-MsWiredAdapter {
  $up = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
  $wired = @($up | Where-Object { $_.MediaType -eq '802.3' -and $_.InterfaceDescription -notmatch '(?i)wireless|wi-fi|wlan' })
  if ($wired.Count) { return $wired[0] }
  if ($up.Count) { return $up[0] }
  return $null
}

# =================================================================== check ===
function New-MsState($C, [string]$Status, [string]$Detail) { [pscustomobject]@{ Key = $C.Key; Name = $C.Name; Status = $Status; Detail = $Detail } }

function Test-MsComponent($C) {
  $port = Get-MsPort $C
  switch ($C.Kind) {
    'App' {
      if (-not (Test-Path -LiteralPath $C.Exe)) { return (New-MsState $C 'MISSING' 'not installed') }
      $running = Test-MsRunning $C
      if ($C.Health) {
        $url = 'http://localhost:{0}{1}' -f $port, $C.Health
        if (Test-MsHttpUp $url) { return (New-MsState $C 'OK' $url) }
        if ($running) { return (New-MsState $C 'DOWN' "running, but $url does not answer") }
        return (New-MsState $C 'DOWN' 'installed, not running')
      }
      if ($running) { return (New-MsState $C 'OK' 'running') }
      return (New-MsState $C 'DOWN' 'installed, not running')
    }
    'Service' {
      $s = Get-Service -Name $C.Service -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $C.Exe)) { return (New-MsState $C 'MISSING' 'program files missing') }
      if (-not (Test-Path -LiteralPath $C.Marker)) { return (New-MsState $C 'MISSING' ('no data in {0}' -f $C.DataDir)) }
      if (-not $s) { return (New-MsState $C 'MISSING' ('service "{0}" does not exist' -f $C.Service)) }
      if ($s.Status -ne 'Running') { return (New-MsState $C 'DOWN' ('service is {0}' -f $s.Status)) }
      $url = 'http://localhost:{0}{1}' -f $port, $C.Health
      if (-not (Test-MsHttpUp $url)) { return (New-MsState $C 'DOWN' "service running, but $url does not answer") }
      if (Test-MsSharedExe $C) {
        $pn = [string](Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $C.Service) -ErrorAction SilentlyContinue).PathName
        if ($pn -notmatch '(?i)[-/]nosingleinstancecheck\b') {
          return (New-MsState $C 'WARN' ('{0} - shares {1} with another service without -nosingleinstancecheck, so one of them can stay down after a restart' -f $url, (Split-Path $C.Exe -Leaf)))
        }
      }
      return (New-MsState $C 'OK' $url)
    }
    'Portable' {
      if (-not (Test-Path -LiteralPath $C.Exe)) { return (New-MsState $C 'MISSING' ('{0} not found' -f $C.Exe)) }
      if (-not (Test-Path -LiteralPath $C.Marker)) { return (New-MsState $C 'MISSING' ('data missing ({0})' -f $C.Marker)) }
      $warn = @()
      if ($C.Registry) {
        $want = $C.Registry['Values']
        foreach ($n in @($want.Keys)) {
          $v = (Get-ItemProperty -LiteralPath $C.Registry['Key'] -Name $n -ErrorAction SilentlyContinue).$n
          if ($v -ne $want[$n]) { $warn += "registry $n is not set (the tray app cannot find the server)" }
        }
      }
      foreach ($e in @($C.EnvVars)) { if ($e -and -not [Environment]::GetEnvironmentVariable($e, 'User')) { $warn += "environment variable $e is missing" } }
      $running = Test-MsRunning $C
      $problem = $null
      if ($C.Health -in 'tcp', 'tls') {
        $where = "port $port"
        if (-not (Test-MsTcpListen $port)) { $problem = "$where does not answer" }
        elseif ($C.Health -eq 'tls') {
          # an open port is not enough: the sites must hand out their certificates
          $sites = @(Get-MsCaddySites $C)
          foreach ($s in $sites) {
            $e = Test-MsTls $s.Name $s.Port
            if ($e) { $problem = 'https://{0}:{1} - {2}' -f $s.Name, $s.Port, $e; break }
          }
          if ($sites.Count) { $where = '{0} site(s) on port {1} with valid certificates' -f $sites.Count, $port }
        }
      } else {
        $where = 'http://localhost:{0}{1}' -f $port, $C.Health
        if (-not (Test-MsHttpUp $where)) { $problem = "$where does not answer" }
      }
      if ($problem) {
        # a missing registry value or variable is often the reason it is down - say so
        $d = if ($running) { "running, but $problem" } else { 'not running' }
        if ($warn.Count) { $d += ' - ' + ($warn -join '; ') }
        return (New-MsState $C 'DOWN' $d)
      }
      if ($warn.Count) { return (New-MsState $C 'WARN' ($where + ' - ' + ($warn -join '; '))) }
      return (New-MsState $C 'OK' $where)
    }
    'Docker' {
      if (-not (Test-Path -LiteralPath $C.Exe)) { return (New-MsState $C 'MISSING' 'not installed') }
      if (Test-MsDockerUp) { return (New-MsState $C 'OK' 'engine running') }
      return (New-MsState $C 'DOWN' 'installed, engine not running')
    }
    'Container' {
      if (-not (Get-MsDockerExe) -or -not (Test-MsDockerUp)) { return (New-MsState $C 'DOWN' 'Docker is not running') }
      foreach ($n in $C.Containers) {
        $run = Get-MsContainerRunning $n
        if ($null -eq $run) { return (New-MsState $C 'MISSING' "container $n does not exist") }
        if (-not $run) { return (New-MsState $C 'DOWN' "container $n is stopped") }
      }
      $url = 'http://localhost:{0}{1}' -f $port, $C.Health
      if (Test-MsHttpUp $url) { return (New-MsState $C 'OK' $url) }
      return (New-MsState $C 'DOWN' "containers running, but $url does not answer")
    }
    'VM' {
      $vbox = Get-MsVBoxManage
      if (-not $vbox) { return (New-MsState $C 'MISSING' 'VirtualBox not installed') }
      $name = Get-MsVmName
      $info = Get-MsVmInfo $vbox $name
      if (-not $info) { return (New-MsState $C 'MISSING' "VM $name is not registered in VirtualBox") }
      if ($info['VMState'] -ne 'running') { return (New-MsState $C 'DOWN' ('VM is {0}' -f $info['VMState'])) }
      $ip = Get-MsHaAddress
      if ($ip) { return (New-MsState $C 'OK' ('http://{0}:8123' -f $ip)) }
      return (New-MsState $C 'WARN' 'VM running, Home Assistant not answering yet (it takes 1-2 minutes after a start)')
    }
  }
}

# The category Windows last handed to the network stack for an adapter - the one its
# firewall actually filters with (NetworkProfile log, event 20002). It can differ from
# what Settings shows: on 2026-09-30 a watchdog wrote "Private" into the registry at
# boot; Settings showed Private all day while the stack, and with it the firewall,
# kept the home network Public - the TVs and Home Assistant could not reach Jellyfin.
function Get-MsStackCategory([string]$InterfaceGuid) {
  foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-NetworkProfile/Operational'; Id = 20002 } -MaxEvents 500 -ErrorAction SilentlyContinue)) {
    $d = @{}
    foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d[[string]$n.Name] = [string]$n.'#text' }
    if ($d['InterfaceGuid'] -ieq $InterfaceGuid) { return @('Public', 'Private', 'DomainAuthenticated')[[int]$d['Category']] }
  }
  return $null
}

function Test-MsNetworkProfile {
  $nic = Get-MsWiredAdapter
  if (-not $nic) { return $null }
  $p = Get-NetConnectionProfile -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue
  if (-not $p) { return $null }
  $st = 'OK'; $stale = $false
  $detail = '{0} is "{1}"' -f $p.Name, $p.NetworkCategory
  if ([string]$p.NetworkCategory -eq 'Public') { $st = 'WARN'; $detail += ' - other devices may be blocked; it should be Private' }
  elseif ((Get-MsStackCategory $nic.InterfaceGuid) -eq 'Public') {
    $st = 'WARN'; $stale = $true
    $detail += ', but the firewall still treats it as Public - other devices (TVs, phones, Home Assistant) are blocked'
  }
  return [pscustomobject]@{ Key = 'network'; Name = 'Home network setting'; Status = $st; Detail = $detail; IfIndex = $nic.ifIndex; Stale = $stale }
}

function Test-MsAll {
  $out = @(foreach ($c in Get-MsDefinitions) { Test-MsComponent $c })
  $net = Test-MsNetworkProfile
  if ($net) { $out += $net }
  return $out
}

function Show-MsTable($States) {
  if ($script:Gui) {
    Send-KitEvent @{ t = 'mstable'; rows = @($States | ForEach-Object { @{ key = $_.Key; name = $_.Name; status = $_.Status; detail = $_.Detail } }) }
    foreach ($s in $States) { Write-KitLog ('{0,-34} {1,-8} {2}' -f $s.Name, $s.Status, $s.Detail) }
    return
  }
  Write-Host ''
  Write-Host ('  {0,-34} {1,-8} {2}' -f 'Part', 'Status', 'Details') -ForegroundColor Gray
  Write-Host ('  {0,-34} {1,-8} {2}' -f ('-' * 30), ('-' * 7), ('-' * 40)) -ForegroundColor DarkGray
  foreach ($s in $States) {
    $color = switch ($s.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('  {0,-34} ' -f $s.Name) -NoNewline
    Write-Host ('{0,-8} ' -f $s.Status) -ForegroundColor $color -NoNewline
    Write-Host $s.Detail -ForegroundColor Gray
    Write-KitLog ('{0,-34} {1,-8} {2}' -f $s.Name, $s.Status, $s.Detail)
  }
  Write-Host ''
}

# ================================================================== repair ===
function Repair-MsApp($C) {
  if (-not (Test-Path -LiteralPath $C.Exe)) { [void](Install-MsPackage $C.Winget) }
  foreach ($rel in @($C.ProfileData)) {
    if (-not $rel) { continue }
    $dst = Join-Path $env:USERPROFILE $rel
    if (Test-Path -LiteralPath $dst) { continue }
    $src = Get-MsBackupPath (Get-MsFilesRel $dst)
    if ($src) { [void](Restore-MsTree $src $dst ('{0} settings ({1})' -f $C.Name, $rel)) }
  }
  Ensure-MsLauncher $C
  if (-not (Test-MsRunning $C)) { Start-MsAsUser $C.Name (Resolve-MsPath $C.StartFile) }
}

function Repair-MsService($C) {
  $f = Get-MsFact $C.Key
  $svc = Get-Service -Name $C.Service -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $C.Marker)) {
    $src = Get-MsBackupPath (Get-MsFilesRel $C.DataDir)
    if ($src) {
      if ($svc -and $svc.Status -eq 'Running') { [void](Invoke-Change ('Stop {0}' -f $C.Service) { Stop-Service -Name $C.Service -Force }) }
      [void](Restore-MsTree $src $C.DataDir ('{0} data' -f $C.Name))
    } else { Say-Warn ('{0}: no data for it in the backup - it will start empty.' -f $C.Name) }
  }
  if (-not (Test-Path -LiteralPath $C.Exe)) { [void](Install-MsPackage $C.Winget) }
  $svc = Get-Service -Name $C.Service -ErrorAction SilentlyContinue
  $bin = Get-MsServiceBin $C
  if (-not $svc) {
    $display = $C.Name; $desc = $null
    if ($f -and $f.DisplayName) { $display = $f.DisplayName }
    if ($f -and $f.Description) { $desc = [string]$f.Description }
    [void](Invoke-Change ('Create the "{0}" service' -f $C.Service) {
      $p = @{ Name = $C.Service; BinaryPathName = $bin; DisplayName = $display; StartupType = 'Automatic' }
      if ($desc) { $p.Description = $desc }
      New-Service @p | Out-Null
    })
  } else {
    if ($svc.StartType -ne 'Automatic') {
      [void](Invoke-Change ('Make {0} start automatically' -f $C.Service) { Set-Service -Name $C.Service -StartupType Automatic })
    }
    # the app's installer may have registered the service itself, without the old
    # command line's switches (winget's Radarr had none) - put them back
    $cur = [string](Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $C.Service)).PathName
    if (-not (Test-MsSameCommand $cur $bin) -and (Test-Path -LiteralPath (Get-CommandExe $bin))) {
      $name = $C.Service
      if ((Invoke-Change ('{0}: service command line -> {1}' -f $name, $bin) { Set-ServiceCommand $name $bin }) -and $svc.Status -eq 'Running') {
        [void](Invoke-Change ('Restart {0}' -f $name) { Restart-Service -Name $name -Force })
      }
    }
  }
  $svc = Get-Service -Name $C.Service -ErrorAction SilentlyContinue
  if (-not $svc -or $svc.Status -ne 'Running') { [void](Invoke-Change ('Start {0}' -f $C.Service) { Start-Service -Name $C.Service }) }
}

function Repair-MsPortable($C) {
  if (-not (Test-Path -LiteralPath $C.Exe) -or -not (Test-Path -LiteralPath $C.Marker)) {
    $src = Get-MsBackupPath (Get-MsFilesRel $C.Root)
    if (-not $src) { Say-Fail ('{0}: {1} is missing and the backup has no copy of it.' -f $C.Name, $C.Root); return }
    Get-Process -Name $C.Process -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (-not (Restore-MsTree $src $C.Root ('{0} ({1})' -f $C.Name, $C.Root))) { return }
  }
  if ($C.Registry) {
    $regKey = $C.Registry['Key']
    $vals = $C.Registry['Values']
    $f = Get-MsFact $C.Key
    if ($f -and $f.Registry) { $vals = [ordered]@{}; foreach ($p in $f.Registry.PSObject.Properties) { $vals[$p.Name] = Convert-KitPath ([string]$p.Value) } }
    foreach ($n in @($vals.Keys)) {
      $cur = (Get-ItemProperty -LiteralPath $regKey -Name $n -ErrorAction SilentlyContinue).$n
      if ($cur -eq $vals[$n]) { continue }
      $value = $vals[$n]
      [void](Invoke-Change ('{0}: registry {1} = {2}' -f $C.Name, $n, $value) {
        if (-not (Test-Path -LiteralPath $regKey)) { New-Item -Path $regKey -Force | Out-Null }
        New-ItemProperty -LiteralPath $regKey -Name $n -Value $value -PropertyType String -Force | Out-Null
      })
    }
  }
  $envChanged = $false
  foreach ($e in @($C.EnvVars)) {
    if (-not $e -or [Environment]::GetEnvironmentVariable($e, 'User')) { continue }
    $saved = Read-Json (Get-MsBackupPath 'settings\env\environment.json')
    $v = $null
    if ($saved) { $v = @($saved.Variables) | Where-Object { $_ -and $_.Scope -eq 'User' -and $_.Name -eq $e } | Select-Object -First 1 }
    if (-not $v) { Say-Warn ('{0}: environment variable {1} is missing and not in the backup - set it by hand.' -f $C.Name, $e); continue }
    $value = [string]$v.Value
    if ((Invoke-Change ('Set environment variable {0}' -f $e) { Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name $e -Value $value -Type String }) -and -not $DryRun) {
      [Environment]::SetEnvironmentVariable($e, $value, 'Process')
      $envChanged = $true
    }
  }
  # the program is started through Explorer below, so Explorer has to hear about the variable first
  if ($envChanged) { Send-EnvironmentChanged }
  # A Caddy that runs without its certificates (no DuckDNS token, or started as SYSTEM by
  # a watchdog before anyone signed in) still holds the port, so a new one could not start.
  if ($C.RestartIfDown -and (Test-MsRunning $C) -and (Test-MsComponent $C).Status -eq 'DOWN') {
    [void](Invoke-Change ('Stop {0} - it runs but does not serve' -f $C.Name) { Get-Process -Name $C.Process -ErrorAction SilentlyContinue | Stop-Process -Force })
    if (-not $DryRun) { Start-Sleep -Seconds 2 }
  }
  Ensure-MsLauncher $C
  if (-not (Test-MsRunning $C)) { Start-MsAsUser $C.Name (Resolve-MsPath $C.StartFile) }
  if ($C.Key -eq 'jellyfin') {
    # the watchdog task restarts Jellyfin when it hangs
    $tj = Read-Json (Get-MsBackupPath 'settings\tasks\tasks.json')
    $t = $null
    if ($tj -and $tj.Tasks) { $t = @($tj.Tasks) | Where-Object { $_ -and $_.Name -match '(?i)jellyfin' -and $_.XmlFile } | Select-Object -First 1 }
    if ($t -and -not (Get-ScheduledTask -TaskName (Convert-KitTaskName $t.Name) -TaskPath $t.Path -ErrorAction SilentlyContinue)) {
      $xmlPath = Get-MsBackupPath ('settings\tasks\' + $t.XmlFile)
      if ($xmlPath) { [void](Register-KitTaskFromBackup $t $xmlPath) }
    }
  }
}

function Repair-MsDockerEngine {
  $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (-not (Test-Path -LiteralPath $exe)) {
    if (-not (Install-MsPackage 'Docker.DockerDesktop')) { return $false }
    if (-not $DryRun) { Say-Warn 'Docker Desktop was just installed. Restart the PC, open Docker Desktop once, then run the repair again.'; return $false }
    return $true
  }
  if (Test-MsDockerUp) { return $true }
  Start-MsAsUser 'Docker Desktop' $exe
  if ($DryRun) { return $true }
  Say-Info 'Waiting for Docker to start (up to 3 minutes)...'
  if (Wait-MsUp { Test-MsDockerUp } 180) { Say-Ok 'Docker is running'; return $true }
  Say-Fail 'Docker did not start. Open Docker Desktop and check for a message (licence agreement, WSL update), then run the repair again.'
  return $false
}

function Repair-MsDockerStack {
  if (-not (Repair-MsDockerEngine)) { return }
  $d = Get-MsDockerFacts
  $dir = [string]$d.ProjectDir
  $compose = Join-Path $dir ([string]$d.ComposeFile)
  if (-not (Test-Path -LiteralPath $compose)) {
    $src = Get-MsBackupPath (Get-MsFilesRel $dir)
    if (-not $src) { Say-Fail ('{0} is missing and not in the backup - Seerr and Jellystat cannot be set up.' -f $compose); return }
    if (-not (Restore-MsTree $src $dir 'Docker compose files')) { return }
  }
  $existing = @()
  if (-not $DryRun -or (Test-MsDockerUp)) { $existing = @(((Invoke-MsDocker 'volume ls -q').StdOut -split "`r?`n") | Where-Object { $_ }) }
  $fresh = @{}
  foreach ($v in @($d.Volumes)) { if ($v) { $fresh[[string]$v.Name] = ($existing -notcontains [string]$v.Name) } }
  foreach ($v in @($d.Volumes | Where-Object { $_ -and $_.External -and $fresh[[string]$_.Name] })) {
    $vn = [string]$v.Name
    [void](Invoke-Change ('Create Docker volume {0} (compose expects it to exist)' -f $vn) { [void](Invoke-MsDockerOrThrow "volume create $vn") })
  }
  $up = 'compose --project-name {0} --project-directory "{1}" -f "{2}" up -d' -f $d.ProjectName, $dir, $compose
  $ok = Invoke-Change 'Start Seerr and Jellystat (docker compose up -d) - may download images first' { [void](Invoke-MsDockerOrThrow $up) }
  if (-not $ok) { return }

  $seerrVol = @($d.Volumes | Where-Object { $_ -and $_.Container -eq 'seerr' } | ForEach-Object { [string]$_.Name }) | Select-Object -First 1
  if ($seerrVol -and $fresh[$seerrVol]) {
    $src = Get-MsBackupPath 'settings\mediaserver\seerr\config'
    if ($src) {
      $from = ($src.Replace('\', '/')) + '/.'
      $owner = '{0}:{1}' -f $d.SeerrUid, $d.SeerrGid
      [void](Invoke-Change 'Put back Seerr settings and request history' {
        [void](Invoke-MsDockerOrThrow 'stop seerr')
        [void](Invoke-MsDockerOrThrow ('cp "{0}" seerr:/app/config' -f $from))
        [void](Invoke-MsDockerOrThrow 'start seerr')
        [void](Invoke-MsDockerOrThrow ('exec -u 0 seerr chown -R {0} /app/config' -f $owner))
        [void](Invoke-MsDockerOrThrow 'restart seerr')
      })
    } else { Say-Warn 'Seerr started empty - the backup has no Seerr data.' }
  }

  $dbVol = @($d.Volumes | Where-Object { $_ -and $_.Container -eq 'jellystat-db' } | ForEach-Object { [string]$_.Name }) | Select-Object -First 1
  if ($dbVol -and $fresh[$dbVol]) {
    $dump = Get-MsBackupPath 'settings\mediaserver\jellystat\jfstat.sql'
    $user = Get-MsEnvFileValue (Join-Path $dir '.env') 'JELLYSTAT_DB_USER'
    if ($dump -and $user) {
      if (-not $DryRun) { [void](Wait-MsUp { (Invoke-MsDocker ('exec jellystat-db pg_isready -U {0} -d jfstat' -f $user)).ExitCode -eq 0 } 120) }
      [void](Invoke-Change 'Put back Jellystat watch history' {
        [void](Invoke-MsDockerOrThrow 'stop jellystat')
        [void](Invoke-MsDockerOrThrow ('cp "{0}" jellystat-db:/tmp/jfstat.sql' -f $dump))
        [void](Invoke-MsDockerOrThrow ('exec jellystat-db psql -q -U {0} -d jfstat -f /tmp/jfstat.sql' -f $user))
        [void](Invoke-MsDockerOrThrow 'exec jellystat-db rm -f /tmp/jfstat.sql')
        [void](Invoke-MsDockerOrThrow 'start jellystat')
      })
    } else { Say-Warn 'Jellystat started empty - no database dump (or no JELLYSTAT_DB_USER in .env) in the backup.' }
  }
}

function Repair-MsHomeAssistant($C) {
  $vbox = Get-MsVBoxManage
  if (-not $vbox) {
    if (-not (Install-MsPackage $C.Winget)) { return }
    $vbox = Get-MsVBoxManage
    if (-not $vbox) { if (-not $DryRun) { Say-Fail 'VirtualBox did not install.' }; return }
  }
  $ha = $null
  if ($script:MsFacts) { $ha = $script:MsFacts.HomeAssistant }
  $name = Get-MsVmName
  if (-not (Get-MsVmInfo $vbox $name)) {
    $cfg = $null
    if ($ha -and $ha.CfgFile) { $cfg = Convert-KitPath ([string]$ha.CfgFile) }
    if (-not $cfg) { $cfg = Join-Path $env:USERPROFILE ('VirtualBox VMs\{0}\{0}.vbox' -f $name) }
    $cfgDir = Split-Path $cfg -Parent
    # 1. the VM's settings + EFI memory (they travel with the profile)
    $haveCfg = Test-Path -LiteralPath $cfg
    if (-not $haveCfg) {
      $src = Get-MsBackupPath (Get-MsFilesRel $cfgDir)
      if ($src) { $haveCfg = (Restore-MsTree $src $cfgDir 'Home Assistant VM settings') -and ($DryRun -or (Test-Path -LiteralPath $cfg)) }
    }
    # 2. its virtual disks (on G:)
    $diskList = @(@($ha.Disks) | Where-Object { $_ })
    $haveDisks = $diskList.Count -gt 0
    foreach ($disk in $diskList) {
      $p = Convert-KitPath ([string]$disk.Path)
      if (Test-Path -LiteralPath $p) { continue }
      $src = Get-MsBackupPath (Get-MsFilesRel $p)
      $ok = $false
      if ($src) { $ok = (Restore-MsTree (Split-Path $src -Parent) (Split-Path $p -Parent) ('Home Assistant disks ({0})' -f (Split-Path $p -Parent))) -and ($DryRun -or (Test-Path -LiteralPath $p)) }
      if (-not $ok) { $haveDisks = $false }
    }
    # 3. tell VirtualBox about it (with no disk list in the backup, let VirtualBox judge the
    #    settings file) - or, with nothing usable, build a fresh Home Assistant OS VM
    $registered = $false
    if ($haveCfg -and ($haveDisks -or $diskList.Count -eq 0)) {
      $registered = Invoke-Change 'Register the Home Assistant VM with VirtualBox' {
        $r = Invoke-Native $vbox ('registervm "{0}"' -f $cfg)
        if ($r.ExitCode -ne 0) { throw $r.Output.Trim() }
      }
    }
    if (-not $registered) {
      New-MsHaosVm $vbox $name $ha
      return
    }
  }
  $info = Get-MsVmInfo $vbox $name
  if ($info -and $info['nic1'] -eq 'bridged' -and $info['VMState'] -ne 'running') {
    $want = $info['bridgeadapter1']
    if (-not (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -eq $want })) {
      $nic = Get-MsWiredAdapter
      if ($nic) {
        $desc = $nic.InterfaceDescription
        [void](Invoke-Change ('Connect the VM to this PC''s network adapter ({0})' -f $desc) {
          $r = Invoke-Native $vbox ('modifyvm "{0}" --bridgeadapter1 "{1}"' -f $name, $desc)
          if ($r.ExitCode -ne 0) { throw $r.Output.Trim() }
        })
      }
    }
  }
  Ensure-MsLauncher $C
  $info = Get-MsVmInfo $vbox $name
  if (-not $info -or $info['VMState'] -ne 'running') {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'HomeAssistant.lnk'
    if (Test-Path -LiteralPath $lnk) { Start-MsAsUser 'the Home Assistant VM' $lnk }
    else { [void](Invoke-Change 'Start the Home Assistant VM' { $r = Invoke-Native $vbox ('startvm "{0}" --type gui' -f $name); if ($r.ExitCode -ne 0) { throw $r.Output.Trim() } }) }
  }
}

# Last resort, when no Home Assistant disk survived: a fresh Home Assistant OS VM
# with the old settings (same MAC, so the router gives it the same IP). Your HA
# backup is then restored in Home Assistant's own welcome screen.
function New-MsHaosVm([string]$VBox, [string]$Name, $Ha) {
  $mem = 4096; $cpus = 4; $mac = $null; $diskDir = 'G:\HomeAssistant'
  if ($Ha) {
    if ($Ha.Memory) { $mem = [int]$Ha.Memory }
    if ($Ha.Cpus) { $cpus = [int]$Ha.Cpus }
    if ($Ha.Mac) { $mac = [string]$Ha.Mac }
    $boot = @($Ha.Disks) | Where-Object { $_ -and $_.Path -notmatch '^[Cc]:' } | Select-Object -First 1
    if ($boot) { $diskDir = Split-Path ([string]$boot.Path) -Parent }
  }
  if (-not (Test-Path -LiteralPath ([IO.Path]::GetPathRoot($diskDir)))) { $diskDir = Join-Path $env:USERPROFILE "VirtualBox VMs\$Name" }
  $tar = $null
  $haDir = Get-MsBackupPath 'settings\mediaserver\homeassistant'
  if ($haDir) { $tar = @(Get-ChildItem -LiteralPath $haDir -Filter *.tar -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) | Select-Object -First 1 }
  Say-Warn 'No Home Assistant disk was found - setting up a fresh Home Assistant OS. Afterwards you restore your HA backup in its welcome screen.'
  if ($DryRun) { Say ('  [dry-run] download the latest Home Assistant OS image to {0} and create VM "{1}" ({2} MB, {3} CPUs, MAC {4})' -f $diskDir, $Name, $mem, $cpus, $mac) 'DarkGray'; return }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/home-assistant/operating-system/releases/latest' -Headers @{ 'User-Agent' = 'PC-Migration-Kit' }
    $asset = @($rel.assets | Where-Object { $_.name -match '^haos_ova-.*\.vdi\.zip$' }) | Select-Object -First 1
    if (-not $asset) { throw 'no VDI image in the latest Home Assistant OS release' }
    $zip = Join-Path $env:TEMP $asset.name
    Say-Info ('Downloading {0} ({1:N0} MB)...' -f $asset.name, ($asset.size / 1MB))
    (New-Object Net.WebClient).DownloadFile($asset.browser_download_url, $zip)
    New-Dir $diskDir | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $diskDir -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    $vdi = @(Get-ChildItem -LiteralPath $diskDir -Filter 'haos_ova-*.vdi' | Sort-Object LastWriteTime -Descending) | Select-Object -First 1
    if (-not $vdi) { throw 'the downloaded image did not contain a .vdi file' }
    $nic = Get-MsWiredAdapter
    $steps = @(
      ('createvm --name "{0}" --ostype Linux_64 --register' -f $Name),
      ('modifyvm "{0}" --firmware efi --memory {1} --cpus {2} --nic1 bridged --bridgeadapter1 "{3}"{4}' -f $Name, $mem, $cpus, $nic.InterfaceDescription, $(if ($mac) { ' --macaddress1 ' + $mac } else { '' })),
      ('storagectl "{0}" --name "SATA" --add sata --controller IntelAhci --portcount 4' -f $Name),
      ('modifymedium disk "{0}" --resize 65536' -f $vdi.FullName),
      ('storageattach "{0}" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "{1}"' -f $Name, $vdi.FullName))
    foreach ($s in $steps) { $r = Invoke-Native $VBox $s; if ($r.ExitCode -ne 0) { throw ('VBoxManage {0}: {1}' -f ($s -split ' ')[0], $r.Output.Trim()) } }
    Say-Ok ('Created VM "{0}" with Home Assistant OS {1}' -f $Name, $rel.tag_name)
    # a new VM has a new ID, so the old shortcut (which starts the VM by ID) would do nothing - start it by name
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'HomeAssistant.lnk'
    New-MsShortcut $lnk (Join-Path (Get-MsVBoxDir) 'VirtualBoxVM.exe') ('--comment "{0}" --startvm "{0}"' -f $Name)
    Say-Ok 'Home Assistant VM starts when you sign in'
    Open-AsUser $lnk
    Say-Warn ('In 2-5 minutes open http://homeassistant.local:8123, choose "Restore from backup" and upload {0}' -f $(if ($tar) { $tar.FullName } else { 'your newest Home Assistant backup (.tar)' }))
  } catch { Say-Fail ('Setting up a fresh Home Assistant OS failed: {0}' -f $_.Exception.Message) }
}

function Set-MsNetworkPrivate($Net, [switch]$Interactive) {
  if (-not $Net -or $Net.Status -ne 'WARN') { return }
  $ask = 'Your network is set to Public, which blocks other devices. Switch it to Private? (Y/n)'
  if ($Net.Stale) { $ask = 'Windows shows your network as Private, but its firewall still treats it as Public, which blocks other devices. Fix that? (Y/n)' }
  if ($Interactive -and -not $DryRun) {
    if ((Read-KitAnswer 'network' $ask 'y' @('y', 'n')) -match '^[nN]') { return }
  }
  $idx = $Net.IfIndex
  if ($Net.Stale) {
    # only a real change hands the category to the network stack again
    [void](Invoke-Change 'Hand the Private setting to the firewall again (Public -> Private)' {
      Set-NetConnectionProfile -InterfaceIndex $idx -NetworkCategory Public
      Start-Sleep -Seconds 2
      Set-NetConnectionProfile -InterfaceIndex $idx -NetworkCategory Private
    })
  } else {
    [void](Invoke-Change 'Set the home network to Private' { Set-NetConnectionProfile -InterfaceIndex $idx -NetworkCategory Private })
  }
}

# Fixes every part that is not OK (or the ones in -Force), then checks again.
function Invoke-MsRepair([string[]]$Only, [string[]]$Force, [switch]$Interactive) {
  $defs = @(Get-MsDefinitions)
  if ($Only) { $defs = @($defs | Where-Object { $Only -contains $_.Key }) }
  Say-Info 'Checking the media server and smart home...'
  $before = @(Test-MsAll)
  Show-MsTable $before
  $firewallByUs = Test-MsWindowsFirewallInCharge
  $dockerDone = $false
  foreach ($c in $defs) {
    $st = $before | Where-Object { $_.Key -eq $c.Key } | Select-Object -First 1
    $broken = ($st -and $st.Status -ne 'OK') -or ($Force -contains $c.Key)
    if ($broken) {
      Say-Step ('Setting up {0}' -f $c.Name)
      try {
        switch ($c.Kind) {
          'App'       { Repair-MsApp $c }
          'Service'   { Repair-MsService $c }
          'Portable'  { Repair-MsPortable $c }
          'Docker'    { [void](Repair-MsDockerEngine) }
          'Container' { if (-not $dockerDone) { Repair-MsDockerStack; $dockerDone = $true } }
          'VM'        { Repair-MsHomeAssistant $c }
        }
      } catch { Say-Fail ('{0}: {1}' -f $c.Name, $_.Exception.Message) }
    }
    if ($firewallByUs) { try { Ensure-MsFirewall $c } catch { Say-Warn ('Firewall rule for {0}: {1}' -f $c.Name, $_.Exception.Message) } }
  }
  if (-not $firewallByUs) { Say-Info 'Firewall ports: your antivirus firewall is in charge, so no Windows Firewall rules were added.' }
  Set-MsNetworkPrivate ($before | Where-Object { $_.Key -eq 'network' } | Select-Object -First 1) -Interactive:$Interactive

  if ($DryRun) { Say-Info 'Dry run - nothing was changed.'; return $before }
  Say-Info 'Giving everything a moment to start, then checking again...'
  [void](Wait-MsUp { @(Test-MsAll | Where-Object { $_.Status -notin 'OK', 'WARN' }).Count -eq 0 } 150)
  $after = @(Test-MsAll)
  Show-MsTable $after
  return $after
}

# ================================================================== backup ===
function Get-MsFacts {
  $comps = @(foreach ($c in Get-MsDefinitions) {
    $f = [ordered]@{ Key = $c.Key; Port = (Get-MsLivePort $c) }
    if ($c.Kind -eq 'Service') {
      $s = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $c.Service) -ErrorAction SilentlyContinue
      if ($s) { $f.BinPath = $s.PathName; $f.DisplayName = $s.DisplayName; $f.Description = $s.Description; $f.StartMode = $s.StartMode }
    }
    if ($c.Registry) {
      $r = [ordered]@{}
      foreach ($n in @($c.Registry['Values'].Keys)) { $v = (Get-ItemProperty -LiteralPath $c.Registry['Key'] -Name $n -ErrorAction SilentlyContinue).$n; if ($v) { $r[$n] = [string]$v } }
      if ($r.Count) { $f.Registry = $r }
    }
    if ($c.Key -eq 'qbittorrent') { $f.ListenPort = Get-MsIniValue (Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini') 'Session\Port' }
    if ($c.Key -eq 'jackett') { try { $f.AllowExternal = (Get-Content -LiteralPath (Join-Path $c.DataDir 'ServerConfig.json') -Raw | ConvertFrom-Json).AllowExternal } catch {} }
    [pscustomobject]$f
  })

  $ha = $null
  $vbox = Get-MsVBoxManage
  if ($vbox) {
    $info = Get-MsVmInfo $vbox 'HomeAssistant'
    if ($info) {
      $disks = @(foreach ($k in $info.Keys) {
        $km = [regex]::Match($k, '^(.+)-(\d+)-(\d+)$')
        if ($km.Success -and $k -notmatch 'ImageUUID|IsEjected|hot-pluggable|nonrotational|discard|tempeject' -and $info[$k] -match '^[A-Za-z]:\\') {
          [pscustomobject]@{ Controller = $km.Groups[1].Value; Port = [int]$km.Groups[2].Value; Device = [int]$km.Groups[3].Value; Path = $info[$k] }
        }
      })
      $mac = [string]$info['macaddress1']
      $ip = $null
      if ($mac) {
        $dash = ($mac.ToUpper() -replace '(..)(?!$)', '$1-')
        $ip = @(Get-NetNeighbor -LinkLayerAddress $dash -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress }) | Select-Object -First 1
      }
      $ha = [pscustomobject]@{ Name = $info['name']; Uuid = $info['UUID']; CfgFile = $info['CfgFile']; Memory = $info['memory']; Cpus = $info['cpus']
                               Firmware = $info['firmware']; Nic = $info['nic1']; BridgeAdapter = $info['bridgeadapter1']; Mac = $mac; Ip = $ip
                               State = $info['VMState']; Disks = @($disks | Sort-Object Controller, Port) }
    }
  }

  $docker = $null
  if ((Get-MsDockerExe) -and (Test-MsDockerUp)) {
    $ids = @(((Invoke-MsDocker 'ps -aq --filter name=seerr --filter name=jellystat').StdOut -split "`r?`n") | Where-Object { $_ })
    if ($ids.Count) {
      try {
        $info = (Invoke-MsDocker ('inspect ' + ($ids -join ' '))).StdOut | ConvertFrom-Json
        $dir = @($info | ForEach-Object { $_.Config.Labels.'com.docker.compose.project.working_dir' } | Where-Object { $_ }) | Select-Object -First 1
        $proj = @($info | ForEach-Object { $_.Config.Labels.'com.docker.compose.project' } | Where-Object { $_ }) | Select-Object -First 1
        $composeText = ''
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'compose.yml'))) { $composeText = [IO.File]::ReadAllText((Join-Path $dir 'compose.yml')) }
        $vols = @(foreach ($ct in $info) {
          foreach ($m in @($ct.Mounts | Where-Object { $_.Type -eq 'volume' })) {
            $short = $m.Name; if ($proj -and $short.StartsWith($proj + '_')) { $short = $short.Substring($proj.Length + 1) }
            $ext = [regex]::IsMatch($composeText, '(?m)^\s+' + [regex]::Escape($short) + ':\s*\r?\n\s+external:\s*true')
            [pscustomobject]@{ Container = $ct.Name.TrimStart('/'); Name = $m.Name; Destination = $m.Destination; External = $ext }
          }
        })
        $uid = ((Invoke-MsDocker 'exec seerr id -u').StdOut).Trim(); $gid = ((Invoke-MsDocker 'exec seerr id -g').StdOut).Trim()
        if ($uid -notmatch '^\d+$') { $uid = '1000' }; if ($gid -notmatch '^\d+$') { $gid = '1000' }
        $docker = [pscustomobject]@{ ProjectDir = $dir; ProjectName = $proj; ComposeFile = 'compose.yml'; Volumes = $vols; SeerrUid = $uid; SeerrGid = $gid }
      } catch {}
    }
  }
  [pscustomobject]@{ CreatedAt = (Get-Date).ToString('s'); Components = $comps; HomeAssistant = $ha; Docker = $docker }
}

# Settings-sized part of the media server backup: facts, Seerr data, a Jellystat
# database dump and the newest Home Assistant backup file.
function Save-MsSnapshot([string]$SettingsDir, $Facts, [switch]$TestMode) {
  $dir = New-Dir (Join-Path $SettingsDir 'mediaserver')
  $facts = $Facts
  if (-not $facts) { $facts = Get-MsFacts }
  Save-Json $facts (Join-Path $dir 'mediaserver.json')
  Say-Ok ('Media server + smart home: {0} parts described' -f @($facts.Components).Count)

  if ($facts.Docker -and (Test-KitSelected 'Media' 'seerr')) {
    # Seerr keeps everything in /app/config (SQLite). Stopping it for a few seconds gives a clean copy.
    $seerr = New-Dir (Join-Path $dir 'seerr')
    $cfg = Join-Path $seerr 'config'
    if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Recurse -Force }   # our own copy from an earlier run
    New-Dir $cfg | Out-Null
    $stopped = $false
    if (-not $TestMode) { $stopped = (Invoke-MsDocker 'stop seerr').ExitCode -eq 0 }
    # only what Seerr needs: its settings and database (logs/ holds symlinks, cache/ is re-downloaded)
    try {
      $r1 = Invoke-MsDocker ('cp seerr:/app/config/settings.json "{0}"' -f (Join-Path $cfg 'settings.json'))
      $r2 = Invoke-MsDocker ('cp seerr:/app/config/db "{0}"' -f (Join-Path $cfg 'db'))
    } finally { if ($stopped) { [void](Invoke-MsDocker 'start seerr') } }
    if ($r1.ExitCode -eq 0 -and $r2.ExitCode -eq 0) { Say-Ok 'Seerr settings and request history' }
    else { Say-Warn ('Seerr data could not be copied: ' + ($r1.Output + ' ' + $r2.Output).Trim()) }
  }
  if ($facts.Docker -and (Test-KitSelected 'Media' 'jellystat')) {
    # Jellystat lives in PostgreSQL: pg_dump is the consistent way to copy it.
    $js = New-Dir (Join-Path $dir 'jellystat')
    $user = Get-MsEnvFileValue (Join-Path ([string]$facts.Docker.ProjectDir) '.env') 'JELLYSTAT_DB_USER'
    if ($user) {
      $a = Invoke-MsDocker ('exec jellystat-db pg_dump -U {0} -d jfstat --clean --if-exists -f /tmp/jfstat.sql' -f $user)
      $b = Invoke-MsDocker ('cp jellystat-db:/tmp/jfstat.sql "{0}"' -f (Join-Path $js 'jfstat.sql'))
      [void](Invoke-MsDocker 'exec jellystat-db rm -f /tmp/jfstat.sql')
      if ($a.ExitCode -eq 0 -and $b.ExitCode -eq 0) { Say-Ok ('Jellystat database ({0})' -f (Format-Bytes (Get-Item -LiteralPath (Join-Path $js 'jfstat.sql')).Length)) }
      else { Say-Warn ('Jellystat database dump failed: ' + ($a.Output + ' ' + $b.Output).Trim()) }
    } else { Say-Warn 'Jellystat: no JELLYSTAT_DB_USER in the compose .env file - database not dumped.' }
  }
  if (-not $facts.Docker -and ((Test-KitSelected 'Media' 'seerr') -or (Test-KitSelected 'Media' 'jellystat'))) { Say-Warn 'Docker is not running - Seerr and Jellystat data were not exported (the copy of Docker''s data disk still has them).' }

  # newest Home Assistant backup (.tar) found in the usual places
  $roots = @('D:\', 'G:\HomeAssistant', 'F:\HomeAssistant', 'F:\Backups', (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Documents'))
  if (-not (Test-KitSelected 'Media' 'homeassistant')) { return $facts }
  $tar = @(foreach ($r in $roots) { Get-ChildItem -LiteralPath $r -Filter *.tar -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 1MB -and $_.Name -match '(?i)ha|home|backup' } }) |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($tar) {
    $age = [int]((Get-Date) - $tar.LastWriteTime).TotalDays
    if (-not $TestMode) { Copy-Item -LiteralPath $tar.FullName -Destination (New-Dir (Join-Path $dir 'homeassistant')) -Force }
    if ($age -gt 14) { Say-Warn ('Newest Home Assistant backup file is {0} days old ({1}). Make a fresh one: HA -> Settings -> System -> Backups -> Create backup, download it into F:\HomeAssistant, then run BACKUP again.' -f $age, $tar.Name) }
    else { Say-Ok ('Home Assistant backup file {0} ({1} days old)' -f $tar.Name, $age) }
  } elseif ($facts.HomeAssistant) { Say-Warn 'No Home Assistant backup file (.tar) found. The VM disk copy covers it, but a fresh HA backup is the safest extra: HA -> Settings -> System -> Backups.' }
  return $facts
}

# The folders of the media server that live outside C: - copied by BACKUP like
# everything else (from a snapshot of their drive, so running databases are consistent).
function Get-MsCopyJobs($Facts) {
  $jobs = New-Object System.Collections.Generic.List[object]
  foreach ($c in @(Get-MsDefinitions | Where-Object { $_.Kind -eq 'Portable' })) {
    if (-not (Test-Path -LiteralPath $c.Root)) { continue }
    if (-not (Test-KitSelected 'Media' $c.Key)) { continue }
    $jobs.Add([pscustomobject]@{ Key = $c.Key; Label = ('{0} ({1})' -f $c.Name, $c.Root); Path = $c.Root; Dest = (Get-MsFilesRel $c.Root)
                                 ExcludeRel = @($c.ExcludeRel); ExcludeNames = @($c.ExcludeNames); ExcludeFiles = @($c.ExcludeFiles); Files = $null })
  }
  $d = $null
  if ($Facts) { $d = $Facts.Docker }
  $dockerDir = if ($d -and $d.ProjectDir) { [string]$d.ProjectDir } else { 'D:\Docker' }
  if ((Test-Path -LiteralPath $dockerDir) -and $dockerDir -notmatch '^[Cc]:' -and (Test-KitSelected 'Media' 'docker')) {
    $jobs.Add([pscustomobject]@{ Key = 'docker'; Label = "Docker compose files ($dockerDir)"; Path = $dockerDir; Dest = (Get-MsFilesRel $dockerDir); ExcludeRel = @(); ExcludeNames = @(); ExcludeFiles = @(); Files = $null })
  }
  if ($Facts -and $Facts.HomeAssistant -and (Test-KitSelected 'Media' 'homeassistant')) {
    # only the disk files the VM really uses - old copies lying next to them are left out
    $byDir = [ordered]@{}
    foreach ($disk in @($Facts.HomeAssistant.Disks)) {
      if (-not $disk -or [string]$disk.Path -match '^[Cc]:') { continue }
      $hd = Split-Path ([string]$disk.Path) -Parent
      if (-not $byDir.Contains($hd)) { $byDir[$hd] = New-Object System.Collections.Generic.List[string] }
      $byDir[$hd].Add((Split-Path ([string]$disk.Path) -Leaf))
    }
    foreach ($hd in @($byDir.Keys)) {
      if (Test-Path -LiteralPath $hd) {
        $jobs.Add([pscustomobject]@{ Key = 'homeassistant'; Label = "Home Assistant disks ($hd)"; Path = $hd; Dest = (Get-MsFilesRel $hd); ExcludeRel = @(); ExcludeNames = @(); ExcludeFiles = @(); Files = $byDir[$hd].ToArray() })
      }
    }
  }
  return $jobs.ToArray()
}
