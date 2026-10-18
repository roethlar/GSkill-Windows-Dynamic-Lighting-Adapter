using System.Buffers.Binary;
using System.Text;
using RoyalDynamicLighting;

public static class EneRamTests
{
    public static void Run()
    {
        RejectsUnsafeAddressesBeforeIo();
        RejectsUnknownFirmware();
        AcceptsBinaryManufacturerOnlyForKnownDram();
        RejectsInvalidLedCounts();
        SendsRbgAndRestoresOriginalState(0);
        SendsRbgAndRestoresOriginalState(1);
        RejectsMismatchedFramesAndForgedDevices();
        EncodesPawnIoBlockCells();
        PartialFrameRemainsRestorable();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception("ENE test failure: " + message);
    }

    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new Exception($"Expected {typeof(T).Name}.");
    }

    private static void RejectsUnsafeAddressesBeforeIo()
    {
        FakeBus bus = new();
        EneRam ram = new(bus);
        foreach (byte address in new byte[] { 0, 0x40, 0x50, 0x51, 0x57, 0x77, 0x7F })
            Throws<ArgumentOutOfRangeException>(() => ram.Detect([0x71, address]));
        Check(bus.AcquireCount == 0, "Invalid address set reached hardware.");
    }

    private static void RejectsUnknownFirmware()
    {
        FakeBus bus = new();
        bus.SetString(0x1000, "AUMA0-E6K5-0107", 16); // Valid ENE GPU must not pass as DRAM.
        EneRam ram = new(bus);
        Check(ram.Detect([0x71]).Count == 0, "GPU signature was accepted.");
        Check(ram.LastProbeResults[0].Status.Contains("AUMA0-E6K5-0107"), "Unknown signature not reported.");
        Check(bus.Writes.Count == 0, "Detection performed lighting writes.");
    }

    private static void RejectsInvalidLedCounts()
    {
        foreach (byte count in new byte[] { 0, 17, 255 })
        {
            FakeBus bus = new();
            bus.Registers[0x1C02] = count;
            Check(new EneRam(bus).Detect([0x71]).Count == 0, "Invalid LED count accepted.");
            Check(bus.Writes.Count == 0, "Invalid LED count caused writes.");
        }
    }

    private static void AcceptsBinaryManufacturerOnlyForKnownDram()
    {
        FakeBus bus = new();
        const string raw = "08DFFA803E88828C83E709F0A3DFFA8032E309F608";
        byte[] bytes = Convert.FromHexString(raw);
        for (int i = 0; i < bytes.Length; i++) bus.Registers[(ushort)(0x1030 + i)] = bytes[i];
        EneRam ram = new(bus);
        Check(ram.Detect([0x71]).Single().Manufacturer == "raw:" + raw, "Binary identity was not preserved verbatim.");
        bus.SetString(0x1000, "AUMA0-E6K5-0107", 16);
        Check(ram.Detect([0x71]).Count == 0, "Binary identity broadened firmware acceptance.");
        Check(bus.Writes.Count == 0, "Binary identity detection changed lighting.");
        bus.SetString(0x1000, "AUDA0-E6K5-0101", 16);
        bus.SetString(0x1030, "Micron", 21);
        Check(ram.Detect([0x71]).Count == 0, "Micron exclusion was lost.");
    }

    private static void SendsRbgAndRestoresOriginalState(byte initialDirect)
    {
        FakeBus bus = new();
        bus.Registers[0x8020] = initialDirect;
        byte[] before = Enumerable.Range(0, 24).Select(i => (byte)(i + 100)).ToArray();
        for (int i = 0; i < before.Length; i++) bus.Registers[(ushort)(0x8100 + i)] = before[i];
        EneRam ram = new(bus);
        EneRamDevice device = ram.Detect([0x71]).Single();
        Check(bus.Writes.Count == 0, "Detection changed lighting state.");
        var frame = Enumerable.Range(0, 8).Select(i => new RgbColor((byte)i, (byte)(10 + i), (byte)(20 + i))).ToArray();
        int leases = bus.AcquireCount;
        ram.SendFrame(device, frame);
        Check(bus.AcquireCount == leases + 1, "Frame did not use one bus lease.");
        Check(bus.Writes.Count == 4, "Eight LED frame should use mode + two color blocks + apply.");
        Check(bus.Writes[0].Register == 0x8020 && bus.Writes[0].Data.SequenceEqual(new byte[] { 1 }), "Direct mode not selected.");
        Check(bus.Writes[1].Register == 0x8100 && bus.Writes[1].Data.Length == 15, "First block has wrong boundary.");
        Check(bus.Writes[2].Register == 0x810F && bus.Writes[2].Data.Length == 9, "Second block has wrong boundary.");
        Check(bus.Writes[1].Data.Take(3).SequenceEqual(new byte[] { 0, 20, 10 }), "RGB was not reordered to RBG.");
        Check(bus.Writes[3].Register == 0x802F, "Frame wasn't applied last.");
        ram.SendFrame(device, Enumerable.Repeat(new RgbColor(255, 0, 0), 8).ToArray());
        ram.RestoreAll();
        Check(bus.Registers[0x8020] == initialDirect, "Original direct mode was not restored.");
        Check(Enumerable.Range(0, 24).Select(i => bus.Registers[(ushort)(0x8100 + i)]).SequenceEqual(before), "Original colors weren't restored.");
        Check(bus.Writes.All(w => w.Register == 0x8020 || w.Register == 0x802F || w.Register is >= 0x8100 and <= 0x812F), "Unexpected register written.");
        Check(bus.Writes.All(w => w.Address == 0x71), "Unexpected device written.");
        int writes = bus.Writes.Count;
        ram.RestoreAll();
        Check(bus.Writes.Count == writes, "Repeated restore performed writes.");
    }

    private static void RejectsMismatchedFramesAndForgedDevices()
    {
        FakeBus bus = new();
        EneRam ram = new(bus);
        EneRamDevice device = ram.Detect([0x71]).Single();
        int leases = bus.AcquireCount;
        Throws<ArgumentException>(() => ram.SendFrame(device, new RgbColor[7]));
        Throws<InvalidOperationException>(() => ram.SendFrame(device with { Address = 0x72 }, new RgbColor[8]));
        Check(bus.AcquireCount == leases, "Invalid frame/controller reached hardware.");
        bus.SetString(0x1000, "DIFFERENT", 16);
        Throws<InvalidDataException>(() => ram.SendFrame(device, new RgbColor[8]));
        Check(bus.Writes.Count == 0, "Changed identity caused lighting writes.");
    }

    private static void EncodesPawnIoBlockCells()
    {
        byte[] bytes = Enumerable.Range(1, 15).Select(i => (byte)i).ToArray();
        ulong[] cells = PawnIo.PackBlockWrite(0x71, 3, bytes);
        Check(cells.Length == 9, "Block transfer must contain nine cells.");
        Check(cells.Take(4).SequenceEqual(new ulong[] { 0x71, 0, 3, 5 }), "Wrong block transfer header.");
        byte[] payload = new byte[40];
        for (int i = 0; i < 5; i++) BinaryPrimitives.WriteUInt64LittleEndian(payload.AsSpan(i * 8), cells[4 + i]);
        Check(payload[0] == 15 && payload.AsSpan(1, 15).SequenceEqual(bytes), "Block payload length/data ordering incorrect.");
        Check(payload.Skip(16).All(v => v == 0), "Block payload padding uninitialized.");
        Throws<ArgumentOutOfRangeException>(() => PawnIo.PackBlockWrite(0x71, 3, new byte[33]));
    }

    private static void PartialFrameRemainsRestorable()
    {
        FakeBus bus = new();
        EneRam ram = new(bus);
        EneRamDevice device = ram.Detect([0x71]).Single();
        bus.FailOnWrite = 2;
        Throws<IOException>(() => ram.SendFrame(device, new RgbColor[8]));
        Check(!bus.Locked, "Failed frame leaked bus lease.");
        bus.FailOnWrite = 0;
        ram.RestoreAll();
        Check(bus.Registers[0x8020] == 0, "Failed frame lost restore snapshot.");
    }

    private sealed class FakeBus : IEneBus
    {
        public Dictionary<ushort, byte> Registers { get; } = new();
        public List<(byte Address, ushort Register, byte[] Data)> Writes { get; } = [];
        public bool Locked { get; private set; }
        public int AcquireCount { get; private set; }
        public int FailOnWrite { get; set; }
        public FakeBus()
        {
            SetString(0x1000, "AUDA0-E6K5-0101", 16);
            SetString(0x1030, "G.Skill", 21);
            Registers[0x1C02] = 8;
            Registers[0x8020] = 0;
        }
        public void SetString(ushort start, string value, int length)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(value);
            for (int i = 0; i < length; i++) Registers[(ushort)(start + i)] = i < bytes.Length ? bytes[i] : (byte)0;
        }
        public IDisposable Acquire()
        {
            Check(!Locked, "Nested bus lock.");
            Locked = true;
            AcquireCount++;
            return new Lease(this);
        }
        private sealed class Lease(FakeBus bus) : IDisposable { public void Dispose() { bus.Locked = false; } }
        public byte ReadRegister(byte address, ushort register)
        {
            Check(Locked, "Register read outside mutex.");
            return Registers.GetValueOrDefault(register);
        }
        public void WriteRegister(byte address, ushort register, byte value) => WriteBlock(address, register, new[] { value });
        public void WriteBlock(byte address, ushort register, ReadOnlySpan<byte> values)
        {
            Check(Locked, "Write outside mutex.");
            if (FailOnWrite != 0 && Writes.Count + 1 == FailOnWrite) throw new IOException("Simulated transaction failure.");
            Writes.Add((address, register, values.ToArray()));
            for (int i = 0; i < values.Length; i++) Registers[(ushort)(register + i)] = values[i];
        }
    }
}
