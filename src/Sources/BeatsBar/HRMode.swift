import Foundation

enum HRMode: String, CaseIterable {
    case session = "session"
    case kernel  = "kernel"

    var displayName: String {
        switch self {
        case .session: return "Session (BLE 0x180D)"
        case .kernel:  return "Kernel bypass (experimental)"
        }
    }

    var description: String {
        switch self {
        case .session: return "Press Start, do the b-button gesture, HR streams while session is open. Audio disconnects during session."
        case .kernel:  return "Tries to open Apple's AACP L2CAP channel directly. macOS blocks this at the kernel level — work in progress."
        }
    }
}

enum Settings {
    private static let hrModeKey = "hrMode"
    static var hrMode: HRMode {
        get {
            let raw = UserDefaults.standard.string(forKey: hrModeKey) ?? HRMode.session.rawValue
            return HRMode(rawValue: raw) ?? .session
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: hrModeKey) }
    }
}

// Common interface every HR backend implements. The status item controller
// holds one of these and doesn't care which mode it is.
protocol HeartRateBackend: AnyObject {
    var isActive: Bool { get }
    var onHR: ((Int) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var onSessionEnded: (() -> Void)? { get set }
    func start()
    func stop()
}
