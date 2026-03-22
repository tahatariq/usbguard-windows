# Multi-Tenant OU-Scoped Policy Guide

USBGuard supports different policy configurations per organizational unit (OU) or tenant through multiple deployment mechanisms. This guide describes how to configure per-OU policies using Group Policy, BigFix, and Intune.

---

## Group Policy (ADMX/ADML)

The USBGuard ADMX template (`USBGuard.admx`) exposes all 10 protection layers as individual policies under:

```
Computer Configuration > Administrative Templates > USBGuard > Protection Layers
```

### OU-Scoped Configuration

1. **Create per-OU GPOs**: Create a separate GPO for each OU that needs a different policy. For example:
   - `USBGuard-FullBlock` — enables all 10 layers (applied to most OUs)
   - `USBGuard-LabExempt` — enables L1-L4 but disables L8-L10 (applied to lab/dev OUs)
   - `USBGuard-ExecutiveExempt` — enables L1-L4, L6-L7 but allows SD cards and Bluetooth (applied to executive OU)

2. **Link GPOs to OUs**: Link each GPO to the appropriate OU in Active Directory. Standard GPO precedence applies (closer OU wins for conflicting settings).

3. **Allowlist per OU**: The ADMX template supports per-OU allowlist entries under `USBGuard > Device Allowlist`. Different OUs can have different approved device lists.

4. **Notification customization**: Set different `CompanyName` and `NotifyMessage` values per OU to customize the end-user experience (e.g., different help desk numbers per region).

### Example: Three-Tier Policy

| OU | GPO | Layers Enabled | Allowlist |
|----|-----|---------------|-----------|
| `corp.local/Workstations` | USBGuard-FullBlock | All 10 | Empty |
| `corp.local/Workstations/Lab` | USBGuard-LabExempt | L1-L7 | Lab USB drives |
| `corp.local/Workstations/Executives` | USBGuard-Executive | L1-L7 | Approved peripherals |

---

## BigFix (Computer Groups)

BigFix provides OU-equivalent scoping through **Computer Groups** and **Fixlet targeting**.

### Configuration Steps

1. **Create Computer Groups** that map to your organizational structure:
   - `USBGuard - Full Policy` (all endpoints by default)
   - `USBGuard - Lab Exemptions` (lab computers)
   - `USBGuard - SD Card Allowed` (endpoints where SD readers are needed)

2. **Create Fixlet variants**: Clone Fixlet 1 for each policy tier:
   - `Fixlet1_FullPolicy.bes` — applies all 10 layers
   - `Fixlet1_StorageOnly.bes` — applies L1-L7 only (no SD/BT/FW)
   - `Fixlet1_CustomLayers.bes` — applies specific layer subset

3. **Target Fixlets to Groups**: In the BigFix Baseline, target each Fixlet variant to its corresponding Computer Group.

4. **Per-group exception workflow**: When creating exceptions via the API, the `pc_name` parameter targets a specific machine. The BigFix audit trail records which group the machine belongs to.

### Registry-Based Policy Override

For more granular control, USBGuard reads policy configuration from `HKLM\SOFTWARE\USBGuard\Policy`. BigFix Fixlets can set per-machine policy overrides:

```powershell
# Set on target machine to control which layers are enforced
Set-ItemProperty "HKLM:\SOFTWARE\USBGuard\Policy" -Name "L8_SDCard" -Value 0 -Type DWord
Set-ItemProperty "HKLM:\SOFTWARE\USBGuard\Policy" -Name "L9_Bluetooth" -Value 0 -Type DWord
```

The ADMX template writes to these same keys, so GPO and BigFix configurations are compatible.

---

## Intune (Device Groups + Configuration Profiles)

### Configuration Steps

1. **Create Intune Device Groups** (dynamic or assigned) for each policy tier.

2. **Create Configuration Profiles** per tier using the OMA-URI settings documented in `docs/intune-oma-uri.md`:
   - Profile "USBGuard Full" — all OMA-URI settings enabled
   - Profile "USBGuard Partial" — subset of OMA-URI settings

3. **Assign profiles to groups**: Each device group gets the appropriate configuration profile.

4. **Win32 App scoping**: If using the Install-USBGuard.ps1 Win32 app approach, create separate app packages with different `-Action` parameters for each tier.

### Compliance Policies

Create per-group compliance policies using `Detect-USBGuard.ps1` variants that check for the expected layer state in each tier.

---

## API Integration

The USBGuard API (`/api/exceptions`) does not enforce OU-scoping directly — it operates on individual `pc_name` values. However, the calling system (ServiceNow, ITSM, self-service portal) should enforce authorization rules:

- **Approver scope**: Approver API keys should only be able to create exceptions for machines in their organizational scope.
- **Audit trail**: The `/api/audit` endpoint records all exceptions. Cross-reference with AD OU membership for compliance reporting.
- **Fleet compliance**: The `/api/fleet/compliance` endpoint returns aggregate counts. Filter by BigFix Computer Group for per-OU compliance rates.

---

## Best Practices

1. **Start with a single full-block policy** applied to all endpoints. Only create OU-specific overrides where business requirements demand it.
2. **Document exceptions**: Every OU that deviates from the full-block policy should have a documented risk acceptance with approver sign-off.
3. **Audit regularly**: Use the compliance report (`USBGuard_ComplianceReport.ps1`) or BigFix Analysis Properties to verify per-OU compliance.
4. **Minimize tiers**: More policy tiers = more complexity = more risk of misconfiguration. Three tiers (full, partial, exempt) covers most organizations.
