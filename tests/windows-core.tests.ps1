#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$modulePath = Join-Path $RepositoryRoot 'windows\RamAltman.psm1'
Import-Module $modulePath -Force
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:fixtureNumber = 0
$script:sendCount = 0
$fixtureRoot = Join-Path $RepositoryRoot ('validation\core-fixtures-{0}-{1}' -f $PID, (Get-Date -Format 'yyyyMMdd-HHmmss'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$testNow = [DateTimeOffset]::Parse('2026-11-09T12:00:00-05:00')

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Expected true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ.')
    if ($Actual -ne $Expected) { throw ('{0} Expected [{1}], got [{2}].' -f $Message, $Expected, $Actual) }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message = 'Expected an exception.')
    $didThrow = $false
    try { & $Action | Out-Null } catch { $didThrow = $true }
    if (-not $didThrow) { throw $Message }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null })
        Write-Host ('PASS {0}' -f $Name)
    } catch {
        $detail = $_.Exception.Message
        $script:results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $detail })
        Write-Host ('FAIL {0}: {1}' -f $Name, $detail) -ForegroundColor Red
    }
}

function New-TestMemory {
    param([long]$Total = 1000000, [long]$Available = 500000)
    [pscustomobject]@{
        TotalBytes = $Total
        AvailableBytes = $Available
        UsedBytes = $Total - $Available
        AvailablePercent = if ($Total -gt 0) { 100.0 * $Available / $Total } else { 0.0 }
    }
}

function New-TestConfig {
    param([hashtable]$Override = @{}, [switch]$Preview)
    $script:fixtureNumber++
    $folder = Join-Path $fixtureRoot ('case-{0}' -f $script:fixtureNumber)
    [void][IO.Directory]::CreateDirectory($folder)
    $settings = [ordered]@{
        Recipient = 'recipient@example.invalid'
        Sender = 'sender@example.invalid'
        SenderName = 'Windows RAM tests'
        ThresholdPercent = 10
        SmtpHost = '127.0.0.1'
        SmtpPort = 2525
        UseSsl = $false
        CredentialPath = ''
        StateDirectory = 'state'
        TimeoutSeconds = 5
    }
    foreach ($key in $Override.Keys) { $settings[$key] = $Override[$key] }
    $configFile = Join-Path $folder 'config.json'
    [IO.File]::WriteAllText($configFile, ($settings | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Read-RamAltmanConfig -Path $configFile -Preview:$Preview
}

$sendFake = {
    param($Config, $Email)
    $script:sendCount++
    Assert-True (-not [string]::IsNullOrWhiteSpace($Email.Subject)) 'Email needs a subject.'
    Assert-True ($Email.Body -match 'Hi Sam,') 'Email needs the greeting.'
}

Test-Case 'Native Windows physical-memory snapshot is sane' {
    $memory = Get-RamAltmanMemory
    Assert-True ($memory.TotalBytes -gt 0) 'Total memory must be positive.'
    Assert-True ($memory.AvailableBytes -ge 0 -and $memory.AvailableBytes -le $memory.TotalBytes) 'Available memory outside physical bounds.'
    Assert-Equal $memory.UsedBytes ($memory.TotalBytes - $memory.AvailableBytes) 'Used memory accounting.'
    Assert-True ($memory.AvailablePercent -ge 0 -and $memory.AvailablePercent -le 100) 'Available percentage outside bounds.'
}

Test-Case 'Config paths resolve relative to the configuration file' {
    $config = New-TestConfig
    Assert-True ([IO.Path]::IsPathRooted($config.StateDirectory)) 'State directory must be absolute.'
    Assert-True ($config.StateDirectory.StartsWith($fixtureRoot, [StringComparison]::OrdinalIgnoreCase)) 'State path escaped its fixture.'
    Assert-Equal $config.ThresholdPercent 10
}

Test-Case 'Legacy SMTP configuration defaults to enabled SMTP delivery' {
    $config = New-TestConfig
    Assert-Equal $config.DeliveryMethod 'Smtp'
    Assert-Equal $config.Enabled $true
}

Test-Case 'Enabled accepts only JSON booleans' {
    Assert-Throws { New-TestConfig @{ Enabled = 'false' } }
    Assert-Throws { New-TestConfig @{ Enabled = 0 } }
    Assert-Equal (New-TestConfig @{ Enabled = $true }).Enabled $true
    Assert-Equal (New-TestConfig @{ Enabled = $false }).Enabled $false
}

Test-Case 'Unknown delivery methods are rejected' {
    Assert-Throws { New-TestConfig @{ DeliveryMethod = 'UnknownTransport' } }
}

Test-Case 'Disabled SMTP delivery creates no state or logs and never sends' {
    $config = New-TestConfig @{ Enabled = $false }
    $beforeCount = $script:sendCount
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake
    Assert-Equal $result.Outcome 'Disabled'
    Assert-Equal $script:sendCount $beforeCount
    Assert-True (-not (Test-Path -LiteralPath $config.StateDirectory)) 'Disabled delivery created state or logs.'
}

Test-Case 'Disabled Gmail delivery never opens OAuth files or creates state' {
    $config = New-TestConfig @{
        Enabled = $false
        DeliveryMethod = 'GmailOAuth'
        GmailClientPath = 'missing-client.json'
        GmailTokenPath = 'missing-token.xml'
    } -Preview
    $beforeCount = $script:sendCount
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake
    Assert-Equal $result.Outcome 'Disabled'
    Assert-Equal $script:sendCount $beforeCount
    Assert-True (-not (Test-Path -LiteralPath $config.StateDirectory)) 'Disabled Gmail delivery wrote state.'
}

Test-Case 'Disabled command-line entry exits cleanly before memory reporting or authorization' {
    $config = New-TestConfig @{
        Enabled = $false
        DeliveryMethod = 'GmailOAuth'
        GmailClientPath = 'missing-client.json'
        GmailTokenPath = 'missing-token.xml'
    } -Preview
    $configPath = Join-Path (Split-Path -Parent $config.StateDirectory) 'config.json'
    $entry = Join-Path $RepositoryRoot 'windows\ram-altman.ps1'
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output = @(& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -ConfigPath $configPath 2>&1)
    Assert-Equal $LASTEXITCODE 0 'Disabled entry must succeed without authorization.'
    Assert-True (($output -join "`n") -match 'Result: Disabled') 'Entry did not report disabled.'
    Assert-True (($output -join "`n") -notmatch '(?m)^(Total:|Available:|VRAM)') 'Disabled entry performed memory reporting.'
    Assert-True (-not (Test-Path -LiteralPath $config.StateDirectory)) 'Disabled entry created state.'
}

Test-Case 'Gmail OAuth preview needs neither authorization nor client/token files' {
    $config = New-TestConfig @{
        DeliveryMethod = 'GmailOAuth'
        SmtpHost = ''
        UseSsl = $true
        GmailClientPath = 'not-authorized-client.json'
        GmailTokenPath = 'not-authorized-token.xml'
    } -Preview
    $beforeCount = $script:sendCount
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake -DryRun
    Assert-Equal $result.Outcome 'Preview'
    Assert-True (-not [string]::IsNullOrWhiteSpace($result.Email.Body)) 'Gmail preview body missing.'
    Assert-Equal $script:sendCount $beforeCount
    Assert-True (-not (Test-Path -LiteralPath $config.StateDirectory)) 'Gmail preview wrote state.'
}

Test-Case 'Gmail OAuth preview allows missing client and token settings' {
    $config = New-TestConfig @{
        DeliveryMethod = 'GmailOAuth'
        SmtpHost = ''
        UseSsl = $true
        GmailClientPath = ''
        GmailTokenPath = ''
    } -Preview
    Assert-Equal $config.DeliveryMethod 'GmailOAuth'
}

Test-Case 'Live Gmail OAuth requires client and token file settings' {
    Assert-Throws { New-TestConfig @{ DeliveryMethod = 'GmailOAuth'; GmailClientPath = ''; GmailTokenPath = '' } }
    Assert-Throws { New-TestConfig @{ DeliveryMethod = 'GmailOAuth'; GmailClientPath = 'missing-client.json'; GmailTokenPath = 'missing-token.xml' } }
}

Test-Case 'Gmail OAuth relative paths resolve beside the config without requiring SMTP' {
    $config = New-TestConfig @{
        DeliveryMethod = 'GmailOAuth'
        SmtpHost = ''
        UseSsl = $true
        GmailClientPath = 'oauth\client.json'
        GmailTokenPath = 'oauth\token.xml'
    } -Preview
    Assert-True ([IO.Path]::IsPathRooted($config.GmailClientPath)) 'Gmail client path is not absolute.'
    Assert-True ([IO.Path]::IsPathRooted($config.GmailTokenPath)) 'Gmail token path is not absolute.'
    Assert-True ($config.GmailClientPath.StartsWith($fixtureRoot, [StringComparison]::OrdinalIgnoreCase)) 'Gmail client path escaped its config fixture.'
    Assert-True ($config.GmailTokenPath.StartsWith($fixtureRoot, [StringComparison]::OrdinalIgnoreCase)) 'Gmail token path escaped its config fixture.'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $config.GmailClientPath))
    [IO.File]::WriteAllText($config.GmailClientPath, '{"installed":{"client_id":"test.invalid","client_secret":"not-a-real-secret"}}')
    [IO.File]::WriteAllText($config.GmailTokenPath, 'Synthetic existence-only token fixture; never imported or sent.')
    $configPath = Join-Path (Split-Path -Parent $config.StateDirectory) 'config.json'
    $liveConfig = Read-RamAltmanConfig -Path $configPath
    Assert-Equal $liveConfig.GmailClientPath $config.GmailClientPath
    Assert-Equal $liveConfig.GmailTokenPath $config.GmailTokenPath
}

Test-Case 'Threshold below zero is rejected' { Assert-Throws { New-TestConfig @{ ThresholdPercent = -1 } } }
Test-Case 'Threshold above 100 is rejected' { Assert-Throws { New-TestConfig @{ ThresholdPercent = 101 } } }
Test-Case 'Nonnumeric threshold is rejected' { Assert-Throws { New-TestConfig @{ ThresholdPercent = 'ten' } } }
Test-Case 'SMTP port zero is rejected' { Assert-Throws { New-TestConfig @{ SmtpPort = 0 } } }
Test-Case 'A text TLS flag is rejected instead of silently coerced' { Assert-Throws { New-TestConfig @{ UseSsl = 'false' } } }
Test-Case 'A nonpositive SMTP timeout is rejected' { Assert-Throws { New-TestConfig @{ TimeoutSeconds = 0 } } }
Test-Case 'Implicit SSL port 465 is rejected' { Assert-Throws { New-TestConfig @{ SmtpPort = 465; UseSsl = $true } } }
Test-Case 'Remote plaintext SMTP is rejected' { Assert-Throws { New-TestConfig @{ SmtpHost = 'smtp.example.invalid'; UseSsl = $false } } }
Test-Case 'Missing recipient is rejected for a live configuration' { Assert-Throws { New-TestConfig @{ Recipient = '' } } }
Test-Case 'Header injection is rejected' { Assert-Throws { New-TestConfig @{ Sender = "sender@example.invalid`r`nBcc: other@example.invalid" } } }
Test-Case 'Malformed JSON is rejected' {
    $path = Join-Path $fixtureRoot 'malformed.json'
    [IO.File]::WriteAllText($path, '{ broken')
    Assert-Throws { Read-RamAltmanConfig -Path $path }
}

Test-Case 'Dry run creates no state or logs and never opens credentials' {
    $config = New-TestConfig
    $config.CredentialPath = Join-Path $fixtureRoot 'this-credential-does-not-exist.xml'
    $beforeCount = $script:sendCount
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake -DryRun
    Assert-Equal $result.Outcome 'Preview'
    Assert-True (-not [string]::IsNullOrWhiteSpace($result.Email.Body)) 'Preview body missing.'
    Assert-True (-not (Test-Path -LiteralPath $config.StateDirectory)) 'Dry run wrote state.'
    Assert-Equal $script:sendCount $beforeCount 'Dry run called send.'
}

Test-Case 'Less than 10 percent remains below threshold even when display rounds to 10.0' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available 99999) -Now $testNow -SendAction $sendFake
    Assert-Equal $result.Outcome 'BelowThreshold'
    Assert-Equal $script:sendCount $beforeCount
}

Test-Case 'Exactly 10 percent sends one email' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available 100000) -Now $testNow -SendAction $sendFake
    Assert-Equal $result.Outcome 'Sent'
    Assert-Equal $script:sendCount ($beforeCount + 1)
}

Test-Case 'Just above 10 percent sends one email' {
    $config = New-TestConfig
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available 100001) -Now $testNow -SendAction $sendFake
    Assert-Equal $result.Outcome 'Sent'
}

Test-Case 'Zero available memory does not send at the default threshold' {
    $config = New-TestConfig
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available 0) -Now $testNow -SendAction $sendFake
    Assert-Equal $result.Outcome 'BelowThreshold'
}

Test-Case 'Completely available physical memory sends' {
    $config = New-TestConfig
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available 1000000) -Now $testNow -SendAction $sendFake
    Assert-Equal $result.Outcome 'Sent'
}

Test-Case 'Repeated runs and a state reload send at most once on the same local day' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    $first = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake
    $second = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddHours(2) -SendAction $sendFake
    $third = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddHours(3) -SendAction $sendFake
    Assert-Equal $first.Outcome 'Sent'
    Assert-Equal $second.Outcome 'AlreadySent'
    Assert-Equal $third.Outcome 'AlreadySent'
    Assert-Equal $script:sendCount ($beforeCount + 1)
    Assert-True (Test-Path -LiteralPath (Join-Path $config.StateDirectory 'state.json')) 'Daily state was not persisted.'
}

Test-Case 'Turning delivery off preserves existing state and all logs byte for byte' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake | Out-Null
    $before = @(Get-ChildItem -LiteralPath $config.StateDirectory -File | Sort-Object Name | ForEach-Object {
        $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join "`n"
    $config.Enabled = $false
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddDays(1) -SendAction $sendFake
    $after = @(Get-ChildItem -LiteralPath $config.StateDirectory -File | Sort-Object Name | ForEach-Object {
        $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join "`n"
    Assert-Equal $result.Outcome 'Disabled'
    Assert-Equal $after $before 'Disabled delivery changed an existing state/log file.'
    Assert-Equal $script:sendCount ($beforeCount + 1)
}

Test-Case 'Gmail delivery shares the same durable daily guard using an injected transport' {
    $config = New-TestConfig @{
        DeliveryMethod = 'GmailOAuth'
        GmailClientPath = 'unused-client.json'
        GmailTokenPath = 'unused-token.xml'
    } -Preview
    $beforeCount = $script:sendCount
    $first = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake
    $second = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddMinutes(5) -SendAction $sendFake
    Assert-Equal $first.Outcome 'Sent'
    Assert-Equal $second.Outcome 'AlreadySent'
    Assert-Equal $script:sendCount ($beforeCount + 1)
}

Test-Case 'Gmail acceptance receipt preserves provider identity body hash and RAM evidence across repeat checks' {
    $config = New-TestConfig @{
        DeliveryMethod = 'GmailOAuth'
        GmailClientPath = 'unused-client.json'
        GmailTokenPath = 'unused-token.xml'
    } -Preview
    $capture = @{ Email = $null; Attempts = 0 }
    $transport = {
        param($Config, $Email)
        $capture.Email = $Email
        $capture.Attempts++
        [pscustomobject]@{ Id = 'synthetic-gmail-message-123'; ThreadId = 'synthetic-gmail-thread-456' }
    }.GetNewClosure()
    $memory = New-TestMemory -Available 123456
    $result = Invoke-RamAltmanCheck -Config $config -Memory $memory -Now $testNow -SendAction $transport
    Assert-Equal $result.Outcome 'Sent'
    Assert-Equal $capture.Attempts 1
    $statePath = Join-Path $config.StateDirectory 'state.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $receipt = $state.LastDelivery
    Assert-Equal $receipt.Provider 'GmailOAuth'
    Assert-Equal $receipt.Sender $config.Sender
    Assert-Equal $receipt.Recipient $config.Recipient
    Assert-Equal $receipt.Subject $capture.Email.Subject
    Assert-Equal $receipt.MessageId 'synthetic-gmail-message-123'
    Assert-Equal $receipt.ThreadId 'synthetic-gmail-thread-456'
    Assert-Equal $receipt.TotalRamBytes $memory.TotalBytes
    Assert-Equal $receipt.AvailableRamBytes $memory.AvailableBytes
    [void][DateTimeOffset]::Parse($receipt.AcceptedAtUtc, [Globalization.CultureInfo]::InvariantCulture)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $expectedHash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($capture.Email.Body))).Replace('-', '') }
    finally { $hasher.Dispose() }
    Assert-Equal $receipt.BodySha256 $expectedHash 'Persisted hash must identify the exact submitted UTF-8 email body.'
    $stateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    $again = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available 222222) -Now $testNow.AddMinutes(5) -SendAction $transport
    Assert-Equal $again.Outcome 'AlreadySent'
    Assert-Equal $capture.Attempts 1
    Assert-Equal (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash $stateHash 'Repeat check must preserve the accepted receipt.'
}

Test-Case 'Missing Gmail authorization fails before reserving a daily delivery' {
    $config = New-TestConfig @{
        DeliveryMethod = 'GmailOAuth'
        GmailClientPath = 'missing-client.json'
        GmailTokenPath = 'missing-token.xml'
    } -Preview
    Assert-Throws { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $config.StateDirectory 'state.json'))) 'Failed Gmail authorization reserved a daily send.'
}

Test-Case 'A new local calendar day permits the next email' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake | Out-Null
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddDays(1) -SendAction $sendFake
    Assert-Equal $result.Outcome 'Sent'
    Assert-Equal $script:sendCount ($beforeCount + 2)
}

Test-Case 'A backward calendar clock cannot bypass the daily send guard' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake | Out-Null
    try { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddDays(-1) -SendAction $sendFake | Out-Null } catch { }
    Assert-Equal $script:sendCount ($beforeCount + 1)
}

Test-Case 'Malformed durable state blocks delivery' {
    $config = New-TestConfig
    [void][IO.Directory]::CreateDirectory($config.StateDirectory)
    [IO.File]::WriteAllText((Join-Path $config.StateDirectory 'state.json'), '{ interrupted write')
    $beforeCount = $script:sendCount
    Assert-Throws { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake }
    Assert-Equal $script:sendCount $beforeCount
}

Test-Case 'An unfinished durable send journal blocks a second same-day send' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake | Out-Null
    $stateFile = Join-Path $config.StateDirectory 'state.json'
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $state.DeliveryStatus = 'Sending'
    [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Depth 20))
    Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddMinutes(5) -SendAction $sendFake | Out-Null
    Assert-Equal $script:sendCount ($beforeCount + 1)
}

Test-Case 'An exclusive state lock prevents overlapping delivery' {
    $config = New-TestConfig
    [void][IO.Directory]::CreateDirectory($config.StateDirectory)
    $lock = [IO.File]::Open((Join-Path $config.StateDirectory 'monitor.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $beforeCount = $script:sendCount
    try {
        $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $sendFake
        Assert-Equal $result.Outcome 'Busy'
        Assert-Equal $script:sendCount $beforeCount
    } finally { $lock.Dispose() }
}

Test-Case 'An ambiguous SMTP failure reserves the day and prevents duplicate retries' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    $ambiguous = { param($Config, $Email); $script:sendCount++; throw 'Connection interrupted after possible SMTP acceptance.' }
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $ambiguous
    Assert-Equal $result.Outcome 'DeliveryUncertain'
    $again = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddMinutes(5) -SendAction $sendFake
    Assert-True ($again.Outcome -in @('AlreadySent', 'DeliveryUncertain')) 'Uncertain attempt was not held.'
    Assert-Equal $script:sendCount ($beforeCount + 1)
}

Test-Case 'A definite SMTP rejection permits a later retry' {
    $config = New-TestConfig
    $reject = { param($Config, $Email); throw (New-Object System.Net.Mail.SmtpException([System.Net.Mail.SmtpStatusCode]::MailboxUnavailable, 'Definite test rejection.')) }
    try { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $reject | Out-Null } catch { }
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddMinutes(5) -SendAction $sendFake
    Assert-Equal $result.Outcome 'Sent'
}

Test-Case 'A refused SMTP connection is retryable before delivery begins' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    $refused = { param($Config, $Email); throw (New-Object Net.Sockets.SocketException(10061)) }
    try { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $refused | Out-Null } catch { }
    $stateFile = Join-Path $config.StateDirectory 'state.json'
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    Assert-Equal $state.DeliveryStatus 'Rejected' 'Connection refusal should be retryable.'
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddMinutes(5) -SendAction $sendFake
    Assert-Equal $result.Outcome 'Sent'
    Assert-Equal $script:sendCount ($beforeCount + 1)
}

Test-Case 'Host-unreachable after possible SMTP acceptance remains uncertain without a same-day retry' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    $unreachable = { param($Config, $Email); throw (New-Object Net.Sockets.SocketException(10065)) }
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $unreachable
    Assert-Equal $result.Outcome 'DeliveryUncertain'
    $again = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddMinutes(5) -SendAction $sendFake
    Assert-Equal $again.Outcome 'DeliveryUncertain'
    Assert-Equal $script:sendCount $beforeCount 'Host-unreachable failure must not open another delivery attempt.'
}

Test-Case 'Network-unreachable after possible SMTP acceptance remains uncertain without a same-day retry' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    $unreachable = { param($Config, $Email); throw (New-Object Net.Sockets.SocketException(10051)) }
    $result = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow -SendAction $unreachable
    Assert-Equal $result.Outcome 'DeliveryUncertain'
    $again = Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddMinutes(5) -SendAction $sendFake
    Assert-Equal $again.Outcome 'DeliveryUncertain'
    Assert-Equal $script:sendCount $beforeCount 'Network-unreachable failure must not open another delivery attempt.'
}

Test-Case 'Missing live credentials fail before reserving delivery or sending' {
    $config = New-TestConfig
    $config.CredentialPath = Join-Path $fixtureRoot 'missing-smtp-credential.xml'
    Assert-Throws { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $config.StateDirectory 'state.json'))) 'Missing credentials reserved the daily attempt.'
}

Test-Case 'Invalid physical-memory bounds fail before delivery' {
    $config = New-TestConfig
    $beforeCount = $script:sendCount
    Assert-Throws { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Total 0 -Available 0) -Now $testNow -SendAction $sendFake }
    Assert-Throws { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available 1000001) -Now $testNow -SendAction $sendFake }
    Assert-Throws { Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available -1) -Now $testNow -SendAction $sendFake }
    Assert-Equal $script:sendCount $beforeCount
}

Test-Case 'Oversized sample history is bounded after the next check' {
    $config = New-TestConfig
    [void][IO.Directory]::CreateDirectory($config.StateDirectory)
    $logPath = Join-Path $config.StateDirectory 'usage.csv'
    $header = "timestamp,total_bytes,used_bytes,available_bytes,available_pct`r`n"
    $row = "2026-11-09T12:00:00.0000000-05:00,1000000,950000,50000,5.0`r`n"
    [IO.File]::WriteAllText($logPath, $header + ($row * 220000), (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-Item -LiteralPath $logPath).Length -gt 10MB) 'Test log was not oversized.'
    Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory -Available 50000) -Now $testNow -SendAction $sendFake | Out-Null
    Assert-True ((Get-Item -LiteralPath $logPath).Length -le 10MB) 'Sample history exceeds its bound.'
    Assert-True (@(Get-Content -LiteralPath $logPath).Count -le 10002) 'Trim retained too many samples.'
}

Test-Case 'Email variety covers a full body cycle without immediate repeats' {
    $config = New-TestConfig
    $bodies = New-Object 'System.Collections.Generic.List[string]'
    $collector = {
        param($Config, $Email)
        $paragraphs = [regex]::Split($Email.Body, '\r?\n\r?\n')
        $bodies.Add($paragraphs[3])
    }.GetNewClosure()
    for ($day = 0; $day -lt 20; $day++) {
        Invoke-RamAltmanCheck -Config $config -Memory (New-TestMemory) -Now $testNow.AddDays($day) -SendAction $collector | Out-Null
    }
    Assert-Equal $bodies.Count 20
    Assert-Equal (@($bodies | Select-Object -First 10 -Unique).Count) 10 'Body templates should form a full cycle.'
    for ($index = 1; $index -lt $bodies.Count; $index++) { Assert-True ($bodies[$index] -ne $bodies[$index - 1]) 'Consecutive message bodies repeated.' }
}

Test-Case 'Every email template ends at the sender signature and excludes the rejected explanatory footer' {
    $config = New-TestConfig
    $state = @{}
    $vram = [pscustomobject]@{
        Supported = $true
        Adapters = @([pscustomobject]@{ Name = 'Synthetic GPU'; TotalBytes = 8GB; AvailableBytes = 4GB })
    }
    $forbidden = 'Snapshot of available|reclaimable|standby|measurement of how long|Sent automatically|Reply if|at most once per local calendar|VRAM is GPU memory|every browser tab|light workloads|Windows Task Scheduler|Today.s forecast|global allocation department'
    for ($day = 0; $day -lt 10; $day++) {
        $email = New-RamAltmanEmail -Config $config -Memory (New-TestMemory) -State $state -Vram $vram
        Assert-True ($email.Body -notmatch $forbidden) 'An email template contains a rejected explanatory/footer phrase.'
        Assert-True ($email.Body.TrimEnd().EndsWith($config.SenderName, [StringComparison]::Ordinal)) 'Email must end at the configured sender name.'
        $lines = $email.Body.TrimEnd() -split '\r?\n'
        Assert-True ($lines[$lines.Count - 2] -match ',$') 'The signoff must immediately precede the sender name.'
    }
}

$failed = @($script:results | Where-Object { -not $_.Passed })
$summary = [pscustomobject]@{
    TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    ModuleSha256 = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
    Total = $script:results.Count
    Passed = $script:results.Count - $failed.Count
    Failed = $failed.Count
    ExternalEmailSent = $false
    FixtureRoot = $fixtureRoot
    Cases = $script:results.ToArray()
}
if ([string]::IsNullOrWhiteSpace($ResultPath)) { $ResultPath = Join-Path $RepositoryRoot 'validation\windows-core-results.json' }
[IO.File]::WriteAllText($ResultPath, ($summary | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host ('{0} passed; {1} failed. Results: {2}' -f $summary.Passed, $summary.Failed, $ResultPath)
if ($failed.Count -gt 0) { exit 1 }
