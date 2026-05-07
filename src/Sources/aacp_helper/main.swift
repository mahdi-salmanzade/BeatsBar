// aacp_helper — short-lived CLI launched by the menu bar app in "kernel
// bypass" mode. With libaacp_unlock.dylib injected via DYLD_INSERT_LIBRARIES,
// it tries to open the AACP L2CAP channel (PSM 0x1001), send the LibrePods
// handshake + notification register + HRM enable, and then write each parsed
// AAP frame's HR (when found) as JSON on stdout. Status / errors go to
// stderr.
//
// The protocol from helper → parent is one JSON object per line on stdout:
//     {"hr": 78}
//     {"battery": {"left": 46, "right": 46, "case": 92}}
//     {"status": "AACP open failed: 0xe00002bc"}
// stderr is free-form log text that the parent surfaces as status.

import Foundation
import IOBluetooth

let BUDS_BDADDR = "28-2d-7f-20-73-ec"
let AAP_PSM: BluetoothL2CAPPSM = 0x1001

func emit(json obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

func emitStatus(_ msg: String) { emit(json: ["status": msg]) }

func slog(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

final class AACPClient: NSObject, IOBluetoothL2CAPChannelDelegate {
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothL2CAPChannel?
    private var rxBuffer = Data()

    func start() {
        guard let dev = IOBluetoothDevice(addressString: BUDS_BDADDR) else {
            emitStatus("invalid BD_ADDR")
            exit(1)
        }
        device = dev
        slog("Device: \(dev.name ?? "?") connected=\(dev.isConnected())")

        if !dev.isConnected() {
            slog("Opening Classic ACL link…")
            _ = dev.openConnection()
        }
        _ = dev.requestAuthentication()

        slog("Opening AACP L2CAP channel on PSM \(String(format: "0x%04X", AAP_PSM)) …")
        var ch: IOBluetoothL2CAPChannel?
        let r = dev.openL2CAPChannelSync(&ch, withPSM: AAP_PSM, delegate: self)
        slog("openL2CAPChannelSync returned \(String(format: "0x%08x", r))")
        if let ch = ch { channel = ch }
    }

    func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        slog("openComplete status=\(String(format: "0x%08x", error))")
        if error == kIOReturnSuccess {
            sendHandshake()
        } else {
            emitStatus("L2CAP open failed: \(String(format: "0x%08x", error))")
        }
    }

    func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int) {
        rxBuffer.append(Data(bytes: ptr, count: len))
        parseFrames()
    }

    func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        slog("channel closed")
        emitStatus("disconnected")
        exit(0)
    }
    func l2capChannelReconfigured(_ channel: IOBluetoothL2CAPChannel!) {}
    func l2capChannelWriteComplete(_ channel: IOBluetoothL2CAPChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {}
    func l2capChannelQueueSpaceAvailable(_ channel: IOBluetoothL2CAPChannel!) {}

    private func sendHandshake() {
        send(Data([0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        send(Data([0x04, 0x00, 0x04, 0x00, 0x0F, 0x00, 0xFF, 0xFF, 0xFE, 0xFF]))
        send(Data([0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x30, 0x01, 0x00, 0x00, 0x00]))
        slog("handshake + HRM enable sent")
    }

    private func send(_ data: Data) {
        guard let channel = channel else { return }
        _ = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> IOReturn in
            channel.writeSync(UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                              length: UInt16(data.count))
        }
    }

    private func parseFrames() {
        let magic = Data([0x04, 0x00, 0x04, 0x00])
        while true {
            guard let start = rxBuffer.firstRange(of: magic) else {
                if rxBuffer.count > 3 { rxBuffer.removeFirst(rxBuffer.count - 3) }
                return
            }
            if start.lowerBound > rxBuffer.startIndex {
                rxBuffer.removeSubrange(rxBuffer.startIndex..<start.lowerBound)
            }
            guard rxBuffer.count >= 6 else { return }
            let searchStart = rxBuffer.startIndex + 4
            let nextRange = rxBuffer[searchStart...].firstRange(of: magic)
            let frameEnd = nextRange?.lowerBound ?? rxBuffer.endIndex
            handleFrame(rxBuffer.subdata(in: rxBuffer.startIndex..<frameEnd))
            rxBuffer.removeSubrange(rxBuffer.startIndex..<frameEnd)
            if nextRange == nil { return }
        }
    }

    private func handleFrame(_ data: Data) {
        guard data.count >= 6 else { return }
        let opcode = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let payload = data.subdata(in: 6..<data.count)
        slog(String(format: "RX op=0x%04X len=%d", opcode, payload.count))

        if opcode == 0x0004 && payload.count >= 1 {
            let count = Int(payload[0])
            var off = 1
            var bat: [String: Int] = [:]
            for _ in 0..<count {
                guard off + 5 <= payload.count else { break }
                let component = payload[off]
                let level = Int(payload[off + 2])
                switch component {
                case 0x02: bat["right"] = level
                case 0x04: bat["left"] = level
                case 0x08: bat["case"] = level
                default: break
                }
                off += 5
            }
            emit(json: ["battery": bat])
        }

        // TODO: identify the actual HR opcode for Powerbeats Pro 2 and emit
        // {"hr": <bpm>} when we see it. The opcode is being mapped in
        // research/PROTOCOL.md.
    }
}

setbuf(stdout, nil)
let client = AACPClient()
DispatchQueue.global().async { client.start() }
RunLoop.main.run()
