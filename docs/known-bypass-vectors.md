# Known Bypass Vectors and Mitigations

This document catalogs known vectors that can circumvent USBGuard's 7-layer protection model, along with recommended mitigations for each. These should be reviewed during risk acceptance and factored into deployment hardening.

---

## 1. Safe Mode Boot

**Vector:** When Windows boots into Safe Mode, BigFix (BESClient) and other SYSTEM-context scheduled tasks do not start. The registry is editable by any local administrator, and the VolumeWatcher (L5) and TamperDetection tasks are inactive. However, DENY ACEs applied by Fixlet 3 survive Safe Mode -- they are stored in the registry's security descriptors and enforced by the kernel regardless of boot mode.

**Impact:** An attacker with physical access and local admin credentials can modify USBSTOR, StorageDevicePolicies, and other protected keys if DENY ACEs are not in place (Standalone deployment). With BigFix DENY ACEs, the registry values cannot be changed even in Safe Mode, but the VolumeWatcher auto-eject and tamper remediation are not running.

**Mitigation:**
- Enable BitLocker with TPM+PIN pre-boot authentication. This prevents offline registry modification by requiring the PIN before Windows (including Safe Mode) can access the encrypted volume.
- Ensure Fixlet 3 (Lock ACLs) is deployed so DENY ACEs protect registry keys even when BigFix is not running.
- Consider disabling Safe Mode boot via `HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal` and `Network` key restrictions (note: this can complicate recovery scenarios).

---

## 2. eSATA (External SATA)

**Vector:** eSATA devices connect through the AHCI/storahci driver stack and appear to Windows as internal SATA disks, not removable storage. They are invisible to all 7 protection layers because:
- L1 (USBSTOR) only covers USB mass storage
- L3 (DenyDeviceClasses) targets USB device install classes
- L5 (VolumeWatcher) sees them as fixed disks, not removable volumes
- There is no clean Windows policy knob to distinguish eSATA from internal SATA

**Impact:** Full read/write access to an external disk via eSATA port, completely bypassing USBGuard policy.

**Mitigation:**
- Physical port blocking: Use eSATA port covers or epoxy to physically disable eSATA connectors on managed endpoints.
- Chassis security: Deploy chassis intrusion detection and tamper-evident seals to prevent internal SATA cable attachment.
- Asset procurement policy: Exclude machines with eSATA ports from the approved hardware catalog where possible.
- Note: There is no software-only mitigation for eSATA on Windows. This is a hardware-level gap.

---

## 3. WSL2 / usbipd

**Vector:** Windows Subsystem for Linux 2 (WSL2) with the `usbipd-win` service can attach USB devices directly to the Linux kernel running inside the WSL2 VM. This bypasses the entire Windows driver stack -- the device is detached from Windows and attached to the Linux USB subsystem, where none of USBGuard's 7 layers apply.

**Impact:** Full access to USB storage devices from within the WSL2 Linux environment, bypassing all Windows-side policy enforcement.

**Mitigation:**
- Disable the usbipd service: `Stop-Service usbipd; Set-Service usbipd -StartupType Disabled`
- Disable WSL entirely via Group Policy: Set `HKLM\SOFTWARE\Policies\Microsoft\Windows\Lxss` value `AllowWSL` to `0` (DWORD).
- Alternatively, use Windows Optional Features to uninstall WSL: `dism.exe /Online /Disable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux`
- Monitor for usbipd installation via software inventory or AppLocker rules.

---

## 4. USB-to-Ethernet Adapters

**Vector:** USB Ethernet adapters (and USB Wi-Fi adapters) install as the `Net` device class (`{4D36E972-E325-11CE-BFC1-08002BE10318}`), which is not included in USBGuard's default DenyDeviceClasses list. This is by design -- blocking the Net class would disable legitimate USB network adapters, docking station Ethernet, and USB tethering used for corporate connectivity.

**Impact:** A USB-to-Ethernet adapter can be plugged in and used to establish an unauthorized network bridge, exfiltrate data over the network, or connect the endpoint to a rogue network.

**Mitigation:**
- Add the Net class GUID to the deny list as a new layer (proposed L11), but this requires a corresponding allowlist for legitimate USB NICs (e.g., corporate-approved docking stations).
- Use 802.1X port authentication on all network ports to prevent unauthorized network access even if the adapter enumerates.
- Deploy network access control (NAC) to detect and quarantine endpoints with unexpected network interfaces.
- Monitor for new Net-class device installations via Windows Event Log (DeviceSetupManager events).

---

## 5. Allowlist Prefix-Match Overpermission

**Vector:** USBGuard's allowlist matches devices by PNP Device ID prefix (e.g., `USBSTOR\DISK&VEN_KINGSTON`). Short or generic prefix entries can be overly permissive, matching entire product families or even all devices from a vendor. For example, `USBSTOR\DISK&VEN_` (with no vendor specified) would match every USB storage device.

**Impact:** An overly broad allowlist entry could permit unauthorized devices that happen to share the same vendor or product prefix as an approved device.

**Mitigation:**
- USBGuard v2 adds a warning when allowlist entries lack `VEN_` and `PROD_` specificity, alerting administrators to overly permissive entries.
- Require full `VEN_<vendor>&PROD_<product>` prefixes as a minimum for all allowlist entries.
- Periodically audit the allowlist (`-Action list-allowlist`) and review entries for excessive breadth.
- Document the approved device model and serial number alongside each allowlist entry in your change management system.
- Consider adding `REV_` (revision) qualifiers for maximum specificity where hardware inventory supports it.

---

## Risk Acceptance Matrix

| Vector | Severity | Software Fix Available | Recommended Action |
|--------|----------|----------------------|-------------------|
| Safe Mode boot | High | Partial (DENY ACEs help) | BitLocker + TPM+PIN |
| eSATA | High | No | Physical port blocking |
| WSL2/usbipd | Medium | Yes (disable service/WSL) | Group Policy + monitoring |
| USB-to-Ethernet | Medium | Partial (allowlist needed) | NAC + 802.1X |
| Allowlist prefix-match | Low | Yes (v2 warnings) | Policy + audit |

---

## Reporting

If you discover a new bypass vector not listed here, report it to the USBGuard project maintainers and update this document. Include:
1. The specific Windows mechanism exploited
2. Which of the 7 layers are bypassed
3. Whether a software mitigation exists
4. Minimum attacker privileges required (physical access, local admin, standard user, etc.)
