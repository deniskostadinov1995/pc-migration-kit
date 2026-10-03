<#
  PC Migration Kit - shared helpers
  ---------------------------------
  Console + log output, the robocopy wrapper (with a live progress bar), JSON
  helpers and small utilities used by both Backup.ps1 and Restore.ps1.

  Written by Claude 2026-09-27.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$script:KitVersion = '2.0'
$script:LogPath    = $null
$script:LogDir     = $null
$script:Issues     = New-Object System.Collections.Generic.List[string]

# Started by the PC Migration Kit app (PC Migration Kit.exe) instead of a console:
# every message, step and progress update goes out as one "@@PCMK {json}" line on
# stdout, and questions are answered by the app on stdin.
$script:Gui = ($env:PCMK_GUI -eq '1')
$script:GuiLastProgress = [DateTime]::MinValue

# ------------------------------------------------------------------ output ---
function Start-KitLog([string]$Path) {
  $script:LogPath = $Path
  $script:LogDir  = Join-Path (Split-Path $Path -Parent) 'logs'
  New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
  Add-Content -LiteralPath $Path -Encoding UTF8 -Value ('==== PC Migration Kit {0}  {1} ====' -f $script:KitVersion, (Get-Date))
  Send-KitEvent @{ t = 'logfile'; path = $Path }
}

function Write-KitLog([string]$Text) {
  if (-not $script:LogPath) { return }
  try { Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) } catch {}
}

function Send-KitEvent([hashtable]$Event) {
  if (-not $script:Gui) { return }
  try {
    $json = ConvertTo-Json -InputObject $Event -Compress -Depth 8
    [Console]::Out.WriteLine('@@PCMK ' + $json)
    [Console]::Out.Flush()
  } catch {}
}

# $Level tells the app how to show the line: text, step, ok, info, warn, fail.
function Say([string]$Text, [string]$Color = 'Gray', [string]$Level = 'text') {
  if ($script:Gui) { Send-KitEvent @{ t = 'log'; lvl = $Level; text = $Text.Trim() } }
  else { Write-Host $Text -ForegroundColor $Color }
  Write-KitLog $Text
}
function Say-Step([string]$Text) { if (-not $script:Gui) { Write-Host '' }; Say ('=== {0} ===' -f $Text) 'Cyan' 'step' }
function Say-Ok([string]$Text)   { if ($script:Gui) { Send-KitEvent @{ t = 'log'; lvl = 'ok'; text = $Text }; Write-KitLog ('  [OK]   ' + $Text) } else { Say ('  [OK]   ' + $Text) 'Green' } }
function Say-Info([string]$Text) { if ($script:Gui) { Send-KitEvent @{ t = 'log'; lvl = 'info'; text = $Text }; Write-KitLog ('         ' + $Text) } else { Say ('         ' + $Text) 'Gray' } }
function Say-Warn([string]$Text) { if ($script:Gui) { Send-KitEvent @{ t = 'log'; lvl = 'warn'; text = $Text }; Write-KitLog ('  [!]    ' + $Text) } else { Say ('  [!]    ' + $Text) 'Yellow' }; $script:Issues.Add($Text) }
function Say-Fail([string]$Text) { if ($script:Gui) { Send-KitEvent @{ t = 'log'; lvl = 'fail'; text = $Text }; Write-KitLog ('  [FAIL] ' + $Text) } else { Say ('  [FAIL] ' + $Text) 'Red' }; $script:Issues.Add($Text) }

# A progress bar in the console, or a progress event for the app (at most a few per second).
function Show-KitProgress([string]$Activity, [string]$Status, [int]$Percent = -1, [string]$Current = '', [switch]$Completed, [hashtable]$Extra) {
  if ($script:Gui) {
    $now = [DateTime]::UtcNow
    if (-not $Completed -and ($now - $script:GuiLastProgress).TotalMilliseconds -lt 400) { return }
    $script:GuiLastProgress = $now
    $e = @{ t = 'progress'; activity = $Activity; status = $Status; pct = $Percent; current = $Current; done = [bool]$Completed }
    if ($Extra) { foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] } }
    Send-KitEvent $e
    return
  }
  if ($Completed) { Write-Progress -Activity $Activity -Completed; return }
  if ($Percent -ge 0) { Write-Progress -Activity $Activity -Status $Status -CurrentOperation $Current -PercentComplete $Percent }
  else { Write-Progress -Activity $Activity -Status $Status -CurrentOperation $Current }
}

# A question for the person in front of the PC: Read-Host in the console, a dialog in the app.
function Read-KitAnswer([string]$Id, [string]$Prompt, [string]$Default = '', [string[]]$Options = @(), [string[]]$Items = @()) {
  if ($script:Gui) {
    Send-KitEvent @{ t = 'ask'; id = $Id; text = $Prompt; default = $Default; options = @($Options); items = @($Items) }
    $a = $null
    try { $a = [Console]::In.ReadLine() } catch {}
    Write-KitLog ('answer to "{0}": {1}' -f $Id, $a)
    if ($null -eq $a) { return $Default }
    return $a
  }
  return (Read-Host $Prompt)
}

function Show-Banner([string]$Title, [string]$Subtitle) {
  if ($script:Gui) { Send-KitEvent @{ t = 'banner'; title = $Title; text = $Subtitle }; return }
  try { $Host.UI.RawUI.WindowTitle = "PC Migration Kit - $Title" } catch {}
  Write-Host ''
  Write-Host '  ================================================================' -ForegroundColor DarkCyan
  Write-Host ('   PC MIGRATION KIT  -  {0}' -f $Title) -ForegroundColor White
  if ($Subtitle) { Write-Host ('   {0}' -f $Subtitle) -ForegroundColor Gray }
  Write-Host '  ================================================================' -ForegroundColor DarkCyan
}

function Exit-Kit([int]$Code = 0, [switch]$NoPause) {
  if ($script:Gui) { Send-KitEvent @{ t = 'exit'; code = $Code; issues = @($script:Issues) }; exit $Code }
  Write-Host ''
  if (-not $NoPause) { [void](Read-Host 'Press ENTER to close this window') }
  exit $Code
}

# Opens a file through Explorer so the browser starts with normal (not admin) rights.
function Open-AsUser([string]$Path) {
  try { Start-Process -FilePath "$env:windir\explorer.exe" -ArgumentList ('"{0}"' -f $Path) } catch {}
}

function Set-ConsoleUtf8 {
  # winget/wsl print UTF-8; without this, Cyrillic app names come back garbled.
  try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
  Disable-QuickEdit
}

# A click inside a console window with QuickEdit on puts it in "Select" mode,
# which freezes all output - and with it the whole script - until Esc is pressed.
# Long unattended runs must not be stoppable by a stray click.
function Disable-QuickEdit {
  try {
    if (-not ('PCMK.ConsoleMode' -as [type])) {
      Add-Type -Namespace PCMK -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    }
    $h = [PCMK.ConsoleMode]::GetStdHandle(-10)   # STD_INPUT_HANDLE
    $mode = 0
    if ([PCMK.ConsoleMode]::GetConsoleMode($h, [ref]$mode)) {
      [void][PCMK.ConsoleMode]::SetConsoleMode($h, (($mode -band (-bnot 0x40)) -bor 0x80))   # clear QUICK_EDIT, keep EXTENDED_FLAGS
    }
  } catch {}
}

# ----------------------------------------------------------------- basics ---
function Test-IsAdmin {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Bytes([double]$Bytes) {
  if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
  if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
  if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
  return '{0:N0} KB' -f ($Bytes / 1KB)
}

function New-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
  return $Path
}

function Get-SafeName([string]$Name) {
  $bad = [IO.Path]::GetInvalidFileNameChars()
  $sb = New-Object Text.StringBuilder
  foreach ($c in $Name.ToCharArray()) { if ($bad -contains $c) { [void]$sb.Append('_') } else { [void]$sb.Append($c) } }
  return $sb.ToString().Trim()
}

function HtmlEnc($Value) { return [System.Net.WebUtility]::HtmlEncode([string]$Value) }

# JSON is always written as an object at the top level (arrays as properties),
# which sidesteps Windows PowerShell's array-unrolling quirks on the way back in.
function Save-Json($Object, [string]$Path, [int]$Depth = 12) {
  New-Dir (Split-Path $Path -Parent) | Out-Null
  $json = ConvertTo-Json -InputObject $Object -Depth $Depth
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Read-Json([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
  if (-not $text.Trim()) { return $null }
  return (ConvertFrom-Json -InputObject $text)
}

# ------------------------------------------------------------- selection ---
# What the person ticked in the app, passed in as "-Selection file.json". Each
# section (Apps, Tasks, Startup, Services, Settings, Registry, Media, Files ...)
# has either an Include or an Exclude list of ids. No selection, or no list for
# a section, means everything in it - the behaviour before the app existed.
$script:Sel = $null

function Read-KitSelection([string]$Path) {
  if (-not $Path) { return }
  if (-not (Test-Path -LiteralPath $Path)) { Say-Warn "Selection file not found: $Path - using everything."; return }
  $script:Sel = Read-Json $Path
  if ($script:Sel) { Write-KitLog ('Selection: ' + $Path) }
}

function Test-KitSelected([string]$Kind, [string]$Key) {
  if (-not $script:Sel -or -not $Kind) { return $true }
  $s = $script:Sel.$Kind
  if (-not $s) { return $true }
  $names = @($s.PSObject.Properties | ForEach-Object { $_.Name })
  if ($names -contains 'Include' -and $null -ne $s.Include) { return (@($s.Include) -contains $Key) }
  if ($names -contains 'Exclude' -and $null -ne $s.Exclude) { return -not (@($s.Exclude) -contains $Key) }
  return $true
}

# A list stored in the selection, e.g. Get-KitSelList 'Files' 'ExcludePaths'.
function Get-KitSelList([string]$Kind, [string]$Name) {
  if (-not $script:Sel -or -not $script:Sel.$Kind) { return @() }
  return @($script:Sel.$Kind.$Name | Where-Object { $_ })
}

# Is $Path one of $Roots or inside one of them (paths compared without case, trailing \ ignored)?
function Test-KitUnder([string]$Path, [string[]]$Roots) {
  if (-not $Path) { return $false }
  $p = $Path.TrimEnd('\') + '\'
  foreach ($r in $Roots) {
    if (-not $r) { continue }
    $rr = $r.TrimEnd('\') + '\'
    if ($p.StartsWith($rr, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-DownloadsFolder {
  try { return (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch { return (Join-Path $env:USERPROFILE 'Downloads') }
}

function Get-KnownFolderMap {
  [ordered]@{
    Desktop   = [Environment]::GetFolderPath('Desktop')
    Documents = [Environment]::GetFolderPath('MyDocuments')
    Downloads = Get-DownloadsFolder
    Pictures  = [Environment]::GetFolderPath('MyPictures')
    Music     = [Environment]::GetFolderPath('MyMusic')
    Videos    = [Environment]::GetFolderPath('MyVideos')
  }
}

# Pull the executable out of a command line such as
#   "C:\Program Files\X\x.exe" --flag     or     C:\Python314\pythonw.exe "D:\a.py"
function Get-CommandExe([string]$CommandLine) {
  if (-not $CommandLine) { return $null }
  $c = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
  if ($c.StartsWith('"')) {
    $end = $c.IndexOf('"', 1)
    if ($end -gt 1) { return $c.Substring(1, $end - 1) }
  }
  $m = [regex]::Match($c, '^(.+?\.(exe|com|bat|cmd|vbs|ps1|lnk|pyw?))(\s|$)', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value }
  return ($c -split '\s+')[0]
}

function Test-CommandExists([string]$Exe) {
  if (-not $Exe) { return $false }
  $e = [Environment]::ExpandEnvironmentVariables($Exe)
  if ([IO.Path]::IsPathRooted($e)) { return (Test-Path -LiteralPath $e) }
  return [bool](Get-Command $e -ErrorAction SilentlyContinue)
}

# Where a program is now when its old path is gone. A reinstall can move it:
# Epic Games went from "Program Files (x86)" to "Program Files" (2026-09-29), and
# per-user apps keep their version in a folder name (SignalRgb\app-2.5.72 -> app-2.5.74).
# Returns the path that exists, or $null.
function Resolve-KitMovedExe([string]$Exe) {
  if (-not $Exe) { return $null }
  $e = [Environment]::ExpandEnvironmentVariables($Exe.Trim().Trim('"'))
  if (-not [IO.Path]::IsPathRooted($e)) { $c = Get-Command $e -ErrorAction SilentlyContinue; if ($c) { return $c.Source }; return $null }
  if (Test-Path -LiteralPath $e -PathType Leaf) { return $e }
  $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}
  $other = $null
  if ($pf86 -and $e.StartsWith($pf86 + '\', [StringComparison]::OrdinalIgnoreCase)) { $other = $pf + $e.Substring($pf86.Length) }
  elseif ($pf -and $pf86 -and $e.StartsWith($pf + '\', [StringComparison]::OrdinalIgnoreCase)) { $other = $pf86 + $e.Substring($pf.Length) }
  if ($other -and (Test-Path -LiteralPath $other -PathType Leaf)) { return $other }
  # a version number in one of the folder names: app-2.5.72, 1.4.2, v3.0
  $parts = $e.Split('\')
  for ($i = $parts.Count - 2; $i -ge 1; $i--) {
    $m = [regex]::Match($parts[$i], '^(?<pre>.*?)\d+(\.\d+){1,3}(?<post>.*)$')
    if (-not $m.Success) { continue }
    $parent = $parts[0..($i - 1)] -join '\'
    if ($parent -match '^[A-Za-z]:$') { $parent += '\' }
    if (-not (Test-Path -LiteralPath $parent)) { continue }
    $rx = '^' + [regex]::Escape($m.Groups['pre'].Value) + '(\d+(?:\.\d+){1,3})' + [regex]::Escape($m.Groups['post'].Value) + '$'
    $rest = $parts[($i + 1)..($parts.Count - 1)] -join '\'
    $dirs = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rx } |
              Sort-Object { try { [version]([regex]::Match($_.Name, $rx).Groups[1].Value) } catch { [version]'0.0' } } -Descending)
    foreach ($d in $dirs) { $c = Join-Path $d.FullName $rest; if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
  }
  return $null
}

# The command line with its program swapped for where that program is now (see Resolve-KitMovedExe).
function Update-KitCommandExe([string]$CommandLine, [string]$OldExe, [string]$NewExe) {
  if (-not $CommandLine -or -not $OldExe -or -not $NewExe -or $OldExe -eq $NewExe) { return $CommandLine }
  $i = $CommandLine.IndexOf($OldExe, [StringComparison]::OrdinalIgnoreCase)
  if ($i -lt 0) { return $CommandLine }
  return $CommandLine.Substring(0, $i) + $NewExe + $CommandLine.Substring($i + $OldExe.Length)
}

# A command line in a form fit for comparing: no quotes, single spaces, lower case.
function Get-CommandKey([string]$CommandLine) {
  return ((([string]$CommandLine).Replace('"', '').Trim()) -replace '\s+', ' ').ToLowerInvariant()
}

# Points an existing service at another command line (program + switches).
function Set-ServiceCommand([string]$Name, [string]$CommandLine) {
  $w = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name)
  if (-not $w) { throw "service $Name not found" }
  $r = Invoke-CimMethod -InputObject $w -MethodName Change -Arguments @{ PathName = $CommandLine }
  if ($r.ReturnValue -ne 0) { throw ('Windows refused the change (code {0})' -f $r.ReturnValue) }
}

# Environment variables written to the registry reach programs started later only
# once Explorer hears about it - anything opened through Explorer (Open-AsUser)
# would otherwise start without them.
function Send-EnvironmentChanged {
  if (-not ('PCMK.Native' -as [type])) {
    Add-Type -Namespace PCMK -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
  }
  $r = [UIntPtr]::Zero
  [void][PCMK.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
}

# Starts a console tool with its argument string passed through verbatim
# (Windows PowerShell mangles embedded quotes when calling native programs).
# System.Diagnostics.Process is used instead of Start-Process because the latter
# can lose the exit code of a process that finishes very quickly.
function Start-NativeProcess([string]$Exe, [string]$Arguments) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  # drain both pipes in the background so the child can never block on a full buffer
  $out = $p.StandardOutput.ReadToEndAsync()
  $err = $p.StandardError.ReadToEndAsync()
  return [pscustomobject]@{ Process = $p; Out = $out; Err = $err }
}

function Invoke-Native([string]$Exe, [string]$Arguments) {
  $h = Start-NativeProcess $Exe $Arguments
  $h.Process.WaitForExit()
  $out = [string]$h.Out.Result; $err = [string]$h.Err.Result
  Write-KitLog ('{0} {1} -> exit {2}' -f $Exe, $Arguments, $h.Process.ExitCode)
  return [pscustomobject]@{ ExitCode = $h.Process.ExitCode; StdOut = $out; StdErr = $err; Output = ($out + $err) }
}

# Runs a change, or only describes it when the calling script runs with -DryRun.
function Invoke-Change([string]$What, [scriptblock]$Action) {
  if ($DryRun) { Say ('  [dry-run] ' + $What) 'DarkGray'; return $true }
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Stop'
  try { & $Action | Out-Null; Say-Ok $What; return $true }
  catch { Say-Fail ('{0} - {1}' -f $What, $_.Exception.Message); return $false }
  finally { $ErrorActionPreference = $old }
}

# ---------------------------------------------------- renamed user account ---
# RESTORE may run in an account with another name than the one the backup was
# made in (backup made as "Plex", restored as "Jellyfin"). Everything that still
# names the old account is rewritten for the current one: paths in settings
# files, registry values, shortcuts, services, scheduled tasks and startup
# items. The entry scripts set $script:OldProfile and $script:NewProfile.

# Settings files and scripts whose paths are rewritten once they are restored.
# Logs, histories and binary data (databases, images) keep their exact bytes.
$script:PathFixFiles = '(?i)(\.(jsonc?|json5|xml|config|ini|cfg|conf|toml|ya?ml|properties|prefs|vbox|lnk|url|ps1|psm1|psd1|bat|cmd|vbs|sh|pyw?|pth|m?js|cjs|ahk|env|md|code-workspace|settings|plist|desktop|vdf|acf)|\.(xml|vbox)-prev|\\\.[^\\.]+|\\(Caddyfile|config|credentials))$'
$script:PathFixSkip  = '(?i)\\(node_modules|site-packages|__pycache__|\.git)\\'
$script:PathFixCount = 0
$script:Latin1       = [Text.Encoding]::GetEncoding(28591)

# How the old profile folder appears inside text, and what replaces it. Matches
# the ways programs write a path - C:\Users\Plex, C:\\Users\\Plex (JSON, .reg),
# C:/Users/Plex and file:///C:/Users/Plex (Qt, Electron), C:\/Users\/Plex,
# /c/Users/Plex (Git Bash), /mnt/c/Users/Plex (WSL) - but never C:\Users\Plex2
# or C:\Users\Plex.old, which are other folders. RxBytes is the same for raw file
# bytes read as Latin-1, where a name outside ASCII shows up as its UTF-8 bytes.
function Get-KitRename {
  if (-not $script:OldProfile -or -not $script:NewProfile -or $script:OldProfile -eq $script:NewProfile) { return $null }
  $key = $script:OldProfile + '>' + $script:NewProfile
  if ($script:KitRename -and $script:KitRename.Key -ceq $key) { return $script:KitRename }
  $old = @($script:OldProfile.TrimEnd('\') -split '\\')
  $new = @($script:NewProfile.TrimEnd('\') -split '\\')
  if ($old[0] -notmatch '^[A-Za-z]:$' -or $new[0] -notmatch '^[A-Za-z]:$' -or $old.Count -lt 2 -or $new.Count -lt 2) { return $null }
  $asBytes = { param([string[]]$Parts) @($Parts | ForEach-Object { $script:Latin1.GetString([Text.Encoding]::UTF8.GetBytes($_)) }) }
  $build = {
    param([string[]]$Parts)
    $d = [regex]::Escape($Parts[0].Substring(0, 1))
    $rest = @($Parts | Select-Object -Skip 1 | ForEach-Object { [regex]::Escape($_) }) -join '\k<sep>'
    New-Object Text.RegularExpressions.Regex (('(?<![A-Za-z0-9])(?<pre>{0}:|/mnt/{0}|/{0})(?<sep>\\\\\\\\|\\\\|\\/|\\|/){1}(?![A-Za-z0-9._-])' -f $d, $rest),
      ([Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'))
  }
  $oldB = & $asBytes $old
  $newB = & $asBytes $new
  $script:KitRename = [pscustomobject]@{
    Key = $key; Rx = (& $build $old); RxBytes = (& $build $oldB)
    # same parent folder (C:\Users): only the last part changes, everything before keeps its spelling
    SameParent = ((@($old | Select-Object -SkipLast 1) -join '\') -eq (@($new | Select-Object -SkipLast 1) -join '\'))
    OldLeaf = $old[-1]; OldLeafBytes = $oldB[-1]; NewLeaf = $new[-1]; NewLeafBytes = $newB[-1]
    NewLetter = $new[0].Substring(0, 1); NewRest = @($new | Select-Object -Skip 1); NewRestBytes = @($newB | Select-Object -Skip 1)
  }
  return $script:KitRename
}

# Rewrites C:\Users\<old name>\... to the current profile when the user name
# changed, keeping the slashes and spelling the text used. -Bytes: the text is
# raw file bytes read as Latin-1 (see Update-KitTextFile).
function Convert-KitPath([string]$Text, [switch]$Bytes) {
  $r = Get-KitRename
  if (-not $Text -or -not $r) { return $Text }
  $rx = if ($Bytes) { $r.RxBytes } else { $r.Rx }
  $ms = $rx.Matches($Text)
  if (-not $ms.Count) { return $Text }
  $sb = New-Object Text.StringBuilder
  $at = 0
  foreach ($m in $ms) {
    [void]$sb.Append($Text, $at, $m.Index - $at)
    if ($r.SameParent) {
      $oldLeaf = if ($Bytes) { $r.OldLeafBytes } else { $r.OldLeaf }
      [void]$sb.Append($m.Value, 0, $m.Length - $oldLeaf.Length).Append($(if ($Bytes) { $r.NewLeafBytes } else { $r.NewLeaf }))
    } else {
      $sep = $m.Groups['sep'].Value
      $pre = $m.Groups['pre'].Value
      if ($pre.EndsWith(':')) { $pre = $r.NewLetter + ':' } elseif ($pre.StartsWith('/mnt/')) { $pre = '/mnt/' + $r.NewLetter.ToLower() } else { $pre = '/' + $r.NewLetter.ToLower() }
      [void]$sb.Append($pre + $sep + (@($(if ($Bytes) { $r.NewRestBytes } else { $r.NewRest })) -join $sep))
    }
    $at = $m.Index + $m.Length
  }
  [void]$sb.Append($Text, $at, $Text.Length - $at)
  return $sb.ToString()
}

# The old account as Windows writes it (PC\Plex, .\Plex, Plex or its SID) -> the account running RESTORE.
function Convert-KitAccount([string]$Value) {
  $s = $script:M.System
  if (-not $Value -or -not $s -or -not $s.UserName) { return $Value }
  if ($s.UserSid -and $Value -eq $s.UserSid) { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
  $old = @(('{0}\{1}' -f $s.UserDomain, $s.UserName), ('{0}\{1}' -f $s.ComputerName, $s.UserName), ('.\' + $s.UserName), [string]$s.UserName)
  if ($old -contains $Value) { return ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) }
  return $Value
}

# Task names some apps make per user: "Hard Disk Sentinel_Plex" (user name) or "...-S-1-5-21-...-1000" (SID).
function Convert-KitTaskName([string]$Name) {
  $s = $script:M.System
  if (-not $Name -or -not $s -or -not $s.UserName) { return $Name }
  if ($s.UserSid) { $Name = $Name.Replace([string]$s.UserSid, [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
  if ($s.UserName -ne $env:USERNAME) { $Name = [regex]::Replace($Name, '_' + [regex]::Escape([string]$s.UserName) + '$', ('_' + $env:USERNAME).Replace('$', '$$'), 'IgnoreCase') }
  return $Name
}

# A .reg export for the renamed account: paths in plain strings (C:\\Users\\Plex,
# C:/Users/Plex), in key and value names, and in hex-encoded strings - REG_EXPAND_SZ,
# REG_MULTI_SZ and binary values that hold nothing but a path (NVIDIA's video
# folder). Other binary data (Qt settings, taskbar pins) keeps its exact bytes.
function Convert-KitRegText([string]$Text) {
  if (-not $Text -or -not (Get-KitRename)) { return $Text }
  $Text = Convert-KitPath $Text
  $ms = [regex]::Matches($Text, '(?m)^(?<head>(?:@|"(?:[^"\\\r\n]|\\.)*")=hex(?:\((?<t>[0-9a-fA-F]+)\))?:)(?<data>[0-9a-fA-F]{2}(?:,(?:\\\r?\n[ \t]*)?[0-9a-fA-F]{2})*)')
  $sb = New-Object Text.StringBuilder
  $at = 0
  foreach ($m in $ms) {
    $hex = $m.Groups['data'].Value -replace '[^0-9a-fA-F]', ''
    # only values that can hold "Users" (UTF-16 or ANSI, any case) are decoded
    if ($hex -notmatch '(?i)7300650072007300|5300450052005300|73657273|53455253') { continue }
    $bytes = New-Object byte[] ($hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    $type = $m.Groups['t'].Value.ToLower()   # '' binary, 1 string, 2 expandable string, 7 multi-string
    $u = $null
    if ($bytes.Length % 2 -eq 0) { $u = [Text.Encoding]::Unicode.GetString($bytes) }
    $newBytes = $null
    if ($null -ne $u -and ($type -in '1', '2', '7' -or ($type -eq '' -and $u.TrimEnd([char]0) -notmatch '[\x00-\x1f]'))) {
      $c = Convert-KitPath $u
      if ($c -cne $u) { $newBytes = [Text.Encoding]::Unicode.GetBytes($c) }
    }
    if (-not $newBytes -and $type -eq '') {
      $a = $script:Latin1.GetString($bytes)
      if ($a.TrimEnd([char]0) -notmatch '[\x00-\x1f]') { $c = Convert-KitPath $a -Bytes; if ($c -cne $a) { $newBytes = $script:Latin1.GetBytes($c) } }
    }
    if (-not $newBytes) { continue }
    $lines = for ($i = 0; $i -lt $newBytes.Length; $i += 25) { [BitConverter]::ToString($newBytes, $i, [Math]::Min(25, $newBytes.Length - $i)).Replace('-', ',').ToLower() }
    [void]$sb.Append($Text, $at, $m.Index - $at).Append($m.Groups['head'].Value).Append(($lines -join ",\`r`n  "))
    $at = $m.Index + $m.Length
  }
  [void]$sb.Append($Text, $at, $Text.Length - $at)
  return $sb.ToString()
}

# Keeps the first version of a file that is changed in place outside the backup
# (a script on D:), e.g. D:\Caddy\x.ps1 -> <Dir>\D\Caddy\x.ps1.
function Save-KitOriginal([string]$Path, [string]$Dir) {
  if (-not $Dir -or $DryRun) { return }
  $to = Join-Path $Dir ($Path.Substring(0, 1) + $Path.Substring(2))
  if (Test-Path -LiteralPath $to) { return }
  New-Dir (Split-Path $to -Parent) | Out-Null
  Copy-Item -LiteralPath $Path -Destination $to -Force
}

# Rewrites the old profile folder inside one settings file or script and keeps
# its encoding byte for byte: UTF-8/ANSI text is handled as Latin-1 (one
# character per byte, so every other byte stays exactly as it was) and UTF-16
# text (with its BOM) as UTF-16. Anything else with zero bytes is binary data
# and is left alone.
function Update-KitTextFile([string]$Path, [string]$KeepOriginalIn) {
  try {
    $fi = New-Object IO.FileInfo($Path)
    if (-not $fi.Exists -or $fi.Length -lt 4 -or $fi.Length -gt 16MB) { return $false }
    $bytes = [IO.File]::ReadAllBytes($Path)
  } catch { return $false }
  $raw = -not ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
  if (-not $raw -and $bytes.Length % 2) { return $false }
  $enc = if ($raw) { $script:Latin1 } else { [Text.Encoding]::Unicode }
  $text = $enc.GetString($bytes)
  if ($raw -and $text.IndexOf([char]0) -ge 0) { return $false }
  $new = Convert-KitPath $text -Bytes:$raw
  if ($new -ceq $text) { return $false }
  if ($DryRun) { return $true }
  try {
    Save-KitOriginal $Path $KeepOriginalIn
    $ro = $fi.IsReadOnly
    if ($ro) { $fi.IsReadOnly = $false }
    [IO.File]::WriteAllBytes($Path, $enc.GetBytes($new))
    if ($ro) { $fi.IsReadOnly = $true }
    return $true
  } catch { Say-Warn ('Could not change {0} to {1} inside {2}: {3}' -f $script:OldProfile, $script:NewProfile, $Path, $_.Exception.Message); return $false }
}

# Points a shortcut (.lnk) that leads into the old profile at the same place in the new one.
function Update-KitShortcut([string]$Path, [string]$KeepOriginalIn) {
  try {
    if (-not $script:WshShell) { $script:WshShell = New-Object -ComObject WScript.Shell }
    $l = $script:WshShell.CreateShortcut($Path)
    $changed = $false
    foreach ($p in 'TargetPath', 'Arguments', 'WorkingDirectory', 'IconLocation') {
      $v = [string]$l.$p
      $n = Convert-KitPath $v
      if ($n -cne $v) { $l.$p = $n; $changed = $true }
    }
    if ($changed -and -not $DryRun) { Save-KitOriginal $Path $KeepOriginalIn; $l.Save() }
    return $changed
  } catch { Say-Warn ('Could not point the shortcut {0} at {1}: {2}' -f $Path, $script:NewProfile, $_.Exception.Message); return $false }
}

# Rewrites the old profile folder inside these files (settings, scripts,
# shortcuts) and says how many changed. Each one is listed in the log.
function Update-KitFilePaths([string[]]$Files, [string]$Label, [string]$KeepOriginalIn) {
  if (-not (Get-KitRename)) { return 0 }
  $todo = @($Files | Where-Object { $_ -and $_ -match $script:PathFixFiles -and $_ -notmatch $script:PathFixSkip })
  $activity = 'Changing {0} to {1} inside restored files' -f $script:OldProfile, $script:NewProfile
  $n = 0; $i = 0
  foreach ($f in $todo) {
    $i++
    if ($i % 250 -eq 0) { Show-KitProgress $activity $Label ([int](100 * $i / $todo.Count)) }
    $ok = if ($f -match '(?i)\.lnk$') { Update-KitShortcut $f $KeepOriginalIn } else { Update-KitTextFile $f $KeepOriginalIn }
    if (-not $ok) { continue }
    $n++
    if ($DryRun) { Say ('  [dry-run] {0} -> {1} inside {2}' -f $script:OldProfile, $script:NewProfile, $f) 'DarkGray' }
    else { Write-KitLog ('{0} -> {1} inside {2}' -f $script:OldProfile, $script:NewProfile, $f) }
  }
  if ($todo.Count -ge 250) { Show-KitProgress $activity $Label -Completed }
  if ($n -and -not $DryRun) { Say-Ok ('{0}: {1} -> {2} inside {3} file(s)' -f $Label, $script:OldProfile, $script:NewProfile, $n) }
  $script:PathFixCount += $n
  return $n
}

# After Invoke-KitCopy -Collect: rewrites the old profile inside the files it just copied.
function Update-KitCopiedFiles($Result) {
  if (-not $Result -or -not $Result.CopiedFiles -or -not $Result.CopiedFiles.Count) { return }
  $src = $Result.Source.TrimEnd('\') + '\'
  $dst = $Result.Destination.TrimEnd('\') + '\'
  $files = @(foreach ($p in $Result.CopiedFiles) { if ($p.StartsWith($src, [StringComparison]::OrdinalIgnoreCase)) { $dst + $p.Substring($src.Length) } })
  [void](Update-KitFilePaths $files $Result.Label)
}

# The scripts your scheduled tasks and startup items run (D:\Caddy\watchdog.ps1,
# a Python venv on D:) and the settings files next to them live outside the
# backup, so the old profile inside them is rewritten where they are. The first
# version of every file changed this way is kept in ProgramData\PCMigrationKit.
function Update-KitAutomationScripts([string[]]$CommandLines, [string]$Label) {
  if (-not (Get-KitRename)) { return }
  $dirs = New-Object System.Collections.Generic.List[string]
  foreach ($c in $CommandLines) {
    foreach ($m in [regex]::Matches([string]$c, '"([A-Za-z]:\\[^"]+)"|(?<!\S)([A-Za-z]:\\[^\s"]+)')) {
      $p = Convert-KitPath ($m.Groups[1].Value + $m.Groups[2].Value)
      if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
      $d = Split-Path $p -Parent
      if ($d -match '(?i)^[A-Z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData\\Microsoft)(\\|$)') { continue }
      # a Python venv keeps its settings (pyvenv.cfg) one level above Scripts\
      if ((Split-Path $d -Leaf) -eq 'Scripts' -and (Test-Path -LiteralPath (Join-Path (Split-Path $d -Parent) 'pyvenv.cfg'))) { $d = Split-Path $d -Parent }
      if (-not $dirs.Contains($d)) { $dirs.Add($d) }
    }
  }
  $files = @(foreach ($d in $dirs) { Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 4MB } | ForEach-Object { $_.FullName } })
  [void](Update-KitFilePaths $files $Label (Join-Path $env:ProgramData 'PCMigrationKit\before-user-rename'))
}

# Registers a scheduled task from the XML saved by BACKUP. The old account (its
# SID and PC\user name, also in the task's name and author) is swapped for the
# current one; a task that stored a password is switched to "run only when
# signed in", because the password was not saved.
function Register-KitTaskFromBackup($Task, [string]$XmlPath, [string]$OldExe, [string]$NewExe) {
  $name = Convert-KitTaskName $Task.Name
  $path = $Task.Path
  $full = $path + $name
  $xml = New-Object Xml.XmlDocument
  $xml.LoadXml([IO.File]::ReadAllText($XmlPath, [Text.Encoding]::Unicode))
  $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
  foreach ($node in @($xml.SelectNodes('//t:UserId | //t:RegistrationInfo/t:Author', $ns))) { $node.InnerText = Convert-KitAccount $node.InnerText }
  foreach ($node in @($xml.SelectNodes('//t:RegistrationInfo/t:URI', $ns))) { $node.InnerText = $full }
  foreach ($lt in @($xml.SelectNodes('//t:Principal/t:LogonType', $ns))) {
    if ($lt.InnerText -eq 'Password') {
      $lt.InnerText = 'InteractiveToken'
      $note = 'Task "{0}" used to run even when signed out - re-enter your password in Task Scheduler to get that back' -f $full
      if (Get-Command Add-Missing -ErrorAction SilentlyContinue) { Add-Missing $note } else { Say-Warn $note }
    }
  }
  foreach ($node in @($xml.SelectNodes('//t:Exec/t:Command | //t:Exec/t:Arguments | //t:Exec/t:WorkingDirectory', $ns))) { $node.InnerText = Convert-KitPath $node.InnerText }
  # the program moved with its reinstall (Program Files (x86) -> Program Files, a new version folder)
  if ($OldExe -and $NewExe) { foreach ($node in @($xml.SelectNodes('//t:Exec/t:Command', $ns))) { $node.InnerText = Update-KitCommandExe $node.InnerText $OldExe $NewExe } }
  $xmlText = $xml.OuterXml
  return (Invoke-Change "Recreate scheduled task $full" { Register-ScheduledTask -Xml $xmlText -TaskName $name -TaskPath $path | Out-Null })
}

function Export-RegKey([string]$Key, [string]$File) {
  New-Dir (Split-Path $File -Parent) | Out-Null
  $null = & reg.exe export $Key $File /y 2>&1
  return ($LASTEXITCODE -eq 0)
}

function Select-Folder([string]$Description) {
  Add-Type -AssemblyName System.Windows.Forms
  $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = $Description
  $dlg.ShowNewFolderButton = $true
  $result = $dlg.ShowDialog($owner)
  $owner.Dispose()
  if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
  return $null
}

# ------------------------------------------------------------- robocopy -----
function ConvertTo-RoboArg([string]$Path) {
  # A quoted path must not end in "\" (robocopy reads \" as an escaped quote).
  $p = $Path.TrimEnd('\')
  if ($p -match '^[A-Za-z]:$') { $p += '\.' }
  return '"' + $p + '"'
}

# Size + file count of a folder tree without copying (robocopy /L is far faster
# than Get-ChildItem on big profiles). The summary labels are localized, so the
# numbers are picked by position: rows are Dirs, Files, Bytes.
function Measure-Tree([string]$Path, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @()) {
  $r = [pscustomobject]@{ Bytes = 0.0; Files = 0 }
  if (-not (Test-Path -LiteralPath $Path)) { return $r }
  $argList = @((ConvertTo-RoboArg $Path), '"C:\__pcmk_nowhere__"', '/L', '/E', '/XJ', '/NJH', '/BYTES', '/NFL', '/NDL', '/NC', '/NP', '/R:0', '/W:0')
  if ($ExcludeDirs.Count)  { $argList += '/XD'; $argList += ($ExcludeDirs  | ForEach-Object { ConvertTo-RoboArg $_ }) }
  if ($ExcludeFiles.Count) { $argList += '/XF'; $argList += ($ExcludeFiles | ForEach-Object { '"' + $_ + '"' }) }
  $out = & cmd.exe /c ("robocopy " + ($argList -join ' ')) 2>$null
  $rows = @($out | Where-Object { $_ -match '^\s*[^\d\s].*:\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s*$' })
  if ($rows.Count -ge 3) {
    $r.Files = [int64](($rows[1] -split ':')[-1].Trim() -split '\s+')[0]
    $r.Bytes = [double](($rows[2] -split ':')[-1].Trim() -split '\s+')[0]
  }
  return $r
}

# Reads whatever robocopy appended to its UTF-16 log since the last call.
function Read-LogTail([string]$Path, [ref]$Offset, [ref]$Carry) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $fs = $null
  try {
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    if ($fs.Length -le $Offset.Value) { return @() }
    [void]$fs.Seek($Offset.Value, [IO.SeekOrigin]::Begin)
    $want = [int][Math]::Min($fs.Length - $Offset.Value, 16MB)
    $want -= ($want % 2)
    if ($want -le 0) { return @() }
    $buf = New-Object byte[] $want
    $read = $fs.Read($buf, 0, $want)
    $read -= ($read % 2)
    $Offset.Value += $read
    $text = $Carry.Value + [Text.Encoding]::Unicode.GetString($buf, 0, $read)
    $text = $text.TrimStart([char]0xFEFF)
    $lines = $text -split "`r?`n"
    $Carry.Value = $lines[-1]
    if ($lines.Count -gt 1) { return $lines[0..($lines.Count - 2)] }
    return @()
  } catch { return @() } finally { if ($fs) { $fs.Dispose() } }
}

# Copies a folder tree with robocopy and shows a progress bar by following the
# robocopy log. Never deletes anything at the destination (no /MIR, no /PURGE).
# -Collect: the source paths of copied files that match this regex end up in
# CopiedFiles (for Update-KitCopiedFiles).
function Invoke-KitCopy {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string[]]$ExcludeDirs = @(),
    [string[]]$ExcludeFiles = @(),
    [string]$Label = 'Copying',
    [double]$ExpectedBytes = 0,
    [switch]$BackupMode,
    [switch]$SkipNewer,
    [string[]]$Files = @('*.*'),
    [switch]$NoSubdirs,
    [int]$Threads = 8,
    [string]$Collect,
    [switch]$MergeOnly
  )
  $res = [pscustomobject]@{ Label = $Label; Source = $Source; Destination = $Destination; ExitCode = -1; Ok = $false; Bytes = 0.0; Files = 0; Errors = 0; Sockets = 0; Log = $null; Skipped = $false; CopiedFiles = $null }
  if (-not (Test-Path -LiteralPath $Source)) { $res.Skipped = $true; $res.Ok = $true; return $res }
  Send-KitEvent @{ t = 'copy'; state = 'start'; label = $Label; source = $Source; dest = $Destination; expected = $ExpectedBytes }
  New-Dir $Destination | Out-Null

  $logDir = $script:LogDir
  if (-not $logDir) { $logDir = New-Dir (Join-Path $env:TEMP 'pcmk-logs') }
  $rlog = Join-Path $logDir ('robocopy-{0}-{1}-{2}.log' -f (Get-SafeName $Label).Replace(' ', '_'), (Get-Date -Format 'HHmmss'), (Get-Random -Maximum 9999))
  $res.Log = $rlog

  $argList = @((ConvertTo-RoboArg $Source), (ConvertTo-RoboArg $Destination)) + @($Files | ForEach-Object { '"' + $_ + '"' })
  if (-not $NoSubdirs) { $argList += '/E' }
  # /UNILOG (not /UNILOG+, which writes 8-bit text to a new file) keeps Cyrillic names intact
  $argList += @('/COPY:DAT', '/DCOPY:DAT', '/XJ', '/XX', '/R:1', '/W:1', "/MT:$Threads", '/NDL', '/NJH', '/NP', '/BYTES', '/FP', ('/UNILOG:' + (ConvertTo-RoboArg $rlog)))
  if ($BackupMode) { $argList += '/B' }
  if ($SkipNewer)  { $argList += '/XO' }
  # only what is not there yet - files that exist at the destination are never touched
  if ($MergeOnly)  { $argList += @('/XC', '/XN', '/XO') }
  if ($ExcludeDirs.Count)  { $argList += '/XD'; $argList += ($ExcludeDirs  | ForEach-Object { ConvertTo-RoboArg $_ }) }
  if ($ExcludeFiles.Count) { $argList += '/XF'; $argList += ($ExcludeFiles | ForEach-Object { '"' + $_ + '"' }) }
  Write-KitLog ('robocopy ' + ($argList -join ' '))

  # output is captured (and ignored): robocopy still echoes a "Log File :" line
  $h = Start-NativeProcess "$env:SystemRoot\System32\robocopy.exe" ($argList -join ' ')
  $p = $h.Process

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $offset = 0L; $carry = ''; $current = ''
  $rxFile = [regex]'\s(\d+)\s+((?:[A-Za-z]:\\|\\\\).+)$'
  $rxErr  = [regex]'\s\d+\s\(0x([0-9A-Fa-f]{8})\)\s.*?((?:[A-Za-z]:\\|\\\\).+)$'
  $failed = New-Object 'System.Collections.Generic.HashSet[string]'
  $sockets = New-Object 'System.Collections.Generic.HashSet[string]'
  $rxCollect = $null
  if ($Collect) { $rxCollect = New-Object Text.RegularExpressions.Regex($Collect); $res.CopiedFiles = New-Object System.Collections.Generic.List[string] }
  $expected = ''
  if ($ExpectedBytes -gt 0) { $expected = ' of ~' + (Format-Bytes $ExpectedBytes) }

  # Error lines repeat once per retry, hence the sets. Code 0 ("completed
  # successfully") is what robocopy reports for AF_UNIX socket files such as
  # Docker's *.sock - runtime handles, never data - so they are counted apart.
  $processLines = {
    param($lines)
    foreach ($ln in $lines) {
      $e = $rxErr.Match($ln)
      if ($e.Success) {
        if ($e.Groups[1].Value -eq '00000000') { [void]$sockets.Add($e.Groups[2].Value) } else { [void]$failed.Add($e.Groups[2].Value) }
        continue
      }
      $m = $rxFile.Match($ln)
      if ($m.Success) {
        $res.Bytes += [double]$m.Groups[1].Value
        $res.Files++
        $current = $m.Groups[2].Value
        if ($rxCollect -and $rxCollect.IsMatch($current)) { $res.CopiedFiles.Add($current) }
      }
    }
  }

  while (-not $p.HasExited) {
    Start-Sleep -Milliseconds 800
    $lines = Read-LogTail $rlog ([ref]$offset) ([ref]$carry)
    . $processLines $lines
    $pct = -1
    if ($ExpectedBytes -gt 0) { $pct = [int][Math]::Min(99, ($res.Bytes / $ExpectedBytes) * 100) }
    $shown = $current
    if ($shown.Length -gt 70 -and -not $script:Gui) { $shown = '...' + $shown.Substring($shown.Length - 67) }
    $status = '{0}{1}  |  {2:N0} files  |  {3:hh\:mm\:ss}' -f (Format-Bytes $res.Bytes), $expected, $res.Files, $sw.Elapsed
    Show-KitProgress $Label $status $pct $shown -Extra @{ kind = 'copy'; bytes = $res.Bytes; expected = $ExpectedBytes; files = $res.Files; secs = [int]$sw.Elapsed.TotalSeconds }
  }
  $p.WaitForExit()
  . $processLines (Read-LogTail $rlog ([ref]$offset) ([ref]$carry))
  if ($carry) { . $processLines @($carry) }
  Show-KitProgress $Label '' -Completed -Extra @{ kind = 'copy'; bytes = $res.Bytes; expected = $ExpectedBytes; files = $res.Files; secs = [int]$sw.Elapsed.TotalSeconds }

  $res.ExitCode = $p.ExitCode
  $res.Errors = $failed.Count
  $res.Sockets = $sockets.Count
  # exit codes 8-15 mean "some files failed"; if the only failures were sockets, it's a clean copy
  $res.Ok = ($res.ExitCode -ge 0 -and $res.ExitCode -lt 8) -or ($res.ExitCode -ge 8 -and $res.ExitCode -lt 16 -and $res.Errors -eq 0)
  Write-KitLog ('robocopy exit {0}: {1} files, {2}, {3} errors, {4} sockets skipped ({5})' -f $res.ExitCode, $res.Files, (Format-Bytes $res.Bytes), $res.Errors, $res.Sockets, $Label)
  Send-KitEvent @{ t = 'copy'; state = 'end'; label = $Label; files = $res.Files; bytes = $res.Bytes; errors = $res.Errors; exit = $res.ExitCode; ok = $res.Ok; log = $rlog }
  return $res
}

function Write-CopyResult($Result) {
  if ($Result.Skipped) { Say-Info ('{0}: nothing there, skipped' -f $Result.Label); return }
  if ($Result.ExitCode -eq 0) { Say-Ok ('{0}: nothing new to copy' -f $Result.Label); return }
  $msg = '{0}: {1:N0} files, {2}' -f $Result.Label, $Result.Files, (Format-Bytes $Result.Bytes)
  if ($Result.Sockets -gt 0) { $msg += ' ({0} live socket file(s) skipped - not data)' -f $Result.Sockets }
  if ($Result.ExitCode -ge 16) { Say-Fail ('{0} - robocopy could not run (code {1}). Log: {2}' -f $Result.Label, $Result.ExitCode, $Result.Log) }
  elseif (-not $Result.Ok -or $Result.Errors -gt 0) { Say-Warn ('{0} - {1} file(s) could not be copied (usually locked or in use). Log: {2}' -f $msg, [Math]::Max(1, $Result.Errors), $Result.Log) }
  else { Say-Ok $msg }
}
