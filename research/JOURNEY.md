# How we cracked AACP on Powerbeats Pro 2

A timeline of the actual reverse-engineering session — including the dead ends, because they're useful.

## The original goal

Show heart rate from Powerbeats Pro 2 in the macOS menu bar, while music plays, with no ceremonial mode-switching. The same way iOS reads HR.

## Round 1 — The standard BLE HR profile (dead end for daily use)

Powerbeats Pro 2 expose the standard Bluetooth SIG Heart Rate Profile (GATT service `0x180D`, characteristic `0x2A37`). Read it with `bleak` from Python — done.

Catch: it's only advertised when the buds enter "fitness equipment pairing mode" via a tap-tap-hold on the b-button, while disconnected from iPhone, while in your ears, and only for ~30 seconds. Verified by Apple's own docs and by capturing the advertisements with `BleakScanner`.

This works, but it's a session-based interaction — open app, do gesture, scan. Unsuitable for an always-on menu bar.

## Round 2 — The proprietary GATT service

The buds expose a custom 128-bit GATT service `4715650b-5e9d-4ac2-b898-a4fc0aa5df78` with one characteristic supporting `write` + `indicate` + `authenticated-signed-writes`. macOS internally calls this **UARP — Unified Accessory Restore Protocol** (Apple's firmware-update channel).

Probed it with bleak: subscribed to indications, sent every AirPods AAP opcode we could find, sent the standard `04 00 04 00 ...` framing variants, both signed and unsigned. **Got zero responses.** Single-byte writes returned ATT "Unlikely Error" — confirming the buds parse what we send but reject all our opcodes.

This is the firmware-update channel, not the HR channel. Wrong door.

## Round 3 — Where iPhone actually gets HR from

Installed Apple's `Bluetooth_HCI_Logging.mobileconfig` profile on iPhone, started an Apple Fitness workout to provoke HR data flow, triggered sysdiagnose, AirDropped the `.tar.gz` to Mac, extracted `bluetoothd-hci-latest.pklg`.

Wrote a `.pklg` parser. Looked at the L2CAP layer of all 4892 ACL packets. Found:

- A super-busy connection on **handle=1** (BR/EDR Classic, confirmed via `HCI_Connection_Complete` event) with 4670 packets on dynamic CID `0x040c`.
- **Every packet started with `04 00 04 00`** — the AACP magic.
- Opcode `0x0017` streamed at 50 Hz (raw IMU/sensor data, HID-formatted).
- Opcode `0x0004` arrived occasionally with a 16-byte payload.

We thought `0x0004` was HR because the values dropped slowly: 94, 94, 93, 93, 92, 92 over 158 seconds. Looked exactly like a resting heart rate decreasing.

**This was wrong.** The same 16 bytes match the LibrePods-documented battery report format perfectly:
```
03 02 01 5e 02 01 04 01 5e 02 01 08 01 00 04 01
^^ count=3
   ^^^^^^^^^^^^^^ right=94% discharging
                  ^^^^^^^^^^^^^^^ left=94% discharging
                                   ^^^^^^^^^^^^^^^ case=0% disconnected
```

Battery dropping 1% over 60 seconds during active audio playback — exactly what you'd expect. We celebrated decoding HR a few hours before realizing.

## Round 4 — Finding PSM 0x1001

Captured a *second* sysdiagnose where the buds reconnect mid-capture. The first one missed the L2CAP setup; the second one had it.

Performed `IOBluetoothDevice.performSDPQuery(...)` from Mac to enumerate the buds' service records. **Got 12 services**, including:

```
Service #7: "AAP Server"  →  L2CAP PSM 0x1001
  Service UUID: 74ec2172-0bad-4d01-8f77-997b2be0722a
```

Cross-referenced with Apple's own SDK header:
```c
kBluetoothL2CAPPSMAACP = 0x1001,  // Apple Accessory Communication Protocol
```

**Apple publicly documents this PSM in their headers.** They just don't let you open it.

## Round 5 — The wall

Tried `IOBluetoothDevice.openL2CAPChannelSync(_:withPSM: 0x1001, ...)` from a Swift CLI:
```
ERROR: openL2CAPChannelSync(0x1001) failed: 0xe00002bc
```

Tried as `sudo`:
```
ERROR: openL2CAPChannelSync(0x1001) failed: 0xe00002bc
```

Tried 24 different PSM values via brute force, plus the async variant, plus opening through the SDP service record, plus registering as an L2CAP listener and waiting for the buds to initiate. Same error every time, or silent failure.

**The block isn't the buds. It's `IOBluetooth.framework` itself**, deciding to refuse third-party app access to PSM 0x1001. Confirmed because:
- The error is returned synchronously, before any Bluetooth packet is exchanged.
- Same error returned even when iPhone is fully off, Apple Watch in airplane mode, no other Apple devices nearby.
- LibrePods on Linux opens the same PSM with the same handshake against the same buds and HR streams cleanly.

## Round 6 — Finding the unlock

`dyld_info -exports` on `/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth` revealed:
```
_OBJC_CLASS_$_AAP
_OBJC_CLASS_$_AAPManager
_AAPServerUUID
_AAPServiceUUID
```

macOS already has a complete internal AAP implementation. It just won't expose it to user-space apps. The next step — which is now in progress — is a `DYLD_INSERT_LIBRARIES` interposer that hooks the policy check inside `openL2CAPChannelSync` and forces it to allow PSM `0x1001`.

LibrePods' AAP Definitions documented:
- The 16-byte handshake that must be sent first
- Control opcode `0x09` with identifier `0x30` = HRM enable/disable
- Battery format that we mis-decoded as HR

That's where we are: we know exactly what to send the moment the L2CAP open succeeds. The interposer is the last piece.

## Round 7 — Disassembling the policy check

Found the exact instruction that produces the error `0xe00002bc`:

```
IOBluetooth`-[IOBluetoothDevice openL2CAPChannelAsync:withPSM:withConfiguration:delegate:]
+136:  mov    w25, #0x2bc
+140:  movk   w25, #0xe000, lsl #16
```

These two ARM64 instructions construct `0xe00002bc` in `w25`. The function stores `w25` to `x0` at exit. So `w25` is the "default error" that's loaded at the start; the success path needs to clear it.

Tracing the success path: `setDelegate:withConfiguration:` → `setPSM:` → `isConnected` check → alloc + `initWithDevice:andClassicPeer:PSM:` → `setDelegate:` → branch to channel-instantiate code that calls into the kernel via `IOService`. Somewhere in that kernel call path is where PSM 0x1001 actually gets rejected — we never reach the part of the function that would clear `w25` to 0.

Both the public `openL2CAPChannelSync:withPSM:delegate:` and the deprecated `openL2CAPChannel:findExisting:newChannel:` route through `openL2CAPChannelAsync:withPSM:withConfiguration:delegate:`, so they all hit the same wall.

`instantiateChannel:findExisting:newChannel:` looks like it might be a separate primitive but in fact it's just a thin wrapper that calls back into `openL2CAPChannelSync:withPSM:delegate:` — so hooking either entry point causes mutual recursion (we added a thread-local guard in the dylib).

**Conclusion:** the actual rejection happens in a kernel-side IOService call, not in user-space. Our dylib successfully hooks the entry points and explores alternate user-space paths, but can't reach past the kernel boundary. To fully bypass requires:

1. **DriverKit extension** (`.dext`) talking directly to the BT controller — Apple-signed, requires developer enrollment.
2. **Kernel extension** (`.kext`) — even harder, Apple no longer signs new ones.
3. **USB Bluetooth controller takeover** — only works if you can detach the controller from the macOS BT stack, which on Apple Silicon Macs is not straightforward.

For shipping today, the menu bar app uses the standard BLE 0x180D session-mode HR path (which works) plus the always-on battery readout (which works through `system_profiler`). The kernel-bypass mode is exposed as an experimental option that exercises the dylib hook path; it can succeed in user-space (we get a real `IOBluetoothL2CAPChannel` object created via the private init) but the underlying L2CAP CONN_REQ never goes on the wire. Logs from the helper process surface the reason in real time.

## Lessons

- **Test your assumptions.** "94 → 92 BPM as user rests" is a credible HR signal. It was battery. Always cross-check with established protocol docs *before* celebrating.
- **The wall is rarely where you think.** We assumed it was MFi crypto for hours. It was a software policy in `IOBluetooth.framework`.
- **`dyld_info -exports` is your friend.** Apple always ships private classes. They're often half the story.
- **Standing on shoulders works.** LibrePods cracked AACP for AirPods on Linux/Android. We extend it to PB Pro 2 on macOS — which means Mac gets the protocol AirPods owners never had a use for, because PB Pro 2 is the only AAP device with a heart rate sensor.
