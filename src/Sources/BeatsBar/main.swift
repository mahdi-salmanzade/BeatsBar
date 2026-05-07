import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var battery: BatteryPoller!
    private var status: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        battery = BatteryPoller(interval: 5.0, deviceNameContains: "Powerbeats")
        status = StatusItemController(battery: battery)
        battery.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu-bar-only, no Dock icon
app.run()
