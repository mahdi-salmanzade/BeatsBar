# AACP Protocol Map — Powerbeats Pro 2

Status: in-progress reverse-engineering map. Verified opcodes are marked ✅, inferred from iPhone trace are 🔍, candidates are ❓.

## Transport

- BR/EDR Classic (not BLE)
- L2CAP PSM **0x1001** = `kBluetoothL2CAPPSMAACP` (per Apple SDK header `BluetoothAssignedNumbers.h`)
- Service UUID **`74ec2172-0bad-4d01-8f77-997b2be0722a`** advertised in SDP as "AAP Server"
- Class UUID **`4b6f7c74-07f4-49de-b0b9-ab4304728f29`** (in SDP attr 0x0009)
- Connection initiated by host (Mac/iPhone) — buds are the L2CAP server

## Handshake (mandatory first packet)

```
00 00 04 00 01 00 02 00 00 00 00 00 00 00 00 00
```

Without this, the buds ignore everything else.

## Frame format (every other packet)

```
04 00 04 00 <opcode_le16> <payload>
```

The leading `04 00 04 00` is the L2CAP-level header repeated as a magic prefix in the AACP layer (length=4, channel=4, but with an outer L2CAP wrapping it on the dynamic CID assigned at PSM 0x1001 connect).

## Opcodes (host-direction column reflects iPhone usage)

| Opcode | Direction | Description | Verified | Notes |
|--------|-----------|-------------|----------|-------|
| `0x0001` | accessory | Unknown / startup ack | 🔍 | Seen TX from iPhone with payload `08` |
| `0x0004` | host | **Battery report** | ✅ | Format below |
| `0x0006` | host | Ear detection | ✅ (LibrePods) | |
| `0x0009` | both | Control commands | ✅ | Identifier 0x30 = HRM enable/disable |
| `0x000D` | accessory | Audio source request | 🔍 | TX no payload |
| `0x000E` | host | Audio source response | 🔍 | |
| `0x000F` | accessory | Notification register | ✅ | Subscribe-all = `FF FF FE FF` |
| `0x0017` | both | 50 Hz IMU/sensor stream | 🔍 | Periodic, ~19ms cadence; HID-formatted with VendorID/MaxReportSize fields |
| `0x001B` | accessory | Timestamp sync | ✅ | Cleartext ISO-8601 string from iPhone |
| `0x001D` | host | Device info | ✅ | Contains buds name + serial + model "A3157" |
| `0x0024` | accessory | Call mgmt config | 🔍 | TX `02 00 01 00 01` |
| `0x0029` | accessory | Host capabilities (?) | 🔍 | TX `05 ff 05 ff ff ff ff ff` |
| `0x002B` | host | Paired devices(?) | 🔍 | 351-byte payload at session start |
| `0x002E` | host | Connected devices list | ✅ | Contains MAC addresses including iPhone's |
| `0x0030` | accessory | BLE keys req | ✅ (LibrePods) | |
| `0x0031` | host | BLE keys response | ✅ (LibrePods) | 71-byte structured payload |
| `0x0054` | accessory | Capabilities exchange | 🔍 | TX `07 00 02 04 01 07 05 02 06 06 04 1c 00 05 00 00 06 00 00 07 00 05` |

### Op 0x0004 — Battery report

```
04 00 04 00 04 00 [count] ([component] 01 [level] [status] 01) × count
```

| Field | Bytes |
|---|---|
| `count` | 0x03 (always 3 components on PB Pro 2: left, right, case) |
| `component` | 0x02 right · 0x04 left · 0x08 case |
| `level` | 0–100 (decimal byte) |
| `status` | 0x00 unknown · 0x01 charging · 0x02 discharging · 0x04 disconnected |

Example from PB Pro 2 (in-ear, discharging):
```
04 00 04 00 04 00 03 02 01 5e 02 01 04 01 5e 02 01 08 01 00 04 01
                  ^^ count
                    ^^ ^^ ^^ ^^ ^^ right=94% discharging
                                   ^^ ^^ ^^ ^^ ^^ left=94% discharging
                                                  ^^ ^^ ^^ ^^ ^^ case=0% disconnected
```

### Control command 0x30 — HRM enable/disable

```
04 00 04 00 09 00 30 [enable] 00 00 00
```
- `enable` = 0x01 to enable, 0x02 to disable

### Heart rate notification (target opcode)

🚧 **Not yet decoded for Powerbeats Pro 2.** Suspected to be one of:
- Reuse of opcode `0x0017` with a specific HID-report-id
- A new opcode in the 0x40+ range (Powerbeats-specific extension to the AAP opcode space)

To map: capture a sysdiagnose with HRM explicitly enabled mid-capture, then look for a periodic ~5s opcode that didn't appear pre-enable.

## Service Discovery (full SDP record summary)

12 services advertised by Powerbeats Pro 2:

| # | Name | Protocol | PSM / Channel |
|---|------|----------|---------------|
| 0 | Handsfree | RFCOMM | ch 7 |
| 1 | (SDP) | L2CAP | (server) |
| 2 | Handsfree | RFCOMM | ch 7 |
| 3 | UARPS | L2CAP | PSM 0x001F |
| 4 | (PnP Information) | — | VID 0x004C / PID 0x201D |
| 5 | GATT | L2CAP | PSM 0x001F |
| 6 | AVRCP Controller | L2CAP | PSM 0x0017 |
| **7** | **AAP Server** | **L2CAP** | **PSM 0x1001** ← this is us |
| 8 | AVRCP Controller | L2CAP | PSM 0x0017 |
| 9 | AVRCP Target | L2CAP | PSM 0x0017 |
| 10 | Audio Sink | L2CAP | PSM 0x0019 |
| 11 | (RFCOMM) | RFCOMM | ch 1 |

## Capture artifacts

- `research/captures/sysdiagnose_2026.05.07_11-46-57+0400/` — first capture, AAP session already established (no setup visible)
- `research/captures/sysdiagnose_2026.05.07_13-09-08+0400/` — fresh capture with reconnect mid-trace; contains the ~250ms post-connect window where AAP channel comes up
