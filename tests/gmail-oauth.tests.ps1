# Standalone Gmail tests: mock Google/browser, real loopback and Windows DPAPI.
# No real Google authorization, credentials, or email delivery occurs.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repository 'windows\GmailOAuth.psm1'
Import-Module $modulePath -Force
$module = Get-Module GmailOAuth
$script:passed = 0
function Assert-Gmail {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Gmail assertion failed: $Message" }
    $script:passed++
    Write-Host "ok $Message"
}
function Assert-GmailThrows {
    param([scriptblock]$Action, [string]$Description)
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-Gmail $thrown $Description
}
$private = Join-Path $repository 'private'
$work = Join-Path $private ('test-gmail-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force
$clientPath = Join-Path $work 'client.json'
$tokenPath = Join-Path $work 'token.dpapi'
$sender = 'fixture-sender@example.com'
$clientJson = @{ installed = @{ client_id = '123456-fixture.apps.googleusercontent.com'; client_secret = 'PUBLIC-DESKTOP-CLIENT-FIXTURE'; token_uri = 'https://untrusted.example.invalid/' } }
$clientJson | ConvertTo-Json | Set-Content -LiteralPath $clientPath -Encoding UTF8
$config = [pscustomobject]@{ Sender = $sender; SenderName = 'RAM owner'; Recipient = 'recipient@example.com'; GmailClientPath = $clientPath; GmailTokenPath = $tokenPath }
try {
    $challenge = & $module { Get-GmailOAuthChallenge 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk' }
    Assert-Gmail ($challenge -eq 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM') 'PKCE S256 matches the published reference vector'
    $random = @(& $module { New-GmailOAuthRandom; New-GmailOAuthRandom })
    Assert-Gmail ($random[0] -match '^[A-Za-z0-9_-]{43}$' -and $random[0] -ne $random[1]) 'cryptographic verifier/state use unique 256 bit base64url values'
    $query = & $module { ConvertFrom-GmailQuery (ConvertTo-GmailQuery @{ state = 'space + plus/and='; code = 'abc=123' }) }
    Assert-Gmail ($query.state -eq 'space + plus/and=' -and $query.code -eq 'abc=123') 'callback query encoding preserves reserved characters'
    Assert-GmailThrows { & $module { ConvertFrom-GmailQuery 'state=a&state=b' } } 'duplicate callback state is rejected'
    Assert-Gmail (-not (& $module { Test-GmailGrantedScopes 'openid email' })) 'Gmail sending permission is required'
    Assert-Gmail (-not (& $module { Test-GmailGrantedScopes 'https://www.googleapis.com/auth/gmail.send' })) 'identity permission is required to verify sender'
    $webPath = Join-Path $work 'web-client.json'
    @{ web = @{ client_id = '123-fixture.apps.googleusercontent.com' } } | ConvertTo-Json | Set-Content -LiteralPath $webPath
    Assert-GmailThrows { & $module { param($Path) Read-GmailDesktopClient $Path } $webPath } 'web OAuth clients cannot substitute for Desktop clients'

    & $module {
        $script:OriginalHttp = ${function:Invoke-GmailOAuthHttp}
        $script:MockIdentity = 'fixture-sender@example.com'
        $script:MockCallbackMode = 'invalid-first'
        $script:MockCalls = @()
        $script:MockAuthQuery = @{}
        $script:MockMissingMessageId = $false
        $script:MockSendStatus = 0
        function script:Start-Process {
            param([string]$FilePath)
            $authorization = New-Object Uri($FilePath)
            if ($authorization.Host -ne 'accounts.google.com') { throw 'Unexpected authorization host.' }
            $script:MockAuthQuery = ConvertFrom-GmailQuery $authorization.Query
            $redirect = New-Object Uri($script:MockAuthQuery.redirect_uri)
            $requests = @()
            if ($script:MockCallbackMode -eq 'invalid-first') {
                $requests += '/wrong-path?state=' + $script:MockAuthQuery.state + '&code=WRONG'
                $requests += '/?state=WRONG&code=WRONG'
            }
            if ($script:MockCallbackMode -eq 'denied') {
                $requests += '/?state=' + $script:MockAuthQuery.state + '&error=access_denied'
            } else { $requests += '/?state=' + $script:MockAuthQuery.state + '&code=FIXTURE-CODE' }
            foreach ($request in $requests) {
                $connection = New-Object Net.Sockets.TcpClient
                try {
                    $connection.Connect([Net.IPAddress]::Loopback, $redirect.Port)
                    $bytes = [Text.Encoding]::ASCII.GetBytes("GET $request HTTP/1.1`r`nHost: 127.0.0.1:$($redirect.Port)`r`nConnection: close`r`n`r`n")
                    $connection.GetStream().Write($bytes, 0, $bytes.Length)
                } finally { $connection.Dispose() }
            }
        }
        function script:Invoke-GmailOAuthHttp {
            param([string]$Uri, [string]$Method, $Body, [hashtable]$Headers = @{}, [string]$ContentType)
            $script:MockCalls += @{Uri=$Uri; Method=$Method; Body=$Body; Headers=$Headers; ContentType=$ContentType}
            if ($Uri -eq 'https://oauth2.googleapis.com/token') {
                if ($Body.grant_type -eq 'authorization_code') {
                    if ((Get-GmailOAuthChallenge $Body.code_verifier) -ne $script:MockAuthQuery.code_challenge -or $Body.code -ne 'FIXTURE-CODE') { throw 'PKCE/code fixture mismatch.' }
                    return [pscustomobject]@{access_token='FIXTURE-ACCESS-TOKEN'; refresh_token='FIXTURE-REFRESH-TOKEN'; expires_in=3600; scope='openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/gmail.send'; token_type='Bearer'}
                }
                return [pscustomobject]@{access_token='FIXTURE-RENEWED-ACCESS'; expires_in=3600; token_type='Bearer'}
            }
            if ($Uri -eq 'https://openidconnect.googleapis.com/v1/userinfo') {
                return [pscustomobject]@{email=$script:MockIdentity; email_verified=$true; sub='fixture-account-subject'}
            }
            if ($Uri -eq 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send') {
                if ($script:MockSendStatus -gt 0) {
                    $failure = New-Object InvalidOperationException('Fixture known API rejection')
                    $failure.Data['RamAltmanHttpStatus'] = $script:MockSendStatus
                    $failure.Data['RamAltmanDefiniteRejection'] = $true
                    throw $failure
                }
                if ($script:MockMissingMessageId) { return [pscustomobject]@{} }
                return [pscustomobject]@{id='fixture-message-id'; threadId='fixture-thread-id'}
            }
            throw 'Unexpected network endpoint.'
        }
    }
    $authorized = Start-RamAltmanGmailAuthorization -ClientPath $clientPath -TokenPath $tokenPath -ExpectedSender $sender
    Assert-Gmail ($authorized.Authorized -and $authorized.Email -eq $sender) 'browser OAuth completes through a real random-port loopback callback'
    $authorization = & $module { $script:MockAuthQuery }
    Assert-Gmail ($authorization.redirect_uri -match '^http://127\.0\.0\.1:\d+/$' -and $authorization.code_challenge_method -eq 'S256' -and $authorization.access_type -eq 'offline') 'authorization uses PKCE and offline access on IPv4 loopback only'
    Assert-Gmail ((@($authorization.scope -split ' ') | Sort-Object) -join ' ' -eq 'email https://www.googleapis.com/auth/gmail.send openid') 'requested scopes are send-only Gmail plus email identity'
    Assert-Gmail ((Test-RamAltmanGmailToken -Path $tokenPath -ExpectedSender $sender)) 'saved token validates and matches the verified sender'
    Assert-Gmail (-not (Test-RamAltmanGmailToken -Path $tokenPath -ExpectedSender 'wrong@example.com')) 'sender mismatch fails token validation'
    $disk = Get-Content -LiteralPath $tokenPath -Raw
    Assert-Gmail ($disk -match '^[0-9a-f]+$' -and $disk -notmatch 'FIXTURE-ACCESS|FIXTURE-REFRESH|fixture-sender') 'disk contains only DPAPI ciphertext, including encrypted identity and access token'
    $before = @(& $module { $script:MockCalls }).Count
    Assert-Gmail ((Get-RamAltmanGmailAccessToken -Config $config) -eq 'FIXTURE-ACCESS-TOKEN') 'unexpired access token is reused'
    $after = @(& $module { $script:MockCalls }).Count
    Assert-Gmail ($before -eq $after) 'cached access needs no Google network request'
    & $module { param($Path) $token = Read-GmailEncryptedToken $Path; $token.ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o'); Write-GmailEncryptedToken $Path $token } $tokenPath
    Assert-Gmail ((Get-RamAltmanGmailAccessToken -Config $config) -eq 'FIXTURE-RENEWED-ACCESS') 'expired access token refreshes through the fixed Google endpoint'
    $retained = & $module { param($Path) (Read-GmailEncryptedToken $Path).RefreshToken } $tokenPath
    Assert-Gmail ($retained -eq 'FIXTURE-REFRESH-TOKEN') 'refresh responses without a replacement retain the original refresh token'
    $wrongConfig = [pscustomobject]@{Sender='wrong@example.com'; GmailClientPath=$clientPath; GmailTokenPath=$tokenPath}
    Assert-GmailThrows { Get-RamAltmanGmailAccessToken -Config $wrongConfig } 'wrong configured sender cannot use saved authorization'
    $corruptPath = Join-Path $work 'corrupt.dpapi'
    'not-a-dpapi-token' | Set-Content -LiteralPath $corruptPath
    Assert-Gmail (-not (Test-RamAltmanGmailToken -Path $corruptPath)) 'corrupt ciphertext fails closed'

    $subject = ('A long RAM report ' * 10) + [char]0x00E9 + [char]0xD83D + [char]0xDE00
    $message = [pscustomobject]@{Subject=$subject; Body=('Memory ' + [char]0x00E9 + "`r`nSecond line")}
    $sent = Send-RamAltmanGmail -Config $config -Email $message -AccessToken 'FIXTURE-ACCESS'
    Assert-Gmail ($sent.Id -eq 'fixture-message-id') 'send returns the confirmed Gmail message ID'
    $sendCalls = @(& $module { @($script:MockCalls | Where-Object {$_.Uri -like '*/messages/send'}) })
    Assert-Gmail ($sendCalls.Count -eq 1 -and $sendCalls[0].Headers.Authorization -eq 'Bearer FIXTURE-ACCESS') 'delivery makes exactly one authenticated send request'
    $raw = ($sendCalls[0].Body | ConvertFrom-Json).raw
    Assert-Gmail ($raw -notmatch '[+/=]') 'Gmail raw MIME uses unpadded base64url'
    $base64 = $raw.Replace('-', '+').Replace('_', '/')
    $base64 += '=' * ((4 - $base64.Length % 4) % 4)
    $mime = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64))
    $parts = $mime -split "`r`n`r`n", 2
    $decodedBody = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1].Trim()))
    Assert-Gmail ($decodedBody -eq $message.Body -and $mime.Contains('Auto-Submitted: auto-generated')) 'RFC5322 MIME preserves UTF8 body and automation footer header'
    $subjectLine = [regex]::Match($parts[0], '(?ms)^Subject: (.*?)(?=\r\n[^ ])').Groups[1].Value
    $decodedSubject = ''
    $words = [regex]::Matches($subjectLine, '=\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=')
    foreach ($word in $words) { $decodedSubject += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($word.Groups[1].Value)) }
    Assert-Gmail ($decodedSubject -eq $subject -and @($words | Where-Object {$_.Value.Length -gt 75}).Count -eq 0) 'long Unicode subject folds within RFC2047 encoded-word limits'
    Assert-GmailThrows { Send-RamAltmanGmail -Config $config -Email ([pscustomobject]@{Subject="injected`r`nBcc: bad@example.com";Body='test'}) -AccessToken 'FIXTURE' } 'header injection is rejected before send'
    & $module { $script:MockMissingMessageId = $true }
    Assert-GmailThrows { Send-RamAltmanGmail -Config $config -Email $message -AccessToken 'FIXTURE' } 'missing Gmail message acknowledgement is uncertain, never silently successful'
    & $module { $script:MockMissingMessageId=$false; $script:MockSendStatus=401 }
    $before401 = @(& $module { @($script:MockCalls | Where-Object {$_.Uri -like '*/messages/send'}) }).Count
    $failure401 = $null
    try { Send-RamAltmanGmail -Config $config -Email $message | Out-Null } catch { $failure401 = $_.Exception }
    Assert-Gmail ($null -ne $failure401) 'HTTP401 propagates without an immediate second send'
    $invalidated = & $module { param($Path) Read-GmailEncryptedToken $Path } $tokenPath
    Assert-Gmail ([DateTimeOffset]::Parse($invalidated.ExpiresAtUtc) -lt [DateTimeOffset]::UtcNow -and $invalidated.RefreshToken -eq 'FIXTURE-REFRESH-TOKEN') 'HTTP401 expires cached access while preserving encrypted refresh credentials'
    $after401 = @(& $module { @($script:MockCalls | Where-Object {$_.Uri -like '*/messages/send'}) }).Count
    Assert-Gmail ($after401 -eq $before401 + 1) 'HTTP401 causes exactly one send request in this attempt'
    $beforeRefresh = @(& $module { @($script:MockCalls | Where-Object {$_.Uri -eq 'https://oauth2.googleapis.com/token'}) }).Count
    $null = Get-RamAltmanGmailAccessToken -Config $config
    $afterRefresh = @(& $module { @($script:MockCalls | Where-Object {$_.Uri -eq 'https://oauth2.googleapis.com/token'}) }).Count
    Assert-Gmail ($afterRefresh -eq $beforeRefresh + 1) 'next scheduled preflight refreshes after HTTP401'

    & $module { $script:MockIdentity='other@example.com' }
    $mismatchPath = Join-Path $work 'mismatch.dpapi'
    Assert-GmailThrows { Start-RamAltmanGmailAuthorization -ClientPath $clientPath -TokenPath $mismatchPath -ExpectedSender $sender } 'wrong Google account is refused after userinfo verification'
    Assert-Gmail (-not (Test-Path -LiteralPath $mismatchPath)) 'wrong-account authorization writes no token'
    & $module { $script:MockCallbackMode='denied' }
    Assert-GmailThrows { Start-RamAltmanGmailAuthorization -ClientPath $clientPath -TokenPath $mismatchPath -ExpectedSender $sender } 'user denying browser consent leaves setup cleanly'

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
public class RamAltmanGmailTestResponse : WebResponse {
    public int StatusCode { get; private set; }
    private string body;
    public RamAltmanGmailTestResponse(int status, string json) { StatusCode=status; body=json; }
    public override Stream GetResponseStream() { return new MemoryStream(Encoding.UTF8.GetBytes(body)); }
}
'@
    & $module {
        $script:MockHttpStatus = 401
        $script:MockTransportMode = ''
        function script:Invoke-RestMethod {
            param($Uri,$Method,$Headers,$TimeoutSec,$MaximumRedirection,$ErrorAction,$Body,$ContentType)
            if ($script:MockTransportMode) {
                if ($script:MockTransportMode -in @('NameResolutionFailure','ProxyNameResolutionFailure','Timeout','ConnectFailure')) {
                    $status = [Net.WebExceptionStatus]$script:MockTransportMode
                    throw (New-Object Net.WebException('Fixture transport error', $null, $status, $null))
                }
                $socket = New-Object Net.Sockets.SocketException([int][Net.Sockets.SocketError]$script:MockTransportMode)
                throw (New-Object Net.WebException('Fixture transport error', $socket, [Net.WebExceptionStatus]::ConnectFailure, $null))
            }
            $response = New-Object RamAltmanGmailTestResponse($script:MockHttpStatus, '{"error":"invalid_grant"}')
            throw (New-Object Net.WebException('Fixture redacted transport error', $null, [Net.WebExceptionStatus]::ProtocolError, $response))
        }
    }
    foreach ($status in @(400,401,403,404,409,413,422,429,408,500,503)) {
        $failure = & $module {
            param($Status)
            $script:MockHttpStatus = $Status
            try { & $script:OriginalHttp -Uri 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send' -Method Post -Body '{}' }
            catch { return $_.Exception }
        } $status
        $expected = $status -in @(400,401,403,404,409,413,422,429)
        Assert-Gmail ([bool]$failure.Data['RamAltmanDefiniteRejection'] -eq $expected -and $failure.Data['RamAltmanHttpStatus'] -eq $status) "HTTP $status uses the correct definite-rejection versus uncertain policy"
    }
    foreach ($mode in @('NameResolutionFailure','ProxyNameResolutionFailure','HostNotFound','NoData','TryAgain','ConnectionRefused','NetworkUnreachable','HostUnreachable','ConnectionReset','Timeout','ConnectFailure')) {
        $failure = & $module {
            param($Mode)
            $script:MockTransportMode = $Mode
            try { & $script:OriginalHttp -Uri 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send' -Method Post -Body '{}' }
            catch { return $_.Exception }
        } $mode
        $expected = $mode -in @('NameResolutionFailure','ProxyNameResolutionFailure','HostNotFound','NoData','TryAgain','ConnectionRefused')
        Assert-Gmail ([bool]$failure.Data['RamAltmanDefiniteRejection'] -eq $expected) "$mode preserves only proven pre-connection retryability"
    }
} finally {
    Import-Module $modulePath -Force
    $fullWork = [IO.Path]::GetFullPath($work)
    $privatePrefix = [IO.Path]::GetFullPath($private).TrimEnd('\') + '\'
    if (-not $fullWork.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refused cleanup outside project private directory.' }
    if (Test-Path -LiteralPath $fullWork) { Remove-Item -LiteralPath $fullWork -Recurse -Force }
}
Write-Host "$script:passed Gmail OAuth checks passed. No real Google requests or email delivery occurred."
