using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

[assembly: InternalsVisibleTo("RoyalDynamicLighting.Tests")]

namespace RoyalDynamicLighting;

// The deliberately small interface exposes ENE lighting registers, not arbitrary SMBus writes.
public interface IEneBus
{
    IDisposable Acquire();
    byte ReadRegister(byte address, ushort register);
    void WriteRegister(byte address, ushort register, byte value);
    void WriteBlock(byte address, ushort register, ReadOnlySpan<byte> values);
}

public sealed class PawnIoException : IOException
{
    public int Status { get; }
    public bool DeviceAbsent => unchecked((uint)Status) == 0xC000000E;
    public PawnIoException(string operation, int status)
        : base($"{operation}: NTSTATUS 0x{unchecked((uint)status):X8} ({new Win32Exception((int)NativeStatusToError(status)).Message})")
    { Status = status; }

    [DllImport("ntdll.dll", EntryPoint = "RtlNtStatusToDosError")]
    private static extern uint NativeStatusToError(int status);
}

public sealed record PawnIoIdentity(string Controller, int Port, ushort IoBase, ushort VendorId,
    ushort DeviceId, ushort SubsystemVendorId, ushort SubsystemDeviceId);

/// <summary>Calls the installed PawnIOLib and the official signed SmbusPIIX4 module.</summary>
public sealed class PawnIo : IEneBus, IDisposable
{
    private const string MutexName = @"Global\Access_SMBUS.HTP.Method";
    private readonly object gate = new();
    private readonly Mutex busMutex;
    private readonly nint library;
    private readonly CloseDelegate close;
    private readonly ExecuteDelegate execute;
    private nint executor;
    private bool disposed;
    private int ownerThread;
    private readonly int port;
    public PawnIoIdentity Identity { get; }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int OpenDelegate(out nint handle);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int LoadDelegate(nint handle, [In] byte[] blob, nuint length);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int CloseDelegate(nint handle);
    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Ansi)]
    private delegate int ExecuteDelegate(nint handle, [MarshalAs(UnmanagedType.LPStr)] string name,
        [In] ulong[] input, nuint inputCount, [Out] ulong[] output, nuint outputCount, out nuint written);

    public PawnIo(string signedModulePath, string? pawnIoLibraryPath = null, int port = 0)
    {
        if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess)
            throw new PlatformNotSupportedException("PawnIO requires a 64-bit Windows process.");
        if (port is not (0 or 1)) throw new ArgumentOutOfRangeException(nameof(port));
        this.port = port;
        string dll = Path.GetFullPath(pawnIoLibraryPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PawnIO", "PawnIOLib.dll"));
        byte[] module = File.ReadAllBytes(Path.GetFullPath(signedModulePath));
        if (module.Length is < 64 or > 4_194_304) throw new InvalidDataException("Unexpected PawnIO module size.");
        busMutex = new Mutex(false, MutexName);
        try
        {
            library = NativeLibrary.Load(dll);
            close = Export<CloseDelegate>("pawnio_close_nt");
            execute = Export<ExecuteDelegate>("pawnio_execute_nt");
            Check(Export<OpenDelegate>("pawnio_open_nt")(out executor), "Open PawnIO (administrator access required)");
            Check(Export<LoadDelegate>("pawnio_load_nt")(executor, module, (nuint)module.Length), "Load signed SmbusPIIX4 module");
            using (Acquire())
            {
                // Long polling delays yield the CPU; short polling remains responsive.
                Execute("ioctl_set_sleep_mode", [1], 0);
                ulong[] id = Execute("ioctl_identity", [], 3);
                uint pci = (uint)id[2];
                if (pci != 0x790B1022) throw new InvalidDataException($"Unsupported SMBus PCI ID 0x{pci:X8}.");
                Identity = new("PIIX4", port, (ushort)id[1], (ushort)pci, (ushort)(pci >> 16),
                    (ushort)(id[2] >> 32), (ushort)(id[2] >> 48));
            }
        }
        catch
        {
            if (executor != 0 && close is not null) close(executor);
            if (library != 0) NativeLibrary.Free(library);
            busMutex.Dispose();
            throw;
        }
    }

    private T Export<T>(string name) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, name));

    public IDisposable Acquire()
    {
        Monitor.Enter(gate);
        bool acquired = false;
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (ownerThread != 0) throw new InvalidOperationException("Nested SMBus transactions are not supported.");
            try { acquired = busMutex.WaitOne(TimeSpan.FromSeconds(2)); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) throw new TimeoutException("SMBus is busy with another application.");
            ownerThread = Environment.CurrentManagedThreadId;
            int previous = checked((int)Execute("ioctl_piix4_port_sel", [unchecked((ulong)-1L)], 1)[0]);
            if (previous != port) Execute("ioctl_piix4_port_sel", [(ulong)port], 1);
            return new BusLease(this, previous);
        }
        catch
        {
            if (acquired)
            {
                ownerThread = 0;
                busMutex.ReleaseMutex();
            }
            Monitor.Exit(gate);
            throw;
        }
    }

    private sealed class BusLease(PawnIo bus, int previous) : IDisposable
    {
        private bool released;
        public void Dispose()
        {
            if (released) return;
            if (bus.ownerThread != Environment.CurrentManagedThreadId)
                throw new InvalidOperationException("SMBus transactions must finish on their acquiring thread.");
            released = true;
            try
            {
                if (previous != bus.port) bus.Execute("ioctl_piix4_port_sel", [(ulong)previous], 1);
            }
            finally
            {
                bus.ownerThread = 0;
                bus.busMutex.ReleaseMutex();
                Monitor.Exit(bus.gate);
            }
        }
    }

    private ulong[] Execute(string name, ulong[] input, int outputCount)
    {
        if (ownerThread != Environment.CurrentManagedThreadId)
            throw new InvalidOperationException("SMBus mutex must be held for the whole operation.");
        ulong[] output = new ulong[outputCount];
        Check(execute(executor, name, input, (nuint)input.Length, output, (nuint)output.Length, out nuint written), name);
        if (written != (nuint)outputCount) throw new IOException($"{name} returned {written} cells; expected {outputCount}.");
        return output;
    }

    private static void Check(int status, string operation)
    {
        if (status < 0) throw new PawnIoException(operation, status);
    }

    private void SelectRegister(byte address, ushort register)
    {
        EneRam.ValidateAddress(address);
        Execute("ioctl_smbus_xfer", [address, 0, 0x00, 3, BinaryPrimitives.ReverseEndianness(register)], 0);
    }

    public byte ReadRegister(byte address, ushort register)
    {
        if (!EneRam.IsReadableRegister(register)) throw new ArgumentOutOfRangeException(nameof(register));
        SelectRegister(address, register);
        ulong value = Execute("ioctl_smbus_xfer", [address, 1, 0x81, 2], 1)[0];
        if (value > byte.MaxValue) throw new InvalidDataException("Invalid SMBus byte response.");
        return (byte)value;
    }

    public void WriteRegister(byte address, ushort register, byte value)
    {
        if (!((register == 0x8020 && value <= 1) || (register == 0x802F && value == 1)))
            throw new ArgumentException("Only direct-mode selection and volatile frame apply are permitted.");
        SelectRegister(address, register);
        Execute("ioctl_smbus_xfer", [address, 0, 0x01, 2, value], 0);
    }

    public void WriteBlock(byte address, ushort register, ReadOnlySpan<byte> values)
    {
        if (values.Length is < 1 or > 15 || register < 0x8100 || register + values.Length > 0x8130)
            throw new ArgumentException("Write must remain within the ENE V2 volatile direct-color buffer.");
        SelectRegister(address, register);
        Execute("ioctl_smbus_xfer", PackBlockWrite(address, 0x03, values), 0);
    }

    internal static ulong[] PackBlockWrite(byte address, byte command, ReadOnlySpan<byte> values)
    {
        if (values.Length is < 1 or > 32) throw new ArgumentOutOfRangeException(nameof(values));
        ulong[] input = new ulong[9];
        input[0] = address;
        input[1] = 0;
        input[2] = command;
        input[3] = 5;
        Span<byte> data = stackalloc byte[40];
        data.Clear();
        data[0] = (byte)values.Length;
        values.CopyTo(data[1..]);
        for (int i = 0; i < 5; i++) input[4 + i] = BinaryPrimitives.ReadUInt64LittleEndian(data.Slice(i * 8, 8));
        return input;
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            if (ownerThread != 0) throw new InvalidOperationException("Cannot dispose during an SMBus transaction.");
            disposed = true;
            try { if (executor != 0) Check(close(executor), "Close PawnIO"); }
            finally
            {
                executor = 0;
                NativeLibrary.Free(library);
                busMutex.Dispose();
            }
        }
    }
}
