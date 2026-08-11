using System;
using System.Drawing;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var form = new Form
        {
            Text = "Hyper-V Pool Canary",
            ClientSize = new Size(520, 220),
            StartPosition = FormStartPosition.CenterScreen,
            BackColor = Color.FromArgb(16, 24, 40),
            FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false
        };

        var title = new Label
        {
            AutoSize = false,
            Text = "ISOLATED WORKER READY",
            ForeColor = Color.FromArgb(101, 221, 170),
            Font = new Font("Segoe UI Semibold", 20F, FontStyle.Bold),
            TextAlign = ContentAlignment.MiddleCenter,
            Bounds = new Rectangle(20, 38, 480, 52)
        };
        var detail = new Label
        {
            AutoSize = false,
            Text = "Executable launched from its disposable payload VHDX",
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 11F),
            TextAlign = ContentAlignment.MiddleCenter,
            Bounds = new Rectangle(20, 104, 480, 40)
        };
        var marker = new Label
        {
            AutoSize = false,
            Name = "evidenceMarker",
            Text = "POOL-CANARY-OK",
            ForeColor = Color.FromArgb(148, 163, 184),
            Font = new Font("Consolas", 10F),
            TextAlign = ContentAlignment.MiddleCenter,
            Bounds = new Rectangle(20, 158, 480, 24)
        };

        form.Controls.Add(title);
        form.Controls.Add(detail);
        form.Controls.Add(marker);
        Application.Run(form);
    }
}
