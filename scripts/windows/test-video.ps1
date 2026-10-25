[CmdletBinding()]
param([ValidateRange(2,120)][int]$Seconds = 6, [ValidateRange(1,5)][int]$Cycles = 2,
    [ValidateSet('H264','HEVC')][string]$Codec = 'H264',
    [ValidateRange(64,3840)][int]$Width = 960, [ValidateRange(64,3840)][int]$Height = 540,
    [ValidateRange(1,60)][int]$FrameRate = 30)
. "$PSScriptRoot/common.ps1"

# Run against an already-open, idle UI. Never send test pictures into an iPad session.
$snapshotPath = Join-Path $LogDir 'window-state.json'
$checks = [Collections.Generic.List[object]]::new()
$feed = $null
$originalPath = $env:Path
function Test-AirPlayClient {
    return @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() |
        Where-Object { $_.LocalEndPoint.Port -eq 7001 -and $_.State -eq 'Established' -and
            -not [Net.IPAddress]::IsLoopback($_.RemoteEndPoint.Address) }).Count -gt 0
}
function Read-View {
    $value = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
    if ($value.error) { throw "UI video error: $($value.error)" }
    return $value
}
function Wait-View([string]$View) {
    $deadline = (Get-Date).AddSeconds(12)
    do {
        if (Test-AirPlayClient) { throw 'An AirPlay client connected. Synthetic test cancelled; reconnect the iPad if needed.' }
        $value = Read-View
        if ($value.view -eq $View) { return $value }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "UI did not enter $View within 12 seconds."
}
$result = [ordered]@{ timestamp=(Get-Date -Format o); status='failed'; scope="synthetic loopback $Codec/RTP only"; ipadConnection='unverified'; checks=$checks }
try {
    $initial = Wait-View waiting
    $ui = @(Get-Process -Name viewMirror -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -eq (Join-Path $ProjectRoot 'src/Windows/viewMirror.App/bin/Debug/net10.0-windows/viewMirror.exe') -and
        $_.MainWindowHandle.ToInt64() -eq $initial.window
    })
    if ($ui.Count -ne 1) { throw 'Start this project UI and wait for its receiver before running the video test.' }
    $msys = Find-MsysRoot
    if (-not $msys) { throw 'MSYS2 UCRT64 not found. Run setup.ps1 first.' }
    Set-MsysEnvironment $msys -MinimalPlugins
    for ($cycle=1; $cycle -le $Cycles; $cycle++) {
        $encoder = if ($Codec -eq 'HEVC') { "x265enc speed-preset=ultrafast tune=zerolatency key-int-max=$FrameRate option-string=log-level=error ! h265parse ! rtph265pay" } else { "openh264enc gop-size=$FrameRate ! h264parse ! rtph264pay" }
        $arguments = "-q videotestsrc is-live=true num-buffers=$($Seconds * $FrameRate) ! video/x-raw,format=I420,width=$Width,height=$Height,framerate=$FrameRate/1 ! $encoder pt=96 config-interval=1 ! udpsink host=127.0.0.1 port=7040 sync=false"
        $feed = Start-Process -FilePath (Join-Path $msys 'ucrt64/bin/gst-launch-1.0.exe') -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $LogDir 'embedded-test-stdout.txt') -RedirectStandardError (Join-Path $LogDir 'embedded-test-stderr.txt')
        $null = $feed.Handle # Keep the exit code available in Windows PowerShell 5.1.
        $video = Wait-View mirroring
        if ($video.frameWidth -ne $Width -or $video.frameHeight -ne $Height -or $video.codec -ne $Codec -or $video.window -ne $initial.window) {
            throw 'Decoded frame size or the shared top-level window does not match.'
        }
        while (-not $feed.HasExited) {
            if (Test-AirPlayClient) { throw 'An AirPlay client connected. Synthetic test cancelled; reconnect the iPad if needed.' }
            Start-Sleep -Milliseconds 100
            $feed.Refresh()
        }
        $feed.WaitForExit()
        if ($feed.ExitCode -ne 0) { throw "Test encoder failed: $($feed.ExitCode). See embedded-test-stderr.txt." }
        $idle = Wait-View waiting
        if ($idle.window -ne $initial.window) { throw 'Waiting view moved to another window.' }
        $checks.Add(@{cycle=$cycle;video=$video;waiting=$idle})
        Write-Host "PASS cycle $cycle`: $Codec/RTP decoded at ${Width}x${Height}, displayed, returned to waiting in the same window."
    }
    $result.status = 'success'
} catch { $result['error'] = $_.Exception.Message; throw }
finally {
    if ($feed -and -not $feed.HasExited) { Stop-Process -Id $feed.Id }
    $env:Path = $originalPath
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $LogDir 'embedded-video-smoke.json') -Encoding utf8
}
