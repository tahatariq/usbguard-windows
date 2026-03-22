using System.Linq;
using Xunit;

namespace USBGuard.Tests;

/// <summary>
/// Unit tests for <see cref="InputValidator"/>.
///
/// These tests exercise the security-critical validation layer that sits between
/// the JavaScript renderer and PowerShell.  No UI, no WebView2 runtime, no admin
/// privileges required — all tests run in a plain xUnit host.
/// </summary>
public class InputValidatorTests
{
    // ── AllowedActions / IsAllowedAction ─────────────────────────────────────

    [Theory]
    [InlineData("status")]
    [InlineData("block")]
    [InlineData("unblock")]
    [InlineData("block-storage")]
    [InlineData("unblock-storage")]
    [InlineData("block-phones")]
    [InlineData("unblock-phones")]
    [InlineData("block-printers")]
    [InlineData("unblock-printers")]
    [InlineData("block-sdcard")]
    [InlineData("unblock-sdcard")]
    [InlineData("block-bluetooth")]
    [InlineData("unblock-bluetooth")]
    [InlineData("block-firewire")]
    [InlineData("unblock-firewire")]
    [InlineData("install-watcher")]
    [InlineData("remove-watcher")]
    [InlineData("install-tamper-detection")]
    [InlineData("remove-tamper-detection")]
    [InlineData("list-allowlist")]
    [InlineData("add-allowlist")]
    [InlineData("remove-allowlist")]
    [InlineData("set-notify-config")]
    public void IsAllowedAction_KnownActions_ReturnsTrue(string action)
        => Assert.True(InputValidator.IsAllowedAction(action));

    [Theory]
    [InlineData("BLOCK")]           // case-insensitive
    [InlineData("Block-Storage")]
    [InlineData("STATUS")]
    public void IsAllowedAction_CaseVariants_ReturnsTrue(string action)
        => Assert.True(InputValidator.IsAllowedAction(action));

    [Theory]
    [InlineData("")]
    [InlineData("format-c")]
    [InlineData("rm -rf /")]
    [InlineData("& Remove-Item")]
    [InlineData("block; Remove-Item")]
    [InlineData("$(malicious)")]
    [InlineData("__proto__")]
    [InlineData("block\nstatus")]   // newline injection
    public void IsAllowedAction_UnknownOrMalicious_ReturnsFalse(string action)
        => Assert.False(InputValidator.IsAllowedAction(action));

    [Fact]
    public void AllowedActions_ContainsAllExpectedEntries()
    {
        // Every block-X action has a matching unblock-X
        var blockActions   = InputValidator.AllowedActions.Where(a => a.StartsWith("block-")).ToList();
        var unblockActions = InputValidator.AllowedActions.Where(a => a.StartsWith("unblock-")).ToList();
        Assert.Equal(blockActions.Count, unblockActions.Count);

        foreach (var block in blockActions)
        {
            var counterpart = "un" + block;
            Assert.Contains(counterpart, InputValidator.AllowedActions);
        }
    }

    // ── IsValidPnpId ─────────────────────────────────────────────────────────

    [Theory]
    [InlineData(@"USBSTOR\DISK&VEN_SanDisk&PROD_Ultra&REV_1.00")]
    [InlineData(@"USBSTOR\DISK&VEN_WD&PROD_MyPassport&REV_0001\12345678")]
    [InlineData("USB#VID_0781&PID_5571")]
    [InlineData("WPD#WPD_0001")]
    [InlineData("BTHENUM#{00001105-0000-1000-8000-00805F9B34FB}")]
    [InlineData("A")]               // single char
    public void IsValidPnpId_ValidIds_ReturnsTrue(string id)
        => Assert.True(InputValidator.IsValidPnpId(id));

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("has space")]
    [InlineData("has'quote")]
    [InlineData("has\"doublequote")]
    [InlineData("has`backtick")]
    [InlineData("has$dollar")]
    [InlineData("has!exclaim")]
    [InlineData("has(paren")]
    [InlineData("has)paren")]
    [InlineData("has|pipe")]
    [InlineData("has<angle")]
    [InlineData("has>angle")]
    [InlineData("has?question")]
    [InlineData("has*star")]
    [InlineData("has+plus")]
    [InlineData("has=equals")]
    [InlineData("has~tilde")]
    [InlineData("has^caret")]
    [InlineData("has%percent")]
    [InlineData("has/slash")]
    [InlineData("has\nnewline")]
    [InlineData("has\ttab")]
    public void IsValidPnpId_InvalidIds_ReturnsFalse(string? id)
        => Assert.False(InputValidator.IsValidPnpId(id!));

    [Fact]
    public void IsValidPnpId_ExactlyMaxLength_ReturnsTrue()
        => Assert.True(InputValidator.IsValidPnpId(new string('A', 200)));

    [Fact]
    public void IsValidPnpId_ExceedsMaxLength_ReturnsFalse()
        => Assert.False(InputValidator.IsValidPnpId(new string('A', 201)));

    // ── SanitizeString ───────────────────────────────────────────────────────

    [Fact]
    public void SanitizeString_ReplacesDoubleQuoteWithSingleQuote()
    {
        var result = InputValidator.SanitizeString("Acme \"IT\" Security", 100);
        Assert.DoesNotContain("\"", result);
        Assert.Contains("'", result);
    }

    [Fact]
    public void SanitizeString_RemovesBacktick()
    {
        var result = InputValidator.SanitizeString("cmd`injection", 100);
        Assert.DoesNotContain("`", result);
        Assert.Equal("cmdinjection", result);
    }

    [Fact]
    public void SanitizeString_RemovesDollarSign()
    {
        var result = InputValidator.SanitizeString("$env:COMPUTERNAME", 100);
        Assert.DoesNotContain("$", result);
        Assert.Equal("env:COMPUTERNAME", result);
    }

    [Fact]
    public void SanitizeString_RemovesSemicolon()
    {
        var result = InputValidator.SanitizeString("IT Security; Remove-Item", 100);
        Assert.DoesNotContain(";", result);
    }

    [Fact]
    public void SanitizeString_EnforcesMaxLen()
    {
        var result = InputValidator.SanitizeString(new string('A', 150), 100);
        Assert.Equal(100, result.Length);
    }

    [Fact]
    public void SanitizeString_ShortInput_NotTruncated()
    {
        var result = InputValidator.SanitizeString("Acme IT", 100);
        Assert.Equal("Acme IT", result);
    }

    [Fact]
    public void SanitizeString_EmptyInput_ReturnsEmpty()
    {
        var result = InputValidator.SanitizeString("", 100);
        Assert.Equal(string.Empty, result);
    }

    [Fact]
    public void SanitizeString_AllDangerousChars_AllStripped()
    {
        var result = InputValidator.SanitizeString("\"`$;", 100);
        // " → ', ` → removed, $ → removed, ; → removed
        Assert.Equal("'", result);
    }

    // ── BuildPsArgs ──────────────────────────────────────────────────────────

    [Fact]
    public void BuildPsArgs_SimpleAction_ReturnsCorrectArgs()
    {
        var args = InputValidator.BuildPsArgs("status");
        Assert.Equal("-Action status", args);
    }

    [Fact]
    public void BuildPsArgs_BlockAll_ReturnsCorrectArgs()
    {
        var args = InputValidator.BuildPsArgs("block");
        Assert.Equal("-Action block", args);
    }

    [Fact]
    public void BuildPsArgs_UnknownAction_ReturnsNull()
    {
        var args = InputValidator.BuildPsArgs("format-c");
        Assert.Null(args);
    }

    [Fact]
    public void BuildPsArgs_InjectionAttemptInAction_ReturnsNull()
    {
        var args = InputValidator.BuildPsArgs("block; Remove-Item C:\\Windows");
        Assert.Null(args);
    }

    [Fact]
    public void BuildPsArgs_ValidDeviceId_IncludesDeviceIdArg()
    {
        var args = InputValidator.BuildPsArgs("add-allowlist", deviceId: @"USBSTOR\DISK&VEN_SanDisk");
        Assert.NotNull(args);
        Assert.Contains("-DeviceId", args);
        Assert.Contains("SanDisk", args);
    }

    [Fact]
    public void BuildPsArgs_InvalidDeviceId_ReturnsNull()
    {
        var args = InputValidator.BuildPsArgs("add-allowlist", deviceId: "has spaces and $injection");
        Assert.Null(args);
    }

    [Fact]
    public void BuildPsArgs_DeviceIdWithShellMetachars_ReturnsNull()
    {
        var args = InputValidator.BuildPsArgs("add-allowlist", deviceId: "$(Remove-Item C:\\Windows)");
        Assert.Null(args);
    }

    [Fact]
    public void BuildPsArgs_NotifyConfig_SanitizesAndIncludesArgs()
    {
        var args = InputValidator.BuildPsArgs(
            "set-notify-config",
            companyName:   "Acme IT",
            notifyMessage: "USB blocked by {COMPANY} policy.");

        Assert.NotNull(args);
        Assert.Contains("-CompanyName", args);
        Assert.Contains("-NotifyMessage", args);
        Assert.Contains("Acme IT", args);
    }

    [Fact]
    public void BuildPsArgs_NotifyConfig_StripsDangerousCharsFromMessage()
    {
        var args = InputValidator.BuildPsArgs(
            "set-notify-config",
            companyName:   "IT Dept",
            notifyMessage: "Blocked by IT`$; rm -rf / policy");

        Assert.NotNull(args);
        Assert.DoesNotContain("`", args);
        Assert.DoesNotContain("$", args);
        Assert.DoesNotContain(";", args);
    }

    [Fact]
    public void BuildPsArgs_NotifyConfig_EnforcesCompanyNameMaxLen()
    {
        var longName = new string('A', 200);
        var args     = InputValidator.BuildPsArgs("set-notify-config",
            companyName: longName, notifyMessage: "msg");

        Assert.NotNull(args);
        // Company name in the arg string must not exceed 100 chars
        var match = System.Text.RegularExpressions.Regex
            .Match(args!, @"-CompanyName ""([^""]+)""");
        Assert.True(match.Success);
        Assert.True(match.Groups[1].Value.Length <= 100);
    }

    [Fact]
    public void BuildPsArgs_PartialNotifyArgs_NoNotifySection()
    {
        // companyName without notifyMessage — neither param is written
        var args = InputValidator.BuildPsArgs("set-notify-config", companyName: "Acme");
        Assert.NotNull(args);
        Assert.DoesNotContain("-CompanyName", args);
    }

    [Fact]
    public void BuildPsArgs_CaseInsensitiveAction_Works()
    {
        var args = InputValidator.BuildPsArgs("BLOCK");
        Assert.NotNull(args);
        Assert.Contains("-Action BLOCK", args);
    }
}
