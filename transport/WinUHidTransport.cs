using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

namespace RoyalDynamicLighting.Transport;

/// <summary>
/// Hosts feature-report-only HID devices using the MIT-licensed WinUHid UMDF driver.
/// Report buffers include their HID report ID as the first byte.
/// </summary>
public sealed class WinUHidTransport : IDisposable
{
    private const int MaxReportLength = 65535;
    private readonly object lifecycle = new();
    private readonly Func<byte, int, byte[]> getFeature;
    private readonly Action<byte[]> setFeature;
    private IntPtr device;
    private Thread? worker;
    private volatile bool stopping;
    private bool disposed;

    // This executes on the report thread. Keep handlers short; do not call Dispose here.
    public event Action<Exception>? ReportError;

    public WinUHidTransport(byte[] reportDescriptor, string instanceId,
        Func<byte, int, byte[]> getFeature, Action<byte[]> setFeature)
    {
        ArgumentNullException.ThrowIfNull(reportDescriptor);
        ArgumentNullException.ThrowIfNull(instanceId);
        this.getFeature = getFeature ?? throw new ArgumentNullException(nameof(getFeature));
        this.setFeature = setFeature ?? throw new ArgumentNullException(nameof(setFeature));
        if (reportDescriptor.Length is 0 or > ushort.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(reportDescriptor));
        if (instanceId.Length is 0 or > 200 || instanceId.IndexOf('\0') >= 0)
            throw new ArgumentException("Use a nonempty stable instance ID without embedded nulls.", nameof(instanceId));

        var pinnedDescriptor = GCHandle.Alloc(reportDescriptor, GCHandleType.Pinned);
        var instance = Marshal.StringToHGlobalUni(instanceId);
        try
        {
            var config = new Native.DeviceConfig
            {
                SupportedEvents = Native.GetFeature | Native.SetFeature,
                // Locally defined virtual device identity; no physical vendor is impersonated.
                VendorId = 0,
                ProductId = 0x524C,
                VersionNumber = 0x0100,
                ReportDescriptorLength = (ushort)reportDescriptor.Length,
                ReportDescriptor = pinnedDescriptor.AddrOfPinnedObject(),
                ContainerId = new Guid("6d655f6a-5aa5-4681-bb6e-c86f8965f594"),
                InstanceId = instance,
            };
            device = Native.WinUHidCreateDevice(ref config);
            if (device == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Cannot create the RAM lighting HID device. Install the WinUHid UMDF package and run elevated.");
        }
        finally
        {
            Marshal.FreeHGlobal(instance);
            pinnedDescriptor.Free();
        }
    }

    /// <summary>Zero means unavailable; error contains the Win32 reason.</summary>
    public static uint GetDriverVersion(out int error)
    {
        var version = Native.WinUHidGetDriverInterfaceVersion();
        error = version == 0 ? Marshal.GetLastWin32Error() : 0;
        return version;
    }

    public void Start()
    {
        lock (lifecycle)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (worker != null) throw new InvalidOperationException("Transport already started.");
            if (!Native.WinUHidStartDevice(device, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot start the virtual HID device.");
            worker = new Thread(PollReports) { IsBackground = true, Name = "Royal LampArray HID" };
            worker.Start();
        }
    }

    private void PollReports()
    {
        while (!stopping)
        {
            var request = Native.WinUHidPollEvent(device, 250);
            if (request == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                if (stopping) break;
                if (error == 1460) continue; // ERROR_TIMEOUT, the ordinary idle poll result.
                try { ReportError?.Invoke(new Win32Exception(error, "Virtual HID request polling stopped.")); }
                catch { }
                stopping = true;
                break;
            }

            // WINUHID_EVENT is packed to one byte: type(4), id(4), report(1), length(4), data.
            var type = unchecked((uint)Marshal.ReadInt32(request, 0));
            var reportId = Marshal.ReadByte(request, 8);
            var length = unchecked((uint)Marshal.ReadInt32(request, 9));
            try
            {
                if (length == 0 || length > MaxReportLength)
                    throw new InvalidOperationException("WinUHid supplied an invalid feature-report length.");

                if (type == Native.GetFeature)
                {
                    var data = getFeature(reportId, (int)length);
                    if (data.Length != length || data[0] != reportId)
                        throw new InvalidOperationException("Feature response must match the requested length and report ID.");
                    var pin = GCHandle.Alloc(data, GCHandleType.Pinned);
                    try { Native.WinUHidCompleteReadEvent(device, request, pin.AddrOfPinnedObject(), length); }
                    finally { pin.Free(); }
                }
                else if (type == Native.SetFeature)
                {
                    var data = new byte[length];
                    Marshal.Copy(IntPtr.Add(request, 13), data, 0, data.Length);
                    if (data[0] != reportId)
                        throw new InvalidOperationException("WinUHid feature report ID does not match its payload.");
                    setFeature(data);
                    Native.WinUHidCompleteWriteEvent(device, request, true);
                }
                else
                {
                    throw new InvalidOperationException("Received an unrequested HID event type.");
                }
            }
            catch (Exception error)
            {
                if (type is Native.GetFeature or Native.ReadReport)
                    Native.WinUHidCompleteReadEvent(device, request, IntPtr.Zero, 0);
                else
                    Native.WinUHidCompleteWriteEvent(device, request, false);
                try { ReportError?.Invoke(error); }
                catch { /* Consumer logging must not terminate the native request worker. */ }
            }
        }
    }

    public void Dispose()
    {
        lock (lifecycle)
        {
            if (disposed) return;
            if (Thread.CurrentThread == worker)
                throw new InvalidOperationException("Dispose the HID transport from its owning thread.");
            disposed = true;
            stopping = true;
            if (device == IntPtr.Zero) return;
            Native.WinUHidStopDevice(device);
            worker?.Join();
            Native.WinUHidDestroyDevice(device);
            device = IntPtr.Zero;
        }
    }

    internal static class Native
    {
        internal const uint GetFeature = 1, SetFeature = 2, ReadReport = 8;

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        internal struct DeviceConfig
        {
            internal uint SupportedEvents;
            internal ushort VendorId, ProductId, VersionNumber, ReportDescriptorLength;
            internal IntPtr ReportDescriptor;
            internal Guid ContainerId;
            internal IntPtr InstanceId, HardwareIds;
            internal uint ReadReportPeriodUs;
        }

        [DllImport("WinUHid.dll", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
        internal static extern uint WinUHidGetDriverInterfaceVersion();
        [DllImport("WinUHid.dll", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
        internal static extern IntPtr WinUHidCreateDevice(ref DeviceConfig config);
        [DllImport("WinUHid.dll", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool WinUHidStartDevice(IntPtr device, IntPtr callback, IntPtr context);
        [DllImport("WinUHid.dll", CallingConvention = CallingConvention.Cdecl, SetLastError = true)]
        internal static extern IntPtr WinUHidPollEvent(IntPtr device, uint timeoutMilliseconds);
        [DllImport("WinUHid.dll", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void WinUHidCompleteReadEvent(IntPtr device, IntPtr request, IntPtr data, uint length);
        [DllImport("WinUHid.dll", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void WinUHidCompleteWriteEvent(IntPtr device, IntPtr request, [MarshalAs(UnmanagedType.Bool)] bool success);
        [DllImport("WinUHid.dll", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void WinUHidStopDevice(IntPtr device);
        [DllImport("WinUHid.dll", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void WinUHidDestroyDevice(IntPtr device);
    }
}
