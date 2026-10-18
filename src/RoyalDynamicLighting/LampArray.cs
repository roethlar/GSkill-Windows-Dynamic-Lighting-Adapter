using System;
using System.Buffers.Binary;
using System.Collections.Generic;

namespace RoyalDynamicLighting;

public readonly record struct RgbColor(byte R, byte G, byte B);

/// <summary>
/// Managed HID Lighting and Illumination (usage page 0x59) endpoint.
/// Reports include the report ID in byte zero and use little-endian fields.
/// Protocol reference: https://www.usb.org/sites/default/files/hutrr84_-_lighting_and_illumination_page.pdf
/// The report layout is also demonstrated by Microsoft's RP2040MacropadHidSample.
/// This implementation and descriptor generator are written independently.
/// </summary>
public sealed class LampArray
{
    public const byte ArrayAttributesReport = 1;
    public const byte LampAttributesRequestReport = 2;
    public const byte LampAttributesResponseReport = 3;
    public const byte MultiUpdateReport = 4;
    public const byte RangeUpdateReport = 5;
    public const byte ControlReport = 6;
    public const int MultiUpdateCapacity = 8;
    public const int MaximumFeatureReportLength = 51;

    private const byte UpdateComplete = 1;
    private readonly object gate = new();
    private readonly int lampsPerStick;
    private readonly RgbColor[] staged;
    private readonly RgbColor[] committed;
    private readonly byte[] descriptor;
    private ushort nextLampId;
    private bool autonomousMode = true;

    public LampArray(int lampCount = 16, int lampsPerStick = 8,
        uint minUpdateIntervalMicroseconds = 33_333)
    {
        if (lampCount is < 1 or > ushort.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(lampCount));
        if (lampsPerStick is < 1 or > ushort.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(lampsPerStick));
        if (minUpdateIntervalMicroseconds is 0 or > int.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(minUpdateIntervalMicroseconds));

        LampCount = lampCount;
        this.lampsPerStick = lampsPerStick;
        MinUpdateIntervalMicroseconds = minUpdateIntervalMicroseconds;
        staged = new RgbColor[lampCount];
        committed = new RgbColor[lampCount];
        descriptor = BuildDescriptor();
    }

    public int LampCount { get; }
    public uint MinUpdateIntervalMicroseconds { get; }

    // Return a copy so callers cannot mutate the descriptor after publication.
    public byte[] ReportDescriptor => (byte[])descriptor.Clone();
    public bool AutonomousMode { get { lock (gate) return autonomousMode; } }

    /// <summary>
    /// A committed, brightness-scaled frame. Callbacks are synchronous and serialized
    /// with report handling; enqueue hardware work promptly. The array is a snapshot
    /// and can be retained or modified without changing protocol state.
    /// </summary>
    public event Action<RgbColor[]>? FrameReady;

    /// <summary>True releases host control; false requests that autonomous effects pause.</summary>
    public event Action<bool>? AutonomousModeChanged;

    public static int GetReportLength(byte reportId) => reportId switch
    {
        ArrayAttributesReport => 23,
        LampAttributesRequestReport => 3,
        LampAttributesResponseReport => 29,
        MultiUpdateReport => MaximumFeatureReportLength,
        RangeUpdateReport => 10,
        ControlReport => 2,
        _ => throw new ArgumentOutOfRangeException(nameof(reportId), "Unknown LampArray report.")
    };

    /// <summary>
    /// Returns a complete feature report, zero-padded to the transport's requested
    /// length. Rejecting short buffers before state changes preserves enumeration.
    /// </summary>
    public byte[] GetFeature(byte reportId, int requestedLength)
    {
        int reportLength = GetReportLength(reportId);
        if (requestedLength < reportLength || requestedLength > ushort.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(requestedLength), "Invalid feature report buffer size.");
        if (reportId is MultiUpdateReport or RangeUpdateReport)
            throw new ArgumentException("Lamp updates are write-only reports.", nameof(reportId));

        lock (gate)
        {
            byte[] report = new byte[requestedLength];
            report[0] = reportId;
            switch (reportId)
            {
                case ArrayAttributesReport:
                    Write16(report, 1, (ushort)LampCount);
                    // Approximate physical DIMM layout: 136 mm long, 6 mm wide,
                    // 44 mm tall, with 20 mm between occupied DIMM slots.
                    int stickCount = (LampCount + lampsPerStick - 1) / lampsPerStick;
                    Write32(report, 3, (uint)(6_000 + (stickCount - 1) * 20_000));
                    Write32(report, 7, 136_000);
                    Write32(report, 11, 44_000);
                    Write32(report, 15, 7); // Chassis, including internal RAM.
                    Write32(report, 19, MinUpdateIntervalMicroseconds);
                    break;
                case LampAttributesRequestReport:
                    Write16(report, 1, nextLampId);
                    break;
                case LampAttributesResponseReport:
                    Write16(report, 1, nextLampId);
                    Write32(report, 3, (uint)(3_000 + nextLampId / lampsPerStick * 20_000));
                    Write32(report, 7, (uint)((long)(nextLampId % lampsPerStick + 1) * 136_000 / (lampsPerStick + 1)));
                    Write32(report, 11, 0);
                    Write32(report, 15, MinUpdateIntervalMicroseconds); // Conservative latency estimate.
                    Write32(report, 19, 2); // Accent lighting.
                    report[23] = report[24] = report[25] = report[26] = 255;
                    report[27] = 1; // Programmable RGB.
                    report[28] = 0; // No input binding for a chassis device.
                    nextLampId = (ushort)((nextLampId + 1) % LampCount);
                    break;
                case ControlReport:
                    report[1] = autonomousMode ? (byte)1 : (byte)0;
                    break;
            }
            return report;
        }
    }

    /// <summary>
    /// Consumes a feature report; transport padding is permitted. Malformed update
    /// reports are ignored atomically, as required by the HID LampArray specification.
    /// Unsupported reports and truncated non-update reports throw ArgumentException.
    /// </summary>
    public void SetFeature(ReadOnlySpan<byte> report)
    {
        if (report.IsEmpty)
            throw new ArgumentException("The report ID is missing.", nameof(report));
        byte id = report[0];
        int requiredLength = GetReportLength(id);
        bool update = id is MultiUpdateReport or RangeUpdateReport;
        if (report.Length < requiredLength)
        {
            if (update) return;
            throw new ArgumentException("The feature report is truncated.", nameof(report));
        }

        lock (gate)
        {
            switch (id)
            {
                case LampAttributesRequestReport:
                    ushort requestedId = Read16(report, 1);
                    nextLampId = requestedId < LampCount ? requestedId : (ushort)0;
                    break;
                case ControlReport:
                    if (report[1] > 1) return;
                    bool newMode = report[1] != 0;
                    if (newMode == autonomousMode) return;
                    autonomousMode = newMode;
                    // A batch from a previous ownership interval must never leak
                    // into updates after the host takes control again.
                    committed.CopyTo(staged, 0);
                    AutonomousModeChanged?.Invoke(newMode);
                    break;
                case MultiUpdateReport:
                    if (!autonomousMode) ApplyMultiUpdate(report);
                    break;
                case RangeUpdateReport:
                    if (!autonomousMode) ApplyRangeUpdate(report);
                    break;
                default:
                    throw new ArgumentException("This feature report is read-only.", nameof(report));
            }
        }
    }

    public RgbColor[] GetCurrentFrame()
    {
        lock (gate) return (RgbColor[])committed.Clone();
    }

    private void ApplyMultiUpdate(ReadOnlySpan<byte> report)
    {
        int count = report[1];
        byte flags = report[2];
        if (count > MultiUpdateCapacity || (flags & ~UpdateComplete) != 0) return;

        // Validate all IDs and duplicates before touching the staged batch.
        Span<ushort> ids = stackalloc ushort[MultiUpdateCapacity];
        for (int slot = 0; slot < count; slot++)
        {
            ushort lampId = Read16(report, 3 + slot * 2);
            if (lampId >= LampCount || ids[..slot].Contains(lampId)) return;
            ids[slot] = lampId;
        }
        for (int slot = 0; slot < count; slot++)
            staged[ids[slot]] = ReadScaledColor(report, 19 + slot * 4);
        CommitIfComplete(flags);
    }

    private void ApplyRangeUpdate(ReadOnlySpan<byte> report)
    {
        byte flags = report[1];
        ushort first = Read16(report, 2);
        ushort last = Read16(report, 4);
        if ((flags & ~UpdateComplete) != 0 || first > last || last >= LampCount) return;
        RgbColor color = ReadScaledColor(report, 6);
        for (int lampId = first; lampId <= last; lampId++) staged[lampId] = color;
        CommitIfComplete(flags);
    }

    private void CommitIfComplete(byte flags)
    {
        if ((flags & UpdateComplete) == 0) return;
        staged.CopyTo(committed, 0);
        FrameReady?.Invoke((RgbColor[])committed.Clone());
    }

    private static RgbColor ReadScaledColor(ReadOnlySpan<byte> report, int offset)
    {
        int intensity = report[offset + 3];
        // 255 is unity gain; round to the nearest available hardware channel level.
        return new RgbColor(
            (byte)((report[offset] * intensity + 127) / 255),
            (byte)((report[offset + 1] * intensity + 127) / 255),
            (byte)((report[offset + 2] * intensity + 127) / 255));
    }

    private static ushort Read16(ReadOnlySpan<byte> buffer, int offset) =>
        BinaryPrimitives.ReadUInt16LittleEndian(buffer.Slice(offset, 2));
    private static void Write16(Span<byte> buffer, int offset, ushort value) =>
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.Slice(offset, 2), value);
    private static void Write32(Span<byte> buffer, int offset, uint value) =>
        BinaryPrimitives.WriteUInt32LittleEndian(buffer.Slice(offset, 4), value);

    private static byte[] BuildDescriptor()
    {
        var bytes = new List<byte>();
        void Add(params byte[] values) => bytes.AddRange(values);
        void Begin(byte id, byte usage) => Add(0x85, id, 0x09, usage, 0xA1, 0x02);
        void End() => Add(0xC0);
        void Field(int bits, int count, uint maximum, bool constant, params byte[] usages)
        {
            foreach (byte usage in usages) Add(0x09, usage);
            Add(0x15, 0); // Logical minimum zero.
            // Four-byte maximum avoids HID's signed short-maximum ambiguity.
            Add(0x27, (byte)maximum, (byte)(maximum >> 8), (byte)(maximum >> 16), (byte)(maximum >> 24));
            Add(0x75, (byte)bits, 0x95, (byte)count, 0xB1, constant ? (byte)3 : (byte)2);
        }

        Add(0x05, 0x59, 0x09, 0x01, 0xA1, 0x01); // LightingAndIllumination / LampArray.
        Begin(ArrayAttributesReport, 0x02);
        Field(16, 1, 65535, true, 0x03);
        Field(32, 5, int.MaxValue, true, 0x04, 0x05, 0x06, 0x07, 0x08);
        End();

        Begin(LampAttributesRequestReport, 0x20);
        Field(16, 1, 65535, false, 0x21);
        End();

        Begin(LampAttributesResponseReport, 0x22);
        Field(16, 1, 65535, false, 0x21);
        Field(32, 5, int.MaxValue, false, 0x23, 0x24, 0x25, 0x27, 0x26);
        Field(8, 6, 255, false, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D);
        End();

        Begin(MultiUpdateReport, 0x50);
        Field(8, 1, MultiUpdateCapacity, false, 0x03);
        Field(8, 1, UpdateComplete, false, 0x55);
        Field(16, MultiUpdateCapacity, 65535, false, 0x21);
        var channels = new byte[MultiUpdateCapacity * 4];
        for (int i = 0; i < channels.Length; i++) channels[i] = (byte)(0x51 + i % 4);
        Field(8, channels.Length, 255, false, channels);
        End();

        Begin(RangeUpdateReport, 0x60);
        Field(8, 1, UpdateComplete, false, 0x55);
        Field(16, 2, 65535, false, 0x61, 0x62);
        Field(8, 4, 255, false, 0x51, 0x52, 0x53, 0x54);
        End();

        Begin(ControlReport, 0x70);
        Field(8, 1, 1, false, 0x71);
        End();
        End();
        return bytes.ToArray();
    }
}
