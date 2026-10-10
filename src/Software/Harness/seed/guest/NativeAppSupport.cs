using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace Codex.NativeApp
{
    public sealed class Geometry
    {
        public int WindowX, WindowY, WindowWidth, WindowHeight;
        public int ClientX, ClientY, ClientWidth, ClientHeight;
        public int ViewportX, ViewportY, ViewportWidth, ViewportHeight;
        public int LogicalWidth, LogicalHeight;
        public uint Dpi;
        public string Scaling;
        public double ScaleX, ScaleY;
    }

    public sealed class Frame : IDisposable
    {
        public Geometry Geometry;
        public Bitmap Bitmap;
        public DateTime StartedUtc, CompletedUtc;
        public byte[] Pixels;
        public int Width { get { return Bitmap.Width; } }
        public int Height { get { return Bitmap.Height; } }
        public void Dispose() { if (Bitmap != null) Bitmap.Dispose(); }
    }

    public sealed class Comparison
    {
        public bool Passed;
        public long ComparedPixels, MismatchedPixels;
        public double MismatchFraction, MeanAbsoluteChannelError;
        public int MaximumChannelError;
    }

    public static class Visual
    {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
        [DllImport("user32.dll", SetLastError=true)] static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll", SetLastError=true)] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll", SetLastError=true)] static extern bool ClientToScreen(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

        public static Geometry Measure(IntPtr window, int width, int height, string scaling)
        {
            IntPtr prior = SetThreadDpiAwarenessContext(new IntPtr(-4));
            if (prior == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Could not establish physical-pixel DPI coordinates.");
            try
            {
                RECT client, outer; POINT origin = new POINT();
                if (!IsWindowVisible(window) || IsIconic(window)) throw new InvalidOperationException("Target window must be visible and restored.");
                if (GetForegroundWindow() != window) throw new InvalidOperationException("Target window is not the foreground window; refusing ambiguous capture/input.");
                if (!GetClientRect(window, out client) || !GetWindowRect(window, out outer) || !ClientToScreen(window, ref origin)) throw new Win32Exception();
                int cw = client.Right - client.Left, ch = client.Bottom - client.Top;
                if (cw < 1 || ch < 1 || (long)cw * ch > 8388608) throw new InvalidOperationException("Client size is empty or exceeds 8388608 pixels.");
                Geometry g = Layout(cw, ch, width, height, scaling);
                g.WindowX = outer.Left; g.WindowY = outer.Top; g.WindowWidth = outer.Right - outer.Left; g.WindowHeight = outer.Bottom - outer.Top;
                g.ClientX = origin.X; g.ClientY = origin.Y; g.ViewportX += origin.X; g.ViewportY += origin.Y;
                g.Dpi = GetDpiForWindow(window);
                Rectangle desktop = System.Windows.Forms.SystemInformation.VirtualScreen;
                if (!desktop.Contains(new Rectangle(g.ClientX, g.ClientY, cw, ch))) throw new InvalidOperationException("Client area extends outside the visible guest desktop.");
                return g;
            }
            finally { if (prior != IntPtr.Zero) SetThreadDpiAwarenessContext(prior); }
        }

        // Pure geometry used by both capture and input; ties put the spare pixel on the right/bottom.
        public static Geometry Layout(int cw, int ch, int width, int height, string scaling)
        {
            if (cw < 1 || ch < 1 || cw > 8192 || ch > 8192) throw new ArgumentOutOfRangeException("client");
            if (width == 0 && height == 0) { width = cw; height = ch; scaling = "client"; }
            if (width < 1 || height < 1 || (long)width * height > 8388608) throw new ArgumentOutOfRangeException("viewport");
            int vw = cw, vh = ch;
            if (scaling == "integer_fit" || scaling == "fit")
            {
                double scale = Math.Min((double)cw / width, (double)ch / height);
                if (scaling == "integer_fit") { scale = Math.Floor(scale); if (scale < 1) throw new InvalidOperationException("Client is smaller than the integer viewport."); }
                vw = Math.Max(1, (int)Math.Floor(width * scale)); vh = Math.Max(1, (int)Math.Floor(height * scale));
            }
            else if (scaling != "stretch" && scaling != "client") throw new ArgumentException("Unknown scaling rule.");
            return new Geometry { ClientWidth=cw, ClientHeight=ch, ViewportX=(cw-vw)/2, ViewportY=(ch-vh)/2,
                ViewportWidth=vw, ViewportHeight=vh, LogicalWidth=width, LogicalHeight=height,
                ScaleX=(double)vw/width, ScaleY=(double)vh/height, Scaling=scaling };
        }

        public static Point MapPoint(Geometry g, int x, int y)
        {
            if (x < 0 || x >= g.LogicalWidth || y < 0 || y >= g.LogicalHeight) throw new ArgumentOutOfRangeException("point", "Point is outside the measured client/viewport.");
            return new Point(g.ViewportX + (int)Math.Floor((x + 0.5) * g.ScaleX), g.ViewportY + (int)Math.Floor((y + 0.5) * g.ScaleY));
        }

        public static byte[] ReadPixels(Bitmap bitmap)
        {
            Rectangle r = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
            BitmapData d = bitmap.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                byte[] data = new byte[bitmap.Width * bitmap.Height * 4];
                for (int y=0; y<bitmap.Height; y++) Marshal.Copy(IntPtr.Add(d.Scan0, y*d.Stride), data, y*bitmap.Width*4, bitmap.Width*4);
                return data;
            }
            finally { bitmap.UnlockBits(d); }
        }

        static Bitmap FromPixels(byte[] bytes, int width, int height)
        {
            Bitmap b = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            BitmapData d = b.LockBits(new Rectangle(0,0,width,height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try { for (int y=0; y<height; y++) Marshal.Copy(bytes, y*width*4, IntPtr.Add(d.Scan0,y*d.Stride), width*4); }
            finally { b.UnlockBits(d); }
            return b;
        }

        public static Frame Capture(IntPtr window, int width, int height, string scaling, int x, int y, int rw, int rh)
        {
            DateTime started = DateTime.UtcNow;
            Geometry g = Measure(window,width,height,scaling);
            if (rw == 0 && rh == 0) { rw = g.LogicalWidth; rh = g.LogicalHeight; }
            if (x<0 || y<0 || rw<1 || rh<1 || (long)x+rw>g.LogicalWidth || (long)y+rh>g.LogicalHeight) throw new ArgumentOutOfRangeException("region", "Region is outside the measured client/viewport.");
            byte[] source;
            IntPtr prior = SetThreadDpiAwarenessContext(new IntPtr(-4));
            if (prior == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Could not establish capture DPI coordinates.");
            try
            {
                using (Bitmap physical = new Bitmap(g.ViewportWidth,g.ViewportHeight,PixelFormat.Format32bppArgb))
                {
                    using (Graphics graphics = Graphics.FromImage(physical)) graphics.CopyFromScreen(g.ViewportX,g.ViewportY,0,0,physical.Size,CopyPixelOperation.SourceCopy);
                    source = ReadPixels(physical);
                }
            }
            finally { if (prior != IntPtr.Zero) SetThreadDpiAwarenessContext(prior); }
            DateTime completed = DateTime.UtcNow;
            byte[] target = new byte[rw*rh*4];
            for (int row=0; row<rh; row++)
                for (int col=0; col<rw; col++)
                {
                    int sy=(int)Math.Floor((y+row+0.5)*g.ScaleY), sx=(int)Math.Floor((x+col+0.5)*g.ScaleX);
                    int from=(sy*g.ViewportWidth+sx)*4, to=(row*rw+col)*4;
                    target[to]=source[from]; target[to+1]=source[from+1]; target[to+2]=source[from+2]; target[to+3]=255;
                }
            return new Frame { Geometry=g, Bitmap=FromPixels(target,rw,rh), Pixels=target, StartedUtc=started, CompletedUtc=completed };
        }

        public static void SavePng(Bitmap image, string path, long maximumBytes)
        {
            using (MemoryStream stream = new MemoryStream())
            {
                image.Save(stream, ImageFormat.Png);
                if (stream.Length > maximumBytes) throw new InvalidOperationException("EvidenceByteLimit: PNG exceeds the remaining evidence budget.");
                using (FileStream file = new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read)) { stream.Position=0; stream.CopyTo(file); }
            }
        }

        public static Comparison Compare(Frame actual, string referencePath, Rectangle[] masks, int tolerance, double maxMismatch, string referenceCopy, string diffPath)
        {
            FileInfo file = new FileInfo(referencePath);
            if (file.Length < 1 || file.Length > 33554432) throw new InvalidOperationException("Reference PNG size must be 1..33554432 bytes.");
            // Reject decompression-sized images before GDI+ allocates their pixels.
            using (FileStream stream=File.OpenRead(referencePath))
            {
                byte[] header=new byte[24];byte[] signature={137,80,78,71,13,10,26,10};
                if(stream.Read(header,0,header.Length)!=header.Length) throw new InvalidOperationException("Incomplete reference PNG header.");
                for(int i=0;i<signature.Length;i++) if(header[i]!=signature[i]) throw new InvalidOperationException("Reference is not a PNG.");
                uint w=((uint)header[16]<<24)|((uint)header[17]<<16)|((uint)header[18]<<8)|header[19];
                uint h=((uint)header[20]<<24)|((uint)header[21]<<16)|((uint)header[22]<<8)|header[23];
                if(w!=actual.Width || h!=actual.Height) throw new InvalidOperationException("Reference dimensions must exactly match the normalized region.");
            }
            using (Bitmap reference = new Bitmap(referencePath))
            {
                if (reference.RawFormat.Guid != ImageFormat.Png.Guid || reference.Width != actual.Width || reference.Height != actual.Height) throw new InvalidOperationException("Reference must be a PNG with exactly the normalized region dimensions.");
                byte[] expected = ReadPixels(reference), diff = new byte[actual.Pixels.Length];
                foreach (Rectangle mask in masks) if (mask.Width<1 || mask.Height<1 || !new Rectangle(0,0,actual.Width,actual.Height).Contains(mask)) throw new ArgumentException("Mask extends outside the compared region.");
                Comparison result = new Comparison(); long totalError=0;
                for (int y=0; y<actual.Height; y++) for (int x=0; x<actual.Width; x++)
                {
                    int i=(y*actual.Width+x)*4; diff[i+3]=255;
                    bool masked=false; foreach (Rectangle mask in masks) if (mask.Contains(x,y)) { masked=true; break; }
                    if (masked) { diff[i]=128; continue; }
                    result.ComparedPixels++; int delta=0;
                    for (int channel=0; channel<3; channel++) { int error=Math.Abs(actual.Pixels[i+channel]-expected[i+channel]); totalError+=error; delta=Math.Max(delta,error); }
                    result.MaximumChannelError=Math.Max(result.MaximumChannelError,delta);
                    if (delta>tolerance) { result.MismatchedPixels++; diff[i+2]=255; }
                    else { byte gray=(byte)(actual.Pixels[i+1]/4); diff[i]=gray; diff[i+1]=gray; diff[i+2]=gray; }
                }
                if (result.ComparedPixels==0) throw new InvalidOperationException("Masks exclude every pixel.");
                result.MismatchFraction=(double)result.MismatchedPixels/result.ComparedPixels;
                result.MeanAbsoluteChannelError=(double)totalError/(result.ComparedPixels*3);
                result.Passed=result.MismatchFraction<=maxMismatch;
                if (!String.IsNullOrEmpty(referenceCopy)) SavePng(reference,referenceCopy,33554432);
                if (!String.IsNullOrEmpty(diffPath)) using (Bitmap b=FromPixels(diff,actual.Width,actual.Height)) SavePng(b,diffPath,33554432);
                return result;
            }
        }

        public static bool PixelMatches(Frame frame, int x, int y, int rgb, int tolerance)
        {
            if (x<0 || x>=frame.Width || y<0 || y>=frame.Height) throw new ArgumentOutOfRangeException("pixel");
            int i=(y*frame.Width+x)*4;
            return Math.Abs(frame.Pixels[i]-(rgb&255))<=tolerance && Math.Abs(frame.Pixels[i+1]-((rgb>>8)&255))<=tolerance && Math.Abs(frame.Pixels[i+2]-((rgb>>16)&255))<=tolerance;
        }

        public static double FractionDifferent(Frame frame, int rgb, int tolerance)
        {
            long different=0;
            for (int i=0; i<frame.Pixels.Length; i+=4)
                if (Math.Abs(frame.Pixels[i]-(rgb&255))>tolerance || Math.Abs(frame.Pixels[i+1]-((rgb>>8)&255))>tolerance || Math.Abs(frame.Pixels[i+2]-((rgb>>16)&255))>tolerance) different++;
            return (double)different/(frame.Width*frame.Height);
        }
    }
}
