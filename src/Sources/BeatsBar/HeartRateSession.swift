import Foundation
import CoreBluetooth

// Reads HR via the standard BLE Heart Rate Profile (GATT 0x180D / 0x2A37).
// Only available when buds are in fitness-equipment-pairing mode (user has
// to tap-tap-hold the b-button while disconnected from iPhone).
//
// This is the session-mode fallback; the always-on AACP path is blocked by
// macOS at the kernel level. See research/JOURNEY.md.

final class HeartRateSession: NSObject, HeartRateBackend, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let HR_SERVICE = CBUUID(string: "180D")
    static let HR_MEASUREMENT = CBUUID(string: "2A37")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var scanTimer: Timer?

    var onHR: ((Int) -> Void)?
    var onStatus: ((String) -> Void)?
    var onSessionEnded: (() -> Void)?

    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true
        onStatus?("Searching… put both buds in your ears, then double-tap-and-hold the b button.")
        central = CBCentralManager(delegate: self, queue: nil)
        scanTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.timeout()
        }
    }

    func stop() {
        scanTimer?.invalidate()
        scanTimer = nil
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        central?.stopScan()
        peripheral = nil
        isActive = false
        onSessionEnded?()
    }

    private func timeout() {
        if peripheral == nil {
            onStatus?("Timed out waiting for HR mode. Try again.")
            stop()
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [Self.HR_SERVICE], options: nil)
        case .unauthorized:
            onStatus?("Bluetooth permission denied — enable in System Settings.")
            stop()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard services.contains(Self.HR_SERVICE) else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        onStatus?("Found \(peripheral.name ?? "HR"). Connecting…")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onStatus?("Connected. Subscribing…")
        peripheral.discoverServices([Self.HR_SERVICE])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onStatus?("Disconnected.")
        stop()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.HR_SERVICE }) else { return }
        peripheral.discoverCharacteristics([Self.HR_MEASUREMENT], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.HR_MEASUREMENT }) else { return }
        peripheral.setNotifyValue(true, for: ch)
        onStatus?("Streaming.")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.HR_MEASUREMENT, let data = characteristic.value, !data.isEmpty else { return }
        let bpm = parseHR(data)
        onHR?(bpm)
    }

    private func parseHR(_ data: Data) -> Int {
        let flags = data[0]
        if flags & 0x01 != 0 && data.count >= 3 {
            return Int(data[1]) | (Int(data[2]) << 8)
        }
        return Int(data[1])
    }
}
