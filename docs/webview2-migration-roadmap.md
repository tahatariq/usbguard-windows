# WebView2 Migration Roadmap

## HTA (MSHTML/IE11) to WebView2 (Chromium)

**Status:** Planning
**Last updated:** 2026-03-22

---

## 1. Why Migrate

The current GUI (`USBGuard-Standalone/USBGuard.hta`) runs in mshta.exe using the MSHTML/Trident engine (IE11 mode). This engine is end-of-life:

- **IE11 is deprecated.** Microsoft ended support in June 2022. MSHTML receives only critical security patches and will eventually be removed from Windows.
- **Limited web standards.** No CSS Grid (partial), no CSS custom properties in pseudo-elements, no ES2017+ (async/await, optional chaining, nullish coalescing). The current UI already uses features that degrade or break in IE11 (e.g., `inset` shorthand, template literals in some paths).
- **ActiveX/COM dependency.** The VBScript `RunPS()` function uses `WScript.Shell` and `Scripting.FileSystemObject` via ActiveX. These COM objects are a known attack surface and are increasingly flagged by endpoint protection tools.
- **No modern tooling.** Cannot use npm packages, bundlers, TypeScript, or any modern frontend framework. Debugging is limited to `alert()` and F12 developer tools that crash frequently in HTA context.
- **Enterprise security posture.** Many organizations disable mshta.exe via AppLocker or WDAC policies as a LOLBin mitigation, which breaks the GUI entirely.

---

## 2. Target Architecture

### Runtime

**Microsoft Edge WebView2** (Chromium-based) replaces MSHTML as the rendering engine.

Two distribution models:

| Model | Pros | Cons |
|-------|------|------|
| **Evergreen** (shared runtime, auto-updated by Microsoft) | No bundling needed, always patched, ~0 MB added to installer | Requires WebView2 Runtime on target machine; version not pinned |
| **Fixed Version** (bundled with app) | Fully self-contained, version-pinned, works air-gapped | Adds ~150-200 MB to package; you own the update cycle |

**Recommendation:** Use Evergreen for standard enterprise deployment. The WebView2 Runtime is pre-installed on Windows 11 and available via WSUS/SCCM/Intune for Windows 10. Provide a Fixed Version build as an alternative for air-gapped environments.

### Host Application

The WebView2 control needs a native host process. Options:

| Host | Language | Effort | Notes |
|------|----------|--------|-------|
| **WinForms app (.NET)** | C# | Low | Simplest path. `WebView2` NuGet package. Single-file publish. |
| **WPF app (.NET)** | C# | Low-Medium | Better DPI/theming support. Same WebView2 NuGet. |
| **C++/Win32** | C++ | High | No .NET dependency. Good for minimal footprint. |
| **PowerShell + WebView2 COM** | PS | Experimental | Fragile; not recommended for production. |

**Recommendation:** .NET 8+ WinForms or WPF app, published as a single-file self-contained exe. This eliminates the .NET runtime prerequisite on target machines while keeping the codebase simple.

---

## 3. Communication Pattern

### Current (HTA)

```
[HTA/VBScript]                    [PowerShell]
RunPS(args)  ──shell.Run──>  powershell.exe -File USBGuard.ps1 -Action X -OutputFile tmp
             <──read file──  writes JSON to %TEMP%\usbguard_out.txt
[JavaScript]
parseStatus(output)  ──JSON.parse──>  update DOM
```

Problems: synchronous `shell.Run` blocks the UI thread, temp file I/O is slow, no streaming, no error channel.

### Target (WebView2)

Two viable patterns:

**Option A: Web Messaging (recommended)**

```
[WebView2 / JavaScript]              [.NET Host]
window.chrome.webview.postMessage({   CoreWebView2.WebMessageReceived ──>
  action: 'block-storage'               invoke PowerShell via System.Management.Automation
})                                       or call registry APIs directly via C#
                                     CoreWebView2.PostWebMessageAsJson({
<── receives JSON response               status: {...}
                                     })
```

- Asynchronous, non-blocking.
- Messages are strings or JSON; no COM objects cross the boundary.
- JavaScript sends requests; host processes them and posts results back.

**Option B: Host Objects (AddHostObjectToScript)**

```
[JavaScript]
const host = window.chrome.webview.hostObjects.usbguard;
const status = await host.GetStatus();  // direct async call to C# object
```

- Feels like a native API from JavaScript.
- More coupling between JS and host; harder to test the web layer independently.

**Recommendation:** Option A (web messaging). It keeps the web layer decoupled and testable in a browser. The host becomes a thin message router that dispatches to PowerShell or (eventually) native C# registry calls.

### Long-term: Eliminate PowerShell shelling

The .NET host can directly manipulate the registry and services via `Microsoft.Win32.Registry` and `System.ServiceProcess`, removing the PowerShell subprocess entirely. This is a Phase 2/3 concern -- Phase 1 should keep calling `USBGuard.ps1` to minimize risk.

---

## 4. UI Modernization

### Phase 1: Port as-is

- Move existing HTML/CSS/JS into the WebView2 content folder unchanged.
- Replace VBScript `RunPS()` calls with `window.chrome.webview.postMessage()`.
- Remove HTA-specific markup (`<HTA:APPLICATION>`, VBScript block).
- The current CSS already uses flexbox, grid, and custom properties -- these will work correctly in Chromium.

### Phase 2: Modernize

- **CSS:** Replace IE11 workarounds. Use CSS nesting, `:has()`, `color-mix()`, container queries.
- **JavaScript:** ES2022+ (top-level await, `structuredClone`, `Array.at()`). Add proper error handling with try/catch on async message flows.
- **Bundler:** Vite or esbuild for development; output a single `index.html` + `bundle.js` for production.
- **Optional framework:** Consider a lightweight framework (Preact, Svelte, or vanilla web components) for reactive status updates. React/Vue are viable but likely overkill for this UI.

### Phase 3: New capabilities

- Real-time status updates via polling or host-pushed messages (replace manual refresh).
- Device event history timeline (read from audit.log).
- Dark/light theme toggle.
- Toast notifications within the app (replace external toast via scheduled task).

---

## 5. Deployment Considerations

### WebView2 Runtime Prerequisite

| Environment | Strategy |
|-------------|----------|
| Windows 11 | Runtime pre-installed. No action needed. |
| Windows 10 (managed) | Deploy runtime via SCCM/Intune/BigFix before app rollout. Microsoft provides an offline installer (~160 MB). |
| Windows 10 (unmanaged) | Bootstrapper exe that downloads runtime on first launch (Microsoft provides `MicrosoftEdgeWebview2Setup.exe` bootstrapper, ~1.8 MB). |
| Air-gapped | Bundle Fixed Version runtime with the app. |

### Packaging

| Format | Use Case |
|--------|----------|
| **ZIP / folder** | Drop-in replacement for current standalone package. Simplest. |
| **MSI** | Enterprise deployment via GPO/SCCM/BigFix. Include runtime check/install as prerequisite. |
| **MSIX** | Modern packaging with auto-update, clean uninstall. Requires signing certificate. |
| **Single-file EXE** | .NET single-file publish. Contains host + embedded web content. Easiest for IT admins to distribute. |

**Recommendation:** Ship as a single-file EXE with embedded web content for the standalone variant. Provide an MSI for enterprise deployment that includes a runtime prerequisite check.

### Elevation

The current HTA is launched via `Launch_USBGuard.bat` which triggers a UAC prompt. The new host exe should:

- Include a `requireAdministrator` manifest so UAC prompts automatically on launch.
- Detect non-admin state and show a clear message (not just a broken UI).

---

## 6. Migration Phases

### Phase 1: Functional Port (Target: 2-3 weeks dev time)

**Goal:** Feature parity with current HTA, running on WebView2.

- Create .NET WinForms/WPF host with WebView2 control.
- Embed existing HTML/CSS as web content (from resources or local folder).
- Replace VBScript `RunPS()` with web messaging bridge.
- Host receives messages, spawns `powershell.exe -File USBGuard.ps1 -Action X`, returns JSON via `PostWebMessageAsJson`.
- Replace `CheckAdmin()` with host-side admin check, exposed via message.
- Test all actions: status, block/unblock (storage, phones, printers, all), watcher, allowlist CRUD, notification config, tamper detection.
- Ship with `Launch_USBGuard.bat` updated to launch new exe instead of mshta.exe.

**Deliverables:** `USBGuard.exe` + `USBGuard.ps1` (unchanged) + web content folder.

### Phase 2: UI/UX Modernization (Target: 2-3 weeks dev time)

**Goal:** Leverage Chromium capabilities for better UX.

- Rewrite JavaScript as ES modules with async/await message handling.
- Add auto-refresh polling (configurable interval, default 5s).
- Improve error display (inline error messages instead of log-only).
- Add device event history panel (parse audit.log).
- Responsive layout improvements.
- Optional: introduce a lightweight framework (Preact/Svelte).
- Begin migrating PowerShell calls to native C# where straightforward (status check, registry reads).

**Deliverables:** Updated `USBGuard.exe` with modernized UI.

### Phase 3: Full Native Backend (Target: 3-4 weeks dev time)

**Goal:** Remove PowerShell dependency for core operations.

- Implement all 7 protection layers as C# methods (registry manipulation, service control, scheduled task management).
- Keep `USBGuard.ps1` for BigFix compatibility and advanced/scripted use.
- Add real-time WMI event subscription in the host process (replace polling).
- Add device history persistence (SQLite or structured log file).
- Consider tray icon mode for background monitoring.

**Deliverables:** Self-contained `USBGuard.exe` with optional PowerShell fallback.

---

## 7. Backwards Compatibility

- **Keep `USBGuard.hta` in the repo** throughout the transition. Do not delete it until Phase 2 is validated in production.
- **`Launch_USBGuard.bat`** should detect WebView2 availability: launch new exe if present, fall back to mshta.exe if not.
- **`USBGuard.ps1`** remains the single source of truth for all protection logic during Phase 1. No divergence between HTA and WebView2 behavior.
- **BigFix fixlets are unaffected.** They call PowerShell directly and do not depend on the GUI.

---

## 8. Estimated Complexity

This is a **significant rewrite**, not a drop-in replacement.

| Component | Effort | Risk |
|-----------|--------|------|
| .NET host app scaffolding | Low | Low -- well-documented by Microsoft |
| Web messaging bridge (replace RunPS) | Medium | Medium -- must handle all action types, error cases, and async flow |
| Port existing HTML/CSS/JS | Low | Low -- Chromium handles all current CSS/JS; main work is removing VBScript |
| Admin elevation + manifest | Low | Low |
| Packaging + runtime prerequisite | Medium | Medium -- runtime deployment across fleet needs planning |
| UI modernization (Phase 2) | Medium | Low |
| Native C# backend (Phase 3) | High | High -- must replicate exact PS behavior for 7 layers, watcher, tamper detection |

**Total estimate:** 7-10 weeks of development across all three phases, assuming one developer. Phase 1 alone (functional parity) is 2-3 weeks and provides the most immediate value.

---

## References

- [WebView2 overview](https://learn.microsoft.com/en-us/microsoft-edge/webview2/)
- [WebView2 for WinForms getting started](https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/winforms)
- [Web messaging interop](https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/communicate-btwn-web-native)
- [WebView2 Runtime distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)
- [Evergreen vs Fixed Version](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/versioning)
