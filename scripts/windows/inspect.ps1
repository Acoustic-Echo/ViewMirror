$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$logDir = Join-Path $root 'artifacts/logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Start-Transcript -Path (Join-Path $logDir 'environment-windows.txt') -Force
try {
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture,BuildNumber | Format-List
    Get-CimInstance Win32_Processor | Select-Object Name,AddressWidth,Architecture | Format-List
    $PSVersionTable | Format-List
    Get-PSDrive -PSProvider FileSystem | Select-Object Name,Root,Free | Format-Table
    Get-NetConnectionProfile | Select-Object Name,InterfaceAlias,NetworkCategory,IPv4Connectivity | Format-List
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | Select-Object InterfaceAlias,IPAddress,PrefixLength | Format-Table
    Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed | Format-Table
    foreach ($name in @('git','gcc','g++','clang','cl','cmake','ninja','pkg-config','gst-launch-1.0','gst-inspect-1.0','openssl','dotnet','code','winget','bash','pacman','rg')) {
        Get-Command $name -ErrorAction SilentlyContinue | Select-Object Name,Source | Format-Table
    }
    & git --version
    $dotnet = 'C:/Program Files/dotnet/dotnet.exe'
    if (Test-Path -LiteralPath $dotnet) { & $dotnet --info }
    $vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        & $vswhere -all -format json
        & $vswhere -all -find 'VC/Tools/MSVC/**/bin/Hostx64/x64/cl.exe'
        & $vswhere -all -find 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    }
    $keys = @('HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/*','HKLM:/Software/Microsoft/Windows/CurrentVersion/Uninstall/*','HKLM:/Software/WOW6432Node/Microsoft/Windows/CurrentVersion/Uninstall/*')
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'MSYS|Visual Studio Code|GStreamer|Git version|Bonjour|OpenSSL' } | Select-Object DisplayName,DisplayVersion,InstallLocation | Format-List
    Get-ChildItem -LiteralPath 'C:/Program Files','C:/Program Files (x86)' -Filter '*Code*' -ErrorAction SilentlyContinue | Select-Object FullName | Format-Table
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    'Administrator: ' + $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} finally { Stop-Transcript }
