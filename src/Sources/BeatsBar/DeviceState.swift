import Foundation

struct PowerbeatsState: Equatable {
    var name: String?
    var address: String?
    var isConnected: Bool = false
    var leftBattery: Int?
    var rightBattery: Int?
    var caseBattery: Int?
    var firmwareVersion: String?
    var lastUpdated: Date = Date()
    var heartRate: Int?
    var hrSessionActive: Bool = false
    var hrError: String?
}

protocol DeviceStateDelegate: AnyObject {
    func deviceStateDidChange(_ state: PowerbeatsState)
}
