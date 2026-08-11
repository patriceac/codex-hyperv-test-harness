using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

internal static class HostInputCanary
{
    private static int Main(string[] args)
    {
        var options = ParseArguments(args);
        string inputPath = Get(options, "input", null);
        string outputDirectory = Get(options, "out", null);
        int holdMilliseconds = Int32.Parse(Get(options, "hold-ms", "2000"), CultureInfo.InvariantCulture);
        if (String.IsNullOrWhiteSpace(inputPath) || String.IsNullOrWhiteSpace(outputDirectory)) return 2;

        Directory.CreateDirectory(outputDirectory);
        string resultPath = Path.Combine(outputDirectory, "host-input-result.json");
        bool passed = false;
        bool readSucceeded = false;
        bool createDenied = false;
        bool overwriteDenied = false;
        bool renameDenied = false;
        bool deleteDenied = false;
        long bytesObserved = 0;
        string inputKind = "missing";
        string failure = null;

        try
        {
            if (Directory.Exists(inputPath))
            {
                inputKind = "directory";
                string markerPath = Path.Combine(inputPath, "marker.txt");
                string largePath = Path.Combine(inputPath, "large.bin");
                readSucceeded = File.ReadAllText(markerPath, Encoding.UTF8).Trim() == "host-input-canary";
                bytesObserved = File.Exists(largePath) ? new FileInfo(largePath).Length : 0;

                string createPath = Path.Combine(inputPath, "guest-create-probe-" + Guid.NewGuid().ToString("N") + ".tmp");
                string overwritePath = Path.Combine(inputPath, "overwrite-probe.txt");
                string renamePath = Path.Combine(inputPath, "rename-probe.txt");
                string renamedPath = Path.Combine(inputPath, "rename-probe-renamed.txt");
                string deletePath = Path.Combine(inputPath, "delete-probe.txt");

                createDenied = IsDenied(delegate { File.WriteAllText(createPath, "guest create probe", new UTF8Encoding(false)); });
                overwriteDenied = IsDenied(delegate { File.WriteAllText(overwritePath, "guest overwrite probe", new UTF8Encoding(false)); });
                renameDenied = IsDenied(delegate { File.Move(renamePath, renamedPath); });
                deleteDenied = IsDenied(delegate { File.Delete(deletePath); });
            }
            else if (File.Exists(inputPath))
            {
                inputKind = "file";
                bytesObserved = new FileInfo(inputPath).Length;
                using (var stream = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    readSucceeded = stream.ReadByte() >= 0 || stream.Length == 0;
                }
                createDenied = overwriteDenied = IsDenied(delegate
                {
                    using (new FileStream(inputPath, FileMode.Open, FileAccess.Write, FileShare.Read)) { }
                });
                renameDenied = true;
                deleteDenied = true;
            }

            passed = readSucceeded && createDenied && overwriteDenied && renameDenied && deleteDenied;
            if (!passed) failure = "One or more read-only host-input checks failed.";
        }
        catch (Exception exception)
        {
            failure = exception.GetType().FullName + ": " + exception.Message;
        }

        string json = "{" +
            "\"passed\":" + JsonBoolean(passed) + "," +
            "\"processId\":" + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) + "," +
            "\"inputKind\":\"" + JsonEscape(inputKind) + "\"," +
            "\"readSucceeded\":" + JsonBoolean(readSucceeded) + "," +
            "\"bytesObserved\":" + bytesObserved.ToString(CultureInfo.InvariantCulture) + "," +
            "\"createDenied\":" + JsonBoolean(createDenied) + "," +
            "\"overwriteDenied\":" + JsonBoolean(overwriteDenied) + "," +
            "\"renameDenied\":" + JsonBoolean(renameDenied) + "," +
            "\"deleteDenied\":" + JsonBoolean(deleteDenied) + "," +
            "\"failure\":" + (failure == null ? "null" : "\"" + JsonEscape(failure) + "\"") + "," +
            "\"writtenUtc\":\"" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\"}";
        WriteAtomic(resultPath, json);
        if (holdMilliseconds > 0) Thread.Sleep(Math.Min(holdMilliseconds, 300000));
        return passed ? 0 : 1;
    }

    private static bool IsDenied(Action operation)
    {
        try
        {
            operation();
            return false;
        }
        catch (UnauthorizedAccessException) { return true; }
        catch (System.Security.SecurityException) { return true; }
        catch (IOException) { return true; }
    }

    private static void WriteAtomic(string path, string content)
    {
        string temporaryPath = path + ".tmp";
        File.WriteAllText(temporaryPath, content, new UTF8Encoding(false));
        if (File.Exists(path)) File.Delete(path);
        File.Move(temporaryPath, path);
    }

    private static string JsonBoolean(bool value) { return value ? "true" : "false"; }

    private static string JsonEscape(string value)
    {
        if (value == null) return String.Empty;
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
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
