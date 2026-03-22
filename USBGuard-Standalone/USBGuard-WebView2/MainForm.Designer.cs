namespace USBGuard;

partial class MainForm
{
    private System.ComponentModel.IContainer components = null!;

    protected override void Dispose(bool disposing)
    {
        if (disposing && components is not null)
            components.Dispose();
        base.Dispose(disposing);
    }

    private void InitializeComponent()
    {
        components = new System.ComponentModel.Container();
        AutoScaleMode    = System.Windows.Forms.AutoScaleMode.Dpi;
        ClientSize       = new System.Drawing.Size(1280, 900);
        MinimumSize      = new System.Drawing.Size(920, 700);
        Text             = "USBGuard";
        StartPosition    = System.Windows.Forms.FormStartPosition.CenterScreen;
        BackColor        = System.Drawing.Color.FromArgb(10, 12, 16);
        // Icon loaded from embedded resource if present; no-op if not found
        try
        {
            Icon = new System.Drawing.Icon(
                System.Reflection.Assembly.GetExecutingAssembly()
                    .GetManifestResourceStream("USBGuard.app.ico")
                ?? System.IO.Stream.Null);
        }
        catch { /* no icon bundled — that's fine */ }
    }
}
