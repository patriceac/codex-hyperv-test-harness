using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal static class PowerTestCanary {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static readonly string Installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "CodexHarnessPowerCanary", "PowerTestCanary.exe");
    static string Quote(string value) { return "\"" + value + "\""; }
    static void Marker(string path) {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, "{\"passed\":true}", new UTF8Encoding(false));
        File.Move(temporary, path);
    }
    static void WaitFor(string path) {
        var timeout = Stopwatch.StartNew();
        while (!File.Exists(path)) { if (timeout.ElapsedMilliseconds > 60000) throw new Exception("Startup marker missing."); Thread.Sleep(200); }
    }
    static void Power(string operation) {
        using (var process = Process.Start(new ProcessStartInfo("shutdown.exe", operation + " /t 5 /f") { UseShellExecute = false, CreateNoWindow = true })) {
            process.WaitForExit(); if (process.ExitCode != 0) throw new Exception("Guest power request failed.");
        }
        Thread.Sleep(Timeout.Infinite);
    }
    static void RunOnce(string mode, string output) {
        using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\RunOnce")) {
            key.SetValue("CodexHarnessPowerCanary", Quote(Installed) + " " + mode + " " + Quote(output));
        }
    }
    static void ObserveStartupNetwork(string output, string mode) {
        object firewall = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2"));
        try {
            int profiles = (int)firewall.GetType().InvokeMember("CurrentProfileTypes", System.Reflection.BindingFlags.GetProperty, null, firewall, null);
            var excluded = (Array)firewall.GetType().InvokeMember("ExcludedInterfaces", System.Reflection.BindingFlags.GetProperty, null, firewall, new object[] { 2 });
            bool passed = profiles == 2 && excluded != null && excluded.Length == 1;
            File.WriteAllText(Path.Combine(output, "startup-" + mode + ".json"), Json.Serialize(new {
                passed, firewallProfileTypes = profiles, firewallExcludedInterfaces = excluded, observedUtc = DateTime.UtcNow.ToString("o")
            }));
            if (!passed) throw new Exception("Autonomous startup did not observe the Private firewall profile and isolated interface exemption.");
        } finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(firewall); }
    }
    // A request-scoped challenge proves traffic between two broker-owned guests.
    // Discovery stays inside the isolated cohort; no host endpoint is involved.
    static void NetworkPeer(string output, string token) {
        using (var udp = new UdpClient(42572)) {
            udp.Client.ReceiveTimeout = 500;
            var timeout = Stopwatch.StartNew();
            string address = null, machine = null;
            bool automatic = false, manual = false;
            long completeAt = -1;
            while (timeout.ElapsedMilliseconds < 900000) {
                if (completeAt >= 0 && timeout.ElapsedMilliseconds >= completeAt) {
                    File.WriteAllText(Path.Combine(output, "peer.json.tmp"), Json.Serialize(new { passed = true, address, machine, automatic, manual, token }));
                    File.Move(Path.Combine(output, "peer.json.tmp"), Path.Combine(output, "peer.json"));
                    return;
                }
                IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                byte[] data;
                try { data = udp.Receive(ref remote); } catch (SocketException ex) { if (ex.SocketErrorCode == SocketError.TimedOut) continue; throw; }
                string[] parts = Encoding.UTF8.GetString(data).Split('|');
                if (parts.Length != 3 || parts[0] != token || (parts[1] != "auto" && parts[1] != "manual")) continue;
                if (address != null && (address != remote.Address.ToString() || machine != parts[2])) throw new Exception("Peer identity changed.");
                address = remote.Address.ToString(); machine = parts[2];
                if (parts[1] == "auto") automatic = true;
                if (parts[1] == "manual" && automatic) manual = true;
                byte[] reply = Encoding.UTF8.GetBytes(token + "|" + parts[1] + "|" + Environment.MachineName);
                udp.Send(reply, reply.Length, remote);
                if (automatic && manual && completeAt < 0) completeAt = timeout.ElapsedMilliseconds + 3000;
            }
            throw new Exception("Both boot challenges were not observed.");
        }
    }
    static void CheckNetwork(string output, string token, string phase) {
        using (var udp = new UdpClient(0)) {
            udp.EnableBroadcast = true; udp.Client.ReceiveTimeout = 500;
            var timeout = Stopwatch.StartNew();
            byte[] challenge = Encoding.UTF8.GetBytes(token + "|" + phase + "|" + Environment.MachineName);
            while (timeout.ElapsedMilliseconds < 30000) {
                udp.Send(challenge, challenge.Length, new IPEndPoint(IPAddress.Broadcast, 42572));
                IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                byte[] data;
                try { data = udp.Receive(ref remote); } catch (SocketException ex) { if (ex.SocketErrorCode == SocketError.TimedOut) continue; throw; }
                string[] parts = Encoding.UTF8.GetString(data).Split('|');
                if (parts.Length != 3 || parts[0] != token || parts[1] != phase || remote.Port != 42572) continue;
                File.WriteAllText(Path.Combine(output, "network-" + phase + ".json"), Json.Serialize(new { passed = true, token, phase, peerAddress = remote.Address.ToString(), peerMachine = parts[2] }));
                return;
            }
            throw new Exception("Cross-guest boot challenge failed.");
        }
    }
    [STAThread]
    static int Main(string[] args) {
        if (!File.Exists(@"C:\CodexGuest\GuestAgent.ps1") || args.Length < 2) return 90;
        string mode = args[0], output = args[1];
        try {
            if (mode == "network-peer") {
                Directory.CreateDirectory(output);
                NetworkPeer(output, args[2]);
                return 0;
            }
            if (mode == "fail-restart") {
                Directory.CreateDirectory(Path.Combine(output, "product-data"));
                File.WriteAllText(Path.Combine(output, "product-data", "restart-session.resume"), "failure-diagnostic-canary");
                File.WriteAllText(Path.Combine(output, "before-boot-1.json"), "{\"passed\":false}");
                return 1;
            }
            if (mode == "setup" || mode == "setup-payload") {
                if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 91;
                if (mode == "setup-payload" && (args.Length != 3 || !Path.IsPathRooted(args[2]) || !File.Exists(args[2]))) return 98;
                Directory.CreateDirectory(Path.GetDirectoryName(Installed));
                File.Copy(Process.GetCurrentProcess().MainModule.FileName, Installed, true);
                if (mode == "setup" && args.Length > 2) {
                    var fixture = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(args[2], Encoding.UTF8));
                    if ((string)fixture["UserSid"] != WindowsIdentity.GetCurrent().User.Value || (string)fixture["Protection"] != "DPAPI CurrentUser") return 92;
                    byte[] plain = ProtectedData.Unprotect(Convert.FromBase64String((string)fixture["ProtectedPassword"]), null, DataProtectionScope.CurrentUser);
                    try {
                        using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon", true)) {
                            if (key.GetValue("DefaultPassword") != null || key.GetValue("AutoLogonCount") != null || (string)key.GetValue("AutoAdminLogon") != "0") return 93;
                            key.SetValue("DefaultUserName", (string)fixture["UserName"]);
                            key.SetValue("DefaultDomainName", Environment.MachineName);
                            key.SetValue("DefaultPassword", Encoding.UTF8.GetString(plain));
                            key.SetValue("AutoLogonCount", 1, RegistryValueKind.DWord);
                            key.SetValue("AutoAdminLogon", "1");
                        }
                    } finally { Array.Clear(plain, 0, plain.Length); }
                }
                Marker(Path.Combine(Path.GetDirectoryName(Installed), "installed.json"));
                return 0;
            }
            if (!File.Exists(Path.Combine(Path.GetDirectoryName(Installed), "installed.json"))) return 94;
            if (mode == "initial") {
                Directory.CreateDirectory(output);
                using (File.Open(Path.Combine(output, "initial-launched-once"), FileMode.CreateNew)) { }
                RunOnce("after-auto", output);
                Marker(Path.Combine(output, "before-boot-1.json"));
                Power("/r");
            } else if (mode == "after-auto" || mode == "after-manual") {
                ObserveStartupNetwork(output, mode);
                Marker(Path.Combine(output, mode + ".json"));
            } else if (mode == "observe-first") {
                WaitFor(Path.Combine(output, "after-auto.json"));
                CheckNetwork(output, args[2], "auto");
                RunOnce("after-manual", output);
                Marker(Path.Combine(output, "before-boot-2.json"));
                Power("/r");
            } else if (mode == "observe-final") {
                WaitFor(Path.Combine(output, "after-manual.json"));
                CheckNetwork(output, args[2], "manual");
                Marker(Path.Combine(output, "final.json"));
            } else if (mode == "installed-shutdown") {
                Process.Start(new ProcessStartInfo(Installed, "shutdown " + Quote(output)) { UseShellExecute = false });
                Thread.Sleep(Timeout.Infinite);
            } else if (mode == "shutdown") {
                if (!String.Equals(Process.GetCurrentProcess().MainModule.FileName, Installed, StringComparison.OrdinalIgnoreCase)) return 95;
                Marker(Path.Combine(output, "shutdown-marker.json"));
                Power("/s");
            } else return 96;
            return 0;
        } catch { return 97; } // Never serialize the credential or exception data.
    }
}
