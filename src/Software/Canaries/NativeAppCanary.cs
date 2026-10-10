// Original fixture for native harness acceptance. No game assets or product code.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

sealed class NativeAppCanary : Form
{
    const int LogicalWidth=320, LogicalHeight=200;
    readonly string output, protocol;
    readonly Stopwatch clock=Stopwatch.StartNew();
    readonly Timer timer=new Timer();
    readonly HashSet<string> processed=new HashSet<string>();
    readonly JavaScriptSerializer json=new JavaScriptSerializer();
    bool ready, controllerA;
    int clicks, paints, seed, ticks;
    uint value;
    long flashUntil;
    SoundPlayer player;
    [StructLayout(LayoutKind.Sequential)] struct Pad { public ushort Buttons; public byte LeftTrigger,RightTrigger; public short LeftX,LeftY,RightX,RightY; }
    [StructLayout(LayoutKind.Sequential)] struct PadState { public uint Packet; public Pad Gamepad; }
    [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint index,out PadState state);

    NativeAppCanary(string[] args)
    {
        output=Option(args,"--out");protocol=Option(args,"--protocol");
        if(String.IsNullOrEmpty(output))throw new ArgumentException("--out is required");
        Directory.CreateDirectory(output);
        Text="Native application harness canary";ClientSize=new Size(1300,820);StartPosition=FormStartPosition.CenterScreen;
        DoubleBuffered=true;AutoScaleMode=AutoScaleMode.None;
        timer.Interval=25;timer.Tick+=Tick;timer.Start();
        if(Array.IndexOf(args,"--audio")>=0) { string wave=Path.Combine(output,"app-produced-tone.wav");WriteTone(wave);player=new SoundPlayer(wave); }
    }
    static string Option(string[] args,string key) { int i=Array.IndexOf(args,key);return i>=0 && i+1<args.Length?args[i+1]:null; }
    void Atomic(string path,object data)
    {
        string temporary=path+".tmp";File.WriteAllText(temporary,json.Serialize(data),new System.Text.UTF8Encoding(false));File.Move(temporary,path);
    }
    void Tick(object sender,EventArgs e)
    {
        if(!ready && clock.ElapsedMilliseconds>=1200) { ready=true;Invalidate();Atomic(Path.Combine(output,"ready.json"),new{ready=true});if(player!=null)player.PlayLooping(); }
        if(clock.ElapsedMilliseconds<flashUntil+100)Invalidate();
        for(uint index=0;index<4;index++) { PadState state;if(XInputGetState(index,out state)==0 && (state.Gamepad.Buttons&0x1000)!=0) { controllerA=true;string marker=Path.Combine(output,"controller-a.json");if(!File.Exists(marker))Atomic(marker,new{passed=true,backend="XInput",physicalXboxVerified=false}); } }
        if(!String.IsNullOrEmpty(protocol) && Directory.Exists(protocol))
        {
            foreach(string commandPath in Directory.GetFiles(protocol,"*.command.json"))
            {
                if(processed.Contains(commandPath))continue;
                var command=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(commandPath));
                string operation=(string)command["operation"];
                if(operation=="ready" && !ready)continue;
                bool ok=true;
                if(operation=="seed") { seed=Convert.ToInt32(command["seed"]);value=(uint)seed;ticks=0; }
                else if(operation=="advance") { int count=Convert.ToInt32(command["ticks"]);for(int i=0;i<count;i++) { value=unchecked(value*1664525U+1013904223U);ticks++; } }
                else if(operation!="ready" && operation!="checkpoint")ok=false;
                string id=(string)command["id"];
                Atomic(Path.Combine(protocol,id+".response.json"),new{protocol="codex-app-test-v1",requestId=(string)command["requestId"],id=id,operation=operation,ok=ok,state=new{seed=seed,ticks=ticks,value=value,clicks=clicks,paints=paints,controllerA=controllerA}});
                processed.Add(commandPath);
            }
        }
    }
    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);if(!ready)return;
        int scale=Math.Min(ClientSize.Width/LogicalWidth,ClientSize.Height/LogicalHeight),left=(ClientSize.Width-LogicalWidth*scale)/2,top=(ClientSize.Height-LogicalHeight*scale)/2;
        int x=(e.X-left)/scale,y=(e.Y-top)/scale;
        if(x>=0 && x<32 && y>=0 && y<32) { clicks++;flashUntil=clock.ElapsedMilliseconds+400;Invalidate(); }
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);e.Graphics.Clear(Color.Black);paints++;if(!ready)return;
        int scale=Math.Min(ClientSize.Width/LogicalWidth,ClientSize.Height/LogicalHeight);
        int left=(ClientSize.Width-LogicalWidth*scale)/2,top=(ClientSize.Height-LogicalHeight*scale)/2;
        e.Graphics.FillRectangle(Brushes.MidnightBlue,left,top,LogicalWidth*scale,LogicalHeight*scale);
        e.Graphics.FillRectangle(Brushes.Lime,left,top,32*scale,32*scale);
        e.Graphics.FillRectangle(Brushes.Magenta,left+160*scale,top+100*scale,32*scale,32*scale);
        if(clock.ElapsedMilliseconds<flashUntil)e.Graphics.FillRectangle(Brushes.Orange,left+64*scale,top+32*scale,32*scale,32*scale);
    }
    protected override void Dispose(bool disposing) { if(disposing) { timer.Dispose();if(player!=null){player.Stop();player.Dispose();} } base.Dispose(disposing); }
    static void WriteTone(string path)
    {
        const int rate=44100, samples=44100;
        using(BinaryWriter w=new BinaryWriter(File.Create(path)))
        {
            w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));w.Write(36+samples*2);w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));w.Write(16);w.Write((ushort)1);w.Write((ushort)1);w.Write(rate);w.Write(rate*2);w.Write((ushort)2);w.Write((ushort)16);w.Write(System.Text.Encoding.ASCII.GetBytes("data"));w.Write(samples*2);
            for(int i=0;i<samples;i++)w.Write((short)(Math.Sin(i*2*Math.PI*440/rate)*8000));
        }
    }
    [STAThread] static int Main(string[] args)
    {
        try { Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new NativeAppCanary(args));return 0; }
        catch(Exception e) { string output=Option(args,"--out");if(!String.IsNullOrEmpty(output))File.WriteAllText(Path.Combine(output,"canary-error.txt"),e.ToString());return 1; }
    }
}
