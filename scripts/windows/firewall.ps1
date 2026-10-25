[CmdletBinding(SupportsShouldProcess)]
param([string]$InterfaceAddress,[switch]$Remove)
. "$PSScriptRoot/common.ps1"
$names = @('viewMirror-Dev-TCP','viewMirror-Dev-UDP','viewMirror-Dev-mDNS')
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script in an elevated PowerShell. Only scoped viewMirror development rules are changed.' }
Start-Transcript -Path (Join-Path $LogDir 'firewall-windows.txt') -Append
try {
    if ($Remove) {
        foreach ($name in $names) { Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Group -eq 'viewMirror Development' } | Remove-NetFirewallRule -WhatIf:$WhatIfPreference }
        return
    }
    if (-not $InterfaceAddress) {
        $profiles = @(Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Private' -and $_.IPv4Connectivity -eq 'Internet' })
        if ($profiles.Count -ne 1) { throw 'Specify -InterfaceAddress on a trusted Private interface.' }
        $InterfaceAddress = (Get-NetIPAddress -InterfaceIndex $profiles[0].InterfaceIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1).IPAddress
    }
    $ip = Get-NetIPAddress -IPAddress $InterfaceAddress -AddressFamily IPv4
    $profile = Get-NetConnectionProfile -InterfaceIndex $ip.InterfaceIndex
    if ($profile.NetworkCategory -ne 'Private') { throw 'Refusing to allow inbound traffic on a non-Private interface.' }
    $bytes = [Net.IPAddress]::Parse($InterfaceAddress).GetAddressBytes()
    for ($bit = $ip.PrefixLength; $bit -lt 32; $bit++) {
        $index = [int][Math]::Floor($bit / 8)
        $bytes[$index] = $bytes[$index] -band (255 -bxor (1 -shl (7 - ($bit % 8))))
    }
    $subnet = ([Net.IPAddress]::new($bytes)).ToString() + '/' + $ip.PrefixLength
    $exe = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'build/native/windows-ucrt64/uxplay.exe'))
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Build UxPlay first.' }
    # Cancelling Windows' first-launch prompt creates program-specific block rules.
    # Keep those blocks on Public/Domain, while the rules below allow only the
    # trusted Private interface/subnet and required receiver ports.
    $promptBlocks = @(Get-NetFirewallApplicationFilter -Program $exe -ErrorAction SilentlyContinue |
        Get-NetFirewallRule | Where-Object {
            $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' -and -not $_.Group -and
            $_.Name -match '^(TCP|UDP) Query User\{' -and
            ($_.Profile.ToString() -eq 'Any' -or $_.Profile.ToString() -match 'Private')
        })
    foreach ($blocked in $promptBlocks) {
        $remaining = @(if ($blocked.Profile.ToString() -eq 'Any') { 'Domain','Public' }
            else { $blocked.Profile.ToString() -split ',\s*' | Where-Object { $_ -ne 'Private' } })
        if ($remaining.Count) {
            Set-NetFirewallRule -Name $blocked.Name -Profile $remaining -WhatIf:$WhatIfPreference | Out-Null
        } else {
            Set-NetFirewallRule -Name $blocked.Name -Enabled False -WhatIf:$WhatIfPreference | Out-Null
        }
    }
    $rules = @(
        @{Name=$names[0];Protocol='TCP';LocalPort='7000-7002';LocalAddress=@($InterfaceAddress)},
        @{Name=$names[1];Protocol='UDP';LocalPort='7000-7002';LocalAddress=@($InterfaceAddress)},
        @{Name=$names[2];Protocol='UDP';LocalPort='5353';LocalAddress=@($InterfaceAddress,'224.0.0.251')}
    )
    foreach ($rule in $rules) {
        $old = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        if ($old -and $old.Group -ne 'viewMirror Development') { throw "Rule name collision; existing rule preserved: $($rule.Name)" }
        $params = @{Profile='Private';Direction='Inbound';Action='Allow';Enabled='True';Program=$exe;InterfaceAlias=$ip.InterfaceAlias;RemoteAddress=$subnet;Protocol=$rule.Protocol;LocalPort=$rule.LocalPort;LocalAddress=$rule.LocalAddress;EdgeTraversalPolicy='Block'}
        if ($old) { Set-NetFirewallRule -Name $rule.Name @params -WhatIf:$WhatIfPreference | Out-Null }
        else { New-NetFirewallRule -Name $rule.Name -DisplayName $rule.Name -Group 'viewMirror Development' @params -WhatIf:$WhatIfPreference | Out-Null }
    }
    if (-not $WhatIfPreference) {
        $records = foreach ($name in $names) {
            $rule = Get-NetFirewallRule -Name $name
            $port = $rule | Get-NetFirewallPortFilter
            $address = $rule | Get-NetFirewallAddressFilter
            [ordered]@{name=$name;profile=$rule.Profile.ToString();action=$rule.Action.ToString();enabled=$rule.Enabled.ToString();program=($rule | Get-NetFirewallApplicationFilter).Program;interface=$ip.InterfaceAlias;protocol=$port.Protocol;localPort=$port.LocalPort;localAddress=$address.LocalAddress;remoteAddress=$address.RemoteAddress}
        }
        @{status='success';rules=@($records);timestamp=(Get-Date -Format o)} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $LogDir 'firewall-windows.json') -Encoding utf8
        Write-Host "Three program-specific inbound rules configured for Private $InterfaceAddress / $subnet only."
    }
} finally { Stop-Transcript }
