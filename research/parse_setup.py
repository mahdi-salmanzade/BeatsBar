"""Parse the FRESH sysdiagnose. We expect to see:
  1. HCI Connection_Complete (BR/EDR or LE) for the buds reconnect
  2. L2CAP CONN_REQ on the AAP PSM (signaling channel CID 0x0001 for Classic, 0x0005 for LE)
  3. Whatever auth handshake follows
  4. Then the HR stream beginning

Goal: identify (a) which PSM is used for HR, (b) what auth packets are exchanged
before HR streaming begins."""
import struct
import sys
from pathlib import Path
from collections import Counter

PKLG = Path(sys.argv[1] if len(sys.argv) > 1 else
            "/Users/intzero/Documents/Powerbeats/sysdiagnose_2026.05.07_13-09-08+0400_iPhone-OS_iPhone_23E261/logs/Bluetooth/bluetoothd-hci-latest.pklg")

# Powerbeats Pro 2 BR/EDR address from earlier discovery
BUDS_BDADDR = "28:2d:7f:20:73:ec"

L2CAP_CMDS = {0x01:"REJECT", 0x02:"CONN_REQ", 0x03:"CONN_RSP",
    0x04:"CFG_REQ", 0x05:"CFG_RSP", 0x06:"DISCONN_REQ", 0x07:"DISCONN_RSP",
    0x08:"ECHO_REQ", 0x09:"ECHO_RSP", 0x0A:"INFO_REQ", 0x0B:"INFO_RSP",
    0x14:"LE_CRED_CONN_REQ", 0x15:"LE_CRED_CONN_RSP",
    0x16:"FLOW_CTRL_CREDIT_IND", 0x17:"L2CAP_CRED_CONN_REQ", 0x18:"L2CAP_CRED_CONN_RSP"}

def iter_records(buf):
    off, n = 0, len(buf)
    while off + 13 <= n:
        length = struct.unpack(">I", buf[off:off+4])[0]
        if length < 9 or length > n - off:
            off += 1; continue
        ts_s, ts_us = struct.unpack(">II", buf[off+4:off+12])
        yield (ts_s + ts_us/1e6, buf[off+12], buf[off+13:off+4+length])
        off += 4 + length

def parse_acl(p):
    if len(p) < 8: return None
    hf = struct.unpack("<H", p[0:2])[0]
    handle, pb = hf & 0xFFF, (hf>>12) & 0x3
    pdu_len = struct.unpack("<H", p[4:6])[0]
    cid = struct.unpack("<H", p[6:8])[0]
    body = p[8:8+pdu_len] if 8+pdu_len <= len(p) else p[8:]
    return handle, pb, pdu_len, cid, body

def main():
    buf = PKLG.read_bytes()
    records = list(iter_records(buf))
    print(f"[parse] {len(records)} records, {len(buf)} bytes")

    base_t = None
    buds_handle = None  # filled when we see Conn_Complete to the buds bdaddr

    print("\n=== Connection completes & disconnects ===")
    for ts, t, p in records:
        if t != 0x01: continue  # HCI Event
        if base_t is None: base_t = ts
        rt = ts - base_t
        if len(p) < 2: continue
        code = p[0]
        if code == 0x03 and len(p) >= 13:  # Connection_Complete BR/EDR
            status = p[2]
            handle = struct.unpack("<H", p[3:5])[0]
            bdaddr = p[5:11][::-1].hex(":")
            link_type = p[11]
            mark = " <- BUDS" if bdaddr == BUDS_BDADDR else ""
            if bdaddr == BUDS_BDADDR and status == 0:
                buds_handle = handle
            print(f"  t={rt:7.3f}  CONN_COMPLETE   status={status} handle={handle} bdaddr={bdaddr}{mark}")
        elif code == 0x05 and len(p) >= 6:  # Disconnection_Complete
            status = p[2]
            handle = struct.unpack("<H", p[3:5])[0]
            reason = p[5]
            print(f"  t={rt:7.3f}  DISCONN         status={status} handle={handle} reason=0x{reason:02x}")
        elif code == 0x3E and len(p) >= 4:
            sub = p[2]
            if sub in (0x01, 0x0A) and len(p) >= 19:
                offset = 3 if sub == 0x01 else 3
                status = p[offset]
                handle = struct.unpack("<H", p[offset+1:offset+3])[0]
                paddr = p[offset+5:offset+11][::-1].hex(":")
                tag = "LE_CONN_COMPLETE" if sub == 0x01 else "LE_ENH_CONN_COMPLETE"
                print(f"  t={rt:7.3f}  {tag} status={status} handle={handle} peer={paddr}")

    if buds_handle is None:
        print("\n[parse] no fresh BR/EDR connection to buds in this trace.")
    else:
        print(f"\n[parse] buds BR/EDR handle = {buds_handle}")

    print(f"\n=== L2CAP signaling for buds handle ===")
    base_t = None
    target = buds_handle
    if target is None:
        # fallback: any handle 1
        target = 1
    for ts, t, payload in records:
        if t not in (0x02, 0x03): continue
        if base_t is None: base_t = ts
        rt = ts - base_t
        dirn = "TX" if t == 0x02 else "RX"
        parsed = parse_acl(payload)
        if not parsed: continue
        handle, pb, pdu_len, cid, body = parsed
        if handle != target: continue
        if cid not in (0x0001, 0x0005): continue  # only signaling channels
        if len(body) < 4: continue
        code = body[0]
        ident = body[1]
        length = struct.unpack("<H", body[2:4])[0]
        data = body[4:4+length]
        name = L2CAP_CMDS.get(code, f"unk_{code:#04x}")
        extra = ""
        if code == 0x02 and len(data) >= 4:
            psm = struct.unpack("<H", data[0:2])[0]
            scid = struct.unpack("<H", data[2:4])[0]
            extra = f"  PSM={psm:#06x}  SCID={scid:#06x}"
        elif code == 0x03 and len(data) >= 8:
            dcid = struct.unpack("<H", data[0:2])[0]
            scid = struct.unpack("<H", data[2:4])[0]
            result = struct.unpack("<H", data[4:6])[0]
            extra = f"  DCID={dcid:#06x}  SCID={scid:#06x}  result={result}"
        elif code in (0x14, 0x17) and len(data) >= 10:
            psm = struct.unpack("<H", data[0:2])[0]
            scid = struct.unpack("<H", data[2:4])[0]
            mtu = struct.unpack("<H", data[4:6])[0]
            extra = f"  PSM={psm:#06x}  SCID={scid:#06x}  MTU={mtu}"
        print(f"  t={rt:7.3f}  {dirn}  cid={cid:#06x}  {name:<20} ident={ident:<3} data={data.hex()}{extra}")

if __name__ == "__main__":
    main()
