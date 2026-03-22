# USBGuard — Enterprise USB Device Management for Windows

Blocks USB storage, phones, cameras, SD cards, Bluetooth file transfer, and FireWire on Windows machines. Multiple deployment options share the same **10-layer protection model** — pick the one that fits your environment:

| | Standalone | BigFix | Intune | GPO |
|---|---|---|---|---|
| **Best for** | Single machines, labs, kiosks | Corporate fleets via HCL BigFix | Entra ID / cloud-managed endpoints | On-prem Active Directory |
| **Tamper protection** | UAC + tamper detection task | DENY ACEs — even local admins cannot revert | Intune compliance enforcement | GPO reapply on refresh |
| **Auto-remediation** | Tamper detection re-applies within 5 min | Baseline re-applies within 4 hours | Intune sync interval | GPO refresh (90 min default) |
| **Exception workflow** | Manual (unblock + re-block) | Fixlet 4 + REST API, full audit trail | Intune assignment exclusion | GPO filtering |
| **User notification** | Windows toast popup | Requires BigFix Client UI or GPO logon script | — | — |
| **Fleet reporting** | Single-machine HTML report | Analysis Properties in Web Reports + API | Intune compliance dashboard | — |
| **Requires network** | No | Yes (BigFix agent) | Yes (Intune enrollment) | Yes (domain joined) |

---

## What Gets Blocked

| Device | Blocked | Layer |
|--------|:-------:|-------|
| USB flash drive (2.0 / 3.x) | Yes | L1 + L3 |
| USB external hard drive | Yes | L1 + L3 |
| USB-C external storage | Yes | L1 + L3 |
| Thunderbolt drive | Yes | L6 |
| USB CD/DVD drive | Yes | L3 |
| USB printer | Yes | L3 |
| Android phone — File Transfer (MTP) | Yes | L7 |
| iPhone — iTunes sync / backup | Yes | L7 |
| iPhone / Android — Windows Photos import | Yes | L7 |
| USB camera or media player (PTP/MTP) | Yes | L7 |
| SD card (built-in or USB reader) | Yes | L8 |
| Bluetooth file transfer (OBEX/FTP) | Yes | L9 |
| FireWire / IEEE 1394 device | Yes | L10 |
| **USB keyboard / mouse** | Never blocked | — |
| **USB headset / audio** | Never blocked | — |
| **USB charging (any device)** | Never blocked | — |
| Network drives, cloud sync | Out of scope | — |

---

## The 10 Protection Layers

| Layer | What It Does |
|-------|-------------|
| L1 | Disables the USB storage class driver (`USBSTOR`) |
| L2 | Write-protects any removable storage that manages to mount (forensic-grade) |
| L3 | Prevents device class installation via Group Policy GUIDs |
| L4 | Kills AutoPlay popup and AutoRun |
| L5 | Background watcher: auto-ejects any USB volume within ~1 second of mount and shows a toast notification |
| L6 | Disables the Thunderbolt driver |
| L7 | Disables the Windows Portable Devices (WPD) driver stack — blocks Android, iPhone, cameras, media players |
| L8 | Disables the SD bus driver (`sdbus`) — blocks SD and microSD card readers |
| L9 | Disables Bluetooth OBEX/FTP services and denies the Bluetooth file transfer device class |
| L10 | Disables the FireWire (IEEE 1394) driver — blocks legacy DMA-capable external storage |

---

## REST API (v2.0.0)

A Python/FastAPI service for managing USB access exceptions through BigFix over HTTP. Key features:

- **RBAC** with three roles: `admin`, `approver`, `readonly` — enforced per-endpoint
- **Timing-safe** API key comparison (`hmac.compare_digest`) to prevent key enumeration
- **Rate limiting** (in-memory, per-key, separate read/write buckets)
- **Configurable SSL** (`bigfix_ca_cert` in `appsettings.json`)
- **Input validation** with regex-based Pydantic validators to prevent injection

| Endpoint | Method | Auth Role | Description |
|----------|--------|-----------|-------------|
| `/api/health` | GET | None | Health check (BigFix connectivity probe) |
| `/api/exceptions/{pc_name}` | GET | readonly+ | Query exception status for a PC |
| `/api/exceptions` | POST | approver+ | Create a USB access exception |
| `/api/exceptions/bulk` | POST | approver+ | Bulk-create exceptions for multiple PCs |
| `/api/exceptions/{pc_name}` | DELETE | admin | Revoke an existing exception |
| `/api/audit` | GET | readonly+ | Query audit log (filterable by action, date range) |
| `/api/fleet/compliance` | GET | readonly+ | Fleet-wide compliance summary from BigFix |
| `/api/inventory/{pc_name}` | GET | readonly+ | USB device inventory and layer status for a PC |

Full API reference: [USBGuard-API/README.md](USBGuard-API/README.md)

---

## Deployment Options

### Standalone (GUI + PowerShell)

Best for single machines, labs, and kiosks. Includes an HTA graphical interface and toast notifications.

[USBGuard-Standalone/README.md](USBGuard-Standalone/README.md)

### BigFix (Enterprise Fleet)

Five fixlets enforce all 10 layers with DENY ACE tamper protection and fleet-wide compliance reporting.

[USBGuard-BigFix/README.md](USBGuard-BigFix/README.md)

### Intune (Win32 App)

Deploy as an Intune Win32 app (`.intunewin` package) with included scripts:

| Script | Purpose |
|--------|---------|
| `Install-USBGuard.ps1` | Install command — applies all layers + watcher + tamper detection |
| `Uninstall-USBGuard.ps1` | Uninstall command — reverses all layers |
| `Detect-USBGuard.ps1` | Detection rule — checks USBSTOR Start value |

Alternatively, use OMA-URI custom configuration profiles to manage registry values natively through Intune CSP. See [docs/intune-oma-uri.md](docs/intune-oma-uri.md).

### GPO (ADMX/ADML Templates)

For on-premises Active Directory environments:

1. Copy `USBGuard.admx` to `%SystemRoot%\PolicyDefinitions\`
2. Copy `en-US\USBGuard.adml` to `%SystemRoot%\PolicyDefinitions\en-US\`
3. Configure policies in Group Policy Management Console under the USBGuard node

### WiX MSI Installer

A WiX v3 scaffold (`USBGuard-Standalone/installer/Product.wxs`) builds an MSI that copies scripts to `%ProgramFiles%\USBGuard`, applies the full block policy, and installs the VolumeWatcher and tamper detection scheduled tasks.

```
candle.exe Product.wxs
light.exe Product.wixobj -o USBGuard.msi
```

---

## Compliance Reporting

`USBGuard_ComplianceReport.ps1` generates an HTML compliance report covering all 10 layers with:

- Per-layer block status (blocked / allowed / not present)
- **NIST 800-53 and CIS Controls mapping** for each layer
- **SHA-256 integrity hash** (`.sha256` sidecar file) for non-repudiation

| Layer | NIST 800-53 | CIS Control |
|-------|-------------|-------------|
| L1 USBSTOR | MP-7, SI-3 | CIS 10.3 |
| L2 WriteProtect | MP-7, SI-12 | CIS 10.5 |
| L3 DenyDeviceClasses | CM-7, SI-3 | CIS 2.7 |
| L4 AutoPlay | SI-3, SC-18 | CIS 10.1 |
| L5 VolumeWatcher | SI-4, AU-6 | CIS 10.4 |
| L6 Thunderbolt | MP-7, AC-19 | CIS 10.3 |
| L7 WPD/MTP/PTP | MP-7, SI-3 | CIS 10.3 |
| L8 SD Card | MP-7, AC-19 | CIS 10.3 |
| L9 Bluetooth FT | AC-18, SC-40 | CIS 15.7 |
| L10 FireWire | MP-7, AC-19 | CIS 10.3 |

---

## Project Structure

```
usbguard-windows/
├── USBGuard-Standalone/
│   ├── Launch_USBGuard.bat              # Start here for GUI
│   ├── USBGuard.hta                     # Graphical admin interface
│   ├── USBGuard.ps1                     # PowerShell backend (all 10 layers)
│   ├── USBGuard_Advanced.ps1            # List connected USB devices, export policy
│   ├── USBGuard_Snapshot.ps1            # Pre-block device snapshot + allowlist setup
│   ├── USBGuard_ComplianceReport.ps1    # HTML compliance report + SHA-256 hash
│   ├── Send-ExceptionNotification.ps1   # Teams/Slack webhook on exception grant
│   ├── Install-USBGuard.ps1             # Intune Win32 app install script
│   ├── Uninstall-USBGuard.ps1           # Intune Win32 app uninstall script
│   ├── Detect-USBGuard.ps1              # Intune Win32 app detection script
│   ├── USBGuard.admx                    # GPO ADMX template
│   ├── en-US/USBGuard.adml              # GPO ADML localization (en-US)
│   └── installer/Product.wxs           # WiX v3 MSI installer scaffold
│
├── USBGuard-BigFix/
│   ├── Fixlet1_ApplyPolicy.bes          # All 10 layers (run first)
│   ├── Fixlet2_DeployWatcher.bes        # Volume Watcher scheduled task
│   ├── Fixlet3_LockACLs.bes            # DENY ACEs (run last, locks everything)
│   ├── Fixlet4_Unblock.bes             # Temporary exception (targeted use only)
│   └── Fixlet5_ComplianceDetection.bes  # Per-layer audit + Analysis Properties
│
├── USBGuard-API/                        # Python/FastAPI REST API v2.0.0
│   ├── app/                             # FastAPI app (routes, BigFix client, RBAC, models)
│   ├── tests/                           # 109 pytest tests (BigFix fully mocked)
│   ├── appsettings.example.json         # Copy to appsettings.json and fill in secrets
│   ├── web.config                       # IIS HttpPlatformHandler config
│   └── README.md                        # API deployment + reference guide
│
├── docs/
│   ├── siem-integration.md              # SIEM integration guide (Event IDs, forwarding)
│   ├── known-bypass-vectors.md          # Known bypass vectors and mitigations
│   └── intune-oma-uri.md               # Intune OMA-URI configuration reference
│
├── tests/
│   ├── unit/                            # Pester unit tests (145 tests)
│   ├── integration/                     # Block/unblock roundtrip tests (10 tests)
│   └── simulation/                      # Manual end-to-end validation scripts
│
├── Run-Tests.ps1                        # Local PowerShell test runner
└── .github/workflows/
    ├── pester-tests.yml                 # CI: Win2022 + Win2025 matrix
    └── api-tests.yml                    # CI: Python/pytest on ubuntu-latest
```

---

## Requirements

| Component | Requirement |
|-----------|-------------|
| OS | Windows 10 (21H2 or later) or Windows 11 |
| PowerShell | 5.1+ (built into Windows) |
| Privileges | Administrator (Standalone: UAC prompt; BigFix: runs as SYSTEM) |
| HTA engine | MSHTML / IE component (present on all Windows versions) |
| BigFix | HCL / IBM BigFix 9.5 or later, BESClient running as LocalSystem |
| API | Python 3.12+, FastAPI, uvicorn (see `USBGuard-API/requirements.txt`) |

---

## Testing

264 automated tests across PowerShell and Python:

```powershell
# PowerShell tests (from repo root, requires admin for registry tests)
.\Run-Tests.ps1              # All tests
.\Run-Tests.ps1 -Unit        # Unit tests only (145 tests)
.\Run-Tests.ps1 -Integration # Integration tests (10 tests)
.\Run-Tests.ps1 -Syntax      # PS syntax check only
```

```bash
# API tests (from USBGuard-API/)
pip install -r requirements.txt
pytest tests/               # 109 tests
```

### CI/CD (GitHub Actions)

- **`pester-tests.yml`** — Syntax check, Pester tests, PSScriptAnalyzer, registry path validation across Windows Server 2022 and 2025
- **`api-tests.yml`** — Python 3.12 pytest on ubuntu-latest, triggered on changes to `USBGuard-API/`

Both pipelines publish JUnit test results as build artifacts.

---

## Security

| Measure | Details |
|---------|---------|
| DENY ACEs (BigFix) | Protected registry keys cannot be modified by local administrators |
| Timing-safe key comparison | API keys validated with `hmac.compare_digest` to prevent timing attacks |
| RBAC | Three roles (admin, approver, readonly) with per-endpoint enforcement |
| Input validation | Regex-based Pydantic validators reject injection attempts in PC names, usernames, RITM numbers |
| Rate limiting | Per-key, per-operation-type (read/write) in-memory rate limiter |
| Configurable SSL | `bigfix_ca_cert` setting for custom CA certificate chains |
| No stored credentials | API keys in `appsettings.json` (excluded from source control); no secrets in scripts |
| Tamper detection | Scheduled task checks and restores policy every 5 minutes, logs to audit log and Event Log |
| Integrity hashing | Compliance reports include SHA-256 sidecar for non-repudiation |

---

## Documentation

| Document | Description |
|----------|-------------|
| [USBGuard-Standalone/README.md](USBGuard-Standalone/README.md) | Standalone deployment guide |
| [USBGuard-BigFix/README.md](USBGuard-BigFix/README.md) | BigFix fleet deployment guide |
| [USBGuard-API/README.md](USBGuard-API/README.md) | API deployment, reference, and scheduling details |
| [docs/siem-integration.md](docs/siem-integration.md) | SIEM integration (Event IDs, log forwarding) |
| [docs/known-bypass-vectors.md](docs/known-bypass-vectors.md) | Known bypass vectors and mitigations |
| [docs/intune-oma-uri.md](docs/intune-oma-uri.md) | Intune OMA-URI configuration reference |

---

## License

See [LICENSE](LICENSE) for details.
