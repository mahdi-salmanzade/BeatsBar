"""Focus on the hot AAP CoC channel (handle=1, cid=0x040c). Identify
opcodes by their frequency and payload patterns. Look specifically for
periodic packets (HR @ ~5s cadence) and TX-direction commands from iPhone."""
import struct
import sys
from pathlib import Path
from collections import Counter, defaultdict

PKLG = Path("/Users/intzero/Documents/Powerbeats/sysdiagnose_2026.05.07_11-46-57+0400_iPhone-OS_iPhone_23E261/logs/Bluetooth/bluetoothd-hci-latest.pklg")

TARGET_HANDLE = 1
TARGET_CID = 0x040c

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

def parse_aap(body):
    """Returns (opcode, payload) if this is an AAP frame, else None."""
    if len(body) < 6 or body[:4] != b"\x04\x00\x04\x00":
        return None
    op = struct.unpack("<H", body[4:6])[0]
    return (op, body[6:])

def main():
    buf = PKLG.read_bytes()
    base_t = None
    pkts = []  # (rel_t, dir, opcode, payload)

    for ts, t, payload in iter_records(buf):
        if t not in (0x02, 0x03): continue
        if base_t is None: base_t = ts
        rt = ts - base_t
        dirn = "TX" if t == 0x02 else "RX"
        parsed = parse_acl(payload)
        if not parsed: continue
        handle, pb, pdu_len, cid, body = parsed
        if pb == 0: continue  # ignore continuations for now (TODO: reassemble)
        if handle != TARGET_HANDLE or cid != TARGET_CID: continue
        aap = parse_aap(body)
        if not aap: continue
        op, pl = aap
        pkts.append((rt, dirn, op, pl))

    print(f"[focus] handle={TARGET_HANDLE} cid={TARGET_CID:#06x}: {len(pkts)} AAP frames")

    # Direction + opcode histogram
    by_dir = Counter()
    by_op = Counter()
    by_dir_op = Counter()
    for rt, d, op, pl in pkts:
        by_dir[d] += 1
        by_op[op] += 1
        by_dir_op[(d, op)] += 1

    print(f"\n[focus] by direction: {dict(by_dir)}")
    print(f"\n[focus] opcode histogram (top 25):")
    for op, c in by_op.most_common(25):
        tx = by_dir_op[("TX", op)]
        rx = by_dir_op[("RX", op)]
        print(f"  op {op:#06x} ({op:>5}): total={c:>4}  TX={tx:>4}  RX={rx:>4}")

    # TX packets are key — what iPhone sends to the buds.
    tx_pkts = [p for p in pkts if p[1] == "TX"]
    print(f"\n[focus] TX packets ({len(tx_pkts)}) — iPhone -> buds:")
    for rt, d, op, pl in tx_pkts[:60]:
        ascii_part = "".join(chr(b) if 0x20<=b<0x7f else "." for b in pl[:48])
        print(f"  t={rt:7.3f}  TX  op={op:#06x}  len={len(pl):>4}  {pl[:48].hex()}  |{ascii_part}|")

    # Look for periodic packets (likely HR streaming).
    # Group packets by opcode, look at inter-arrival intervals.
    print(f"\n[focus] inter-arrival analysis (RX, looking for periodic ~5s opcode = HR):")
    by_op_times = defaultdict(list)
    for rt, d, op, pl in pkts:
        if d == "RX":
            by_op_times[op].append(rt)
    for op, times in sorted(by_op_times.items(), key=lambda kv: -len(kv[1])):
        if len(times) < 3: continue
        # Compute gaps
        gaps = [times[i+1]-times[i] for i in range(len(times)-1)]
        avg = sum(gaps)/len(gaps)
        median = sorted(gaps)[len(gaps)//2]
        print(f"  op {op:#06x}: n={len(times):>4}  avg_gap={avg:.3f}s  median_gap={median:.3f}s  "
              f"first_t={times[0]:.2f}s  last_t={times[-1]:.2f}s")

if __name__ == "__main__":
    main()
