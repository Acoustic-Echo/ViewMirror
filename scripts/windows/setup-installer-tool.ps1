[CmdletBinding()]
param([string]$ToolDirectory)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$lock = Get-Content (Join-Path $project 'packaging/windows/inno-setup.lock.json') -Raw | ConvertFrom-Json
if (-not $ToolDirectory) {
    $candidates = @()
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $candidates += @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq "Inno Setup $($lock.version)" -and $_.InstallLocation } | ForEach-Object { Join-Path $_.InstallLocation 'ISCC.exe' })
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ((Test-Path -LiteralPath $candidate) -and (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq $lock.isccSha256) {
            Write-Output $candidate
            return
        }
    }
}
if (-not $ToolDirectory) { $ToolDirectory = Join-Path $project ".tools/InnoSetup-$($lock.version)" }
$ToolDirectory = [IO.Path]::GetFullPath($ToolDirectory)
$compiler = Join-Path $ToolDirectory 'ISCC.exe'
if (Test-Path -LiteralPath $compiler) {
    if ((Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash -ne $lock.isccSha256) {
        throw "Existing compiler differs from the pinned version. Preserved: $compiler"
    }
    Write-Output $compiler
    return
}
if (Test-Path -LiteralPath $ToolDirectory) { throw "Nonempty or incomplete tool directory preserved: $ToolDirectory" }
$cache = Join-Path $project '.tools/installer-downloads'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$download = Join-Path $cache "innosetup-$($lock.version)-x64.exe"
if (-not (Test-Path -LiteralPath $download)) {
    & curl.exe -fL --retry 2 --max-time 180 --output $download $lock.url
    if ($LASTEXITCODE -ne 0) { throw 'Official Inno Setup download failed. No installer was run.' }
}
if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $lock.sha256) {
    throw 'Compiler installer SHA256 mismatch. No installer was run.'
}
$signature = Get-AuthenticodeSignature -LiteralPath $download
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne $lock.publisher) {
    throw 'Official publisher signature verification failed. No installer was run.'
}
if ($ToolDirectory.Contains('"')) { throw 'Tool path cannot contain quotes.' }
Write-Host "Installing the verified Inno Setup compiler for this user only: $ToolDirectory"
$arguments = '/CURRENTUSER /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /TASKS="" /DIR="' + $ToolDirectory + '" /LOG="' + (Join-Path $cache 'install.log') + '"'
$process = Start-Process -FilePath $download -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $compiler)) { throw "Compiler installation failed: $($process.ExitCode)" }
if ((Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash -ne $lock.isccSha256) { throw 'Installed compiler hash differs from the pinned version.' }
Write-Output $compiler
