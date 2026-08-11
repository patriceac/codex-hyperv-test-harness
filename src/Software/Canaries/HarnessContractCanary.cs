using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class HarnessContractCanary
{
    [STAThread]
    private static int Main(string[] args)
    {
        var options = ParseArguments(args);
        string resultPath = Get(options, "result", null);
        bool passed = Boolean.Parse(Get(options, "passed", "true"));
        int delayMs = Int32.Parse(Get(options, "delay-ms", "1000"), CultureInfo.InvariantCulture);
        int stayMs = Int32.Parse(Get(options, "stay-ms", "3000"), CultureInfo.InvariantCulture);
        int exitCode = Int32.Parse(Get(options, "exit-code", "0"), CultureInfo.InvariantCulture);

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
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 16, FontStyle.Regular),
            Text = "Waiting to publish the application result..."
        };
        form.Controls.Add(status);
        form.Controls.Add(title);

        var publishTimer = new Timer { Interval = Math.Max(1, delayMs) };
        publishTimer.Tick += delegate
        {
            publishTimer.Stop();
            if (!String.IsNullOrWhiteSpace(resultPath))
            {
                string directory = Path.GetDirectoryName(resultPath);
                if (!String.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
                string json = "{\"passed\":" + (passed ? "true" : "false") +
                    ",\"processId\":" + System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
                    ",\"writtenUtc\":\"" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\"}";
                string temporaryPath = resultPath + ".tmp";
                File.WriteAllText(temporaryPath, json, new UTF8Encoding(false));
                if (File.Exists(resultPath)) File.Delete(resultPath);
                File.Move(temporaryPath, resultPath);
            }
            status.Text = passed ? "Application result: PASSED" : "Application result: FAILED";
            status.ForeColor = passed ? Color.FromArgb(85, 230, 165) : Color.FromArgb(255, 113, 113);
        };

        var closeTimer = new Timer { Interval = Math.Max(1, delayMs + Math.Max(0, stayMs)) };
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
            publishTimer.Start();
            closeTimer.Start();
        };

        Application.Run(form);
        return exitCode;
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
