<# Safe task-definition tests; -RegisterSmokeTask additionally runs a disposable
   task that writes a local marker file. No test uses SMTP or sends email. #>
[CmdletBinding()]
param([switch]$RegisterSmokeTask)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'TaskSupport.ps1')
$repositoryPath = Split-Path $PSScriptRoot -Parent
$fixturePath = Join-Path $repositoryPath ('private\scheduler-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixturePath
$passed = New-Object 'System.Collections.Generic.List[string]'
function Assert-Test {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $passed.Add($Name)
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    $caught = $false
    try { & $Action } catch { $caught = $true }
    Assert-Test -Condition $caught -Name $Name
}
$configPath = Join-Path $fixturePath 'fixture config.json'
@{
    Recipient = 'recipient@example.invalid'; Sender = 'sender@example.invalid'
    SenderName = 'Scheduler test'; ThresholdPercent = 100
    SmtpHost = '127.0.0.1'; SmtpPort = 2525; UseSsl = $false
    CredentialPath = ''; StateDirectory = 'state'
} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
$identity = Get-RamAltmanTaskIdentity -RepositoryPath $repositoryPath
$executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$entryPath = Join-Path $PSScriptRoot 'ram-altman.ps1'
$arguments = Get-RamAltmanTaskArguments -EntryPath $entryPath -ConfigPath $configPath
$uniqueTaskName = 'RamAltman-Test-' + [Guid]::NewGuid().ToString('N')

$xmlText = & (Join-Path $PSScriptRoot 'install-task.ps1') -ConfigPath $configPath -TaskName $uniqueTaskName -PlanOnly
[xml]$xml = $xmlText -join [Environment]::NewLine
$xmlText | Set-Content -LiteralPath (Join-Path $fixturePath 'plan.xml') -Encoding UTF8
$ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
$ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
function Read-TaskNode {
    param([string]$XPath)
    $node = $xml.SelectSingleNode($XPath, $ns)
    if ($null -eq $node) { return '' }
    $node.InnerText
}
Assert-Test ((Read-TaskNode '//t:Actions/t:Exec/t:Command') -eq $executable) 'Native Windows PowerShell executable'
Assert-Test ((Read-TaskNode '//t:Actions/t:Exec/t:Arguments') -ceq $arguments) 'Script and config paths with spaces quoted'
Assert-Test ((Read-TaskNode '//t:Actions/t:Exec/t:WorkingDirectory') -eq $repositoryPath) 'Explicit working directory'
Assert-Test ((Read-TaskNode '//t:TimeTrigger/t:Repetition/t:Interval') -eq 'PT5M') 'Five minute repeat interval'
Assert-Test ([string]::IsNullOrEmpty((Read-TaskNode '//t:TimeTrigger/t:Repetition/t:Duration'))) 'Repeat has no expiration duration'
Assert-Test ((Read-TaskNode '//t:LogonTrigger/t:UserId') -in @($identity.Name, $identity.Sid)) 'Logon trigger belongs to current account'
$principalUser = Read-TaskNode '//t:Principal/t:UserId'
# ScheduledTasks can canonicalize a SID to an account name when exporting XML.
if ($principalUser -match '^S-1-') { $principalSid = $principalUser } else {
    $principalSid = (New-Object Security.Principal.NTAccount($principalUser)).Translate([Security.Principal.SecurityIdentifier]).Value
}
Assert-Test ($principalSid -eq $identity.Sid) 'Principal resolves to current Windows SID'
Assert-Test ((Read-TaskNode '//t:Principal/t:LogonType') -eq 'InteractiveToken') 'Same user interactive token for DPAPI'
Assert-Test ((Read-TaskNode '//t:Principal/t:RunLevel') -eq 'LeastPrivilege') 'No elevation required'
Assert-Test ((Read-TaskNode '//t:MultipleInstancesPolicy') -eq 'IgnoreNew') 'Overlapping task runs ignored'
Assert-Test ((Read-TaskNode '//t:StartWhenAvailable') -eq 'true') 'Missed runs can start when available'
Assert-Test ((Read-TaskNode '//t:DisallowStartIfOnBatteries') -eq 'false') 'Can run on battery power'
Assert-Test ((Read-TaskNode '//t:StopIfGoingOnBatteries') -eq 'false') 'Continues when switching to battery'
Assert-Test ((Read-TaskNode '//t:ExecutionTimeLimit') -eq 'PT4M') 'Four minute execution limit'
Assert-Test ((Read-TaskNode '//t:Hidden') -eq 'true') 'Task marked hidden'
Assert-Test ($null -eq (Get-ScheduledTask -TaskPath '\' -TaskName $uniqueTaskName -ErrorAction SilentlyContinue)) 'Plan does not register a task'

$owned = [pscustomobject]@{
    Description = $identity.Description
    Actions = @([pscustomobject]@{ Execute = $executable; Arguments = $arguments })
}
Assert-RamAltmanOwnedTask -Task $owned -Description $identity.Description -Executable $executable -EntryPath $entryPath
$passed.Add('Recognizes an owned task')
$owned.Description = 'Unrelated task'
Assert-Throws { Assert-RamAltmanOwnedTask -Task $owned -Description $identity.Description -Executable $executable -EntryPath $entryPath } 'Rejects an unrelated description'
$owned.Description = $identity.Description
$owned.Actions[0].Execute = 'cmd.exe'
Assert-Throws { Assert-RamAltmanOwnedTask -Task $owned -Description $identity.Description -Executable $executable -EntryPath $entryPath } 'Rejects an unrelated executable'
$owned.Actions[0].Execute = $executable
$owned.Actions[0].Arguments = '-File "C:\elsewhere.ps1"'
Assert-Throws { Assert-RamAltmanOwnedTask -Task $owned -Description $identity.Description -Executable $executable -EntryPath $entryPath } 'Rejects an unrelated script action'
Assert-Throws { Assert-RamAltmanTaskName -Name 'folder\task' } 'Rejects task path injection'
Assert-Throws { Get-RamAltmanTaskArguments -EntryPath 'C:\bad"script.ps1' -ConfigPath $configPath } 'Rejects command line quote injection'

$testPassword = 'Disposable scheduler credential test; not an account password'
$credentialPath = Join-Path $fixturePath 'smtp.credential.xml'
$secure = ConvertTo-SecureString $testPassword -AsPlainText -Force
$credential = New-Object Management.Automation.PSCredential('smtp-test-user', $secure)
$credential | Export-Clixml -LiteralPath $credentialPath -Encoding UTF8
$restored = Import-Clixml -LiteralPath $credentialPath
Assert-Test ($restored -is [Management.Automation.PSCredential] -and $restored.UserName -ceq 'smtp-test-user' -and $restored.GetNetworkCredential().Password -ceq $testPassword) 'DPAPI credential roundtrip under current Windows account'
Assert-Test (-not (Get-Content -LiteralPath $credentialPath -Raw).Contains($testPassword)) 'Credential XML does not contain plaintext test password'
$fixtureConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$fixtureConfig.CredentialPath = 'smtp.credential.xml'
$fixtureConfig | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
Import-Module (Join-Path $PSScriptRoot 'RamAltman.psm1') -Force
$loaded = Read-RamAltmanConfig -Path $configPath
Assert-Test ($loaded.CredentialPath -eq $credentialPath -and $loaded.StateDirectory -eq (Join-Path $fixturePath 'state')) 'Setup schema resolves config-relative credential and state paths'
$credential = $null
$restored = $null
$secure = $null
$testPassword = $null

if ($RegisterSmokeTask) {
    $runnerPath = Join-Path $fixturePath 'harmless task runner.ps1'
    $markerPath = Join-Path $fixturePath 'task executed.marker'
    'param([string]$ConfigPath) [IO.File]::WriteAllText($ConfigPath, "Local scheduler launch succeeded")' | Set-Content -LiteralPath $runnerPath -Encoding UTF8
    $smokeArguments = Get-RamAltmanTaskArguments -EntryPath $runnerPath -ConfigPath $markerPath
    $action = New-ScheduledTaskAction -Execute $executable -Argument $smokeArguments -WorkingDirectory $fixturePath
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Sid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    $definition = New-ScheduledTask -Action $action -Principal $principal -Settings $settings -Description ('Disposable local RamAltman test ' + $uniqueTaskName)
    $registered = $false
    try {
        $null = Register-ScheduledTask -TaskPath '\' -TaskName $uniqueTaskName -InputObject $definition
        $registered = $true
        Start-ScheduledTask -TaskPath '\' -TaskName $uniqueTaskName
        $deadline = (Get-Date).AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 250
            $markerExists = Test-Path -LiteralPath $markerPath -PathType Leaf
        } while (-not $markerExists -and (Get-Date) -lt $deadline)
        Assert-Test $markerExists 'Registered task launches hidden quoted paths and writes local marker'
    } finally {
        if ($registered) {
            Stop-ScheduledTask -TaskPath '\' -TaskName $uniqueTaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskPath '\' -TaskName $uniqueTaskName -Confirm:$false
        }
    }
    Assert-Test ($null -eq (Get-ScheduledTask -TaskPath '\' -TaskName $uniqueTaskName -ErrorAction SilentlyContinue)) 'Disposable smoke task removed'
}

$result = [ordered]@{
    Timestamp = (Get-Date).ToString('o')
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    FixtureDirectory = $fixturePath
    Passed = $passed.Count
    Checks = @($passed.ToArray())
    RegisteredSmokeTask = [bool]$RegisterSmokeTask
    EmailSent = $false
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixturePath 'result.json') -Encoding UTF8
$passed | ForEach-Object { Write-Host ('PASS: ' + $_) }
Write-Host ("Passed {0} scheduler tests. Evidence: {1}" -f $passed.Count, (Join-Path $fixturePath 'result.json'))
