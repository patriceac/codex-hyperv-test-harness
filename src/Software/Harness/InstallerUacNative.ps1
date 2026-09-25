function Initialize-InstallerNative {
    if ('CodexInstallerNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

public sealed class CodexInstallerProcessIdentity {
    public int ProcessId, SessionId, IntegrityRid, ElevationType;
    public long CreationFileTime;
    public string ImagePath, UserSid;
    public bool Elevated, AdministratorGroup, AdministratorDenyOnly;
}
public sealed class CodexInstallerProcess : IDisposable {
    internal IntPtr Handle;
    public CodexInstallerProcessIdentity Identity;
    public bool Exited { get {return CodexInstallerNative.WaitForSingleObject(Handle,0)==0;} }
    public int ExitCode { get {uint code;CodexInstallerNative.Check(CodexInstallerNative.GetExitCodeProcess(Handle,out code));return unchecked((int)code);} }
    public void Dispose() {if(Handle!=IntPtr.Zero){CodexInstallerNative.CloseHandle(Handle);Handle=IntPtr.Zero;}}
}
public static class CodexInstallerNative {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo { public int cb;public string reserved,desktop,title;public int x,y,width,height,xChars,yChars,fill,flags;public short show,reserved2;public IntPtr reservedPointer,input,output,error; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {public IntPtr process,thread;public int pid,tid;}
    [StructLayout(LayoutKind.Sequential)] struct Luid {public uint low;public int high;}
    [StructLayout(LayoutKind.Sequential)] struct Privilege {public uint count;public Luid luid;public uint attributes;}
    [StructLayout(LayoutKind.Sequential)] struct SidAttributes {public IntPtr sid;public uint attributes;}
    [StructLayout(LayoutKind.Sequential)] struct Input {public uint type;public InputUnion data;}
    [StructLayout(LayoutKind.Explicit)] struct InputUnion {[FieldOffset(0)]public Keyboard keyboard;[FieldOffset(0)]public Mouse mouse;}
    [StructLayout(LayoutKind.Sequential)] struct Keyboard {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
    [StructLayout(LayoutKind.Sequential)] struct Mouse {public int x,y;public uint data,flags,time;public UIntPtr extra;}
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSQueryUserToken(uint session,out IntPtr token);
    [DllImport("userenv.dll",SetLastError=true)] static extern bool CreateEnvironmentBlock(out IntPtr environment,IntPtr token,bool inherit);
    [DllImport("userenv.dll")] static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("userenv.dll",CharSet=CharSet.Unicode)] static extern int CreateProfile(string sid,string user,[Out] StringBuilder path,uint length);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out long created,out long exited,out long kernel,out long user);
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder path,ref uint size);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int kind,IntPtr value,int length,out int needed);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr token,uint access,IntPtr attributes,int level,int type,out IntPtr duplicate);
    [DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system,string name,out Luid luid);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref Privilege privileges,int length,IntPtr previous,IntPtr returned);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid,uint index);
    [DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr token,string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo info);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out int pid);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder value,int length,out int needed);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] inputs,int size);
    public static void Check(bool okay) {if(!okay)throw new Win32Exception(Marshal.GetLastWin32Error());}
    public static void RequireSystem() {if(WindowsIdentity.GetCurrent().User.Value!="S-1-5-18")throw new InvalidOperationException("Installer controller requires guest SYSTEM.");}
    public static void EnablePrivilege(string name) {
        IntPtr token;Check(OpenProcessToken(Process.GetCurrentProcess().Handle,0x28,out token));
        try {Privilege p=new Privilege();p.count=1;p.attributes=2;Check(LookupPrivilegeValue(null,name,out p.luid));Check(AdjustTokenPrivileges(token,false,ref p,0,IntPtr.Zero,IntPtr.Zero));if(Marshal.GetLastWin32Error()!=0)throw new Win32Exception(Marshal.GetLastWin32Error());}finally{CloseHandle(token);}
    }
    static IntPtr TokenData(IntPtr token,int kind) {int size;GetTokenInformation(token,kind,IntPtr.Zero,0,out size);if(size<=0)throw new Win32Exception(Marshal.GetLastWin32Error());IntPtr p=Marshal.AllocHGlobal(size);try{Check(GetTokenInformation(token,kind,p,size,out size));return p;}catch{Marshal.FreeHGlobal(p);throw;}}
    static int TokenInt(IntPtr token,int kind) {IntPtr p=TokenData(token,kind);try{return Marshal.ReadInt32(p);}finally{Marshal.FreeHGlobal(p);}}
    public static CodexInstallerProcessIdentity Observe(int pid) {
        IntPtr process=OpenProcess(0x1000,false,pid);if(process==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr token;Check(OpenProcessToken(process,8,out token));
            try {
                var value=new CodexInstallerProcessIdentity();value.ProcessId=pid;
                long exit,kernel,user;Check(GetProcessTimes(process,out value.CreationFileTime,out exit,out kernel,out user));
                var path=new StringBuilder(32768);uint size=(uint)path.Capacity;Check(QueryFullProcessImageName(process,0,path,ref size));value.ImagePath=path.ToString();
                using(var identity=new WindowsIdentity(token))value.UserSid=identity.User.Value;
                value.SessionId=TokenInt(token,12);value.Elevated=TokenInt(token,20)!=0;value.ElevationType=TokenInt(token,18);
                IntPtr data=TokenData(token,25);try {IntPtr sid=Marshal.ReadIntPtr(data);uint count=Marshal.ReadByte(GetSidSubAuthorityCount(sid));value.IntegrityRid=Marshal.ReadInt32(GetSidSubAuthority(sid,count-1));}finally{Marshal.FreeHGlobal(data);}
                data=TokenData(token,2);try {int count=Marshal.ReadInt32(data),offset=IntPtr.Size==8?8:4,step=Marshal.SizeOf(typeof(SidAttributes));for(int i=0;i<count;i++){var group=(SidAttributes)Marshal.PtrToStructure(IntPtr.Add(data,offset+i*step),typeof(SidAttributes));if(new SecurityIdentifier(group.sid).Value=="S-1-5-32-544"){value.AdministratorGroup=true;value.AdministratorDenyOnly=(group.attributes&16)!=0;}}}finally{Marshal.FreeHGlobal(data);}
                return value;
            }finally{CloseHandle(token);}
        }finally{CloseHandle(process);}
    }
    public static string Quote(string argument) {
        var result=new StringBuilder("\"");int slashes=0;
        foreach(char c in argument){if(c=='\\'){slashes++;continue;}if(c=='"'){result.Append('\\',slashes*2+1).Append(c);}else{result.Append('\\',slashes).Append(c);}slashes=0;}
        return result.Append('\\',slashes*2).Append('"').ToString();
    }
    static CodexInstallerProcess Start(IntPtr token,string image,string arguments,string desktop) {
        IntPtr environment;Check(CreateEnvironmentBlock(out environment,token,false));
        try {
            StartupInfo startup=new StartupInfo();startup.cb=Marshal.SizeOf(startup);startup.desktop=desktop;
            ProcessInfo child;Check(CreateProcessAsUser(token,image,new StringBuilder(Quote(image)+" "+arguments),IntPtr.Zero,IntPtr.Zero,false,0x08000404,environment,System.IO.Path.GetDirectoryName(image),ref startup,out child));
            try {var process=new CodexInstallerProcess {Handle=child.process,Identity=Observe(child.pid)};if(ResumeThread(child.thread)==0xFFFFFFFF)throw new Win32Exception(Marshal.GetLastWin32Error());return process;}
            catch {TerminateProcess(child.process,1);CloseHandle(child.process);throw;}
            finally {CloseHandle(child.thread);}
        }finally{DestroyEnvironmentBlock(environment);}
    }
    public static CodexInstallerProcess StartAsConsoleUser(string image,string arguments,string expectedSid) {
        RequireSystem();EnablePrivilege("SeTcbPrivilege");EnablePrivilege("SeAssignPrimaryTokenPrivilege");EnablePrivilege("SeIncreaseQuotaPrivilege");
        IntPtr token;Check(WTSQueryUserToken(WTSGetActiveConsoleSessionId(),out token));
        try {
            if(TokenInt(token,20)!=0) {IntPtr data=TokenData(token,19),limited=Marshal.ReadIntPtr(data);Marshal.FreeHGlobal(data);CloseHandle(token);token=limited;}
            using(var identity=new WindowsIdentity(token))if(identity.User.Value!=expectedSid)throw new InvalidOperationException("Unexpected interactive console identity.");
            if(TokenInt(token,20)!=0 || TokenInt(token,12)!=(int)WTSGetActiveConsoleSessionId())throw new InvalidOperationException("Interactive token is elevated or in another session.");
            return Start(token,image,arguments,"winsta0\\default");
        }finally{CloseHandle(token);}
    }
    public static string ConsoleSid() {
        RequireSystem();EnablePrivilege("SeTcbPrivilege");IntPtr token;Check(WTSQueryUserToken(WTSGetActiveConsoleSessionId(),out token));try{using(var identity=new WindowsIdentity(token))return identity.User.Value;}finally{CloseHandle(token);}
    }
    public static CodexInstallerProcess StartOnSecureDesktop(string script,string requestRoot) {
        RequireSystem();EnablePrivilege("SeDebugPrivilege");EnablePrivilege("SeAssignPrimaryTokenPrivilege");EnablePrivilege("SeIncreaseQuotaPrivilege");
        Process logon=null;foreach(var p in Process.GetProcessesByName("winlogon"))if(p.SessionId==(int)WTSGetActiveConsoleSessionId()){if(logon!=null)throw new InvalidOperationException("Ambiguous console Winlogon.");logon=p;}
        if(logon==null)throw new InvalidOperationException("Console Winlogon not found.");
        IntPtr process=OpenProcess(0x1000,false,logon.Id),token=IntPtr.Zero,duplicate=IntPtr.Zero;
        if(process==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
        try {Check(OpenProcessToken(process,0xB,out token));Check(DuplicateTokenEx(token,0xF01FF,IntPtr.Zero,2,1,out duplicate));return Start(duplicate,System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe"),"-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "+Quote(script)+" -RequestRoot "+Quote(requestRoot)+" -SecureUi","winsta0\\winlogon");}
        finally {if(duplicate!=IntPtr.Zero)CloseHandle(duplicate);if(token!=IntPtr.Zero)CloseHandle(token);CloseHandle(process);}
    }
    public static string NewProfile(string sid,string user) {var path=new StringBuilder(260);int hr=CreateProfile(sid,user,path,(uint)path.Capacity);if(hr<0)Marshal.ThrowExceptionForHR(hr);return path.ToString();}
    public static int SecureForeground() {
        IntPtr desktop=OpenInputDesktop(0,false,1);if(desktop==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
        try {var name=new StringBuilder(128);int needed;Check(GetUserObjectInformation(desktop,2,name,256,out needed));if(!String.Equals(name.ToString(),"Winlogon",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Secure input desktop is not active.");}finally{CloseDesktop(desktop);}
        int pid;GetWindowThreadProcessId(GetForegroundWindow(),out pid);return pid;
    }
    public static void TypeSecureCharacter(ushort value,int expectedConsentPid) {
        if(SecureForeground()!=expectedConsentPid)throw new InvalidOperationException("Secure foreground changed.");
        var events=new Input[2];events[0].type=1;events[0].data.keyboard.scan=value;events[0].data.keyboard.flags=4;events[1]=events[0];events[1].data.keyboard.flags=6;
        Check(SendInput(2,events,Marshal.SizeOf(typeof(Input)))==2);
    }
    public static void StopExact(CodexInstallerProcessIdentity expected) {
        IntPtr process=OpenProcess(0x101001,false,expected.ProcessId);
        if(process==IntPtr.Zero){if(Marshal.GetLastWin32Error()==87)return;throw new Win32Exception(Marshal.GetLastWin32Error());}
        try {long created,exit,kernel,user;Check(GetProcessTimes(process,out created,out exit,out kernel,out user));if(created!=expected.CreationFileTime)throw new InvalidOperationException("Cleanup refused a reused process ID.");if(WaitForSingleObject(process,0)==0)return;Check(TerminateProcess(process,1));if(WaitForSingleObject(process,5000)!=0)throw new TimeoutException("Privileged process cleanup did not finish.");}finally{CloseHandle(process);}
    }
    public static bool IsAlive(CodexInstallerProcessIdentity expected) {
        IntPtr process=OpenProcess(0x101000,false,expected.ProcessId);
        if(process==IntPtr.Zero){if(Marshal.GetLastWin32Error()==87)return false;throw new Win32Exception(Marshal.GetLastWin32Error());}
        try {long created,exit,kernel,user;Check(GetProcessTimes(process,out created,out exit,out kernel,out user));if(created!=expected.CreationFileTime)throw new InvalidOperationException("Observed process ID was reused.");return WaitForSingleObject(process,0)!=0;}finally{CloseHandle(process);}
    }
}
'@
}
