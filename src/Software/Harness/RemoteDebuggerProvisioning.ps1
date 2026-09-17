$script:RemoteDebuggerProvisionEvidenceFileName = 'remote-debugger-provisioning.json'

function Test-RemoteDebuggerProvisionFixedHex {
    param([AllowNull()] [object] $Value)

    Set-StrictMode -Version Latest

    $Value -is [string] -and ([string]$Value) -cmatch '\A[A-Fa-f0-9]{64}\z'
}

function Get-RemoteDebuggerProvisionObjectPropertyNames {
    param([AllowNull()] [object] $Value)

    Set-StrictMode -Version Latest

    if ($null -eq $Value) { return @() }
    @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Assert-RemoteDebuggerProvisionExactProperties {
    param(
        [Parameter(Mandatory = $true)] [object] $Value,
        [Parameter(Mandatory = $true)] [string[]] $Expected,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    Set-StrictMode -Version Latest

    if ($Value -is [string] -or $Value -is [array] -or $Value -is [ValueType]) {
        throw "$Context must be a JSON object."
    }
    $actual = @(Get-RemoteDebuggerProvisionObjectPropertyNames -Value $Value)
    $unexpected = @($actual | Where-Object { $_ -cnotin $Expected })
    $missing = @($Expected | Where-Object { $_ -cnotin $actual })
    if ($unexpected.Count -gt 0 -or $missing.Count -gt 0) {
        $details = New-Object Collections.Generic.List[string]
        if ($missing.Count -gt 0) { $details.Add('missing: ' + ($missing -join ', ')) }
        if ($unexpected.Count -gt 0) { $details.Add('unexpected: ' + ($unexpected -join ', ')) }
        throw "$Context has an invalid property set ($($details -join '; '))."
    }
}

function Resolve-RemoteDebuggerProvisionRequestV1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object] $RequestProfile,
        [Parameter(Mandatory = $true)] [object] $ConfigProfile,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')]
        [string] $RequestId
    )

    Set-StrictMode -Version Latest

    Assert-RemoteDebuggerProvisionExactProperties -Value $RequestProfile `
        -Expected @('FixtureRelativePath', 'ExpectedSha256') -Context 'RemoteDebuggerProvisionV1 request profile'
    Assert-RemoteDebuggerProvisionExactProperties -Value $ConfigProfile `
        -Expected @('FormatVersion', 'Enabled', 'PublisherThumbprint', 'ApprovedExecutableSha256') -Context 'RemoteDebuggerProvisionV1 broker policy'

    if ($ConfigProfile.FormatVersion -is [bool] -or
        ($ConfigProfile.FormatVersion -isnot [int16] -and $ConfigProfile.FormatVersion -isnot [int32] -and $ConfigProfile.FormatVersion -isnot [int64]) -or
        [int64]$ConfigProfile.FormatVersion -ne 1) {
        throw 'RemoteDebuggerProvisionV1 broker policy requires exact integer FormatVersion 1.'
    }
    if ($ConfigProfile.Enabled -isnot [bool] -or -not [bool]$ConfigProfile.Enabled) {
        throw 'RemoteDebuggerProvisionV1 is not enabled by this protected broker configuration.'
    }
    if (-not (Test-RemoteDebuggerProvisionFixedHex -Value $ConfigProfile.PublisherThumbprint)) {
        throw 'RemoteDebuggerProvisionV1 broker policy has an invalid publisher SHA-256 thumbprint.'
    }
    if (-not (Test-RemoteDebuggerProvisionFixedHex -Value $RequestProfile.ExpectedSha256)) {
        throw 'RemoteDebuggerProvisionV1 request has an invalid executable SHA-256.'
    }

    $approvedValues = @($ConfigProfile.ApprovedExecutableSha256)
    if ($ConfigProfile.ApprovedExecutableSha256 -is [string] -or $approvedValues.Count -lt 1 -or $approvedValues.Count -gt 32) {
        throw 'RemoteDebuggerProvisionV1 broker policy must contain between one and 32 approved executable SHA-256 values.'
    }
    $approved = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $approvedValues) {
        if (-not (Test-RemoteDebuggerProvisionFixedHex -Value $value)) {
            throw 'RemoteDebuggerProvisionV1 broker policy contains an invalid approved executable SHA-256.'
        }
        if (-not $approved.Add(([string]$value).ToUpperInvariant())) {
            throw 'RemoteDebuggerProvisionV1 broker policy contains a duplicate approved executable SHA-256.'
        }
    }
    $expectedSha256 = ([string]$RequestProfile.ExpectedSha256).ToUpperInvariant()
    if (-not $approved.Contains($expectedSha256)) {
        throw 'RemoteDebuggerProvisionV1 request executable SHA-256 is not present in the protected allowlist.'
    }

    if ($RequestProfile.FixtureRelativePath -isnot [string]) {
        throw 'RemoteDebuggerProvisionV1 FixtureRelativePath must be a string.'
    }
    $rawRelativePath = [string]$RequestProfile.FixtureRelativePath
    if (-not [string]::Equals($rawRelativePath, $rawRelativePath.Trim(), [StringComparison]::Ordinal)) {
        throw 'RemoteDebuggerProvisionV1 FixtureRelativePath may not have leading or trailing whitespace.'
    }
    $relativePath = $rawRelativePath.Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath.Length -gt 240 -or
        [IO.Path]::IsPathRooted($relativePath) -or $relativePath.IndexOf(':') -ge 0 -or
        $relativePath.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
        throw 'RemoteDebuggerProvisionV1 FixtureRelativePath must be a relative Windows path of at most 240 characters without a drive or alternate-data-stream separator.'
    }
    $segments = @($relativePath.Split([char]'\'))
    $invalidFileNameCharacters = [IO.Path]::GetInvalidFileNameChars()
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -in @('.', '..') -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal) -or $segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment.IndexOfAny($invalidFileNameCharacters) -ge 0) {
            throw 'RemoteDebuggerProvisionV1 FixtureRelativePath contains an empty, traversal, trailing-dot/space, or invalid Windows path segment.'
        }
    }
    if (-not [string]::Equals([IO.Path]::GetFileName($relativePath), 'RemoteDebugger.exe', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RemoteDebuggerProvisionV1 fixture leaf must be RemoteDebugger.exe.'
    }

    [pscustomobject][ordered]@{
        FormatVersion = 1
        Profile = 'RemoteDebuggerProvisionV1'
        RequestId = $RequestId
        FixtureRelativePath = $relativePath
        ExpectedSha256 = $expectedSha256
        PublisherThumbprint = ([string]$ConfigProfile.PublisherThumbprint).ToUpperInvariant()
        EvidenceFileName = $script:RemoteDebuggerProvisionEvidenceFileName
    }
}

function Resolve-RemoteDebuggerProvisionV1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object] $RequestProfile,
        [Parameter(Mandatory = $true)] [object] $ConfigProfile,
        [Parameter(Mandatory = $true)] [string] $GuestPayloadRoot,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')]
        [string] $RequestId
    )

    Set-StrictMode -Version Latest

    $request = Resolve-RemoteDebuggerProvisionRequestV1 -RequestProfile $RequestProfile -ConfigProfile $ConfigProfile -RequestId $RequestId
    $payloadRoot = [IO.Path]::GetFullPath($GuestPayloadRoot).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($payloadRoot) -or [IO.Path]::GetPathRoot($payloadRoot) -eq $payloadRoot) {
        throw 'RemoteDebuggerProvisionV1 guest payload root must be a specific absolute directory.'
    }
    $payloadPrefix = $payloadRoot + '\'
    $fixturePath = [IO.Path]::GetFullPath([IO.Path]::Combine($payloadRoot, [string]$request.FixtureRelativePath))
    if (-not $fixturePath.StartsWith($payloadPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RemoteDebuggerProvisionV1 FixtureRelativePath escapes the mounted payload root.'
    }

    [pscustomobject][ordered]@{
        FormatVersion = 1
        Profile = 'RemoteDebuggerProvisionV1'
        RequestId = [string]$request.RequestId
        FixtureRelativePath = [string]$request.FixtureRelativePath
        GuestFixturePath = $fixturePath
        ExpectedSha256 = [string]$request.ExpectedSha256
        PublisherThumbprint = [string]$request.PublisherThumbprint
        EvidenceFileName = [string]$request.EvidenceFileName
    }
}

function Invoke-RemoteDebuggerProvisionV1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object] $Session,
        [Parameter(Mandatory = $true)] [object] $RequestProfile,
        [Parameter(Mandatory = $true)] [object] $ConfigProfile,
        [Parameter(Mandatory = $true)] [string] $GuestPayloadRoot,
        [Parameter(Mandatory = $true)] [string] $GuestOutputRoot,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')]
        [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [scriptblock] $ActivityCheck
    )

    Set-StrictMode -Version Latest

    $definition = Resolve-RemoteDebuggerProvisionV1 -RequestProfile $RequestProfile -ConfigProfile $ConfigProfile `
        -GuestPayloadRoot $GuestPayloadRoot -RequestId $RequestId
    $outputRoot = [IO.Path]::GetFullPath($GuestOutputRoot).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($outputRoot) -or [IO.Path]::GetPathRoot($outputRoot) -eq $outputRoot) {
        throw 'RemoteDebuggerProvisionV1 guest output root must be a specific absolute directory.'
    }
    $remainingSeconds = [int][Math]::Floor(($ExecutionDeadlineUtc.ToUniversalTime() - [DateTime]::UtcNow).TotalSeconds)
    if ($remainingSeconds -lt 10) { throw 'RemoteDebuggerProvisionV1 has insufficient request time remaining.' }
    $guestTimeoutSeconds = [Math]::Min(180, $remainingSeconds)

    $guestOperation = {
        param(
            [string] $GuestFixturePath,
            [string] $ExpectedSha256,
            [string] $PublisherThumbprint,
            [string] $GuestOutputRoot,
            [string] $EvidenceFileName,
            [string] $RequestId,
            [int] $TimeoutSeconds,
            [string] $GuestPayloadRoot
        )

        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest

        if (-not ('CodexRemoteDebuggerAuthenticode' -as [type])) {
            Add-Type -ReferencedAssemblies @('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Security.dll') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;

public static class CodexRemoteDebuggerAuthenticode
{
    private const int Success = 0;
    private const int CertEUntrustedRoot = unchecked((int)0x800B0109);
    private const string CodeSigningOid = "1.3.6.1.5.5.7.3.3";
    private const string Sha256Oid = "2.16.840.1.101.3.4.2.1";
    private static readonly Guid GenericVerifyV2 = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");

    public static string Verify(string path, string expectedThumbprint)
    {
        byte[] image = File.ReadAllBytes(Path.GetFullPath(path));
        if (image.Length < 256 || image.Length > 536870912)
            throw new InvalidDataException("Executable size is outside Authenticode validation bounds.");
        PeLayout layout = ReadPeLayout(image);
        byte[] signature = ReadPkcs7Certificate(image, layout.CertificateOffset, layout.CertificateSize);
        SignedCms cms = new SignedCms();
        try
        {
            cms.Decode(signature);
            cms.CheckSignature(true);
        }
        catch (CryptographicException ex)
        {
            throw new InvalidDataException("The embedded Authenticode CMS signature is invalid.", ex);
        }
        if (cms.SignerInfos.Count < 1 || cms.SignerInfos[0].Certificate == null)
            throw new InvalidDataException("Authenticode signature has no signer certificate.");
        X509Certificate2 certificate = cms.SignerInfos[0].Certificate;
        ValidateCodeSigningCertificate(certificate);
        DigestInfo signed = ReadIndirectDataDigest(cms.ContentInfo.Content);
        if (!String.Equals(signed.Algorithm, Sha256Oid, StringComparison.Ordinal))
            throw new InvalidDataException("Only SHA-256 Authenticode signatures are accepted.");
        byte[] actualDigest = ComputeAuthenticodeDigest(image, layout);
        if (!FixedEquals(signed.Digest, actualDigest))
            throw new InvalidDataException("Authenticode PE image digest does not match the signed digest.");
        string thumbprint;
        using (SHA256 sha = SHA256.Create()) { thumbprint = ToHex(sha.ComputeHash(certificate.RawData)); }
        if (!String.Equals(thumbprint, expectedThumbprint, StringComparison.OrdinalIgnoreCase))
            throw new UnauthorizedAccessException("Executable publisher does not match the protected publisher certificate pin.");
        int trust = VerifyTrust(path);
        if (trust != Success && trust != CertEUntrustedRoot)
            throw new UnauthorizedAccessException(String.Format("Authenticode trust failed (0x{0:X8}).", trust));
        return thumbprint;
    }

    private static PeLayout ReadPeLayout(byte[] image)
    {
        if (ReadUInt16(image, 0) != 0x5A4D) throw new InvalidDataException("Executable has no DOS header.");
        int peOffset = ReadInt32(image, 0x3C);
        if (peOffset < 0x40 || peOffset > image.Length - 256 || ReadUInt32(image, peOffset) != 0x00004550)
            throw new InvalidDataException("Executable has no valid PE header.");
        int optional = checked(peOffset + 24);
        int optionalSize = ReadUInt16(image, peOffset + 20);
        if (optional + optionalSize > image.Length) throw new InvalidDataException("PE optional header exceeds the executable.");
        int magic = ReadUInt16(image, optional);
        int directories;
        if (magic == 0x10B) directories = optional + 96;
        else if (magic == 0x20B) directories = optional + 112;
        else throw new InvalidDataException("Unsupported PE optional-header format.");
        int checksum = optional + 64;
        int certificateDirectory = directories + (8 * 4);
        if (certificateDirectory + 8 > optional + optionalSize) throw new InvalidDataException("PE security directory is missing.");
        uint rawOffset = ReadUInt32(image, certificateDirectory);
        uint rawSize = ReadUInt32(image, certificateDirectory + 4);
        if (rawOffset == 0 || rawSize < 8 || ((ulong)rawOffset + rawSize) > (ulong)image.Length)
            throw new InvalidDataException("PE Authenticode certificate table is missing or outside the executable.");
        return new PeLayout(checksum, certificateDirectory, checked((int)rawOffset), checked((int)rawSize));
    }

    private static byte[] ReadPkcs7Certificate(byte[] image, int certificateOffset, int certificateTableSize)
    {
        int cursor = certificateOffset;
        int end = checked(certificateOffset + certificateTableSize);
        while (cursor + 8 <= end)
        {
            int length = ReadInt32(image, cursor);
            int revision = ReadUInt16(image, cursor + 4);
            int type = ReadUInt16(image, cursor + 6);
            if (length < 8 || cursor + length > end) throw new InvalidDataException("Invalid WIN_CERTIFICATE record.");
            if (revision == 0x0200 && type == 0x0002)
            {
                byte[] result = new byte[length - 8];
                Buffer.BlockCopy(image, cursor + 8, result, 0, result.Length);
                return result;
            }
            cursor = checked(cursor + ((length + 7) & ~7));
        }
        throw new InvalidDataException("PE certificate table has no PKCS#7 Authenticode signature.");
    }

    private static DigestInfo ReadIndirectDataDigest(byte[] content)
    {
        int cursor = 0;
        Tlv outer = ReadTlv(content, ref cursor, content.Length, 0x30);
        if (cursor != content.Length) throw new InvalidDataException("Authenticode indirect data has trailing content.");
        int inner = outer.ContentOffset;
        int innerEnd = outer.ContentOffset + outer.Length;
        ReadTlv(content, ref inner, innerEnd, -1);
        Tlv digestInfo = ReadTlv(content, ref inner, innerEnd, 0x30);
        if (inner != innerEnd) throw new InvalidDataException("Authenticode indirect data is malformed.");
        int digestCursor = digestInfo.ContentOffset;
        int digestEnd = digestInfo.ContentOffset + digestInfo.Length;
        Tlv algorithm = ReadTlv(content, ref digestCursor, digestEnd, 0x30);
        int algorithmCursor = algorithm.ContentOffset;
        int algorithmEnd = algorithm.ContentOffset + algorithm.Length;
        Tlv oid = ReadTlv(content, ref algorithmCursor, algorithmEnd, 0x06);
        string algorithmOid = DecodeOid(content, oid.ContentOffset, oid.Length);
        while (algorithmCursor < algorithmEnd) ReadTlv(content, ref algorithmCursor, algorithmEnd, -1);
        Tlv digest = ReadTlv(content, ref digestCursor, digestEnd, 0x04);
        if (digestCursor != digestEnd) throw new InvalidDataException("Authenticode digest info is malformed.");
        byte[] value = new byte[digest.Length];
        Buffer.BlockCopy(content, digest.ContentOffset, value, 0, digest.Length);
        return new DigestInfo(algorithmOid, value);
    }

    private static Tlv ReadTlv(byte[] value, ref int cursor, int end, int expectedTag)
    {
        if (cursor >= end) throw new InvalidDataException("Unexpected end of Authenticode ASN.1 content.");
        int tag = value[cursor++];
        if (expectedTag >= 0 && tag != expectedTag) throw new InvalidDataException("Unexpected Authenticode ASN.1 tag.");
        if (cursor >= end) throw new InvalidDataException("Missing Authenticode ASN.1 length.");
        int first = value[cursor++];
        int length;
        if ((first & 0x80) == 0) length = first;
        else
        {
            int count = first & 0x7F;
            if (count < 1 || count > 4 || cursor + count > end) throw new InvalidDataException("Unsupported Authenticode ASN.1 length.");
            length = 0;
            for (int i = 0; i < count; i++) length = checked((length << 8) | value[cursor++]);
        }
        if (length < 0 || cursor + length > end) throw new InvalidDataException("Authenticode ASN.1 value exceeds its container.");
        Tlv result = new Tlv((byte)tag, cursor, length);
        cursor += length;
        return result;
    }

    private static string DecodeOid(byte[] value, int offset, int length)
    {
        if (length < 1) throw new InvalidDataException("Authenticode algorithm OID is empty.");
        List<long> parts = new List<long>();
        int first = value[offset];
        parts.Add(first < 80 ? first / 40 : 2);
        parts.Add(first < 80 ? first % 40 : first - 80);
        long component = 0;
        bool pending = false;
        for (int i = 1; i < length; i++)
        {
            byte current = value[offset + i];
            component = checked((component << 7) | (uint)(current & 0x7F));
            pending = (current & 0x80) != 0;
            if (!pending) { parts.Add(component); component = 0; }
        }
        if (pending) throw new InvalidDataException("Authenticode algorithm OID is truncated.");
        return String.Join(".", parts.ToArray());
    }

    private static byte[] ComputeAuthenticodeDigest(byte[] image, PeLayout layout)
    {
        using (SHA256 hash = SHA256.Create())
        {
            Append(hash, image, 0, layout.ChecksumOffset);
            Append(hash, image, layout.ChecksumOffset + 4, layout.CertificateDirectoryOffset - (layout.ChecksumOffset + 4));
            Append(hash, image, layout.CertificateDirectoryOffset + 8, layout.CertificateOffset - (layout.CertificateDirectoryOffset + 8));
            int afterCertificate = checked(layout.CertificateOffset + layout.CertificateSize);
            Append(hash, image, afterCertificate, image.Length - afterCertificate);
            hash.TransformFinalBlock(new byte[0], 0, 0);
            return hash.Hash;
        }
    }

    private static void Append(HashAlgorithm hash, byte[] image, int offset, int count)
    {
        if (offset < 0 || count < 0 || offset + count > image.Length) throw new InvalidDataException("Invalid PE Authenticode hash span.");
        if (count > 0) hash.TransformBlock(image, offset, count, image, offset);
    }

    private static void ValidateCodeSigningCertificate(X509Certificate2 certificate)
    {
        DateTime now = DateTime.UtcNow;
        if (now < certificate.NotBefore.ToUniversalTime() || now > certificate.NotAfter.ToUniversalTime())
            throw new InvalidDataException("The publisher certificate is outside its validity period.");
        bool codeSigning = false;
        foreach (X509Extension extension in certificate.Extensions)
        {
            X509EnhancedKeyUsageExtension eku = extension as X509EnhancedKeyUsageExtension;
            if (eku != null)
                foreach (Oid oid in eku.EnhancedKeyUsages)
                    if (String.Equals(oid.Value, CodeSigningOid, StringComparison.Ordinal)) codeSigning = true;
            X509BasicConstraintsExtension constraints = extension as X509BasicConstraintsExtension;
            if (constraints != null && constraints.CertificateAuthority)
                throw new InvalidDataException("A certificate-authority certificate cannot be used as the application publisher leaf.");
        }
        if (!codeSigning) throw new InvalidDataException("The Authenticode certificate is not valid for code signing.");
    }

    private static int VerifyTrust(string path)
    {
        IntPtr pathPointer = Marshal.StringToCoTaskMemUni(Path.GetFullPath(path));
        IntPtr filePointer = IntPtr.Zero;
        try
        {
            WinTrustFileInfo file = new WinTrustFileInfo();
            file.StructSize = (uint)Marshal.SizeOf(typeof(WinTrustFileInfo));
            file.FilePath = pathPointer;
            filePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WinTrustFileInfo)));
            Marshal.StructureToPtr(file, filePointer, false);
            WinTrustData data = new WinTrustData();
            data.StructSize = (uint)Marshal.SizeOf(typeof(WinTrustData));
            data.UiChoice = 2;
            data.RevocationChecks = 0;
            data.UnionChoice = 1;
            data.FileInfo = filePointer;
            data.StateAction = 1;
            data.ProviderFlags = 0x00000004 | 0x00001000;
            int result = WinVerifyTrust(IntPtr.Zero, GenericVerifyV2, ref data);
            data.StateAction = 2;
            WinVerifyTrust(IntPtr.Zero, GenericVerifyV2, ref data);
            return result;
        }
        finally
        {
            if (filePointer != IntPtr.Zero) Marshal.FreeHGlobal(filePointer);
            Marshal.FreeCoTaskMem(pathPointer);
        }
    }

    private static bool FixedEquals(byte[] left, byte[] right)
    {
        if (left == null || right == null || left.Length != right.Length) return false;
        int difference = 0;
        for (int i = 0; i < left.Length; i++) difference |= left[i] ^ right[i];
        return difference == 0;
    }

    private static string ToHex(byte[] value)
    {
        char[] result = new char[value.Length * 2];
        const string alphabet = "0123456789ABCDEF";
        for (int i = 0; i < value.Length; i++)
        {
            result[i * 2] = alphabet[value[i] >> 4];
            result[i * 2 + 1] = alphabet[value[i] & 15];
        }
        return new String(result);
    }

    private static ushort ReadUInt16(byte[] value, int offset)
    {
        if (offset < 0 || offset + 2 > value.Length) throw new InvalidDataException("PE field exceeds the executable.");
        return BitConverter.ToUInt16(value, offset);
    }
    private static uint ReadUInt32(byte[] value, int offset)
    {
        if (offset < 0 || offset + 4 > value.Length) throw new InvalidDataException("PE field exceeds the executable.");
        return BitConverter.ToUInt32(value, offset);
    }
    private static int ReadInt32(byte[] value, int offset)
    {
        if (offset < 0 || offset + 4 > value.Length) throw new InvalidDataException("PE field exceeds the executable.");
        return BitConverter.ToInt32(value, offset);
    }

    private sealed class PeLayout
    {
        public readonly int ChecksumOffset;
        public readonly int CertificateDirectoryOffset;
        public readonly int CertificateOffset;
        public readonly int CertificateSize;
        public PeLayout(int checksumOffset, int certificateDirectoryOffset, int certificateOffset, int certificateSize)
        {
            ChecksumOffset = checksumOffset;
            CertificateDirectoryOffset = certificateDirectoryOffset;
            CertificateOffset = certificateOffset;
            CertificateSize = certificateSize;
        }
    }
    private sealed class DigestInfo
    {
        public readonly string Algorithm;
        public readonly byte[] Digest;
        public DigestInfo(string algorithm, byte[] digest) { Algorithm = algorithm; Digest = digest; }
    }
    private struct Tlv
    {
        public readonly byte Tag;
        public readonly int ContentOffset;
        public readonly int Length;
        public Tlv(byte tag, int contentOffset, int length) { Tag = tag; ContentOffset = contentOffset; Length = length; }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustFileInfo
    {
        public uint StructSize;
        public IntPtr FilePath;
        public IntPtr FileHandle;
        public IntPtr KnownSubject;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustData
    {
        public uint StructSize;
        public IntPtr PolicyCallbackData;
        public IntPtr SipClientData;
        public uint UiChoice;
        public uint RevocationChecks;
        public uint UnionChoice;
        public IntPtr FileInfo;
        public uint StateAction;
        public IntPtr StateData;
        public IntPtr UrlReference;
        public uint ProviderFlags;
        public uint UiContext;
        public IntPtr SignatureSettings;
    }
    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(IntPtr window, [MarshalAs(UnmanagedType.LPStruct)] Guid action, ref WinTrustData data);
}
'@
        }

        function Get-FixedFileSha256 {
            param([Parameter(Mandatory = $true)] [string] $Path)
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
            finally { $sha.Dispose(); $stream.Dispose() }
        }

        function Assert-PathWithoutReparseAncestor {
            param(
                [Parameter(Mandatory = $true)] [string] $Path,
                [Parameter(Mandatory = $true)] [string] $StopAt
            )
            $current = [IO.Path]::GetFullPath($Path)
            $boundary = [IO.Path]::GetFullPath($StopAt).TrimEnd('\')
            while ($true) {
                if (Test-Path -LiteralPath $current) {
                    $item = Get-Item -LiteralPath $current -Force
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "RemoteDebuggerProvisionV1 rejects reparse point: $current"
                    }
                }
                if ([string]::Equals($current.TrimEnd('\'), $boundary, [StringComparison]::OrdinalIgnoreCase)) { break }
                $parent = Split-Path -Parent $current
                if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'RemoteDebuggerProvisionV1 path did not resolve beneath its expected boundary.'
                }
                $current = $parent
            }
        }

        function Set-ProtectedDirectoryAcl {
            param(
                [Parameter(Mandatory = $true)] [string] $Path,
                [string] $ReadSid
            )

            $security = New-Object Security.AccessControl.DirectorySecurity
            $security.SetAccessRuleProtection($true, $false)
            $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
                $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    [Security.AccessControl.FileSystemRights]::FullControl,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow)
                $security.AddAccessRule($rule)
            }
            if (-not [string]::IsNullOrWhiteSpace($ReadSid)) {
                $sid = [Security.Principal.SecurityIdentifier]::new($ReadSid)
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                    $inheritance,
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow)
                $security.AddAccessRule($rule)
            }
            [IO.Directory]::SetAccessControl($Path, $security)
        }

        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'RemoteDebuggerProvisionV1 guest bootstrap did not receive a full administrator token.'
        }
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if (-not (Test-Path -LiteralPath $GuestFixturePath -PathType Leaf)) {
            throw 'RemoteDebuggerProvisionV1 fixture is missing from the mounted payload.'
        }
        Assert-PathWithoutReparseAncestor -Path $GuestFixturePath -StopAt ([IO.Path]::GetPathRoot($GuestFixturePath))

        $commonApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        $stagingRoot = Join-Path $commonApplicationData 'CodexGuest\RemoteDebuggerProvisioning'
        $requestRoot = Join-Path $stagingRoot $RequestId
        Assert-PathWithoutReparseAncestor -Path $stagingRoot -StopAt $commonApplicationData
        if (-not (Test-Path -LiteralPath $stagingRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $stagingRoot | Out-Null
        }
        Assert-PathWithoutReparseAncestor -Path $stagingRoot -StopAt $commonApplicationData
        Set-ProtectedDirectoryAcl -Path $stagingRoot
        if (Test-Path -LiteralPath $requestRoot) {
            throw 'RemoteDebuggerProvisionV1 refuses to reuse an existing protected staging directory.'
        }
        New-Item -ItemType Directory -Path $requestRoot | Out-Null
        Assert-PathWithoutReparseAncestor -Path $requestRoot -StopAt $commonApplicationData
        Set-ProtectedDirectoryAcl -Path $requestRoot

        try {
        $provisioningRoot = 'C:\CodexGuest\Provisioning'
        $expectedOutputRoot = Join-Path $provisioningRoot $RequestId
        if (-not [string]::Equals([IO.Path]::GetFullPath($GuestOutputRoot).TrimEnd('\'), $expectedOutputRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'RemoteDebuggerProvisionV1 evidence output must use the fixed protected per-request provisioning path.'
        }
        Assert-PathWithoutReparseAncestor -Path $provisioningRoot -StopAt ([IO.Path]::GetPathRoot($provisioningRoot))
        if (-not (Test-Path -LiteralPath $provisioningRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $provisioningRoot | Out-Null
        }
        Assert-PathWithoutReparseAncestor -Path $provisioningRoot -StopAt ([IO.Path]::GetPathRoot($provisioningRoot))
        Set-ProtectedDirectoryAcl -Path $provisioningRoot -ReadSid $currentSid
        if (Test-Path -LiteralPath $expectedOutputRoot) {
            throw 'RemoteDebuggerProvisionV1 refuses to overwrite existing provisioning evidence.'
        }
        New-Item -ItemType Directory -Path $expectedOutputRoot | Out-Null
        Assert-PathWithoutReparseAncestor -Path $expectedOutputRoot -StopAt ([IO.Path]::GetPathRoot($expectedOutputRoot))
        Set-ProtectedDirectoryAcl -Path $expectedOutputRoot -ReadSid $currentSid

        $source = [IO.File]::Open($GuestFixturePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $actualSha256 = ([BitConverter]::ToString($sha.ComputeHash($source))).Replace('-', '')
            if (-not [string]::Equals($actualSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RemoteDebuggerProvisionV1 mounted fixture does not match its protected approved SHA-256.'
            }
            $source.Position = 0

            $stagedExecutable = Join-Path $requestRoot 'RemoteDebugger.exe'
            $destination = [IO.File]::Open($stagedExecutable, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $source.CopyTo($destination); $destination.Flush($true) }
            finally { $destination.Dispose() }
        }
        finally {
            $sha.Dispose()
            $source.Dispose()
        }

            $stagedSha256 = Get-FixedFileSha256 -Path $stagedExecutable
            if (-not [string]::Equals($stagedSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RemoteDebuggerProvisionV1 protected staging copy changed before execution.'
            }
            Assert-PathWithoutReparseAncestor -Path $stagedExecutable -StopAt ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
            $verifiedPublisher = [CodexRemoteDebuggerAuthenticode]::Verify($stagedExecutable, $PublisherThumbprint)
            if (-not [string]::Equals($verifiedPublisher, $PublisherThumbprint, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RemoteDebuggerProvisionV1 Authenticode verifier returned a different publisher pin.'
            }

            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $stagedExecutable
            $start.Arguments = 'cli platform-provision'
            $start.WorkingDirectory = $requestRoot
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            if ($null -eq $process) { throw 'RemoteDebuggerProvisionV1 could not start the fixed provisioning command.' }
            try {
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                    try { $process.Kill() } catch { }
                    throw "RemoteDebuggerProvisionV1 exceeded its bounded $TimeoutSeconds-second guest timeout."
                }
                $process.WaitForExit()
                $stdout = [string]$stdoutTask.Result
                $stderr = [string]$stderrTask.Result
                if ($process.ExitCode -ne 0) {
                    $bounded = (($stderr + [Environment]::NewLine + $stdout).Trim())
                    if ($bounded.Length -gt 4096) { $bounded = $bounded.Substring(0, 4096) }
                    throw "RemoteDebuggerProvisionV1 product provisioner exited $($process.ExitCode): $bounded"
                }
            }
            finally { $process.Dispose() }

            $receiptPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'RemoteDebugger\Support\provisioning-receipt.json'
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
                throw 'RemoteDebuggerProvisionV1 did not receive the protected product provisioning receipt.'
            }
            Assert-PathWithoutReparseAncestor -Path $receiptPath -StopAt ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
            $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($receipt.Provisioned -isnot [bool] -or -not [bool]$receipt.Provisioned) {
                throw 'RemoteDebuggerProvisionV1 receipt does not attest successful provisioning.'
            }
            if (-not [string]::Equals([string]$receipt.PublisherThumbprint, $PublisherThumbprint, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RemoteDebuggerProvisionV1 receipt publisher does not match the protected publisher pin.'
            }
            if (-not [string]::Equals([string]$receipt.ServiceStartMode, 'demand', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RemoteDebuggerProvisionV1 receipt does not attest demand-start service configuration.'
            }
            if (-not [string]::Equals([string]$receipt.RegisteredUserSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RemoteDebuggerProvisionV1 receipt registered a different interactive user SID.'
            }

            $expectedManagedPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'RemoteDebugger\RemoteDebugger.exe'
            $expectedServicePath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'RemoteDebugger\Support\RemoteDebugger.Support.exe'
            $managedPath = [IO.Path]::GetFullPath([string]$receipt.ManagedApplicationPath)
            $servicePath = [IO.Path]::GetFullPath([string]$receipt.ServiceExecutablePath)
            if (-not [string]::Equals($managedPath, $expectedManagedPath, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($servicePath, $expectedServicePath, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RemoteDebuggerProvisionV1 receipt paths do not match the fixed protected product installation.'
            }
            Assert-PathWithoutReparseAncestor -Path $managedPath -StopAt ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles))
            Assert-PathWithoutReparseAncestor -Path $servicePath -StopAt ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles))
            $managedSha256 = Get-FixedFileSha256 -Path $managedPath
            $serviceSha256 = Get-FixedFileSha256 -Path $servicePath
            if (-not [string]::Equals($managedSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($serviceSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'RemoteDebuggerProvisionV1 installed product bytes do not match the approved fixture SHA-256.'
            }

            $service = Get-Service -Name 'RemoteDebuggerSupport' -ErrorAction Stop
            if ([string]$service.Status -ne 'Running') {
                throw "RemoteDebuggerProvisionV1 support service is '$($service.Status)' instead of Running."
            }
            # The acceptance coordinator receives UDP announcements separately
            # from the product. Scope its exception to this disposable payload;
            # product firewall preparation remains the product service's job.
            $labPath = Join-Path $GuestPayloadRoot 'lab\RemoteDebugger.Lab.exe'
            if (-not (Test-Path -LiteralPath $labPath -PathType Leaf)) {
                throw 'The dedicated acceptance payload is missing its fixed Lab executable.'
            }
            Assert-PathWithoutReparseAncestor -Path $labPath -StopAt $GuestPayloadRoot
            New-NetFirewallRule -Name 'CodexRdAcceptanceLabUdp' -DisplayName 'Codex RD acceptance coordination' `
                -Program $labPath -Direction Inbound -Action Allow -Protocol UDP -LocalPort 45835 `
                -Profile Private -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null
            $evidence = [pscustomobject][ordered]@{
                FormatVersion = 1
                Profile = 'RemoteDebuggerProvisionV1'
                RequestId = $RequestId
                FixtureSha256 = $actualSha256
                ManagedExecutablePath = $managedPath
                ManagedExecutableSha256 = $managedSha256
                ServiceExecutablePath = $servicePath
                ServiceExecutableSha256 = $serviceSha256
                ServiceName = 'RemoteDebuggerSupport'
                ServiceStatus = [string]$service.Status
                ServiceStartMode = [string]$receipt.ServiceStartMode
                PublisherThumbprint = ([string]$receipt.PublisherThumbprint).ToUpperInvariant()
                RegisteredUserSid = [string]$receipt.RegisteredUserSid
                ReceiptPath = $receiptPath
                ProvisionedUtc = [string]$receipt.ProvisionedUtc
            }

            if (-not (Test-Path -LiteralPath $GuestOutputRoot -PathType Container)) {
                throw 'RemoteDebuggerProvisionV1 protected provisioning output disappeared before evidence publication.'
            }
            Assert-PathWithoutReparseAncestor -Path $GuestOutputRoot -StopAt ([IO.Path]::GetPathRoot($GuestOutputRoot))
            $evidencePath = Join-Path $GuestOutputRoot $EvidenceFileName
            if (Test-Path -LiteralPath $evidencePath) {
                throw 'RemoteDebuggerProvisionV1 refuses to replace existing provisioning evidence.'
            }
            $temporaryEvidence = $evidencePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            try {
                $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryEvidence -Encoding UTF8
                [IO.File]::Move($temporaryEvidence, $evidencePath)
            }
            finally { Remove-Item -LiteralPath $temporaryEvidence -Force -ErrorAction SilentlyContinue }
            $evidence
        }
        finally {
            if (Test-Path -LiteralPath $requestRoot -PathType Container) {
                Remove-Item -LiteralPath $requestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $remoteJob = $null
    try {
        $remoteJob = Invoke-Command -Session $Session -ScriptBlock $guestOperation -ArgumentList @(
            [string]$definition.GuestFixturePath,
            [string]$definition.ExpectedSha256,
            [string]$definition.PublisherThumbprint,
            $outputRoot,
            [string]$definition.EvidenceFileName,
            $RequestId,
            $guestTimeoutSeconds,
            [IO.Path]::GetFullPath($GuestPayloadRoot)
        ) -AsJob -ErrorAction Stop

        while ([string]$remoteJob.State -in @('NotStarted', 'Running')) {
            if ($ActivityCheck) { & $ActivityCheck }
            if ([DateTime]::UtcNow -ge $ExecutionDeadlineUtc.ToUniversalTime()) {
                Stop-Job -Job $remoteJob -ErrorAction SilentlyContinue
                throw 'RemoteDebuggerProvisionV1 exceeded the request execution deadline.'
            }
            Wait-Job -Job $remoteJob -Timeout 1 | Out-Null
        }
        if ([string]$remoteJob.State -ne 'Completed') {
            $reason = if ($remoteJob.ChildJobs.Count -gt 0 -and $remoteJob.ChildJobs[0].JobStateInfo.Reason) {
                [string]$remoteJob.ChildJobs[0].JobStateInfo.Reason.Message
            }
            else { "Remote job entered state $($remoteJob.State)." }
            throw "RemoteDebuggerProvisionV1 guest bootstrap failed: $reason"
        }
        $values = @(Receive-Job -Job $remoteJob -ErrorAction Stop)
        $result = @($values | Where-Object {
            $_ -and $_.PSObject.Properties['Profile'] -and [string]$_.Profile -eq 'RemoteDebuggerProvisionV1'
        } | Select-Object -Last 1)
        if ($result.Count -ne 1) { throw 'RemoteDebuggerProvisionV1 guest bootstrap returned no normalized evidence.' }
        $remoteEvidence = $result[0]
        if ($remoteEvidence.FormatVersion -is [bool] -or [int64]$remoteEvidence.FormatVersion -ne 1 -or
            -not [string]::Equals([string]$remoteEvidence.RequestId, $RequestId, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$remoteEvidence.FixtureSha256, [string]$definition.ExpectedSha256, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$remoteEvidence.ManagedExecutableSha256, [string]$definition.ExpectedSha256, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$remoteEvidence.ServiceExecutableSha256, [string]$definition.ExpectedSha256, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$remoteEvidence.PublisherThumbprint, [string]$definition.PublisherThumbprint, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'RemoteDebuggerProvisionV1 guest evidence does not match the protected request identity.'
        }
        if (-not [string]::Equals([string]$remoteEvidence.ManagedExecutablePath, 'C:\Program Files\RemoteDebugger\RemoteDebugger.exe', [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$remoteEvidence.ServiceExecutablePath, 'C:\Program Files\RemoteDebugger\Support\RemoteDebugger.Support.exe', [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$remoteEvidence.ReceiptPath, 'C:\ProgramData\RemoteDebugger\Support\provisioning-receipt.json', [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$remoteEvidence.ServiceName, 'RemoteDebuggerSupport', [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$remoteEvidence.ServiceStatus, 'Running', [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$remoteEvidence.ServiceStartMode, 'demand', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'RemoteDebuggerProvisionV1 guest evidence does not attest the fixed managed installation and running demand-start service.'
        }
        if ([string]$remoteEvidence.RegisteredUserSid -notmatch '\AS-\d(?:-\d+)+\z') {
            throw 'RemoteDebuggerProvisionV1 guest evidence has an invalid registered user SID.'
        }
        $provisionedUtc = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact([string]$remoteEvidence.ProvisionedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$provisionedUtc)) {
            throw 'RemoteDebuggerProvisionV1 guest evidence has an invalid provisioning timestamp.'
        }
        [pscustomobject][ordered]@{
            FormatVersion = 1
            Profile = 'RemoteDebuggerProvisionV1'
            RequestId = [string]$remoteEvidence.RequestId
            FixtureSha256 = ([string]$remoteEvidence.FixtureSha256).ToUpperInvariant()
            ManagedExecutablePath = [string]$remoteEvidence.ManagedExecutablePath
            ManagedExecutableSha256 = ([string]$remoteEvidence.ManagedExecutableSha256).ToUpperInvariant()
            ServiceExecutablePath = [string]$remoteEvidence.ServiceExecutablePath
            ServiceExecutableSha256 = ([string]$remoteEvidence.ServiceExecutableSha256).ToUpperInvariant()
            ServiceName = 'RemoteDebuggerSupport'
            ServiceStatus = 'Running'
            ServiceStartMode = 'demand'
            PublisherThumbprint = ([string]$remoteEvidence.PublisherThumbprint).ToUpperInvariant()
            RegisteredUserSid = [string]$remoteEvidence.RegisteredUserSid
            ReceiptPath = [string]$remoteEvidence.ReceiptPath
            ProvisionedUtc = $provisionedUtc.ToUniversalTime().ToString('o')
            EvidenceFileName = [string]$definition.EvidenceFileName
        }
    }
    finally {
        if ($remoteJob) {
            if ([string]$remoteJob.State -in @('NotStarted', 'Running')) { Stop-Job -Job $remoteJob -ErrorAction SilentlyContinue }
            Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue
        }
    }
}
