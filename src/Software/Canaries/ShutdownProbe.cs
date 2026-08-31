using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

internal static class ShutdownProbe
{
    private static int Main(string[] args)
    {
        var options = ParseArguments(args);
        string markerPath = Get(options, "marker", null);
        int delayMs = Int32.Parse(Get(options, "delay-ms", "3000"), CultureInfo.InvariantCulture);
        if (String.IsNullOrWhiteSpace(markerPath))
        {
            Console.Error.WriteLine("--marker is required.");
            return 2;
        }
        if (delayMs < 0 || delayMs > 30000)
        {
            Console.Error.WriteLine("--delay-ms must be between 0 and 30000.");
            return 2;
        }

        try
        {
            string directory = Path.GetDirectoryName(markerPath);
            if (!String.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);

            string json = "{\"passed\":true,\"requestedShutdown\":true,\"processId\":" +
                Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
                ",\"writtenUtc\":\"" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\"}";
            string temporaryPath = markerPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            byte[] payload = new UTF8Encoding(false).GetBytes(json);
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(payload, 0, payload.Length);
                stream.Flush(true);
            }
            if (File.Exists(markerPath)) File.Delete(markerPath);
            File.Move(temporaryPath, markerPath);
            System.Threading.Thread.Sleep(delayMs);

            var shutdown = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "shutdown.exe"),
                Arguments = "/s /t 0",
                CreateNoWindow = true,
                UseShellExecute = false
            };
            Process.Start(shutdown);
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 1;
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
