[CmdletBinding()]
param(
    [string]$ReleaseRoot = 'C:\releases\ViewMirror',
    [string]$PackageProject,
    [string]$SourceArchiveDirectory,
    [string]$CompilerPath,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
function Read-ProjectVersion([string]$Root) {
    $path = Join-Path $Root 'src/Windows/viewMirror.App/viewMirror.App.csproj'
    [xml]$metadata = [IO.File]::ReadAllText($path)
    $node = $metadata.SelectSingleNode('/Project/PropertyGroup/Version')
    if (-not $node -or $node.InnerText.Trim() -notmatch '^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$') { throw "Set a valid Version in $path" }
    return $node.InnerText.Trim()
}
$version = Read-ProjectVersion $project
if (-not $PackageProject) {
    if (Test-Path -LiteralPath (Join-Path $project 'scripts/windows/package.ps1')) { $PackageProject = $project }
    else { $PackageProject = Join-Path (Split-Path $project) 'viewMirror-release-work' }
}
$PackageProject = (Resolve-Path -LiteralPath $PackageProject).Path
$packageScript = Join-Path $PackageProject 'scripts/windows/package.ps1'
if (-not (Test-Path -LiteralPath $packageScript)) { throw "Portable packaging script not found: $packageScript" }
$packageVersion = Read-ProjectVersion $PackageProject
if ($packageVersion -ne $version) { throw "Development version '$version' differs from portable source version '$packageVersion'. Update both project versions before packaging." }
$ReleaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
$buildDirectory = Join-Path (Join-Path $ReleaseRoot $version) ('build-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
if (-not $SourceArchiveDirectory) {
    if (Test-Path -LiteralPath $ReleaseRoot) {
        foreach ($directory in (Get-ChildItem -LiteralPath $ReleaseRoot -Directory | Sort-Object LastWriteTime -Descending)) {
            $candidate = Join-Path $directory.FullName 'source-archives'
            if (Test-Path -LiteralPath (Join-Path $candidate 'sources-manifest.json')) { $SourceArchiveDirectory = $candidate; break }
        }
    }
    if (-not $SourceArchiveDirectory) {
        $candidate = Join-Path $PackageProject 'dependency-sources'
        if (Test-Path -LiteralPath (Join-Path $candidate 'sources-manifest.json')) { $SourceArchiveDirectory = $candidate }
    }
}
$plan = [ordered]@{
    version = $version
    developmentProject = $project
    packageProject = $PackageProject
    outputDirectory = $buildDirectory
    sourceArchiveDirectory = $SourceArchiveDirectory
    operations = @('Build native and WPF application','Publish self-contained application','Create application and corresponding-source ZIPs','Create installer and installer-source ZIP','Verify and collect shared artifacts')
}
Write-Host "ViewMirror version: $version"
Write-Host "Portable source: $PackageProject"
Write-Host "Output: $buildDirectory"
if ($CheckOnly) {
    $plan | ConvertTo-Json -Depth 4
    Write-Host 'CHECK ONLY: no build, installation or output directory creation was performed.'
    return
}
if (Test-Path -LiteralPath $buildDirectory) { throw "Output already exists; preserved: $buildDirectory" }
$packageArguments = @{ OutputRoot=$ReleaseRoot; Version=$version; OutputDirectory=$buildDirectory }
if ($SourceArchiveDirectory) { $packageArguments.SourceArchiveDirectory=$SourceArchiveDirectory }
& $packageScript @packageArguments
$installerDirectory = Join-Path $buildDirectory 'installer'
$installerArguments = @{ ReleaseDirectory=$buildDirectory; OutputDirectory=$installerDirectory; ExpectedVersion=$version }
if ($CompilerPath) { $installerArguments.CompilerPath=$CompilerPath }
& "$PSScriptRoot/build-installer.ps1" @installerArguments
$share = Join-Path $buildDirectory 'share'
New-Item -ItemType Directory -Path $share | Out-Null
$artifacts = @()
foreach ($manifestPath in @((Join-Path $buildDirectory 'release-artifacts.json'),(Join-Path $installerDirectory 'installer-artifacts.json'))) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.version -ne $version) { throw 'Generated artifact version mismatch.' }
    foreach ($entry in $manifest.artifacts) {
        $source = Join-Path (Split-Path $manifestPath) $entry.file
        $destination = Join-Path $share $entry.file
        Copy-Item -LiteralPath $source -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $entry.sha256) { throw "Shared artifact hash mismatch: $($entry.file)" }
        $artifacts += $entry
    }
}
$artifacts | ForEach-Object { "$($_.sha256)  $($_.file)" } | Set-Content -LiteralPath (Join-Path $share 'SHA256SUMS.txt') -Encoding ascii
@"
ViewMirror $version / Windows 11 x64

Run ViewMirror-$version-win-x64-setup.exe to install for the current user.
The application starts from the ViewMirror Start menu shortcut.
The executable is unsigned. Do not disable system security protections.
Provide both the application sources ZIP and installer-source ZIP to recipients.
This build command verifies packaging; it does not verify an iPad connection.
"@ | Set-Content -LiteralPath (Join-Path $share 'README.txt') -Encoding UTF8
$plan['artifacts'] = @($artifacts)
$plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $buildDirectory 'build-release.json') -Encoding UTF8
Write-Host "Created ViewMirror $version. Share directory: $share"
