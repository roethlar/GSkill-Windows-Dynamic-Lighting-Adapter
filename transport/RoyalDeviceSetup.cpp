// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Royal Dynamic Lighting contributors.
// Original, narrowly scoped WinUHid device installation helper.
#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <cfgmgr32.h>
#include <cstdio>
#include <cwchar>
#include <string>
#include <vector>
#include <stdexcept>

namespace {
constexpr wchar_t HardwareId[] = L"Root\\WinUHid";
constexpr GUID SystemClass = {0x4d36e97d, 0xe325, 0x11ce, {0xbf,0xc1,0x08,0x00,0x2b,0xe1,0x03,0x18}};
struct DeviceSet {
    HDEVINFO value;
    explicit DeviceSet(HDEVINFO v) : value(v) {}
    ~DeviceSet() { if (value != INVALID_HANDLE_VALUE) SetupDiDestroyDeviceInfoList(value); }
    DeviceSet(const DeviceSet&) = delete;
    DeviceSet& operator=(const DeviceSet&) = delete;
};
struct Failure { DWORD code; const wchar_t* operation; };
void Check(BOOL result, const wchar_t* operation) {
    if (!result) throw Failure{GetLastError(), operation};
}
void CheckSet(const DeviceSet& set) {
    if (set.value == INVALID_HANDLE_VALUE) throw Failure{GetLastError(), L"Create device information set"};
}
bool IsRoyalDevice(HDEVINFO set, SP_DEVINFO_DATA& device) {
    DWORD type = 0, bytes = 0;
    if (!SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_HARDWAREID, &type, nullptr, 0, &bytes)) {
        const DWORD error = GetLastError();
        if (error == ERROR_INVALID_DATA) return false;
        if (error != ERROR_INSUFFICIENT_BUFFER) throw Failure{error, L"Read hardware ID size"};
    }
    if (bytes < 2 * sizeof(wchar_t) || bytes > 65536 || bytes % sizeof(wchar_t))
        throw Failure{ERROR_INVALID_DATA, L"Invalid hardware ID buffer"};
    std::vector<wchar_t> ids(bytes / sizeof(wchar_t) + 2, L'\0');
    Check(SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_HARDWAREID, &type,
        reinterpret_cast<PBYTE>(ids.data()), bytes, nullptr), L"Read hardware IDs");
    if (type != REG_MULTI_SZ) throw Failure{ERROR_INVALID_DATA, L"Hardware ID registry type"};
    for (const wchar_t* id = ids.data(); *id; id += wcslen(id) + 1)
        if (_wcsicmp(id, HardwareId) == 0) return true;
    return false;
}
std::wstring InstanceId(HDEVINFO set, SP_DEVINFO_DATA& device) {
    wchar_t id[MAX_DEVICE_ID_LEN]{};
    Check(SetupDiGetDeviceInstanceIdW(set, &device, id, ARRAYSIZE(id), nullptr), L"Read device instance ID");
    return id;
}
void RequireNoExistingDevice() {
    DeviceSet set(SetupDiGetClassDevsW(nullptr, L"ROOT", nullptr, DIGCF_ALLCLASSES));
    CheckSet(set);
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA device{}; device.cbSize = sizeof(device);
        if (!SetupDiEnumDeviceInfo(set.value, index, &device)) {
            if (GetLastError() == ERROR_NO_MORE_ITEMS) break;
            throw Failure{GetLastError(), L"Enumerate devices"};
        }
        if (IsRoyalDevice(set.value, device)) {
            fwprintf(stderr, L"Existing WinUHid device: %ls\n", InstanceId(set.value, device).c_str());
            throw Failure{ERROR_ALREADY_EXISTS, L"Refusing to replace existing WinUHid device"};
        }
    }
}
bool NeedsRestart(HDEVINFO set, SP_DEVINFO_DATA& device) {
    SP_DEVINSTALL_PARAMS_W parameters{}; parameters.cbSize = sizeof(parameters);
    Check(SetupDiGetDeviceInstallParamsW(set, &device, &parameters), L"Read restart status");
    return (parameters.Flags & (DI_NEEDREBOOT | DI_NEEDRESTART)) != 0;
}
void SetQuiet(HDEVINFO set, SP_DEVINFO_DATA& device) {
    SP_DEVINSTALL_PARAMS_W parameters{}; parameters.cbSize = sizeof(parameters);
    Check(SetupDiGetDeviceInstallParamsW(set, &device, &parameters), L"Read device install parameters");
    parameters.Flags |= DI_QUIETINSTALL;
    Check(SetupDiSetDeviceInstallParamsW(set, &device, &parameters), L"Disable installation UI");
}
bool RemoveNode(HDEVINFO set, SP_DEVINFO_DATA& device) {
    SetQuiet(set, device);
    SP_REMOVEDEVICE_PARAMS parameters{};
    parameters.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
    parameters.ClassInstallHeader.InstallFunction = DIF_REMOVE;
    parameters.Scope = DI_REMOVEDEVICE_GLOBAL;
    Check(SetupDiSetClassInstallParamsW(set, &device, &parameters.ClassInstallHeader,
        sizeof(parameters)), L"Set device removal parameters");
    Check(SetupDiCallClassInstaller(DIF_REMOVE, set, &device), L"Remove WinUHid device");
    return NeedsRestart(set, device);
}
DWORD Install(const wchar_t* inf) {
    // Only an absolute Windows path to this package is accepted.
    const size_t length = wcslen(inf);
    if (length < 4 || !((inf[1] == L':' && (inf[2] == L'\\' || inf[2] == L'/')) ||
        (inf[0] == L'\\' && inf[1] == L'\\')))
        throw Failure{ERROR_BAD_PATHNAME, L"INF path must be absolute"};
    wchar_t fullInf[32768]{};
    const DWORD pathLength = GetFullPathNameW(inf, ARRAYSIZE(fullInf), fullInf, nullptr);
    if (!pathLength || pathLength >= ARRAYSIZE(fullInf))
        throw Failure{ERROR_BAD_PATHNAME, L"Resolve INF path"};
    const wchar_t* basename = wcsrchr(fullInf, L'\\');
    if (!basename || _wcsicmp(basename + 1, L"WinUHidDriver.inf"))
        throw Failure{ERROR_INVALID_NAME, L"Only WinUHidDriver.inf is supported"};
    GUID classId{}; wchar_t className[MAX_CLASS_NAME_LEN]{};
    Check(SetupDiGetINFClassW(fullInf, &classId, className, ARRAYSIZE(className), nullptr), L"Read INF class");
    if (!IsEqualGUID(classId, SystemClass))
        throw Failure{ERROR_INVALID_DATA, L"Unexpected INF device class"};
    RequireNoExistingDevice();
    // Record the precise published name before device binding. If binding
    // subsequently fails, the caller can remove this newly staged package.
    // An identical package that was present beforehand remains unowned.
    wchar_t publishedPath[MAX_PATH]{};
    PWSTR publishedName = nullptr;
    const BOOL packageAdded = SetupCopyOEMInfW(fullInf, nullptr, SPOST_PATH,
        SP_COPY_NOOVERWRITE, publishedPath, ARRAYSIZE(publishedPath), nullptr, &publishedName);
    if (!packageAdded && GetLastError() != ERROR_FILE_EXISTS)
        throw Failure{GetLastError(), L"Stage WinUHid package"};
    if (!publishedName || !*publishedName)
        throw Failure{ERROR_INVALID_DATA, L"Read staged package identity"};
    wprintf(L"PublishedInf=%ls\nPackageAdded=%d\n", publishedName, packageAdded ? 1 : 0);
    fflush(stdout);
    DeviceSet set(SetupDiCreateDeviceInfoList(&classId, nullptr)); CheckSet(set);
    SP_DEVINFO_DATA device{}; device.cbSize = sizeof(device);
    Check(SetupDiCreateDeviceInfoW(set.value, className, &classId, L"WinUHid Virtual HID Enumerator",
        nullptr, DICD_GENERATE_ID, &device), L"Create WinUHid device information");
    constexpr wchar_t hardwareIds[] = L"Root\\WinUHid\0";
    Check(SetupDiSetDeviceRegistryPropertyW(set.value, &device, SPDRP_HARDWAREID,
        reinterpret_cast<const BYTE*>(hardwareIds), sizeof(hardwareIds)), L"Assign WinUHid hardware ID");
    SetQuiet(set.value, device);
    Check(SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set.value, &device), L"Register WinUHid root device");
    try {
        const std::wstring instance = InstanceId(set.value, device);
        wprintf(L"CreatedInstanceId=%ls\n", instance.c_str());
        BOOL restart = FALSE;
        Check(UpdateDriverForPlugAndPlayDevicesW(nullptr, HardwareId, fullInf,
            INSTALLFLAG_FORCE | INSTALLFLAG_NONINTERACTIVE, &restart), L"Install WinUHid driver package");
        const bool needRestart = restart || NeedsRestart(set.value, device);
        wprintf(L"InstalledInstanceId=%ls\nRebootRequired=%d\n", instance.c_str(), needRestart ? 1 : 0);
        return needRestart ? ERROR_SUCCESS_REBOOT_REQUIRED : ERROR_SUCCESS;
    } catch (...) {
        try {
            const bool restart = RemoveNode(set.value, device);
            fwprintf(stderr, L"Removed newly created device after installation failure. RebootRequired=%d\n", restart ? 1 : 0);
        } catch (const Failure& rollback) {
            fwprintf(stderr, L"Rollback failed: %ls (Win32 %lu, 0x%08lX). The installation receipt must retain this device.\n",
                rollback.operation, rollback.code, rollback.code);
        }
        throw;
    }
}
DWORD Remove(const wchar_t* instance) {
    if (_wcsnicmp(instance, L"ROOT\\", 5) || !instance[5] || wcspbrk(instance, L"*?\r\n"))
        throw Failure{ERROR_INVALID_NAME, L"Removal requires one exact ROOT device instance"};
    DeviceSet set(SetupDiCreateDeviceInfoList(nullptr, nullptr)); CheckSet(set);
    SP_DEVINFO_DATA device{}; device.cbSize = sizeof(device);
    if (!SetupDiOpenDeviceInfoW(set.value, instance, nullptr, 0, &device)) {
        const DWORD error = GetLastError();
        if (error == ERROR_NO_SUCH_DEVINST || error == ERROR_NO_SUCH_DEVICE || error == ERROR_NOT_FOUND) {
            wprintf(L"Device already absent: %ls\n", instance);
            return ERROR_SUCCESS;
        }
        throw Failure{error, L"Open recorded device instance"};
    }
    if (!IsRoyalDevice(set.value, device))
        throw Failure{ERROR_INVALID_DATA, L"Recorded device is not Root\\WinUHid"};
    if (_wcsicmp(InstanceId(set.value, device).c_str(), instance))
        throw Failure{ERROR_INVALID_DATA, L"Device instance identity changed"};
    const bool restart = RemoveNode(set.value, device);
    wprintf(L"RemovedInstanceId=%ls\nRebootRequired=%d\n", instance, restart ? 1 : 0);
    return restart ? ERROR_SUCCESS_REBOOT_REQUIRED : ERROR_SUCCESS;
}
}
int wmain(int argc, wchar_t** argv) {
    if (argc == 2 && (!_wcsicmp(argv[1], L"--help") || !_wcsicmp(argv[1], L"/?"))) {
        wprintf(L"RoyalDeviceSetup install <absolute WinUHidDriver.inf path>\nRoyalDeviceSetup remove <exact ROOT instance ID>\nOnly Root\\WinUHid is supported. Returns 0 or 3010 on success.\n");
        return 0;
    }
    try {
        if (argc != 3) throw Failure{ERROR_INVALID_PARAMETER, L"Expected install/remove and one argument"};
        if (!_wcsicmp(argv[1], L"install")) return static_cast<int>(Install(argv[2]));
        if (!_wcsicmp(argv[1], L"remove")) return static_cast<int>(Remove(argv[2]));
        throw Failure{ERROR_INVALID_PARAMETER, L"Unknown operation"};
    } catch (const Failure& error) {
        fwprintf(stderr, L"%ls failed (Win32 %lu, 0x%08lX).\n", error.operation, error.code, error.code);
        return static_cast<int>(error.code ? error.code : ERROR_GEN_FAILURE);
    } catch (const std::exception&) {
        fwprintf(stderr, L"Device setup failed due to an internal allocation or runtime error.\n");
        return ERROR_GEN_FAILURE;
    }
}
