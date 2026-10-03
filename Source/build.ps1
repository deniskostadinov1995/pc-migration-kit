<#
  Builds "PC Migration Kit.exe" (WPF on .NET Framework 4.8 - nothing to install on
  Windows 10/11) with the C# compiler that comes with Visual Studio Build Tools.
  The screens (xaml\), the engine scripts (..\Engine) and the icon are built in,
  so the exe also works on its own; next to an Engine folder it uses that one.

  .\build.ps1            build and copy to the kit folder
  .\build.ps1 -NoCopy    build only (Source\build\PCMigrationKit.exe)

  Written by Claude 2026-10-02.
#>
param([switch]$NoCopy)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$kit = Split-Path $src -Parent
$outDir = Join-Path $src 'build'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ---- the compiler: Roslyn from VS Build Tools (C# 7+), never the old in-box C# 5 one
$csc = @(
  "${env:ProgramFiles(x86)}\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe",
  "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe",
  "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\Roslyn\csc.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) { $csc = & $vswhere -latest -products * -find 'MSBuild\**\Bin\Roslyn\csc.exe' | Select-Object -First 1 }
}
if (-not $csc) { throw 'No C# compiler found - install "Visual Studio Build Tools" (winget install Microsoft.VisualStudio.2022.BuildTools).' }

$icon = Join-Path $src 'app.ico'
if (-not (Test-Path $icon)) { & (Join-Path $src 'make-icon.ps1') -Out $icon | Out-Null }

$fw = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319'
$refs = @('System.dll', 'System.Core.dll', 'System.Xml.dll', 'System.Xml.Linq.dll', 'System.Xaml.dll', 'System.Management.dll', 'System.Web.Extensions.dll',
          'System.Windows.Forms.dll', 'System.Drawing.dll', 'Microsoft.CSharp.dll', 'WPF\PresentationCore.dll', 'WPF\PresentationFramework.dll', 'WPF\WindowsBase.dll') |
        ForEach-Object { '/reference:"' + (Join-Path $fw $_) + '"' }
$res = @()
foreach ($f in Get-ChildItem (Join-Path $src 'xaml') -Filter *.xaml) { $res += ('/resource:"{0}",Xaml/{1}' -f $f.FullName, $f.Name) }
foreach ($f in Get-ChildItem (Join-Path $kit 'Engine') -Filter *.ps1) { $res += ('/resource:"{0}",Engine/{1}' -f $f.FullName, $f.Name) }
$res += ('/resource:"{0}",App/app.ico' -f $icon)
$files = @(Get-ChildItem (Join-Path $src 'src') -Filter *.cs | ForEach-Object { '"' + $_.FullName + '"' })
$out = Join-Path $outDir 'PCMigrationKit.exe'

$argList = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/langversion:latest', '/utf8output', '/warn:3', '/nowarn:1701,1702',
             ('/out:"{0}"' -f $out), ('/win32icon:"{0}"' -f $icon), ('/win32manifest:"{0}"' -f (Join-Path $src 'app.manifest'))) + $refs + $res + $files
$rsp = Join-Path $outDir 'build.rsp'
[IO.File]::WriteAllLines($rsp, $argList)
& $csc "@$rsp"
if ($LASTEXITCODE -ne 0) { throw "The compiler reported errors (exit $LASTEXITCODE)." }
"built: $out ({0:N0} KB)" -f ((Get-Item $out).Length / 1KB)
if (-not $NoCopy) {
  $dest = Join-Path $kit 'PC Migration Kit.exe'
  Copy-Item -LiteralPath $out -Destination $dest -Force
  "copied: $dest"
}
