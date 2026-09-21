/*
 * Experimental PCI and packet-path implementation for the Lekuo DTB3F21 (82599ES).
 * Based on Apple's NetworkingDriverKit sample; see ../LICENSE.txt.
 *
 * This development build enables the first PCI function. It can replace an
 * existing network driver and directly programs device registers and DMA.
 * Review the hardware match and keep a separate recovery network path.
 */

#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODMACommand.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/OSAction.h>
#include <PCIDriverKit/IOPCIDevice.h>
#include <PCIDriverKit/IOPCIFamilyDefinitions.h>
#include <NetworkingDriverKit/NetworkingDriverKit.h>
#include <os/log.h>
#include <atomic>
#include <string.h>
#include <time.h>

#include "Lekuo82599.h"
#include "IxgbeDescriptors.h"
#include "IxgbeRegisters.h"

#undef super
#define super IOUserNetworkEthernet

// Enable only in a separately reviewed development build for function 1.
constexpr bool kEnableMacLoopbackPrototype = false;
// Enable only in a temporary live-link diagnostic build. Intel's GPTC/GOTC
// counters are read-to-clear, so ordinary builds must leave them untouched.
constexpr bool kEnableTxCounterDiagnostics = false;
// Enabled only in a separately staged flow-diagnostic build.
constexpr bool kEnableFlowDiagnostics = true;

struct RingMemory {
    IOBufferMemoryDescriptor *storage;
    IODMACommand *dma;
    uint64_t cpuAddress;
    uint64_t deviceAddress;
    bool prepared;
};

static void releaseRing(RingMemory *ring)
{
    if (ring->prepared) {
        ring->dma->CompleteDMA(kIODMACommandCompleteDMANoOptions);
        ring->prepared = false;
    }
    OSSafeReleaseNULL(ring->dma);
    OSSafeReleaseNULL(ring->storage);
    ring->cpuAddress = 0;
    ring->deviceAddress = 0;
}

static kern_return_t allocateRing(IOPCIDevice *pci, uint64_t bytes, RingMemory *ring)
{
    IOAddressSegment cpuRange = {};
    IODMACommandSpecification specification = {};
    uint64_t flags = 0;
    uint32_t segmentCount = 32;
    IOAddressSegment segments[32] = {};
    kern_return_t result = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionInOut, bytes, 4096, &ring->storage);
    if (result != kIOReturnSuccess) return result;

    result = ring->storage->SetLength(bytes);
    if (result != kIOReturnSuccess) goto fail;

    result = ring->storage->GetAddressRange(&cpuRange);
    if (result != kIOReturnSuccess) goto fail;
    if (cpuRange.address == 0 || cpuRange.length < bytes) {
        result = kIOReturnNoMemory;
        goto fail;
    }
    memset(reinterpret_cast<void *>(cpuRange.address), 0, bytes);

    specification.options = kIODMACommandSpecificationNoOptions;
    specification.maxAddressBits = 64;
    result = IODMACommand::Create(pci, kIODMACommandCreateNoOptions,
                                  &specification, &ring->dma);
    if (result != kIOReturnSuccess) goto fail;

    result = ring->dma->PrepareForDMA(kIODMACommandPrepareForDMANoOptions,
                                      ring->storage, 0, bytes, &flags,
                                      &segmentCount, segments);
    if (result != kIOReturnSuccess) goto fail;
    ring->prepared = true;
    if (segmentCount != 1 || segments[0].address == 0 ||
        segments[0].length < bytes) {
        result = kIOReturnUnsupported;
        goto fail;
    }
    ring->deviceAddress = segments[0].address;
    ring->cpuAddress = cpuRange.address;
    return kIOReturnSuccess;

fail:
    releaseRing(ring);
    return result;
}

struct Lekuo82599_IVars {
    IOPCIDevice *pci;
    RingMemory rxRing;
    RingMemory txRing;
    IODispatchQueue *dispatchQueue;
    IOUserNetworkPacketBufferPool *pool;
    IOUserNetworkTxSubmissionQueue *txSubmission;
    IOUserNetworkTxCompletionQueue *txCompletion;
    IOUserNetworkRxSubmissionQueue *rxSubmission;
    IOUserNetworkRxCompletionQueue *rxCompletion;
    OSAction *txAction;
    IOTimerDispatchSource *pollTimer;
    OSAction *pollAction;
    IOUserNetworkPacket *rxPackets[ixgbe::ringEntries];
    uint16_t rxOffsets[ixgbe::ringEntries];
    IOUserNetworkPacket *txPackets[ixgbe::ringEntries];
    uint16_t rxConsumer;
    uint16_t rxFilled;
    uint16_t txProducer;
    uint16_t txConsumer;
    uint64_t rxFromSubmission;
    uint64_t rxFromPool;
    uint64_t rxAcquireFailures;
    uint64_t rxDelivered;
    uint64_t rxDropped;
    uint64_t txSubmitted;
    uint64_t txCompleted;
    uint64_t flowLastLogNs;
    uint32_t currentMtu;
    uint32_t savedAutoControl;
    uint32_t savedHighlanderControl;
    bool promiscuous;
    bool hardwareReady;
    bool dmaMayBeActive;
    bool interfaceEnabled;
    bool linkReportedUp;
    bool baseStarted;
    bool pciOpened;
    bool pciMemoryEnabled;
    bool macLoopbackConfigured;
};

static bool isInterfaceEnabled(const Lekuo82599_IVars *state)
{
    return __atomic_load_n(&state->interfaceEnabled, __ATOMIC_ACQUIRE);
}

static void setInterfaceEnabled(Lekuo82599_IVars *state, bool enabled)
{
    __atomic_store_n(&state->interfaceEnabled, enabled, __ATOMIC_RELEASE);
}

// After disabling packet/timer sources, wait for callbacks already queued or
// executing before quiescing DMA or releasing packet objects. Driver methods
// may themselves run on this queue, in which case they are already ordered.
static void drainPacketCallbacks(Lekuo82599_IVars *state)
{
    if (state->dispatchQueue != nullptr && !state->dispatchQueue->OnQueue())
        state->dispatchQueue->DispatchSync(^{});
}

static kern_return_t setPciCommandBits(IOPCIDevice *pci, uint16_t setBits,
                                        uint16_t clearBits)
{
    if (pci == nullptr) return kIOReturnBadArgument;
    uint16_t command = 0xffff;
    pci->ConfigurationRead16(0x04, &command);
    if (command == 0xffff) return kIOReturnIOError;
    uint16_t desired = (command | setBits) & ~clearBits;
    pci->ConfigurationWrite16(0x04, desired);
    uint16_t actual = 0xffff;
    pci->ConfigurationRead16(0x04, &actual);
    if (actual == 0xffff || (actual & (setBits | clearBits)) !=
                               (desired & (setBits | clearBits)))
        return kIOReturnIOError;
    return kIOReturnSuccess;
}

static kern_return_t waitForRegister(IOPCIDevice *pci, uint32_t offset,
                                     uint32_t mask, uint32_t expected,
                                     uint32_t attempts, uint32_t delayUs)
{
    for (uint32_t n = 0; n < attempts; ++n) {
        uint32_t value = 0xffffffff;
        pci->MemoryRead32(0, offset, &value);
        if (value == 0xffffffff) return kIOReturnIOError;
        if ((value & mask) == expected) return kIOReturnSuccess;
        IODelay(delayUs);
    }
    return kIOReturnTimeout;
}

// Development-only MAC TX-to-RX loopback on the inactive second function.
// This tests the PCIe/DMA/MAC paths, not the SFP or the external link.
static kern_return_t configureMacLoopback(Lekuo82599_IVars *state)
{
    if (state == nullptr || state->pci == nullptr ||
        state->macLoopbackConfigured) return kIOReturnBadArgument;
    uint32_t autoControl = 0xffffffff;
    uint32_t highlander = 0xffffffff;
    state->pci->MemoryRead32(0, ixgbe::autoControl, &autoControl);
    state->pci->MemoryRead32(0, ixgbe::highlanderControl, &highlander);
    if (autoControl == 0xffffffff || highlander == 0xffffffff)
        return kIOReturnIOError;
    // This test owns only the loopback state it creates. A pre-existing loop
    // means the port is already under an unexpected configuration.
    if ((highlander & ixgbe::highlanderMacLoopback) != 0)
        return kIOReturnBusy;
    state->savedAutoControl = autoControl;
    state->savedHighlanderControl = highlander;
    state->macLoopbackConfigured = true; // Also restore after partial setup.
    state->pci->MemoryWrite32(
        0, ixgbe::autoControl,
        (autoControl & ~ixgbe::autoControlLinkModeMask) |
            ixgbe::autoControl10GbNoNegotiation |
            ixgbe::autoControlForceLinkUp | ixgbe::autoControlRestart);
    state->pci->MemoryWrite32(0, ixgbe::highlanderControl,
                               highlander | ixgbe::highlanderMacLoopback);
    uint32_t actualAuto = 0xffffffff;
    uint32_t actualHighlander = 0xffffffff;
    state->pci->MemoryRead32(0, ixgbe::autoControl, &actualAuto);
    state->pci->MemoryRead32(0, ixgbe::highlanderControl, &actualHighlander);
    if (actualAuto == 0xffffffff || actualHighlander == 0xffffffff ||
        (actualAuto & (ixgbe::autoControlLinkModeMask |
                       ixgbe::autoControlForceLinkUp)) !=
            (ixgbe::autoControl10GbNoNegotiation |
             ixgbe::autoControlForceLinkUp) ||
        (actualHighlander & ixgbe::highlanderMacLoopback) == 0)
        return kIOReturnIOError;
    return kIOReturnSuccess;
}

static kern_return_t restoreMacLoopback(Lekuo82599_IVars *state)
{
    if (state == nullptr || state->pci == nullptr) return kIOReturnBadArgument;
    if (!state->macLoopbackConfigured) return kIOReturnSuccess;
    // Remove the loop before allowing the NVM link mode to negotiate again.
    state->pci->MemoryWrite32(0, ixgbe::highlanderControl,
                               state->savedHighlanderControl &
                                   ~ixgbe::highlanderMacLoopback);
    state->pci->MemoryWrite32(0, ixgbe::autoControl,
                               state->savedAutoControl |
                                   ixgbe::autoControlRestart);
    uint32_t actual = 0xffffffff;
    state->pci->MemoryRead32(0, ixgbe::highlanderControl, &actual);
    if (actual == 0xffffffff ||
        (actual & ixgbe::highlanderMacLoopback) != 0)
        return kIOReturnIOError;
    state->pci->MemoryRead32(0, ixgbe::autoControl, &actual);
    if (actual == 0xffffffff ||
        (actual & (ixgbe::autoControlLinkModeMask |
                   ixgbe::autoControlForceLinkUp)) !=
            (state->savedAutoControl &
             (ixgbe::autoControlLinkModeMask |
              ixgbe::autoControlForceLinkUp)))
        return kIOReturnIOError;
    state->macLoopbackConfigured = false;
    return kIOReturnSuccess;
}

// The 82599's CTRL.RST is per PCI function. PCIDriverKit's Reset method is
// device-wide on a multifunction device, so it must not be used here. This
// routine is compiled but not called until ownership and teardown are ready.
[[maybe_unused]] static kern_return_t resetOneFunction(IOPCIDevice *pci)
{
    if (pci == nullptr) return kIOReturnBadArgument;
    uint32_t control = 0xffffffff;
    pci->MemoryWrite32(0, ixgbe::interruptMaskClear, 0xffffffff);
    pci->MemoryRead32(0, ixgbe::control, &control);
    if (control == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::control,
                       control | ixgbe::controlMasterDisable);
    // A cleared STATUS.GIO means all pending master requests from this
    // function have completed. Never reset before this handshake succeeds.
    kern_return_t result = waitForRegister(
        pci, ixgbe::status, ixgbe::statusMasterEnabled, 0, 1000, 100);
    if (result != kIOReturnSuccess) return result;

    pci->MemoryRead32(0, ixgbe::control, &control);
    if (control == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::control,
                       control | ixgbe::controlSoftwareReset);
    result = waitForRegister(pci, ixgbe::control,
                             ixgbe::controlSoftwareReset, 0, 1000, 100);
    if (result != kIOReturnSuccess) return result;
    IODelay(10000); // Intel specifies at least 10 ms after software reset.
    pci->MemoryWrite32(0, ixgbe::interruptMaskClear, 0xffffffff);
    result = waitForRegister(pci, ixgbe::eepromControl,
                             ixgbe::eepromAutoReadDone,
                             ixgbe::eepromAutoReadDone, 1000, 100);
    if (result != kIOReturnSuccess) return result;
    return waitForRegister(pci, ixgbe::receiveDataReadControl,
                           ixgbe::receiveDMAInitialized,
                           ixgbe::receiveDMAInitialized, 1000, 100);
}

[[maybe_unused]] static kern_return_t readStationAddress(
    IOPCIDevice *pci, IOUserNetworkMACAddress *address)
{
    if (pci == nullptr || address == nullptr) return kIOReturnBadArgument;
    uint32_t low = 0xffffffff;
    uint32_t high = 0xffffffff;
    pci->MemoryRead32(0, ixgbe::receiveAddressLow0, &low);
    pci->MemoryRead32(0, ixgbe::receiveAddressHigh0, &high);
    if (low == 0xffffffff || high == 0xffffffff ||
        (high & ixgbe::receiveAddressValid) == 0)
        return kIOReturnIOError;
    address->octet[0] = static_cast<uint8_t>(low);
    address->octet[1] = static_cast<uint8_t>(low >> 8);
    address->octet[2] = static_cast<uint8_t>(low >> 16);
    address->octet[3] = static_cast<uint8_t>(low >> 24);
    address->octet[4] = static_cast<uint8_t>(high);
    address->octet[5] = static_cast<uint8_t>(high >> 8);
    bool allZero = true;
    for (uint8_t byte : address->octet) allZero &= byte == 0;
    if (allZero || (address->octet[0] & 1) != 0)
        return kIOReturnBadMedia;
    return kIOReturnSuccess;
}

// This routine is intentionally not called by the inactive Start path. It
// programs only the receive geometry; a working driver must also initialize
// queues, filters, link state, and safe DMA shutdown before using it.
[[maybe_unused]] static kern_return_t programJumboReceiveGeometry(
    IOPCIDevice *pci)
{
    if (pci == nullptr) return kIOReturnBadArgument;
    uint32_t maxFrame = 0xffffffff;
    uint32_t highlander = 0xffffffff;
    uint32_t receiveData = 0xffffffff;
    uint32_t split = 0xffffffff;
    pci->MemoryRead32(0, ixgbe::maxFrameSize, &maxFrame);
    pci->MemoryRead32(0, ixgbe::highlanderControl, &highlander);
    pci->MemoryRead32(0, ixgbe::receiveDataReadControl, &receiveData);
    pci->MemoryRead32(0, ixgbe::rxSplitControl, &split);
    if (maxFrame == 0xffffffff || highlander == 0xffffffff ||
        receiveData == 0xffffffff || split == 0xffffffff)
        return kIOReturnIOError;

    // Intel specifies MFS from the destination MAC through the CRC. It adds
    // VLAN header bytes separately, so a 9000-byte MTU uses MFS=9018.
    maxFrame = (maxFrame & ~ixgbe::maxFrameSizeMask) |
               ixgbe::jumboFrameRegisterValue;
    pci->MemoryWrite32(0, ixgbe::maxFrameSize, maxFrame);
    pci->MemoryWrite32(0, ixgbe::highlanderControl,
                       highlander | ixgbe::highlanderJumboEnable |
                       ixgbe::highlanderReceiveCRCStrip);
    pci->MemoryWrite32(0, ixgbe::receiveDataReadControl,
                       (receiveData & ~ixgbe::receiveRSCFirstSizeMask) |
                       ixgbe::receiveCRCStrip);
    split &= ~(ixgbe::rxSplitBufferSizeMask |
               ixgbe::rxSplitDescriptorTypeMask);
    split |= ixgbe::rxSplit10KiBBuffer |
             ixgbe::rxSplitOneBufferDescriptor |
             ixgbe::rxSplitDropWhenEmpty;
    pci->MemoryWrite32(0, ixgbe::rxSplitControl, split);

    uint32_t check = 0xffffffff;
    pci->MemoryRead32(0, ixgbe::maxFrameSize, &check);
    if ((check & ixgbe::maxFrameSizeMask) !=
        ixgbe::jumboFrameRegisterValue)
        return kIOReturnIOError;
    pci->MemoryRead32(0, ixgbe::highlanderControl, &check);
    if ((check & ixgbe::highlanderJumboEnable) == 0)
        return kIOReturnIOError;
    pci->MemoryRead32(0, ixgbe::rxSplitControl, &check);
    if ((check & (ixgbe::rxSplitBufferSizeMask |
                  ixgbe::rxSplitDescriptorTypeMask)) !=
        (ixgbe::rxSplit10KiBBuffer |
         ixgbe::rxSplitOneBufferDescriptor))
        return kIOReturnIOError;
    return kIOReturnSuccess;
}

// Register programming for a single queue in a function that has already
// completed its reset handshake. This does not start DMA or publish tails.
[[maybe_unused]] static kern_return_t prepareSingleQueueRegisters(
    IOPCIDevice *pci, const RingMemory *rx, const RingMemory *tx)
{
    if (pci == nullptr || rx == nullptr || tx == nullptr ||
        rx->deviceAddress == 0 || tx->deviceAddress == 0 ||
        (rx->deviceAddress & 0xfff) != 0 ||
        (tx->deviceAddress & 0xfff) != 0)
        return kIOReturnBadArgument;
    constexpr uint32_t rxBytes = ixgbe::ringEntries *
                                 sizeof(IxgbeRxDescriptor);
    constexpr uint32_t txBytes = ixgbe::ringEntries *
                                 sizeof(IxgbeTxDescriptor);
    uint32_t value = 0xffffffff;
    pci->MemoryRead32(0, ixgbe::rxControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::rxControl,
                       value & ~ixgbe::receiveEnable);
    pci->MemoryRead32(0, ixgbe::transmitDMAControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::transmitDMAControl,
                       value & ~ixgbe::transmitDMAEnable);
    pci->MemoryWrite32(0, ixgbe::rxPacketBufferSize,
                       ixgbe::receivePacketBuffer128KiB);
    for (uint32_t pool = 1; pool < 8; ++pool)
        pci->MemoryWrite32(0, ixgbe::rxPacketBufferSize + pool * 4, 0);
    uint32_t arbiter = 0xffffffff;
    pci->MemoryRead32(0, ixgbe::transmitArbiterControl, &arbiter);
    if (arbiter == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::transmitArbiterControl,
                       arbiter | ixgbe::transmitArbiterDisable);
    pci->MemoryWrite32(0, ixgbe::txPacketBufferSize,
                       ixgbe::transmitPacketBuffer40KiB);
    for (uint32_t pool = 1; pool < 8; ++pool)
        pci->MemoryWrite32(0, ixgbe::txPacketBufferSize + pool * 4, 0);
    pci->MemoryWrite32(0, ixgbe::transmitMaxSizeRequest, 0xffff);
    pci->MemoryWrite32(0, ixgbe::transmitArbiterControl,
                       arbiter & ~ixgbe::transmitArbiterDisable);
    pci->MemoryRead32(0, ixgbe::filterControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::filterControl,
                       value | ixgbe::receiveBroadcastAccept |
                       ixgbe::receiveAllMulticast);
    pci->MemoryRead32(0, ixgbe::controlExtension, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::controlExtension,
                       value | ixgbe::controlExtensionNoSnoopDisable);
    pci->MemoryRead32(0, ixgbe::rxDirectCacheAccessControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::rxDirectCacheAccessControl,
                       value & ~ixgbe::rxDirectCacheAccessReservedBit);

    pci->MemoryWrite32(0, ixgbe::rxDescriptorBaseLow,
                       static_cast<uint32_t>(rx->deviceAddress));
    pci->MemoryWrite32(0, ixgbe::rxDescriptorBaseHigh,
                       static_cast<uint32_t>(rx->deviceAddress >> 32));
    pci->MemoryWrite32(0, ixgbe::rxDescriptorLength, rxBytes);
    pci->MemoryWrite32(0, ixgbe::rxDescriptorHead, 0);
    pci->MemoryWrite32(0, ixgbe::rxDescriptorTail, 0);
    pci->MemoryWrite32(0, ixgbe::txDescriptorBaseLow,
                       static_cast<uint32_t>(tx->deviceAddress));
    pci->MemoryWrite32(0, ixgbe::txDescriptorBaseHigh,
                       static_cast<uint32_t>(tx->deviceAddress >> 32));
    pci->MemoryWrite32(0, ixgbe::txDescriptorLength, txBytes);
    pci->MemoryWrite32(0, ixgbe::txDescriptorHead, 0);
    pci->MemoryWrite32(0, ixgbe::txDescriptorTail, 0);

    pci->MemoryRead32(0, ixgbe::highlanderControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::highlanderControl,
                       value | ixgbe::highlanderTransmitCRC |
                       ixgbe::highlanderTransmitPad);
    pci->MemoryRead32(0, ixgbe::rxDescriptorLength, &value);
    if (value != rxBytes) return kIOReturnIOError;
    pci->MemoryRead32(0, ixgbe::txDescriptorLength, &value);
    if (value != txBytes) return kIOReturnIOError;
    return kIOReturnSuccess;
}

// Caller must first stop handing new packets to the device. Only a successful
// master-disable handshake permits packet buffers and descriptor rings to be
// released. This is not yet connected to an active interface.
[[maybe_unused]] static kern_return_t quiesceSingleQueueHardware(
    Lekuo82599_IVars *state)
{
    if (state == nullptr) return kIOReturnBadArgument;
    IOPCIDevice *pci = state->pci;
    if (pci == nullptr) return kIOReturnBadArgument;
    pci->MemoryWrite32(0, ixgbe::interruptMaskClear, 0xffffffff);
    uint32_t value = 0xffffffff;
    pci->MemoryRead32(0, ixgbe::rxDescriptorControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::rxDescriptorControl,
                       value & ~ixgbe::receiveQueueEnable);
    kern_return_t result = waitForRegister(pci, ixgbe::rxDescriptorControl,
                                            ixgbe::receiveQueueEnable,
                                            0, 1000, 100);
    if (result != kIOReturnSuccess) return result;
    IODelay(100); // Intel requires a further RX DMA settling period.
    pci->MemoryRead32(0, ixgbe::rxControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::rxControl,
                       value & ~ixgbe::receiveEnable);

    // Intel's dynamic TX-disable sequence first waits for the hardware head
    // to catch the posted tail. A stalled link may prevent draining; in that
    // case the subsequent queue-disable and master-disable handshakes remain
    // mandatory before any buffer can be released.
    uint32_t tail = 0xffffffff;
    pci->MemoryRead32(0, ixgbe::txDescriptorTail, &tail);
    if (tail == 0xffffffff) return kIOReturnIOError;
    bool drained = false;
    for (uint32_t attempt = 0; attempt < 1000; ++attempt) {
        uint32_t head = 0xffffffff;
        pci->MemoryRead32(0, ixgbe::txDescriptorHead, &head);
        if (head == 0xffffffff) return kIOReturnIOError;
        if (head == tail) {
            drained = true;
            break;
        }
        IODelay(100);
    }
    if (!drained)
        os_log(OS_LOG_DEFAULT,
               "Lekuo82599: TX ring did not drain before queue disable");
    if (drained && state->txRing.cpuAddress != 0) {
        auto *descriptors = reinterpret_cast<volatile IxgbeTxDescriptor *>(
            state->txRing.cpuAddress);
        bool writtenBack = false;
        for (uint32_t attempt = 0; attempt < 1000; ++attempt) {
            writtenBack = true;
            for (uint16_t index = state->txConsumer;
                 index != state->txProducer; index = ixgbe::next(index)) {
                if ((descriptors[index].offloadStatus &
                     ixgbe::txDescriptorDone) == 0) {
                    writtenBack = false;
                    break;
                }
            }
            if (writtenBack) break;
            IODelay(100);
        }
        if (!writtenBack)
            os_log(OS_LOG_DEFAULT,
                   "Lekuo82599: TX descriptors did not write back before queue disable");
    }

    pci->MemoryRead32(0, ixgbe::txDescriptorControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::txDescriptorControl,
                       value & ~ixgbe::transmitQueueEnable);
    result = waitForRegister(pci, ixgbe::txDescriptorControl,
                             ixgbe::transmitQueueEnable, 0, 1000, 100);
    if (result != kIOReturnSuccess) return result;
    pci->MemoryRead32(0, ixgbe::transmitDMAControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::transmitDMAControl,
                       value & ~ixgbe::transmitDMAEnable);

    pci->MemoryRead32(0, ixgbe::control, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    pci->MemoryWrite32(0, ixgbe::control,
                       value | ixgbe::controlMasterDisable);
    result = waitForRegister(pci, ixgbe::status,
                             ixgbe::statusMasterEnabled, 0, 1000, 100);
    if (result != kIOReturnSuccess) return result;
    return setPciCommandBits(pci, 0, kIOPCICommandBusLead);
}

static void releaseQueues(Lekuo82599_IVars *state)
{
    if (state->pollTimer != nullptr) {
        IOTimerDispatchSource *timer = state->pollTimer;
        state->pollTimer = nullptr;
        timer->SetEnable(false);
        timer->Cancel(^{ timer->release(); });
    }
    OSSafeReleaseNULL(state->pollAction);
    OSSafeReleaseNULL(state->txAction);
    OSSafeReleaseNULL(state->rxCompletion);
    OSSafeReleaseNULL(state->rxSubmission);
    OSSafeReleaseNULL(state->txCompletion);
    OSSafeReleaseNULL(state->txSubmission);
    OSSafeReleaseNULL(state->pool);
    OSSafeReleaseNULL(state->dispatchQueue);
}

static void completeTxPackets(Lekuo82599_IVars *state, IOReturn status)
{
    while (state->txConsumer != state->txProducer) {
        uint16_t index = state->txConsumer;
        IOUserNetworkPacket *packet = state->txPackets[index];
        state->txPackets[index] = nullptr;
        state->txConsumer = ixgbe::next(index);
        if (packet == nullptr) continue;
        packet->setCompletionStatus(status);
        if (state->txCompletion == nullptr ||
            state->txCompletion->EnqueuePacket(packet) != kIOReturnSuccess) {
            state->pool->DeallocatePacket(packet);
        }
    }
}

static void releaseRxPackets(Lekuo82599_IVars *state)
{
    if (state->pool == nullptr) return;
    for (uint16_t i = 0; i < ixgbe::ringEntries; ++i) {
        if (state->rxPackets[i] != nullptr) {
            state->pool->DeallocatePacket(state->rxPackets[i]);
            state->rxPackets[i] = nullptr;
            state->rxOffsets[i] = 0;
        }
    }
    state->rxConsumer = 0;
    state->rxFilled = 0;
}

// The network stack may not have posted RX submissions when it first enables
// the interface. Seed the hardware ring from the pool in that case, then use
// submitted packets as they become available for replacements.
static kern_return_t acquireRxPacket(Lekuo82599_IVars *state,
                                     IOUserNetworkPacket **out)
{
    if (state == nullptr || state->pool == nullptr ||
        state->rxSubmission == nullptr || out == nullptr)
        return kIOReturnBadArgument;
    *out = nullptr;
    IOUserNetworkPacket *packet = nullptr;
    if (state->rxSubmission->DequeuePackets(&packet, 1) == 1) {
        if (packet == nullptr) {
            if (kEnableFlowDiagnostics) ++state->rxAcquireFailures;
            return kIOReturnNoResources;
        }
        if (kEnableFlowDiagnostics) ++state->rxFromSubmission;
        *out = packet;
        return kIOReturnSuccess;
    }
    if (packet != nullptr) state->pool->deallocatePacket(packet);
    kern_return_t result = state->pool->allocatePacket(out);
    if (result != kIOReturnSuccess) {
        if (kEnableFlowDiagnostics) ++state->rxAcquireFailures;
        if (*out != nullptr) {
            state->pool->deallocatePacket(*out);
            *out = nullptr;
        }
        return result;
    }
    if (kEnableFlowDiagnostics && *out != nullptr) ++state->rxFromPool;
    return *out != nullptr ? kIOReturnSuccess : kIOReturnNoResources;
}

static kern_return_t fillRxRing(Lekuo82599_IVars *state)
{
    if (state->rxRing.cpuAddress == 0 || state->rxSubmission == nullptr)
        return kIOReturnNotReady;
    auto *descriptors = reinterpret_cast<volatile IxgbeRxDescriptor *>(
        state->rxRing.cpuAddress);
    for (uint16_t index = state->rxFilled;
         index < ixgbe::ringEntries; ++index) {
        IOUserNetworkPacket *packet = nullptr;
        kern_return_t result = acquireRxPacket(state, &packet);
        if (result != kIOReturnSuccess) return result;
        uint64_t address = packet->getDataIOVirtualAddress();
        uint64_t offset = packet->getDataOff();
        if (address == 0 || offset > UINT16_MAX ||
            offset + kLekuoMaxRxPacketBytes > kLekuoRxBufferBytes ||
            UINT64_MAX - address < offset) {
            state->pool->DeallocatePacket(packet);
            return kIOReturnBadArgument;
        }
        descriptors[index].fields.read.packetAddress = address + offset;
        descriptors[index].fields.read.headerAddress = 0;
        state->rxPackets[index] = packet;
        state->rxOffsets[index] = static_cast<uint16_t>(offset);
        state->rxFilled = index + 1;
    }
    state->rxConsumer = 0;
    return kIOReturnSuccess;
}

static kern_return_t startSingleQueueHardware(Lekuo82599_IVars *state)
{
    if (!state->pciOpened || state->pci == nullptr ||
        state->rxRing.cpuAddress == 0 || state->txRing.cpuAddress == 0)
        return kIOReturnNotReady;
    kern_return_t result = resetOneFunction(state->pci);
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: resetOneFunction failed 0x%x", result);
        return result;
    }
    uint32_t autoControl = 0xffffffff;
    uint32_t autoControl2 = 0xffffffff;
    state->pci->MemoryRead32(0, ixgbe::autoControl, &autoControl);
    state->pci->MemoryRead32(0, ixgbe::autoControl2, &autoControl2);
    if (autoControl == 0xffffffff || autoControl2 == 0xffffffff)
        return kIOReturnIOError;
    os_log(OS_LOG_DEFAULT,
           "Lekuo82599: NVM link configuration AUTOC=0x%08x AUTOC2=0x%08x",
           autoControl, autoControl2);
    memset(reinterpret_cast<void *>(state->rxRing.cpuAddress), 0,
           ixgbe::ringEntries * sizeof(IxgbeRxDescriptor));
    memset(reinterpret_cast<void *>(state->txRing.cpuAddress), 0,
           ixgbe::ringEntries * sizeof(IxgbeTxDescriptor));
    state->rxConsumer = state->rxFilled = 0;
    state->txProducer = state->txConsumer = 0;

    result = programJumboReceiveGeometry(state->pci);
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: jumbo geometry failed 0x%x", result);
        return result;
    }
    result = prepareSingleQueueRegisters(state->pci,
                                          &state->rxRing, &state->txRing);
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: queue registers failed 0x%x", result);
        return result;
    }
    if (kEnableMacLoopbackPrototype) {
        result = configureMacLoopback(state);
        if (result != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT, "Lekuo82599: MAC loopback setup failed 0x%x", result);
            return result;
        }
    }
    if (state->promiscuous) {
        uint32_t filter = 0xffffffff;
        state->pci->MemoryRead32(0, ixgbe::filterControl, &filter);
        if (filter == 0xffffffff) return kIOReturnIOError;
        state->pci->MemoryWrite32(0, ixgbe::filterControl,
                                   filter | ixgbe::receiveAllUnicast);
    }
    for (uint32_t attempt = 0; attempt < 20; ++attempt) {
        result = fillRxRing(state);
        if (result != kIOReturnNoResources) break;
        IODelay(1000);
    }
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: RX ring fill failed 0x%x", result);
        return result;
    }

    // Mark possible DMA before the first enable write, so every failure path
    // must quiesce hardware before releasing descriptors or packet buffers.
    state->dmaMayBeActive = true;
    result = setPciCommandBits(state->pci, kIOPCICommandBusLead, 0);
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: PCI bus master enable failed 0x%x", result);
        return result;
    }
    uint32_t value = 0xffffffff;
    state->pci->MemoryRead32(0, ixgbe::transmitDMAControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    state->pci->MemoryWrite32(0, ixgbe::transmitDMAControl,
                               value | ixgbe::transmitDMAEnable);
    state->pci->MemoryRead32(0, ixgbe::txDescriptorControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    state->pci->MemoryWrite32(0, ixgbe::txDescriptorControl,
                               value | ixgbe::transmitQueueEnable);
    result = waitForRegister(state->pci, ixgbe::txDescriptorControl,
                             ixgbe::transmitQueueEnable,
                             ixgbe::transmitQueueEnable, 1000, 100);
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: TX queue enable failed 0x%x", result);
        return result;
    }

    state->pci->MemoryRead32(0, ixgbe::rxDescriptorControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    state->pci->MemoryWrite32(0, ixgbe::rxDescriptorControl,
                               value | ixgbe::receiveQueueEnable);
    result = waitForRegister(state->pci, ixgbe::rxDescriptorControl,
                             ixgbe::receiveQueueEnable,
                             ixgbe::receiveQueueEnable, 1000, 100);
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: RX queue enable failed 0x%x", result);
        return result;
    }
    std::atomic_thread_fence(std::memory_order_release);
    state->pci->MemoryWrite32(0, ixgbe::rxDescriptorTail,
                               ixgbe::ringEntries - 1);

    state->pci->MemoryRead32(0, ixgbe::securityReceiveControl, &value);
    if (value == 0xffffffff) return kIOReturnIOError;
    state->pci->MemoryWrite32(0, ixgbe::securityReceiveControl,
                               value | ixgbe::securityReceiveDisable);
    result = waitForRegister(state->pci, ixgbe::securityReceiveStatus,
                             ixgbe::securityReceiveReady,
                             ixgbe::securityReceiveReady, 1000, 100);
    if (result != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: security RX gate failed 0x%x", result);
        return result;
    }
    uint32_t receive = 0xffffffff;
    state->pci->MemoryRead32(0, ixgbe::rxControl, &receive);
    if (receive == 0xffffffff) return kIOReturnIOError;
    state->pci->MemoryWrite32(0, ixgbe::rxControl,
                               receive | ixgbe::receiveEnable);
    state->pci->MemoryWrite32(0, ixgbe::securityReceiveControl,
                               value & ~ixgbe::securityReceiveDisable);
    state->hardwareReady = true;
    os_log(OS_LOG_DEFAULT, "Lekuo82599: queue hardware ready");
    return kIOReturnSuccess;
}

static void receivePackets(Lekuo82599_IVars *state)
{
    if (state->rxRing.cpuAddress == 0 || state->rxSubmission == nullptr ||
        state->rxCompletion == nullptr || !state->pciOpened) return;
    auto *descriptors = reinterpret_cast<volatile IxgbeRxDescriptor *>(
        state->rxRing.cpuAddress);
    bool advanced = false;
    uint16_t lastIndex = 0;
    for (uint16_t n = 0; n < ixgbe::ringEntries; ++n) {
        uint16_t index = state->rxConsumer;
        uint32_t status = descriptors[index].fields.writeback.statusAndError;
        if ((status & ixgbe::rxDescriptorDone) == 0) break;
        std::atomic_thread_fence(std::memory_order_acquire);

        // Reserve a replacement before handing the completed packet to the
        // stack. Without one, leave this descriptor in place and try later.
        IOUserNetworkPacket *replacement = nullptr;
        if (acquireRxPacket(state, &replacement) != kIOReturnSuccess) break;
        uint64_t address = replacement->getDataIOVirtualAddress();
        uint64_t offset = replacement->getDataOff();
        if (address == 0 || offset > UINT16_MAX ||
            offset + kLekuoMaxRxPacketBytes > kLekuoRxBufferBytes ||
            UINT64_MAX - address < offset) {
            state->pool->DeallocatePacket(replacement);
            break;
        }

        IOUserNetworkPacket *completed = state->rxPackets[index];
        uint16_t completedOffset = state->rxOffsets[index];
        uint16_t length = descriptors[index].fields.writeback.length;
        descriptors[index].fields.read.packetAddress = address + offset;
        descriptors[index].fields.read.headerAddress = 0;
        state->rxPackets[index] = replacement;
        state->rxOffsets[index] = static_cast<uint16_t>(offset);
        state->rxConsumer = ixgbe::next(index);
        lastIndex = index;
        advanced = true;

        bool valid = completed != nullptr &&
            (status & (ixgbe::rxEndOfPacket | ixgbe::rxFrameErrorMask)) ==
                ixgbe::rxEndOfPacket &&
            length >= kEthernetHeaderBytes &&
            length <= kLekuoMaxRxPacketBytes &&
            completedOffset + length <= kLekuoRxBufferBytes;
        if (valid) {
            valid = completed->setDataOffAndLen(completedOffset, length) ==
                        kIOReturnSuccess &&
                    completed->setLinkHeaderLength(kEthernetHeaderBytes) ==
                        kIOReturnSuccess;
        }
        if (valid &&
            state->rxCompletion->EnqueuePacket(completed) == kIOReturnSuccess) {
            if (kEnableFlowDiagnostics) ++state->rxDelivered;
            continue;
        }
        if (kEnableFlowDiagnostics) ++state->rxDropped;
        if (completed != nullptr) state->pool->DeallocatePacket(completed);
    }
    if (advanced) {
        std::atomic_thread_fence(std::memory_order_release);
        state->pci->MemoryWrite32(0, ixgbe::rxDescriptorTail, lastIndex);
    }
}

static void reapTx(Lekuo82599_IVars *state)
{
    auto *descriptors = reinterpret_cast<volatile IxgbeTxDescriptor *>(
        state->txRing.cpuAddress);
    while (state->txConsumer != state->txProducer) {
        uint16_t index = state->txConsumer;
        if ((descriptors[index].offloadStatus & ixgbe::txDescriptorDone) == 0)
            break;
        std::atomic_thread_fence(std::memory_order_acquire);
        IOUserNetworkPacket *packet = state->txPackets[index];
        state->txPackets[index] = nullptr;
        state->txConsumer = ixgbe::next(index);
        if (packet == nullptr) continue;
        if (kEnableTxCounterDiagnostics &&
            packet->getDataLength() > 1522) {
            uint32_t goodPackets = 0, goodBytesLow = 0;
            uint32_t goodBytesHigh = 0, dmaPackets = 0;
            state->pci->MemoryRead32(
                0, ixgbe::goodPacketsTransmitted, &goodPackets);
            state->pci->MemoryRead32(
                0, ixgbe::goodOctetsTransmittedLow, &goodBytesLow);
            state->pci->MemoryRead32(
                0, ixgbe::goodOctetsTransmittedHigh, &goodBytesHigh);
            state->pci->MemoryRead32(
                0, ixgbe::dmaGoodTxPackets, &dmaPackets);
            uint64_t goodBytes =
                (static_cast<uint64_t>(goodBytesHigh & 0xf) << 32) |
                goodBytesLow;
            os_log(OS_LOG_DEFAULT,
                   "Lekuo82599: jumbo TX complete length=%u GPTC=%u GOTC=%llu TXDGPC=%u",
                   packet->getDataLength(), goodPackets,
                   static_cast<unsigned long long>(goodBytes), dmaPackets);
        }
        packet->setCompletionStatus(kIOReturnSuccess);
        if (kEnableFlowDiagnostics) ++state->txCompleted;
        if (state->txCompletion->EnqueuePacket(packet) != kIOReturnSuccess)
            state->pool->DeallocatePacket(packet);
    }
}

static void submitTx(Lekuo82599_IVars *state)
{
    if (state->txRing.cpuAddress == 0 || state->txSubmission == nullptr ||
        state->txCompletion == nullptr || !state->pciOpened) return;
    reapTx(state);

    auto *descriptors = reinterpret_cast<volatile IxgbeTxDescriptor *>(
        state->txRing.cpuAddress);
    bool posted = false;
    while (ixgbe::next(state->txProducer) != state->txConsumer) {
        IOUserNetworkPacket *packet = nullptr;
        if (state->txSubmission->DequeuePackets(&packet, 1) != 1) {
            if (packet != nullptr) state->pool->DeallocatePacket(packet);
            break;
        }
        uint32_t length = packet->getDataLength();
        uint64_t baseAddress = packet->getDataIOVirtualAddress();
        uint64_t offset = packet->getDataOff();
        if (length < kEthernetHeaderBytes ||
            length > kLekuoMaxRxPacketBytes || baseAddress == 0 ||
            offset > kLekuoRxBufferBytes ||
            length > kLekuoRxBufferBytes - offset ||
            UINT64_MAX - baseAddress < offset) {
            packet->setCompletionStatus(kIOReturnBadArgument);
            if (state->txCompletion->EnqueuePacket(packet) != kIOReturnSuccess)
                state->pool->DeallocatePacket(packet);
            continue;
        }

        if (kEnableTxCounterDiagnostics && length > 1522) {
            uint32_t discarded = 0;
            // Establish a per-probe baseline before posting its descriptor.
            state->pci->MemoryRead32(
                0, ixgbe::goodPacketsTransmitted, &discarded);
            state->pci->MemoryRead32(
                0, ixgbe::goodOctetsTransmittedLow, &discarded);
            state->pci->MemoryRead32(
                0, ixgbe::goodOctetsTransmittedHigh, &discarded);
            state->pci->MemoryRead32(
                0, ixgbe::dmaGoodTxPackets, &discarded);
            os_log(OS_LOG_DEFAULT,
                   "Lekuo82599: jumbo TX queued length=%u", length);
        }

        uint16_t index = state->txProducer;
        descriptors[index].bufferAddress = baseAddress + offset;
        descriptors[index].commandTypeLength =
            ixgbe::txEndOfPacket | ixgbe::txInsertCRC |
            ixgbe::txReportStatus | ixgbe::txExtended |
            ixgbe::txAdvancedData | length;
        descriptors[index].offloadStatus = length << ixgbe::txPayloadLengthShift;
        state->txPackets[index] = packet;
        if (kEnableFlowDiagnostics) ++state->txSubmitted;
        state->txProducer = ixgbe::next(index);
        posted = true;
    }
    if (posted) {
        std::atomic_thread_fence(std::memory_order_release);
        state->pci->MemoryWrite32(0, ixgbe::txDescriptorTail,
                                  state->txProducer);
    }
}

bool Lekuo82599::init()
{
    if (!super::init()) return false;
    os_log(OS_LOG_DEFAULT, "Lekuo82599: init entered");
    ivars = static_cast<Lekuo82599_IVars *>(IOMallocZero(sizeof(Lekuo82599_IVars)));
    if (ivars != nullptr) ivars->currentMtu = 1500;
    return ivars != nullptr;
}

kern_return_t IMPL(Lekuo82599, Start)
{
    // A boot with the previous gated build stalled in kernelmanagerd while
    // matching port 2. Keep the disabled build entirely out of the PCI path
    // so the next diagnostic can distinguish matching and launch failures
    // from our own hardware initialization.
    constexpr bool kEnableHardwarePrototype = true;
    // Keep the function guard aligned with the published function-0 personality.
    constexpr uint64_t rxRingBytes = ixgbe::ringEntries * sizeof(IxgbeRxDescriptor);
    constexpr uint64_t txRingBytes = ixgbe::ringEntries * sizeof(IxgbeTxDescriptor);
    static const IOUserNetworkMediaType mediaTypes[] = {
        kIOUserNetworkMediaEthernetAuto
    };
    IOUserNetworkMACAddress macAddress = {};
    IOUserNetworkPacketQueue *queues[4] = {};
    uint16_t vendor = 0xffff;
    uint16_t device = 0xffff;
    uint32_t status = 0xffffffff;
    uint8_t bus = 0xff;
    uint8_t slot = 0xff;
    uint8_t function = 0xff;
    IODataQueueDispatchSource *txDataQueue = nullptr;
    IOUserNetworkPacketBufferPoolOptions poolOptions = {};
    kern_return_t result = super::Start(provider, SUPERDISPATCH);
    os_log(OS_LOG_DEFAULT, "Lekuo82599: superclass Start returned 0x%x",
           result);
    if (result != kIOReturnSuccess) return result;
    ivars->baseStarted = true;
    if (!kEnableHardwarePrototype) {
        os_log(OS_LOG_DEFAULT,
               "Lekuo82599: Start entered with hardware prototype disabled");
        result = kIOReturnUnsupported;
        goto fail;
    }

    ivars->pci = OSDynamicCast(IOPCIDevice, provider);
    if (ivars->pci == nullptr) {
        result = kIOReturnUnsupported;
        goto fail;
    }

    // Reject any unexpected function before opening the provider.
    result = ivars->pci->GetBusDeviceFunction(&bus, &slot, &function);
    if (result != kIOReturnSuccess) goto fail;
    if (function != 0) {
        os_log(OS_LOG_DEFAULT,
               "Lekuo82599: refusing PCI %u:%u:%u before Open",
               bus, slot, function);
        result = kIOReturnUnsupported;
        goto fail;
    }

    result = ivars->pci->Open(this);
    os_log(OS_LOG_DEFAULT, "Lekuo82599: PCI Open returned 0x%x", result);
    if (result != kIOReturnSuccess) goto fail;
    ivars->pciOpened = true;

    ivars->pci->ConfigurationRead16(0x00, &vendor);
    ivars->pci->ConfigurationRead16(0x02, &device);
    if (vendor != 0x8086 || device != 0x10fb) {
        result = kIOReturnUnsupported;
        goto fail;
    }

    os_log(OS_LOG_DEFAULT,
           "Lekuo82599: matched PCI %u:%u:%u 8086:10fb (hardware gate off: %d)",
           bus, slot, function, !kEnableHardwarePrototype);

    result = setPciCommandBits(ivars->pci, kIOPCICommandMemorySpace, 0);
    if (result != kIOReturnSuccess) goto fail;
    ivars->pciMemoryEnabled = true;

    // IXGBE_STATUS is a read-only 82599 register in BAR 0. This first
    // transport milestone does not write device registers or enable DMA.
    ivars->pci->MemoryRead32(0, 0x00008, &status);
    os_log(OS_LOG_DEFAULT, "Lekuo82599: PCI %u:%u:%u 8086:10fb status 0x%08x",
           bus, slot, function, status);

    // Each 82599 advanced RX/TX descriptor is 16 bytes. Map complete,
    // contiguous descriptor rings before any future hardware programming.
    result = allocateRing(ivars->pci, rxRingBytes, &ivars->rxRing);
    if (result != kIOReturnSuccess) goto fail;
    result = allocateRing(ivars->pci, txRingBytes, &ivars->txRing);
    if (result != kIOReturnSuccess) goto fail;

    // Reserve enough buffers for one full RX ring, one TX ring and spare
    // packets. No descriptors are posted by this inactive build.
    result = CopyDispatchQueue("Default", &ivars->dispatchQueue);
    if (result != kIOReturnSuccess) goto fail;

    poolOptions.packetCount = 4096;
    poolOptions.bufferCount = poolOptions.packetCount;
    poolOptions.bufferSize = kLekuoRxBufferBytes;
    poolOptions.maxBuffersPerPacket = 1;
    poolOptions.poolFlags = PoolFlagMapToDext | PoolFlagMapToDevice;
    poolOptions.dmaSpecification.maxAddressBits = 64;
    result = IOUserNetworkPacketBufferPool::CreateWithOptions(
        ivars->pci, "Lekuo82599", &poolOptions, &ivars->pool);
    if (result != kIOReturnSuccess) goto fail;

    result = CreateActionTxPacketAvailable(0, &ivars->txAction);
    if (result != kIOReturnSuccess) goto fail;
    result = IOUserNetworkTxSubmissionQueue::Create(
        ivars->pool, this, 512, 0, ivars->dispatchQueue, &ivars->txSubmission);
    if (result != kIOReturnSuccess) goto fail;
    result = ivars->txSubmission->CopyDataQueue(&txDataQueue);
    if (result != kIOReturnSuccess) goto fail;
    result = txDataQueue->SetDataAvailableHandler(ivars->txAction);
    if (result != kIOReturnSuccess) goto fail;
    OSSafeReleaseNULL(txDataQueue);

    result = IOUserNetworkTxCompletionQueue::Create(
        ivars->pool, this, 512, 0, ivars->dispatchQueue, &ivars->txCompletion);
    if (result != kIOReturnSuccess) goto fail;
    result = IOUserNetworkRxSubmissionQueue::Create(
        ivars->pool, this, 1024, 0, ivars->dispatchQueue, &ivars->rxSubmission);
    if (result != kIOReturnSuccess) goto fail;
    result = IOUserNetworkRxCompletionQueue::Create(
        ivars->pool, this, 1024, 0, ivars->dispatchQueue, &ivars->rxCompletion);
    if (result != kIOReturnSuccess) goto fail;

    result = IOTimerDispatchSource::Create(ivars->dispatchQueue,
                                            &ivars->pollTimer);
    if (result != kIOReturnSuccess) goto fail;
    result = CreateActionPollTimer(0, &ivars->pollAction);
    if (result != kIOReturnSuccess) goto fail;
    result = ivars->pollTimer->SetHandler(ivars->pollAction);
    if (result != kIOReturnSuccess) goto fail;

    result = readStationAddress(ivars->pci, &macAddress);
    if (result != kIOReturnSuccess) goto fail;
    result = ReportAvailableMediaTypes(mediaTypes,
                                       sizeof(mediaTypes) / sizeof(mediaTypes[0]));
    if (result != kIOReturnSuccess) goto fail;
    queues[0] = ivars->txSubmission;
    queues[1] = ivars->txCompletion;
    queues[2] = ivars->rxSubmission;
    queues[3] = ivars->rxCompletion;
    result = RegisterEthernetInterface(macAddress, ivars->pool, queues, 4);
    if (result != kIOReturnSuccess) goto fail;
    result = RegisterService();
    if (result != kIOReturnSuccess) goto fail;
    return kIOReturnSuccess;

fail:
    OSSafeReleaseNULL(txDataQueue);
    if (ivars->dmaMayBeActive) {
        kern_return_t stopResult = quiesceSingleQueueHardware(ivars);
        if (stopResult != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT,
                         "Lekuo82599: DMA did not quiesce during Start failure: 0x%x",
                         stopResult);
            return stopResult; // Keep mappings and packets pinned.
        }
        ivars->dmaMayBeActive = false;
        ivars->hardwareReady = false;
    }
    if (ivars->macLoopbackConfigured) {
        kern_return_t restoreResult = restoreMacLoopback(ivars);
        if (restoreResult != kIOReturnSuccess) return restoreResult;
    }
    completeTxPackets(ivars, kIOReturnAborted);
    releaseRxPackets(ivars);
    releaseQueues(ivars);
    releaseRing(&ivars->txRing);
    releaseRing(&ivars->rxRing);
    if (ivars->pciMemoryEnabled) {
        setPciCommandBits(ivars->pci, 0, kIOPCICommandMemorySpace);
        ivars->pciMemoryEnabled = false;
    }
    if (ivars->pciOpened) {
        ivars->pci->Close(this);
        ivars->pciOpened = false;
    }
    ivars->pci = nullptr;
    if (ivars->baseStarted) {
        super::Stop(provider, SUPERDISPATCH);
        ivars->baseStarted = false;
    }
    return result;
}

kern_return_t IMPL(Lekuo82599, Stop)
{
    // Stop packet callbacks before the DMA shutdown handshake. They share the
    // driver's dispatch queue, so no new descriptor can be posted by us here.
    setInterfaceEnabled(ivars, false);
    if (ivars->pollTimer != nullptr)
        ivars->pollTimer->SetEnable(false);
    if (ivars->txSubmission != nullptr)
        ivars->txSubmission->SetEnable(false);
    if (ivars->rxSubmission != nullptr)
        ivars->rxSubmission->SetEnable(false);
    drainPacketCallbacks(ivars);
    if (ivars->dmaMayBeActive) {
        kern_return_t result = quiesceSingleQueueHardware(ivars);
        if (result != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT,
                         "Lekuo82599: DMA did not quiesce during Stop: 0x%x",
                         result);
            return result; // Do not free a buffer the controller may still DMA.
        }
        ivars->dmaMayBeActive = false;
        ivars->hardwareReady = false;
    }
    if (ivars->macLoopbackConfigured) {
        kern_return_t restoreResult = restoreMacLoopback(ivars);
        if (restoreResult != kIOReturnSuccess) return restoreResult;
    }
    completeTxPackets(ivars, kIOReturnAborted);
    releaseRxPackets(ivars);
    releaseQueues(ivars);
    releaseRing(&ivars->txRing);
    releaseRing(&ivars->rxRing);
    if (ivars->pciMemoryEnabled) {
        setPciCommandBits(ivars->pci, 0, kIOPCICommandMemorySpace);
        ivars->pciMemoryEnabled = false;
    }
    if (ivars->pciOpened) {
        ivars->pci->Close(this);
        ivars->pciOpened = false;
    }
    ivars->pci = nullptr;
    if (ivars->baseStarted) {
        ivars->baseStarted = false;
        return super::Stop(provider, SUPERDISPATCH);
    }
    return kIOReturnSuccess;
}

void Lekuo82599::free()
{
    if (ivars != nullptr) {
        IOFree(ivars, sizeof(Lekuo82599_IVars));
        ivars = nullptr;
    }
    super::free();
}

kern_return_t IMPL(Lekuo82599, SetInterfaceEnable)
{
    if (!isEnable) {
        setInterfaceEnabled(ivars, false);
        if (ivars->pollTimer != nullptr)
            ivars->pollTimer->SetEnable(false);
        if (ivars->txSubmission != nullptr)
            ivars->txSubmission->SetEnable(false);
        if (ivars->rxSubmission != nullptr)
            ivars->rxSubmission->SetEnable(false);
        drainPacketCallbacks(ivars);
        if (ivars->dmaMayBeActive) {
            kern_return_t result = quiesceSingleQueueHardware(ivars);
            if (result != kIOReturnSuccess) return result;
            ivars->dmaMayBeActive = false;
        }
        if (ivars->macLoopbackConfigured) {
            kern_return_t result = restoreMacLoopback(ivars);
            if (result != kIOReturnSuccess) return result;
        }
        ivars->hardwareReady = false;
        completeTxPackets(ivars, kIOReturnAborted);
        releaseRxPackets(ivars);
        if (ivars->txCompletion != nullptr)
            ivars->txCompletion->SetEnable(false);
        if (ivars->rxCompletion != nullptr)
            ivars->rxCompletion->SetEnable(false);
        ivars->linkReportedUp = false;
        ReportLinkStatus(kIOUserNetworkLinkStatusInactive,
                         kIOUserNetworkMediaEthernetAuto);
        return kIOReturnSuccess;
    }

    if (isInterfaceEnabled(ivars)) return kIOReturnSuccess;
    if (ivars->dmaMayBeActive) return kIOReturnBusy;
    kern_return_t result = ivars->txCompletion->SetEnable(true);
    if (result != kIOReturnSuccess) goto fail;
    result = ivars->rxCompletion->SetEnable(true);
    if (result != kIOReturnSuccess) goto fail;
    result = ivars->rxSubmission->SetEnable(true);
    if (result != kIOReturnSuccess) goto fail;
    result = ivars->txSubmission->SetEnable(true);
    if (result != kIOReturnSuccess) goto fail;

    result = startSingleQueueHardware(ivars);
    if (result != kIOReturnSuccess) goto fail;
    setInterfaceEnabled(ivars, true);
    result = ivars->pollTimer->SetEnable(true);
    if (result != kIOReturnSuccess) goto fail;
    result = ivars->pollTimer->WakeAtTime(
        kIOTimerClockUptimeRaw,
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 250000, 0);
    if (result != kIOReturnSuccess) goto fail;
    ivars->txSubmission->requestDequeue();
    os_log(OS_LOG_DEFAULT, "Lekuo82599: interface enabled");
    return kIOReturnSuccess;

fail:
    setInterfaceEnabled(ivars, false);
    os_log(OS_LOG_DEFAULT,
           "Lekuo82599: SetInterfaceEnable failed 0x%x (DMA possible %d, loopback %d)",
           result, ivars->dmaMayBeActive, ivars->macLoopbackConfigured);
    if (ivars->pollTimer != nullptr)
        ivars->pollTimer->SetEnable(false);
    if (ivars->txSubmission != nullptr)
        ivars->txSubmission->SetEnable(false);
    if (ivars->rxSubmission != nullptr)
        ivars->rxSubmission->SetEnable(false);
    drainPacketCallbacks(ivars);
    if (ivars->dmaMayBeActive) {
        kern_return_t stopResult = quiesceSingleQueueHardware(ivars);
        if (stopResult != kIOReturnSuccess) return stopResult;
        ivars->dmaMayBeActive = false;
    }
    if (ivars->macLoopbackConfigured) {
        kern_return_t restoreResult = restoreMacLoopback(ivars);
        if (restoreResult != kIOReturnSuccess) return restoreResult;
    }
    ivars->hardwareReady = false;
    completeTxPackets(ivars, kIOReturnAborted);
    releaseRxPackets(ivars);
    if (ivars->txCompletion != nullptr)
        ivars->txCompletion->SetEnable(false);
    if (ivars->rxCompletion != nullptr)
        ivars->rxCompletion->SetEnable(false);
    return result;
}

kern_return_t IMPL(Lekuo82599, SetMTU)
{
    // The device will be programmed to its maximum receive frame size before
    // an interface is enabled. Track the requested interface MTU separately.
    if (mtu < 1280 || mtu > kLekuoMTU) return kIOReturnBadArgument;
    ivars->currentMtu = mtu;
    return kIOReturnSuccess;
}

kern_return_t IMPL(Lekuo82599, GetMaxTransferUnit)
{
    if (mtu == nullptr) return kIOReturnBadArgument;
    // This is the interface ceiling, not the current configured MTU.
    // Start cannot register an interface until jumbo hardware setup exists.
    *mtu = kLekuoMTU;
    return kIOReturnSuccess;
}

kern_return_t IMPL(Lekuo82599, SetHardwareAssists)
{
    // One descriptor per packet is implemented; checksum and TSO offloads are
    // deliberately unavailable until their descriptor formats are handled.
    return hardwareAssists == 0 ? kIOReturnSuccess : kIOReturnUnsupported;
}

kern_return_t IMPL(Lekuo82599, GetHardwareAssists)
{
    if (hardwareAssists == nullptr) return kIOReturnBadArgument;
    *hardwareAssists = 0;
    return kIOReturnSuccess;
}

kern_return_t IMPL(Lekuo82599, SetPromiscuousModeEnable)
{
    ivars->promiscuous = enable;
    if (!ivars->hardwareReady || !ivars->pciOpened) return kIOReturnSuccess;
    uint32_t filter = 0xffffffff;
    ivars->pci->MemoryRead32(0, ixgbe::filterControl, &filter);
    if (filter == 0xffffffff) return kIOReturnIOError;
    filter = enable ? filter | ixgbe::receiveAllUnicast :
                      filter & ~ixgbe::receiveAllUnicast;
    ivars->pci->MemoryWrite32(0, ixgbe::filterControl, filter);
    return kIOReturnSuccess;
}

kern_return_t IMPL(Lekuo82599, SetMulticastAddresses)
{
    // This early driver implementation accepts all multicast. This includes IPv6
    // solicited-node addresses even before an MTA hash filter is implemented.
    if (count != 0 && addresses == nullptr) return kIOReturnBadArgument;
    return kIOReturnSuccess;
}

kern_return_t IMPL(Lekuo82599, SetAllMulticastModeEnable)
{
    (void)enable;
    return kIOReturnSuccess; // All multicast is already admitted by FCTRL.
}

void IMPL(Lekuo82599, TxPacketAvailable)
{
    (void)action;
    if (!isInterfaceEnabled(ivars) || !ivars->hardwareReady) return;
    submitTx(ivars);
}

void IMPL(Lekuo82599, PollTimer)
{
    (void)action;
    (void)time;
    if (!isInterfaceEnabled(ivars) || !ivars->hardwareReady) return;
    receivePackets(ivars);
    submitTx(ivars); // Also reaps completed TX and resumes a backed-up queue.

    uint32_t links = 0xffffffff;
    ivars->pci->MemoryRead32(0, ixgbe::links, &links);
    // Intel says LINKS is undefined for forced MAC loopback. Report the
    // development test path as active while the loop is configured.
    bool up = ivars->macLoopbackConfigured ||
              (links != 0xffffffff && (links & ixgbe::linkUp) != 0);
    if (up != ivars->linkReportedUp) {
        os_log(OS_LOG_DEFAULT, "Lekuo82599: link %{public}s LINKS=0x%08x",
               up ? "up" : "down", links);
        ReportLinkStatus(up ? kIOUserNetworkLinkStatusActive :
                              kIOUserNetworkLinkStatusInactive,
                         kIOUserNetworkMediaEthernetAuto);
        ivars->linkReportedUp = up;
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (kEnableFlowDiagnostics &&
        (ivars->flowLastLogNs == 0 ||
         now - ivars->flowLastLogNs >= 1000000000ULL)) {
        ivars->flowLastLogNs = now;
        uint32_t rdh = 0xffffffff, rdt = 0xffffffff;
        uint32_t tdh = 0xffffffff, tdt = 0xffffffff;
        ivars->pci->MemoryRead32(0, ixgbe::rxDescriptorHead, &rdh);
        ivars->pci->MemoryRead32(0, ixgbe::rxDescriptorTail, &rdt);
        ivars->pci->MemoryRead32(0, ixgbe::txDescriptorHead, &tdh);
        ivars->pci->MemoryRead32(0, ixgbe::txDescriptorTail, &tdt);
        os_log(OS_LOG_DEFAULT,
               "Lekuo82599: flow RX submit=%llu pool=%llu acquireFail=%llu delivered=%llu dropped=%llu rdh=%u rdt=%u rxConsumer=%u TX posted=%llu completed=%llu tdh=%u tdt=%u txConsumer=%u txProducer=%u",
               static_cast<unsigned long long>(ivars->rxFromSubmission),
               static_cast<unsigned long long>(ivars->rxFromPool),
               static_cast<unsigned long long>(ivars->rxAcquireFailures),
               static_cast<unsigned long long>(ivars->rxDelivered),
               static_cast<unsigned long long>(ivars->rxDropped),
               rdh, rdt, ivars->rxConsumer,
               static_cast<unsigned long long>(ivars->txSubmitted),
               static_cast<unsigned long long>(ivars->txCompleted),
               tdh, tdt, ivars->txConsumer, ivars->txProducer);
    }
    kern_return_t result = ivars->pollTimer->WakeAtTime(
        kIOTimerClockUptimeRaw, now + 250000, 0);
    if (result != kIOReturnSuccess)
        os_log(OS_LOG_DEFAULT, "Lekuo82599: poll timer stopped: 0x%x", result);
}
