Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:LogDir = Join-Path $script:ProjectRoot 'artifacts/logs'
New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
function Assert-NativeExit([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit $LASTEXITCODE). See artifacts/logs." }
}
function Find-MsysRoot {
    $candidates = @($env:viewMirror_MSYS2_ROOT)
    $local = Join-Path $script:ProjectRoot 'artifacts/windows-local.json'
    if (Test-Path -LiteralPath $local) { $candidates += (Get-Content -LiteralPath $local -Raw | ConvertFrom-Json).msysRoot }
    $candidates += @('C:/msys64',"$env:USERPROFILE/msys64",(Join-Path $script:ProjectRoot '.tools/msys64'))
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'usr/bin/bash.exe'))) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}
function Get-FileSha256([string]$Path) {
    # Works in the isolated Windows PowerShell 5.1 child without module autoload.
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Set-MsysEnvironment([string]$MsysRoot,[switch]$MinimalPlugins) {
    $env:MSYSTEM = 'UCRT64'
    $env:CHERE_INVOKING = '1'
    $env:MSYS2_PATH_TYPE = 'minimal'
    $env:viewMirror_ROOT = $script:ProjectRoot.Replace('\','/')
    $env:Path = "$MsysRoot\ucrt64\bin;$MsysRoot\usr\bin;$env:SystemRoot\System32;$env:SystemRoot"
    # Restrict discovery to the selected UCRT64 installation; no MSVC/MINGW64 plugins.
    foreach ($name in @('GSTREAMER_ROOT_DIR','GSTREAMER_1_0_ROOT_MSVC_X86_64','GST_PLUGIN_PATH','GST_PLUGIN_PATH_1_0','PKG_CONFIG_PATH','CMAKE_PREFIX_PATH','CC','CXX')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    $env:PKG_CONFIG_LIBDIR = "$MsysRoot/ucrt64/lib/pkgconfig;$MsysRoot/ucrt64/share/pkgconfig"
    $env:GST_PLUGIN_SYSTEM_PATH_1_0 = "$MsysRoot/ucrt64/lib/gstreamer-1.0"
    $env:GST_PLUGIN_SCANNER_1_0 = "$MsysRoot/ucrt64/libexec/gstreamer-1.0/gst-plugin-scanner.exe"
    $env:GST_REGISTRY_1_0 = Join-Path $script:ProjectRoot 'artifacts/gstreamer-registry-windows.bin'
    $env:GST_DEBUG_NO_COLOR = '1'
    if ($MinimalPlugins) {
        $plugins = @('coreelements','app','playback','autodetect','typefindfunctions','videoparsersbad','libav','videoconvertscale','d3d11','d3d12','audioconvert','audioresample','volume','level','wasapi','videotestsrc','audiotestsrc','openh264','rtp','rtpmanager','udp','x265')
        $pluginDir = Join-Path $script:ProjectRoot 'artifacts/gstreamer-plugins-ucrt64'
        New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null
        foreach ($plugin in $plugins) {
            $filename = "libgst$plugin.dll"
            $source = Join-Path $MsysRoot "ucrt64/lib/gstreamer-1.0/$filename"
            $target = Join-Path $pluginDir $filename
            if (-not (Test-Path -LiteralPath $source)) { throw "Required UCRT64 GStreamer plugin missing: $source" }
            if (-not (Test-Path -LiteralPath $target) -or (Get-FileSha256 $source) -ne (Get-FileSha256 $target)) {
                Copy-Item -LiteralPath $source -Destination $target -Force
            }
        }
        $unexpected = @(Get-ChildItem -LiteralPath $pluginDir -File -Filter '*.dll' | Where-Object { $_.Name -notin @($plugins | ForEach-Object { "libgst$_.dll" }) })
        if ($unexpected.Count) { throw 'Unexpected plugins in the project-scoped GStreamer directory. Review its contents before starting.' }
        $env:GST_PLUGIN_SYSTEM_PATH_1_0 = $pluginDir
        $env:GST_REGISTRY_1_0 = Join-Path $script:ProjectRoot 'artifacts/gstreamer-registry-windows-minimal.bin'
    }
}
function Invoke-Msys([string]$MsysRoot,[string]$Command) {
    # A script file avoids PS 5.1 versus PS 7 native -c quote marshalling differences.
    $commandFile = Join-Path $script:ProjectRoot ('artifacts/msys-command-' + [guid]::NewGuid().ToString('N') + '.sh')
    [IO.File]::WriteAllText($commandFile, ("#!/usr/bin/env bash`nset -euo pipefail`n" + $Command.Replace("`r`n","`n") + "`n"), [Text.UTF8Encoding]::new($false))
    & (Join-Path $MsysRoot 'usr/bin/bash.exe') --login ($commandFile.Replace('\','/'))
    Assert-NativeExit $Command
}
function Find-Dotnet {
    $candidates = @((Join-Path $script:ProjectRoot '.tools/dotnet/dotnet.exe'),"$env:ProgramFiles/dotnet/dotnet.exe")
    $found = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($found) { $candidates += $found.Source }
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    throw '.NET 10 SDK not found. Run setup.ps1.'
}
function Assert-PackageSnapshot([string]$MsysRoot) {
    $lockPath = Join-Path $script:ProjectRoot 'docs/versions/windows-msys2-packages.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) { return }
    $installed = @{}
    & (Join-Path $MsysRoot 'usr/bin/pacman.exe') -Q | ForEach-Object { $name,$version = $_ -split ' ',2; $installed[$name] = $version }
    Assert-NativeExit 'Read MSYS2 package versions'
    foreach ($line in Get-Content -LiteralPath $lockPath) {
        $name,$version = $line -split ' ',2
        if (-not $installed.ContainsKey($name) -or $installed[$name] -ne $version) { throw "MSYS2 version drift: expected $line. Preserve this installation and use the frozen snapshot in a separate MSYS2 root." }
    }
}
function Assert-UxPlaySourceSnapshot {
    $source = Join-Path $script:ProjectRoot 'third_party/UxPlay'
    $manifest = Join-Path $script:ProjectRoot 'docs/versions/uxplay-source.sha256'
    if (-not (Test-Path -LiteralPath $manifest)) { throw 'Bundled UxPlay source manifest is missing. Restore the standalone project snapshot.' }
    $count = 0
    foreach ($line in Get-Content -LiteralPath $manifest) {
        if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw "Invalid source manifest entry: $line" }
        $expected = $Matches[1]
        $path = [IO.Path]::GetFullPath((Join-Path $source $Matches[2]))
        if (-not $path.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Source manifest path escapes the UxPlay directory.' }
        if (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw "UxPlay source snapshot differs: $path. Existing source was preserved." }
        $count++
    }
    if ($count -eq 0) { throw 'UxPlay source manifest is empty.' }
    Write-Host "PASS bundled UxPlay source snapshot: $count SHA-256 checks."
}
