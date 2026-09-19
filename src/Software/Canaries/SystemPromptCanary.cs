using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Threading;

internal static class SystemPromptCanary
{
    private static int Main(string[] args)
    {
        var options = ParseArguments(args);
        string resultPath = Get(options, "result", null);
        int settleMs = Int32.Parse(Get(options, "settle-ms", "15000"), CultureInfo.InvariantCulture);
        if (String.IsNullOrWhiteSpace(resultPath) || settleMs < 1000 || settleMs > 60000)
        {
            Console.Error.WriteLine("--result is required and --settle-ms must be between 1000 and 60000.");
            return 2;
        }

        TcpListener listener = null;
        try
        {
            bool elevated = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
            listener = new TcpListener(IPAddress.Any, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Thread.Sleep(settleMs);

            string directory = Path.GetDirectoryName(resultPath);
            if (!String.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
            string json = "{\"passed\":" + (elevated ? "true" : "false") +
                ",\"elevated\":" + (elevated ? "true" : "false") +
                ",\"listening\":true,\"port\":" + port.ToString(CultureInfo.InvariantCulture) +
                ",\"processId\":" + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
                ",\"writtenUtc\":\"" + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\"}";
            string temporaryPath = resultPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            byte[] payload = new UTF8Encoding(false).GetBytes(json);
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(payload, 0, payload.Length);
                stream.Flush(true);
            }
            if (File.Exists(resultPath)) File.Delete(resultPath);
            File.Move(temporaryPath, resultPath);
            return elevated ? 0 : 1;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 1;
        }
        finally
        {
            if (listener != null) listener.Stop();
        }
    }

    private static Dictionary<string, string> ParseArguments(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < args.Length; index++)
        {
            if (!args[index].StartsWith("--", StringComparison.Ordinal)) continue;
            string key = args[index].Substring(2);
            string value = index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal) ? args[++index] : "true";
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
