using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace USBGuard;

public partial class MainForm : Form
{
    private WebView2 _webView = null!;
    private readonly string _psScriptPath;
    private readonly bool _isAdmin;

    public MainForm()
    {
        InitializeComponent();
        _isAdmin = CheckAdmin();
        _psScriptPath = ResolveScriptPath();
    }

    // ── Admin check ─────────────────────────────────────────────────────────

    private static bool CheckAdmin()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    // ── Script resolution ────────────────────────────────────────────────────

    private static string ResolveScriptPath()
    {
        var baseDir = AppContext.BaseDirectory;
        // USBGuard.exe lives in USBGuard-WebView2\; USBGuard.ps1 is one level up
        var candidates = new[]
        {
            Path.Combine(baseDir, "USBGuard.ps1"),
            Path.Combine(baseDir, "..", "USBGuard.ps1"),
            Path.Combine(baseDir, "..", "..", "USBGuard.ps1"),
        };
        foreach (var c in candidates)
            if (File.Exists(c)) return Path.GetFullPath(c);

        // Fallback: assume sibling; will fail at runtime with a clear error
        return Path.GetFullPath(Path.Combine(baseDir, "..", "USBGuard.ps1"));
    }

    // ── WebView2 initialisation ──────────────────────────────────────────────

    protected override async void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        await InitWebViewAsync();
    }

    private async Task InitWebViewAsync()
    {
        _webView = new WebView2 { Dock = DockStyle.Fill };
        Controls.Add(_webView);

        // User data folder — required by WebView2; isolated per-app
        var userDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "USBGuard", "WebView2Cache");

        var env = await CoreWebView2Environment.CreateAsync(null, userDataFolder);
        await _webView.EnsureCoreWebView2Async(env);

        // Harden the WebView — no context menus, no dev tools in production
        var settings = _webView.CoreWebView2.Settings;
        settings.AreDefaultContextMenusEnabled = false;
        settings.AreDevToolsEnabled = false;
        settings.IsStatusBarEnabled = false;
        settings.IsZoomControlEnabled = false;
        settings.IsBuiltInErrorPageEnabled = true;

        // Map a virtual hostname to wwwroot so navigation works without file:// quirks
        var wwwroot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "wwwroot"));
        _webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            "usbguard.local", wwwroot, CoreWebView2HostResourceAccessKind.Allow);

        _webView.CoreWebView2.WebMessageReceived += OnWebMessageReceived;

        _webView.CoreWebView2.Navigate("https://usbguard.local/index.html");
    }

    // ── Message dispatch ─────────────────────────────────────────────────────

    private async void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string raw = e.TryGetWebMessageAsString();
        JsonElement msg;
        try { msg = JsonDocument.Parse(raw).RootElement; }
        catch { return; }

        if (!msg.TryGetProperty("type", out var typeProp)) return;
        var msgType = typeProp.GetString() ?? "";

        switch (msgType)
        {
            case "init":
                int reqId0 = msg.TryGetProperty("reqId", out var r0) ? r0.GetInt32() : 0;
                await PostJsonAsync(new { type = "init-result", reqId = reqId0, isAdmin = _isAdmin });
                break;

            case "run-action":
                if (!msg.TryGetProperty("action", out var actionProp)) return;
                string action   = actionProp.GetString() ?? "";
                int    reqId    = msg.TryGetProperty("reqId",         out var rp)  ? rp.GetInt32()   : 0;
                string? devId   = msg.TryGetProperty("deviceId",      out var dip) ? dip.GetString() : null;
                string? company = msg.TryGetProperty("companyName",   out var cnp) ? cnp.GetString() : null;
                string? notify  = msg.TryGetProperty("notifyMessage", out var nmp) ? nmp.GetString() : null;
                await HandleActionAsync(reqId, action, devId, company, notify);
                break;
        }
    }

    // ── Action handler ───────────────────────────────────────────────────────

    private async Task HandleActionAsync(
        int     reqId,
        string  action,
        string? deviceId,
        string? companyName,
        string? notifyMessage)
    {
        if (!_isAdmin)
        {
            await PostJsonAsync(new
            {
                type = "action-result", reqId, action,
                output = "[ERROR] Administrator privileges required.", exitCode = 1,
            });
            return;
        }

        // Delegate to InputValidator — testable without a UI dependency
        string? psArgs = InputValidator.BuildPsArgs(action, deviceId, companyName, notifyMessage);
        if (psArgs is null)
        {
            string reason = !InputValidator.IsAllowedAction(action)
                ? "[ERROR] Unknown action."
                : "[ERROR] Invalid arguments — rejected by input validation.";
            await PostJsonAsync(new { type = "action-result", reqId, action, output = reason, exitCode = 1 });
            return;
        }

        var (stdout, stderr, exitCode) = await InvokePowerShellAsync(psArgs);
        string combined = string.IsNullOrWhiteSpace(stderr) ? stdout : stdout + "\n" + stderr;

        await PostJsonAsync(new { type = "action-result", reqId, action, output = combined, exitCode });
    }

    // ── PowerShell invocation ────────────────────────────────────────────────

    private async Task<(string stdout, string stderr, int exitCode)> InvokePowerShellAsync(string psArgs)
    {
        if (!File.Exists(_psScriptPath))
            return ("", $"[ERROR] USBGuard.ps1 not found at: {_psScriptPath}", 1);

        var psi = new ProcessStartInfo
        {
            FileName               = "powershell.exe",
            Arguments              = $"-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"{_psScriptPath}\" {psArgs}",
            UseShellExecute        = false,
            RedirectStandardOutput = true,
            RedirectStandardError  = true,
            CreateNoWindow         = true,
        };

        using var proc = new Process { StartInfo = psi };
        proc.Start();

        var stdoutTask = proc.StandardOutput.ReadToEndAsync();
        var stderrTask = proc.StandardError.ReadToEndAsync();
        await proc.WaitForExitAsync();

        return (await stdoutTask, await stderrTask, proc.ExitCode);
    }

    // ── Post helper ──────────────────────────────────────────────────────────

    private Task PostJsonAsync(object payload)
    {
        if (_webView?.CoreWebView2 is { } wv2)
            wv2.PostWebMessageAsJson(JsonSerializer.Serialize(payload));
        return Task.CompletedTask;
    }
}
