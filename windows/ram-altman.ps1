#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Run')]
param(
    [Parameter(ParameterSetName='Status')][switch]$Status,
    [Parameter(ParameterSetName='Preview')][switch]$DryRun,
    [string]$ConfigPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'private\config.json' }
    Import-Module (Join-Path $PSScriptRoot 'RamAltman.psm1') -Force
    $config = Read-RamAltmanConfig -Path $ConfigPath -Preview
    if (-not $DryRun -and -not $Status) {
        if (-not $config.Enabled) { Write-Output 'Result: Disabled'; exit 0 }
        $config = Read-RamAltmanConfig -Path $ConfigPath
    }
    $memory = Get-RamAltmanMemory
    $culture = [Globalization.CultureInfo]::InvariantCulture
    Write-Output ('Total:     {0} GiB' -f ($memory.TotalBytes / 1GB).ToString('0.00',$culture))
    Write-Output ('In use:    {0} GiB' -f ($memory.UsedBytes / 1GB).ToString('0.00',$culture))
    Write-Output ('Available: {0} GiB ({1}%)' -f ($memory.AvailableBytes / 1GB).ToString('0.00',$culture),$memory.AvailablePercent.ToString('0.0',$culture))
    $vram = $null
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Vram.psm1')) {
        try { Import-Module (Join-Path $PSScriptRoot 'Vram.psm1') -Force; $vram = Get-RamAltmanVram }
        catch { $vram = [pscustomobject]@{Supported=$false;Adapters=@();Reason='GPU reading failed.'} }
        if ($vram.Supported) {
            foreach ($adapter in $vram.Adapters) {
                Write-Output ('VRAM ({0}): {1} GiB of {2} GiB available ({3}%)' -f $adapter.Name,($adapter.AvailableBytes / 1GB).ToString('0.00',$culture),($adapter.TotalBytes / 1GB).ToString('0.00',$culture),$adapter.AvailablePercent.ToString('0.0',$culture))
            }
        } else { Write-Output 'VRAM: unavailable from this GPU driver.' }
    }
    if ($Status) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Output 'Automatic email: not configured.' }
        else {
            Write-Output ('Automatic email: ' + $(if ($config.Enabled) {'enabled in configuration'} else {'DISABLED'}))
            Write-Output ('Delivery method: ' + $config.DeliveryMethod)
            $authPath = $config.CredentialPath
            if ($config.DeliveryMethod -eq 'GmailOAuth') { $authPath = $config.GmailTokenPath }
            Write-Output ('Authorization: ' + $(if ($authPath -and (Test-Path -LiteralPath $authPath -PathType Leaf)) {'saved locally'} else {'not configured'}))
            try {
                $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $task = Get-ScheduledTask -TaskPath '\' -TaskName ('RamAltman-' + $sid) -ErrorAction SilentlyContinue
                Write-Output ('Scheduled task: ' + $(if ($null -eq $task) {'not installed'} else {[string]$task.State}))
            } catch { Write-Output 'Scheduled task: could not query.' }
        }
        exit 0
    }
    $result = Invoke-RamAltmanCheck -Config $config -Memory $memory -DryRun:$DryRun -Vram $vram
    Write-Output ('Result: ' + $result.Outcome)
    if ($DryRun) {
        if ($null -ne $result.Email) {
            Write-Output ("`r`nTo: " + $(if ($config.Recipient) {$config.Recipient} else {'recipient-not-set@example.com'}))
            Write-Output ('From: ' + $(if ($config.Sender) {$config.Sender} else {'sender-not-set@example.com'}))
            Write-Output ('Subject: ' + $result.Email.Subject)
            Write-Output ("`r`n" + $result.Email.Body)
        } else { Write-Output 'No email: available RAM is below the configured threshold.' }
    }
    if ($result.Outcome -eq 'DeliveryUncertain') {
        Write-Error 'Delivery is uncertain. Further sends are blocked today to prevent duplicates. Inspect private\state\events.jsonl and your SMTP provider.' -ErrorAction Continue
        exit 2
    }
    exit 0
} catch {
    Write-Error ('RamAltman: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
