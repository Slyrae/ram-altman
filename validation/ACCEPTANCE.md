# Windows qualification summary

The Windows fork is developed and checked locally. Public qualification records contain summary counts; private machine captures, account identifiers, tokens, task identities, and delivery receipts are excluded.

## Local verification

The current implementation passed 179 local checks:

| Area | Passing checks |
| --- | ---: |
| Core memory, threshold, state, locking, daily delivery and receipt behavior | 49 |
| Loopback SMTP integration | 4 |
| Gmail OAuth, PKCE, callback, encrypted token handling, MIME and failure policy | 55 |
| Windows scheduler definitions and disposable task smoke checks | 27 |
| Enable/disable process ownership and full-stop controls | 17 |
| Interactive setup and saved-default behavior | 12 |
| Optional NVIDIA VRAM reporting and bounded subprocess failures | 15 |
| **Total** | **179** |

The Gmail tests mock Google endpoints and browser launch while exercising a real local TCP callback listener and Windows DPAPI. SMTP integration uses a loopback-only capture service. Scheduler and control checks use disposable local tasks and processes. These checks do not send email to an external recipient.

## Live account qualification

Actual Gmail operation has been verified locally:

- Browser authorization confirmed the configured sender, and OAuth access-token refresh succeeded.
- A natural scheduled monitor run submitted a report successfully. The sender's Gmail Sent record and the local body hash independently matched the delivery receipt.
- A self-addressed report using the final email copy was independently observed in both Gmail Sent and Inbox.
- A later natural scheduled check suppressed another report for the same day; the existing production delivery receipt remained unchanged.
- Complete OFF stopped and disabled the owned task, left no owned monitoring processes, and preserved delivery state during observation. Turning the monitor back ON restored the configured task.

The associated receipts, account information, message identifiers, machine measurements, and screenshots remain private. Provider acceptance and a Sent record establish submission; they do not establish delivery to a recipient's inbox. The self-addressed Inbox observation is a separate check.

## Relevant behavior

- The inclusive RAM trigger uses unrounded available physical bytes: at least 10% by default.
- A persistent, flushed reservation and exclusive lock protect the daily limit across overlapping runs and restarts.
- Known negative provider replies and proven pre-connection failures can be retried on a later check. An ambiguous submission blocks further sends for that local day.
- The Gmail option requests send-only mail permission plus verified email identity. Tokens are encrypted locally for the same Windows user and computer.
- Optional NVIDIA VRAM telemetry uses a bounded driver query. Unsupported telemetry remains unknown and does not prevent the RAM report.
- Disable turns off the saved configuration, stops/disables the owned task, and checks that its monitoring process tree has exited.

Google External/Testing registrations expire their Gmail authorization after seven days. Sustained personal use requires appropriate Google registration and remains subject to revocation and provider policy. See [Google setup](../GOOGLE-SETUP.md), [Windows usage](../WINDOWS.md), and the [privacy policy](../docs/privacy.html).
