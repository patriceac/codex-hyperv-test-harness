using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

internal static class DetachedLockCanary
{
    private static int Main(string[] args)
    {
        string outdir = GetArgument(args, "--outdir");
        if (String.IsNullOrWhiteSpace(outdir)) return 2;
        Directory.CreateDirectory(outdir);

        if (HasArgument(args, "--child"))
        {
            return RunChild(outdir);
        }

        string executable = Process.GetCurrentProcess().MainModule.FileName;
        var child = Process.Start(new ProcessStartInfo
        {
            FileName = executable,
            Arguments = "--child --outdir \"" + outdir.Replace("\"", "\\\"") + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(executable)
        });
        if (child == null) return 3;
        Thread.Sleep(250);
        return 0;
    }

    private static int RunChild(string outdir)
    {
        string lockPath = Path.Combine(outdir, "descendant-exclusive-lock.log");
        using (var stream = new FileStream(lockPath, FileMode.Create, FileAccess.ReadWrite, FileShare.None))
        {
            byte[] content = Encoding.UTF8.GetBytes("held exclusively by descendant PID " +
                Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
            stream.Write(content, 0, content.Length);
            stream.Flush(true);

            string resultPath = Path.Combine(outdir, "child-ready.json");
            string temporaryPath = resultPath + ".tmp";
            File.WriteAllText(temporaryPath,
                "{\"passed\":true,\"childProcessId\":" +
                Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) + "}",
                new UTF8Encoding(false));
            if (File.Exists(resultPath)) File.Delete(resultPath);
            File.Move(temporaryPath, resultPath);

            Thread.Sleep(TimeSpan.FromMinutes(10));
        }
        return 0;
    }

    private static bool HasArgument(string[] args, string name)
    {
        foreach (string argument in args)
        {
            if (String.Equals(argument, name, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static string GetArgument(string[] args, string name)
    {
        for (int index = 0; index + 1 < args.Length; index++)
        {
            if (String.Equals(args[index], name, StringComparison.OrdinalIgnoreCase)) return args[index + 1];
        }
        return null;
    }
}
