[CmdletBinding()]
param(
    [ValidateSet('Debug','Release')][string]$Configuration = 'Debug',
    [ValidateSet('Auto','Gnu','MicrosoftLib')][string]$ArchiveTool = 'Auto'
)
. "$PSScriptRoot/common.ps1"
$originalPath = $env:Path
$originalLibrarian = $env:viewMirror_COFF_LIBRARIAN
$msys = Find-MsysRoot
if (-not $msys) { throw 'MSYS2 not found. Run setup.ps1 first.' }
$dotnet = Find-Dotnet
function Find-MicrosoftLibrarian {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio discovery tool not found; a Microsoft-signed lib.exe is required for this archive mode.' }
    $installations = @(& $vswhere -all -products '*' -property installationPath)
    foreach ($installation in $installations) {
        $candidates = @(Get-ChildItem -Path (Join-Path $installation 'VC/Tools/MSVC/*/bin/Hostx64/x64/lib.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        foreach ($candidate in $candidates) {
            $signature = Get-AuthenticodeSignature -FilePath $candidate.FullName
            if ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match '(^|, )O=Microsoft Corporation(,|$)') { return $candidate.FullName }
        }
    }
    throw 'No valid Microsoft-signed x64 lib.exe found. Install the Visual Studio C++ build tools or use an approved GNU archive tool.'
}
Start-Transcript -Path (Join-Path $LogDir 'build-windows.txt') -Append
try {
    Assert-UxPlaySourceSnapshot
    Assert-PackageSnapshot $msys
    if ($ArchiveTool -eq 'Auto') {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:/SYSTEM/CurrentControlSet/Control/CI/Policy' -ErrorAction SilentlyContinue
        $ArchiveTool = if ($policy -and $policy.PSObject.Properties['VerifiedAndReputablePolicyState'] -and $policy.VerifiedAndReputablePolicyState -eq 1) { 'MicrosoftLib' } else { 'Gnu' }
    }
    if ($ArchiveTool -eq 'MicrosoftLib') {
        $librarian = Find-MicrosoftLibrarian
        $env:viewMirror_COFF_LIBRARIAN = $librarian.Replace('\','/')
        @{archiveTool=$ArchiveTool;path=$librarian;sha256=(Get-FileHash -LiteralPath $librarian -Algorithm SHA256).Hash;version=(Get-Item -LiteralPath $librarian).VersionInfo.ProductVersion;signature='Valid Microsoft Corporation'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDir 'archive-tool-windows.json') -Encoding utf8
    }
    Write-Host "Archive tool: $ArchiveTool. Compiler, linker and dependency libraries: MSYS2 UCRT64."
    Set-MsysEnvironment $msys
    $archiveOptions = if ($ArchiveTool -eq 'MicrosoftLib') {
        '-DviewMirror_COFF_LIBRARIAN="$viewMirror_COFF_LIBRARIAN" -DCMAKE_AR="$viewMirror_COFF_LIBRARIAN" -DCMAKE_PROJECT_INCLUDE="$viewMirror_ROOT/scripts/windows/coff-archive.cmake"'
    } else {
        '-DCMAKE_AR=/ucrt64/bin/ar.exe -DCMAKE_RANLIB=/ucrt64/bin/ranlib.exe -DCMAKE_PROJECT_INCLUDE= -DviewMirror_COFF_LIBRARIAN='
    }
    $nativeBuild = @'
cd "$viewMirror_ROOT"
cmake -S third_party/UxPlay -B build/native/windows-ucrt64 -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_C_COMPILER=/ucrt64/bin/gcc.exe -DCMAKE_CXX_COMPILER=/ucrt64/bin/g++.exe -DNO_MARCH_NATIVE=ON -DUSE_DNS_SD=OFF __ARCHIVE_OPTIONS__ 2>&1 | tee "$viewMirror_ROOT/artifacts/logs/build-native-windows.txt"
cmake --build build/native/windows-ucrt64 --parallel 8 2>&1 | tee -a "$viewMirror_ROOT/artifacts/logs/build-native-windows.txt"
test -s build/native/windows-ucrt64/uxplay.exe
'@
    Invoke-Msys $msys $nativeBuild.Replace('__ARCHIVE_OPTIONS__', $archiveOptions)
    Write-Host 'Preparing the project-scoped GStreamer registry for receiver startup.'
    Set-MsysEnvironment $msys -MinimalPlugins
    Invoke-Msys $msys 'for plugin in appsrc h264parse avdec_h264 h265parse avdec_h265 x265enc avdec_aac avdec_alac d3d11videosink wasapisink autodetect udpsrc rtpjitterbuffer rtph264pay rtph264depay rtph265pay rtph265depay; do gst-inspect-1.0 "$plugin" > "$viewMirror_ROOT/artifacts/logs/gst-${plugin}-build.txt"; done'
    $env:Path = $originalPath
    Push-Location $ProjectRoot
    try {
        if (-not (Test-Path -LiteralPath 'viewMirror.slnx')) {
            & $dotnet new sln --name viewMirror --format slnx
            Assert-NativeExit 'Create solution'
            & $dotnet sln viewMirror.slnx add src/Windows/viewMirror.App/viewMirror.App.csproj
            Assert-NativeExit 'Add WPF project'
        }
        & $dotnet build viewMirror.slnx --configuration $Configuration --nologo
        Assert-NativeExit 'WPF build'
    } finally { Pop-Location }
    Write-Host 'Native and WPF builds succeeded.'
} finally { $env:Path = $originalPath; $env:viewMirror_COFF_LIBRARIAN = $originalLibrarian; Stop-Transcript }
