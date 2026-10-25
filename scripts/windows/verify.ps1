[CmdletBinding()]
param([switch]$Receive,[string]$InterfaceAddress)
. "$PSScriptRoot/common.ps1"
$originalPath = $env:Path
$result = [ordered]@{native='unverified';gstreamer='unverified';wpf='unverified';receiver='unverified';mdns='unverified';ipadConnection='unverified';timestamp=(Get-Date -Format o)}
$leaveRunning = $false
Start-Transcript -Path (Join-Path $LogDir 'verify-windows.txt') -Append
try {
    $msys = Find-MsysRoot
    if (-not $msys) { throw 'Run setup.ps1 first.' }
    Set-MsysEnvironment $msys -MinimalPlugins
    Invoke-Msys $msys 'bash "$viewMirror_ROOT/scripts/windows/native-verify.sh"'
    $result.native = 'success'
    $result.gstreamer = 'success'
    $env:Path = $originalPath
    $wpfExe = Join-Path $ProjectRoot 'src/Windows/viewMirror.App/bin/Debug/net10.0-windows/viewMirror.exe'
    $window = Start-Process -FilePath $wpfExe -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
    try {
        if (-not $window.WaitForInputIdle(15000)) { throw 'WPF UI thread did not become idle.' }
        $until = (Get-Date).AddSeconds(10)
        do { Start-Sleep -Milliseconds 250; $window.Refresh() } while (-not $window.HasExited -and $window.MainWindowHandle -eq 0 -and (Get-Date) -lt $until)
        if ($window.HasExited -or $window.MainWindowHandle -eq 0 -or -not $window.Responding -or $window.MainWindowTitle -cne 'ViewMirror') { throw 'WPF window did not initialize.' }
        @{pid=$window.Id;title=$window.MainWindowTitle;responding=$window.Responding;windowHandle=$window.MainWindowHandle.ToInt64()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDir 'wpf-startup.json') -Encoding utf8
        $window.CloseMainWindow() | Out-Null
        if (-not $window.WaitForExit(10000) -or $window.ExitCode -ne 0) { throw 'WPF did not exit cleanly.' }
        $result.wpf = 'success'
        Write-Host 'PASS WPF main window initialized, responded and exited cleanly.'
    } finally { if (-not $window.HasExited) { Stop-Process -Id $window.Id } }
    & "$PSScriptRoot/receiver.ps1"
    $receiverState = Get-Content -LiteralPath (Join-Path $ProjectRoot 'artifacts/receiver-windows.json') -Raw | ConvertFrom-Json
    $listeners = Get-NetTCPConnection -State Listen -OwningProcess $receiverState.pid
    $listeners | Select-Object LocalAddress,LocalPort,State,OwningProcess | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDir 'receiver-listeners.json')
    # Upstream uses base+1 for the shared AirPlay/RAOP HTTP listener; RTP starts on connection.
    if (-not ($listeners | Where-Object { $_.LocalPort -eq 7001 })) { throw 'UxPlay TCP listener 7001 not found.' }
    # The CIM cmdlet can omit sockets sharing UDP 5353 with other applications.
    & "$env:SystemRoot/System32/netstat.exe" -ano -p udp | Where-Object { $_ -match ('\s+' + $receiverState.pid + '\s*$') } | Set-Content -LiteralPath (Join-Path $LogDir 'receiver-udp.txt')
    $result.receiver = 'success'
    if (-not $InterfaceAddress) {
        $private = @(Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Private' -and $_.IPv4Connectivity -eq 'Internet' })
        if ($private.Count -ne 1) { throw 'Specify -InterfaceAddress for a trusted Private IPv4 interface.' }
        $InterfaceAddress = (Get-NetIPAddress -InterfaceIndex $private[0].InterfaceIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1).IPAddress
    }
    Set-MsysEnvironment $msys -MinimalPlugins
    & (Join-Path $msys 'ucrt64/bin/python.exe') (Join-Path $ProjectRoot 'scripts/mdns_probe.py') --interface $InterfaceAddress --name ViewMirror-Windows --port 7001 --output (Join-Path $LogDir 'mdns-windows.json')
    Assert-NativeExit 'mDNS PTR/SRV/TXT/A response'
    $result.mdns = 'success'
    $leaveRunning = [bool]$Receive
    Write-Host 'PASS AirPlay receiver wait and local mDNS query response. iPad connection is still unverified.'
} catch {
    $result['error'] = $_.Exception.Message
    throw
} finally {
    $env:Path = $originalPath
    if (-not $leaveRunning) { & "$PSScriptRoot/receiver.ps1" -Stop }
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDir 'verification-windows.json') -Encoding utf8
    Stop-Transcript
}
