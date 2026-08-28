using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class LiveEvidenceCanary
{
    private static Form form;
    private static Label phaseLabel;
    private static Label detailLabel;
    private static Label markerLabel;
    private static string outputDirectory;
    private static int phase;

    [STAThread]
    private static int Main(string[] args)
    {
        var options = ParseArguments(args);
        outputDirectory = Get(options, "outdir", null);
        if (String.IsNullOrWhiteSpace(outputDirectory))
        {
            Console.Error.WriteLine("--outdir is required.");
            return 2;
        }
        outputDirectory = Path.GetFullPath(outputDirectory);
        Directory.CreateDirectory(outputDirectory);

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        form = new Form
        {
            Text = "Hyper-V Live Evidence Canary",
            StartPosition = FormStartPosition.CenterScreen,
            ClientSize = new Size(780, 440),
            FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false,
            MinimizeBox = false,
            BackColor = Color.FromArgb(17, 32, 57),
            ForeColor = Color.White
        };

        var title = new Label
        {
            AutoSize = false,
            Bounds = new Rectangle(40, 38, 700, 52),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI Semibold", 22F, FontStyle.Bold),
            Text = "BROKER-MEDIATED LIVE OBSERVATION"
        };
        phaseLabel = new Label
        {
            AutoSize = false,
            Bounds = new Rectangle(55, 128, 670, 95),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 34F, FontStyle.Bold)
        };
        detailLabel = new Label
        {
            AutoSize = false,
            Bounds = new Rectangle(70, 242, 640, 65),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 13F, FontStyle.Regular)
        };
        markerLabel = new Label
        {
            AutoSize = false,
            Bounds = new Rectangle(70, 340, 640, 38),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Consolas", 12F, FontStyle.Bold),
            ForeColor = Color.FromArgb(203, 213, 225)
        };
        form.Controls.Add(title);
        form.Controls.Add(phaseLabel);
        form.Controls.Add(detailLabel);
        form.Controls.Add(markerLabel);

        var phaseTimer = new Timer { Interval = 18000 };
        var closeTimer = new Timer { Interval = 15000 };
        phaseTimer.Tick += delegate
        {
            if (phase < 3)
            {
                SetPhase(phase + 1);
                return;
            }

            phaseTimer.Stop();
            SetCompleted();
            closeTimer.Start();
        };
        closeTimer.Tick += delegate
        {
            closeTimer.Stop();
            form.Close();
        };
        form.Shown += delegate
        {
            SetPhase(1);
            phaseTimer.Start();
        };
        form.FormClosed += delegate
        {
            phaseTimer.Dispose();
            closeTimer.Dispose();
        };

        Application.Run(form);
        return 0;
    }

    private static void SetPhase(int value)
    {
        phase = value;
        string state;
        string detail;
        Color color;
        switch (value)
        {
            case 1:
                state = "PHASE 1 · AZURE";
                detail = "The application is active while wait_result_file remains pending.";
                color = Color.FromArgb(56, 189, 248);
                break;
            case 2:
                state = "PHASE 2 · AMBER";
                detail = "A later capture must show this distinct application state.";
                color = Color.FromArgb(251, 191, 36);
                break;
            default:
                state = "PHASE 3 · VIOLET";
                detail = "Live observations did not cancel, restart, or extend the request.";
                color = Color.FromArgb(196, 181, 253);
                break;
        }
        form.BackColor = Color.FromArgb(
            Math.Max(8, color.R / 7),
            Math.Max(12, color.G / 7),
            Math.Max(18, color.B / 7));
        phaseLabel.Text = state;
        phaseLabel.ForeColor = color;
        detailLabel.Text = detail;
        markerLabel.Text = "LIVE-EVIDENCE-CANARY · SEQUENCE " + value.ToString(CultureInfo.InvariantCulture);
        WriteJsonAtomic(
            Path.Combine(outputDirectory, "release-gate-progress.json"),
            "{\"phase\":" + value.ToString(CultureInfo.InvariantCulture) +
            ",\"state\":\"" + state + "\",\"processId\":" +
            System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
            ",\"writtenUtc\":\"" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\"}");
    }

    private static void SetCompleted()
    {
        phase = 4;
        form.BackColor = Color.FromArgb(10, 48, 38);
        phaseLabel.Text = "COMPLETE · EMERALD";
        phaseLabel.ForeColor = Color.FromArgb(52, 211, 153);
        detailLabel.Text = "The original request is finishing normally; terminal evidence follows.";
        markerLabel.Text = "LIVE-EVIDENCE-CANARY · ORIGINAL REQUEST COMPLETING";
        string timestamp = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
        string processId = System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture);
        WriteJsonAtomic(
            Path.Combine(outputDirectory, "release-gate-progress.json"),
            "{\"phase\":4,\"state\":\"COMPLETE · EMERALD\",\"processId\":" + processId +
            ",\"writtenUtc\":\"" + timestamp + "\"}");
        WriteJsonAtomic(
            Path.Combine(outputDirectory, "live-evidence-canary-complete.json"),
            "{\"passed\":true,\"phase\":4,\"processId\":" + processId +
            ",\"writtenUtc\":\"" + timestamp + "\"}");
    }

    private static void WriteJsonAtomic(string path, string json)
    {
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temporary, json, new UTF8Encoding(false));
        if (File.Exists(path))
        {
            File.Replace(temporary, path, null, true);
        }
        else
        {
            File.Move(temporary, path);
        }
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
