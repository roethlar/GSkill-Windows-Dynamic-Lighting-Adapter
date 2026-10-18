#include <Windows.h>
#include <stddef.h>
#include <stdio.h>
#include "WinUHid.h"

int main()
{
    printf("{\"configSize\":%zu,\"descriptorOffset\":%zu,\"containerOffset\":%zu,\"instanceOffset\":%zu,\"hardwareOffset\":%zu,\"periodOffset\":%zu,\"eventReportOffset\":%zu,\"eventLengthOffset\":%zu,\"eventDataOffset\":%zu}\n",
        sizeof(WINUHID_DEVICE_CONFIG), offsetof(WINUHID_DEVICE_CONFIG, ReportDescriptor),
        offsetof(WINUHID_DEVICE_CONFIG, ContainerId), offsetof(WINUHID_DEVICE_CONFIG, InstanceID),
        offsetof(WINUHID_DEVICE_CONFIG, HardwareIDs), offsetof(WINUHID_DEVICE_CONFIG, ReadReportPeriodUs),
        offsetof(WINUHID_EVENT, ReportId), offsetof(WINUHID_EVENT, Read.DataLength), offsetof(WINUHID_EVENT, Write.Data));
    return 0;
}
