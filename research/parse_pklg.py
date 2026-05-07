"""Parse Apple PacketLogger .pklg HCI traces and pull out the GATT/ATT
exchanges between iPhone and the Powerbeats Pro 2.

PKLG record format:
  [length:u32be][ts_sec:u32be][ts_usec:u32be][type:u8][payload:bytes]
  where length = 9 + len(payload).

Packet types:
  0x00 HCI Command   (host -> controller)
  0x01 HCI Event     (controller -> host)
  0x02 ACL Send      (host -> controller -> remote)
  0x03 ACL Receive   (remote -> controller -> host)
  0x07 LMP
  0xFB Apple-private OS log
  0xFC etc. — Apple internal
"""
import struct
import sys
from collections import Counter
from pathlib import Path

PKLG = Path(sys.argv[1] if len(sys.argv) > 1 else
            "/Users/intzero/Documents/Powerbeats/sysdiagnose_2026.05.07_11-46-57+0400_iPhone-OS_iPhone_23E261/logs/Bluetooth/bluetoothd-hci-latest.pklg")

TYPES = {
    0x00: "HCI_CMD",
    0x01: "HCI_EVT",
    0x02: "ACL_TX",
    0x03: "ACL_RX",
    0x04: "SCO_TX",
    0x05: "SCO_RX",
    0x07: "LMP",
}

def iter_records(buf: bytes):
    off = 0
    n = len(buf)
    while off + 13 <= n:
        length = struct.unpack(">I", buf[off:off+4])[0]
        if length < 9 or length > n - off:
            # Malformed; resync by skipping a byte
            off += 1
            continue
        ts_s, ts_us = struct.unpack(">II", buf[off+4:off+12])
        ptype = buf[off+12]
        payload = buf[off+13 : off+4+length]
        yield (ts_s + ts_us / 1e6, ptype, payload)
        off += 4 + length

def main():
    print(f"[parse] reading {PKLG}")
    buf = PKLG.read_bytes()
    print(f"[parse] {len(buf)} bytes")

    type_counts = Counter()
    records = list(iter_records(buf))
    print(f"[parse] parsed {len(records)} records")

    for _, t, _ in records:
        type_counts[t] += 1

    print("\n[parse] packet type histogram:")
    for t, c in sorted(type_counts.items()):
        name = TYPES.get(t, f"unknown_{t:#04x}")
        print(f"  {t:#04x} {name:<12} {c}")

    # Look at ACL packets specifically — that's where ATT/GATT lives.
    acl = [(ts, t, p) for (ts, t, p) in records if t in (0x02, 0x03)]
    print(f"\n[parse] {len(acl)} ACL packets total")

    if acl:
        # Show first few ACL TX/RX so we can see the connection-handle space
        print("\n[parse] first 5 ACL packets:")
        for ts, t, p in acl[:5]:
            dirn = "TX" if t == 0x02 else "RX"
            print(f"  ts={ts:.3f}  {dirn}  len={len(p)}  hex={p[:32].hex()}…")

if __name__ == "__main__":
    main()
