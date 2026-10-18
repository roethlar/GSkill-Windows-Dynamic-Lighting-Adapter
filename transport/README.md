# Windows Dynamic Lighting transport

This component presents the app's HID LampArray descriptor and feature reports through the WinUHid user-mode driver. It contains no memory-controller or RAM-register code. The application owns report semantics and passes GET/SET callbacks to `WinUHidTransport`.

```csharp
using var transport = new WinUHidTransport(
    lamp.ReportDescriptor,
    "RoyalDynamicLighting-RAM",
    lamp.GetFeature,
    report => lamp.SetFeature(report));
transport.ReportError += error => Console.Error.WriteLine(error.Message);
transport.Start();
```

Callbacks execute on a dedicated report thread. Feature buffers include the report ID at byte zero. Queue RAM writes on a separate worker so HID requests complete promptly. Dispose the transport from the application's owning thread; it cancels native polling, waits for outstanding callbacks, and removes the virtual device.

## Build inputs

- Visual Studio 2022 Build Tools with MSVC x64 and Windows SDK 10.0.26100.0.
- .NET SDK 8 for the managed project.
- WinUHid source in `../third_party/WinUHid`, pinned for this build to `d6cebbef5c7909168d1f881185be8f607d6aefd4`.
- Official `Microsoft.Windows.WDK.x64` NuGet package version `10.0.26100.6584`, extracted under `packages/wdk`.

`Build-Native.ps1` compiles the unchanged upstream WinUHid client and UMDF2 source, stamps the INF, generates its catalog, and builds an ABI probe. It uses the extracted WDK files directly and does not install a driver or change certificate trust. The driver targets x64 Windows 11 and UMDF 2.33, using Microsoft's existing WUDFRd and VHF components. It also requires the Microsoft Visual C++ runtime (`VCRUNTIME140.dll`).

`Build-DeviceSetup.ps1` builds the original installation helper using only MSVC and the Windows SDK; it does not require the WDK. It uses `/MT` to include the C++ runtime statically. The redistributable installer carries this helper and its MIT notice, without DevCon or any other WDK tools.

```powershell
.\transport\Build-Native.ps1
.\transport\Build-DeviceSetup.ps1
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = 'false'
.\tools\dotnet\dotnet.exe run --project .\transport\tests\TransportSmoke.csproj --configuration Release
```

`native/WinUHid.dll` is copied transitively beside the managed application. `driver/` contains `WinUHidDriver.dll`, `WinUHidDriver.inf`, and `WinUHidDriver.cat`. The package remains locally signed, but the application, driver, and local certificate trust have now been uninstalled from this machine. Rebuilding produces unsigned outputs that must be signed again before installation.

## Installation package

The scripts deliberately separate creating a locally signed package from trusting and installing it:

1. `Sign-Driver.ps1` creates a code-signing end-entity certificate in the current user's personal certificate store, signs the driver and catalog, exports its public certificate and file-hash manifest, and deletes the temporary signing certificate and private key. It adds no trusted root or publisher certificate.
2. Elevated `Install-Driver.ps1 -TrustLocalCertificate` first runs the read-only `Verify-Package.ps1` check. This checks the exact three package hashes, signer identity, and native WinVerifyTrust result. It accepts only `S_OK` (`0x00000000`) or the expected untrusted local root (`CERT_E_UNTRUSTEDROOT`, `0x800B0109`); digest errors, missing/invalid signatures, and other trust errors fail. Validation uses cached/local certificate data and displays no UI. It then adds the public signing certificate to the local machine's Root and TrustedPublisher stores and uses `native/RoyalDeviceSetup.exe` to create the WinUHid enumerator and install the package through Windows SetupAPI. It records the exact device, published INF, thumbprint, newly added trust entries, and restart requirement in `%ProgramData%\RoyalDynamicLighting\transport-install.json`. The state directory and file are owned by Administrators with protected ACLs: Administrators/SYSTEM full control, Users read/execute. Both scripts reject reparse points and the uninstaller validates the receipt's ownership/ACL before reading it. Installation refuses to replace an existing WinUHid enumerator.
3. Elevated `Uninstall-Driver.ps1` removes only the recorded device/package and the certificate trust entries that this installer added. It can also reverse recorded partial installation changes.

The local certificate has the code-signing purpose and is not a certificate authority. The scripts do not change Secure Boot, memory integrity, driver enforcement, or test-signing boot mode. The driver and PawnIO require the application to run elevated.

`RoyalDeviceSetup` is original MIT-licensed code restricted to `Root\WinUHid`. It refuses an existing matching root device, records the exact staged package before binding, removes its newly created device if installation fails, and verifies the hardware ID before removing an exact recorded instance. Its output distinguishes newly added packages from identical packages already present, so cleanup preserves pre-existing packages. It is built with the static C++ runtime and returns `0` on success or `3010` when a restart is required. The PowerShell scripts emit a final object containing `Operation`, `RebootRequired`, `InstanceId`, and `PublishedInf` so the outer installer can handle restart requests. Uninstallation journals each completed device/package removal to support retry after partial failure. The scripts retain a DevCon fallback for older development workspaces; the packaged installer uses only the new helper and does not redistribute WDK tools.

The enumerator's Device Manager name is `WinUHid Virtual HID Enumerator`. During runtime validation, Windows exposed the LampArray as `HID-compliant device`. VHF does not accept HID manufacturer/product strings through its public configuration. A fixed application-specific container GUID and stable instance ID keep this virtual device separate from unrelated hardware.

## Validation performed

- Native x64 client and UMDF driver compile successfully.
- Inf2Cat signability test passes without errors or warnings for Windows 11 CO, NI, and GE targets.
- WDK InfVerif `/u` passes.
- Managed P/Invoke structure sizes and field offsets match a native program compiled against the actual upstream header, including packed report payload offsets.
- Native DLL loading and the missing-driver error path pass.
- PowerShell scripts parse successfully.
- Native signature verification against the signed DLL and catalog returns the expected `0x800B0109` before certificate trust. A corrupted copy is rejected with `TRUST_E_BAD_DIGEST` (`0x80096010`); the unsigned client DLL is rejected with `TRUST_E_NOSIGNATURE` (`0x800B0100`). These checks are reproducible with `tests/Test-Signatures.ps1` and leave the signed package unchanged.
- The earlier authorized installation succeeded: enumerator `ROOT\SYSTEM\0001`, published package `oem39.inf`, device error code zero. These historical identifiers describe this machine; removal used the recorded installation receipt.
- During that installation, Windows WinRT enumerated VID `0000`, PID `524C` as a connected, enabled, 16-lamp chassis LampArray. Its availability was false while Windows owned lighting control.
- Application logs confirmed that Windows acquired lighting control and its first host frame was applied to both RAM controllers.
- The replacement device setup helper builds with MSVC warnings treated as errors, has no dynamic Visual C++ runtime dependency, and passes nonmutating argument-rejection checks. Its removal branch successfully removed the real WinUHid device with exit code zero. Its installation branch has not yet been tested on a clean Windows installation; the earlier successful installation used DevCon.
- Authorized removal completed without a restart: the helper removed the device, PnPUtil removed `oem39.inf`, and the installer-owned Root and TrustedPublisher certificate entries were removed. The application and all associated scheduled tasks, including the temporary SYSTEM shutdown helper, are gone.

Driver loading, certificate trust, HID report delivery, RAM output, and actual removal have been verified on this machine. The current state is uninstalled. Interactive Settings presentation and installation through the replacement helper on a clean Windows installation remain untested.

Sources: [WinUHid](https://github.com/cgutman/WinUHid), [Microsoft VHF configuration](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/vhf/ns-vhf-_vhf_config), [Microsoft Dynamic Lighting devices](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/dynamic-lighting-devices), [WDK NuGet installation](https://learn.microsoft.com/en-us/windows-hardware/drivers/install-the-wdk-using-nuget). WinUHid is MIT licensed; its license is preserved with the source and driver package.
