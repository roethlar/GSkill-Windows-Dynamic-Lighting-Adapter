using System.Globalization;
using Windows.Devices.Enumeration;
using Windows.Devices.Lights;

// Read-only metadata probe. This program never changes colors, brightness, enabled
// state, or ownership and never opens a PawnIO handle.
// https://learn.microsoft.com/en-us/uwp/api/windows.devices.lights.lamparray
internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        try
        {
            bool requireRoyal = args.Contains("--require-royal", StringComparer.Ordinal);
            int expectedCount = 16;
            int countIndex = Array.IndexOf(args, "--expected-lamps");
            if (countIndex >= 0)
            {
                if (countIndex + 1 >= args.Length || !int.TryParse(args[countIndex + 1], NumberStyles.None, CultureInfo.InvariantCulture, out expectedCount) || expectedCount < 1)
                    throw new ArgumentException("--expected-lamps requires a positive integer.");
            }

            string selector = LampArray.GetDeviceSelector();
            Console.WriteLine($"LampArray selector: {selector}");
            var devices = await DeviceInformation.FindAllAsync(selector).AsTask().WaitAsync(TimeSpan.FromSeconds(15));
            Console.WriteLine($"Enumerated LampArray devices: {devices.Count}");
            int royalCount = 0;
            bool royalValid = false;
            foreach (DeviceInformation device in devices)
            {
                Console.WriteLine($"Name: {device.Name}");
                Console.WriteLine($"  Id: {device.Id}");
                Console.WriteLine($"  DeviceInformation.IsEnabled: {device.IsEnabled}");
                try
                {
                    LampArray? array = await LampArray.FromIdAsync(device.Id).AsTask().WaitAsync(TimeSpan.FromSeconds(15));
                    if (array is null)
                    {
                        Console.WriteLine("  LampArray.FromIdAsync returned null.");
                        continue;
                    }

                    bool isRoyal = array.HardwareVendorId == 0 && array.HardwareProductId == 0x524C;
                    Console.WriteLine($"  Royal adapter: {isRoyal}");
                    Console.WriteLine($"  Hardware: VID {array.HardwareVendorId:X4}, PID {array.HardwareProductId:X4}, version {array.HardwareVersion:X4}");
                    Console.WriteLine($"  LampCount: {array.LampCount}; kind: {array.LampArrayKind}");
                    Console.WriteLine($"  IsConnected: {array.IsConnected}; IsAvailable: {array.IsAvailable}; IsEnabled: {array.IsEnabled}");
                    Console.WriteLine($"  MinUpdateInterval: {array.MinUpdateInterval.TotalMilliseconds:F4} ms");
                    Console.WriteLine($"  BoundingBox: {array.BoundingBox}; SupportsVirtualKeys: {array.SupportsVirtualKeys}");
                    if (isRoyal)
                    {
                        royalCount++;
                        bool geometryValid = true;
                        for (int i = 0; i < array.LampCount; i++)
                        {
                            LampInfo lamp = array.GetLampInfo(i);
                            bool programmable = lamp.FixedColor is null;
                            Console.WriteLine($"    Lamp {i}: position={lamp.Position}, purpose={lamp.Purposes}, programmable={programmable}, RGB levels={lamp.RedLevelCount}/{lamp.GreenLevelCount}/{lamp.BlueLevelCount}, intensity levels={lamp.GainLevelCount}, latency={lamp.UpdateLatency.TotalMilliseconds:F4} ms");
                            geometryValid &= programmable && lamp.RedLevelCount == 255 && lamp.GreenLevelCount == 255 && lamp.BlueLevelCount == 255;
                        }
                        royalValid |= array.IsConnected && array.LampCount == expectedCount && array.LampArrayKind == LampArrayKind.Chassis && geometryValid;
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"  Metadata error: {ex.GetType().Name}, HRESULT 0x{ex.HResult:X8}: {ex.Message}");
                }
            }
            Console.WriteLine($"Royal adapter matches: {royalCount}; expected {expectedCount} lamps accepted: {royalValid}");
            return requireRoyal && !royalValid ? 2 : 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"LampProbe failed: {ex.GetType().Name}, HRESULT 0x{ex.HResult:X8}: {ex.Message}");
            return 1;
        }
    }
}
