# Royal Dynamic Lighting

A standalone adapter for this machine's two G.Skill Royal DDR5 modules:

```text
Windows Dynamic Lighting → virtual HID LampArray → adapter → PawnIO → ENE RAM LEDs
```

There is no OpenRGB application, SDK, server, library, copied code, or startup dependency. The adapter uses the installed PawnIO driver and its official signed AMD SMBus module directly. The managed application is published with its .NET runtime included.

## Verified hardware and current status

- ASUS ROG CROSSHAIR X870E DARK HERO, Windows build 26300.
- Two 48 GB G.Skill modules, WMI part number `F5-6000J2836F48G`.
- AMD PIIX4 SMBus, PCI `1022:790B`, port 0.
- ENE controllers at `0x71` and `0x73`, firmware `AUDA0-E6K5-0101`, eight LEDs each.
- PawnIO 2.2.0 installed. Official signed `SmbusPIIX4.bin` module release 0.2.11 included.
- Both sticks turned blue in a direct PawnIO test, confirmed visually by the user. The test restored their previous state.
- Application builds without warnings. LampArray, RAM backend, frame dispatch, native transport ABI, INF validation, and driver catalog checks pass.
- During validation, the locally signed virtual HID driver loaded successfully (`ROOT\SYSTEM\0001`, driver package `oem39.inf`, device error code 0).
- Windows' LampArray API recognized the adapter as **HID-compliant device**, VID `0000`, PID `524C`, with 16 programmable chassis LEDs, connected and enabled. Unavailable to other apps while Windows owns lighting is expected.
- Logs confirmed Windows acquired lighting control and applied its first lighting frame to both RAM controllers on October 17, 2026.
- At the user's request, the running application, startup task, virtual driver/package, and dedicated certificate trust were removed on October 17, 2026. Elevated verification found no remaining adapter process or startup entry; no reboot was required. The installer and source remain available.

The generated `config.json` records verified addresses and controller identities. The manufacturer-register area contains binary data on this firmware; its exact bytes are retained as a `raw:` fingerprint instead of inventing a manufacturer name.

## Installation

For a fresh Windows installation on this same hardware, run `artifacts\installer\RoyalDynamicLighting-Setup-0.1.0-x64.exe`. It is an offline installer for Windows 11 23H2 or later on x64 hardware. It includes the published application and its .NET runtime, the virtual HID driver, official PawnIO 2.2.0 setup, and Microsoft Visual C++ x64 runtime 14.51.36247. Suitable installed prerequisites are reused. No compiler, SDK, or OpenRGB installation is required.

The installer uses one administrator elevation, displays the driver certificate trust changes before installation, starts the adapter, and adds **Royal Dynamic Lighting** to Installed apps. It never restarts Windows automatically. Existing manual installations are detected and will not be replaced by this first installer release.

Alternatively, from the development folder, run the script setup in an administrator PowerShell after installing PawnIO and the Visual C++ runtime:

```powershell
.\Setup.ps1 -TrustLocalCertificate
```

Setup installs the locally signed WinUHid UMDF driver and adds its dedicated public signing certificate to `LocalMachine\Root` and `LocalMachine\TrustedPublisher`. The temporary private signing key has already been deleted. Setup does not change Secure Boot, memory integrity, or test-signing settings.

The adapter is copied to `%ProgramFiles%\RoyalDynamicLighting`. A `RoyalDynamicLighting` scheduled task runs it as SYSTEM at startup, with a 20-second delay, and starts it immediately after installation. This supplies the elevated PawnIO access without keeping an administrator console open. Program files and installation receipts are protected against ordinary-user writes.

After installation, open **Settings → Personalization → Dynamic Lighting**. Windows' device API names the virtual device **HID-compliant device**; it exposes 16 programmable chassis LEDs across both RAM sticks. Choose a solid color or effect there.

Logs and installation receipts are under `%ProgramData%\RoyalDynamicLighting`. The adapter restores the saved lighting mode and direct-color buffer on normal shutdown and when Windows releases control. Competing RGB applications should be closed.

The executable installer keeps its support files under `%ProgramFiles%\RoyalDynamicLighting Setup`. A protected package journal tracks its own changes for retry and removal. It preserves configuration and diagnostic logs across removal/reinstallation. Shared PawnIO and Visual C++ installations are retained when removing this adapter.

The local driver certificate expires October 17, 2027; future installations after expiration need a newly signed package. The installer EXE itself has no public Authenticode publisher signature.

## Commands

From the published `artifacts\app` directory:

```powershell
.\RoyalDynamicLighting.exe doctor
.\RoyalDynamicLighting.exe detect --addresses 0x71,0x73 --write-config C:\path\new-config.json
.\RoyalDynamicLighting.exe test-color 2080FF --seconds 15 --config C:\path\config.json
.\RoyalDynamicLighting.exe run --config C:\path\config.json --log C:\path\adapter.log
.\RoyalDynamicLighting.exe stop
```

All commands except `doctor` need elevation for this PawnIO installation. Detection selects ENE register addresses and reads their contents; it performs no lighting-state, SPD, EEPROM, or controller-address changes. Hardware writes require a recognized firmware and validated LED count. The direct `stop` command requires access to the running process's shutdown event; an administrator console cannot necessarily signal an instance running as SYSTEM. Use the removal script for the installed background adapter.

To check Windows recognition without changing colors:

```powershell
.\tools\dotnet\dotnet.exe run --no-build --project .\tools\LampProbe\LampProbe.csproj -c Release -- --require-royal --expected-lamps 16
```

## Removal

For an installation made with the EXE, use **Settings → Apps → Installed apps → Royal Dynamic Lighting → Uninstall**. For a manually installed copy, use an administrator PowerShell session:

```powershell
.\Uninstall-App.ps1
.\transport\Uninstall-Driver.ps1
```

The first command disables the adapter's startup task, requests a normal stop through a temporary SYSTEM task, waits for the actual adapter processes to exit, and removes the task and installed binaries. The temporary task has no automatic trigger and is removed afterward. If shutdown fails, startup remains disabled and the running adapter's files and driver are retained. A process that exits with a restoration error is reported in the log and can still be removed safely.

The second command removes the exact recorded virtual device, driver package, and certificate trust entries added by its installer. PawnIO remains installed. Source files, diagnostic logs, and the hardware configuration are retained.

## Build

```powershell
.\Build.ps1 -Publish
```

The project-local .NET 8 SDK is under `tools\dotnet`. Building needs no hardware access. See `transport\README.md` for native driver build inputs and signing details. The driver/client require the installed Microsoft Visual C++ runtime; this machine has version 14.51.36247.0.

Build the installer with `installer\Build-Installer.ps1`. It uses the portable Inno Setup 7 compiler under `tools\installer\inno` (or `-CompilerPath`), validates the signed package and prerequisite hashes, assembles a minimal payload, and emits the EXE, SHA-256 checksum, and payload manifest under `artifacts\installer`. `installer\dependencies\dependencies.json` records download provenance and redistribution notices. The WDK DevCon binary is excluded; the original MIT-licensed `RoyalDeviceSetup` helper handles the exact WinUHid device through Windows SetupAPI.

Installer verification includes PowerShell 5.1 lifecycle checks, compiler validation, and a separate non-administrator extraction harness (`installer\tests\PayloadSmoke.iss`) that checks the embedded payload without installing anything. A full privileged install/uninstall on fresh Windows remains untested.

## Remaining validation

Windows device enumeration and the first Dynamic Lighting frame delivery are verified on the current boot. A cold power-cycle has not been tested. Some ENE modules require volatile address assignment at `0x77` after a cold start; the current implementation does not perform that operation. If the saved addresses are absent, the adapter stops with diagnostics instead of writing to unverified devices. The startup task is configured, but operation after a cold boot remains to be verified.

The first complete host frame switches the controllers into direct mode. Immediately freezing an existing onboard animation at the earlier ownership-change notification is not implemented. The HID staging buffer starts black, so an initial partial update can make untouched LEDs black; normal whole-device Windows effects supply complete frames. Physical DIMM coordinates and update latency are approximate. These are prototype limitations, not a production conformance claim.

## Sources and third-party components

The HID reports follow the [USB Lighting and Illumination specification](https://www.usb.org/sites/default/files/hutrr84_-_lighting_and_illumination_page.pdf). Windows supports virtual LampArray devices through its HID stack: [Microsoft device documentation](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/dynamic-lighting-devices).

ENE register behavior was independently implemented from the [SignalRGB ENE RAM protocol implementation](https://gitlab.com/signalrgb/signal-plugins/-/blob/d3cdcd8dcc03faf5aaaccc72c732d896cbed3988/Plugins/Asus/ENE_RAM.js) and [Hypercolor controller mapping](https://github.com/hyperb1iss/hypercolor/blob/5e8557bee90400e415907f3f802a69981716a524/crates/hypercolor-hal/src/drivers/asus/smbus.rs). Neither application is required or shipped.

The signed [PawnIO module](https://github.com/namazso/PawnIO.Modules/releases/tag/0.2.11) is LGPL-2.1-or-later; its license is in `licenses`. Module SHA-256: `91F9B4B1C39E3D399CE48477A89D8F6BD3E58A2241064A4DAEC3A1513DFF56E5`. The virtual HID transport uses MIT-licensed [WinUHid](https://github.com/cgutman/WinUHid), pinned to `d6cebbef5c7909168d1f881185be8f607d6aefd4`; its license is preserved in `licenses` and with its source.
