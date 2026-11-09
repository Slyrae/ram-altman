<# Exercises the real setup flow in an isolated copy with mocked Google sign-in.
   No browser, Google request, SMTP request, or production task is used. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
$repositoryPath = Split-Path $PSScriptRoot -Parent
$suffix = [guid]::NewGuid().ToString('N')
$fixture = Join-Path $repositoryPath ('private\setup-test-' + $suffix)
$windows = Join-Path $fixture 'windows'; $private = Join-Path $fixture 'private'
$null = New-Item -ItemType Directory -Path $windows, $private
foreach ($name in @('setup.ps1','TaskSupport.ps1','RamAltman.psm1','ram-altman.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $windows $name) }
@'
function Start-RamAltmanGmailAuthorization {
    param([string]$ClientPath, [string]$TokenPath, [string]$ExpectedSender)
    if ($ExpectedSender -cne 'sender@example.invalid') { throw 'Setup supplied wrong sender identity' }
    if (-not (Test-Path -LiteralPath $ClientPath -PathType Leaf)) { throw 'Setup did not copy client JSON before authorization' }
    [IO.File]::WriteAllText($TokenPath, 'Mock authorization result: not a real token')
    [pscustomobject]@{Authorized=$true}
}
Export-ModuleMember -Function Start-RamAltmanGmailAuthorization
'@ | Set-Content -LiteralPath (Join-Path $windows 'GmailOAuth.psm1') -Encoding UTF8
$downloadedClient = Join-Path $fixture 'downloaded Desktop client.json'
'{"installed":{"client_id":"test-only.apps.googleusercontent.com","client_secret":"not-a-real-secret","redirect_uris":["http://localhost"]}}' | Set-Content -LiteralPath $downloadedClient -Encoding UTF8
$originalClientHash = (Get-FileHash -LiteralPath $downloadedClient -Algorithm SHA256).Hash
$configPath = Join-Path $private 'config.json'
$original = [ordered]@{Recipient='recipient@example.invalid';Sender='sender@example.invalid';SenderName='Saved display name';Enabled=$false;DeliveryMethod='Smtp';ThresholdPercent=10;SmtpHost='smtp.example.invalid';SmtpPort=587;UseSsl=$true;CredentialPath='';StateDirectory='state';GmailClientPath='gmail-client.json';GmailTokenPath='gmail.token.xml'}
$original | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
$answers = New-Object 'System.Collections.Generic.Queue[string]'
foreach ($answer in @('y','','','','',$downloadedClient)) { $answers.Enqueue($answer) }
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if ($AsSecureString) { throw 'GmailOAuth setup incorrectly requested a password' }
    if ($answers.Count -eq 0) { throw ('Unexpected setup prompt: ' + $Prompt) }
    $answers.Dequeue()
}
$taskName = 'RamAltman-SetupTest-' + $suffix
& (Join-Path $windows 'setup.ps1') -ConfigureOnly -TaskName $taskName
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$passed = New-Object 'System.Collections.Generic.List[string]'
function Assert-Test([bool]$Condition,[string]$Name) { if (-not $Condition) { throw ('FAIL: '+$Name) }; $passed.Add($Name); Write-Host ('PASS: '+$Name) }
Assert-Test ($config.Recipient -ceq $original.Recipient -and $config.Sender -ceq $original.Sender -and $config.SenderName -ceq $original.SenderName) 'Enter retains recipient, sender, and display name from private config'
Assert-Test ($config.DeliveryMethod -ceq 'GmailOAuth') 'GmailOAuth is default even for an existing SMTP configuration'
Assert-Test (-not $config.Enabled) 'Setup saves monitoring disabled until explicit enable'
Assert-Test ([IO.Path]::GetFullPath($config.StateDirectory) -eq (Join-Path $private 'state')) 'Setup retains the existing daily history directory'
Assert-Test ($answers.Count -eq 0) 'Gmail setup consumes expected prompts and never asks for a password'
$client = Join-Path $private $config.GmailClientPath
$token = Join-Path $private $config.GmailTokenPath
Assert-Test ((Test-Path -LiteralPath $client -PathType Leaf) -and (Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash -eq $originalClientHash) 'Desktop OAuth client copied into private directory without content changes'
Assert-Test ((Get-FileHash -LiteralPath $downloadedClient -Algorithm SHA256).Hash -eq $originalClientHash) 'Original downloaded client JSON preserved'
Assert-Test (Test-Path -LiteralPath $token -PathType Leaf) 'Authorization receives private token destination and expected sender'
Assert-Test (@(Get-ChildItem -LiteralPath $private -Filter 'smtp*.xml').Count -eq 0) 'Gmail path creates no SMTP password file'
Assert-Test (@(Get-ChildItem -LiteralPath $private -Filter 'config.previous.*.json').Count -eq 1) 'Previous private configuration backed up'
Assert-Test ($null -eq (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)) 'ConfigureOnly does not register or enable a scheduled task'
Import-Module (Join-Path $windows 'RamAltman.psm1') -Force
$null = Read-RamAltmanConfig -Path $configPath
$passed.Add('Saved Gmail config validates with config-relative client and token paths')
Write-Host 'PASS: Saved Gmail config validates with config-relative client and token paths'
$result = [ordered]@{Timestamp=(Get-Date).ToString('o');PowerShellVersion=$PSVersionTable.PSVersion.ToString();FixtureDirectory=$fixture;Passed=$passed.Count;Checks=@($passed.ToArray());GoogleAuthorization='Mocked';EmailSent=$false;ProductionConfigurationModified=$false}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $repositoryPath 'validation\setup-results.json') -Encoding UTF8
Write-Host ("Passed {0} setup tests." -f $passed.Count)
