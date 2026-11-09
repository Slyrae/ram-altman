<# Removes only the task owned by this Windows account and this checkout. #>
[CmdletBinding()]
param([string]$TaskName)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This uninstaller requires Windows.' }
. (Join-Path $PSScriptRoot 'TaskSupport.ps1')
Import-Module ScheduledTasks -ErrorAction Stop
$repositoryPath = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$identity = Get-RamAltmanTaskIdentity -RepositoryPath $repositoryPath
if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = $identity.TaskName }
Assert-RamAltmanTaskName -Name $TaskName
$task = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $task) { Write-Host "No task installed: $TaskName"; return }
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$entryPath = Join-Path $PSScriptRoot 'ram-altman.ps1'
Assert-RamAltmanOwnedTask -Task $task -Description $identity.Description -Executable $executable -EntryPath $entryPath
Stop-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskPath '\' -TaskName $TaskName -Confirm:$false
Write-Host "Removed task: $TaskName"
Write-Host 'Configuration, encrypted credentials, and usage history were retained.'
