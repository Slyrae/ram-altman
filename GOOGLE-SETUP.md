# One-time standalone Gmail authorization

The Windows app sends through Google's Gmail API. It never needs your Google password or an app password. It needs your own Desktop OAuth client and browser consent. Tokens are encrypted locally with Windows DPAPI.

## Register the Desktop client

1. Open [Google Cloud Console credentials](https://console.cloud.google.com/apis/credentials) as your sender account. Review and accept any first-time terms yourself.
2. Create/select a project such as `RamAltman Windows`. This registers API access; it creates no hosted server, VM, task, or Windows service.
3. Enable **Gmail API** in the [API Library](https://console.cloud.google.com/apis/library/gmail.googleapis.com).
4. Configure **Google Auth Platform** branding and an **External** audience for a personal Gmail account. Use your own email for support/developer contact.
5. Add the scopes `https://www.googleapis.com/auth/gmail.send`, `openid`, and `email`. These give sending and verified identity; no mailbox reading.
6. Create an OAuth client of type **Desktop app**, named `RamAltman Windows`, and download its JSON. Save it under this checkout's ignored `private/` folder, or point setup at the download; setup copies it and preserves the original.
7. In **Testing**, add your sender as a test user. For sustained operation, use **In production**: Testing authorizations/refresh tokens expire after seven days for Gmail scopes. Google's personal-use verification exception may avoid public verification, but an unverified-app warning can remain. Review Google's authorization screen yourself and authorize only your own known app.

Google account policies may block authorization. Do not disable account protections to bypass a block; follow Google's instructions or use a supported relay.

## Connect and control

1. Double-click `Setup.cmd` and keep the saved sender/recipient.
2. Choose Gmail OAuth and provide the Desktop client JSON path.
3. Sign in and approve the displayed permissions in Google's browser page. Choose the configured sender; the app rejects a different or unverified account.
4. Return to setup and review the email preview. Choose whether to enable automatic sending. The first check starts in about one minute, then every five minutes.
5. Use `Disable.cmd` for a complete stop, `Enable.cmd` to reactivate, and `Status.cmd` to inspect status and memory.

Connecting Gmail does not send email. Submission starts after enabling and meeting the RAM threshold. Disable retains the encrypted token; access can also be revoked from [Google third-party connections](https://myaccount.google.com/connections).

## Real delivery acceptance

Local tests use synthetic tokens and simulated Google responses. They do not prove account authorization or real delivery. Completion requires a dry run, a test email, a report sent by the scheduled task, the matching Gmail Sent record, duplicate suppression on a later automatic check, and full shutdown/re-enable verification. Retain the Gmail message ID and local body hash. Current status: [validation/ACCEPTANCE.md](validation/ACCEPTANCE.md).

Official references: [Desktop OAuth and PKCE](https://developers.google.com/identity/protocols/oauth2/native-app), [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [Testing expiry](https://support.google.com/cloud/answer/15549945), [personal-use verification exception](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification#exceptions_to_verification_requirements).
