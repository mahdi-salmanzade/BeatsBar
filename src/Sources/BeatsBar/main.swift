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

// Enforce single-instance BEFORE setting up AppKit — otherwise the duplicate
// briefly grabs an NSStatusItem and you see flicker.
SingleInstance.acquireOrExit()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu-bar-only, no Dock icon
app.run()
