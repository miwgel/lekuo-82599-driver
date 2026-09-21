/*
 * Intel 82599 register offsets and descriptor bits used by this driver.
 * Values are from Intel's 82599 datasheet and the BSD-licensed ixy driver;
 * see ../IXY-LICENSE.txt for the latter's license and disclaimer.
 */

#ifndef LEKUO_IXGBE_REGISTERS_H
#define LEKUO_IXGBE_REGISTERS_H

#include <stdint.h>
#include "IxgbeDescriptors.h"

namespace ixgbe {
constexpr uint32_t control = 0x00000;
constexpr uint32_t status = 0x00008;
constexpr uint32_t controlExtension = 0x00018;
constexpr uint32_t eepromControl = 0x10010;
constexpr uint32_t interruptMaskClear = 0x00888;
constexpr uint32_t rxDescriptorBaseLow = 0x01000;
constexpr uint32_t rxDescriptorBaseHigh = 0x01004;
constexpr uint32_t rxDescriptorLength = 0x01008;
constexpr uint32_t rxDescriptorHead = 0x01010;
constexpr uint32_t rxDescriptorTail = 0x01018;
constexpr uint32_t rxDescriptorControl = 0x01028;
constexpr uint32_t rxSplitControl = 0x02100;
constexpr uint32_t rxDirectCacheAccessControl = 0x02200;
constexpr uint32_t rxControl = 0x03000;
constexpr uint32_t rxPacketBufferSize = 0x03c00;
constexpr uint32_t receiveDataReadControl = 0x02f00;
constexpr uint32_t filterControl = 0x05080;
constexpr uint32_t receiveAddressLow0 = 0x05400;
constexpr uint32_t receiveAddressHigh0 = 0x05404;
constexpr uint32_t highlanderControl = 0x04240;
constexpr uint32_t maxFrameSize = 0x04268;
constexpr uint32_t autoControl = 0x042a0;
constexpr uint32_t links = 0x042a4;
constexpr uint32_t autoControl2 = 0x042a8;
constexpr uint32_t txDescriptorBaseLow = 0x06000;
constexpr uint32_t txDescriptorBaseHigh = 0x06004;
constexpr uint32_t txDescriptorLength = 0x06008;
constexpr uint32_t txDescriptorHead = 0x06010;
constexpr uint32_t txDescriptorTail = 0x06018;
constexpr uint32_t txDescriptorControl = 0x06028;
constexpr uint32_t transmitDMAControl = 0x04a80;
constexpr uint32_t txPacketBufferSize = 0x0cc00;
constexpr uint32_t transmitMaxSizeRequest = 0x08100;
constexpr uint32_t transmitArbiterControl = 0x04900;
constexpr uint32_t securityReceiveControl = 0x08d00;
constexpr uint32_t securityReceiveStatus = 0x08d04;
constexpr uint32_t goodPacketsTransmitted = 0x04080;
constexpr uint32_t goodOctetsTransmittedLow = 0x04090;
constexpr uint32_t goodOctetsTransmittedHigh = 0x04094;
constexpr uint32_t dmaGoodTxPackets = 0x087a0;

constexpr uint32_t controlSoftwareReset = 0x04000000;
constexpr uint32_t controlMasterDisable = 0x00000004;
constexpr uint32_t statusMasterEnabled = 0x00080000;
constexpr uint32_t controlExtensionNoSnoopDisable = 0x00010000;
constexpr uint32_t eepromAutoReadDone = 0x00000200;
constexpr uint32_t receiveDMAInitialized = 0x00000008;
constexpr uint32_t receiveCRCStrip = 0x00000002;
constexpr uint32_t receiveRSCFirstSizeMask = 0x003e0000;
constexpr uint32_t receiveEnable = 0x00000001;
constexpr uint32_t receiveQueueEnable = 0x02000000;
constexpr uint32_t securityReceiveDisable = 0x00000002;
constexpr uint32_t securityReceiveReady = 0x00000001;
constexpr uint32_t transmitQueueEnable = 0x02000000;
constexpr uint32_t transmitDMAEnable = 0x00000001;
constexpr uint32_t transmitArbiterDisable = 0x00000040;
constexpr uint32_t receiveBroadcastAccept = 0x00000400;
constexpr uint32_t receiveAllMulticast = 0x00000100;
constexpr uint32_t receiveAllUnicast = 0x00000200;
constexpr uint32_t receiveAddressValid = 0x80000000;
constexpr uint32_t receivePacketBuffer128KiB = 128 * 1024;
constexpr uint32_t transmitPacketBuffer40KiB = 40 * 1024;
constexpr uint32_t rxDirectCacheAccessReservedBit = 1u << 12;
constexpr uint32_t rxSplitBufferSizeMask = 0x0000007f;
constexpr uint32_t rxSplitDescriptorTypeMask = 0x0e000000;
constexpr uint32_t rxSplitOneBufferDescriptor = 0x02000000;
constexpr uint32_t rxSplitDropWhenEmpty = 0x10000000;
constexpr uint32_t rxSplit10KiBBuffer = kLekuoRxBufferBytes / 1024;
constexpr uint32_t jumboFrameRegisterValue = kLekuoMaxFrameBytes << 16;
constexpr uint32_t highlanderReceiveCRCStrip = 0x00000002;
constexpr uint32_t highlanderJumboEnable = 0x00000004;
constexpr uint32_t highlanderMacLoopback = 0x00008000;
constexpr uint32_t highlanderTransmitPad = 0x00000400;
constexpr uint32_t highlanderTransmitCRC = 0x00000001;
constexpr uint32_t autoControlForceLinkUp = 0x00000001;
constexpr uint32_t autoControlRestart = 0x00001000;
constexpr uint32_t autoControlLinkModeMask = 0x0000e000;
constexpr uint32_t autoControl10GbNoNegotiation = 0x00002000;
constexpr uint32_t maxFrameSizeMask = 0xffff0000;
constexpr uint32_t rxDescriptorDone = 0x00000001;
constexpr uint32_t rxEndOfPacket = 0x00000002;
constexpr uint32_t rxFrameErrorMask = 0x3b000000;
constexpr uint32_t txDescriptorDone = 0x00000001;
constexpr uint32_t txEndOfPacket = 0x01000000;
constexpr uint32_t txInsertCRC = 0x02000000;
constexpr uint32_t txReportStatus = 0x08000000;
constexpr uint32_t txExtended = 0x20000000;
constexpr uint32_t txAdvancedData = 0x00300000;
constexpr uint32_t txPayloadLengthShift = 14;
constexpr uint32_t linkUp = 0x40000000;

constexpr uint16_t ringEntries = 512;
constexpr uint16_t ringMask = ringEntries - 1;
inline uint16_t next(uint16_t index) { return (index + 1) & ringMask; }
static_assert(kLekuoMaxFrameBytes == 9018, "9000-byte MTU includes Ethernet header and CRC");
static_assert(rxSplit10KiBBuffer == 10, "SRRCTL buffer field uses KiB units");
static_assert(jumboFrameRegisterValue == 0x233a0000,
              "MAXFRS.MFS occupies bits 31:16");
}

#endif
