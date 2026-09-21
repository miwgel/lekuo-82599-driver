/*
 * Intel 82599 advanced descriptor layouts.
 * Adapted from the BSD-3-Clause ixy ixgbe driver by Paul Emmerich:
 * https://github.com/emmericp/ixy
 * The full license and disclaimer are reproduced in IXY-LICENSE.txt.
 */

#ifndef LEKUO_IXGBE_DESCRIPTORS_H
#define LEKUO_IXGBE_DESCRIPTORS_H

#include <stdint.h>

struct IxgbeRxDescriptor {
    union {
        struct {
            uint64_t packetAddress;
            uint64_t headerAddress;
        } read;
        struct {
            uint64_t rssAndHeader;
            uint32_t statusAndError;
            uint16_t length;
            uint16_t vlan;
        } writeback;
    } fields;
};

struct IxgbeTxDescriptor {
    uint64_t bufferAddress;
    uint32_t commandTypeLength;
    uint32_t offloadStatus;
};

static_assert(sizeof(IxgbeRxDescriptor) == 16, "82599 RX descriptor size");
static_assert(sizeof(IxgbeTxDescriptor) == 16, "82599 TX descriptor size");

// MAXFRS.MFS counts Ethernet header through CRC; a VLAN header is added by
// the device. The receive buffer must hold an entire non-VLAN frame.
constexpr uint32_t kLekuoMTU = 9000;
constexpr uint32_t kEthernetHeaderBytes = 14;
constexpr uint32_t kEthernetCRCBytes = 4;
constexpr uint32_t kLekuoMaxFrameBytes =
    kLekuoMTU + kEthernetHeaderBytes + kEthernetCRCBytes;
constexpr uint32_t kLekuoMaxPacketBytes = kLekuoMTU + kEthernetHeaderBytes;
constexpr uint32_t kLekuoMaxRxPacketBytes = kLekuoMaxPacketBytes + 4; // VLAN
constexpr uint32_t kLekuoRxBufferBytes = 10 * 1024;
static_assert(kLekuoRxBufferBytes >= kLekuoMaxFrameBytes,
              "RX buffer must accommodate jumbo frames");

#endif
