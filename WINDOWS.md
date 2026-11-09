# RamAltman for Windows

Native Windows fork of [Iain Kay's Ram-Altman](https://github.com/IainKay/ram-altman), inspired by its [email previews](https://ram-altman.lol/). Reports how much RAM Sam missed, with bonus NVIDIA VRAM figures.

Every email puts **available GiB and percentage in the subject**, then opens with a prominent summary. Illustrative example (these numbers are not a machine capture):

```text
Subject: [RAM: 12.80 GiB available / 80.0%] You missed a spot

Hi Sam,

12.80 GiB OF 16.00 GiB OF SYSTEM RAM IS AVAILABLE RIGHT NOW (80.0%).

  Available / idle capacity:  12.80 GiB (80.0%)
  Total usable system RAM:   16.00 GiB
  In use:                    3.20 GiB

...one of ten rotating messages...

BONUS: GPU MEMORY WITH ROOM TO SPARE
  NVIDIA GPU: 6.00 GiB of 8.00 GiB of VRAM available (75.0%).
```

Every run takes a fresh snapshot. Eight subjects, ten messages, and six sign-offs rotate through shuffle bags without immediate repeats across cycles. Wording retains the upstream humor with Windows references.

## Setup

Requires Windows, built-in Windows PowerShell 5.1, Task Scheduler, and Google browser authorization using your own Desktop OAuth client. Normal operation needs no WSL, Python, admin rights, extra PowerShell modules, or persistent background process. Optional VRAM readings use the NVIDIA driver's installed `nvidia-smi` executable. SMTP with STARTTLS is an alternative delivery method.

1. Double-click **Status.cmd** for live RAM and VRAM figures.
2. Double-click **Preview.cmd** to print an email. It sends nothing and changes no logs, credentials, configuration, or delivery state.
3. Follow [Google setup](GOOGLE-SETUP.md), then double-click **Setup.cmd**. Keep the prefilled sender/recipient, choose Gmail OAuth, and provide the Desktop client JSON. Google handles sign-in in your browser; the app never asks for your Google password.
4. Review the live preview and choose whether to enable automatic delivery. The task starts in about one minute, then checks every five minutes and at logon.

The recipient is configurable. Neither upstream nor this fork bundles Sam's email address. You must supply it.

**Initial checkout:** no production task or email credentials are installed. Status and Preview work immediately. Sending begins after local setup enables the task.

## Complete on/off controls

**Enable.cmd** verifies saved authorization, enables the configuration and installs/enables the owned task. **Disable.cmd** saves off first, disables/stops the owned task, and verifies its launcher and child processes have exited. Process cleanup targets exact executable, arguments, Windows account, process ID and start time, protecting unrelated processes and tasks. A control lock prevents racing controls.

While off, a manual live launch exits before RAM/VRAM sampling, Google access or delivery state writes. Status and Preview remain available on request. No custom Windows service, tray process or daemon is installed; the shared Windows Task Scheduler service is left running. Saved authorization/history remain for easy reactivation. A message already accepted by Gmail cannot be unsent by disabling.

## Behavior and memory definitions

- Send when **available system RAM is at least 10%**, including exactly 10%. The comparison uses raw bytes, before display rounding.
- Send at most once per **local calendar day** for this configuration and state directory. A below-threshold check does not consume that day.
- Each invocation exits after its work. An exclusive file lock covers manual and overlapping runs. Durable state survives process exit and reboot.
- VRAM is additional information, **not another trigger**. NVIDIA adapters with valid driver telemetry are listed separately. AMD/Intel/shared GPU memory and unknown figures are not estimated.
- The scheduled task runs while the configuring Windows user is logged on, including a locked session. It does not run while signed out or powered off. Checks continue on resume/logon; missed days do not generate a backlog. The project folder must remain accessible.

“Idle capacity” means **available physical RAM at the instant sampled**, including reclaimable standby cache. It is not an idle-time measurement. Windows reports OS-usable physical RAM, which can be lower than installed DIMM capacity due to hardware reservations. VRAM availability describes memory capacity, not GPU compute utilization. Driver-reserved VRAM can make total differ from used plus available; the email uses the driver's reported free figure.

## Gmail OAuth and local credentials

Gmail OAuth requests `gmail.send`, `openid`, and `email`: sending and verified sender identity, with no mailbox reading permission. Browser authorization uses PKCE, random state, and a temporary `127.0.0.1` listener that closes on completion/timeout. Tokens are encrypted with Windows DPAPI for the same user and PC. Refresh happens automatically; expired or revoked permission requires reconnecting.

Google External/Testing authorizations expire after seven days for Gmail scopes. A personal In production registration supports sustained operation, subject to Google policy and possible unverified-app warnings. This is API registration, not cloud hosting of the Windows monitor. See [the setup guide](GOOGLE-SETUP.md).

## Optional SMTP mode

The default is STARTTLS on port 587 with certificate validation. Port 465/implicit TLS is rejected. Providers requiring OAuth-only SMTP need a compatible relay; this version supports username/password authentication or an unauthenticated relay. It does not bypass provider authentication. Unencrypted SMTP is allowed only for an explicitly configured loopback server for local testing.

Setup saves `private/config.json` and uses Windows DPAPI through `Export-Clixml` for credentials. Only the same Windows account on the same PC can decrypt them. The task uses that account's interactive token, with no password in its command line. Setup restricts the private folder's ACL to that account and SYSTEM. Rerun setup after moving PCs or changing accounts.

For personal Gmail, use `smtp.gmail.com`, port `587`, STARTTLS, your full Gmail address as username, and a [Google app password](https://support.google.com/accounts/answer/185833?hl=en). App passwords require 2-Step Verification and may be unavailable under some account policies. Enter it only in the hidden local setup prompt. Saved configuration values are offered as defaults when setup runs again.

Default runtime files stay under the ignored `private/` folder:

| File | Purpose |
| --- | --- |
| `config.json` | Recipient, sender, SMTP settings, threshold and paths |
| `smtp*.credential.xml` | DPAPI-encrypted SMTP credential |
| `gmail-client*.json` | Your registered Google Desktop OAuth client configuration |
| `gmail*.token.xml` | DPAPI-encrypted Google access/refresh token data |
| `state/state.json` | Daily reservation/result and shuffle bags |
| `state/monitor.lock` | Exclusive process lock |
| `state/usage.csv` | RAM samples; after 10 MiB, retain latest 10,000 lines |
| `state/events.jsonl` | Outcomes; after 1 MiB, retain latest 1,000 lines |

All settings are shown in `windows/config.example.json`. Relative paths resolve against the configuration file's directory. Private configuration, backups, and credentials are ignored by Git. **Do not delete delivery state to retry the program:** that removes its daily guard. Use Preview instead.

## Failed delivery and duplicates

A durable `Sending` reservation is flushed to disk **before submission**. Gmail acceptance requires a returned message ID; SMTP acceptance is also supported. Success records `Sent` and a receipt with sender, recipient, subject, RAM snapshot, body SHA-256 and Gmail message/thread IDs when available. Explicit negative provider replies and proven pre-connection failures permit retry on a later check. Authorization refresh precedes reservation. A rejected Gmail access token is invalidated for refresh on the next check.

If the connection disappears after submission, the server might already have accepted the email. Ambiguous failures, including timeouts, record `Uncertain` and block further sends that local day. A crash leaving `Sending` is handled the same way. The next day can try again. This favors avoiding duplicates over retrying potentially accepted messages. SMTP acceptance cannot prove inbox delivery.

Corrupt state or a clock earlier than the saved delivery date fails closed. Preserve the state for inspection. Exit codes: `0` success/skipped/preview; `1` config or definite failure; `2` uncertain delivery. Inspect `private/state/events.jsonl` and your SMTP provider's activity. Secrets are never logged.

## Commands

From the repository folder in PowerShell:

```powershell
# Read-only live status / preview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\ram-altman.ps1 -Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\ram-altman.ps1 -DryRun

# Configure without enabling email
.\windows\setup.ps1 -ConfigureOnly

# Inspect task XML, install a configured task, or remove it
.\windows\install-task.ps1 -PlanOnly
.\windows\install-task.ps1
.\windows\uninstall-task.ps1
```

Task name: `RamAltman-<Windows SID>`. Install/removal refuses an existing task unless ownership and executable match this checkout. Uninstall retains configuration/history. Setup pauses an existing task during reconfiguration and keeps a backup. Uninstall before moving the folder, then reinstall from the new location.

## Tests

Tests use synthetic memory, disposable local tasks, and a **loopback-only SMTP capture server**. They never send external mail. Python is required only for the SMTP integration test.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows-core.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-vram.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\test-scheduler.ps1 -RegisterSmokeTask
python .\tests\smtp-loopback.tests.py
```

Actual results and setup requirements: [validation/ACCEPTANCE.md](validation/ACCEPTANCE.md).

## Provenance and references

Upstream commit: `b451bc2ed31d0a85260b92e3acc83b61ebc9a0c2`. Original Bash scripts, Git history, and `README.upstream.md` are retained. Windows fork: [Slyrae/ram-altman](https://github.com/Slyrae/ram-altman), branch `windows-native`. The original upstream is retained separately. Same [Unlicense](LICENSE) as upstream.

References: [Windows memory definition](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/ns-sysinfoapi-memorystatusex), [STARTTLS support](https://learn.microsoft.com/en-us/dotnet/api/system.net.mail.smtpclient.enablessl?view=netframework-4.8.1), [DPAPI credential export](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/export-clixml?view=powershell-5.1), [NVIDIA telemetry](https://docs.nvidia.com/deploy/nvidia-smi/index.html).
