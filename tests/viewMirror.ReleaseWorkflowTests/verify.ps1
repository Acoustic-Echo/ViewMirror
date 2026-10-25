[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testRoot = Join-Path $project ('artifacts/release-workflow-tests/' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $testRoot 'project'
$package = Join-Path $testRoot 'portable'
foreach ($root in @($fixture,$package)) {
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts/windows') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'src/Windows/viewMirror.App') -Force | Out-Null
    '<Project><PropertyGroup><Version>2.4.6</Version></PropertyGroup></Project>' | Set-Content -LiteralPath (Join-Path $root 'src/Windows/viewMirror.App/viewMirror.App.csproj')
}
Copy-Item -LiteralPath (Join-Path $project 'scripts/windows/build-release.ps1') -Destination (Join-Path $fixture 'scripts/windows/build-release.ps1')
@'
param($OutputRoot,$Version,$OutputDirectory,$SourceArchiveDirectory)
$ErrorActionPreference='Stop'
if($Version -ne '2.4.6'){throw 'Wrong package version passed.'}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$artifacts=@()
foreach($name in @("ViewMirror-$Version-win-x64.zip","ViewMirror-$Version-sources.zip")){
    $path=Join-Path $OutputDirectory $name
    'FIXTURE ONLY: not a release archive' | Set-Content -LiteralPath $path
    $artifacts+=@{file=$name;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $path).Length}
}
@{version=$Version;artifacts=$artifacts}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutputDirectory 'release-artifacts.json')
'@ | Set-Content -LiteralPath (Join-Path $package 'scripts/windows/package.ps1')
@'
param($ReleaseDirectory,$OutputDirectory,$ExpectedVersion,$CompilerPath)
$ErrorActionPreference='Stop'
$metadata=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'release-artifacts.json') -Raw|ConvertFrom-Json
if($ExpectedVersion -ne '2.4.6' -or $metadata.version -ne $ExpectedVersion){throw 'Wrong installer version passed.'}
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$artifacts=@()
foreach($name in @("ViewMirror-$ExpectedVersion-win-x64-setup.exe","ViewMirror-$ExpectedVersion-installer-source.zip")){
    $path=Join-Path $OutputDirectory $name
    'FIXTURE ONLY: not an executable or archive'|Set-Content -LiteralPath $path
    $artifacts+=@{file=$name;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $path).Length}
}
@{version=$ExpectedVersion;artifacts=$artifacts}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutputDirectory 'installer-artifacts.json')
'@ | Set-Content -LiteralPath (Join-Path $fixture 'scripts/windows/build-installer.ps1')
$output = Join-Path $testRoot 'output'
& (Join-Path $fixture 'scripts/windows/build-release.ps1') -ReleaseRoot $output -PackageProject $package
$builds = @(Get-ChildItem -LiteralPath (Join-Path $output '2.4.6') -Directory)
if ($builds.Count -ne 1) { throw 'Timestamped version output not created.' }
$result = Get-Content -LiteralPath (Join-Path $builds[0].FullName 'build-release.json') -Raw | ConvertFrom-Json
if ($result.version -ne '2.4.6' -or $result.artifacts.Count -ne 4) { throw 'Collected artifact version/count mismatch.' }
foreach ($entry in $result.artifacts) {
    if ($entry.file -notlike 'ViewMirror-2.4.6-*') { throw 'Stale artifact name.' }
    $path = Join-Path (Join-Path $builds[0].FullName 'share') $entry.file
    if ((Get-FileHash -LiteralPath $path).Hash -ne $entry.sha256) { throw 'Shared artifact checksum mismatch.' }
}
'<Project><PropertyGroup><Version>2.4.7</Version></PropertyGroup></Project>' | Set-Content -LiteralPath (Join-Path $package 'src/Windows/viewMirror.App/viewMirror.App.csproj')
$rejected = $false
try { & (Join-Path $fixture 'scripts/windows/build-release.ps1') -ReleaseRoot $output -PackageProject $package -CheckOnly }
catch { if ($_.Exception.Message -notmatch 'differs from portable source version') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Mismatched source project version was accepted.' }
@{status='success';fixtureVersion='2.4.6';versionPropagatedToPackageAndInstaller=$true;sharedArtifactsVerified=4;sourceVersionMismatchRejected=$true;realApplicationBuilt=$false;realInstallerBuilt=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'result.json')
Write-Host "PASS: dynamic version propagation, four shared artifact checksums, source version mismatch rejection. Fixtures: $testRoot"
