using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Threading;
using System.Web.Script.Serialization;

internal static class InstallerUacCanary {
    [STAThread] static int Main(string[] args) {
        try {
            if(args.Length==2 && args[0]=="elevated") {
                var identity=WindowsIdentity.GetCurrent();
                if(!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))return 7;
                string path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"CodexInstallerAcceptance",args[1]+".json");
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path,new JavaScriptSerializer().Serialize(new {Sid=identity.User.Value,SessionId=Process.GetCurrentProcess().SessionId,Profile=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)}));
                Thread.Sleep(8000); // Allow independent token/process observation before exit.
                return 0;
            }
            if(args.Length!=1)return 8;
            var start=new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName,"elevated "+args[0]);
            start.UseShellExecute=true;start.Verb="runas";
            using(var child=Process.Start(start)){child.WaitForExit();return child.ExitCode;}
        } catch(Win32Exception error){return error.NativeErrorCode;} catch{return 9;}
    }
}
