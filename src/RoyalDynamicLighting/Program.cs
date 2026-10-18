using System.Diagnostics;
using System.Globalization;
using System.Security.Principal;
using System.Runtime.Versioning;
using System.Text.Json;
using RoyalDynamicLighting.Transport;

namespace RoyalDynamicLighting;

internal sealed record DeviceConfig(byte Address, string Firmware, string Manufacturer, int LedCount);
internal sealed record BridgeConfig(int Port, int FramesPerSecond, DeviceConfig[] Devices);

[SupportedOSPlatform("windows")]
internal static class Program
{
    private const string StopEventName = @"Global\RoyalDynamicLighting.Stop";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static StreamWriter? log;

    public static int Main(string[] args)
    {
        try
        {
            string? logPath = Option(args, "--log");
            if (logPath is not null)
            {
                logPath = Path.GetFullPath(logPath);
                Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
                log = new StreamWriter(new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) { AutoFlush = true };
            }
            if (args.Length == 0 || args[0] is "help" or "--help" or "-h") { Help(); return 0; }
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows 11 is required.");
            return args[0] switch
            {
                "doctor" => Doctor(),
                "detect" => Detect(args),
                "run" => Run(args),
                "test-color" => TestColor(args),
                "stop" => Stop(),
                _ => throw new ArgumentException($"Unknown command '{args[0]}'. Use --help.")
            };
        }
        catch (Exception ex)
        {
            Write($"ERROR: {ex.Message}");
            return 1;
        }
        finally { log?.Dispose(); }
    }

    private static void Help() => Console.WriteLine("""
        Royal Dynamic Lighting — standalone PawnIO RAM adapter
        doctor                                   Check prerequisites without accessing RAM
        detect [--write-config PATH]             Identify ENE RAM controllers
               [--addresses 0x70,0x71,...] [--port 0|1]
        run --config PATH [--log PATH]            Expose configured RAM to Dynamic Lighting
        test-color RRGGBB --config PATH           Set color briefly, then restore
                         [--seconds 1..30]
        stop                                     Ask the running adapter to restore and exit

        detect, run, and test-color require administrator access to PawnIO.
        Detection selects ENE read registers; it does not change lighting.
        Detection never accesses SPD or assigns controller addresses.
        """);

    private static int Doctor()
    {
        Write($"Windows: {Environment.OSVersion.Version}; 64-bit: {Environment.Is64BitProcess}; administrator: {IsAdministrator()}");
        string dll = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PawnIO", "PawnIOLib.dll");
        Write($"PawnIO library: {(File.Exists(dll) ? FileVersionInfo.GetVersionInfo(dll).FileVersion : "not installed")} ({dll})");
        Write($"Signed SMBus module: {(File.Exists(ModulePath) ? "present" : "missing")}");
        try
        {
            uint version = WinUHidTransport.GetDriverVersion(out int error);
            Write(version == 0 ? $"Virtual HID driver unavailable (Win32 {error}); install the prepared driver package as administrator." : $"Virtual HID driver interface version: {version}");
        }
        catch (DllNotFoundException ex) { Write($"Virtual HID transport unavailable: {ex.Message}"); }
        return 0;
    }

    private static string ModulePath => Path.Combine(AppContext.BaseDirectory, "modules", "SmbusPIIX4.bin");

    private static int Detect(string[] args)
    {
        RequireAdministrator();
        int port = int.Parse(Option(args, "--port") ?? "0", CultureInfo.InvariantCulture);
        string? list = Option(args, "--addresses");
        byte[] addresses = list is null ? EneRam.DefaultProbeAddresses.ToArray() : list.Split(',').Select(ParseAddress).ToArray();
        using PawnIo pawn = new(ModulePath, port: port);
        Write($"SMBus: {pawn.Identity.Controller}, port {port}, PCI {pawn.Identity.VendorId:X4}:{pawn.Identity.DeviceId:X4}");
        EneRam ram = new(pawn);
        IReadOnlyList<EneRamDevice> devices = ram.Detect(addresses);
        foreach (EneProbeResult probe in ram.LastProbeResults)
        {
            string detail = probe.Device is { } d ? $"{d.Firmware}, {d.Manufacturer}, {d.LedCount} LEDs" : probe.Status;
            Write($"0x{probe.Address:X2}: {detail}");
        }
        if (devices.Count == 0)
            throw new InvalidOperationException("No supported initialized ENE RAM controller found. Keep this diagnostic output; do not force a different firmware or LED count.");
        string? destination = Option(args, "--write-config");
        if (destination is not null)
        {
            BridgeConfig config = new(port, 30, devices.Select(d => new DeviceConfig(d.Address, d.Firmware, d.Manufacturer, d.LedCount)).ToArray());
            destination = Path.GetFullPath(destination);
            if (File.Exists(destination)) throw new IOException($"Configuration already exists: {destination}. Move it aside before saving a new detection.");
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.WriteAllText(destination, JsonSerializer.Serialize(config, JsonOptions));
            Write($"Saved verified controller identities to {destination}");
        }
        return 0;
    }

    private static BridgeConfig LoadConfig(string[] args)
    {
        string path = Option(args, "--config") ?? throw new ArgumentException("Supply --config PATH created by detect --write-config PATH.");
        BridgeConfig config = JsonSerializer.Deserialize<BridgeConfig>(File.ReadAllText(path)) ?? throw new InvalidDataException("Configuration is empty.");
        if (config.Port is not (0 or 1) || config.FramesPerSecond is < 1 or > 30 || config.Devices is null || config.Devices.Length is < 1 or > 4)
            throw new InvalidDataException("Configuration requires port 0 or 1, 1–30 FPS, and 1–4 verified RAM modules.");
        if (config.Devices.Any(d => d is null || d.LedCount is < 1 or > 16) || config.Devices.Select(d => d.Address).Distinct().Count() != config.Devices.Length)
            throw new InvalidDataException("Configuration has invalid LED counts or duplicate addresses.");
        if (config.Devices.Select(d => d.LedCount).Distinct().Count() != 1)
            throw new InvalidDataException("This layout requires identical LED counts on each RAM module.");
        foreach (DeviceConfig device in config.Devices) EneRam.ValidateAddress(device.Address);
        return config;
    }

    private static IReadOnlyList<EneRamDevice> VerifyConfig(EneRam ram, BridgeConfig config)
    {
        var devices = ram.Detect(config.Devices.Select(d => d.Address));
        foreach (DeviceConfig expected in config.Devices)
        {
            EneRamDevice? actual = devices.SingleOrDefault(d => d.Address == expected.Address);
            if (actual is null || actual.Firmware != expected.Firmware || actual.Manufacturer != expected.Manufacturer || actual.LedCount != expected.LedCount)
                throw new InvalidDataException($"RAM at 0x{expected.Address:X2} no longer matches the saved configuration. Run detection again.");
        }
        return config.Devices.Select(d => devices.Single(actual => actual.Address == d.Address)).ToArray();
    }

    private static int Run(string[] args)
    {
        RequireAdministrator();
        BridgeConfig config = LoadConfig(args);
        using Mutex instance = new(false, @"Global\RoyalDynamicLighting.Instance");
        bool owns;
        try { owns = instance.WaitOne(0); } catch (AbandonedMutexException) { owns = true; }
        if (!owns) throw new InvalidOperationException("Another adapter instance is already running.");
        try
        {
            CheckConflicts();
            using PawnIo pawn = new(ModulePath, port: config.Port);
            EneRam ram = new(pawn);
            IReadOnlyList<EneRamDevice> devices = VerifyConfig(ram, config);
            LampArray lamps = new(devices.Sum(d => d.LedCount), devices[0].LedCount, (uint)Math.Ceiling(1_000_000.0 / config.FramesPerSecond));
            using EventWaitHandle stop = new(false, EventResetMode.ManualReset, StopEventName);
            stop.Reset();
            Exception? workerError = null;
            long appliedFrames = 0;
            using FrameDispatcher worker = new(frame =>
            {
                int offset = 0;
                foreach (EneRamDevice device in devices)
                {
                    ram.SendFrame(device, frame.AsSpan(offset, device.LedCount));
                    offset += device.LedCount;
                }
                if (Interlocked.Increment(ref appliedFrames) == 1) Write("Applied the first host lighting frame to both configured RAM controllers.");
            }, ram.RestoreAll, config.FramesPerSecond, ex => { workerError = ex; stop.Set(); });
            lamps.FrameReady += worker.Submit;
            Action<bool> ownershipChanged = value =>
            {
                Write(value ? "Windows released lighting control." : "Windows acquired lighting control.");
                worker.SetAutonomous(value);
            };
            lamps.AutonomousModeChanged += ownershipChanged;
            using WinUHidTransport transport = new(lamps.ReportDescriptor, "RoyalDynamicLighting.RAM", lamps.GetFeature, data => lamps.SetFeature(data));
            transport.ReportError += ex => { Write($"HID report: {ex.Message}"); };
            ConsoleCancelEventHandler cancel = (_, e) => { e.Cancel = true; stop.Set(); };
            Console.CancelKeyPress += cancel;
            try
            {
                transport.Start();
                Write($"Serving {lamps.LampCount} RAM LEDs across {devices.Count} modules. Open Windows Settings > Personalization > Dynamic Lighting.");
                stop.WaitOne();
            }
            finally
            {
                transport.Dispose();
                lamps.FrameReady -= worker.Submit;
                lamps.AutonomousModeChanged -= ownershipChanged;
                Console.CancelKeyPress -= cancel;
                worker.Dispose();
            }
            if (workerError is not null) throw new IOException($"RAM output stopped: {workerError.Message}", workerError);
            Write("RAM lighting restored; adapter stopped.");
            return 0;
        }
        finally { instance.ReleaseMutex(); }
    }

    private static int TestColor(string[] args)
    {
        RequireAdministrator();
        if (args.Length < 2 || args[1].Length != 6 || !uint.TryParse(args[1], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out uint rgb))
            throw new ArgumentException("Use test-color RRGGBB --config PATH.");
        int seconds = int.Parse(Option(args, "--seconds") ?? "3", CultureInfo.InvariantCulture);
        if (seconds is < 1 or > 30) throw new ArgumentOutOfRangeException(nameof(seconds));
        CheckConflicts();
        using Mutex instance = new(false, @"Global\RoyalDynamicLighting.Instance");
        bool owns;
        try { owns = instance.WaitOne(0); } catch (AbandonedMutexException) { owns = true; }
        if (!owns) throw new InvalidOperationException("Stop the running adapter before testing colors.");
        try
        {
            BridgeConfig config = LoadConfig(args);
            using PawnIo pawn = new(ModulePath, port: config.Port);
            EneRam ram = new(pawn);
            var devices = VerifyConfig(ram, config);
            try
            {
                RgbColor color = new((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
                foreach (var device in devices) ram.SendFrame(device, Enumerable.Repeat(color, device.LedCount).ToArray());
                Write($"Test color #{rgb:X6} for {seconds} seconds.");
                using ManualResetEvent done = new(false);
                ConsoleCancelEventHandler cancel = (_, e) => { e.Cancel = true; done.Set(); };
                Console.CancelKeyPress += cancel;
                try { done.WaitOne(TimeSpan.FromSeconds(seconds)); }
                finally { Console.CancelKeyPress -= cancel; }
            }
            finally { ram.RestoreAll(); }
            Write("Previous lighting restored.");
            return 0;
        }
        finally { instance.ReleaseMutex(); }
    }

    private static int Stop()
    {
        using EventWaitHandle stop = EventWaitHandle.OpenExisting(StopEventName);
        stop.Set();
        Write("Requested lighting restoration and shutdown.");
        return 0;
    }

    private static void CheckConflicts()
    {
        string[] names = ["LightingService", "SignalRgb", "SignalRgbLauncher", "LEDKeeper2", "RGBFusion", "TridentZ", "Gskill", "XPG-Prime"];
        foreach (string name in names)
        {
            Process[] found = Process.GetProcessesByName(name);
            bool running = found.Length != 0;
            foreach (Process process in found) process.Dispose();
            if (running) throw new InvalidOperationException($"Close {name} before allowing this adapter to control RAM.");
        }
    }

    private static byte ParseAddress(string value)
    {
        value = value.Trim();
        return value.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            ? byte.Parse(value[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture)
            : byte.Parse(value, CultureInfo.InvariantCulture);
    }

    private static bool IsAdministrator() => new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    private static void RequireAdministrator()
    {
        if (!IsAdministrator()) throw new UnauthorizedAccessException("This operation needs an administrator terminal because PawnIO requires elevated access. 'doctor' works without elevation.");
    }

    private static string? Option(string[] args, string name)
    {
        int index = Array.IndexOf(args, name);
        if (index < 0) return null;
        if (index + 1 == args.Length || args[index + 1].StartsWith("--")) throw new ArgumentException($"{name} requires a value.");
        return args[index + 1];
    }

    private static void Write(string message)
    {
        string line = $"[{DateTimeOffset.Now:O}] {message}";
        lock (JsonOptions) { Console.WriteLine(line); log?.WriteLine(line); }
    }
}
