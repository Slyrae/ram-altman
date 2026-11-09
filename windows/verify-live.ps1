<#
.SYNOPSIS
Plans, or explicitly runs, natural Task Scheduler and Gmail delivery verification.
.DESCRIPTION
The default is read-only planning. -Run sends one test email to the configured
sender, then permits the normal production task to email its configured recipient.
All sends come from natural Task Scheduler triggers. Existing daily send history
is retained. Gmail acceptance receipts are saved locally; this script does not
read Gmail or claim that the recipient opened or received a message.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TaskName,
    [switch]$Run,
    [switch]$PlanOnly,
    [ValidateRange(30,180)][int]$SendTimeoutSeconds = 180,
    [ValidateRange(60,360)][int]$RepeatTimeoutSeconds = 360
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Live verification requires Windows.' }
if ($Run -and $PlanOnly) { throw 'Choose -Run or -PlanOnly.' }
$repositoryPath = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not $ConfigPath) { $ConfigPath = Join-Path $repositoryPath 'private\config.json' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
. (Join-Path $PSScriptRoot 'TaskSupport.ps1')
Import-Module (Join-Path $PSScriptRoot 'RamAltman.psm1') -Force
$identity = Get-RamAltmanTaskIdentity -RepositoryPath $repositoryPath
if (-not $TaskName) { $TaskName = $identity.TaskName }
Assert-RamAltmanTaskName -Name $TaskName
$entryPath = Join-Path $PSScriptRoot 'ram-altman.ps1'
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not $Run) {
    $configPresent = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    $method = $null
    $clientPresent = $false
    $tokenPresent = $false
    $configurationError = $null
    if ($configPresent) {
        try {
            $previewConfig = Read-RamAltmanConfig -Path $ConfigPath -Preview
            $method = $previewConfig.DeliveryMethod
            if ($previewConfig.GmailClientPath) { $clientPresent = Test-Path -LiteralPath $previewConfig.GmailClientPath -PathType Leaf }
            if ($previewConfig.GmailTokenPath) { $tokenPresent = Test-Path -LiteralPath $previewConfig.GmailTokenPath -PathType Leaf }
        } catch { $configurationError = $_.Exception.Message }
    }
    [pscustomobject]@{
        Mode = 'PlanOnly'
        ConfigPath = $ConfigPath
        ProductionTaskName = $TaskName
        ConfigurationPresent = [bool]$configPresent
        DeliveryMethod = $method
        DesktopClientFilePresent = [bool]$clientPresent
        EncryptedTokenFilePresent = [bool]$tokenPresent
        ConfigurationError = $configurationError
        RealMailSent = $false
        PlannedSteps = @(
            'Require existing local Gmail OAuth authorization; turn production off during the self-test.'
            'Register a unique self-addressed test task and wait for its natural one-minute trigger.'
            'Save the self-test provider receipt and remove only that unique test task.'
            'Enable production and wait for its natural trigger, retaining any matching receipt already sent today.'
            'Wait for a later natural AlreadySent check to demonstrate the daily duplicate guard.'
            'Verify Disabled exits without state changes and leaves no owned process; turn production back on.'
            'Save local provider receipts and task evidence; Gmail Sent-folder confirmation remains a separate step.'
        )
        Execute = 'Run this script with -Run after Gmail setup has completed.'
    }
    return
}

Import-Module ScheduledTasks -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'GmailOAuth.psm1') -Force
$config = Read-RamAltmanConfig -Path $ConfigPath
if ($config.DeliveryMethod -ne 'GmailOAuth') { throw 'Live verification requires DeliveryMethod=GmailOAuth.' }
if (-not (Test-RamAltmanGmailToken -Path $config.GmailTokenPath -ExpectedSender $config.Sender)) {
    throw 'Local Gmail authorization is missing or belongs to another sender. Complete Setup.cmd before using -Run.'
}
$productionTask = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $productionTask) {
    Assert-RamAltmanOwnedTask -Task $productionTask -Description $identity.Description -Executable $executable -EntryPath $entryPath
}

$verificationId = [guid]::NewGuid().ToString('N')
$verificationDirectory = Join-Path $repositoryPath ('private\verification\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $verificationId.Substring(0,8))
[void][IO.Directory]::CreateDirectory($verificationDirectory)
$receiptPath = Join-Path $verificationDirectory 'live-verification.json'
$selfConfigPath = Join-Path $verificationDirectory 'self-test-config.json'
$selfTaskName = $identity.TaskName + '-LiveVerify-' + $verificationId.Substring(0,8)
Assert-RamAltmanTaskName -Name $selfTaskName
if ($null -ne (Get-ScheduledTask -TaskPath '\' -TaskName $selfTaskName -ErrorAction SilentlyContinue)) {
    throw 'The unique verification task name is already in use. No task was changed.'
}
$script:verificationSteps = New-Object 'System.Collections.Generic.List[object]'
$report = [ordered]@{
    Version = 1
    StartedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    CompletedAtUtc = $null
    Passed = $false
    ConfigPath = $ConfigPath
    ProductionTaskName = $TaskName
    TestTaskName = $selfTaskName
    VerificationDirectory = $verificationDirectory
    Sender = $config.Sender
    ProductionRecipient = $config.Recipient
    ExternalGmailReadPerformed = $false
    SentFolderConfirmationPending = $true
    ProofMeaning = 'Provider acceptance plus local scheduler/state evidence; external Sent-folder confirmation is separate.'
    SourceSha256 = @{
        Core = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'RamAltman.psm1') -Algorithm SHA256).Hash
        GmailOAuth = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'GmailOAuth.psm1') -Algorithm SHA256).Hash
        VerificationHarness = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    }
    SelfTestLastDelivery = $null
    ProductionLastDelivery = $null
    ReusedExistingTodayReceipt = $false
    TestTaskRemoved = $false
    ProductionOn = $false
    Failure = $null
    CleanupErrors = @()
    Steps = @()
}
$testTaskTouched = $false
$productionTouched = $false
$completed = $false

function Save-VerificationReport {
    $report.Steps = $script:verificationSteps.ToArray()
    $temporary = $receiptPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($report | ConvertTo-Json -Depth 18), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($receiptPath)) {
            [IO.File]::Replace($temporary, $receiptPath, [Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($temporary, $receiptPath) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Add-VerificationStep([string]$Name, $Evidence) {
    $script:verificationSteps.Add([pscustomobject]@{
        Name = $Name
        CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Evidence = $Evidence
    })
    Save-VerificationReport
    Write-Host ('Verified: ' + $Name)
}

function Read-LiveState([string]$StateDirectory) {
    $path = Join-Path $StateDirectory 'state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { throw "Delivery state is unreadable. It was retained: $path" }
}

function Get-LiveTaskEvidence([string]$Name) {
    $task = Get-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction Stop
    Assert-RamAltmanOwnedTask -Task $task -Description $identity.Description -Executable $executable -EntryPath $entryPath
    $info = Get-ScheduledTaskInfo -TaskPath '\' -TaskName $Name -ErrorAction Stop
    [pscustomobject]@{
        Name = $Name
        State = [string]$task.State
        Enabled = [bool]$task.Settings.Enabled
        LastRunTime = $info.LastRunTime.ToString('o')
        LastRunTimeUtc = $info.LastRunTime.ToUniversalTime().ToString('o')
        LastTaskResult = [long]$info.LastTaskResult
        NextRunTime = $info.NextRunTime.ToString('o')
    }
}

function Assert-MatchingProviderReceipt($State, $ExpectedConfig) {
    if ($null -eq $State -or $null -eq $State.PSObject.Properties['LastDelivery']) { throw 'Sent state has no saved provider receipt; daily history was retained.' }
    $delivery = $State.LastDelivery
    foreach ($field in @('Provider','Sender','Recipient','MessageId','BodySha256','Subject','AcceptedAtUtc','TotalRamBytes','AvailableRamBytes')) {
        if ($null -eq $delivery.PSObject.Properties[$field]) { throw "Provider receipt lacks $field; daily history was retained." }
    }
    if ($delivery.Provider -ne 'GmailOAuth' -or $delivery.Sender -ne $ExpectedConfig.Sender -or $delivery.Recipient -ne $ExpectedConfig.Recipient) {
        throw 'Today''s saved send receipt does not match the configured Gmail sender/recipient. It will not be reset or bypassed.'
    }
    if ([string]::IsNullOrWhiteSpace($delivery.MessageId) -or $delivery.BodySha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Provider message identity or body hash is missing. Daily history was retained.'
    }
}

function Wait-NaturalSent([string]$Name, $ExpectedConfig, [DateTimeOffset]$RegisteredAt, [bool]$AllowExistingTodayReceipt) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($SendTimeoutSeconds)
    $nextProgress = [DateTimeOffset]::MinValue
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $state = Read-LiveState $ExpectedConfig.StateDirectory
        $today = [DateTimeOffset]::Now.ToString('yyyy-MM-dd')
        if ($null -ne $state -and $state.LastDate -eq $today) {
            if ($state.DeliveryStatus -in @('Sending','Uncertain')) {
                if ($state.DeliveryStatus -eq 'Uncertain') { throw 'Delivery is uncertain. The daily guard will be retained; no forced retry will occur.' }
            } elseif ($state.DeliveryStatus -eq 'Sent') {
                Assert-MatchingProviderReceipt $state $ExpectedConfig
                $task = Get-LiveTaskEvidence $Name
                $lastRun = [DateTimeOffset]::Parse($task.LastRunTimeUtc)
                $naturalRunObserved = $lastRun -ge $RegisteredAt.AddSeconds(-2) -and $task.LastTaskResult -eq 0 -and $task.State -ne 'Running'
                if ($AllowExistingTodayReceipt -or $naturalRunObserved) {
                    return [pscustomobject]@{ State = $state; Task = $task; NaturalRunObserved = $naturalRunObserved }
                }
            }
        }
        if ([DateTimeOffset]::UtcNow -ge $nextProgress) {
            Write-Host ('Waiting for the natural Task Scheduler trigger: ' + $Name)
            $nextProgress = [DateTimeOffset]::UtcNow.AddSeconds(15)
        }
        Start-Sleep -Seconds 3
    }
    throw "Natural scheduled delivery was not confirmed within $SendTimeoutSeconds seconds. Check RAM eligibility, Gmail authorization, and Task Scheduler; no daily history was reset."
}

function Get-StateFileManifest([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return '' }
    (@(Get-ChildItem -LiteralPath $Directory -File -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join "`n")
}

function Remove-SelfTestTask {
    if (-not $testTaskTouched) { return }
    if (Test-Path -LiteralPath $selfConfigPath -PathType Leaf) {
        & (Join-Path $PSScriptRoot 'disable.ps1') -ConfigPath $selfConfigPath -TaskName $selfTaskName
    }
    & (Join-Path $PSScriptRoot 'uninstall-task.ps1') -TaskName $selfTaskName
    if ($null -ne (Get-ScheduledTask -TaskPath '\' -TaskName $selfTaskName -ErrorAction SilentlyContinue)) { throw 'The owned verification task was not removed.' }
    $report.TestTaskRemoved = $true
}

try {
    Save-VerificationReport
    $productionTouched = $true
    & (Join-Path $PSScriptRoot 'disable.ps1') -ConfigPath $ConfigPath -TaskName $TaskName
    Add-VerificationStep 'Production paused before self-test' @{ DailyHistoryReset = $false }
    $selfConfig = $config.PSObject.Copy()
    $selfConfig.Recipient = $config.Sender
    $selfConfig.Enabled = $true
    $selfConfig.StateDirectory = Join-Path $verificationDirectory 'self-test-state'
    [IO.File]::WriteAllText($selfConfigPath, ($selfConfig | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $null = Read-RamAltmanConfig -Path $selfConfigPath
    $testTaskTouched = $true
    $selfRegisteredAt = [DateTimeOffset]::UtcNow
    & (Join-Path $PSScriptRoot 'install-task.ps1') -ConfigPath $selfConfigPath -TaskName $selfTaskName -IntervalMinutes 5
    $selfResult = Wait-NaturalSent $selfTaskName $selfConfig $selfRegisteredAt $false
    $report.SelfTestLastDelivery = $selfResult.State.LastDelivery
    Add-VerificationStep 'Natural scheduled self-addressed Gmail test accepted' @{
        ConfigPath = $selfConfigPath
        StatePath = (Join-Path $selfConfig.StateDirectory 'state.json')
        Task = $selfResult.Task
        LastDelivery = $selfResult.State.LastDelivery
    }
    Remove-SelfTestTask
    Add-VerificationStep 'Self-test task removed with receipt retained' @{ Removed = $report.TestTaskRemoved; TaskName = $selfTaskName }

    $beforeProduction = Read-LiveState $config.StateDirectory
    $existingToday = $null -ne $beforeProduction -and $beforeProduction.LastDate -eq [DateTimeOffset]::Now.ToString('yyyy-MM-dd') -and $beforeProduction.DeliveryStatus -eq 'Sent'
    if ($existingToday) { Assert-MatchingProviderReceipt $beforeProduction $config }
    $productionRegisteredAt = [DateTimeOffset]::UtcNow
    & (Join-Path $PSScriptRoot 'enable.ps1') -ConfigPath $ConfigPath -TaskName $TaskName
    $productionResult = Wait-NaturalSent $TaskName $config $productionRegisteredAt $existingToday
    $report.ProductionLastDelivery = $productionResult.State.LastDelivery
    $report.ReusedExistingTodayReceipt = [bool]$existingToday
    Add-VerificationStep 'Configured production Gmail acceptance receipt confirmed' @{
        ReusedExistingTodayReceipt = [bool]$existingToday
        StatePath = (Join-Path $config.StateDirectory 'state.json')
        LastDelivery = $productionResult.State.LastDelivery
        Task = $productionResult.Task
    }

    $receiptId = [string]$productionResult.State.LastDelivery.MessageId
    $receiptDate = [string]$productionResult.State.LastDate
    $firstRun = [DateTimeOffset]::Parse($productionResult.Task.LastRunTimeUtc)
    if ($existingToday) { $firstRun = $productionRegisteredAt.AddSeconds(-2) }
    $repeatDeadline = [DateTimeOffset]::UtcNow.AddSeconds($RepeatTimeoutSeconds)
    $nextProgress = [DateTimeOffset]::MinValue
    $repeatEvidence = $null
    while ([DateTimeOffset]::UtcNow -lt $repeatDeadline) {
        if ([DateTimeOffset]::Now.ToString('yyyy-MM-dd') -ne $receiptDate) { throw 'The local calendar day changed during duplicate-guard verification. Daily history was retained.' }
        $current = Read-LiveState $config.StateDirectory
        if ($null -eq $current -or $current.DeliveryStatus -ne 'Sent' -or $current.LastDelivery.MessageId -ne $receiptId) {
            throw 'The saved production receipt changed during duplicate-guard verification.'
        }
        $taskEvidence = Get-LiveTaskEvidence $TaskName
        $laterRun = [DateTimeOffset]::Parse($taskEvidence.LastRunTimeUtc) -gt $firstRun -and $taskEvidence.LastTaskResult -eq 0 -and $taskEvidence.State -ne 'Running'
        $usagePath = Join-Path $config.StateDirectory 'usage.csv'
        $usageCount = 0
        if (Test-Path -LiteralPath $usagePath) { $usageCount = [math]::Max(0, @(Get-Content -LiteralPath $usagePath).Count - 1) }
        $alreadySentEvent = $null
        $eventPath = Join-Path $config.StateDirectory 'events.jsonl'
        if (Test-Path -LiteralPath $eventPath) {
            foreach ($line in @(Get-Content -LiteralPath $eventPath -Tail 2000)) {
                if (-not $line) { continue }
                $event = $line | ConvertFrom-Json
                if ($event.outcome -eq 'AlreadySent' -and [DateTimeOffset]::Parse($event.timestamp) -gt $firstRun) { $alreadySentEvent = $event }
            }
        }
        if ($laterRun -and $usageCount -ge 2 -and $null -ne $alreadySentEvent) {
            $repeatEvidence = @{ Task = $taskEvidence; UsageRows = $usageCount; AlreadySentEvent = $alreadySentEvent; MessageIdUnchanged = $receiptId }
            break
        }
        if ([DateTimeOffset]::UtcNow -ge $nextProgress) {
            Write-Host 'Waiting for the later natural automatic check to prove the daily duplicate guard.'
            $nextProgress = [DateTimeOffset]::UtcNow.AddSeconds(15)
        }
        Start-Sleep -Seconds 3
    }
    if ($null -eq $repeatEvidence) { throw "A later natural AlreadySent check was not confirmed within $RepeatTimeoutSeconds seconds." }
    Add-VerificationStep 'Later natural check preserved the same daily Gmail receipt' $repeatEvidence

    & (Join-Path $PSScriptRoot 'disable.ps1') -ConfigPath $ConfigPath -TaskName $TaskName
    $offConfig = Read-RamAltmanConfig -Path $ConfigPath -Preview
    $offTask = Get-LiveTaskEvidence $TaskName
    $expectedArguments = @(Get-RamAltmanTaskArguments -EntryPath $entryPath -ConfigPath $ConfigPath)
    $owned = @(Get-RamAltmanLauncherSnapshot -Executable $executable -Arguments $expectedArguments -OwnerSid $identity.Sid)
    if ($offConfig.Enabled -or $offTask.Enabled -or $offTask.State -eq 'Running' -or $owned.Count -ne 0) { throw 'Off verification found an enabled task/configuration or an owned monitoring process.' }
    $beforeDisabledEntry = Get-StateFileManifest $config.StateDirectory
    $disabledOutput = @(& $executable -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entryPath -ConfigPath $ConfigPath 2>&1)
    $disabledExit = $LASTEXITCODE
    $afterDisabledEntry = Get-StateFileManifest $config.StateDirectory
    $ownedAfterDisabledEntry = @(Get-RamAltmanLauncherSnapshot -Executable $executable -Arguments $expectedArguments -OwnerSid $identity.Sid)
    if ($disabledExit -ne 0 -or ($disabledOutput -join "`n") -notmatch 'Result: Disabled' -or $beforeDisabledEntry -cne $afterDisabledEntry -or $ownedAfterDisabledEntry.Count -ne 0) {
        throw 'Disabled entry did not exit cleanly without modifying its saved state/logs.'
    }
    Add-VerificationStep 'Off stopped automatic activity and manual entry preserved all state' @{
        ConfigEnabled = $offConfig.Enabled
        Task = $offTask
        OwnedProcessCount = $owned.Count
        OwnedProcessCountAfterDisabledEntry = $ownedAfterDisabledEntry.Count
        DisabledEntryExitCode = $disabledExit
        DisabledEntryOutput = $disabledOutput -join "`n"
        StateAndLogHashesUnchanged = $true
    }

    & (Join-Path $PSScriptRoot 'enable.ps1') -ConfigPath $ConfigPath -TaskName $TaskName
    $onConfig = Read-RamAltmanConfig -Path $ConfigPath
    $onTask = Get-LiveTaskEvidence $TaskName
    $finalState = Read-LiveState $config.StateDirectory
    if (-not $onConfig.Enabled -or -not $onTask.Enabled -or $finalState.LastDelivery.MessageId -ne $receiptId) { throw 'Re-enabling did not preserve the daily receipt and enabled production state.' }
    $report.ProductionOn = $true
    Add-VerificationStep 'Production returned to On with the same daily guard' @{ Task = $onTask; MessageId = $receiptId; ConfigEnabled = $onConfig.Enabled }
    $completed = $true
    $report.Passed = $true
} catch {
    $report.Failure = $_.Exception.Message
    Write-Error ('Live verification failed: ' + $_.Exception.Message) -ErrorAction Continue
} finally {
    if ($testTaskTouched -and -not $report.TestTaskRemoved) {
        try { Remove-SelfTestTask }
        catch { $report.CleanupErrors += ('Verification task cleanup: ' + $_.Exception.Message) }
    }
    if (-not $completed -and $productionTouched) {
        try { & (Join-Path $PSScriptRoot 'disable.ps1') -ConfigPath $ConfigPath -TaskName $TaskName }
        catch { $report.CleanupErrors += ('Production shutdown: ' + $_.Exception.Message) }
        $report.ProductionOn = $false
    }
    $report.CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-VerificationReport
}
Write-Host ('Verification receipt: ' + $receiptPath)
if (-not $completed -or $report.CleanupErrors.Count -gt 0) { throw 'Live verification did not complete. Inspect the saved receipt and retained daily history before retrying.' }
Write-Host 'Natural scheduler verification passed. Production is On. Gmail Sent-folder confirmation remains a separate step.'
[pscustomobject]@{ Passed = $true; ReceiptPath = $receiptPath; ProductionOn = $report.ProductionOn; SelfTestMessageId = $report.SelfTestLastDelivery.MessageId; ProductionMessageId = $report.ProductionLastDelivery.MessageId; SentFolderConfirmationPending = $true }
