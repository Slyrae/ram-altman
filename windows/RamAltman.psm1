#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture

function Get-RamAltmanMemory {
    if ($env:OS -ne 'Windows_NT') { throw 'This memory reader requires Windows.' }
    if (-not ('RamAltman.NativeMemory' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RamAltman {
    public static class NativeMemory {
        [StructLayout(LayoutKind.Sequential)]
        public struct MemoryStatus {
            public uint Length, MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile;
            public ulong TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        }
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
        public static MemoryStatus Read() {
            var status = new MemoryStatus();
            status.Length = (uint)Marshal.SizeOf(typeof(MemoryStatus));
            if (!GlobalMemoryStatusEx(ref status))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return status;
        }
    }
}
'@
    }
    $native = [RamAltman.NativeMemory]::Read()
    [pscustomobject]@{
        TotalBytes = $native.TotalPhys
        AvailableBytes = $native.AvailPhys
        UsedBytes = $native.TotalPhys - $native.AvailPhys
        AvailablePercent = [double]$native.AvailPhys * 100.0 / $native.TotalPhys
    }
}

function Resolve-ConfigFilePath([string]$Value, [string]$BaseDirectory) {
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Read-RamAltmanConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Preview)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $baseDirectory = Split-Path -Parent $fullPath
    $values = @{
        Recipient = ''; Sender = ''; SenderName = 'A concerned RAM owner'
        ThresholdPercent = 10; SmtpHost = ''; SmtpPort = 587; UseSsl = $true
        CredentialPath = ''; StateDirectory = 'state'; TimeoutSeconds = 30
        DeliveryMethod = 'Smtp'; Enabled = $true; GmailClientPath = ''; GmailTokenPath = ''
    }
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        $raw = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
        if ($null -eq $raw -or $raw -is [array] -or $raw -isnot [pscustomobject]) { throw 'Config must be a JSON object.' }
        foreach ($property in $raw.PSObject.Properties) {
            if (-not $values.ContainsKey($property.Name)) { throw "Unknown config setting: $($property.Name)" }
            $values[$property.Name] = $property.Value
        }
    } elseif (-not $Preview) { throw "Config not found: $fullPath. Run Setup.cmd first." }
    foreach ($key in @('Recipient','Sender','SenderName','SmtpHost','CredentialPath','StateDirectory','DeliveryMethod','GmailClientPath','GmailTokenPath')) {
        if ($values[$key] -isnot [string] -or $values[$key] -match '[\r\n\x00]') { throw "Invalid $key setting." }
    }
    if ($values.Enabled -isnot [bool]) { throw 'Enabled must be true or false.' }
    if ($values.DeliveryMethod -notin @('Smtp','GmailOAuth')) { throw 'DeliveryMethod must be Smtp or GmailOAuth.' }
    foreach ($key in @('ThresholdPercent','SmtpPort','TimeoutSeconds')) {
        if ($values[$key] -isnot [ValueType] -or $values[$key] -is [bool]) { throw "$key must be a number." }
    }
    $threshold = [double]$values.ThresholdPercent
    if ([double]::IsNaN($threshold) -or [double]::IsInfinity($threshold) -or $threshold -lt 0 -or $threshold -gt 100) {
        throw 'ThresholdPercent must be between 0 and 100.'
    }
    if ($values.SmtpPort -lt 1 -or $values.SmtpPort -gt 65535 -or [math]::Floor($values.SmtpPort) -ne $values.SmtpPort) { throw 'SmtpPort must be an integer between 1 and 65535.' }
    if ($values.SmtpPort -eq 465) { throw 'Port 465 (implicit TLS) is unsupported. Use a STARTTLS SMTP endpoint, usually port 587.' }
    if ($values.TimeoutSeconds -lt 1 -or $values.TimeoutSeconds -gt 120 -or [math]::Floor($values.TimeoutSeconds) -ne $values.TimeoutSeconds) { throw 'TimeoutSeconds must be an integer between 1 and 120.' }
    if ($values.UseSsl -isnot [bool]) { throw 'UseSsl must be true or false.' }
    if (-not $values.UseSsl -and $values.SmtpHost -notin @('localhost','127.0.0.1','::1')) { throw 'STARTTLS is required for non-loopback SMTP servers.' }
    foreach ($key in @('Recipient','Sender')) {
        if ($values[$key]) {
            try { $address = New-Object Net.Mail.MailAddress($values[$key]) } catch { throw "Invalid $key email address." }
            if ($address.Address -ne $values[$key] -or $values[$key] -notmatch '@') { throw "$key must contain one plain email address." }
        } elseif (-not $Preview) { throw "$key email address is required. Run Setup.cmd first." }
    }
    if (-not $Preview -and $values.DeliveryMethod -eq 'Smtp' -and [string]::IsNullOrWhiteSpace($values.SmtpHost)) { throw 'SmtpHost is required.' }
    if ($values.SmtpHost -match '\s|[/\\:@]') {
        if ($values.SmtpHost -ne '::1') { throw 'SmtpHost must be a hostname or IP, without a port or URL.' }
    }
    if ([string]::IsNullOrWhiteSpace($values.StateDirectory)) { throw 'StateDirectory is required.' }
    $values.StateDirectory = Resolve-ConfigFilePath $values.StateDirectory $baseDirectory
    if ($values.CredentialPath) {
        $values.CredentialPath = Resolve-ConfigFilePath $values.CredentialPath $baseDirectory
        if (-not $Preview -and $values.DeliveryMethod -eq 'Smtp' -and -not (Test-Path -LiteralPath $values.CredentialPath -PathType Leaf)) { throw 'SMTP credential file is missing. Run Setup.cmd under this Windows account.' }
    }
    foreach ($key in @('GmailClientPath','GmailTokenPath')) {
        if ($values[$key]) { $values[$key] = Resolve-ConfigFilePath $values[$key] $baseDirectory }
        if (-not $Preview -and $values.DeliveryMethod -eq 'GmailOAuth' -and (-not $values[$key] -or -not (Test-Path -LiteralPath $values[$key] -PathType Leaf))) {
            throw "$key is missing. Run Setup.cmd to authorize Gmail in your browser."
        }
    }
    [pscustomobject]$values
}

function Assert-MemorySnapshot($Memory) {
    foreach ($key in @('TotalBytes','AvailableBytes')) {
        if ($null -eq $Memory -or $null -eq $Memory.PSObject.Properties[$key]) { throw "Memory snapshot lacks $key." }
        $number = [decimal]$Memory.$key
        if ($number -lt 0 -or [math]::Floor($number) -ne $number) { throw 'Memory byte counts must be nonnegative integers.' }
    }
    if ([decimal]$Memory.TotalBytes -le 0 -or [decimal]$Memory.AvailableBytes -gt [decimal]$Memory.TotalBytes) { throw 'Invalid physical memory snapshot.' }
}

function Format-GiB($Bytes) { return ([double]$Bytes / 1GB).ToString('0.00', $script:Invariant) + ' GiB' }
function Format-MemoryPercent($Memory) { return ([double]$Memory.AvailableBytes * 100 / [double]$Memory.TotalBytes).ToString('0.0', $script:Invariant) }

function Get-TemplatePick([hashtable]$State, [string]$Name, [int]$Count, [switch]$Preview) {
    if ($Preview) { return Get-Random -Minimum 0 -Maximum $Count }
    if (-not $State.ContainsKey('Bags')) { $State.Bags = @{} }
    if (-not $State.Bags.ContainsKey($Name)) { $State.Bags[$Name] = @{Remaining = @(); Last = -1} }
    $bag = $State.Bags[$Name]
    $remaining = @($bag.Remaining | Where-Object { $_ -ge 0 -and $_ -lt $Count })
    if ($remaining.Count -eq 0) {
        $remaining = @(0..($Count - 1) | Sort-Object { Get-Random })
        if ($Count -gt 1 -and $remaining[0] -eq $bag.Last) {
            $remaining = @($remaining[1..($Count - 1)]) + @($remaining[0])
        }
    }
    $next = [int]$remaining[0]
    $bag.Remaining = @($remaining | Select-Object -Skip 1)
    $bag.Last = $next
    return $next
}

function New-RamAltmanEmail {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Memory, [hashtable]$State = @{}, [switch]$Preview, $Vram)
    Assert-MemorySnapshot $Memory
    $total = Format-GiB $Memory.TotalBytes
    $available = Format-GiB $Memory.AvailableBytes
    $used = Format-GiB ([decimal]$Memory.TotalBytes - [decimal]$Memory.AvailableBytes)
    $percent = Format-MemoryPercent $Memory
    $subjects = @(
        'Good news: we found some RAM', 'Unused RAM detected in the wild', 'RAM sighting on my PC',
        'A substantial amount of RAM remains at large', 'You missed a spot', 'Daily RAM census: some survived',
        'My RAM still has room to spare', "Still not all of it, I'm afraid"
    )
    $bodies = @(
        "I'm writing to report that you appear to have missed some. I assume this is an oversight.",
        "A routine inspection found all this capacity still available on my PC. I thought you'd want to know before someone tries to train something on it.",
        "Daily status report: the RAM remains here. Threat level: someone at OpenAI might notice.",
        "$available of my $total of RAM is still available. I'm as surprised as you are.",
        "Please don't be alarmed, but this RAM is on my desk instead of in a data centre. As far as I can tell, it has no plans today.",
        "This PC still has $available of RAM available. I thought you'd want to know.",
        "Today's report from my PC: $available of $total of RAM is still available. That's $percent%.",
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on this much. It's not for sale, I just like knowing it's there.",
        "I have a confession. I have $available of RAM available, which is $percent% of the $total in this PC.",
        "If RAM sits available in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of my memory."
    )
    $signoffs = @('Yours in abundance,','Regards from the last free RAM in the county,','Hoarding responsibly,','Stay allocated,','Yours, with memory to spare,','Kind regards,')
    $subject = $subjects[(Get-TemplatePick $State 'subject' $subjects.Count -Preview:$Preview)]
    $body = $bodies[(Get-TemplatePick $State 'body' $bodies.Count -Preview:$Preview)]
    $signoff = $signoffs[(Get-TemplatePick $State 'signoff' $signoffs.Count -Preview:$Preview)]
    $lines = @(
        'Hi Sam,', '',
        "$available OF $total OF SYSTEM RAM IS AVAILABLE RIGHT NOW ($percent%).", '',
        "  Available / idle capacity:  $available ($percent%)",
        "  Total usable system RAM:   $total",
        "  In use:                    $used", '', $body
    )
    if ($null -ne $Vram) {
        if ($Vram.Supported) {
            $lines += @('', 'BONUS: GPU MEMORY WITH ROOM TO SPARE')
            foreach ($adapter in $Vram.Adapters) {
                $gpuFree = Format-GiB $adapter.AvailableBytes
                $gpuTotal = Format-GiB $adapter.TotalBytes
                $gpuPct = ([double]$adapter.AvailableBytes * 100 / [double]$adapter.TotalBytes).ToString('0.0', $script:Invariant)
                $lines += "  $($adapter.Name): $gpuFree of $gpuTotal of VRAM available ($gpuPct%)."
            }
        } else { $lines += @('', 'Bonus VRAM reading: unavailable from the installed GPU driver.') }
    }
    $name = $Config.SenderName
    if (-not $name) { $name = 'A concerned RAM owner' }
    $lines += @('', $signoff, $name)
    [pscustomobject]@{ Subject = "[RAM: $available available / $percent%] $subject"; Body = ($lines -join "`r`n") }
}

function ConvertTo-StateHashtable($Object) {
    if ($null -eq $Object) { return $null }
    if ($Object.GetType() -eq [Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $Object.PSObject.Properties) { $result[$property.Name] = ConvertTo-StateHashtable $property.Value }
        return $result
    }
    if ($Object -is [array]) { return ,@($Object | ForEach-Object { ConvertTo-StateHashtable $_ }) }
    return $Object
}

function Read-DeliveryState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{Version = 1; LastDate = ''; DeliveryStatus = ''; LastAttemptUtc = ''; Bags = @{}} }
    try {
        $state = ConvertTo-StateHashtable (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
        if ($state -isnot [hashtable]) { throw 'Invalid state schema.' }
        foreach ($key in @('Version','LastDate','DeliveryStatus','LastAttemptUtc','Bags')) {
            if (-not $state.ContainsKey($key)) { throw "Missing state field: $key" }
        }
        if ($state.Version -ne 1 -or $state.Bags -isnot [hashtable]) { throw 'Invalid state schema.' }
        if ($state.LastDate) {
            [void][datetime]::ParseExact($state.LastDate, 'yyyy-MM-dd', $script:Invariant)
            [void][DateTimeOffset]::Parse($state.LastAttemptUtc, $script:Invariant)
            if ($state.DeliveryStatus -notin @('Sending','Sent','Rejected','Uncertain')) { throw 'Invalid delivery status.' }
        } elseif ($state.DeliveryStatus -or $state.LastAttemptUtc) { throw 'Delivery state lacks its date.' }
        return $state
    } catch { throw "Delivery state is unreadable; refusing to send to avoid a duplicate. Preserve and inspect $Path. $($_.Exception.Message)" }
}

function Write-DeliveryState([string]$Path, [hashtable]$State) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($State | ConvertTo-Json -Depth 12))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Write-RamSample($Config, $Memory, [DateTimeOffset]$Now) {
    $path = Join-Path $Config.StateDirectory 'usage.csv'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 10MB) {
        $tail = @(Get-Content -LiteralPath $path -Tail 10000)
        [IO.File]::WriteAllLines($path, @('timestamp,total_bytes,used_bytes,available_bytes,available_pct') + $tail, [Text.UTF8Encoding]::new($false))
    }
    if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllText($path, "timestamp,total_bytes,used_bytes,available_bytes,available_pct`r`n", [Text.UTF8Encoding]::new($false)) }
    $line = '{0},{1},{2},{3},{4}' -f $Now.ToString('o'), $Memory.TotalBytes, ([decimal]$Memory.TotalBytes - [decimal]$Memory.AvailableBytes), $Memory.AvailableBytes, (Format-MemoryPercent $Memory)
    [IO.File]::AppendAllText($path, $line + "`r`n", [Text.UTF8Encoding]::new($false))
}

function Write-RunEvent($Config, [string]$Outcome, [DateTimeOffset]$Now) {
    $path = Join-Path $Config.StateDirectory 'events.jsonl'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 1MB) {
        [IO.File]::WriteAllLines($path, @(Get-Content -LiteralPath $path -Tail 1000), [Text.UTF8Encoding]::new($false))
    }
    $line = @{timestamp = $Now.ToString('o'); outcome = $Outcome} | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($path, $line + "`r`n", [Text.UTF8Encoding]::new($false))
}

function Send-RamAltmanSmtp($Config, $Email, $Credential) {
    $message = New-Object Net.Mail.MailMessage
    $client = New-Object Net.Mail.SmtpClient($Config.SmtpHost, [int]$Config.SmtpPort)
    try {
        $message.From = New-Object Net.Mail.MailAddress($Config.Sender, $Config.SenderName, [Text.Encoding]::UTF8)
        $message.To.Add($Config.Recipient)
        $message.Subject = $Email.Subject
        $message.SubjectEncoding = [Text.Encoding]::UTF8
        $message.Body = $Email.Body
        $message.BodyEncoding = [Text.Encoding]::UTF8
        $message.Headers.Add('Auto-Submitted','auto-generated')
        $client.EnableSsl = $Config.UseSsl
        $client.DeliveryMethod = [Net.Mail.SmtpDeliveryMethod]::Network
        $client.UseDefaultCredentials = $false
        $client.Timeout = [int]$Config.TimeoutSeconds * 1000
        if ($null -ne $Credential) { $client.Credentials = $Credential.GetNetworkCredential() }
        # .NET Framework otherwise inherits system TLS policy; explicitly require TLS 1.2.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $client.Send($message)
    } finally { $message.Dispose(); $client.Dispose() }
}

function Test-RetryableDeliveryFailure($Exception) {
    $current = $Exception
    while ($null -ne $current) {
        if ($current.Data.Contains('RamAltmanDefiniteRejection') -and $current.Data['RamAltmanDefiniteRejection'] -eq $true) { return $true }
        if ($current -is [Net.Mail.SmtpException]) {
            $code = [int]$current.StatusCode
            if ($code -ge 400 -and $code -le 599) { return $true }
        }
        # These errors prove no SMTP connection was established. Timeouts and
        # resets do not: the server may already have accepted the message.
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -in @(
            [Net.Sockets.SocketError]::HostNotFound, [Net.Sockets.SocketError]::NoData,
            [Net.Sockets.SocketError]::TryAgain, [Net.Sockets.SocketError]::ConnectionRefused)) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Invoke-RamAltmanCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, $Memory, [DateTimeOffset]$Now = [DateTimeOffset]::Now, [scriptblock]$SendAction, [switch]$DryRun, $Vram)
    if (-not $DryRun -and -not $Config.Enabled) {
        return [pscustomobject]@{Outcome = 'Disabled'; Memory = $Memory; Email = $null}
    }
    if ($null -eq $Memory) { $Memory = Get-RamAltmanMemory }
    Assert-MemorySnapshot $Memory
    $qualifies = [decimal]$Memory.AvailableBytes * 100 -ge [decimal]$Config.ThresholdPercent * [decimal]$Memory.TotalBytes
    if ($DryRun) {
        $email = $null
        if ($qualifies) { $email = New-RamAltmanEmail -Config $Config -Memory $Memory -Preview -Vram $Vram }
        return [pscustomobject]@{Outcome = 'Preview'; Memory = $Memory; Email = $email}
    }
    [void][IO.Directory]::CreateDirectory($Config.StateDirectory)
    $lockPath = Join-Path $Config.StateDirectory 'monitor.lock'
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { return [pscustomobject]@{Outcome = 'Busy'; Memory = $Memory; Email = $null} }
    try {
        $statePath = Join-Path $Config.StateDirectory 'state.json'
        $state = Read-DeliveryState $statePath
        Write-RamSample $Config $Memory $Now
        if (-not $qualifies) { $outcome = 'BelowThreshold' }
        else {
            $today = $Now.ToString('yyyy-MM-dd', $script:Invariant)
            if ($state.LastDate -and [string]::CompareOrdinal($state.LastDate, $today) -gt 0) { throw 'Clock is earlier than the saved delivery date; refusing to send.' }
            if ($state.LastDate -eq $today -and $state.DeliveryStatus -in @('Sending','Sent','Uncertain')) {
                $outcome = 'AlreadySent'
                if ($state.DeliveryStatus -ne 'Sent') { $outcome = 'DeliveryUncertain' }
            } else {
                $credential = $null
                $gmailAccessToken = $null
                if (-not $SendAction -and $Config.DeliveryMethod -eq 'GmailOAuth') {
                    Import-Module (Join-Path $PSScriptRoot 'GmailOAuth.psm1') -Force
                    $gmailAccessToken = Get-RamAltmanGmailAccessToken -Config $Config
                } elseif (-not $SendAction -and $Config.CredentialPath) {
                    try { $credential = Import-Clixml -LiteralPath $Config.CredentialPath }
                    catch { throw 'Cannot decrypt SMTP credential. Run Setup.cmd as this Windows user on this PC.' }
                    if ($credential -isnot [Management.Automation.PSCredential]) { throw 'SMTP credential is not a PSCredential.' }
                }
                $email = New-RamAltmanEmail -Config $Config -Memory $Memory -State $state -Vram $Vram
                # Durable reservation closes the accepted-by-server / process-crash gap.
                $state.LastDate = $today
                $state.LastAttemptUtc = $Now.ToUniversalTime().ToString('o')
                $state.DeliveryStatus = 'Sending'
                Write-DeliveryState $statePath $state
                $providerReceipt = $null
                try {
                    if ($SendAction) { $providerReceipt = & $SendAction $Config $email }
                    elseif ($Config.DeliveryMethod -eq 'GmailOAuth') { $providerReceipt = Send-RamAltmanGmail -Config $Config -Email $email -AccessToken $gmailAccessToken }
                    else { Send-RamAltmanSmtp $Config $email $credential }
                } catch {
                    if (Test-RetryableDeliveryFailure $_.Exception) {
                        $state.DeliveryStatus = 'Rejected'
                        Write-DeliveryState $statePath $state
                        Write-RunEvent $Config 'Rejected' $Now
                        throw 'Email submission failed before acceptance (provider rejection or unreachable endpoint). It will retry on the next scheduled check; inspect the delivery settings or provider limits.'
                    }
                    $state.DeliveryStatus = 'Uncertain'
                    Write-DeliveryState $statePath $state
                    Write-RunEvent $Config 'DeliveryUncertain' $Now
                    return [pscustomobject]@{Outcome = 'DeliveryUncertain'; Memory = $Memory; Email = $email}
                }
                $state.DeliveryStatus = 'Sent'
                $bodyHasher = [Security.Cryptography.SHA256]::Create()
                try { $bodyHash = [BitConverter]::ToString($bodyHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($email.Body))).Replace('-','') }
                finally { $bodyHasher.Dispose() }
                $state.LastDelivery = @{
                    AcceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); Provider = $Config.DeliveryMethod
                    Sender = $Config.Sender; Recipient = $Config.Recipient; Subject = $email.Subject; BodySha256 = $bodyHash
                    TotalRamBytes = $Memory.TotalBytes; AvailableRamBytes = $Memory.AvailableBytes
                }
                if ($Config.DeliveryMethod -eq 'GmailOAuth' -and $null -ne $providerReceipt -and $null -ne $providerReceipt.PSObject.Properties['Id']) {
                    $state.LastDelivery.MessageId = [string]$providerReceipt.Id
                    if ($null -ne $providerReceipt.PSObject.Properties['ThreadId']) { $state.LastDelivery.ThreadId = [string]$providerReceipt.ThreadId }
                }
                Write-DeliveryState $statePath $state
                $outcome = 'Sent'
            }
        }
        Write-RunEvent $Config $outcome $Now
        [pscustomobject]@{Outcome = $outcome; Memory = $Memory; Email = $null}
    } finally { $lock.Dispose() }
}

Export-ModuleMember -Function Get-RamAltmanMemory,Read-RamAltmanConfig,New-RamAltmanEmail,Invoke-RamAltmanCheck
