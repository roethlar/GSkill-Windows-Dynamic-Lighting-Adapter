using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using RoyalDynamicLighting;

namespace RoyalDynamicLighting.Tests;

public static class LampArrayTests
{
    public static void Run()
    {
        DescriptorAgreesWithWireReports();
        EnumerationWrapsAndRejectsShortBuffers();
        GeometryAndCapabilitiesAreConsistent();
        MultiReportBatchCommitsOnceAndScalesBrightness();
        InvalidReportsNeverPartiallyMutateOrCommit();
        AutonomousTransitionsDiscardUncommittedUpdates();
        PaddedReportsAndFrameOwnershipAreSafe();
        ConcurrentReportsRemainAtomic();
        Console.WriteLine("LampArray: 8 protocol checks passed.");
    }

    private static void DescriptorAgreesWithWireReports()
    {
        var lamp = new LampArray();
        var fields = ParseDescriptor(lamp.ReportDescriptor);
        int[] expectedLengths = { 0, 23, 3, 29, 51, 10, 2 };
        for (byte id = 1; id <= 6; id++)
        {
            int bits = fields.Where(f => f.Report == id).Sum(f => f.Bits);
            Equal(expectedLengths[id], 1 + bits / 8, $"report {id} length in descriptor");
            Equal(expectedLengths[id], LampArray.GetReportLength(id), $"report {id} wire size");
        }
        Equal(0x59, fields[0].UsagePage, "usage page");
        CheckField(fields, 1, 0x03, 0, 16, 65535);
        CheckField(fields, 1, 0x07, 112, 32, int.MaxValue);
        CheckField(fields, 3, 0x27, 112, 32, int.MaxValue);
        CheckField(fields, 3, 0x26, 144, 32, int.MaxValue);
        CheckField(fields, 3, 0x2B, 200, 8, 255);
        CheckField(fields, 4, 0x03, 0, 8, 8);
        CheckField(fields, 4, 0x55, 8, 8, 1);
        CheckField(fields, 4, 0x21, 16, 16, 65535);
        CheckField(fields, 4, 0x51, 144, 8, 255);
        CheckField(fields, 5, 0x61, 8, 16, 65535);
        CheckField(fields, 5, 0x54, 64, 8, 255);
        CheckField(fields, 6, 0x71, 0, 8, 1);
        Equal(8, fields.Count(f => f.Report == 4 && f.Usage == 0x21), "multi lamp ID slots");
        Equal(8, fields.Count(f => f.Report == 4 && f.Usage == 0x54), "multi intensity slots");
        // Returned metadata is owned by the caller.
        byte[] descriptor = lamp.ReportDescriptor;
        descriptor[0] = 0;
        Equal((byte)0x05, lamp.ReportDescriptor[0], "descriptor is protected against mutation");
    }

    private static void EnumerationWrapsAndRejectsShortBuffers()
    {
        var lamp = new LampArray(3);
        Equal((ushort)0, Read16(lamp.GetFeature(3, 29), 1), "initial ID");
        Throws<ArgumentOutOfRangeException>(() => lamp.GetFeature(3, 28));
        Equal((ushort)1, Read16(lamp.GetFeature(3, 29), 1), "short GET did not advance ID");
        Equal((ushort)2, Read16(lamp.GetFeature(3, 29), 1), "last ID");
        Equal((ushort)0, Read16(lamp.GetFeature(3, 29), 1), "ID wraps");
        lamp.SetFeature(new byte[] { 2, 2, 0 });
        Equal((ushort)2, Read16(lamp.GetFeature(3, 29), 1), "explicit ID");
        lamp.SetFeature(new byte[] { 2, 255, 255 });
        Equal((ushort)0, Read16(lamp.GetFeature(3, 29), 1), "invalid ID resets to zero");
        Throws<ArgumentException>(() => lamp.SetFeature(new byte[] { 2, 1 }));
        Throws<ArgumentException>(() => lamp.GetFeature(4, 51));
        Throws<ArgumentOutOfRangeException>(() => lamp.GetFeature(255, 51));
    }

    private static void GeometryAndCapabilitiesAreConsistent()
    {
        var lamp = new LampArray(16, 8, 40_000);
        byte[] attributes = lamp.GetFeature(1, 23);
        Equal((ushort)16, Read16(attributes, 1), "lamp count");
        Equal(7u, Read32(attributes, 15), "chassis kind");
        Equal(40_000u, Read32(attributes, 19), "minimum interval");
        var positions = new HashSet<(uint, uint, uint)>();
        for (int i = 0; i < lamp.LampCount; i++)
        {
            byte[] item = lamp.GetFeature(3, 29);
            Equal((ushort)i, Read16(item, 1), "lamp ID");
            uint x = Read32(item, 3), y = Read32(item, 7), z = Read32(item, 11);
            True(x <= Read32(attributes, 3) && y <= Read32(attributes, 7) && z <= Read32(attributes, 11), "position in bounding box");
            True(positions.Add((x, y, z)), "distinct lamp position");
            Equal(2u, Read32(item, 19), "accent purpose");
            True(item.AsSpan(23, 4).ToArray().All(v => v == 255), "RGB and intensity level counts");
            Equal((byte)1, item[27], "programmable lamp");
            Equal((byte)0, item[28], "no keyboard binding");
        }
        var oddCount = new LampArray(9, 8);
        Equal((ushort)9, Read16(oddCount.GetFeature(1, 23), 1), "partial final stick supported");
        Throws<ArgumentOutOfRangeException>(() => new LampArray(0));
        Throws<ArgumentOutOfRangeException>(() => new LampArray(16, 0));
        Throws<ArgumentOutOfRangeException>(() => new LampArray(minUpdateIntervalMicroseconds: 0));
    }

    private static void MultiReportBatchCommitsOnceAndScalesBrightness()
    {
        var lamp = HostControlled(16);
        var frames = new List<RgbColor[]>();
        lamp.FrameReady += frame => frames.Add(frame);
        lamp.SetFeature(Multi(false, (9, 255, 100, 1, 128), (0, 9, 8, 7, 255)));
        lamp.SetFeature(Range(3, 5, 10, 20, 30, 255, false));
        Equal(0, frames.Count, "incomplete updates stay buffered");
        True(lamp.GetCurrentFrame().All(c => c == default), "uncommitted colors stay private");
        lamp.SetFeature(Multi(true, (15, 255, 255, 255, 0)));
        Equal(1, frames.Count, "one completed frame");
        Equal(new RgbColor(128, 50, 1), frames[0][9], "intensity gain with rounding");
        Equal(new RgbColor(9, 8, 7), frames[0][0], "unity intensity");
        for (int i = 3; i <= 5; i++) Equal(new RgbColor(10, 20, 30), frames[0][i], "inclusive range");
        Equal(default(RgbColor), frames[0][15], "zero intensity turns lamp off");
        lamp.SetFeature(Range(1, 1, 100, 200, 255, 255, true));
        Equal(2, frames.Count, "second commit");
        Equal(frames[0][9], frames[1][9], "partial frame preserves previous lamps");
    }

    private static void InvalidReportsNeverPartiallyMutateOrCommit()
    {
        var lamp = HostControlled(4);
        int frames = 0;
        lamp.FrameReady += _ => frames++;
        lamp.SetFeature(Range(0, 3, 20, 30, 40, 255, false));
        lamp.SetFeature(Multi(true, (0, 255, 0, 0, 255), (0, 0, 255, 0, 255)));
        lamp.SetFeature(Multi(true, (1, 255, 0, 0, 255), (4, 0, 255, 0, 255)));
        lamp.SetFeature(Range(0, 4, 255, 0, 0, 255, true));
        lamp.SetFeature(Range(3, 0, 255, 0, 0, 255, true));
        byte[] badCount = Multi(true);
        badCount[1] = 9;
        lamp.SetFeature(badCount);
        byte[] badFlags = Range(0, 3, 255, 0, 0, 255, true);
        badFlags[1] = 3;
        lamp.SetFeature(badFlags);
        lamp.SetFeature(new byte[] { 4, 1, 1 });
        lamp.SetFeature(new byte[] { 5, 1 });
        Equal(0, frames, "invalid reports cannot flush a batch");
        // Zero slots with UpdateComplete flushes previously staged valid updates.
        lamp.SetFeature(Multi(true));
        Equal(1, frames, "valid complete report flushes batch");
        True(lamp.GetCurrentFrame().All(c => c == new RgbColor(20, 30, 40)), "invalid reports cannot partly mutate a batch");
    }

    private static void AutonomousTransitionsDiscardUncommittedUpdates()
    {
        var lamp = new LampArray(2);
        int frames = 0;
        var modes = new List<bool>();
        lamp.FrameReady += _ => frames++;
        lamp.AutonomousModeChanged += mode => modes.Add(mode);
        True(lamp.AutonomousMode, "autonomous by default");
        lamp.SetFeature(Range(0, 1, 255, 0, 0, 255, true));
        Equal(0, frames, "autonomous mode ignores updates");
        lamp.SetFeature(new byte[] { 6, 0 });
        lamp.SetFeature(new byte[] { 6, 0 });
        Equal(1, modes.Count, "repeated control is a no-op");
        lamp.SetFeature(Range(0, 1, 10, 20, 30, 255, true));
        lamp.SetFeature(Range(0, 0, 255, 0, 0, 255, false));
        lamp.SetFeature(new byte[] { 6, 1 });
        lamp.SetFeature(new byte[] { 6, 0 });
        lamp.SetFeature(Multi(true));
        True(lamp.GetCurrentFrame().All(c => c == new RgbColor(10, 20, 30)), "ownership change discards stale batch");
        Equal(2, frames, "mode changes never emit color frames");
        True(modes.SequenceEqual(new[] { false, true, false }), "mode event order");
        lamp.SetFeature(new byte[] { 6, 7 });
        True(!lamp.AutonomousMode, "invalid mode ignored");
        Equal((byte)0, lamp.GetFeature(6, 2)[1], "mode GET");
    }

    private static void PaddedReportsAndFrameOwnershipAreSafe()
    {
        var lamp = HostControlled(2);
        byte[] padded = new byte[51];
        Range(0, 1, 1, 2, 3, 255, true).CopyTo(padded, 0);
        lamp.FrameReady += frame => frame[0] = new RgbColor(255, 255, 255);
        lamp.SetFeature(padded);
        Equal(new RgbColor(1, 2, 3), lamp.GetCurrentFrame()[0], "event subscriber cannot alter state");
        RgbColor[] snapshot = lamp.GetCurrentFrame();
        snapshot[0] = default;
        Equal(new RgbColor(1, 2, 3), lamp.GetCurrentFrame()[0], "snapshot caller cannot alter state");
        byte[] paddedGet = lamp.GetFeature(1, 51);
        Equal(51, paddedGet.Length, "GET length matches request");
        True(paddedGet.Skip(23).All(b => b == 0), "GET padding is zero");
        // Unused slots may contain invalid IDs; they must be ignored.
        byte[] one = Multi(true, (1, 4, 5, 6, 255));
        one[5] = one[6] = 255;
        lamp.SetFeature(one);
        Equal(new RgbColor(4, 5, 6), lamp.GetCurrentFrame()[1], "unused slots ignored");
    }

    private static void ConcurrentReportsRemainAtomic()
    {
        var lamp = HostControlled(16);
        int frames = 0;
        lamp.FrameReady += frame =>
        {
            True(frame.All(c => c == frame[0]), "concurrent report cannot tear frame");
            frames++;
        };
        Parallel.For(0, 128, i =>
        {
            lamp.SetFeature(Range(0, 15, (byte)i, (byte)(255 - i), 7, 255, true));
            _ = lamp.GetFeature(3, 29);
        });
        Equal(128, frames, "serialized frame event count");
    }

    private static LampArray HostControlled(int count)
    {
        var lamp = new LampArray(count);
        lamp.SetFeature(new byte[] { 6, 0 });
        return lamp;
    }

    private static byte[] Range(ushort first, ushort last, byte r, byte g, byte b, byte intensity, bool complete)
    {
        byte[] report = { 5, complete ? (byte)1 : (byte)0, 0, 0, 0, 0, r, g, b, intensity };
        BinaryPrimitives.WriteUInt16LittleEndian(report.AsSpan(2, 2), first);
        BinaryPrimitives.WriteUInt16LittleEndian(report.AsSpan(4, 2), last);
        return report;
    }

    private static byte[] Multi(bool complete, params (ushort Id, byte R, byte G, byte B, byte Intensity)[] slots)
    {
        byte[] report = new byte[51];
        report[0] = 4;
        report[1] = (byte)slots.Length;
        report[2] = complete ? (byte)1 : (byte)0;
        for (int i = 0; i < slots.Length; i++)
        {
            BinaryPrimitives.WriteUInt16LittleEndian(report.AsSpan(3 + i * 2, 2), slots[i].Id);
            report[19 + i * 4] = slots[i].R;
            report[20 + i * 4] = slots[i].G;
            report[21 + i * 4] = slots[i].B;
            report[22 + i * 4] = slots[i].Intensity;
        }
        return report;
    }

    // An independent, minimal HID short-item decoder verifies descriptor offsets,
    // repeated RGBI usage ordering, report sizes, and logical limits.
    private readonly record struct Field(byte Report, int UsagePage, int Usage, int Offset, int Bits, uint Maximum);
    private static List<Field> ParseDescriptor(byte[] descriptor)
    {
        int report = 0, page = 0, size = 0, count = 0, depth = 0;
        uint maximum = 0;
        var offsets = new Dictionary<int, int>();
        var usages = new List<int>();
        var fields = new List<Field>();
        for (int i = 0; i < descriptor.Length;)
        {
            byte header = descriptor[i++];
            int length = (header & 3) == 3 ? 4 : header & 3;
            uint value = 0;
            for (int j = 0; j < length; j++) value |= (uint)descriptor[i++] << (8 * j);
            int type = (header >> 2) & 3, tag = header >> 4;
            if (type == 1)
            {
                switch (tag)
                {
                    case 0: page = (int)value; break;
                    case 2: maximum = value; break;
                    case 7: size = (int)value; break;
                    case 8: report = (int)value; break;
                    case 9: count = (int)value; break;
                }
            }
            else if (type == 2 && tag == 0) usages.Add((int)value);
            else if (type == 0)
            {
                if (tag == 10) depth++;
                if (tag == 12) depth--;
                if (tag == 11)
                {
                    int offset = offsets.GetValueOrDefault(report);
                    for (int n = 0; n < count; n++)
                        fields.Add(new Field((byte)report, page, usages[Math.Min(n, usages.Count - 1)], offset + n * size, size, maximum));
                    offsets[report] = offset + count * size;
                }
                usages.Clear();
            }
            True(depth >= 0, "balanced descriptor collections");
        }
        Equal(0, depth, "all descriptor collections closed");
        return fields;
    }

    private static void CheckField(List<Field> fields, byte report, int usage, int offset, int bits, uint maximum)
    {
        Field field = fields.First(f => f.Report == report && f.Usage == usage);
        Equal(offset, field.Offset, $"report {report}, usage {usage:X2} offset");
        Equal(bits, field.Bits, $"report {report}, usage {usage:X2} width");
        Equal(maximum, field.Maximum, $"report {report}, usage {usage:X2} logical maximum");
    }

    private static ushort Read16(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset, 2));
    private static uint Read32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
    private static void True(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
    private static void Equal<T>(T expected, T actual, string message)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"{message}: expected {expected}, got {actual}");
    }
    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}");
    }
}
