using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace USBGuard;

/// <summary>
/// Input validation and argument sanitization for the WebView2 host.
/// Extracted as a separate class so it can be unit-tested without a UI dependency.
/// </summary>
internal static class InputValidator
{
    // Whitelist of actions the host will forward to USBGuard.ps1.
    // Any action not in this set is rejected before PS is invoked.
    internal static readonly HashSet<string> AllowedActions = new(StringComparer.OrdinalIgnoreCase)
    {
        "status",
        "block",                    "unblock",
        "block-storage",            "unblock-storage",
        "block-phones",             "unblock-phones",
        "block-printers",           "unblock-printers",
        "block-sdcard",             "unblock-sdcard",
        "block-bluetooth",          "unblock-bluetooth",
        "block-firewire",           "unblock-firewire",
        "install-watcher",          "remove-watcher",
        "install-tamper-detection", "remove-tamper-detection",
        "list-allowlist",           "add-allowlist", "remove-allowlist",
        "set-notify-config",
    };

    // PNP Device IDs contain only safe alphanumeric + punctuation characters.
    // Shell metacharacters (!, @, #, $, %, ^, &, *, (, ), +, =, ~, `, ', ", <, >, ?, /, |)
    // are rejected. The allowed set matches Windows PNP ID format exactly.
    internal static readonly Regex PnpIdPattern =
        new(@"^[A-Za-z0-9_\-\\&\.\{\}@#]{1,200}$", RegexOptions.Compiled);

    /// <summary>
    /// Returns true if <paramref name="action"/> is in the allowed set.
    /// Comparison is case-insensitive.
    /// </summary>
    internal static bool IsAllowedAction(string action) => AllowedActions.Contains(action);

    /// <summary>
    /// Returns true if <paramref name="deviceId"/> is a syntactically valid PNP Device ID.
    /// Rejects empty strings, strings longer than 200 chars, and any shell metacharacters.
    /// </summary>
    internal static bool IsValidPnpId(string deviceId) =>
        !string.IsNullOrEmpty(deviceId) && PnpIdPattern.IsMatch(deviceId);

    /// <summary>
    /// Strips characters that could escape a PowerShell double-quoted string:
    /// double-quote, backtick, dollar sign, semicolon.
    /// Also enforces a maximum length.
    /// </summary>
    internal static string SanitizeString(string s, int maxLen)
    {
        if (string.IsNullOrEmpty(s)) return string.Empty;
        var cleaned = s
            .Replace("\"", "'")
            .Replace("`", "")
            .Replace("$", "")
            .Replace(";", "");
        return cleaned[..Math.Min(cleaned.Length, maxLen)];
    }

    /// <summary>
    /// Builds the PowerShell argument string for <c>USBGuard.ps1</c>.
    /// Returns <c>null</c> if <paramref name="action"/> is not whitelisted or if
    /// <paramref name="deviceId"/> fails PNP ID validation.
    /// </summary>
    internal static string? BuildPsArgs(
        string  action,
        string? deviceId      = null,
        string? companyName   = null,
        string? notifyMessage = null)
    {
        if (!IsAllowedAction(action)) return null;

        var sb = new StringBuilder($"-Action {action}");

        if (deviceId is not null)
        {
            if (!IsValidPnpId(deviceId)) return null;
            sb.Append($" -DeviceId \"{deviceId}\"");
        }

        if (companyName is not null && notifyMessage is not null)
        {
            var safeCompany = SanitizeString(companyName,   100);
            var safeMsg     = SanitizeString(notifyMessage, 500);
            sb.Append($" -CompanyName \"{safeCompany}\" -NotifyMessage \"{safeMsg}\"");
        }

        return sb.ToString();
    }
}
