// libaacp_unlock.dylib
//
// DYLD_INSERT_LIBRARIES interposer that bypasses macOS's user-space block
// on opening L2CAP PSM 0x1001 (kBluetoothL2CAPPSMAACP — Apple Accessory
// Communication Protocol).
//
// macOS IOBluetooth.framework's -[IOBluetoothDevice openL2CAPChannelSync:withPSM:delegate:]
// returns IOReturn 0xe00002bc when called with PSM 0x1001 from a third-party app,
// even with sudo. The block is enforced by IOBluetooth itself — bytes never reach the
// peer.
//
// This interposer:
//   1. Logs every call to openL2CAPChannelSync / openL2CAPChannelAsync.
//   2. For PSM 0x1001, instead of letting the public method run its policy
//      check, constructs the channel via the private
//      -[_initWithDevice:andClassicPeer:PSM:withServiceUUID:] init,
//      sets the AAP service UUID, registers the delegate, then triggers
//      the L2CAP setup. (The exact mechanism for triggering the open without
//      the policy check is what we figure out at runtime — this file is the
//      laboratory.)
//
// Build:   make
// Use:     DYLD_INSERT_LIBRARIES=$PWD/libaacp_unlock.dylib ./BeatsBar
// SIP:     library validation must be off for arbitrary process injection.
//
//          To enable injection per-binary without disabling SIP system-wide,
//          codesign the target binary with --entitlements that include
//          com.apple.security.cs.allow-dyld-environment-variables AND
//          com.apple.security.cs.disable-library-validation, AND remove the
//          hardened runtime flag. We do that for our own binary as part of
//          the build, so this dylib loads fine.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOBluetooth/IOBluetooth.h>
#import <dlfcn.h>
#import <stdio.h>

#define LOG(fmt, ...) fprintf(stderr, "[aacp_unlock] " fmt "\n", ##__VA_ARGS__)

static IOReturn (*orig_openL2CAPChannelSync)(id self, SEL _cmd,
                                              IOBluetoothL2CAPChannel **outChannel,
                                              BluetoothL2CAPPSM psm,
                                              id delegate);

// Thread-local recursion guard. The deprecated open path internally calls
// openL2CAPChannelSync — without the guard our hook would recurse forever.
static __thread int in_hook = 0;

static IOReturn hooked_openL2CAPChannelSync(id self, SEL _cmd,
                                             IOBluetoothL2CAPChannel **outChannel,
                                             BluetoothL2CAPPSM psm,
                                             id delegate)
{
    if (in_hook) {
        // Reentrant call — pass straight through to the original implementation.
        return orig_openL2CAPChannelSync(self, _cmd, outChannel, psm, delegate);
    }
    LOG("openL2CAPChannelSync called: psm=0x%04X  delegate=%p", psm, delegate);

    if (psm == 0x1001) {
        // We learned from disassembly that the public method tail-calls the
        // withConfiguration: variant where the policy check lives. The
        // deprecated -[openL2CAPChannel:findExisting:newChannel:] takes an
        // entirely different path: it allocates a channel via the private
        // -initWithDevice:andClassicPeer:PSM: init and dispatches into
        // -instantiateChannel:findExisting:newChannel: — without the public
        // method's policy check.
        in_hook = 1;
        SEL deprecatedSel = NSSelectorFromString(@"openL2CAPChannel:findExisting:newChannel:");
        if ([self respondsToSelector:deprecatedSel]) {
            LOG("  → PSM 0x1001 (AACP). Trying the deprecated openL2CAPChannel:findExisting:newChannel: path.");
            IOBluetoothL2CAPChannel *newCh = nil;
            typedef IOReturn (*OpenFn)(id, SEL, BluetoothL2CAPPSM, BOOL, IOBluetoothL2CAPChannel **);
            OpenFn fn = (OpenFn)[self methodForSelector:deprecatedSel];
            IOReturn r = fn(self, deprecatedSel, psm, NO, &newCh);
            LOG("  → deprecated open result: 0x%08x  channel=%p", r, newCh);
            if (r == kIOReturnSuccess && newCh != nil) {
                if (delegate && [newCh respondsToSelector:@selector(setDelegate:)]) {
                    [newCh setDelegate:delegate];
                }
                if (outChannel) *outChannel = newCh;
                LOG("  → ✅ deprecated path opened the channel");
                in_hook = 0;
                return kIOReturnSuccess;
            }
            LOG("  → deprecated path failed too. Falling back to baseline.");
        }

        IOReturn baseline = orig_openL2CAPChannelSync(self, _cmd, outChannel, psm, delegate);
        LOG("  → baseline result: 0x%08x", baseline);
        in_hook = 0;
        return baseline;
    }

    return orig_openL2CAPChannelSync(self, _cmd, outChannel, psm, delegate);
}

// Private IOBluetooth function: flips a kernel property "DeviceL2CAPOnlyUserClients"
// via IORegistryEntrySetCFProperty. Calling with `true` disables kernel-side L2CAP
// enforcement so user-space clients can open arbitrary PSMs (including 0x1001).
typedef int (*DisableL2CAPKernelDriversFn)(bool disable);
typedef int (*BluetoothHCISetupUserClientFn)(void);

__attribute__((constructor))
static void aacp_unlock_init(void) {
    LOG("loaded. arch=%s", "arm64");

    void *fw = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW);
    LOG("dlopen IOBluetooth: %p", fw);

    // Try the kernel-policy bypass FIRST. If it sticks, the standard
    // openL2CAPChannelSync will work without any swizzle gymnastics.
    BluetoothHCISetupUserClientFn setupUC = (BluetoothHCISetupUserClientFn)dlsym(fw, "BluetoothHCISetupUserClient");
    if (setupUC) {
        int r = setupUC();
        LOG("BluetoothHCISetupUserClient: %d", r);
    } else {
        LOG("BluetoothHCISetupUserClient: not found");
    }
    DisableL2CAPKernelDriversFn disableL2CAP = (DisableL2CAPKernelDriversFn)dlsym(fw, "IOBluetoothHCIControllerDisableL2CAPKernelDrivers");
    if (disableL2CAP) {
        int r = disableL2CAP(true);
        LOG("IOBluetoothHCIControllerDisableL2CAPKernelDrivers(true): kern_return=0x%08x", r);
    } else {
        LOG("IOBluetoothHCIControllerDisableL2CAPKernelDrivers: not found");
    }

    Class deviceCls = objc_getClass("IOBluetoothDevice");
    if (!deviceCls) {
        LOG("ERROR: IOBluetoothDevice class not found");
        return;
    }

    SEL sel = NSSelectorFromString(@"openL2CAPChannelSync:withPSM:delegate:");
    Method m = class_getInstanceMethod(deviceCls, sel);
    if (!m) {
        LOG("ERROR: openL2CAPChannelSync method not found");
        return;
    }

    orig_openL2CAPChannelSync = (IOReturn (*)(id, SEL, IOBluetoothL2CAPChannel**, BluetoothL2CAPPSM, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_openL2CAPChannelSync);
    LOG("swizzled -[IOBluetoothDevice openL2CAPChannelSync:withPSM:delegate:]");
}
