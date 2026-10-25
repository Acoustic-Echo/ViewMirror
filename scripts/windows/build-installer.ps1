[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseDirectory,
    [string]$OutputDirectory,
    [string]$CompilerPath,
    [string]$ExpectedVersion
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$ReleaseDirectory = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $ReleaseDirectory ('installer-vs-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw "Output already exists; choose a new directory. Preserved: $OutputDirectory" }
$manifest = Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'release-artifacts.json') -Raw | ConvertFrom-Json
$version = [string]$manifest.version
if ($version -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-[a-zA-Z0-9.-]+)?$') { throw 'Invalid release version.' }
$numericVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3]).0"
if (-not $ExpectedVersion) {
    $applicationProject = Join-Path $project 'src/Windows/viewMirror.App/viewMirror.App.csproj'
    if (Test-Path -LiteralPath $applicationProject) {
        [xml]$applicationMetadata = [IO.File]::ReadAllText($applicationProject)
        $versionNode = $applicationMetadata.SelectSingleNode('/Project/PropertyGroup/Version')
        if ($versionNode) { $ExpectedVersion = $versionNode.InnerText.Trim() }
    }
}
if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
    throw "Release ZIP version '$version' differs from project version '$ExpectedVersion'. In Visual Studio External Tools, use -File scripts/windows/build-release.ps1 without a fixed ReleaseDirectory."
}
$binaryName = "ViewMirror-$version-win-x64.zip"
$sourceName = "ViewMirror-$version-sources.zip"
foreach ($name in @($binaryName, $sourceName)) {
    $entry = @($manifest.artifacts | Where-Object file -eq $name)
    if ($entry.Count -ne 1 -or $entry[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Missing release hash: $name" }
    $file = Join-Path $ReleaseDirectory $name
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry[0].sha256) { throw "Release SHA256 mismatch: $name" }
}
if (-not $CompilerPath) { $CompilerPath = & "$PSScriptRoot/setup-installer-tool.ps1" }
$CompilerPath = (Resolve-Path -LiteralPath $CompilerPath).Path
$lock = Get-Content (Join-Path $project 'packaging/windows/inno-setup.lock.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $CompilerPath -Algorithm SHA256).Hash -ne $lock.isccSha256) { throw 'Use the pinned Inno Setup compiler.' }
$translationDirectory = Join-Path $project 'packaging/windows/licenses'
$translation = Get-Content -LiteralPath (Join-Path $translationDirectory 'translation.lock.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath (Join-Path $translationDirectory 'GPL-3.0.ja.md')).Hash -ne $translation.sourceSha256 -or
    (Get-FileHash -LiteralPath (Join-Path $translationDirectory 'GPL-3.0.ja.txt')).Hash -ne $translation.displaySha256) {
    throw 'Japanese GPL translation hash mismatch. Restore or review the pinned translation files.'
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$log = Join-Path $OutputDirectory 'build-installer.log'
Start-Transcript -LiteralPath $log | Out-Null
try {
    $extract = Join-Path $OutputDirectory 'payload'
    New-Item -ItemType Directory -Path $extract | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $ReleaseDirectory $binaryName))
    try {
        foreach ($entry in $archive.Entries) {
            $destination = [IO.Path]::GetFullPath((Join-Path $extract $entry.FullName))
            if (-not $destination.StartsWith($extract + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe ZIP entry.' }
        }
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $ReleaseDirectory $binaryName), $extract)
    $payload = Join-Path $extract 'ViewMirror'
    $marker = Get-Content (Join-Path $payload 'viewMirror.runtime.json') -Raw | ConvertFrom-Json
    if ($marker.formatVersion -ne 1 -or $marker.version -ne $version) { throw 'Wrong portable release marker.' }
    $executableVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'viewMirror.exe')).ProductVersion
    if (($executableVersion -split '\+',2)[0] -ne $version) { throw "Application executable version '$executableVersion' differs from installer version '$version'. Rebuild the application ZIP first." }
    foreach ($line in Get-Content -LiteralPath (Join-Path $payload 'FILES.sha256')) {
        if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw 'Invalid payload checksum manifest.' }
        $expected = $Matches[1]
        $file = [IO.Path]::GetFullPath((Join-Path $payload $Matches[2]))
        if (-not $file.StartsWith($payload + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe checksum path.' }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $expected) { throw "Payload checksum mismatch: $file" }
    }
    # The mutex must match App.xaml.cs in the packaged release.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('VIEWMIRROR-PACKAGE')))).Replace('-', '').Substring(0,24) }
    finally { $sha.Dispose() }
    $definition = Join-Path $project 'packaging/windows/ViewMirror.iss'
    if (-not (Select-String -LiteralPath $definition -SimpleMatch "AppMutex=Local\viewMirror-$key" -Quiet)) { throw 'Installer and packaged application mutex differ.' }
    & $CompilerPath --no-ide-signtools --no-signing --quiet "--define=PayloadDir=$payload" "--define=AppVersion=$version" "--define=NumericVersion=$numericVersion" "--output-dir=$OutputDirectory" $definition
    if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed: $LASTEXITCODE. See $log" }
    $recipe = Join-Path $OutputDirectory 'installer-source'
    $recipeFiles = @('packaging/windows/ViewMirror.iss','packaging/windows/INSTALLER-README.txt','packaging/windows/inno-setup.lock.json','packaging/windows/icons/ViewMirror.ico','packaging/windows/licenses/GPL-3.0.ja.md','packaging/windows/licenses/GPL-3.0.ja.txt','packaging/windows/licenses/translation.lock.json','scripts/windows/setup-installer-tool.ps1','scripts/windows/build-installer.ps1')
    foreach ($optional in @('scripts/windows/build-release.ps1','packaging/windows/BUILD.md')) {
        if (Test-Path -LiteralPath (Join-Path $project $optional)) { $recipeFiles += $optional }
    }
    if (Test-Path -LiteralPath (Join-Path $project 'docs/installer.md')) { $recipeFiles += 'docs/installer.md' }
    foreach ($relative in $recipeFiles) {
        $destination = Join-Path $recipe $relative
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $project $relative) -Destination $destination
    }
    @'
ViewMirror installer source

Run from this extracted source directory on Windows 11 x64:
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File scripts/windows/build-installer.ps1 -ReleaseDirectory C:\path\to\release

The release directory must contain release-artifacts.json, the matching
ViewMirror-<version>-win-x64.zip and ViewMirror-<version>-sources.zip.
The script verifies their hashes before building. Application code is not compiled.
Omitting OutputDirectory creates a new timestamped directory under ReleaseDirectory.
An existing output directory is never overwritten.
Inno Setup is pinned in packaging/windows/inno-setup.lock.json. The setup helper
reuses a matching installed compiler or installs the verified official compiler
for the current user. CompilerPath may select an existing pinned ISCC.exe.
The Japanese translation files and their fixed hashes are included under
packaging/windows/licenses. The original English GPL is in the application ZIP.

Provide the application sources ZIP together with this installer sources ZIP.
The installer is unsigned. No firewall or system security settings are changed.
'@ | Set-Content -LiteralPath (Join-Path $recipe 'README.txt') -Encoding UTF8
    $sourceZip = Join-Path $OutputDirectory "ViewMirror-$version-installer-source.zip"
    [IO.Compression.ZipFile]::CreateFromDirectory($recipe, $sourceZip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $installer = Join-Path $OutputDirectory "ViewMirror-$version-win-x64-setup.exe"
    $artifacts = @($installer,$sourceZip) | ForEach-Object { [ordered]@{ file=[IO.Path]::GetFileName($_);bytes=(Get-Item -LiteralPath $_).Length;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() } }
    [ordered]@{ version=$version; compilerVersion=$lock.version; compilerSha256=$lock.isccSha256; inputBinary=$binaryName; inputBinarySha256=($manifest.artifacts | Where-Object file -eq $binaryName).sha256; signature='unsigned'; artifacts=@($artifacts) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'installer-artifacts.json') -Encoding UTF8
    $artifacts | ForEach-Object { "$($_.sha256)  $($_.file)" } | Set-Content (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ascii
    Write-Host "Created unsigned installer: $installer"
} finally { Stop-Transcript | Out-Null }
