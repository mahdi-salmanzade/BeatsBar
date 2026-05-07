import Foundation

// Polls `system_profiler SPBluetoothDataType -json` every N seconds and extracts
// connection state + battery for the Powerbeats Pro 2. macOS already tracks
// this internally via IOBluetooth — system_profiler is a reliable reader for it.

final class BatteryPoller {
    private let interval: TimeInterval
    private let deviceNameContains: String  // e.g. "Powerbeats"
    private var timer: Timer?
    var onUpdate: ((PowerbeatsState) -> Void)?

    init(interval: TimeInterval = 5.0, deviceNameContains: String = "Powerbeats") {
        self.interval = interval
        self.deviceNameContains = deviceNameContains
    }

    func start() {
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let state = self.queryBluetoothState()
            DispatchQueue.main.async {
                self.onUpdate?(state)
            }
        }
    }

    private func queryBluetoothState() -> PowerbeatsState {
        var st = PowerbeatsState()
        st.lastUpdated = Date()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return st
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bt = (json["SPBluetoothDataType"] as? [Any])?.first as? [String: Any] else {
            return st
        }

        let needle = self.deviceNameContains.lowercased()

        // Each section is an array of single-key dicts: [{ "Device Name": { ...props... } }]
        for (section, isConnected) in [("device_connected", true), ("device_not_connected", false)] {
            guard let items = bt[section] as? [[String: Any]] else { continue }
            for entry in items {
                for (deviceName, propsAny) in entry {
                    guard deviceName.lowercased().contains(needle),
                          let props = propsAny as? [String: Any] else { continue }
                    st.name = deviceName
                    st.isConnected = isConnected
                    st.address = props["device_address"] as? String
                    if let lb = props["device_batteryLevelLeft"] as? String {
                        st.leftBattery = parsePercent(lb)
                    }
                    if let rb = props["device_batteryLevelRight"] as? String {
                        st.rightBattery = parsePercent(rb)
                    }
                    if let cb = props["device_batteryLevelCase"] as? String {
                        st.caseBattery = parsePercent(cb)
                    }
                    if let fw = props["device_firmwareVersion"] as? String {
                        st.firmwareVersion = fw
                    }
                    return st
                }
            }
        }
        return st
    }

    private func parsePercent(_ s: String) -> Int? {
        // Format examples: "92%", "100%"
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        return Int(trimmed)
    }
}
