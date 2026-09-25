using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Web.Script.Serialization;

internal static class InstallerUacVerifier {
    [STAThread] static int Main(string[] args) {
        if(args.Length!=5)return 2;
        try {
            var json=new JavaScriptSerializer();
            var record=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(args[1]));
            var identities=(Dictionary<string,object>)record["Identity"];
            var initiating=(Dictionary<string,object>)identities["Initiator"];
            var admin=(Dictionary<string,object>)identities["ElevationAccount"];
            var current=WindowsIdentity.GetCurrent();
            bool passed=current.User.Value==(string)initiating["Sid"] && !new WindowsPrincipal(current).IsInRole(WindowsBuiltInRole.Administrator);
            string marker=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"CodexInstallerAcceptance",args[4]+".json");
            bool expected=args[0]=="After" && args[3]=="Accept";
            passed=passed && File.Exists(marker)==expected;
            if(expected){var elevated=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(marker));passed=passed && (string)elevated["Sid"]==(string)admin["Sid"] && Convert.ToInt32(elevated["SessionId"])==Process.GetCurrentProcess().SessionId && String.Equals((string)elevated["Profile"],(string)admin["ProfilePath"],StringComparison.OrdinalIgnoreCase);}
            Directory.CreateDirectory(args[2]);
            File.WriteAllText(Path.Combine(args[2],"result.json"),json.Serialize(new {passed=passed,phase=args[0],sid=current.User.Value}));
            return 0;
        }catch{return 3;}
    }
}
