[CmdletBinding()]
param([switch]$Refresh)
. "$PSScriptRoot/common.ps1"
$msys = Find-MsysRoot
if (-not $msys) { throw 'MSYS2 not found.' }
$versions = Join-Path $ProjectRoot 'docs/versions'
New-Item -ItemType Directory -Path $versions -Force | Out-Null
$packageLock = Join-Path $versions 'windows-msys2-packages.lock'
if ((Test-Path -LiteralPath $packageLock) -and -not $Refresh) { throw 'Snapshot already exists. Use -Refresh only for an intentional dependency update.' }
$archives = Join-Path $ProjectRoot '.tools/msys2-package-cache'
New-Item -ItemType Directory -Path $archives -Force | Out-Null
& (Join-Path $msys 'usr/bin/pacman.exe') -Q | Set-Content -LiteralPath $packageLock -Encoding utf8
Assert-NativeExit 'Record MSYS2 versions'
$items = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $msys 'var/cache/pacman/pkg') -Filter '*.pkg.tar.zst') {
    Copy-Item -LiteralPath $file.FullName -Destination $archives
    $repo = if ($file.Name.StartsWith('mingw-w64-ucrt-')) { 'mingw/ucrt64' } else { 'msys/x86_64' }
    [ordered]@{file=$file.Name;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();url="https://repo.msys2.org/$repo/$($file.Name)"}
}
@{base='msys2-base.lock.json';archives=@($items);created=(Get-Date -Format o)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $versions 'msys2-archives.lock.json') -Encoding utf8
Write-Host "Frozen $(@($items).Count) archives plus the pinned MSYS2 base. Keep .tools/msys2-package-cache for offline reconstruction."
