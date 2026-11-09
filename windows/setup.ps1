<# Interactive local setup. Google tokens and SMTP passwords stay DPAPI-encrypted. #>
[CmdletBinding()]
param([switch]$ConfigureOnly, [string]$TaskName)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This setup requires Windows.' }
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'RamAltman.psm1') -Force
. (Join-Path $PSScriptRoot 'TaskSupport.ps1')
Import-Module ScheduledTasks -ErrorAction Stop
$repositoryPath = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$privatePath = Join-Path $repositoryPath 'private'
$configPath = Join-Path $privatePath 'config.json'

function Read-RequiredValue {
    param([string]$Prompt, [string]$DefaultValue = '')
    $label = $Prompt
    if ($DefaultValue) { $label += ' [' + $DefaultValue + ']' }
    do {
        $value = (Read-Host $label).Trim()
        if (-not $value -and $DefaultValue) { $value = $DefaultValue }
    } while ([string]::IsNullOrWhiteSpace($value))
    $value
}

Write-Host 'RamAltman for Windows'
Write-Host 'Checks every five minutes; reports at most once per day when available RAM is at least 10%.'
Write-Host 'Setup connects your account and previews the message; setup does not send email.'
$defaults = @{ Recipient = ''; Sender = ''; SenderName = ''; SmtpHost = ''; SmtpPort = 587; GmailClientPath = ''; StateDirectory = 'state'; ThresholdPercent = 10; TimeoutSeconds = 30 }
if (Test-Path -LiteralPath $configPath) {
    if ((Read-Host 'Update the saved configuration (a backup will be kept)? [y/N]') -notmatch '^(?i:y|yes)$') { return }
    $existingConfig = Read-RamAltmanConfig -Path $configPath -Preview
    foreach ($setting in @('Recipient', 'Sender', 'SenderName', 'SmtpHost', 'SmtpPort', 'GmailClientPath', 'StateDirectory', 'ThresholdPercent', 'TimeoutSeconds')) {
        $defaults[$setting] = $existingConfig.$setting
    }
}
$recipient = Read-RequiredValue -Prompt 'Recipient email address' -DefaultValue $defaults.Recipient
$sender = Read-RequiredValue -Prompt 'Your sender email address' -DefaultValue $defaults.Sender
$namePrompt = 'Your display name (optional)'
if ($defaults.SenderName) { $namePrompt += ' [' + $defaults.SenderName + ']' }
$senderName = (Read-Host $namePrompt).Trim()
if (-not $senderName) { $senderName = $defaults.SenderName }
Write-Host ''
Write-Host '1. GmailOAuth: sign in to Google in your browser (recommended; no Gmail password or app password).'
Write-Host '2. SMTP: use a provider''s STARTTLS server and password/app password.'
$methodChoice = (Read-Host 'Delivery method [1]').Trim()
switch -Regex ($methodChoice) {
    '^(|1|GmailOAuth)$' { $deliveryMethod = 'GmailOAuth'; break }
    '^(2|Smtp)$' { $deliveryMethod = 'Smtp'; break }
    default { throw 'Choose 1 for GmailOAuth or 2 for SMTP.' }
}

$smtpHost = ''; $smtpPort = 587; $smtpUsername = '-'; $clientSource = ''
if ($deliveryMethod -eq 'GmailOAuth') {
    Write-Host ''
    Write-Host 'One-time Google setup at https://console.cloud.google.com/:'
    Write-Host '  Create/select a project, enable Gmail API, and configure the OAuth consent screen.'
    Write-Host '  Create an OAuth client with application type Desktop app, then download its JSON file.'
    Write-Host '  For an External app in Testing, add your sender as a test user. Testing refresh tokens expire after seven days.'
    Write-Host '  For continuing daily use, publish the consent screen to Production. Google may require verification or show an unverified-app notice.'
    $clientDefault = ''
    if ($defaults.GmailClientPath -and (Test-Path -LiteralPath $defaults.GmailClientPath -PathType Leaf)) { $clientDefault = $defaults.GmailClientPath }
    $clientSource = Read-RequiredValue -Prompt 'Downloaded Desktop OAuth client JSON path' -DefaultValue $clientDefault
    $clientSource = $clientSource.Trim('"')
    if (-not (Test-Path -LiteralPath $clientSource -PathType Leaf)) { throw 'The selected OAuth client JSON file does not exist.' }
    $clientSource = (Resolve-Path -LiteralPath $clientSource).ProviderPath
} else {
    $smtpHost = Read-RequiredValue -Prompt 'SMTP server hostname' -DefaultValue $defaults.SmtpHost
    $portText = (Read-Host ('SMTP STARTTLS port [' + $defaults.SmtpPort + ']')).Trim()
    $smtpPort = [int]$defaults.SmtpPort
    if ($portText -and (-not [int]::TryParse($portText, [ref]$smtpPort) -or $smtpPort -lt 1 -or $smtpPort -gt 65535)) { throw 'SMTP port must be between 1 and 65535.' }
    if ($smtpPort -eq 465) { throw 'Port 465 uses implicit TLS. Use the provider''s STARTTLS endpoint, usually port 587.' }
    $smtpUsername = (Read-Host "SMTP username [${sender}] (type - for no authentication)").Trim()
    if (-not $smtpUsername) { $smtpUsername = $sender }
}

$null = New-Item -ItemType Directory -Path $privatePath -Force
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
foreach ($principalSid in @($sid, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'))) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($principalSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $privatePath -AclObject $acl
$suffix = [Guid]::NewGuid().ToString('N')
$candidatePath = Join-Path $privatePath ('.setup-' + $suffix + '.json')
$newFiles = New-Object 'System.Collections.Generic.List[string]'
$saved = $false
$credentialName = ''; $clientName = 'gmail-client.json'; $tokenName = 'gmail.token.xml'
$identity = Get-RamAltmanTaskIdentity -RepositoryPath $repositoryPath
if (-not $TaskName) { $TaskName = $identity.TaskName }
Assert-RamAltmanTaskName -Name $TaskName
$existingTask = Get-ScheduledTask -TaskPath '\' -TaskName $TaskName -ErrorAction SilentlyContinue
$wasEnabled = $false
if ($null -ne $existingTask) {
    $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-RamAltmanOwnedTask -Task $existingTask -Description $identity.Description -Executable $executable -EntryPath (Join-Path $PSScriptRoot 'ram-altman.ps1')
    $wasEnabled = [bool]$existingTask.Settings.Enabled
}
try {
    if ($null -ne $existingTask) {
        $null = Disable-ScheduledTask -TaskPath '\' -TaskName $TaskName
        Stop-ScheduledTask -TaskPath '\' -TaskName $TaskName
        Write-Host 'Paused the existing task while updating its configuration.'
    }
    if ($deliveryMethod -eq 'GmailOAuth') {
        $clientDestination = Join-Path $privatePath $clientName
        if ([IO.Path]::GetFullPath($clientSource) -ne [IO.Path]::GetFullPath($clientDestination)) {
            if (Test-Path -LiteralPath $clientDestination) { $clientName = 'gmail-client.' + $suffix + '.json'; $clientDestination = Join-Path $privatePath $clientName }
            Copy-Item -LiteralPath $clientSource -Destination $clientDestination -ErrorAction Stop
            $newFiles.Add($clientDestination)
        }
        if (Test-Path -LiteralPath (Join-Path $privatePath $tokenName)) { $tokenName = 'gmail-token.' + $suffix + '.dpapi' }
    } elseif ($smtpUsername -ne '-') {
        $password = Read-Host 'SMTP password or app password (hidden)' -AsSecureString
        if ($password.Length -eq 0) { throw 'An SMTP password is required for authenticated SMTP.' }
        $credential = New-Object Management.Automation.PSCredential($smtpUsername, $password)
        $credentialName = 'smtp.credential.xml'
        if (Test-Path -LiteralPath (Join-Path $privatePath $credentialName)) { $credentialName = 'smtp.' + $suffix + '.credential.xml' }
        $credentialFile = Join-Path $privatePath $credentialName
        $newFiles.Add($credentialFile)
        $credential | Export-Clixml -LiteralPath $credentialFile -Encoding UTF8
        $credential = $null; $password = $null
    }
    $configuration = [ordered]@{
        Recipient = $recipient; Sender = $sender; SenderName = $senderName
        ThresholdPercent = $defaults.ThresholdPercent; Enabled = $false; DeliveryMethod = $deliveryMethod
        GmailClientPath = $clientName; GmailTokenPath = $tokenName
        SmtpHost = $smtpHost; SmtpPort = $smtpPort; UseSsl = $true
        CredentialPath = $credentialName; StateDirectory = $defaults.StateDirectory; TimeoutSeconds = $defaults.TimeoutSeconds
    }
    $configuration | ConvertTo-Json | Set-Content -LiteralPath $candidatePath -Encoding UTF8
    $null = Read-RamAltmanConfig -Path $candidatePath -Preview
    if ($deliveryMethod -eq 'GmailOAuth') {
        Import-Module (Join-Path $PSScriptRoot 'GmailOAuth.psm1') -Force
        $tokenDestination = Join-Path $privatePath $tokenName
        $newFiles.Add($tokenDestination)
        Write-Host 'Opening Google sign-in. Choose the sender account and approve Gmail sending access.'
        $null = Start-RamAltmanGmailAuthorization -ClientPath $clientDestination -TokenPath $tokenDestination -ExpectedSender $sender
    }
    $null = Read-RamAltmanConfig -Path $candidatePath
    Write-Host ''
    Write-Host 'Preview of an email using current memory figures:'
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'ram-altman.ps1') -ConfigPath $candidatePath -DryRun
    if ($LASTEXITCODE -ne 0) { throw 'Email preview failed. Configuration was not replaced.' }
    if (Test-Path -LiteralPath $configPath) { [IO.File]::Replace($candidatePath, $configPath, (Join-Path $privatePath ('config.previous.' + $suffix + '.json'))) }
    else { [IO.File]::Move($candidatePath, $configPath) }
    $saved = $true
    Write-Host "Saved configuration: $configPath"
    if (-not $ConfigureOnly) {
        Write-Host 'Enabling permits automatic email delivery, starting in about one minute.'
        if ((Read-Host 'Turn RamAltman ON now? [y/N]') -match '^(?i:y|yes)$') { & (Join-Path $PSScriptRoot 'enable.ps1') -ConfigPath $configPath -TaskName $TaskName }
        else { Write-Host 'RamAltman is OFF. Use Enable.cmd when ready.' }
    } else { Write-Host 'RamAltman is OFF. Use Enable.cmd when ready.' }
} finally {
    if (Test-Path -LiteralPath $candidatePath) { Remove-Item -LiteralPath $candidatePath -Force }
    if (-not $saved) {
        foreach ($newFile in $newFiles) { if (Test-Path -LiteralPath $newFile) { Remove-Item -LiteralPath $newFile -Force } }
        if ($wasEnabled) { $null = Enable-ScheduledTask -TaskPath '\' -TaskName $TaskName; Write-Host 'The previous configuration and enabled task were restored.' }
    }
}
