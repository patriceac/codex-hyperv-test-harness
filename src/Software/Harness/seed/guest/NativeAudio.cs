using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Codex.NativeApp
{
    public sealed class AudioEndpoint { public string Id, Flow; public uint State; public bool IsDefault; }
    public sealed class AudioCapture
    {
        public string EndpointId, StartedUtc, CompletedUtc, StopReason, FormatHex;
        public int Channels, SampleRate, BitsPerSample, FormatTag, BlockAlign, PacketCount, Discontinuities, TimestampErrors;
        public long CapturedFrames, DataBytes;
        public ulong FirstDevicePosition, LastDevicePosition, FirstQpc100ns, LastQpc100ns;
        public double ElapsedMs, AudioDurationMs;
        public bool PlaybackPacketsObserved;
    }

    [ComImport,Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator {}
    [ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDevices
    {
        [PreserveSig] int EnumAudioEndpoints(int flow,uint state,out IDeviceCollection collection);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow,int role,out IDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)]string id,out IDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr callback);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr callback);
    }
    [ComImport,Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDeviceCollection { [PreserveSig] int GetCount(out uint count); [PreserveSig] int Item(uint index,out IDevice device); }
    [ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDevice
    {
        [PreserveSig] int Activate(ref Guid id,uint context,IntPtr parameters,[MarshalAs(UnmanagedType.IUnknown)]out object instance);
        [PreserveSig] int OpenPropertyStore(uint access,out IntPtr store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)]out string id);
        [PreserveSig] int GetState(out uint state);
    }
    [ComImport,Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        [PreserveSig] int Initialize(int mode,uint flags,long duration,long periodicity,IntPtr format,IntPtr session);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint frames);
        [PreserveSig] int IsFormatSupported(int mode,IntPtr format,out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod,out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid id,[MarshalAs(UnmanagedType.IUnknown)]out object service);
    }
    [ComImport,Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ICapture
    {
        [PreserveSig] int GetBuffer(out IntPtr data,out uint frames,out uint flags,out ulong position,out ulong qpc);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }

    public static class Audio
    {
        static void Check(int hr,string operation) { if(hr<0) throw new COMException(operation+" failed: 0x"+hr.ToString("X8"),hr); }
        static void Release(object value) { if(value!=null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }

        public static AudioEndpoint[] Endpoints()
        {
            IDevices devices=(IDevices)new MMDeviceEnumerator(); List<AudioEndpoint> result=new List<AudioEndpoint>();
            try
            {
                for(int flow=0;flow<2;flow++)
                {
                    string defaultId=null; IDevice current=null; IDeviceCollection collection=null;
                    try
                    {
                        if(devices.GetDefaultAudioEndpoint(flow,0,out current)>=0) Check(current.GetId(out defaultId),"Default endpoint identity");
                        Check(devices.EnumAudioEndpoints(flow,15,out collection),"Endpoint enumeration");
                        uint count; Check(collection.GetCount(out count),"Endpoint count");
                        if(count>256) throw new InvalidOperationException("Guest endpoint count exceeds 256.");
                        for(uint i=0;i<count;i++)
                        {
                            IDevice device=null;
                            try { Check(collection.Item(i,out device),"Endpoint"); string id;uint state;Check(device.GetId(out id),"Endpoint identity");Check(device.GetState(out state),"Endpoint state");result.Add(new AudioEndpoint{Id=id,Flow=flow==0?"Render":"Capture",State=state,IsDefault=id==defaultId}); }
                            finally { Release(device); }
                        }
                    }
                    finally { Release(current);Release(collection); }
                }
                return result.ToArray();
            }
            finally { Release(devices); }
        }

        public static AudioCapture Capture(string endpointId,int durationMs,long maximumBytes,string path)
        {
            if(durationMs<100 || durationMs>30000 || maximumBytes<1024 || maximumBytes>33554432) throw new ArgumentOutOfRangeException("capture bounds");
            IDevices devices=(IDevices)new MMDeviceEnumerator(); IDevice device=null; IAudioClient client=null; ICapture capture=null;
            IntPtr mix=IntPtr.Zero; bool started=false; AudioCapture result=new AudioCapture();
            try
            {
                if(String.IsNullOrEmpty(endpointId)) Check(devices.GetDefaultAudioEndpoint(0,0,out device),"No active default guest render endpoint");
                else
                {
                    bool found=false;foreach(AudioEndpoint endpoint in Endpoints()) if(endpoint.Id==endpointId && endpoint.Flow=="Render" && endpoint.State==1) found=true;
                    if(!found) throw new InvalidOperationException("Requested endpoint is not an active guest render endpoint.");
                    Check(devices.GetDevice(endpointId,out device),"Requested guest render endpoint");
                }
                Check(device.GetId(out result.EndpointId),"Render endpoint identity");
                Guid clientId=typeof(IAudioClient).GUID;object instance;Check(device.Activate(ref clientId,23,IntPtr.Zero,out instance),"WASAPI activation");client=(IAudioClient)instance;
                Check(client.GetMixFormat(out mix),"Mix format");
                int size=18+(ushort)Marshal.ReadInt16(mix,16); if(size>256) throw new InvalidOperationException("Mix format exceeds the bounded WAVEFORMATEX size.");
                byte[] format=new byte[size];Marshal.Copy(mix,format,0,size);
                result.FormatTag=BitConverter.ToUInt16(format,0);result.Channels=BitConverter.ToUInt16(format,2);result.SampleRate=BitConverter.ToInt32(format,4);
                result.BlockAlign=BitConverter.ToUInt16(format,12);result.BitsPerSample=BitConverter.ToUInt16(format,14);result.FormatHex=BitConverter.ToString(format);
                if(result.BlockAlign<1 || result.Channels<1 || result.Channels>32 || result.SampleRate<8000 || result.SampleRate>384000) throw new InvalidOperationException("Guest mix format exceeds supported bounds.");
                Check(client.Initialize(0,0x20000,10000000,0,mix,IntPtr.Zero),"Shared-mode WASAPI loopback initialize");
                Guid captureId=typeof(ICapture).GUID;object service;Check(client.GetService(ref captureId,out service),"Loopback capture service");capture=(ICapture)service;
                using(FileStream stream=new FileStream(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read))
                using(BinaryWriter writer=new BinaryWriter(stream))
                {
                    writer.Write(Encoding.ASCII.GetBytes("RIFF"));writer.Write(0);writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));writer.Write(size);writer.Write(format);
                    if((size&1)!=0) writer.Write((byte)0);
                    writer.Write(Encoding.ASCII.GetBytes("data"));long dataSizeOffset=stream.Position;writer.Write(0);long dataStart=stream.Position;
                    result.StartedUtc=DateTime.UtcNow.ToString("o"); Stopwatch watch=Stopwatch.StartNew();Check(client.Start(),"Loopback start");started=true;result.StopReason="Duration";
                    bool boundedStop=false;
                    while(watch.ElapsedMilliseconds<durationMs && !boundedStop)
                    {
                        uint packet;Check(capture.GetNextPacketSize(out packet),"Loopback packet size");
                        while(packet>0 && watch.ElapsedMilliseconds<durationMs)
                        {
                            IntPtr data;uint frames,flags;ulong position,qpc;Check(capture.GetBuffer(out data,out frames,out flags,out position,out qpc),"Loopback packet");
                            try
                            {
                                long byteCount=(long)frames*result.BlockAlign;
                                if(byteCount>1048576 || stream.Position+byteCount+((stream.Position+byteCount-dataStart)&1)>maximumBytes) { result.StopReason="EvidenceByteLimit";boundedStop=true;break; }
                                byte[] bytes=new byte[(int)byteCount];if((flags&2)==0) Marshal.Copy(data,bytes,0,bytes.Length);
                                writer.Write(bytes);
                                if(result.PacketCount==0) { result.FirstDevicePosition=position;result.FirstQpc100ns=qpc; }
                                result.LastDevicePosition=position;result.LastQpc100ns=qpc;result.PacketCount++;result.CapturedFrames+=frames;
                                if((flags&1)!=0)result.Discontinuities++;if((flags&4)!=0)result.TimestampErrors++;
                            }
                            finally { Check(capture.ReleaseBuffer(frames),"Loopback release packet"); }
                            Check(capture.GetNextPacketSize(out packet),"Loopback next packet");
                        }
                        if(!boundedStop) Thread.Sleep(5);
                    }
                    Check(client.Stop(),"Loopback stop");started=false;result.CompletedUtc=DateTime.UtcNow.ToString("o");result.ElapsedMs=watch.Elapsed.TotalMilliseconds;
                    result.DataBytes=stream.Length-dataStart;result.AudioDurationMs=(double)result.CapturedFrames*1000/result.SampleRate;result.PlaybackPacketsObserved=result.PacketCount>0;
                    if((result.DataBytes&1)!=0)writer.Write((byte)0);
                    stream.Position=4;writer.Write((int)(stream.Length-8));stream.Position=dataSizeOffset;writer.Write((int)result.DataBytes);writer.Flush();
                }
                return result;
            }
            finally { if(started && client!=null)client.Stop();if(mix!=IntPtr.Zero)Marshal.FreeCoTaskMem(mix);Release(capture);Release(client);Release(device);Release(devices); }
        }
    }
}
