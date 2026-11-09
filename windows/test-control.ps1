<# Runs reversible control tests in an isolated checkout with harmless loop scripts.
   Never connects to Google or SMTP, and never edits the production configuration. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module ScheduledTasks
$repositoryPath = Split-Path $PSScriptRoot -Parent
$suffix = [guid]::NewGuid().ToString('N')
$fixture = Join-Path $repositoryPath ('private\control-test-' + $suffix)
$windows = Join-Path $fixture 'windows'
$private = Join-Path $fixture 'private'
$null = New-Item -ItemType Directory -Path $windows, $private
foreach ($name in @('TaskSupport.ps1', 'enable.ps1', 'disable.ps1', 'install-task.ps1', 'RamAltman.psm1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $windows $name)
}
. (Join-Path $windows 'TaskSupport.ps1')
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$configPath = Join-Path $private 'config.json'
$configuration = [ordered]@{
    Recipient = 'recipient@example.invalid'; Sender = 'sender@example.invalid'; SenderName = 'Control test'
    Enabled = $false; DeliveryMethod = 'Smtp'; ThresholdPercent = 100
    SmtpHost = '127.0.0.1'; SmtpPort = 2525; UseSsl = $false
    CredentialPath = ''; StateDirectory = 'state'
}
$configuration | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
$passed = New-Object 'System.Collections.Generic.List[string]'
function Assert-Test([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ('FAIL: ' + $Name) }
    $passed.Add($Name)
    Write-Host ('PASS: ' + $Name)
}
function Read-Enabled { (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).Enabled }
$previous = Update-RamAltmanConfigEnabled -Path $configPath -Enabled $true
Assert-Test (-not $previous -and (Read-Enabled)) 'Atomic enable returns previous state and saves true'
$previous = Update-RamAltmanConfigEnabled -Path $configPath -Enabled $false
Assert-Test ($previous -and -not (Read-Enabled)) 'Atomic disable returns previous state and saves false'
$before = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
Assert-Test ($before.Recipient -eq $configuration.Recipient -and $before.StateDirectory -eq 'state') 'Controls preserve other configuration fields'

$entryPath = Join-Path $windows 'ram-altman.ps1'
$childPath = Join-Path $windows 'harmless-child.ps1'
@'
param([string]$MarkerPath)
[IO.File]::WriteAllText($MarkerPath + '.pid', $PID.ToString())
while ($true) { [IO.File]::WriteAllText($MarkerPath, (Get-Date).ToString('o')); Start-Sleep -Milliseconds 200 }
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8
@'
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText($ConfigPath + '.launcher.pid', $PID.ToString())
$native = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$childPath = Join-Path $PSScriptRoot 'harmless-child.ps1'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $childPath + '" -MarkerPath "' + $ConfigPath + '.child-heartbeat"'
$null = Start-Process -FilePath $native -WindowStyle Hidden -ArgumentList $arguments -PassThru
while ($true) { [IO.File]::WriteAllText($ConfigPath + '.launcher-heartbeat', (Get-Date).ToString('o')); Start-Sleep -Milliseconds 200 }
'@ | Set-Content -LiteralPath $entryPath -Encoding UTF8
$taskName = 'RamAltman-ControlTest-' + $suffix
$unrelatedName = 'RamAltman-UnrelatedTest-' + $suffix
$registered = New-Object 'System.Collections.Generic.List[string]'
$identity = Get-RamAltmanTaskIdentity -RepositoryPath $fixture
$unrelatedMarker = Join-Path $private 'unrelated-heartbeat'
$unrelatedArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $childPath + '" -MarkerPath "' + $unrelatedMarker + '"'
$unrelatedTask = New-ScheduledTask -Action (New-ScheduledTaskAction -Execute $executable -Argument $unrelatedArgs) -Principal (New-ScheduledTaskPrincipal -UserId $identity.Sid -LogonType Interactive -RunLevel Limited) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3)) -Description 'Unrelated disposable task for preservation test'
$snapshots = @()
try {
    $null = Register-ScheduledTask -TaskPath '\' -TaskName $unrelatedName -InputObject $unrelatedTask
    $registered.Add($unrelatedName)
    Start-ScheduledTask -TaskPath '\' -TaskName $unrelatedName
    & (Join-Path $windows 'enable.ps1') -ConfigPath $configPath -TaskName $taskName
    $registered.Add($taskName)
    Assert-Test (Read-Enabled) 'Enable turns configuration on'
    $installed = Get-ScheduledTask -TaskPath '\' -TaskName $taskName
    Assert-Test ([bool]$installed.Settings.Enabled) 'Enable registers an enabled owned task'
    Start-ScheduledTask -TaskPath '\' -TaskName $taskName
    $deadline = (Get-Date).AddSeconds(20)
    do { Start-Sleep -Milliseconds 200 } while ((-not (Test-Path -LiteralPath ($configPath + '.child-heartbeat.pid')) -or -not (Test-Path -LiteralPath ($unrelatedMarker + '.pid'))) -and (Get-Date) -lt $deadline)
    Assert-Test ((Test-Path -LiteralPath ($configPath + '.child-heartbeat.pid')) -and (Test-Path -LiteralPath ($unrelatedMarker + '.pid'))) 'Owned launcher, its child, and unrelated task are running'
    $snapshots = @(Get-RamAltmanLauncherSnapshot -Executable $executable -Arguments @(Get-RamAltmanTaskArguments -EntryPath $entryPath -ConfigPath $configPath) -OwnerSid $identity.Sid)
    $launcherId = [int](Get-Content -LiteralPath ($configPath + '.launcher.pid'))
    $childId = [int](Get-Content -LiteralPath ($configPath + '.child-heartbeat.pid'))
    $unrelatedId = [int](Get-Content -LiteralPath ($unrelatedMarker + '.pid'))
    $snapshotIds = @($snapshots | ForEach-Object { $_.ProcessId })
    Assert-Test ($snapshotIds -contains $launcherId -and $snapshotIds -contains $childId -and $snapshotIds -notcontains $unrelatedId) 'Pre-stop snapshot identifies owned launcher and descendant while excluding unrelated process'
    $beforeUnrelated = Get-Content -LiteralPath $unrelatedMarker -Raw
    & (Join-Path $windows 'disable.ps1') -ConfigPath $configPath -TaskName $taskName
    Assert-Test (-not (Read-Enabled)) 'Disable turns configuration off'
    $stopped = Get-ScheduledTask -TaskPath '\' -TaskName $taskName
    Assert-Test (-not $stopped.Settings.Enabled -and [string]$stopped.State -ne 'Running') 'Owned task is disabled and stopped'
    Assert-Test (@($snapshots | Where-Object { $null -ne (Get-RamAltmanSnapshotProcess -Snapshot $_) }).Count -eq 0) 'Owned launcher and child have completely exited'
    Start-Sleep -Milliseconds 400
    $afterUnrelated = Get-Content -LiteralPath $unrelatedMarker -Raw
    $unrelatedAfter = Get-ScheduledTask -TaskPath '\' -TaskName $unrelatedName
    Assert-Test ($unrelatedAfter.Settings.Enabled -and [string]$unrelatedAfter.State -eq 'Running' -and $beforeUnrelated -ne $afterUnrelated) 'Unrelated running task and heartbeat are preserved'
    & (Join-Path $windows 'disable.ps1') -ConfigPath $configPath -TaskName $taskName
    Assert-Test (-not (Read-Enabled)) 'Repeated disable is idempotent'

    $failed = $false
    try { & (Join-Path $windows 'enable.ps1') -ConfigPath $configPath -TaskName $unrelatedName } catch { $failed = $true }
    Assert-Test ($failed -and -not (Read-Enabled)) 'Failed enable restores the previous disabled configuration'
    Assert-Test ((Get-ScheduledTask -TaskPath '\' -TaskName $unrelatedName).Description -eq 'Unrelated disposable task for preservation test') 'Task collision leaves unrelated definition unchanged'

    $configuration.DeliveryMethod = 'GmailOAuth'
    $configuration.Enabled = $true
    $configuration.GmailClientPath = 'missing-client.json'
    $configuration.GmailTokenPath = 'missing-token.dpapi'
    $configuration | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    & (Join-Path $windows 'disable.ps1') -ConfigPath $configPath -TaskName ('RamAltman-AbsentTest-' + $suffix)
    Assert-Test (-not (Read-Enabled)) 'Disable works before Gmail client/token files exist and without an installed task'
    Import-Module (Join-Path $windows 'RamAltman.psm1') -Force
    $disabledConfig = Read-RamAltmanConfig -Path $configPath -Preview
    $disabled = Invoke-RamAltmanCheck -Config $disabledConfig -Memory ([pscustomobject]@{ TotalBytes = 100; AvailableBytes = 100 }) -SendAction { throw 'Disabled monitor attempted email' }
    Assert-Test ($disabled.Outcome -eq 'Disabled') 'Manual disabled invocation exits before email/authentication work'
} finally {
    foreach ($name in $registered) {
        Stop-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
    foreach ($item in $snapshots) {
        $process = Get-RamAltmanSnapshotProcess -Snapshot $item
        if ($null -ne $process) { Stop-Process -InputObject $process -Force }
    }
}
Assert-Test (@($registered | Where-Object { $null -ne (Get-ScheduledTask -TaskPath '\' -TaskName $_ -ErrorAction SilentlyContinue) }).Count -eq 0) 'All disposable test tasks removed'
$result = [ordered]@{Timestamp=(Get-Date).ToString('o');PowerShellVersion=$PSVersionTable.PSVersion.ToString();FixtureDirectory=$fixture;Passed=$passed.Count;Checks=@($passed.ToArray());EmailSent=$false;GoogleContacted=$false;ProductionConfigurationModified=$false}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $repositoryPath 'validation\control-results.json') -Encoding UTF8
Write-Host ("Passed {0} control tests." -f $passed.Count)
