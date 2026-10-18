using System.Text;

namespace RoyalDynamicLighting;

public sealed record EneRamDevice(byte Address, string Firmware, string Manufacturer, int LedCount, byte DirectMode);
public sealed record EneProbeResult(byte Address, EneRamDevice? Device, string Status);
public sealed record EneIdentityDiagnostics(byte Address, string FirmwareHex, string ManufacturerHex,
    byte Config02, byte Config03);

/// <summary>Strict ENE V2 DRAM backend. No EEPROM, address remapping, SPD, or persistent writes.</summary>
public sealed class EneRam(IEneBus bus)
{
    // These are published ENE DRAM addresses. The shared 0x77 remap address and SPD 0x50-0x57 are excluded.
    private static readonly byte[] AddressPool = [0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x4F, 0x66, 0x67,
        0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76];
    public static IReadOnlyList<byte> CandidateAddresses { get; } = Array.AsReadOnly(AddressPool);
    public static IReadOnlyList<byte> DefaultProbeAddresses { get; } = Array.AsReadOnly<byte>([0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76]);
    private const string SupportedFirmware = "AUDA0-E6K5-0101";
    private readonly object gate = new();
    private readonly Dictionary<byte, EneRamDevice> validated = new();
    private readonly Dictionary<byte, Snapshot> snapshots = new();
    private sealed record Snapshot(byte DirectMode, byte[] Colors);
    public IReadOnlyList<EneProbeResult> LastProbeResults { get; private set; } = Array.Empty<EneProbeResult>();

    internal static void ValidateAddress(byte address)
    {
        if (!AddressPool.Contains(address))
            throw new ArgumentOutOfRangeException(nameof(address), $"0x{address:X2} is outside the supported ENE DRAM address pool.");
    }

    internal static bool IsReadableRegister(ushort register) =>
        register is >= 0x1000 and <= 0x100F or >= 0x1030 and <= 0x1044 or >= 0x1C00 and <= 0x1C3F
            or 0x8020 or >= 0x8100 and <= 0x812F;

    /// <summary>Only ENE address-pointer writes and register reads; never changes LED state.</summary>
    public IReadOnlyList<EneRamDevice> Detect(IEnumerable<byte> explicitAddresses)
    {
        ArgumentNullException.ThrowIfNull(explicitAddresses);
        byte[] addresses = explicitAddresses.Distinct().ToArray();
        foreach (byte address in addresses) ValidateAddress(address); // Validate everything before accessing hardware.
        lock (gate)
        {
            if (snapshots.Count != 0) throw new InvalidOperationException("Restore active controllers before detecting again.");
            validated.Clear();
            List<EneProbeResult> results = [];
            foreach (byte address in addresses)
            {
                try
                {
                    using var lease = bus.Acquire();
                    EneRamDevice device = ReadIdentity(address);
                    validated.Add(address, device);
                    results.Add(new(address, device, "Verified ENE V2 DRAM controller"));
                }
                catch (PawnIoException ex) when (ex.DeviceAbsent)
                { results.Add(new(address, null, "No response")); }
                catch (InvalidDataException ex)
                { results.Add(new(address, null, ex.Message)); }
                // Busy, denied, timeout, collision, and unexpected errors abort discovery.
            }
            LastProbeResults = results.AsReadOnly();
            return validated.Values.ToArray();
        }
    }

    private EneRamDevice ReadIdentity(byte address)
    {
        string firmware = ReadAscii(address, 0x1000, 16);
        if (firmware != SupportedFirmware)
            throw new InvalidDataException($"Unrecognized DRAM firmware '{firmware}'; no lighting writes permitted.");
        byte[] manufacturerBytes = ReadBytes(address, 0x1030, 21);
        if (Encoding.ASCII.GetString(manufacturerBytes).Contains("Micron", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Micron controller is not supported by this backend.");
        // On the user's AUDA DDR5 controllers this region contains identical binary
        // firmware bytes, rather than a vendor name. Preserve the full identity;
        // never invent a manufacturer or broaden firmware acceptance from it.
        int manufacturerEnd = Array.IndexOf(manufacturerBytes, (byte)0);
        if (manufacturerEnd < 0) manufacturerEnd = manufacturerBytes.Length;
        string manufacturer = manufacturerBytes.AsSpan(0, manufacturerEnd)
            .IndexOfAnyExceptInRange((byte)0x20, (byte)0x7E) < 0
            ? Encoding.ASCII.GetString(manufacturerBytes, 0, manufacturerEnd).TrimEnd()
            : "raw:" + Convert.ToHexString(manufacturerBytes);
        // AUDA0-E6K5-0101 uses config byte 2, not the GPU variants' byte 3.
        int count = bus.ReadRegister(address, 0x1C02);
        if (count is < 1 or > 16) throw new InvalidDataException($"Invalid ENE DRAM LED count {count}.");
        byte direct = bus.ReadRegister(address, 0x8020);
        if (direct > 1) throw new InvalidDataException($"Unknown direct-mode value 0x{direct:X2}.");
        return new(address, firmware, manufacturer, count, direct);
    }

    private string ReadAscii(byte address, ushort start, int length)
    {
        byte[] data = ReadBytes(address, start, length);
        int end = Array.IndexOf(data, (byte)0);
        if (end < 0) end = length;
        if (data.AsSpan(0, end).IndexOfAnyExceptInRange((byte)0x20, (byte)0x7E) >= 0)
            throw new InvalidDataException($"Controller identity at register 0x{start:X4} is not printable ASCII: {Convert.ToHexString(data)}.");
        return Encoding.ASCII.GetString(data, 0, end).TrimEnd();
    }

    private byte[] ReadBytes(byte address, ushort start, int length)
    {
        byte[] data = new byte[length];
        for (int i = 0; i < data.Length; i++) data[i] = bus.ReadRegister(address, (ushort)(start + i));
        return data;
    }

    // Raw identity registers only. This never adds a controller to the writable set.
    public EneIdentityDiagnostics DiagnoseIdentity(byte address)
    {
        ValidateAddress(address);
        lock (gate)
        {
            using var lease = bus.Acquire();
            return new(address, Convert.ToHexString(ReadBytes(address, 0x1000, 16)),
                Convert.ToHexString(ReadBytes(address, 0x1030, 21)),
                bus.ReadRegister(address, 0x1C02), bus.ReadRegister(address, 0x1C03));
        }
    }

    private void VerifyDevice(EneRamDevice device)
    {
        if (!validated.TryGetValue(device.Address, out EneRamDevice? actual) || actual != device)
            throw new InvalidOperationException("Controller must be detected by this backend before lighting writes.");
    }

    public void SendFrame(EneRamDevice device, ReadOnlySpan<RgbColor> colors)
    {
        ArgumentNullException.ThrowIfNull(device);
        if (colors.Length != device.LedCount) throw new ArgumentException("Frame must match the detected LED count.", nameof(colors));
        lock (gate)
        {
            VerifyDevice(device);
            using var lease = bus.Acquire(); // Holds the interprocess lock across every pointer, block and apply.
            if (!snapshots.ContainsKey(device.Address))
            {
                EneRamDevice current = ReadIdentity(device.Address);
                if (current.Firmware != device.Firmware || current.LedCount != device.LedCount || current.Manufacturer != device.Manufacturer)
                    throw new InvalidDataException("Controller identity changed; detection must be repeated.");
                byte[] before = new byte[device.LedCount * 3];
                for (int i = 0; i < before.Length; i++) before[i] = bus.ReadRegister(device.Address, (ushort)(0x8100 + i));
                snapshots.Add(device.Address, new(current.DirectMode, before));
            }
            byte[] wire = new byte[colors.Length * 3];
            for (int i = 0; i < colors.Length; i++)
            {
                wire[i * 3] = colors[i].R;
                wire[i * 3 + 1] = colors[i].B;
                wire[i * 3 + 2] = colors[i].G;
            }
            bus.WriteRegister(device.Address, 0x8020, 1);
            WriteColors(device.Address, wire);
            bus.WriteRegister(device.Address, 0x802F, 1);
        }
    }

    private void WriteColors(byte address, ReadOnlySpan<byte> bytes)
    {
        for (int offset = 0; offset < bytes.Length; offset += 15)
            bus.WriteBlock(address, (ushort)(0x8100 + offset), bytes.Slice(offset, Math.Min(15, bytes.Length - offset)));
    }

    public void Restore(EneRamDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        lock (gate)
        {
            VerifyDevice(device);
            if (!snapshots.TryGetValue(device.Address, out Snapshot? snapshot)) return;
            using var lease = bus.Acquire();
            EneRamDevice current = ReadIdentity(device.Address);
            if (current.Firmware != device.Firmware || current.LedCount != device.LedCount || current.Manufacturer != device.Manufacturer)
                throw new InvalidDataException("Controller identity changed; refusing to restore to a different device.");
            WriteColors(device.Address, snapshot.Colors);
            bus.WriteRegister(device.Address, 0x802F, 1);
            bus.WriteRegister(device.Address, 0x8020, snapshot.DirectMode);
            snapshots.Remove(device.Address);
        }
    }

    public void RestoreAll()
    {
        lock (gate)
        {
            List<Exception> errors = [];
            foreach (byte address in snapshots.Keys.ToArray())
            {
                try { Restore(validated[address]); }
                catch (Exception ex) { errors.Add(ex); }
            }
            if (errors.Count != 0) throw new AggregateException("One or more RAM lighting states could not be restored.", errors);
        }
    }
}
