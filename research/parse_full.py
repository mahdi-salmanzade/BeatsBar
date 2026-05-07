"""Full decoder: ATT writes/indicates + LE Signaling (L2CAP CoC setup) +
the actual L2CAP CoC data channel traffic."""
import struct
import sys
from pathlib import Path
from collections import Counter

PKLG = Path(sys.argv[1] if len(sys.argv) > 1 else
            "/Users/intzero/Documents/Powerbeats/sysdiagnose_2026.05.07_11-46-57+0400_iPhone-OS_iPhone_23E261/logs/Bluetooth/bluetoothd-hci-latest.pklg")

ATT_OPS = {0x01:"ERR_RSP", 0x02:"MTU_REQ", 0x03:"MTU_RSP",
    0x04:"FIND_INFO_REQ",0x05:"FIND_INFO_RSP",
    0x06:"FIND_BY_TYPE_REQ",0x07:"FIND_BY_TYPE_RSP",
    0x08:"READ_BY_TYPE_REQ",0x09:"READ_BY_TYPE_RSP",
    0x0A:"READ_REQ",0x0B:"READ_RSP",
    0x0C:"READ_BLOB_REQ",0x0D:"READ_BLOB_RSP",
    0x10:"READ_BY_GRP_REQ",0x11:"READ_BY_GRP_RSP",
    0x12:"WRITE_REQ",0x13:"WRITE_RSP",
    0x16:"PREP_WRITE_REQ",0x17:"PREP_WRITE_RSP",
    0x18:"EXEC_WRITE_REQ",0x19:"EXEC_WRITE_RSP",
    0x1B:"NOTIFY",0x1D:"INDICATE",0x1E:"CONFIRM",
    0x52:"WRITE_CMD",0xD2:"SIGNED_WRITE_CMD"}

L2CAP_SIG = {0x14:"LE_CREDIT_CONN_REQ", 0x15:"LE_CREDIT_CONN_RSP",
    0x16:"L2CAP_FLOW_CTRL_CREDIT_IND",
    0x17:"L2CAP_CREDIT_BASED_CONN_REQ", 0x18:"L2CAP_CREDIT_BASED_CONN_RSP",
    0x19:"L2CAP_RECONFIG_REQ", 0x1A:"L2CAP_RECONFIG_RSP"}

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
    handle, pb, bc = hf & 0xFFF, (hf>>12) & 0x3, (hf>>14) & 0x3
    acl_len = struct.unpack("<H", p[2:4])[0]
    pdu_len = struct.unpack("<H", p[4:6])[0]
    cid = struct.unpack("<H", p[6:8])[0]
    body = p[8:8+pdu_len] if 8+pdu_len <= len(p) else p[8:]
    return handle, pb, bc, pdu_len, cid, body

def main():
    buf = PKLG.read_bytes()
    records = list(iter_records(buf))

    # Per-connection ACL stats
    handle_stats = Counter()
    handle_cids = {}  # handle -> Counter of cids
    base_t = None

    # Collect all ATT events and CoC data per handle
    att_evs = []
    sig_evs = []  # L2CAP Signaling
    coc_pkts = []  # high-CID dynamic data

    for ts, t, payload in records:
        if t not in (0x02, 0x03): continue
        if base_t is None: base_t = ts
        rt = ts - base_t
        dirn = "TX" if t == 0x02 else "RX"
        parsed = parse_acl(payload)
        if not parsed: continue
        handle, pb, bc, pdu_len, cid, body = parsed
        if pb == 0: continue  # ignore fragments for now
        handle_stats[handle] += 1
        handle_cids.setdefault(handle, Counter())[cid] += 1

        if cid == 0x0004 and body:  # ATT
            op = body[0]
            att_evs.append((rt, dirn, handle, op, ATT_OPS.get(op, f"op_{op:#04x}"), body[1:]))
        elif cid == 0x0005 and len(body) >= 4:  # LE Signaling
            code = body[0]
            ident = body[1]
            sig_len = struct.unpack("<H", body[2:4])[0]
            sig_data = body[4:4+sig_len]
            sig_evs.append((rt, dirn, handle, code, L2CAP_SIG.get(code, f"sig_{code:#04x}"), sig_data))
        elif cid >= 0x40 and cid < 0x8000:  # dynamic CoC channel
            coc_pkts.append((rt, dirn, handle, cid, body))

    print(f"\n=== ACL traffic per handle ===")
    for h, n in handle_stats.most_common():
        print(f"  handle {h} ({h:#06x}): {n} packets")
        cids = handle_cids[h].most_common(8)
        for cid, c in cids:
            print(f"    cid {cid:#06x} ({cid}): {c}")

    print(f"\n=== ATT events (handshake hints) — total {len(att_evs)} ===")
    for rt, dirn, h, op, name, body in att_evs:
        print(f"  t={rt:7.3f}  {dirn}  conn={h}  {name:<22} body={body.hex()}")

    print(f"\n=== L2CAP Signaling (CoC setup) — total {len(sig_evs)} ===")
    for rt, dirn, h, code, name, data in sig_evs[:60]:
        print(f"  t={rt:7.3f}  {dirn}  conn={h}  {name:<28} data={data.hex()}")

    print(f"\n=== L2CAP CoC dynamic-channel packets (data!) — total {len(coc_pkts)} ===")
    # Group by (handle, cid) to see which channels carry data
    by_chan = Counter()
    for rt, dirn, h, cid, body in coc_pkts:
        by_chan[(h, cid)] += 1
    print("  channel popularity (handle, cid) -> packet count:")
    for (h, cid), c in by_chan.most_common():
        print(f"    handle={h} cid={cid:#06x}({cid}): {c} pkts")

    # Show first 20 CoC packets on the hottest channel
    if by_chan:
        hottest = by_chan.most_common(1)[0][0]
        print(f"\n  first 20 packets on hottest CoC channel handle={hottest[0]} cid={hottest[1]:#06x}:")
        shown = 0
        for rt, dirn, h, cid, body in coc_pkts:
            if (h, cid) != hottest: continue
            print(f"    t={rt:7.3f}  {dirn}  len={len(body):>3}  {body[:40].hex()}{'…' if len(body)>40 else ''}")
            shown += 1
            if shown >= 20: break

if __name__ == "__main__":
    main()
