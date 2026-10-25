. "$PSScriptRoot/common.ps1"
$dotnetExe = Find-Dotnet
$msys = Find-MsysRoot
if (-not $msys) { throw 'Run setup.ps1 first.' }
$env:viewMirror_MSYS2_ROOT = $msys
$env:Path = "$PSHOME;$(Split-Path -Parent $dotnetExe);$msys/ucrt64/bin;$msys/usr/bin;$(Join-Path $ProjectRoot '.tools/vscode/bin');$env:Path"
Write-Host 'Tools added to this PowerShell session only. Use build.ps1/verify.ps1 to isolate native library discovery.'
