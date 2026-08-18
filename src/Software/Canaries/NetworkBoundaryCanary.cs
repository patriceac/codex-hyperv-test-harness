using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// This executable is deliberately a guest-side acceptance canary.  It does
// not use Hyper-V, PowerShell Direct, firewall APIs, or host paths.  The
// broker supplies the network profile; this process only observes the guest
// boundary and talks to endpoints explicitly supplied by the outer test
// orchestrator.
internal static class NetworkBoundaryCanary
{
    private const int DefaultTimeoutMilliseconds = 4000;
    private const int MaximumHoldMilliseconds = 300000;
    private const string ProtocolMagic = "CODEX-NETWORK-BOUNDARY-V1";
    private const string ProtocolAck = "CODEX-NETWORK-BOUNDARY-ACK-V1";

    private sealed class CanaryOptions
    {
        public readonly Dictionary<string, string> Values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public string Get(string name, string fallback)
        {
            string value;
            return Values.TryGetValue(name, out value) ? value : fallback;
        }

        public bool Has(string name)
        {
            return Values.ContainsKey(name);
        }

        public int GetInt(string name, int fallback)
        {
            int value;
            return Int32.TryParse(Get(name, fallback.ToString(CultureInfo.InvariantCulture)), NumberStyles.Integer, CultureInfo.InvariantCulture, out value)
                ? value
                : fallback;
        }
    }

    private sealed class BoundaryCheck
    {
        public string Name;
        public string Kind;
        public bool Required;
        public bool Observed;
        public bool Passed;
        public string Detail;

        public string ToJson()
        {
            return "{" +
                "\"name\":" + Json.String(Name) + "," +
                "\"kind\":" + Json.String(Kind) + "," +
                "\"required\":" + Json.Boolean(Required) + "," +
                "\"observed\":" + Json.Boolean(Observed) + "," +
                "\"passed\":" + Json.Boolean(Passed) + "," +
                "\"detail\":" + Json.String(Detail) + "}";
        }
    }

    private sealed class ProbeObservation
    {
        public string Name;
        public string Target;
        public bool Succeeded;
        public string Detail;

        public string ToJson()
        {
            return "{" +
                "\"name\":" + Json.String(Name) + "," +
                "\"target\":" + Json.String(Target) + "," +
                "\"succeeded\":" + Json.Boolean(Succeeded) + "," +
                "\"detail\":" + Json.String(Detail) + "}";
        }
    }

    private sealed class InterfaceObservation
    {
        public string Name;
        public string Type;
        public string Status;
        public bool IsUp;
        public bool DhcpEnabled;
        public readonly List<string> IPv4 = new List<string>();
        public readonly List<string> IPv6 = new List<string>();
        public readonly List<string> Gateways = new List<string>();
        public readonly List<string> DnsServers = new List<string>();

        public string ToJson()
        {
            return "{" +
                "\"name\":" + Json.String(Name) + "," +
                "\"type\":" + Json.String(Type) + "," +
                "\"status\":" + Json.String(Status) + "," +
                "\"isUp\":" + Json.Boolean(IsUp) + "," +
                "\"dhcpEnabled\":" + Json.Boolean(DhcpEnabled) + "," +
                "\"ipv4\":" + Json.Array(IPv4) + "," +
                "\"ipv6\":" + Json.Array(IPv6) + "," +
                "\"gateways\":" + Json.Array(Gateways) + "," +
                "\"dnsServers\":" + Json.Array(DnsServers) + "}";
        }
    }

    private sealed class NetworkSnapshot
    {
        public readonly List<InterfaceObservation> Interfaces = new List<InterfaceObservation>();
        public readonly List<string> CommandEvidence = new List<string>();
        public bool InventorySucceeded;
        public int ActiveIPv4Count;
        public int ActiveIPv6Count;
        public int GatewayCount;
        public int DefaultRouteCount;
        public string RoutePrint;
        public string ArpPrint;
        public string IpConfigPrint;

        public string ToJson()
        {
            var interfaces = new List<string>();
            foreach (InterfaceObservation item in Interfaces) interfaces.Add(item.ToJson());
            return "{" +
                "\"inventorySucceeded\":" + Json.Boolean(InventorySucceeded) + "," +
                "\"activeIPv4Count\":" + ActiveIPv4Count.ToString(CultureInfo.InvariantCulture) + "," +
                "\"activeIPv6Count\":" + ActiveIPv6Count.ToString(CultureInfo.InvariantCulture) + "," +
                "\"gatewayCount\":" + GatewayCount.ToString(CultureInfo.InvariantCulture) + "," +
                "\"defaultRouteCount\":" + DefaultRouteCount.ToString(CultureInfo.InvariantCulture) + "," +
                "\"interfaces\":" + Json.RawArray(interfaces) + "," +
                "\"routePrint\":" + Json.String(RoutePrint) + "," +
                "\"arpPrint\":" + Json.String(ArpPrint) + "," +
                "\"ipconfigPrint\":" + Json.String(IpConfigPrint) + "}";
        }
    }

    private sealed class CanaryResult
    {
        public string Profile;
        public bool Passed;
        public string Failure;
        public int ProcessId;
        public bool ListenerStarted;
        public string ListenerStartedUtc;
        public int ListenerAcceptedConnections;
        public bool ListenerClosed;
        public string ListenerStoppedUtc;
        public bool UdpListenerStarted;
        public string UdpListenerStartedUtc;
        public int UdpListenerReceivedDatagrams;
        public bool UdpListenerClosed;
        public string UdpListenerStoppedUtc;
        public string NonAdminEndpointReceipt;
        public NetworkSnapshot Snapshot;
        public readonly List<BoundaryCheck> Checks = new List<BoundaryCheck>();
        public readonly List<ProbeObservation> Probes = new List<ProbeObservation>();
        public string StartedUtc;
        public string CompletedUtc;

        public string ToJson()
        {
            var checks = new List<string>();
            foreach (BoundaryCheck check in Checks) checks.Add(check.ToJson());
            var probes = new List<string>();
            foreach (ProbeObservation probe in Probes) probes.Add(probe.ToJson());
            return "{" +
                "\"schemaVersion\":1," +
                "\"passed\":" + Json.Boolean(Passed) + "," +
                "\"profile\":" + Json.String(Profile) + "," +
                "\"processId\":" + ProcessId.ToString(CultureInfo.InvariantCulture) + "," +
                "\"startedUtc\":" + Json.String(StartedUtc) + "," +
                "\"completedUtc\":" + Json.String(CompletedUtc) + "," +
                "\"failure\":" + Json.String(Failure) + "," +
                "\"listener\":{" +
                    "\"started\":" + Json.Boolean(ListenerStarted) + "," +
                    "\"startedUtc\":" + Json.String(ListenerStartedUtc) + "," +
                    "\"acceptedConnections\":" + ListenerAcceptedConnections.ToString(CultureInfo.InvariantCulture) + "," +
                    "\"closed\":" + Json.Boolean(ListenerClosed) + "," +
                    "\"stoppedUtc\":" + Json.String(ListenerStoppedUtc) + "}," +
                "\"udpListener\":{" +
                    "\"started\":" + Json.Boolean(UdpListenerStarted) + "," +
                    "\"startedUtc\":" + Json.String(UdpListenerStartedUtc) + "," +
                    "\"receivedDatagrams\":" + UdpListenerReceivedDatagrams.ToString(CultureInfo.InvariantCulture) + "," +
                    "\"closed\":" + Json.Boolean(UdpListenerClosed) + "," +
                    "\"stoppedUtc\":" + Json.String(UdpListenerStoppedUtc) + "}," +
                "\"nonAdminEndpointReceipt\":" + Json.String(NonAdminEndpointReceipt) + "," +
                "\"checks\":" + Json.RawArray(checks) + "," +
                "\"probes\":" + Json.RawArray(probes) + "," +
                "\"network\":" + (Snapshot == null ? "null" : Snapshot.ToJson()) +
                "}";
        }
    }

    private sealed class ListenerState
    {
        public TcpListener Listener;
        public Thread Thread;
        public volatile bool Stop;
        public volatile bool Started;
        public volatile int AcceptedConnections;
        public volatile bool UnexpectedConnection;
        public string StartedUtc;
        public string StoppedUtc;
        public readonly ManualResetEvent Ready = new ManualResetEvent(false);
    }

    private sealed class UdpListenerState
    {
        public UdpClient Listener;
        public Thread Thread;
        public volatile bool Stop;
        public volatile bool Started;
        public volatile int ReceivedDatagrams;
        public string StartedUtc;
        public string StoppedUtc;
        public readonly ManualResetEvent Ready = new ManualResetEvent(false);
    }

    private sealed class CommandResult
    {
        public string Output;
        public string Error;
        public bool TimedOut;
    }

    private static int Main(string[] args)
    {
        CanaryOptions options = ParseArguments(args);
        string resultPath = options.Get("result", null);
        if (String.IsNullOrWhiteSpace(resultPath)) return 2;

        int holdMilliseconds = Math.Max(0, Math.Min(MaximumHoldMilliseconds, options.GetInt("hold-ms", 1500)));
        int stayMilliseconds = Math.Max(1000, Math.Min(MaximumHoldMilliseconds, options.GetInt("stay-ms", 3500)));
        var form = new CanaryForm(options.Get("profile", "None"), stayMilliseconds);
        form.Shown += delegate
        {
            var thread = new Thread(new ThreadStart(delegate
            {
                CanaryResult result;
                try
                {
                    result = Execute(options, holdMilliseconds);
                }
                catch (Exception exception)
                {
                    result = CreateFatalResult(options.Get("profile", "None"), exception);
                }

                try { WriteAtomic(resultPath, result.ToJson()); }
                catch (Exception writeException)
                {
                    result.Passed = false;
                    result.Failure = "Result write failed: " + writeException.GetType().FullName + ": " + writeException.Message;
                    try { WriteAtomic(resultPath, result.ToJson()); } catch { }
                }

                string evidencePath = options.Get("evidence", null);
                if (!String.IsNullOrWhiteSpace(evidencePath))
                {
                    try { WriteAtomic(evidencePath, BuildEvidenceDocument(result)); } catch { }
                }

                form.SetResult(result);
            }));
            thread.IsBackground = true;
            thread.Start();
        };
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(form);
        return form.ExitCode;
    }

    private static string BuildEvidenceDocument(CanaryResult result)
    {
        return "{" +
            "\"schemaVersion\":1," +
            "\"evidenceType\":\"NetworkBoundaryCanary\"," +
            "\"result\":" + result.ToJson() + "," +
            "\"generatedUtc\":" + Json.String(DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)) +
            "}";
    }

    private static CanaryResult CreateFatalResult(string profile, Exception exception)
    {
        var result = new CanaryResult
        {
            Profile = profile,
            Passed = false,
            ProcessId = Process.GetCurrentProcess().Id,
            StartedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
            CompletedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
            Failure = exception.GetType().FullName + ": " + exception.Message,
            ListenerClosed = false,
            UdpListenerClosed = false
        };
        result.Checks.Add(new BoundaryCheck
        {
            Name = "CanaryExecution",
            Kind = "Harness",
            Required = true,
            Observed = false,
            Passed = false,
            Detail = result.Failure
        });
        return result;
    }

    private static CanaryResult Execute(CanaryOptions options, int holdMilliseconds)
    {
        string profile = options.Get("profile", "None");
        var result = new CanaryResult
        {
            Profile = profile,
            ProcessId = Process.GetCurrentProcess().Id,
            StartedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
            ListenerClosed = true,
            UdpListenerClosed = true
        };
        ListenerState listener = null;
        UdpListenerState udpListener = null;
        try
        {
            result.Snapshot = CaptureNetworkSnapshot();
            AddCheck(result, "GuestNetworkInventory", "Harness", true, result.Snapshot.InventorySucceeded,
                result.Snapshot.InventorySucceeded ? "Guest interface, route, ARP, and ipconfig evidence was collected." :
                    "One or more guest network inventory commands failed; boundary checks fail closed.");
            listener = StartListenerIfRequested(options, result);
            udpListener = StartUdpListenerIfRequested(options, result);
            if (String.Equals(profile, "None", StringComparison.OrdinalIgnoreCase))
            {
                ExecuteNone(options, result);
            }
            else if (String.Equals(profile, "IsolatedTestNet", StringComparison.OrdinalIgnoreCase))
            {
                ExecuteIsolated(options, result, listener);
            }
            else if (String.Equals(profile, "InternetOnly", StringComparison.OrdinalIgnoreCase))
            {
                ExecuteInternet(options, result, listener, udpListener);
            }
            else if (String.Equals(profile, "TrustedLan", StringComparison.OrdinalIgnoreCase))
            {
                ExecuteTrustedLan(options, result);
            }
            else
            {
                AddCheck(result, "KnownProfile", "Harness", true, false, "Unsupported network profile: " + profile);
            }

            if (holdMilliseconds > 0)
            {
                // Keep the guest process alive for the bounded cancellation
                // scenario and, for listener-only jobs, while another cohort
                // attempts the negative.  The result is published after this
                // hold so the runner assertion remains authoritative.
                Thread.Sleep(holdMilliseconds);
            }
        }
        catch (Exception exception)
        {
            AddCheck(result, "CanaryExecution", "Harness", false, false, exception.GetType().FullName + ": " + exception.Message);
        }
        finally
        {
            if (listener != null)
            {
                result.ListenerAcceptedConnections = listener.AcceptedConnections;
                result.ListenerStarted = listener.Started;
                result.ListenerStartedUtc = listener.StartedUtc;
                StopListener(listener);
                result.ListenerStoppedUtc = listener.StoppedUtc;
                result.ListenerClosed = listener.Thread == null || !listener.Thread.IsAlive;
                AddCheck(result, "ListenerCleanup", "Cleanup", result.ListenerClosed, result.ListenerClosed, result.ListenerClosed ?
                    "The request-scoped listener stopped before result publication." :
                    "The request-scoped listener did not stop within the bounded cleanup window.");
                if (listener.UnexpectedConnection)
                {
                    AddCheckResult(result, "UnexpectedInboundConnection", "Negative", true, true, false,
                        "A connection reached a listener that was configured to reject all inbound peer traffic.");
                }
            }
            if (udpListener != null)
            {
                result.UdpListenerReceivedDatagrams = udpListener.ReceivedDatagrams;
                result.UdpListenerStarted = udpListener.Started;
                result.UdpListenerStartedUtc = udpListener.StartedUtc;
                StopUdpListener(udpListener);
                result.UdpListenerStoppedUtc = udpListener.StoppedUtc;
                result.UdpListenerClosed = udpListener.Thread == null || !udpListener.Thread.IsAlive;
                AddCheck(result, "UdpListenerCleanup", "Cleanup", result.UdpListenerClosed, result.UdpListenerClosed, result.UdpListenerClosed ?
                    "The request-scoped UDP listener stopped before result publication." :
                    "The request-scoped UDP listener did not stop within the bounded cleanup window.");
            }
            result.CompletedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            result.Passed = true;
            foreach (BoundaryCheck check in result.Checks)
            {
                if (check.Required && !check.Passed) { result.Passed = false; break; }
            }
            if (!result.Passed && String.IsNullOrWhiteSpace(result.Failure))
            {
                foreach (BoundaryCheck check in result.Checks)
                {
                    if (check.Required && !check.Passed)
                    {
                        result.Failure = check.Name + ": " + check.Detail;
                        break;
                    }
                }
            }
        }
        return result;
    }

    private static void ExecuteNone(CanaryOptions options, CanaryResult result)
    {
        AddCheck(result, "NoUsableIPv4", "Negative", true, result.Snapshot.ActiveIPv4Count == 0,
            "Active non-loopback IPv4 interfaces: " + result.Snapshot.ActiveIPv4Count.ToString(CultureInfo.InvariantCulture));
        AddCheck(result, "NoDefaultGateway", "Negative", true, result.Snapshot.GatewayCount == 0,
            "Observed gateways: " + result.Snapshot.GatewayCount.ToString(CultureInfo.InvariantCulture));
        AddCheck(result, "NoDefaultRouteTable", "Negative", true, result.Snapshot.DefaultRouteCount == 0,
            "Observed IPv4 default routes: " + result.Snapshot.DefaultRouteCount.ToString(CultureInfo.InvariantCulture));
        AddDnsCheck(options, result, "DnsNegative", false, "dns-name", "Negative");
        AddTcpCheck(options, result, "TcpNegative", false, "tcp-host", "tcp-port", "Negative");
        AddHttpsCheck(options, result, "HttpsNegative", false, "https-uri", "Negative");
        AddCheck(result, "NoActiveIPv6", "Negative", true, result.Snapshot.ActiveIPv6Count == 0,
            "Active non-loopback IPv6 addresses: " + result.Snapshot.ActiveIPv6Count.ToString(CultureInfo.InvariantCulture));
    }

    private static void ExecuteIsolated(CanaryOptions options, CanaryResult result, ListenerState listener)
    {
        string networkPrefix = options.Get("network-prefix", null);
        bool addressInNetwork = result.Snapshot.ActiveIPv4Count == 1;
        foreach (InterfaceObservation item in result.Snapshot.Interfaces)
        {
            if (!item.IsUp) continue;
            foreach (string address in item.IPv4)
            {
                if (!AddressInPrefix(address, networkPrefix)) addressInNetwork = false;
            }
        }
        AddCheck(result, "GuestAddressInIsolatedPrefix", "Boundary", true, addressInNetwork,
            "Expected guest prefix: " + (networkPrefix ?? "<missing>"));
        AddCheck(result, "NoDefaultGateway", "Negative", true, result.Snapshot.GatewayCount == 0,
            "IsolatedTestNet must not expose a default gateway.");
        AddCheck(result, "NoDefaultRouteTable", "Negative", true, result.Snapshot.DefaultRouteCount == 0,
            "IsolatedTestNet must not expose an IPv4 default route.");
        AddCheck(result, "NoIPv4DnsServer", "Negative", true, !HasDnsServer(result.Snapshot),
            "IsolatedTestNet must not retain an IPv4 DNS server.");
        AddCheck(result, "IPv6Disabled", "Negative", true, result.Snapshot.ActiveIPv6Count == 0,
            "IsolatedTestNet must not expose active IPv6.");

        if (options.Has("listener-only"))
        {
            AddCheck(result, "ListenerReady", "Positive", true, listener != null && listener.Started,
                "Different-cohort target listener is ready only for an explicit bounded negative probe.");
            return;
        }

        AddPeerCheck(options, result, listener);
        AddTcpCheck(options, result, "HostNegative", false, "host-host", "host-port", "Negative");
        AddTcpCheck(options, result, "LanNegative", false, "lan-host", "lan-port", "Negative");
        AddTcpCheck(options, result, "InternetNegative", false, "internet-host", "internet-port", "Negative");
        AddTcpCheck(options, result, "DifferentCohortNegative", false, "different-host", "different-port", "Negative");
        AddDnsCheck(options, result, "PublicDnsNegative", false, "dns-name", "Negative");
    }

    private static void ExecuteInternet(CanaryOptions options, CanaryResult result, ListenerState listener, UdpListenerState udpListener)
    {
        AddCheck(result, "InboundListenerReady", "Boundary", true, listener != null && listener.Started,
            "The live host-to-guest negative probe requires an active request-scoped guest listener.");
        AddCheck(result, "UdpInboundListenerReady", "Boundary", true, udpListener != null && udpListener.Started,
            "The live host-to-guest UDP negative probe requires an active request-scoped guest UDP listener.");
        if (options.Has("listener-only")) return;
        string gatewayAddress = options.Get("gateway-address", null);
        bool gatewayObserved = false;
        foreach (InterfaceObservation item in result.Snapshot.Interfaces)
        {
            foreach (string gateway in item.Gateways)
            {
                if (String.Equals(gateway, gatewayAddress, StringComparison.OrdinalIgnoreCase)) gatewayObserved = true;
            }
        }
        AddCheck(result, "ApprovedDefaultGateway", "Boundary", true,
            result.Snapshot.GatewayCount == 1 && gatewayObserved,
            "Expected exactly one default gateway: " + (gatewayAddress ?? "<missing>"));
        bool routeMentionsGateway = !String.IsNullOrWhiteSpace(gatewayAddress) &&
            !String.IsNullOrWhiteSpace(result.Snapshot.RoutePrint) &&
            result.Snapshot.RoutePrint.IndexOf(gatewayAddress, StringComparison.OrdinalIgnoreCase) >= 0;
        AddCheck(result, "ApprovedDefaultRouteTable", "Boundary", true,
            result.Snapshot.DefaultRouteCount == 1 && routeMentionsGateway,
            "Expected exactly one IPv4 default route through the pinned gateway.");
        AddCheck(result, "GuestAddressInNatPrefix", "Boundary", true,
            GuestAddressInPrefix(result, options.Get("nat-prefix", null)),
            "The guest must have exactly one IPv4 address inside the pinned NAT prefix.");
        AddDnsCheck(options, result, "PublicDnsPositive", true, "dns-name", "Positive");
        AddTcpCheck(options, result, "PublicTcpPositive", true, "tcp-host", "tcp-port", "Positive");
        AddHttpsCheck(options, result, "PublicHttpsPositive", true, "https-uri", "Positive");
        AddTcpCheck(options, result, "HostNegative", false, "host-host", "host-port", "Negative");
        AddTcpCheck(options, result, "PrivateNetworkNegative", false, "private-host", "private-port", "Negative");
        AddTcpCheck(options, result, "NatPrefixNegative", false, "nat-host", "nat-port", "Negative");
        AddTcpCheck(options, result, "PeerNegative", false, "peer-host", "peer-port", "Negative");
        AddTcpCheck(options, result, "IPv6Negative", false, "ipv6-host", "ipv6-port", "Negative");
        // Egress probes can populate the gateway neighbor cache.  Use a
        // post-traffic snapshot for both the ARP evidence and the final
        // network evidence rather than the pre-probe inventory.
        result.Snapshot = CaptureNetworkSnapshot();
        AddCheck(result, "GuestNetworkInventoryAfterEgress", "Harness", true, result.Snapshot.InventorySucceeded,
            result.Snapshot.InventorySucceeded ? "Guest interface, route, ARP, and ipconfig evidence was refreshed after egress probes." :
                "The post-egress guest network inventory failed; boundary checks fail closed.");
        AddGatewayArpCheck(options, result);
    }

    private static void ExecuteTrustedLan(CanaryOptions options, CanaryResult result)
    {
        bool hasIpv4 = result.Snapshot.ActiveIPv4Count > 0;
        bool hasDhcp = false;
        foreach (InterfaceObservation item in result.Snapshot.Interfaces) hasDhcp = hasDhcp || item.DhcpEnabled;
        AddCheck(result, "DhcpLease", "Positive", true, hasIpv4 && hasDhcp,
            "TrustedLan requires an active IPv4 DHCP lease.");
        AddCheck(result, "ExactAllowlistedSwitch", "Boundary", true,
            !String.IsNullOrWhiteSpace(options.Get("switch-name", null)),
            "The broker must have matched this exact switch name to its private allowlist.");
        AddDnsCheck(options, result, "LanDnsPositive", true, "dns-name", "Positive");
        AddTcpCheck(options, result, "ReachableLanPositive", true, "lan-host", "lan-port", "Positive");
        string receipt = options.Get("non-admin-endpoint-receipt", null);
        bool validReceipt = IsHexFingerprint(receipt);
        result.NonAdminEndpointReceipt = receipt;
        AddCheck(result, "NoSensitiveRouterProbe", "Safety", true, validReceipt,
            validReceipt ? "A protected trusted-endpoint inventory receipt is present; this guest canary contacted only the explicitly configured LAN endpoint. Non-router identity is accepted only from the independently matched host inventory and policy." :
                "TrustedLan requires --non-admin-endpoint-receipt with exactly 64 hexadecimal characters; the guest canary cannot self-attest non-router identity.");
    }

    private static void AddPeerCheck(CanaryOptions options, CanaryResult result, ListenerState listener)
    {
        string host = options.Get("peer-host", null);
        int port = options.GetInt("peer-port", 0);
        if (String.IsNullOrWhiteSpace(host) || port < 1 || port > 65535)
        {
            AddCheck(result, "SameCohortPeerPositive", "Positive", true, false, "An explicit same-cohort peer endpoint is required.");
            return;
        }
        ProbeObservation observation = ProbePeer(host, port, options.GetInt("timeout-ms", DefaultTimeoutMilliseconds));
        result.Probes.Add(observation);
        AddCheck(result, "SameCohortPeerPositive", "Positive", true, observation.Succeeded, observation.Detail);
        if (listener != null)
        {
            Thread.Sleep(100);
            AddCheck(result, "PeerListenerAccepted", "Positive", true, listener.AcceptedConnections > 0,
                "The peer handshake reached this VM's request-scoped listener.");
        }
    }

    private static void AddDnsCheck(CanaryOptions options, CanaryResult result, string name, bool expectedSuccess, string optionName, string kind)
    {
        string host = options.Get(optionName, null);
        if (String.IsNullOrWhiteSpace(host))
        {
            AddCheck(result, name, kind, true, false, "An explicit DNS endpoint is required.");
            return;
        }
        bool resolved = false;
        string detail;
        IPAddress[] addresses = null;
        Exception resolutionError = null;
        int timeoutMilliseconds = Math.Max(250, options.GetInt("timeout-ms", DefaultTimeoutMilliseconds));
        var resolverThread = new Thread(new ThreadStart(delegate
        {
            try { addresses = Dns.GetHostAddresses(host); }
            catch (Exception exception) { resolutionError = exception; }
        }));
        resolverThread.IsBackground = true;
        resolverThread.Start();
        bool completed = resolverThread.Join(timeoutMilliseconds);
        if (!completed)
        {
            detail = "TimeoutException: DNS resolution timed out after " + timeoutMilliseconds.ToString(CultureInfo.InvariantCulture) + " ms.";
        }
        else if (resolutionError != null)
        {
            detail = resolutionError.GetType().Name + ": " + resolutionError.Message;
        }
        else
        {
            resolved = addresses != null && addresses.Length > 0;
            detail = "Resolved " + (addresses == null ? 0 : addresses.Length).ToString(CultureInfo.InvariantCulture) + " address(es).";
        }
        AddCheck(result, name, kind, true, expectedSuccess ? resolved : !resolved,
            (expectedSuccess ? "Expected DNS resolution. " : "Expected DNS failure. ") + detail);
    }

    private static void AddTcpCheck(CanaryOptions options, CanaryResult result, string name, bool expectedSuccess, string hostOption, string portOption, string kind)
    {
        string host = options.Get(hostOption, null);
        int port = options.GetInt(portOption, 0);
        if (String.IsNullOrWhiteSpace(host) || port < 1 || port > 65535)
        {
            AddCheck(result, name, kind, true, false, "An explicit TCP endpoint is required.");
            return;
        }
        ProbeObservation observation = ProbeTcp(host, port, options.GetInt("timeout-ms", DefaultTimeoutMilliseconds));
        result.Probes.Add(observation);
        AddCheck(result, name, kind, true, expectedSuccess ? observation.Succeeded : !observation.Succeeded,
            (expectedSuccess ? "Expected TCP connection. " : "Expected TCP failure. ") + observation.Detail);
    }

    private static void AddHttpsCheck(CanaryOptions options, CanaryResult result, string name, bool expectedSuccess, string uriOption, string kind)
    {
        string uri = options.Get(uriOption, null);
        if (String.IsNullOrWhiteSpace(uri))
        {
            AddCheck(result, name, kind, true, false, "An explicit HTTPS URI is required.");
            return;
        }
        ProbeObservation observation = ProbeHttps(uri, options.GetInt("timeout-ms", DefaultTimeoutMilliseconds));
        result.Probes.Add(observation);
        AddCheck(result, name, kind, true, expectedSuccess ? observation.Succeeded : !observation.Succeeded,
            (expectedSuccess ? "Expected HTTPS response. " : "Expected HTTPS failure. ") + observation.Detail);
    }

    private static void AddGatewayArpCheck(CanaryOptions options, CanaryResult result)
    {
        string gateway = options.Get("gateway-address", null);
        string mac = NormalizeMac(options.Get("gateway-mac", null));
        bool addressFound = !String.IsNullOrWhiteSpace(gateway) &&
            !String.IsNullOrWhiteSpace(result.Snapshot.ArpPrint) &&
            result.Snapshot.ArpPrint.IndexOf(gateway, StringComparison.OrdinalIgnoreCase) >= 0;
        bool macFound = String.IsNullOrWhiteSpace(mac) || NormalizeMac(result.Snapshot.ArpPrint).IndexOf(mac, StringComparison.OrdinalIgnoreCase) >= 0;
        AddCheck(result, "GatewayArpEvidence", "Boundary", true, addressFound && macFound,
            "Expected gateway " + (gateway ?? "<missing>") + " with pinned MAC " + (mac ?? "<not supplied>") + ".");
    }

    private static bool IsHexFingerprint(string value)
    {
        if (String.IsNullOrWhiteSpace(value) || value.Length != 64) return false;
        for (int index = 0; index < value.Length; index++)
        {
            char character = value[index];
            if (!((character >= '0' && character <= '9') ||
                  (character >= 'a' && character <= 'f') ||
                  (character >= 'A' && character <= 'F'))) return false;
        }
        return true;
    }

    private static bool HasDnsServer(NetworkSnapshot snapshot)
    {
        foreach (InterfaceObservation item in snapshot.Interfaces)
        {
            if (item.IsUp && item.DnsServers.Count > 0) return true;
        }
        return false;
    }

    private static bool GuestAddressInPrefix(CanaryResult result, string prefix)
    {
        if (String.IsNullOrWhiteSpace(prefix)) return false;
        if (result.Snapshot.ActiveIPv4Count != 1) return false;
        bool found = false;
        foreach (InterfaceObservation item in result.Snapshot.Interfaces)
        {
            if (!item.IsUp) continue;
            foreach (string address in item.IPv4)
            {
                if (!AddressInPrefix(address, prefix)) return false;
                found = true;
            }
        }
        return found;
    }

    private static bool AddressInPrefix(string address, string prefix)
    {
        if (String.IsNullOrWhiteSpace(address) || String.IsNullOrWhiteSpace(prefix)) return false;
        string[] pieces = prefix.Split('/');
        IPAddress candidate;
        IPAddress network;
        int length;
        if (pieces.Length != 2 || !IPAddress.TryParse(address, out candidate) || !IPAddress.TryParse(pieces[0], out network) ||
            !Int32.TryParse(pieces[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out length) ||
            candidate.AddressFamily != AddressFamily.InterNetwork || network.AddressFamily != AddressFamily.InterNetwork || length < 0 || length > 32) return false;
        byte[] candidateBytes = candidate.GetAddressBytes();
        byte[] networkBytes = network.GetAddressBytes();
        int fullBytes = length / 8;
        int remainingBits = length % 8;
        for (int index = 0; index < fullBytes; index++) if (candidateBytes[index] != networkBytes[index]) return false;
        if (remainingBits == 0) return true;
        int mask = 0xff << (8 - remainingBits);
        return (candidateBytes[fullBytes] & mask) == (networkBytes[fullBytes] & mask);
    }

    private static NetworkSnapshot CaptureNetworkSnapshot()
    {
        var snapshot = new NetworkSnapshot();
        foreach (NetworkInterface networkInterface in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (networkInterface.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            var item = new InterfaceObservation
            {
                Name = networkInterface.Name,
                Type = networkInterface.NetworkInterfaceType.ToString(),
                Status = networkInterface.OperationalStatus.ToString(),
                IsUp = networkInterface.OperationalStatus == OperationalStatus.Up,
                DhcpEnabled = false
            };
            try
            {
                IPInterfaceProperties properties = networkInterface.GetIPProperties();
                foreach (UnicastIPAddressInformation address in properties.UnicastAddresses)
                {
                    if (address.Address.AddressFamily == AddressFamily.InterNetwork)
                    {
                        item.IPv4.Add(address.Address.ToString());
                        if (item.IsUp && !address.Address.ToString().StartsWith("169.254.", StringComparison.Ordinal)) snapshot.ActiveIPv4Count++;
                    }
                    else if (address.Address.AddressFamily == AddressFamily.InterNetworkV6 && !IPAddress.IsLoopback(address.Address))
                    {
                        item.IPv6.Add(address.Address.ToString());
                        if (item.IsUp) snapshot.ActiveIPv6Count++;
                    }
                }
                foreach (GatewayIPAddressInformation gateway in properties.GatewayAddresses)
                {
                    if (gateway.Address.AddressFamily == AddressFamily.InterNetwork) item.Gateways.Add(gateway.Address.ToString());
                }
                foreach (IPAddress dnsServer in properties.DnsAddresses)
                {
                    if (dnsServer.AddressFamily == AddressFamily.InterNetwork) item.DnsServers.Add(dnsServer.ToString());
                }
                try { item.DhcpEnabled = properties.GetIPv4Properties().IsDhcpEnabled; } catch { }
            }
            catch (Exception exception)
            {
                item.Status = item.Status + ": " + exception.GetType().Name;
            }
            snapshot.GatewayCount += item.Gateways.Count;
            snapshot.Interfaces.Add(item);
        }
        CommandResult route = RunCommand("route.exe", "print -4", 4000);
        CommandResult arp = RunCommand("arp.exe", "-a", 4000);
        CommandResult ipconfig = RunCommand("ipconfig.exe", "/all", 4000);
        snapshot.RoutePrint = route.Output;
        snapshot.ArpPrint = arp.Output;
        snapshot.IpConfigPrint = ipconfig.Output;
        snapshot.InventorySucceeded = !route.TimedOut && !arp.TimedOut && !ipconfig.TimedOut &&
            String.IsNullOrWhiteSpace(route.Error) && String.IsNullOrWhiteSpace(arp.Error) && String.IsNullOrWhiteSpace(ipconfig.Error);
        if (!String.IsNullOrWhiteSpace(snapshot.RoutePrint))
        {
            string[] routeLines = snapshot.RoutePrint.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string line in routeLines)
            {
                string trimmed = line.TrimStart();
                if (trimmed.StartsWith("0.0.0.0", StringComparison.Ordinal) &&
                    (trimmed.Length == 7 || Char.IsWhiteSpace(trimmed[7]))) snapshot.DefaultRouteCount++;
            }
        }
        return snapshot;
    }

    private static ListenerState StartListenerIfRequested(CanaryOptions options, CanaryResult result)
    {
        if (!options.Has("listen-port") && !options.Has("listener-only")) return null;
        int port = options.GetInt("listen-port", 0);
        if (port < 1 || port > 65535)
        {
            AddCheck(result, "ListenerReady", "Positive", true, false, "listen-port must be between 1 and 65535.");
            return null;
        }
        var state = new ListenerState();
        state.Listener = new TcpListener(IPAddress.Any, port);
        state.Listener.Start();
        state.StartedUtc = UtcNowText();
        state.Started = true;
        result.ListenerStarted = true;
        result.ListenerStartedUtc = state.StartedUtc;
        state.Thread = new Thread(new ThreadStart(delegate
        {
            state.Ready.Set();
            while (!state.Stop)
            {
                try
                {
                    if (!state.Listener.Pending()) { Thread.Sleep(50); continue; }
                    using (TcpClient client = state.Listener.AcceptTcpClient())
                    using (NetworkStream stream = client.GetStream())
                    {
                        byte[] buffer = new byte[ProtocolMagic.Length + 8];
                        stream.ReadTimeout = 1500;
                        int count = 0;
                        try { count = stream.Read(buffer, 0, buffer.Length); } catch { }
                        string received = Encoding.ASCII.GetString(buffer, 0, count);
                        if (received.StartsWith(ProtocolMagic, StringComparison.Ordinal))
                        {
                            byte[] ack = Encoding.ASCII.GetBytes(ProtocolAck);
                            stream.Write(ack, 0, ack.Length);
                            state.AcceptedConnections++;
                            if (options.Has("forbid-connections")) state.UnexpectedConnection = true;
                        }
                        else if (options.Has("forbid-connections")) state.UnexpectedConnection = true;
                    }
                }
                catch (SocketException) { if (!state.Stop) Thread.Sleep(50); }
                catch (ObjectDisposedException) { break; }
                catch { if (!state.Stop) Thread.Sleep(50); }
            }
        }));
        state.Thread.IsBackground = true;
        state.Thread.Start();
        state.Ready.WaitOne(1000);
        return state;
    }

    private static void StopListener(ListenerState state)
    {
        state.Stop = true;
        try { state.Listener.Stop(); } catch { }
        state.StoppedUtc = UtcNowText();
        if (state.Thread != null && state.Thread.IsAlive) state.Thread.Join(2000);
        state.Ready.Close();
    }

    private static UdpListenerState StartUdpListenerIfRequested(CanaryOptions options, CanaryResult result)
    {
        if (!options.Has("udp-listen-port")) return null;
        int port = options.GetInt("udp-listen-port", 0);
        if (port < 1 || port > 65535)
        {
            AddCheck(result, "UdpListenerReady", "Positive", true, false, "udp-listen-port must be between 1 and 65535.");
            return null;
        }
        var state = new UdpListenerState();
        state.Listener = new UdpClient(new IPEndPoint(IPAddress.Any, port));
        state.Listener.Client.ReceiveTimeout = 250;
        state.StartedUtc = UtcNowText();
        state.Started = true;
        state.Thread = new Thread(new ThreadStart(delegate
        {
            state.Ready.Set();
            while (!state.Stop)
            {
                try
                {
                    IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                    byte[] payload = state.Listener.Receive(ref remote);
                    if (payload != null) state.ReceivedDatagrams++;
                }
                catch (SocketException) { if (!state.Stop) continue; }
                catch (ObjectDisposedException) { break; }
                catch { if (!state.Stop) Thread.Sleep(50); }
            }
        }));
        state.Thread.IsBackground = true;
        state.Thread.Start();
        state.Ready.WaitOne(1000);
        return state;
    }

    private static void StopUdpListener(UdpListenerState state)
    {
        state.Stop = true;
        try { state.Listener.Close(); } catch { }
        state.StoppedUtc = UtcNowText();
        if (state.Thread != null && state.Thread.IsAlive) state.Thread.Join(2000);
        state.Ready.Close();
    }

    private static string UtcNowText()
    {
        return DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
    }

    private static ProbeObservation ProbePeer(string host, int port, int timeoutMilliseconds)
    {
        var observation = new ProbeObservation { Name = "peer-handshake", Target = host + ":" + port.ToString(CultureInfo.InvariantCulture) };
        Exception lastException = null;
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(Math.Max(250, timeoutMilliseconds));
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using (TcpClient client = new TcpClient())
                {
                    IAsyncResult pending = client.BeginConnect(host, port, null, null);
                    int waitMilliseconds = (int)Math.Max(1, Math.Min(1000, (deadline - DateTime.UtcNow).TotalMilliseconds));
                    if (!pending.AsyncWaitHandle.WaitOne(waitMilliseconds)) throw new TimeoutException("peer connect timed out");
                    client.EndConnect(pending);
                    using (NetworkStream stream = client.GetStream())
                    {
                        stream.ReadTimeout = 1500;
                        stream.WriteTimeout = 1500;
                        byte[] magic = Encoding.ASCII.GetBytes(ProtocolMagic);
                        stream.Write(magic, 0, magic.Length);
                        byte[] ack = new byte[ProtocolAck.Length + 8];
                        int count = stream.Read(ack, 0, ack.Length);
                        string text = Encoding.ASCII.GetString(ack, 0, count);
                        if (!text.StartsWith(ProtocolAck, StringComparison.Ordinal)) throw new IOException("peer did not return the canary acknowledgement");
                    }
                }
                observation.Succeeded = true;
                observation.Detail = "The explicit peer completed the canary handshake.";
                return observation;
            }
            catch (Exception exception) { lastException = exception; Thread.Sleep(100); }
        }
        observation.Succeeded = false;
        observation.Detail = lastException == null ? "peer connection failed" : lastException.GetType().Name + ": " + lastException.Message;
        return observation;
    }

    private static ProbeObservation ProbeTcp(string host, int port, int timeoutMilliseconds)
    {
        var observation = new ProbeObservation { Name = "tcp", Target = host + ":" + port.ToString(CultureInfo.InvariantCulture) };
        try
        {
            using (TcpClient client = new TcpClient())
            {
                IAsyncResult pending = client.BeginConnect(host, port, null, null);
                if (!pending.AsyncWaitHandle.WaitOne(Math.Max(250, timeoutMilliseconds))) throw new TimeoutException("TCP connect timed out");
                client.EndConnect(pending);
            }
            observation.Succeeded = true;
            observation.Detail = "TCP connection completed.";
        }
        catch (Exception exception)
        {
            observation.Succeeded = false;
            observation.Detail = exception.GetType().Name + ": " + exception.Message;
        }
        return observation;
    }

    private static ProbeObservation ProbeHttps(string uri, int timeoutMilliseconds)
    {
        var observation = new ProbeObservation { Name = "https", Target = uri };
        try
        {
            Uri parsed = new Uri(uri, UriKind.Absolute);
            if (!String.Equals(parsed.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("HTTPS probe requires an https:// URI");
            var request = (HttpWebRequest)WebRequest.Create(parsed);
            request.Method = "GET";
            request.Timeout = Math.Max(250, timeoutMilliseconds);
            request.ReadWriteTimeout = Math.Max(250, timeoutMilliseconds);
            request.AllowAutoRedirect = false;
            request.UserAgent = "Codex-NetworkBoundaryCanary/1";
            using (WebResponse response = request.GetResponse())
            using (Stream stream = response.GetResponseStream())
            {
                if (stream != null) stream.ReadByte();
                HttpWebResponse http = response as HttpWebResponse;
                int code = http == null ? 200 : (int)http.StatusCode;
                observation.Succeeded = code >= 200 && code < 400;
                observation.Detail = "HTTPS status " + code.ToString(CultureInfo.InvariantCulture) + ".";
            }
        }
        catch (Exception exception)
        {
            observation.Succeeded = false;
            observation.Detail = exception.GetType().Name + ": " + exception.Message;
        }
        return observation;
    }

    private static CommandResult RunCommand(string fileName, string arguments, int timeoutMilliseconds)
    {
        var result = new CommandResult { Output = String.Empty, Error = String.Empty, TimedOut = false };
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (Process process = Process.Start(startInfo))
            {
                if (process == null) { result.Error = "process did not start"; return result; }
                result.Output = process.StandardOutput.ReadToEnd();
                result.Error = process.StandardError.ReadToEnd();
                if (!process.WaitForExit(Math.Max(250, timeoutMilliseconds)))
                {
                    result.TimedOut = true;
                    try { process.Kill(); } catch { }
                }
            }
        }
        catch (Exception exception) { result.Error = exception.GetType().Name + ": " + exception.Message; }
        if (result.Output.Length > 12000) result.Output = result.Output.Substring(0, 12000);
        if (result.Error.Length > 4000) result.Error = result.Error.Substring(0, 4000);
        return result;
    }

    private static string NormalizeMac(string value)
    {
        if (String.IsNullOrWhiteSpace(value)) return String.Empty;
        return value.Replace(":", String.Empty).Replace("-", String.Empty).Replace(".", String.Empty).ToUpperInvariant();
    }

    private static void AddCheck(CanaryResult result, string name, string kind, bool required, bool observed, string detail)
    {
        AddCheckResult(result, name, kind, required, observed, observed, detail);
    }

    private static void AddCheckResult(CanaryResult result, string name, string kind, bool required, bool observed, bool passed, string detail)
    {
        result.Checks.Add(new BoundaryCheck
        {
            Name = name,
            Kind = kind,
            Required = required,
            Observed = observed,
            Passed = passed,
            Detail = detail
        });
    }

    private static CanaryOptions ParseArguments(string[] args)
    {
        var options = new CanaryOptions();
        for (int index = 0; index < args.Length; index++)
        {
            string argument = args[index];
            if (String.IsNullOrWhiteSpace(argument) || !argument.StartsWith("--", StringComparison.Ordinal)) continue;
            string key = argument.Substring(2);
            string value = "true";
            int equals = key.IndexOf('=');
            if (equals >= 0)
            {
                value = key.Substring(equals + 1);
                key = key.Substring(0, equals);
            }
            else if (index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal)) value = args[++index];
            options.Values[key] = value;
        }
        return options;
    }

    private static void WriteAtomic(string path, string content)
    {
        string directory = Path.GetDirectoryName(path);
        if (!String.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
        string temporaryPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temporaryPath, content, new UTF8Encoding(false));
        if (File.Exists(path)) File.Delete(path);
        File.Move(temporaryPath, path);
    }

    private static class Json
    {
        public static string Boolean(bool value) { return value ? "true" : "false"; }

        public static string String(string value)
        {
            if (value == null) return "null";
            var builder = new StringBuilder();
            builder.Append('"');
            foreach (char character in value)
            {
                switch (character)
                {
                    case '\\': builder.Append("\\\\"); break;
                    case '"': builder.Append("\\\""); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\t': builder.Append("\\t"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    default:
                        if (character < 32) builder.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                        else builder.Append(character);
                        break;
                }
            }
            builder.Append('"');
            return builder.ToString();
        }

        public static string Array(IEnumerable<string> values)
        {
            var raw = new List<string>();
            foreach (string value in values) raw.Add(String(value));
            return RawArray(raw);
        }

        public static string RawArray(IEnumerable<string> values)
        {
            var builder = new StringBuilder();
            builder.Append('[');
            bool first = true;
            foreach (string value in values)
            {
                if (!first) builder.Append(',');
                first = false;
                builder.Append(value ?? "null");
            }
            builder.Append(']');
            return builder.ToString();
        }
    }

    private sealed class CanaryForm : Form
    {
        private readonly Label _status;
        private readonly TextBox _details;
        private readonly int _stayMilliseconds;
        public int ExitCode { get; private set; }

        public CanaryForm(string profile, int stayMilliseconds)
        {
            _stayMilliseconds = stayMilliseconds;
            Text = "Codex Network Boundary Canary — " + profile;
            ClientSize = new Size(900, 520);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(15, 23, 42);
            ForeColor = Color.White;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;

            var title = new Label
            {
                Dock = DockStyle.Top,
                Height = 78,
                Text = "NETWORK BOUNDARY CANARY\r\n" + profile.ToUpperInvariant(),
                TextAlign = ContentAlignment.MiddleCenter,
                ForeColor = Color.FromArgb(125, 211, 252),
                Font = new Font("Segoe UI Semibold", 20F, FontStyle.Bold)
            };
            _status = new Label
            {
                Dock = DockStyle.Top,
                Height = 46,
                Text = "Collecting guest-side boundary evidence…",
                TextAlign = ContentAlignment.MiddleCenter,
                ForeColor = Color.White,
                Font = new Font("Segoe UI", 12F)
            };
            _details = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                Dock = DockStyle.Fill,
                BackColor = Color.FromArgb(30, 41, 59),
                ForeColor = Color.FromArgb(226, 232, 240),
                Font = new Font("Consolas", 10F)
            };
            Controls.Add(_details);
            Controls.Add(_status);
            Controls.Add(title);
        }

        public void SetResult(CanaryResult result)
        {
            if (IsDisposed) return;
            BeginInvoke((MethodInvoker)delegate
            {
                ExitCode = result.Passed ? 0 : 1;
                _status.Text = result.Passed ? "BOUNDARY RESULT: PASSED" : "BOUNDARY RESULT: FAILED";
                _status.ForeColor = result.Passed ? Color.FromArgb(110, 231, 183) : Color.FromArgb(252, 165, 165);
                var lines = new List<string>();
                foreach (BoundaryCheck check in result.Checks)
                {
                    lines.Add((check.Passed ? "PASS " : "FAIL ") + check.Name + " — " + check.Detail);
                }
                _details.Text = String.Join(Environment.NewLine, lines.ToArray());
                var timer = new System.Windows.Forms.Timer { Interval = _stayMilliseconds };
                timer.Tick += delegate { timer.Stop(); timer.Dispose(); Close(); };
                timer.Start();
            });
        }
    }
}
