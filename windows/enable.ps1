<# Enables this checkout's monitor without changing saved credentials or history. #>
[CmdletBinding()]
param([string]$ConfigPath, [string]$TaskName)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This control requires Windows.' }
. (Join-Path $PSScriptRoot 'TaskSupport.ps1')
Import-Module (Join-Path $PSScriptRoot 'RamAltman.psm1') -Force
$repositoryPath = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $ConfigPath) { $ConfigPath = Join-Path $repositoryPath 'private\config.json' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$lock = Enter-RamAltmanConfigControlLock -Path $ConfigPath
$changed = $false
try {
    $config = Read-RamAltmanConfig -Path $ConfigPath
    if ($config.DeliveryMethod -eq 'GmailOAuth') {
        Import-Module (Join-Path $PSScriptRoot 'GmailOAuth.psm1') -Force
        if (-not (Test-RamAltmanGmailToken -Path $config.GmailTokenPath -ExpectedSender $config.Sender)) { throw 'Google sign-in is missing or belongs to another sender. Run Setup.cmd to connect Gmail.' }
    }
    $previous = Update-RamAltmanConfigEnabled -Path $ConfigPath -Enabled $true -ControlLock $lock
    $changed = $true
    & (Join-Path $PSScriptRoot 'install-task.ps1') -ConfigPath $ConfigPath -TaskName $TaskName
    Write-Host 'RamAltman is ON. Automatic checks run every five minutes while this Windows account is logged on.'
    Write-Host 'Use Disable.cmd to stop all monitoring and email activity.'
} catch {
    if ($changed) { $null = Update-RamAltmanConfigEnabled -Path $ConfigPath -Enabled $previous -ControlLock $lock }
    throw
} finally { $lock.Dispose() }
