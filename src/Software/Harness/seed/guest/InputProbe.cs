using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        string resultPath = null;
        for (int index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], "--result", StringComparison.OrdinalIgnoreCase))
            {
                resultPath = args[index + 1];
            }
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new InputProbeForm(resultPath));
    }
}

internal sealed class InputProbeForm : Form
{
    private readonly string _resultPath;
    private readonly TextBox _inputBox;
    private readonly Label _statusLabel;
    private readonly Button _confirmButton;

    public InputProbeForm(string resultPath)
    {
        _resultPath = resultPath;

        Text = "Codex Input Probe";
        Name = "InputProbeWindow";
        AccessibleName = "InputProbeWindow";
        ClientSize = new Size(640, 380);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        BackColor = Color.FromArgb(19, 27, 48);
        ForeColor = Color.White;
        TopMost = true;

        Label heading = new Label();
        heading.AutoSize = false;
        heading.Text = "Headless Hyper-V input test";
        heading.Font = new Font("Segoe UI Semibold", 23F, FontStyle.Regular);
        heading.TextAlign = ContentAlignment.MiddleCenter;
        heading.Location = new Point(20, 24);
        heading.Size = new Size(600, 52);
        Controls.Add(heading);

        Label instructions = new Label();
        instructions.AutoSize = false;
        instructions.Text = "The guest agent will type below, then perform a real mouse click.";
        instructions.Font = new Font("Segoe UI", 11F, FontStyle.Regular);
        instructions.ForeColor = Color.FromArgb(190, 210, 225);
        instructions.TextAlign = ContentAlignment.MiddleCenter;
        instructions.Location = new Point(20, 82);
        instructions.Size = new Size(600, 28);
        Controls.Add(instructions);

        _inputBox = new TextBox();
        _inputBox.Name = "InputBox";
        _inputBox.AccessibleName = "InputBox";
        _inputBox.Font = new Font("Consolas", 14F, FontStyle.Regular);
        _inputBox.Location = new Point(65, 127);
        _inputBox.Size = new Size(510, 29);
        _inputBox.TextAlign = HorizontalAlignment.Center;
        _inputBox.TextChanged += delegate
        {
            _statusLabel.Text = "Keyboard characters received: " + _inputBox.TextLength;
        };
        Controls.Add(_inputBox);

        _confirmButton = new Button();
        _confirmButton.Name = "ConfirmButton";
        _confirmButton.AccessibleName = "ConfirmButton";
        _confirmButton.Text = "Confirm mouse click";
        _confirmButton.Font = new Font("Segoe UI Semibold", 12F, FontStyle.Regular);
        _confirmButton.Location = new Point(185, 195);
        _confirmButton.Size = new Size(270, 48);
        _confirmButton.BackColor = Color.FromArgb(30, 220, 177);
        _confirmButton.ForeColor = Color.FromArgb(10, 40, 44);
        _confirmButton.FlatStyle = FlatStyle.Flat;
        _confirmButton.FlatAppearance.BorderSize = 0;
        _confirmButton.Click += ConfirmButtonClick;
        Controls.Add(_confirmButton);

        _statusLabel = new Label();
        _statusLabel.Name = "StatusLabel";
        _statusLabel.AccessibleName = "StatusLabel";
        _statusLabel.AutoSize = false;
        _statusLabel.Text = "Waiting for guest input...";
        _statusLabel.Font = new Font("Segoe UI Semibold", 12F, FontStyle.Regular);
        _statusLabel.ForeColor = Color.FromArgb(30, 220, 177);
        _statusLabel.TextAlign = ContentAlignment.MiddleCenter;
        _statusLabel.Location = new Point(40, 270);
        _statusLabel.Size = new Size(560, 58);
        Controls.Add(_statusLabel);

        Timer safetyTimer = new Timer();
        safetyTimer.Interval = 120000;
        safetyTimer.Tick += delegate { Close(); };
        safetyTimer.Start();

        Shown += delegate { _inputBox.Focus(); };
    }

    private void ConfirmButtonClick(object sender, EventArgs eventArgs)
    {
        bool keyboardReceived = _inputBox.TextLength > 0;
        _statusLabel.Text = keyboardReceived
            ? "MOUSE CLICK RECEIVED\r\nKEYBOARD TEXT VERIFIED"
            : "Mouse click received, but keyboard text is empty";
        _statusLabel.ForeColor = keyboardReceived
            ? Color.FromArgb(30, 220, 177)
            : Color.FromArgb(255, 190, 75);

        if (!string.IsNullOrWhiteSpace(_resultPath))
        {
            string directory = Path.GetDirectoryName(_resultPath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            string json = "{" +
                "\"keyboardText\":\"" + JsonEscape(_inputBox.Text) + "\"," +
                "\"keyboardReceived\":" + (keyboardReceived ? "true" : "false") + "," +
                "\"mouseClicked\":true," +
                "\"timestampUtc\":\"" + DateTime.UtcNow.ToString("o") + "\"," +
                "\"processId\":" + Process.GetCurrentProcess().Id + "," +
                "\"sessionId\":" + Process.GetCurrentProcess().SessionId + "," +
                "\"userInteractive\":" + (Environment.UserInteractive ? "true" : "false") + "," +
                "\"userName\":\"" + JsonEscape(Environment.UserName) + "\"" +
                "}";
            File.WriteAllText(_resultPath, json, Encoding.UTF8);
        }
    }

    private static string JsonEscape(string value)
    {
        if (value == null)
        {
            return string.Empty;
        }

        return value
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"")
            .Replace("\r", "\\r")
            .Replace("\n", "\\n")
            .Replace("\t", "\\t");
    }
}
