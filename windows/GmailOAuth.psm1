#requires -Version 5.1
# Standalone Gmail OAuth: browser consent, send-only Gmail access, Windows DPAPI.
Set-StrictMode -Version Latest
if ($env:OS -eq 'Windows_NT') {
    # Native modules must remain available when a caller inherited a custom
    # PSModulePath (for example from Python or another PowerShell installation).
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Import-Module (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
    } elseif (-not (Get-Module -Name Microsoft.PowerShell.Security)) {
        Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
    }
}
$script:GmailSendScope = 'https://www.googleapis.com/auth/gmail.send'
$script:GmailTokenEndpoint = 'https://oauth2.googleapis.com/token'
$script:GmailUserInfoEndpoint = 'https://openidconnect.googleapis.com/v1/userinfo'
$script:GmailSendEndpoint = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'

function Assert-GmailOAuthWindows {
    if ($env:OS -ne 'Windows_NT') { throw 'Gmail token storage requires Windows DPAPI.' }
}

function Get-GmailProperty($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Assert-GmailPlainAddress([string]$Address) {
    if ([string]::IsNullOrWhiteSpace($Address) -or $Address -match '[\r\n\x00]') { throw 'A plain email address is required.' }
    try { $parsed = New-Object Net.Mail.MailAddress($Address) } catch { throw 'A plain email address is required.' }
    if ($parsed.Address -ne $Address -or $Address -notmatch '@') { throw 'Use one plain email address without a display name.' }
}

function Read-GmailDesktopClient([string]$Path) {
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $installed = Get-GmailProperty $json 'installed'
        $clientId = Get-GmailProperty $installed 'client_id'
        $clientSecret = Get-GmailProperty $installed 'client_secret' ''
        if ($null -eq $installed -or $clientId -isnot [string] -or
            $clientId -notmatch '^[A-Za-z0-9._-]+\.apps\.googleusercontent\.com$' -or
            $clientSecret -isnot [string] -or $clientSecret -match '[\r\n\x00]') { throw 'Invalid desktop client.' }
        # Endpoints from the downloaded file are deliberately ignored.
        return [pscustomobject]@{ ClientId = $clientId; ClientSecret = $clientSecret }
    } catch { throw 'Cannot read Google Desktop OAuth client JSON. Enable Gmail API and download a Desktop app client from your own Google Cloud project.' }
}

function ConvertTo-GmailBase64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GmailOAuthRandom {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    ConvertTo-GmailBase64Url $bytes
}

function Get-GmailOAuthChallenge([string]$Verifier) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { ConvertTo-GmailBase64Url ($hash.ComputeHash([Text.Encoding]::ASCII.GetBytes($Verifier))) }
    finally { $hash.Dispose() }
}

function ConvertTo-GmailQuery([hashtable]$Values) {
    (@($Values.Keys | Sort-Object | ForEach-Object {
        [Uri]::EscapeDataString([string]$_) + '=' + [Uri]::EscapeDataString([string]$Values[$_])
    }) -join '&')
}

function ConvertFrom-GmailQuery([string]$Query) {
    $result = @{}
    foreach ($part in $Query.TrimStart('?').Split('&')) {
        if (-not $part) { continue }
        $pair = $part.Split([char[]]'=', 2, [StringSplitOptions]::None)
        $key = [Uri]::UnescapeDataString($pair[0].Replace('+', ' '))
        if ($result.ContainsKey($key)) { throw 'Duplicate callback parameter.' }
        $value = ''
        if ($pair.Count -eq 2) { $value = [Uri]::UnescapeDataString($pair[1].Replace('+', ' ')) }
        $result[$key] = $value
    }
    return $result
}

function Test-GmailGrantedScopes([string]$Scopes) {
    $granted = @($Scopes -split '\s+' | Where-Object { $_ })
    return ($granted -contains $script:GmailSendScope -and $granted -contains 'openid' -and
        ($granted -contains 'email' -or $granted -contains 'https://www.googleapis.com/auth/userinfo.email'))
}

function Invoke-GmailOAuthHttp {
    param([Parameter(Mandatory)][string]$Uri, [ValidateSet('Get', 'Post')][string]$Method,
        $Body, [hashtable]$Headers = @{}, [string]$ContentType = 'application/x-www-form-urlencoded')
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $parameters = @{ Uri = $Uri; Method = $Method; Headers = $Headers; TimeoutSec = 25; MaximumRedirection = 0; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $parameters.Body = $Body; $parameters.ContentType = $ContentType }
    try { return Invoke-RestMethod @parameters }
    catch {
        $transportError = $_.Exception
        $status = 0
        $googleError = ''
        $response = Get-GmailProperty $transportError 'Response'
        if ($null -ne $response) {
            try { $status = [int]$response.StatusCode } catch { }
            try {
                $reader = New-Object IO.StreamReader($response.GetResponseStream())
                try { $errorJson = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
                $candidate = Get-GmailProperty $errorJson 'error'
                if ($candidate -is [string] -and $candidate -in @('invalid_grant','invalid_client','access_denied','invalid_scope')) { $googleError = $candidate }
            } catch { }
        }
        $message = 'Google request failed; check the network connection and local Gmail authorization.'
        if ($status) { $message = "Google request failed (HTTP $status). Check Gmail authorization or provider limits." }
        if ($googleError -in @('invalid_grant','access_denied')) { $message = 'Google authorization expired or was revoked. Run Gmail setup again to authorize this Windows account.' }
        if ($googleError -eq 'invalid_client') { $message = 'Google OAuth client was rejected. Check the saved Desktop client JSON and authorize again.' }
        $failure = New-Object InvalidOperationException($message)
        $failure.Data['RamAltmanHttpStatus'] = $status
        $failure.Data['RamAltmanGoogleError'] = $googleError
        # Explicit negative API replies can be retried by the outer daily guard.
        # Timeouts, network errors, HTTP408 and5xx remain ambiguous after send.
        if ($status -in @(400,401,403,404,409,413,422,429)) { $failure.Data['RamAltmanDefiniteRejection'] = $true }
        # Preserve only proven pre-connection failures when sanitizing the raw
        # exception. A timeout/reset/unreachable socket may follow acceptance.
        $current = $transportError
        while ($null -ne $current) {
            if ($current -is [Net.WebException] -and $current.Status -in @(
                [Net.WebExceptionStatus]::NameResolutionFailure, [Net.WebExceptionStatus]::ProxyNameResolutionFailure)) {
                $failure.Data['RamAltmanDefiniteRejection'] = $true
            }
            if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -in @(
                [Net.Sockets.SocketError]::HostNotFound, [Net.Sockets.SocketError]::NoData,
                [Net.Sockets.SocketError]::TryAgain, [Net.Sockets.SocketError]::ConnectionRefused)) {
                $failure.Data['RamAltmanDefiniteRejection'] = $true
            }
            $current = $current.InnerException
        }
        throw $failure
    }
}

function Write-GmailEncryptedToken([string]$Path, $Token) {
    Assert-GmailOAuthWindows
    $fullPath = [IO.Path]::GetFullPath($Path)
    $null = [IO.Directory]::CreateDirectory((Split-Path $fullPath -Parent))
    $temporary = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $secure = ConvertTo-SecureString -String ($Token | ConvertTo-Json -Depth 5 -Compress) -AsPlainText -Force
    try {
        $encrypted = ConvertFrom-SecureString -SecureString $secure
        $bytes = [Text.Encoding]::UTF8.GetBytes($encrypted)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($temporary, $fullPath, [Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($temporary, $fullPath) }
    } finally {
        $secure.Dispose()
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Read-GmailEncryptedToken([string]$Path) {
    Assert-GmailOAuthWindows
    $secure = $null
    $pointer = [IntPtr]::Zero
    try {
        $encrypted = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $secure = ConvertTo-SecureString -String $encrypted.Trim() -ErrorAction Stop
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in @('Version','Email','Subject','ClientId','RefreshToken','AccessToken','ExpiresAtUtc','Scopes')) {
            if ($null -eq $token.PSObject.Properties[$name]) { throw 'Invalid token schema.' }
        }
        if ($token.Version -ne 1) { throw 'Unsupported token version.' }
        # PowerShell 7.5+ may deserialize ISO JSON strings as DateTime; native
        # Windows PowerShell 5.1 preserves them as strings. Keep one schema.
        if ($token.ExpiresAtUtc -is [datetime] -or $token.ExpiresAtUtc -is [DateTimeOffset]) {
            $token.ExpiresAtUtc = $token.ExpiresAtUtc.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        foreach ($name in @('Email','Subject','ClientId','RefreshToken','AccessToken','ExpiresAtUtc','Scopes')) {
            if ($token.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($token.$name) -or $token.$name -match '[\r\n\x00]') { throw 'Invalid token field.' }
        }
        Assert-GmailPlainAddress $token.Email
        [void][DateTimeOffset]::Parse($token.ExpiresAtUtc, [Globalization.CultureInfo]::InvariantCulture)
        if (-not (Test-GmailGrantedScopes $token.Scopes)) { throw 'Required scopes missing.' }
        return $token
    } catch { throw 'Cannot decrypt or validate the Gmail token. Run Gmail setup as the same Windows user on this PC.' }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function Test-RamAltmanGmailToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedSender)
    try {
        $token = Read-GmailEncryptedToken $Path
        if ($ExpectedSender -and $token.Email -ne $ExpectedSender) { return $false }
        return $true
    } catch { return $false }
}

function Write-GmailCallbackResponse($Stream, [int]$Status, [string]$Text) {
    $body = [Text.Encoding]::UTF8.GetBytes('<!doctype html><html><meta charset="utf-8"><title>RamAltman Gmail setup</title><body><p>' + $Text + '</p></body></html>')
    $reason = 'OK'
    if ($Status -ne 200) { $reason = 'Bad Request' }
    $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status $reason`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Start-RamAltmanGmailAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClientPath, [Parameter(Mandatory)][string]$TokenPath,
        [Parameter(Mandatory)][string]$ExpectedSender, [ValidateRange(15,180)][int]$TimeoutSeconds = 180)
    Assert-GmailOAuthWindows
    Assert-GmailPlainAddress $ExpectedSender
    $client = Read-GmailDesktopClient $ClientPath
    $verifier = New-GmailOAuthRandom
    $state = New-GmailOAuthRandom
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $code = $null
    try {
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $redirect = "http://127.0.0.1:$port/"
        $query = @{
            client_id = $client.ClientId; redirect_uri = $redirect; response_type = 'code'
            scope = ($script:GmailSendScope + ' openid email'); state = $state
            code_challenge = (Get-GmailOAuthChallenge $verifier); code_challenge_method = 'S256'
            access_type = 'offline'; prompt = 'consent select_account'; login_hint = $ExpectedSender
        }
        Write-Host "Opening Google sign-in. Choose $ExpectedSender and allow sending email. No Gmail password is stored by RamAltman."
        Start-Process -FilePath ('https://accounts.google.com/o/oauth2/v2/auth?' + (ConvertTo-GmailQuery $query)) | Out-Null
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTimeOffset]::UtcNow -lt $deadline -and -not $code) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
            $connection = $listener.AcceptTcpClient()
            $denied = $false
            try {
                $connection.ReceiveTimeout = 2000
                $connection.SendTimeout = 2000
                $stream = $connection.GetStream()
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                try {
                    $line = $reader.ReadLine()
                    if ($null -eq $line -or $line.Length -gt 16384 -or $line -notmatch '^GET ([^ ]+) HTTP/1\.[01]$') { throw 'Invalid callback request.' }
                    $target = $matches[1]
                    if (-not $target.StartsWith('/')) { throw 'Invalid callback target.' }
                    $uri = New-Object Uri($redirect.TrimEnd('/') + $target)
                    if ($uri.AbsolutePath -ne '/') { throw 'Wrong callback path.' }
                    $headersSize = 0
                    do {
                        $headerLine = $reader.ReadLine()
                        if ($null -eq $headerLine) { throw 'Incomplete callback request.' }
                        $headersSize += $headerLine.Length
                        if ($headersSize -gt 16384) { throw 'Callback headers too long.' }
                    } while ($headerLine.Length -gt 0)
                    $parameters = ConvertFrom-GmailQuery $uri.Query
                    if (-not $parameters.ContainsKey('state') -or -not [string]::Equals($parameters.state, $state, [StringComparison]::Ordinal)) { throw 'Callback state mismatch.' }
                    if ($parameters.ContainsKey('error')) {
                        $denied = $true
                        Write-GmailCallbackResponse $stream 200 'Google authorization was declined. Close this tab and return to RamAltman setup.'
                    } elseif ($parameters.ContainsKey('code') -and -not [string]::IsNullOrWhiteSpace($parameters.code)) {
                        $code = $parameters.code
                        Write-GmailCallbackResponse $stream 200 'Authorization response received. Close this tab and return to RamAltman setup to finish.'
                    } else { throw 'Authorization code missing.' }
                } finally { $reader.Dispose() }
            } catch {
                try { Write-GmailCallbackResponse ($connection.GetStream()) 400 'This request was not a valid RamAltman authorization response.' } catch { }
            } finally { $connection.Dispose() }
            if ($denied) { throw 'Google authorization was declined. No Gmail token was saved.' }
        }
        if (-not $code) { throw 'Google sign-in timed out. No Gmail token was saved. Run setup again when ready.' }
    } finally { $listener.Stop() }
    $body = @{ client_id = $client.ClientId; code = $code; code_verifier = $verifier; grant_type = 'authorization_code'; redirect_uri = $redirect }
    if ($client.ClientSecret) { $body.client_secret = $client.ClientSecret }
    $response = Invoke-GmailOAuthHttp -Uri $script:GmailTokenEndpoint -Method Post -Body $body
    $refresh = Get-GmailProperty $response 'refresh_token'
    $access = Get-GmailProperty $response 'access_token'
    $scopes = [string](Get-GmailProperty $response 'scope' '')
    if ([string]::IsNullOrWhiteSpace($refresh) -or [string]::IsNullOrWhiteSpace($access) -or -not (Test-GmailGrantedScopes $scopes)) {
        throw 'Google did not grant the required offline sending permission. Run setup again and allow Gmail sending and email identity.'
    }
    $identity = Invoke-GmailOAuthHttp -Uri $script:GmailUserInfoEndpoint -Method Get -Headers @{ Authorization = 'Bearer ' + $access }
    $email = Get-GmailProperty $identity 'email'
    $verified = Get-GmailProperty $identity 'email_verified' $false
    $subject = Get-GmailProperty $identity 'sub'
    if ($verified -ne $true -or $email -ne $ExpectedSender -or [string]::IsNullOrWhiteSpace($subject)) {
        throw 'The Google account does not match the configured verified sender. No Gmail token was saved.'
    }
    $expires = [double](Get-GmailProperty $response 'expires_in' 0)
    if ($expires -le 0 -or $expires -gt 31536000) { throw 'Google returned an invalid token expiry. No Gmail token was saved.' }
    $token = [ordered]@{
        Version = 1; Email = [string]$email; Subject = [string]$subject; ClientId = $client.ClientId
        RefreshToken = [string]$refresh; AccessToken = [string]$access
        ExpiresAtUtc = [DateTimeOffset]::UtcNow.AddSeconds($expires).ToString('o'); Scopes = $scopes
    }
    Write-GmailEncryptedToken $TokenPath $token
    [pscustomobject]@{ Authorized = $true; Email = $email; TokenPath = [IO.Path]::GetFullPath($TokenPath) }
}

function Get-RamAltmanGmailAccessToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    Assert-GmailPlainAddress $Config.Sender
    $client = Read-GmailDesktopClient $Config.GmailClientPath
    $token = Read-GmailEncryptedToken $Config.GmailTokenPath
    if ($token.Email -ne $Config.Sender -or $token.ClientId -ne $client.ClientId) { throw 'Saved Gmail authorization does not match this sender and Desktop client. Run Gmail setup again.' }
    $expiry = [DateTimeOffset]::Parse($token.ExpiresAtUtc, [Globalization.CultureInfo]::InvariantCulture)
    if ($expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) { return $token.AccessToken }
    $body = @{ client_id = $client.ClientId; refresh_token = $token.RefreshToken; grant_type = 'refresh_token' }
    if ($client.ClientSecret) { $body.client_secret = $client.ClientSecret }
    $response = Invoke-GmailOAuthHttp -Uri $script:GmailTokenEndpoint -Method Post -Body $body
    $access = Get-GmailProperty $response 'access_token'
    $expires = [double](Get-GmailProperty $response 'expires_in' 0)
    $scopes = [string](Get-GmailProperty $response 'scope' $token.Scopes)
    if ([string]::IsNullOrWhiteSpace($access) -or $expires -le 0 -or $expires -gt 31536000 -or -not (Test-GmailGrantedScopes $scopes)) { throw 'Google did not renew the required sending permission. Run Gmail setup again.' }
    $token.AccessToken = [string]$access
    $token.ExpiresAtUtc = [DateTimeOffset]::UtcNow.AddSeconds($expires).ToString('o')
    $token.Scopes = $scopes
    $refresh = Get-GmailProperty $response 'refresh_token' ''
    if ($refresh) { $token.RefreshToken = [string]$refresh }
    Write-GmailEncryptedToken $Config.GmailTokenPath $token
    return $token.AccessToken
}

function ConvertTo-GmailEncodedHeader([string]$Value) {
    if ($Value -match '[\r\n\x00]') { throw 'Email header contains an invalid control character.' }
    $words = @()
    $part = ''
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = [string]$Value[$index]
        if ([char]::IsHighSurrogate($Value[$index]) -and $index + 1 -lt $Value.Length -and [char]::IsLowSurrogate($Value[$index + 1])) {
            $character += [string]$Value[++$index]
        }
        if ($part -and [Text.Encoding]::UTF8.GetByteCount($part + $character) -gt 42) {
            $words += '=?UTF-8?B?' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($part)) + '?='
            $part = ''
        }
        $part += $character
    }
    if ($part) { $words += '=?UTF-8?B?' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($part)) + '?=' }
    $words -join "`r`n "
}

function New-GmailMimeMessage($Config, $Email) {
    Assert-GmailPlainAddress $Config.Sender
    Assert-GmailPlainAddress $Config.Recipient
    if ($Email.Subject -isnot [string] -or $Email.Body -isnot [string]) { throw 'Email subject and body must be strings.' }
    $from = $Config.Sender
    if ($Config.SenderName) { $from = (ConvertTo-GmailEncodedHeader $Config.SenderName) + ' <' + $Config.Sender + '>' }
    $body = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Email.Body), [Base64FormattingOptions]::InsertLineBreaks)
    $lines = @(
        ('From: ' + $from), ('To: ' + $Config.Recipient), ('Subject: ' + (ConvertTo-GmailEncodedHeader $Email.Subject)),
        ('Date: ' + [DateTimeOffset]::UtcNow.ToString('r', [Globalization.CultureInfo]::InvariantCulture)),
        ('Message-ID: <' + [guid]::NewGuid().ToString('N') + '@ram-altman.local>'),
        'MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8', 'Content-Transfer-Encoding: base64',
        'Auto-Submitted: auto-generated', '', $body, ''
    )
    return ($lines -join "`r`n")
}

function Send-RamAltmanGmail {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Email, [string]$AccessToken)
    if (-not $AccessToken) { $AccessToken = Get-RamAltmanGmailAccessToken -Config $Config }
    if ([string]::IsNullOrWhiteSpace($AccessToken) -or $AccessToken -match '[\r\n\x00]') { throw 'Invalid Gmail access token.' }
    $mime = New-GmailMimeMessage $Config $Email
    $raw = ConvertTo-GmailBase64Url ([Text.Encoding]::UTF8.GetBytes($mime))
    $body = @{ raw = $raw } | ConvertTo-Json -Compress
    # Exactly one send request; the outer monitor owns reservation/retry policy.
    try {
        $result = Invoke-GmailOAuthHttp -Uri $script:GmailSendEndpoint -Method Post -Headers @{ Authorization = 'Bearer ' + $AccessToken } -Body $body -ContentType 'application/json; charset=utf-8'
    } catch {
        $failure = $_.Exception
        if ($failure.Data['RamAltmanHttpStatus'] -eq 401) {
            # Retry on the next scheduled check with a refreshed token. Never
            # issue another send request within the current reserved attempt.
            try {
                $token = Read-GmailEncryptedToken $Config.GmailTokenPath
                if ($token.AccessToken -eq $AccessToken) {
                    $token.ExpiresAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
                    Write-GmailEncryptedToken $Config.GmailTokenPath $token
                }
            } catch { $failure.Data['RamAltmanTokenCacheInvalidationFailed'] = $true }
        }
        throw $failure
    }
    $id = Get-GmailProperty $result 'id'
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'Gmail did not confirm a message ID; delivery is uncertain.' }
    [pscustomobject]@{ Id = $id; ThreadId = (Get-GmailProperty $result 'threadId' '') }
}

Export-ModuleMember -Function Start-RamAltmanGmailAuthorization,Get-RamAltmanGmailAccessToken,Send-RamAltmanGmail,Test-RamAltmanGmailToken
