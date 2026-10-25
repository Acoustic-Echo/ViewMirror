[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$DebugReceiver,
    [switch]$EmbeddedVideo,
    [ValidateSet('960x540','1280x720','1920x1080','2560x1440','3840x2160')]
    [string]$Resolution = '1920x1080',
    [ValidateSet('Auto','H264','HEVC')]
    [string]$Codec = 'Auto'
)
. "$PSScriptRoot/common.ps1"
$stateFile = Join-Path $ProjectRoot 'artifacts/receiver-windows.json'
$executable = Join-Path $ProjectRoot 'build/native/windows-ucrt64/uxplay.exe'
$previous = $null
if (Test-Path -LiteralPath $stateFile) {
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $candidate = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
    if ($candidate -and $candidate.Path -eq $executable -and $candidate.StartTime.ToUniversalTime().Ticks -eq ([datetime]$state.startUtc).ToUniversalTime().Ticks) { $previous = $candidate }
}
if ($Stop) {
    if ($previous) { Stop-Process -Id $previous.Id; $previous.WaitForExit(10000) | Out-Null; Write-Host "Stopped managed UxPlay PID $($previous.Id)." }
    else { Write-Host 'No managed receiver is running.' }
    return
}
if ($previous) {
    $activeResolution = '1920x1080'
    if ($state.PSObject.Properties['resolution']) { $activeResolution = $state.resolution }
    if ($activeResolution -ne $Resolution) { throw "Receiver is running with resolution $activeResolution. Stop it before changing resolution to $Resolution." }
    $activeEmbedded = $false
    if ($state.PSObject.Properties['embeddedVideo']) { $activeEmbedded = [bool]$state.embeddedVideo }
    if ($activeEmbedded -ne [bool]$EmbeddedVideo) { throw 'Stop the managed receiver before changing its video output mode.' }
    $activeCodec = 'Auto'
    if ($state.PSObject.Properties['codec']) { $activeCodec = $state.codec }
    if ($activeCodec -ne $Codec) { throw "Stop the managed receiver before changing codec from $activeCodec to $Codec." }
    Write-Host "Receiver already running: PID $($previous.Id), requested resolution $activeResolution. Logs: $LogDir/receiver-*.txt"
    return
}
if (-not (Test-Path -LiteralPath $executable)) { throw 'Build UxPlay before starting the receiver.' }
$conflicts = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 7000,7001,7002 }
if ($conflicts) { throw 'TCP 7000-7002 is already used. Existing process preserved; choose other ports deliberately.' }
$originalPath = $env:Path
$originalDebugFile = $env:GST_DEBUG_FILE
try {
    $msys = Find-MsysRoot
    if (-not $msys) { throw 'MSYS2 not found.' }
    Set-MsysEnvironment $msys -MinimalPlugins
    $env:GST_DEBUG = '2'
    # WPF has its own open debug file; do not inherit that file into UxPlay.
    $env:GST_DEBUG_FILE = Join-Path $LogDir 'receiver-gstreamer.txt'
    $configFile = Join-Path $ProjectRoot 'artifacts/uxplay-empty.rc'
    '# Explicit empty configuration: no changes to user-wide uxplayrc.' | Set-Content -LiteralPath $configFile -Encoding ascii
    $arguments = @('-rc',('"' + $configFile + '"'),'-n','ViewMirror-Windows','-nh','-p','7000','-s',$Resolution,'-vs','d3d11videosink','-as','wasapisink')
    # HEVC support also accepts H.264; the sending device selects the actual codec.
    $hevcEnabled = $Codec -eq 'HEVC' -or ($Codec -eq 'Auto' -and [int]($Resolution.Split('x')[1]) -gt 1080)
    if ($hevcEnabled) { $arguments += '-h265' }
    if ($EmbeddedVideo) {
        # Encoded video stays on loopback; WPF owns the local rendering pipeline.
        $arguments += @('-vrtp','"config-interval=1 pt=96 ! udpsink host=127.0.0.1 port=7040 sync=false async=false"')
    }
    # Normal logging is unbuffered on Windows; debug output can be buffered.
    if ($DebugReceiver) { $arguments += @('-d','1') }
    # Hidden also hides the first D3D video window. Reuse the caller's console
    # (or its absence for the WPF launcher), without hiding renderer windows.
    $process = Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $ProjectRoot -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $LogDir 'receiver-stdout.txt') -RedirectStandardError (Join-Path $LogDir 'receiver-stderr.txt')
    @{pid=$process.Id;startUtc=$process.StartTime.ToUniversalTime().ToString('o');executable=$executable;name='ViewMirror-Windows';basePort=7000;servicePort=7001;resolution=$Resolution;embeddedVideo=[bool]$EmbeddedVideo;codec=$Codec;hevcEnabled=$hevcEnabled} | ConvertTo-Json | Set-Content -LiteralPath $stateFile
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $process.Refresh()
        if ($process.HasExited) {
            Get-Content -LiteralPath (Join-Path $LogDir 'receiver-stdout.txt') -Tail 20
            Get-Content -LiteralPath (Join-Path $LogDir 'receiver-stderr.txt') -Tail 20
            throw 'UxPlay exited before opening TCP 7001. See receiver-stdout.txt and receiver-stderr.txt for the native error.'
        }
        $listener = Get-NetTCPConnection -LocalPort 7001 -State Listen -OwningProcess $process.Id -ErrorAction SilentlyContinue
        if ($listener) { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    if (-not $listener) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" | Where-Object { $_.ExecutablePath -eq (Join-Path $msys 'ucrt64/libexec/gstreamer-1.0/gst-plugin-scanner.exe') } | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw 'UxPlay did not open TCP 7001 within 20 seconds. Check GStreamer discovery and logs; process existence alone is not receiver readiness.'
    }
    Write-Host "Receiver running: PID $($process.Id), name ViewMirror-Windows, requested resolution $Resolution, codec $Codec (HEVC support: $hevcEnabled), TCP/UDP 7000-7002."
    Write-Host "Logs: $LogDir/receiver-stdout.txt and receiver-stderr.txt"
} finally { $env:Path = $originalPath; $env:GST_DEBUG_FILE = $originalDebugFile }
