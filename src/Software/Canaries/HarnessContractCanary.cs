using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class HarnessContractCanary
{
    private const string AccentedControlName = "Approuver le pilote et d\u00E9bloquer la file";

    [STAThread]
    private static int Main(string[] args)
    {
        var options = ParseArguments(args);
        string resultPath = Get(options, "result", null);
        bool passed = Boolean.Parse(Get(options, "passed", "true"));
        int delayMs = Int32.Parse(Get(options, "delay-ms", "1000"), CultureInfo.InvariantCulture);
        int stayMs = Int32.Parse(Get(options, "stay-ms", "3000"), CultureInfo.InvariantCulture);
        int exitCode = Int32.Parse(Get(options, "exit-code", "0"), CultureInfo.InvariantCulture);
        bool requireClick = Boolean.Parse(Get(options, "require-click", "false"));

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var form = new Form
        {
            Text = "Hyper-V Harness Contract Canary",
            StartPosition = FormStartPosition.Manual,
            Location = new Point(220, 160),
            ClientSize = new Size(720, 400),
            BackColor = Color.FromArgb(19, 27, 46),
            ForeColor = Color.White
        };
        var title = new Label
        {
            AutoSize = false,
            Dock = DockStyle.Top,
            Height = 110,
            TextAlign = ContentAlignment.BottomCenter,
            Font = new Font("Segoe UI", 24, FontStyle.Bold),
            Text = "HARNESS CONTRACT CANARY"
        };
        var status = new Label
        {
            AutoSize = false,
            Location = new Point(80, 135),
            Size = new Size(560, 90),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 16, FontStyle.Regular),
            Text = requireClick ? "Waiting for the named control click..." : "Waiting to publish the application result..."
        };
        form.Controls.Add(status);
        form.Controls.Add(title);

        Button approvalButton = null;
        if (requireClick)
        {
            approvalButton = new Button
            {
                Name = "AccentedApprovalButton",
                AccessibleName = AccentedControlName,
                Text = AccentedControlName,
                Font = new Font("Segoe UI Semibold", 12, FontStyle.Regular),
                Location = new Point(145, 255),
                Size = new Size(430, 58),
                BackColor = Color.FromArgb(85, 230, 165),
                ForeColor = Color.FromArgb(19, 27, 46),
                FlatStyle = FlatStyle.Flat
            };
            approvalButton.FlatAppearance.BorderSize = 0;
            approvalButton.Click += delegate
            {
                WriteResult(resultPath, passed, AccentedControlName);
                status.Text = passed ? "Accented control click: PASSED" : "Accented control click: FAILED";
                status.ForeColor = passed ? Color.FromArgb(85, 230, 165) : Color.FromArgb(255, 113, 113);
                approvalButton.Enabled = false;
            };
            form.Controls.Add(approvalButton);
            approvalButton.BringToFront();
        }

        var publishTimer = new Timer { Interval = Math.Max(1, delayMs) };
        publishTimer.Tick += delegate
        {
            publishTimer.Stop();
            WriteResult(resultPath, passed, null);
            status.Text = passed ? "Application result: PASSED" : "Application result: FAILED";
            status.ForeColor = passed ? Color.FromArgb(85, 230, 165) : Color.FromArgb(255, 113, 113);
        };

        var closeTimer = new Timer { Interval = Math.Max(1, (requireClick ? 0 : delayMs) + Math.Max(0, stayMs)) };
        closeTimer.Tick += delegate
        {
            closeTimer.Stop();
            form.Close();
        };
        form.FormClosed += delegate
        {
            publishTimer.Dispose();
            closeTimer.Dispose();
            Environment.ExitCode = exitCode;
        };
        form.Shown += delegate
        {
            if (!requireClick) publishTimer.Start();
            closeTimer.Start();
        };

        Application.Run(form);
        return exitCode;
    }

    private static void WriteResult(string resultPath, bool passed, string clickedControlName)
    {
        if (String.IsNullOrWhiteSpace(resultPath)) return;
        string directory = Path.GetDirectoryName(resultPath);
        if (!String.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
        string clickedProperty = clickedControlName == null
            ? String.Empty
            : ",\"clickedControlName\":\"" + EscapeJson(clickedControlName) + "\"";
        string json = "{\"passed\":" + (passed ? "true" : "false") +
            ",\"processId\":" + System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
            clickedProperty +
            ",\"writtenUtc\":\"" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\"}";
        string temporaryPath = resultPath + ".tmp";
        File.WriteAllText(temporaryPath, json, new UTF8Encoding(false));
        if (File.Exists(resultPath)) File.Delete(resultPath);
        File.Move(temporaryPath, resultPath);
    }

    private static string EscapeJson(string value)
    {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    private static Dictionary<string, string> ParseArguments(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < args.Length; index++)
        {
            if (!args[index].StartsWith("--", StringComparison.Ordinal)) continue;
            string key = args[index].Substring(2);
            string value = index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal)
                ? args[++index]
                : "true";
            result[key] = value;
        }
        return result;
    }

    private static string Get(Dictionary<string, string> options, string key, string fallback)
    {
        string value;
        return options.TryGetValue(key, out value) ? value : fallback;
    }
}
