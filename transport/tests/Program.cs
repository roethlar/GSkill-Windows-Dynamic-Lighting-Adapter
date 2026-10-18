using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using RoyalDynamicLighting.Transport;

using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "native-abi.json")));
var native = typeof(WinUHidTransport).GetNestedType("Native", BindingFlags.NonPublic)!;
var config = native.GetNestedType("DeviceConfig", BindingFlags.NonPublic)!;
void Equal(string key, int actual)
{
    var expected = doc.RootElement.GetProperty(key).GetInt32();
    if (actual != expected) throw new Exception($"ABI mismatch: {key}: native={expected}, managed={actual}");
}
Equal("configSize", Marshal.SizeOf(config));
Equal("descriptorOffset", Marshal.OffsetOf(config, "ReportDescriptor").ToInt32());
Equal("containerOffset", Marshal.OffsetOf(config, "ContainerId").ToInt32());
Equal("instanceOffset", Marshal.OffsetOf(config, "InstanceId").ToInt32());
Equal("hardwareOffset", Marshal.OffsetOf(config, "HardwareIds").ToInt32());
Equal("periodOffset", Marshal.OffsetOf(config, "ReadReportPeriodUs").ToInt32());
Equal("eventReportOffset", 8);
Equal("eventLengthOffset", 9);
Equal("eventDataOffset", 13);
Console.WriteLine("PASS: P/Invoke ABI agrees with compiled upstream C++ header.");

uint version = WinUHidTransport.GetDriverVersion(out int error);
if (version == 0 && error == 0) throw new Exception("Native failed without a Win32 error.");
Console.WriteLine($"PASS: Native DLL loads; driver version={version}, Win32 error={error}.");
Console.WriteLine("No devices created and no hardware writes performed.");
