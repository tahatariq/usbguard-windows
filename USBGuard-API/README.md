# USBGuard API

A FastAPI service that manages USB access exceptions on Windows endpoints via IBM BigFix.
When a user requires temporary USB storage access (e.g. to transfer project files), a
ServiceNow RITM is raised and an administrator calls this API to deploy a BigFix action
that writes the necessary registry keys and re-enables the USBSTOR driver on the target PC.

When the exception expires, a scheduled BigFix baseline automatically re-blocks USB
storage — no manual cleanup required.  The DELETE endpoint allows immediate revocation
before the expiry date.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Installation](#2-installation)
3. [Configuration](#3-configuration)
4. [API Key Management](#4-api-key-management)
5. [IIS Setup](#5-iis-setup)
6. [Running Locally](#6-running-locally)
7. [Running Tests](#7-running-tests)
8. [API Reference](#8-api-reference)
9. [How Scheduling Works](#9-how-scheduling-works)
10. [How Auto-Expiry Works](#10-how-auto-expiry-works)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| **Python 3.12+** | Install from [python.org](https://python.org). During installation, tick **"Add Python to PATH"** — this is all `web.config` requires. No specific install directory is needed. |
| **IIS 10+** | Available on Windows Server 2016/2019/2022 and Windows 10/11 Pro/Enterprise. |
| **HttpPlatformHandler v1.2** | Download from the [IIS site](https://www.iis.net/downloads/microsoft/httpplatformhandler). This bridges IIS ↔ uvicorn. |
| **IBM BigFix 10+** | The REST API must be enabled on port 52311. A service account with permission to create actions is required. |

---

## 2. Installation

```powershell
# Navigate to the project directory on the server
cd C:\inetpub\wwwroot\USBGuard-API

# Create a virtual environment (recommended — keeps dependencies isolated)
python -m venv .venv
.venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

---

## 3. Configuration

`appsettings.json` contains secrets and is excluded from git (see `.gitignore`).
Copy the example template and fill in real values:

```powershell
copy appsettings.example.json appsettings.json
notepad appsettings.json
```

```json
{
  "bigfix_server": "bigfix.corp.example.com",
  "bigfix_port": 52311,
  "bigfix_username": "usbguard-svc",
  "bigfix_password": "REPLACE_WITH_BIGFIX_PASSWORD",
  "api_keys": [
    "REPLACE_WITH_A_STRONG_RANDOM_KEY"
  ]
}
```

| Field | Required | Description |
|---|---|---|
| `bigfix_server` | Yes | Hostname or IP of the BigFix server. No `https://` prefix or port here. |
| `bigfix_port` | No | BigFix REST API port. Default: `52311`. |
| `bigfix_username` | Yes | BigFix operator username. Needs permission to create actions. |
| `bigfix_password` | Yes | Password for the BigFix operator account. |
| `api_keys` | Yes | List of accepted API keys. See [Section 4](#4-api-key-management). |

**Security:** Keep `appsettings.json` outside the IIS web root, or restrict it with a filesystem ACL so
it cannot be served to HTTP clients.

---

## 4. API Key Management

### Generating a key

```powershell
python generate_api_key.py
```

This produces a cryptographically secure 32-byte URL-safe token, for example:

```
Generated API key:

  3Zk8mQwT9rVxNpL2aBcDeFgHiJkLmNoP

Add this to appsettings.json:
  "api_keys": ["3Zk8mQwT9rVxNpL2aBcDeFgHiJkLmNoP"]
```

You can also generate one directly from Python:
```powershell
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

### Where keys are stored

Keys live only in `appsettings.json` on the IIS server.
They are **never** stored in the codebase, environment variables, or logs.
The file is excluded from git via `.gitignore` so it cannot be accidentally committed.

### Multiple keys (one per caller)

The `api_keys` field is a list — issue a separate key to each system that calls the API:

```json
"api_keys": [
  "key-for-servicenow-integration",
  "key-for-admin-script",
  "key-for-monitoring-tool"
]
```

This allows you to revoke a single caller's access without affecting others.

### Key rotation (zero downtime)

1. Generate a new key with `python generate_api_key.py`.
2. **Add** the new key to `api_keys` (keep the old key in the list).
3. Restart the service (or recycle the IIS app pool) to pick up the new key.
4. Update the calling system to use the new key.
5. **Remove** the old key from `api_keys` and restart the service again.

The old and new key both work during the transition window (step 2–4), so there is no downtime.

---

## 5. IIS Setup

### 5.1 Install HttpPlatformHandler

1. Download `httpPlatformHandler_amd64.msi` from the [IIS downloads page](https://www.iis.net/downloads/microsoft/httpplatformhandler).
2. Run the installer. The module appears in IIS Manager under **Modules**.

### 5.2 Create the IIS Site

1. Open **IIS Manager**.
2. Right-click **Sites** → **Add Website**.
3. Set the **Physical path** to the project root (e.g. `C:\inetpub\wwwroot\USBGuard-API`).
4. Assign a binding — HTTPS on port 443 with a valid certificate is strongly recommended.
5. Click **OK**.

### 5.3 Configure the Application Pool

1. In **Application Pools**, find the pool created for your site.
2. Set **.NET CLR version** to **No Managed Code** (the pool hosts Python, not .NET).
3. Under **Advanced Settings → Identity**, set an account that:
   - Has **read** access to the project directory.
   - Has **write** access to `logs\` (where HttpPlatformHandler writes stdout).

### 5.4 Review web.config

No changes are needed. The included `web.config` uses `%SystemRoot%\System32\cmd.exe`
(always available on any Windows version) to call `start.cmd`, which resolves Python
automatically — no path or version number is hardcoded:

- If `.venv\Scripts\python.exe` exists in the project root → virtual environment is used.
- Otherwise `python` is called from the system `PATH` → global installation is used.

Python just needs to be installed. The exact install path or version directory does not matter.

### 5.5 Create the Logs Directory

```powershell
New-Item -ItemType Directory -Path C:\inetpub\wwwroot\USBGuard-API\logs
# Grant the application pool identity write access:
icacls logs /grant "IIS AppPool\USBGuardAPI:(OI)(CI)W"
```

### 5.6 Disable Directory Browsing

In IIS Manager, select the site → **Directory Browsing** → **Disable**.

---

## 6. Running Locally

For development and testing, run directly with uvicorn (no IIS needed):

```powershell
# From the project root, with the virtual environment activated:
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

The Swagger UI is then available at `http://127.0.0.1:8000/docs` — all endpoints can be
tested interactively from the browser.

**Note:** You still need a real or test `appsettings.json`. For local testing without a
BigFix server, mock the `app.state.bigfix` object (as the tests do) or point at a dev
BigFix instance.

---

## 7. Running Tests

```powershell
# Install test dependencies (one-time):
pip install pytest pytest-cov

# Run all tests:
pytest tests/ -v

# Run with coverage report:
pytest tests/ -v --cov=app --cov-report=term-missing
```

Tests are organised into three files:

| File | What it covers |
|---|---|
| `tests/test_date_parser.py` | All 13 date formats, past-date correction, unparseable inputs |
| `tests/test_models.py` | Pydantic validation — required fields, RITM pattern, day range |
| `tests/test_bigfix.py` | Scheduling offset calculation, PowerShell base64 encoding |
| `tests/test_api.py` | All three API endpoints, auth rejection, BigFix error handling |

No real BigFix server is required — the BigFix client is fully mocked in the API tests.

### CI

Tests run automatically on GitHub Actions whenever code in `USBGuard-API/` is pushed or a
pull request is opened. See `.github/workflows/api-tests.yml`.

---

## 8. API Reference

All endpoints require the `X-API-Key` header.

### 8.1 Get Exception Status

```
GET /api/exceptions/{pc_name}
```

Returns the current USB exception status for the named PC by querying registry values via
the BigFix relevance API.

**Example:**

```bash
curl -s -X GET "https://usbguard.corp.example.com/api/exceptions/DESKTOP-01" \
     -H "X-API-Key: your-api-key" | jq .
```

**200 Response:**

```json
{
  "success": true,
  "message": "Exception status retrieved.",
  "data": {
    "pc_name": "DESKTOP-01",
    "has_active_exception": true,
    "expiry_time": "2026-06-01T00:00:00",
    "granted_to_user": "john.doe",
    "ritm": "RITM0012345"
  },
  "warning": null
}
```

**404 Response** (computer not enrolled in BigFix):

```json
{
  "success": false,
  "message": "Computer 'DESKTOP-01' was not found in BigFix."
}
```

---

### 8.2 Create Exception

```
POST /api/exceptions
Content-Type: application/json
```

Deploys a BigFix action that grants USB storage access on the target PC for the requested
duration, then automatically expires.

**Request body:**

| Field | Type | Required | Notes |
|---|---|---|---|
| `pc_name` | string | Yes | Exact computer name as enrolled in BigFix. |
| `username` | string | Yes | AD username of the person receiving access. |
| `ritm` | string | Yes | ServiceNow RITM number, e.g. `RITM0012345`. Must match `RITM\d{7}` (case-insensitive). |
| `start_date` | string | Yes | When the exception starts. Many formats accepted — see table below. Defaults to today if unparseable or in the past. |
| `number_of_days` | integer | Yes | Duration in days. 1–365. |

**Accepted date formats:**

| Format | Example |
|---|---|
| ISO 8601 | `2026-05-20` |
| Slash (UK) | `20/05/2026` |
| Slash (US) | `05/20/2026` |
| Dashed | `20-05-2026` |
| Short month name | `20 May 2026` |
| Full month name | `20 May 2026` or `May 20, 2026` |
| Dot-separated | `20.05.2026` |
| Compact | `20260520` |

**Example — immediate start (today):**

```bash
curl -s -X POST "https://usbguard.corp.example.com/api/exceptions" \
     -H "X-API-Key: your-api-key" \
     -H "Content-Type: application/json" \
     -d '{
           "pc_name": "DESKTOP-01",
           "username": "john.doe",
           "ritm": "RITM0012345",
           "start_date": "2026-03-21",
           "number_of_days": 5
         }' | jq .
```

**201 Response (immediate):**

```json
{
  "success": true,
  "message": "Exception created. USB access will be active on next BigFix agent check-in.",
  "data": {
    "action_id": "12345",
    "pc_name": "DESKTOP-01",
    "start_date": "2026-03-21",
    "expiry": "2026-03-26",
    "ritm": "RITM0012345",
    "scheduled": false
  },
  "warning": null
}
```

**201 Response (future start date):**

```json
{
  "success": true,
  "message": "Exception scheduled. BigFix will activate USB access on 2026-05-20 and the PC will be unblocked the next time it checks in on or after that date (even if currently offline).",
  "data": {
    "action_id": "12346",
    "pc_name": "DESKTOP-01",
    "start_date": "2026-05-20",
    "expiry": "2026-05-27",
    "ritm": "RITM0012345",
    "scheduled": true
  },
  "warning": null
}
```

**201 Response (past date corrected):**

```json
{
  "success": true,
  "message": "Exception created. USB access will be active on next BigFix agent check-in.",
  "data": {
    "action_id": "12347",
    "pc_name": "DESKTOP-01",
    "start_date": "2026-03-21",
    "expiry": "2026-03-26",
    "ritm": "RITM0012345",
    "scheduled": false
  },
  "warning": "Start date 2020-01-01 is in the past — using today's date."
}
```

---

### 8.3 Revoke Exception

```
DELETE /api/exceptions/{pc_name}
```

Deploys a BigFix action that immediately disables USBSTOR and clears the USBGuard registry
keys on the target PC.  Use this when access needs to be removed before the expiry date.

**Example:**

```bash
curl -s -X DELETE "https://usbguard.corp.example.com/api/exceptions/DESKTOP-01" \
     -H "X-API-Key: your-api-key" | jq .
```

**200 Response:**

```json
{
  "success": true,
  "message": "Exception revoked. USB access will be blocked on next BigFix baseline run (up to 4 hours).",
  "data": {
    "action_id": "99999",
    "pc_name": "DESKTOP-01"
  },
  "warning": null
}
```

---

## 9. How Scheduling Works

### Same day or past date → immediate

BigFix dispatches the action right away. The PC will process it within minutes if online,
or when it next checks in if currently offline.

### Future start date → BigFix holds the action

When `start_date` is in the future, the BigFix action is created with a `StartDateTimeOffset`
in the BES XML (e.g. `+03:00:00:00` for 3 days from now). BigFix holds the action on the
server and only releases it to the endpoint on/after that date.

```
Today (API call)                  start_date                 expiry
     │                                │                          │
     │  BigFix holds action           │  Action executes         │  BigFix baseline
     │  — PC gets nothing yet         │  on next check-in        │  re-blocks USB
     ├────────────────────────────────┼──────────────────────────┼──────────────────
     0                               +3d                        +10d
```

### Offline PCs

If the PC is offline when the action is scheduled to run, BigFix will apply it the next
time the PC checks in — **as long as it comes back online before the end window** (which
is set to `start_date + number_of_days + 14 days`).  A PC that is offline for more than
14 days after the expiry date will not receive the action (the window is intentionally
generous to handle extended absences like holiday shutdowns).

The same applies to revoke actions: an offline PC will be re-blocked within the 7-day
revoke window when it next checks in.

---

## 10. How Auto-Expiry Works

The API relies on a BigFix baseline (running every 4 hours) to enforce the USBGuard policy.
The baseline checks the `ExceptionExpiry` registry value on each endpoint:

- **Value absent or date passed** → baseline re-disables USBSTOR (`Start = 4`) and sets `WriteProtect = 1`.
- **Valid future expiry exists** → baseline takes no action.

This means:
- USB is blocked again **automatically** after the expiry date with no manual step.
- Use `DELETE /api/exceptions/{pc_name}` to revoke **immediately** before expiry.
- There is a delay of up to 4 hours between expiry and the baseline enforcing the block —
  this is the BigFix polling interval, not an API limitation.

---

## 11. Troubleshooting

### 1. `502 Bad Gateway` from the API

BigFix returned an error. Common causes:
- Wrong `bigfix_server` or `bigfix_port` in `appsettings.json`.
- Incorrect `bigfix_username` / `bigfix_password`.
- BigFix REST API not enabled — check **BigFix Administration → Advanced Options → Enable REST API**.
- Firewall blocking port 52311 between the IIS server and the BigFix server.

Check `logs\python.log` for the full error details.

### 2. Action deployed but USB is not enabled on the PC

- The BigFix client may be offline or not checking in. Check the action status in the BigFix Console.
- If `start_date` was in the future, the action has not fired yet — this is expected behaviour.
- Verify the computer name matches exactly what is shown in the BigFix Console.
- Check that `BESClient` is running: `Get-Service BESClient`.

### 3. `404 Computer not found` for a PC that exists in BigFix

- BigFix uses the Windows computer name (`$env:COMPUTERNAME`), not the FQDN. Try without the domain suffix.
- The computer may be in a restricted BigFix site that the service account cannot see.

### 4. IIS returns `503 Service Unavailable` immediately after deployment

- The application pool may have stopped. Open IIS Manager → Application Pools → Start the pool.
- Check the Windows Event Log (Application) for startup errors.
- Ensure `logs\` exists and the pool identity has write permission.
- Verify `processPath` in `web.config` points to the correct Python executable.

### 5. `401 Unauthorized` even when providing `X-API-Key`

- The header name is case-sensitive in some HTTP clients — use exactly `X-API-Key`.
- Check for leading/trailing whitespace in the key value in `appsettings.json`.
- If a proxy or load balancer sits in front of IIS, confirm it is not stripping custom headers.
