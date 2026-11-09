<# Turns off this checkout's monitor and stops its owned task/process tree. #>
[CmdletBinding()]
param([string]$ConfigPath, [string]$TaskName)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This control requires Windows.' }
. (Join-Path $PSScriptRoot 'TaskSupport.ps1')
Import-Module ScheduledTasks -ErrorAction Stop
$repositoryPath = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if (-not $ConfigPath) { $ConfigPath = Join-Path $repositoryPath 'private\config.json' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$identity = Get-RamAltmanTaskIdentity -RepositoryPath $repositoryPath
if (-not $TaskName) { $TaskName = $identity.TaskName }
Assert-RamAltmanTaskName -Name $TaskName
$lock = Enter-RamAltmanConfigControlLock -Path $ConfigPath
try {
    $null = Update-RamAltmanConfigEnabled -Path $ConfigPath -Enabled $false -ControlLock $lock
    Write-Host 'Automatic email delivery is OFF in the configuration.'
    $task = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $entryPath = Join-Path $PSScriptRoot 'ram-altman.ps1'
    $expectedArguments = @(Get-RamAltmanTaskArguments -EntryPath $entryPath -ConfigPath $ConfigPath)
    if ($null -ne $task) {
        Assert-RamAltmanOwnedTask -Task $task -Description $identity.Description -Executable $executable -EntryPath $entryPath
        $expectedArguments += [string]$task.Actions[0].Arguments
    }
    $snapshot = @(Get-RamAltmanLauncherSnapshot -Executable $executable -Arguments $expectedArguments -OwnerSid $identity.Sid)
    if ($null -ne $task) {
        $null = Disable-ScheduledTask -TaskPath '\' -TaskName $TaskName
        Stop-ScheduledTask -TaskPath '\' -TaskName $TaskName
    }
    $deadline = (Get-Date).AddSeconds(10)
    $cleanupAt = (Get-Date).AddSeconds(2)
    do {
        $fresh = @(Get-RamAltmanLauncherSnapshot -Executable $executable -Arguments $expectedArguments -OwnerSid $identity.Sid -PriorSnapshot $snapshot)
        foreach ($item in $fresh) {
            if (@($snapshot | Where-Object { $_.ProcessId -eq $item.ProcessId -and $_.StartTimeUtcTicks -eq $item.StartTimeUtcTicks }).Count -eq 0) { $snapshot += $item }
        }
        $remaining = @($snapshot | Where-Object { $null -ne (Get-RamAltmanSnapshotProcess -Snapshot $_) })
        if ($remaining.Count -gt 0 -and (Get-Date) -ge $cleanupAt) {
            # Only exact PID/start-time/executable matches from the pre-stop tree
            # are eligible. Never kill a newly reused PID or an unrelated app.
            foreach ($item in $remaining) {
                $process = Get-RamAltmanSnapshotProcess -Snapshot $item
                if ($null -ne $process) { Stop-Process -InputObject $process -Force -ErrorAction Stop }
            }
        }
        $currentTask = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
        $running = $null -ne $currentTask -and [string]$currentTask.State -eq 'Running'
        if (-not $running -and $remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    $remaining = @($snapshot | Where-Object { $null -ne (Get-RamAltmanSnapshotProcess -Snapshot $_) })
    $fresh = @(Get-RamAltmanLauncherSnapshot -Executable $executable -Arguments $expectedArguments -OwnerSid $identity.Sid -PriorSnapshot $snapshot)
    if ($fresh.Count -gt 0) { throw 'Email delivery is off, but a newly observed owned process has not stopped. Run Disable.cmd again before treating shutdown as complete.' }
    if ($running -or $remaining.Count -gt 0) { throw 'Email delivery is off, but an owned task or process has not stopped. Check Task Scheduler before treating shutdown as complete.' }
    if ($null -ne $currentTask -and $currentTask.Settings.Enabled) { throw 'Email delivery is off, but the task is still enabled. Check Task Scheduler.' }
    Write-Host 'RamAltman is completely OFF. Its scheduled task is stopped and disabled; no owned monitoring processes remain.'
    Write-Host 'Saved credentials and daily history were retained. Use Enable.cmd to turn it back on.'
} finally { $lock.Dispose() }
