[CmdletBinding()]
param([Parameter(Mandatory)][string]$MsysRoot)
. "$PSScriptRoot/common.ps1"
# Called only by setup.ps1 after extracting a NEW pinned base. Never downgrade a shared environment.
$packages = & (Join-Path $MsysRoot 'usr/bin/pacman.exe') -Q
if ($packages -match '^mingw-w64-') { throw 'Snapshot restore requires a new MSYS2 base without MinGW packages. Existing environment preserved.' }
$manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'docs/versions/msys2-archives.lock.json') -Raw | ConvertFrom-Json
$cache = Join-Path $ProjectRoot '.tools/msys2-package-cache'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
foreach ($entry in $manifest.archives) {
    $file = Join-Path $cache $entry.file
    if (-not (Test-Path -LiteralPath $file)) { Invoke-WebRequest $entry.url -OutFile $file -TimeoutSec 300 }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.sha256) { throw "Snapshot SHA256 mismatch: $file" }
}
Set-MsysEnvironment $MsysRoot
Invoke-Msys $MsysRoot 'set -euo pipefail; shopt -s nullglob; files=("$viewMirror_ROOT"/.tools/msys2-package-cache/*.pkg.tar.zst); base=(); for f in "${files[@]}"; do case "${f##*/}" in mingw-w64-*) ;; *) base+=("$f");; esac; done; if ((${#base[@]})); then pacman --noconfirm -U "${base[@]}"; fi'
Invoke-Msys $MsysRoot 'set -euo pipefail; shopt -s nullglob; files=("$viewMirror_ROOT"/.tools/msys2-package-cache/mingw-w64-ucrt-*.pkg.tar.zst); pacman --noconfirm -U "${files[@]}"'
Assert-PackageSnapshot $MsysRoot
