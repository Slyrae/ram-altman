"""Exercise the real Windows SMTP client against a loopback-only capture server.

Uses only Python's standard library. No DNS lookup or external mail delivery occurs.
Run with: python tests/smtp-loopback.tests.py
"""

from __future__ import annotations

import hashlib
import json
import os
from email import policy
from email.parser import Parser
from pathlib import Path
import socketserver
import subprocess
import threading
import time


ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "validation" / f"smtp-fixtures-{os.getpid()}-{int(time.time())}"
POWERSHELL = Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"


class CaptureServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, mode: str):
        self.mode = mode
        self.messages: list[str] = []
        self.connections = 0
        super().__init__(("127.0.0.1", 0), SMTPHandler)

    def __exit__(self, exc_type, exc_value, traceback):
        self.shutdown()
        self.server_close()


class SMTPHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.server.connections += 1
        self.connection.settimeout(15)
        self.wfile.write(b"220 localhost RamAltman test receiver\r\n")
        while line := self.rfile.readline():
            command = line.decode("ascii", errors="replace").strip().upper()
            if command.startswith(("EHLO ", "HELO ")):
                self.wfile.write(b"250-localhost\r\n250 SIZE 1048576\r\n")
            elif command.startswith("MAIL FROM:"):
                self.wfile.write(b"250 2.1.0 Sender accepted\r\n")
            elif command.startswith("RCPT TO:"):
                if self.server.mode == "reject":
                    self.wfile.write(b"550 5.1.1 Definite test rejection\r\n")
                else:
                    self.wfile.write(b"250 2.1.5 Recipient accepted\r\n")
            elif command == "DATA":
                self.wfile.write(b"354 End with a single dot\r\n")
                payload = []
                while (data_line := self.rfile.readline()) not in (b".\r\n", b""):
                    payload.append(data_line)
                self.server.messages.append(b"".join(payload).decode("utf-8", errors="replace"))
                if self.server.mode == "ambiguous":
                    return  # Captured DATA, deliberately lose the acceptance acknowledgement.
                self.wfile.write(b"250 2.0.0 Message accepted\r\n")
            elif command == "QUIT":
                self.wfile.write(b"221 2.0.0 Bye\r\n")
                return
            elif command == "RSET":
                self.wfile.write(b"250 2.0.0 Reset\r\n")
            else:
                self.wfile.write(b"502 5.5.1 Unsupported test command\r\n")


def quoted(path: Path) -> str:
    return "'" + str(path).replace("'", "''") + "'"


def invoke(config: Path) -> subprocess.CompletedProcess[str]:
    script = config.parent / "invoke.ps1"
    script.write_text(
        "$ErrorActionPreference = 'Stop'\n"
        f"Import-Module {quoted(ROOT / 'windows/RamAltman.psm1')} -Force\n"
        f"$config = Read-RamAltmanConfig -Path {quoted(config)}\n"
        "$memory = [pscustomobject]@{TotalBytes=1000000L;AvailableBytes=500000L;"
        "UsedBytes=500000L;AvailablePercent=50.0}\n"
        "try {\n"
        "  $result = Invoke-RamAltmanCheck -Config $config -Memory $memory\n"
        "  $result | ConvertTo-Json -Depth 8\n"
        "} catch { Write-Output ('EXPECTED-OR-UNEXPECTED-ERROR: ' + $_.Exception.Message); exit 1 }\n",
        encoding="utf-8-sig",
    )
    return subprocess.run(
        [str(POWERSHELL), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(script)],
        capture_output=True,
        text=True,
        timeout=30,
    )


def make_config(folder: Path, port: int) -> Path:
    folder.mkdir(parents=True)
    config = folder / "config.json"
    config.write_text(json.dumps({
        "Recipient": "recipient@example.invalid",
        "Sender": "sender@example.invalid",
        "SenderName": "Loopback transport test",
        "ThresholdPercent": 10,
        "SmtpHost": "127.0.0.1",
        "SmtpPort": port,
        "UseSsl": False,
        "CredentialPath": "",
        "StateDirectory": "state",
        "TimeoutSeconds": 5,
    }, indent=2), encoding="utf-8")
    return config


def check(condition: bool, message: str):
    if not condition:
        raise AssertionError(message)


def successful_delivery():
    with CaptureServer("success") as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        config = make_config(FIXTURES / "success", server.server_address[1])
        first = invoke(config)
        check(first.returncode == 0, first.stdout + first.stderr)
        check(len(server.messages) == 1, "Actual SMTP client did not submit exactly one message.")
        wire = server.messages[0]
        message = Parser(policy=policy.default).parsestr(wire)
        check(message["Auto-Submitted"] == "auto-generated", "Auto-Submitted header missing.")
        check("Hi Sam," in message.get_content(), "Expected email body not present in SMTP MIME content.")
        check("recipient@example.invalid" in str(message["To"]), "Recipient not present on SMTP wire.")
        check("sender@example.invalid" in str(message["From"]), "Sender not present on SMTP wire.")
        connections_before = server.connections
        second = invoke(config)
        check(second.returncode == 0, second.stdout + second.stderr)
        check(len(server.messages) == 1, "Repeated process submitted a duplicate daily email.")
        check(server.connections == connections_before, "Already-sent check unnecessarily opened SMTP.")
        state = json.loads((config.parent / "state/state.json").read_text(encoding="utf-8-sig"))
        check(state["DeliveryStatus"] == "Sent", "Successful SMTP send was not durably recorded.")


def rejected_delivery():
    with CaptureServer("reject") as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        config = make_config(FIXTURES / "rejection", server.server_address[1])
        invoke(config)  # SMTP rejection may be represented as a result or exception.
        check(len(server.messages) == 0, "Rejected recipient received DATA.")
        state = json.loads((config.parent / "state/state.json").read_text(encoding="utf-8-sig"))
        check(state["DeliveryStatus"] == "Rejected", "Definite SMTP rejection not recorded as retryable.")
        server.mode = "success"
        retried = invoke(config)
        check(retried.returncode == 0, retried.stdout + retried.stderr)
        check(len(server.messages) == 1, "A definite rejection prevented the successful next retry.")


def ambiguous_delivery():
    with CaptureServer("ambiguous") as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        config = make_config(FIXTURES / "ambiguous", server.server_address[1])
        invoke(config)
        check(len(server.messages) == 1, "Ambiguous test did not capture DATA before disconnect.")
        state = json.loads((config.parent / "state/state.json").read_text(encoding="utf-8-sig"))
        check(state["DeliveryStatus"] == "Uncertain", "Lost SMTP acceptance was not marked uncertain.")
        connections_before = server.connections
        server.mode = "success"
        invoke(config)
        check(len(server.messages) == 1, "Unknown SMTP acceptance caused duplicate automatic delivery.")
        check(server.connections == connections_before, "Uncertain-day guard still opened SMTP.")


def dpapi_credential_roundtrip():
    with CaptureServer("success") as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        config = make_config(FIXTURES / "dpapi", server.server_address[1])
        credential = config.parent / "test-credential.xml"
        setup = config.parent / "export-credential.ps1"
        marker = "loopback-test-not-a-real-password"
        setup.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "Import-Module (Join-Path $PSHOME 'Modules\\Microsoft.PowerShell.Security\\Microsoft.PowerShell.Security.psd1')\n"
            f"$secure = ConvertTo-SecureString '{marker}' -AsPlainText -Force\n"
            "$credential = New-Object Management.Automation.PSCredential('loopback-test-user', $secure)\n"
            f"$credential | Export-Clixml -LiteralPath {quoted(credential)}\n",
            encoding="utf-8-sig",
        )
        exported = subprocess.run(
            [str(POWERSHELL), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(setup)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        check(exported.returncode == 0, exported.stdout + exported.stderr)
        exported_bytes = credential.read_bytes()
        check(marker.encode("utf-8") not in exported_bytes and marker.encode("utf-16le") not in exported_bytes,
              "Credential export contains plaintext password.")
        settings = json.loads(config.read_text(encoding="utf-8"))
        settings["CredentialPath"] = credential.name
        config.write_text(json.dumps(settings, indent=2), encoding="utf-8")
        sent = invoke(config)
        check(sent.returncode == 0, sent.stdout + sent.stderr)
        check(len(server.messages) == 1, "Credential decrypt preflight prevented local delivery.")


def main() -> int:
    FIXTURES.mkdir(parents=True)
    results = []
    for name, test in [
        ("Real SMTP delivery and repeat-process daily suppression", successful_delivery),
        ("Definite SMTP rejection retries safely", rejected_delivery),
        ("Lost final SMTP acknowledgement suppresses duplicate delivery", ambiguous_delivery),
        ("Windows DPAPI credential export and current-user import roundtrip", dpapi_credential_roundtrip),
    ]:
        try:
            test()
            print(f"PASS {name}")
            results.append({"Name": name, "Passed": True, "Error": None})
        except Exception as exc:
            print(f"FAIL {name}: {exc}")
            results.append({"Name": name, "Passed": False, "Error": str(exc)})
    failed = sum(not item["Passed"] for item in results)
    summary = {
        "TimestampUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "ModuleSha256": hashlib.sha256((ROOT / "windows/RamAltman.psm1").read_bytes()).hexdigest(),
        "BindAddress": "127.0.0.1",
        "ExternalEmailSent": False,
        "FixtureRoot": str(FIXTURES),
        "Total": len(results),
        "Passed": len(results) - failed,
        "Failed": failed,
        "Cases": results,
    }
    output = ROOT / "validation/smtp-loopback-results.json"
    output.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"{len(results) - failed} passed; {failed} failed. Results: {output}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
