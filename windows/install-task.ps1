<#
.SYNOPSIS
Installs a per-user RAM check every five minutes and when that user logs on.
.DESCRIPTION
Runs with the current user's interactive token and does not require an
administrator password. That user must be logged on. No task is installed by
-PlanOnly; it prints the task XML for inspection.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TaskName,
    [ValidateRange(1, 1440)][int]$IntervalMinutes = 5,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows.' }
. (Join-Path $PSScriptRoot 'TaskSupport.ps1')
Import-Module (Join-Path $PSScriptRoot 'RamAltman.psm1') -Force
Import-Module ScheduledTasks -ErrorAction Stop

$repositoryPath = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $repositoryPath 'private\config.json' }
$entryPath = Join-Path $PSScriptRoot 'ram-altman.ps1'
if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) { throw "Monitor script missing: $entryPath" }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Configuration not found: $ConfigPath. Run Setup.cmd first." }
$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
$config = Read-RamAltmanConfig -Path $resolvedConfigPath
if (-not $config.Enabled) { throw 'RamAltman is disabled. Use Enable.cmd to enable the configuration and scheduled task together.' }
$identity = Get-RamAltmanTaskIdentity -RepositoryPath $repositoryPath
if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = $identity.TaskName }
Assert-RamAltmanTaskName -Name $TaskName
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = Get-RamAltmanTaskArguments -EntryPath $entryPath -ConfigPath $resolvedConfigPath
$existing = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Assert-RamAltmanOwnedTask -Task $existing -Description $identity.Description -Executable $executable -EntryPath $entryPath
}

$action = New-ScheduledTaskAction -Execute $executable -Argument $arguments -WorkingDirectory $repositoryPath
$repeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$logon = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$principal = New-ScheduledTaskPrincipal -UserId $identity.Sid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -Hidden
$definition = New-ScheduledTask -Action $action -Trigger @($repeat, $logon) -Settings $settings -Principal $principal -Description $identity.Description
if ($PlanOnly) {
    # Export-ScheduledTask accepts an unregistered task object via -InputObject.
    Export-ScheduledTask -InputObject $definition
    return
}

$null = Register-ScheduledTask -TaskPath '\' -TaskName $TaskName -InputObject $definition -Force
Write-Host "Installed task: $TaskName"
Write-Host "Checks every $IntervalMinutes minutes, starting in about one minute, and at logon."
Write-Host "Runs only while $($identity.Name) is logged on."
Write-Host "Configuration: $resolvedConfigPath"
