[CmdletBinding()]
param(
    [string]$MsysRoot,
    [switch]$UpdateExistingMsys,
    [switch]$InstallVSCode
)
. "$PSScriptRoot/common.ps1"
if ($env:OS -ne 'Windows_NT' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Windows x64 with a 64-bit PowerShell is required.' }
$ProgressPreference = 'SilentlyContinue'
$originalPath = $env:Path
Start-Transcript -Path (Join-Path $LogDir 'setup-windows.txt') -Append
try {
    $existingMsys = Find-MsysRoot
    if (-not $MsysRoot) { $MsysRoot = $existingMsys }
    if (-not $MsysRoot) { $MsysRoot = Join-Path $ProjectRoot '.tools/msys64' }
    $MsysRoot = [IO.Path]::GetFullPath($MsysRoot)
    if ($MsysRoot -match '[^\x00-\x7f]|\s') { throw 'MSYS2 root must be an ASCII path without spaces. Supply -MsysRoot.' }
    $newMsys = -not (Test-Path -LiteralPath (Join-Path $MsysRoot 'usr/bin/bash.exe'))
    $cache = Join-Path $ProjectRoot '.tools/downloads'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    if ($newMsys) {
        if (Test-Path -LiteralPath $MsysRoot) { throw "Refusing to overwrite existing directory: $MsysRoot" }
        $baseLock = Join-Path $ProjectRoot 'msys2-base.lock.json'
        if (Test-Path -LiteralPath $baseLock) {
            $asset = Get-Content -LiteralPath $baseLock -Raw | ConvertFrom-Json
        } else {
            $releases = Invoke-RestMethod 'https://api.github.com/repos/msys2/msys2-installer/releases?per_page=20'
            $release = $releases | Where-Object { $_.tag_name -notmatch 'nightly' -and -not $_.prerelease } | Select-Object -First 1
            if (-not $release) { throw 'No stable MSYS2 release found.' }
            $download = $release.assets | Where-Object { $_.name -match '^msys2-base-x86_64-.*\.sfx\.exe$' } | Select-Object -First 1
            if (-not $download) { throw 'No MSYS2 x64 base archive found.' }
            $sha = if ($download.digest) { $download.digest -replace '^sha256:','' } else { ((Invoke-WebRequest ($download.browser_download_url + '.sha256')).Content.Trim() -split '\s+')[0] }
            $asset = [pscustomobject]@{release=$release.tag_name;name=$download.name;url=$download.browser_download_url;sha256=$sha}
            $asset | ConvertTo-Json | Set-Content -LiteralPath $baseLock -Encoding utf8
        }
        $archive = Join-Path $cache $asset.name
        if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest $asset.url -OutFile $archive -TimeoutSec 300 }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $asset.sha256) { throw "MSYS2 SHA256 mismatch: $archive. No archive executed." }
        $parent = Split-Path -Parent $MsysRoot
        if ((Split-Path -Leaf $MsysRoot) -ne 'msys64') { throw 'MSYS2 base archive requires root folder name msys64.' }
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        & $archive '-y' "-o$parent"
        Assert-NativeExit 'Extract MSYS2'
    }
    @{msysRoot=$MsysRoot} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ProjectRoot 'artifacts/windows-local.json') -Encoding utf8
    Set-MsysEnvironment $MsysRoot
    Invoke-Msys $MsysRoot 'printf "MSYSTEM=%s MINGW_PREFIX=%s\n" "$MSYSTEM" "$MINGW_PREFIX"'
    $packages = @('gcc','cmake','ninja','pkgconf','openssl','libplist','gstreamer','gst-plugins-base','gst-plugins-good','gst-plugins-bad','gst-libav','json-glib') | ForEach-Object { 'mingw-w64-ucrt-x86_64-' + $_ }
    $missing = @()
    foreach ($package in $packages) {
        & (Join-Path $MsysRoot 'usr/bin/pacman.exe') -Q $package 2>$null
        if ($LASTEXITCODE -ne 0) { $missing += $package }
    }
    $snapshotPath = Join-Path $ProjectRoot 'docs/versions/msys2-archives.lock.json'
    if ($newMsys -and (Test-Path -LiteralPath $snapshotPath)) {
        # Only a NEW installation may be restored/downgraded to the frozen snapshot.
        & "$PSScriptRoot/restore-snapshot.ps1" -MsysRoot $MsysRoot
        $missing = @()
    } elseif ($newMsys -or $UpdateExistingMsys) {
        # MSYS runtime updates can terminate the first shell. Always open a new one for phase 2.
        Invoke-Msys $MsysRoot 'pacman --noconfirm -Syu'
        Invoke-Msys $MsysRoot 'pacman --noconfirm -Syu'
    } elseif ($missing.Count -gt 0) {
        throw ('Existing MSYS2 lacks packages. Review and rerun with -UpdateExistingMsys to permit its supported full update: ' + ($missing -join ', '))
    }
    if ($missing.Count -gt 0) { Invoke-Msys $MsysRoot ('pacman --noconfirm -S --needed ' + ($packages -join ' ')) }
    Assert-PackageSnapshot $MsysRoot
    Invoke-Msys $MsysRoot 'pacman -Q > "$viewMirror_ROOT/artifacts/msys2-packages.txt"; pacman -Qqe > "$viewMirror_ROOT/artifacts/msys2-explicit.txt"'
    $env:Path = $originalPath
    $dotnet = $null
    try { $dotnet = Find-Dotnet } catch { }
    $sdk = '10.0.402'
    $sdkFound = $false
    if ($dotnet) { $sdkFound = [bool]((& $dotnet --list-sdks) -match "^$([regex]::Escape($sdk)) ") }
    if (-not $sdkFound) {
        Write-Host "Installing isolated .NET SDK $sdk under .tools/dotnet (no administrator rights)."
        $installer = Join-Path $cache 'dotnet-install.ps1'
        Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
        & $installer -Version $sdk -Architecture x64 -InstallDir (Join-Path $ProjectRoot '.tools/dotnet') -NoPath
        if (-not $?) { throw '.NET SDK installation failed.' }
        $dotnet = Find-Dotnet
    }
    & $dotnet --list-sdks
    Assert-NativeExit '.NET SDK detection'
    Assert-UxPlaySourceSnapshot
    if ($InstallVSCode) {
        $code = Get-Command code -ErrorAction SilentlyContinue
        $codePaths = @("$env:LOCALAPPDATA/Programs/Microsoft VS Code/Code.exe","$env:ProgramFiles/Microsoft VS Code/Code.exe",(Join-Path $ProjectRoot '.tools/vscode/Code.exe'))
        if (-not $code -and -not ($codePaths | Where-Object { Test-Path -LiteralPath $_ })) {
            $codeArchive = Join-Path $cache 'vscode-win32-x64.zip'
            $metadata = Invoke-RestMethod 'https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest'
            $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ProjectRoot 'artifacts/vscode-download.json')
            Invoke-WebRequest $metadata.url -OutFile $codeArchive -TimeoutSec 300
            if ($metadata.sha256hash -and (Get-FileHash -LiteralPath $codeArchive -Algorithm SHA256).Hash -ne $metadata.sha256hash) { throw 'VS Code SHA256 mismatch.' }
            Expand-Archive -LiteralPath $codeArchive -DestinationPath (Join-Path $ProjectRoot '.tools/vscode')
            New-Item -ItemType Directory -Path (Join-Path $ProjectRoot '.tools/vscode/data') -Force | Out-Null
        } else { Write-Host 'Existing VS Code reused.' }
    }
    Write-Host 'Setup complete. Run scripts/windows/build.ps1, then verify.ps1.'
} finally { $env:Path = $originalPath; Stop-Transcript }
