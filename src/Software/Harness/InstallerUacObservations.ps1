function Initialize-InstallerPathObservation {
    if ('CodexInstallerPathObservation' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public sealed class CodexInstallerPathObservation {
    public string Name, Path, Status="Unobservable", Kind, OwnerSid, Sddl, Sha256;
    public long? Length;
    public int? ErrorCode;
    [StructLayout(LayoutKind.Sequential)] struct FileInfo {
        public uint Attributes, CreateLow, CreateHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInfo info);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle file,System.Text.StringBuilder name,uint length,uint flags);
    [DllImport("advapi32.dll")] static extern uint GetSecurityInfo(SafeFileHandle file,int type,uint flags,out IntPtr owner,out IntPtr group,out IntPtr dacl,out IntPtr sacl,out IntPtr descriptor);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertSidToStringSid(IntPtr sid,out IntPtr text);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(IntPtr descriptor,uint revision,uint flags,out IntPtr text,out uint length);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
    static void Check(bool okay) { if(!okay) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
    public sealed class Lease : IDisposable {
        internal List<SafeFileHandle> Handles=new List<SafeFileHandle>();
        public FileStream Stream;
        public void Dispose(){if(Stream!=null)Stream.Dispose();for(int i=Handles.Count-1;i>=0;i--)Handles[i].Dispose();}
    }
    public static Lease OpenBoundFile(string path,string expectedHash,long maximumLength) {
        var lease=new Lease();
        try {
            string absolute=System.IO.Path.GetFullPath(path),root=System.IO.Path.GetPathRoot(absolute),current=root;
            if(root.Length!=3 || root[1]!=':' || absolute.IndexOf(':',2)>=0)throw new InvalidOperationException("A local drive path is required.");
            var components=new List<string>();components.Add(root);
            foreach(string part in absolute.Substring(root.Length).Split(new[]{'\\'},StringSplitOptions.RemoveEmptyEntries)){current=System.IO.Path.Combine(current,part);components.Add(current);}
            SafeFileHandle file=null;FileInfo info=new FileInfo();
            foreach(string component in components){file=CreateFile(component,component==absolute?0x80000000u:0x20080u,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(file.IsInvalid){int error=Marshal.GetLastWin32Error();file.Dispose();throw new System.ComponentModel.Win32Exception(error);}lease.Handles.Add(file);Check(GetFileInformationByHandle(file,out info));if((info.Attributes&0x400)!=0)throw new InvalidOperationException("Reparse point refused.");}
            var name=new System.Text.StringBuilder(32768);uint count=GetFinalPathNameByHandle(file,name,(uint)name.Capacity,0);Check(count>0 && count<name.Capacity);
            if(!String.Equals(name.ToString(),"\\\\?\\"+absolute,StringComparison.OrdinalIgnoreCase) || (info.Attributes&0x10)!=0 || (((long)info.SizeHigh<<32)|info.SizeLow)>maximumLength)throw new InvalidOperationException("Bound file identity or size invalid.");
            lease.Stream=new FileStream(file,FileAccess.Read);
            if(expectedHash!=null){string hash;using(var digest=SHA256.Create())hash=BitConverter.ToString(digest.ComputeHash(lease.Stream)).Replace("-","");if(hash!=expectedHash)throw new InvalidOperationException("Bound file hash mismatch.");lease.Stream.Position=0;}
            return lease;
        }catch{lease.Dispose();throw;}
    }
    public static CodexInstallerPathObservation Read(string path,string name) {
        var result=new CodexInstallerPathObservation {Name=name,Path=path};
        var handles=new List<SafeFileHandle>();
        try {
            string absolute=System.IO.Path.GetFullPath(path), root=System.IO.Path.GetPathRoot(absolute);
            if(root.Length!=3 || root[1]!=':' || absolute.IndexOf(':',2)>=0) throw new InvalidOperationException("A local drive path is required.");
            var components=new List<string>();components.Add(root);
            string current=root;
            foreach(string part in absolute.Substring(root.Length).Split(new[]{'\\'},StringSplitOptions.RemoveEmptyEntries)) { current=System.IO.Path.Combine(current,part);components.Add(current); }
            FileInfo info=new FileInfo();
            SafeFileHandle file=null;
            foreach(string component in components) {
                // Retain every parent without write/delete sharing: a directory
                // cannot be replaced or converted to a junction during the read.
                file=CreateFile(component,component==absolute?0x80000000u:0x20080u,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
                if(file.IsInvalid) { int code=Marshal.GetLastWin32Error();file.Dispose();throw new System.ComponentModel.Win32Exception(code); }
                handles.Add(file);Check(GetFileInformationByHandle(file,out info));
                if((info.Attributes&0x400)!=0) { result.Status="ReparsePointRefused";return result; }
            }
            var finalName=new System.Text.StringBuilder(32768);
            uint count=GetFinalPathNameByHandle(file,finalName,(uint)finalName.Capacity,0);
            Check(count>0 && count<finalName.Capacity);
            if(!String.Equals(finalName.ToString(),"\\\\?\\"+absolute,StringComparison.OrdinalIgnoreCase)) { result.Status="PathIdentityMismatch";return result; }
            IntPtr owner,group,dacl,sacl,descriptor;
            uint error=GetSecurityInfo(file,1,7,out owner,out group,out dacl,out sacl,out descriptor);
            if(error!=0) throw new System.ComponentModel.Win32Exception((int)error);
            try {
                IntPtr text;uint length;
                Check(ConvertSidToStringSid(owner,out text));try {result.OwnerSid=Marshal.PtrToStringUni(text);}finally{LocalFree(text);}
                Check(ConvertSecurityDescriptorToStringSecurityDescriptor(descriptor,1,7,out text,out length));try{result.Sddl=Marshal.PtrToStringUni(text);}finally{LocalFree(text);}
            } finally {LocalFree(descriptor);}
            result.Kind=(info.Attributes&0x10)!=0?"Directory":"File";
            if(result.Kind=="File") {
                result.Length=((long)info.SizeHigh<<32)|info.SizeLow;
                if(result.Length>1073741824) {result.Status="SizeLimitExceeded";return result;}
                using(var stream=new FileStream(file,FileAccess.Read)) using(var hash=SHA256.Create()) result.Sha256=BitConverter.ToString(hash.ComputeHash(stream)).Replace("-","");
            }
            result.Status="Found";
        } catch(System.ComponentModel.Win32Exception error) {
            result.ErrorCode=error.NativeErrorCode;
            result.Status=error.NativeErrorCode==2 || error.NativeErrorCode==3?"Absent":error.NativeErrorCode==5?"AccessDenied":"Unobservable";
        } catch { result.Status="Unobservable"; }
        finally {for(int i=handles.Count-1;i>=0;i--)handles[i].Dispose();}
        return result;
    }
}
'@
}

function Get-InstallerPrivilegedObservations {
    param($Policy, $Identity)
    Initialize-InstallerPathObservation
    $roots = @{
        InitiatorProfile=[string]$Identity.Initiator.ProfilePath
        AdministratorProfile=[string]$Identity.ElevationAccount.ProfilePath
        ProgramData=[Environment]::GetFolderPath('CommonApplicationData')
        ProgramFiles=[Environment]::GetFolderPath('ProgramFiles')
    }
    foreach ($specification in $Policy.PrivilegedObservations) {
        $root = $roots[$specification.Root]
        if ([string]::IsNullOrWhiteSpace($root)) { throw 'Requested observation has no established profile root.' }
        $path = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $specification.RelativePath))
        if (-not $path.StartsWith($root.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Observation path escaped its established root.' }
        [CodexInstallerPathObservation]::Read($path, [string]$specification.Name)
    }
}
