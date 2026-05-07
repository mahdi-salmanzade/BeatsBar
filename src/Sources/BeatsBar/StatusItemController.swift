import AppKit

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private var state = PowerbeatsState()

    private let menu = NSMenu()
    private var hrItem: NSMenuItem!
    private var batteryItemL: NSMenuItem!
    private var batteryItemR: NSMenuItem!
    private var batteryItemCase: NSMenuItem!
    private var connItem: NSMenuItem!
    private var hrSessionItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private let battery: BatteryPoller
    private var hrBackend: HeartRateBackend?
    private var modeMenu: NSMenu!

    init(battery: BatteryPoller) {
        self.battery = battery
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupMenu()
        refresh()
        battery.onUpdate = { [weak self] st in
            guard let self = self else { return }
            var merged = st
            merged.heartRate = self.state.heartRate
            merged.hrSessionActive = self.state.hrSessionActive
            merged.hrError = self.state.hrError
            self.state = merged
            self.refresh()
        }
    }

    private func setupMenu() {
        connItem = NSMenuItem(title: "Searching for Powerbeats…", action: nil, keyEquivalent: "")
        connItem.image = NSImage.icon(.device, height: 16)
        connItem.isEnabled = false
        menu.addItem(connItem)
        menu.addItem(.separator())

        hrItem = NSMenuItem(title: "Heart Rate: —", action: nil, keyEquivalent: "")
        hrItem.image = NSImage.icon(.heart)
        hrItem.isEnabled = false
        menu.addItem(hrItem)

        batteryItemL = NSMenuItem(title: "Left: —", action: nil, keyEquivalent: "")
        batteryItemL.isEnabled = false
        menu.addItem(batteryItemL)

        batteryItemR = NSMenuItem(title: "Right: —", action: nil, keyEquivalent: "")
        batteryItemR.isEnabled = false
        menu.addItem(batteryItemR)

        batteryItemCase = NSMenuItem(title: "Case: —", action: nil, keyEquivalent: "")
        batteryItemCase.isEnabled = false
        menu.addItem(batteryItemCase)

        menu.addItem(.separator())

        hrSessionItem = NSMenuItem(title: "Start HR session…", action: #selector(toggleHR), keyEquivalent: "")
        hrSessionItem.target = self
        menu.addItem(hrSessionItem)

        // HR mode submenu
        let modeRoot = NSMenuItem(title: "HR Mode", action: nil, keyEquivalent: "")
        modeMenu = NSMenu()
        for mode in HRMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectHRMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.toolTip = mode.description
            modeMenu.addItem(item)
        }
        modeRoot.submenu = modeMenu
        menu.addItem(modeRoot)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let aboutItem = NSMenuItem(title: "About BeatsBar…", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func refresh() {
        // Build the menu-bar title with inline icons.
        guard let button = statusItem.button else { return }

        let attr = NSMutableAttributedString()
        let baseline: CGFloat = -3

        // Heart icon + BPM — only shown when we actually have HR data.
        if let hr = state.heartRate {
            if let heartImg = NSImage.icon(.heartFill) {
                let att = NSTextAttachment()
                att.image = heartImg
                att.bounds = CGRect(x: 0, y: baseline, width: heartImg.size.width, height: heartImg.size.height)
                attr.append(NSAttributedString(attachment: att))
            }
            attr.append(NSAttributedString(string: " \(hr)  "))
        }

        // Battery icon (rotated 90° CCW so it stands tall in the bar) + lowest
        // level among L/R, at half size so it doesn't overpower the bar.
        let lowest = [state.leftBattery, state.rightBattery].compactMap { $0 }.min()
        if let lvl = lowest {
            if let battImg = NSImage.icon(.battery(forLevel: lvl), height: 7)?
                .rotated(byDegrees: 90) {
                let att = NSTextAttachment()
                att.image = battImg
                att.bounds = CGRect(x: 0, y: baseline, width: battImg.size.width, height: battImg.size.height)
                attr.append(NSAttributedString(attachment: att))
            }
            attr.append(NSAttributedString(string: " \(lvl)%"))
        } else if state.isConnected {
            attr.append(NSAttributedString(string: "—"))
        }
        button.attributedTitle = attr
        button.toolTip = state.name ?? "BeatsBar"

        // Connection
        if state.isConnected {
            connItem.title = "\(state.name ?? "Powerbeats") connected"
        } else if state.name != nil {
            connItem.title = "\(state.name ?? "Powerbeats") not connected"
        } else {
            connItem.title = "Searching for Powerbeats…"
        }

        // HR
        if let hr = state.heartRate {
            hrItem.title = "Heart Rate: \(hr) bpm"
            hrItem.image = NSImage.icon(.heartFill)
        } else if state.hrSessionActive {
            hrItem.title = state.hrError ?? "Starting session…"
            hrItem.image = NSImage.icon(.heart)
        } else if let err = state.hrError {
            hrItem.title = err
            hrItem.image = NSImage.icon(.heart)
        } else {
            hrItem.title = "Heart Rate: — (start session below)"
            hrItem.image = NSImage.icon(.heart)
        }

        // Battery rows
        renderBatteryRow(batteryItemL, label: "Left", level: state.leftBattery)
        renderBatteryRow(batteryItemR, label: "Right", level: state.rightBattery)
        renderBatteryRow(batteryItemCase, label: "Case", level: state.caseBattery)

        let mode = Settings.hrMode
        let action = state.hrSessionActive ? "Stop HR" : "Start HR"
        hrSessionItem.title = "\(action) (\(mode.displayName))"
        loginItem.state = LoginItem.isEnabled ? .on : .off
        for item in modeMenu.items {
            item.state = (item.representedObject as? String == mode.rawValue) ? .on : .off
        }
    }

    @objc private func selectHRMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = HRMode(rawValue: raw) else { return }
        // If a session is running on the old mode, stop it first.
        if state.hrSessionActive {
            hrBackend?.stop()
        }
        Settings.hrMode = mode
        refresh()
    }

    private func renderBatteryRow(_ item: NSMenuItem, label: String, level: Int?) {
        if let lvl = level {
            item.title = "\(label): \(lvl)%"
            item.image = NSImage.icon(.battery(forLevel: lvl))
        } else {
            item.title = "\(label): —"
            item.image = NSImage.icon(.battery0)
        }
    }

    @objc private func toggleHR() {
        if state.hrSessionActive {
            hrBackend?.stop()
            return
        }
        state.hrSessionActive = true
        state.hrError = nil
        state.heartRate = nil
        refresh()

        let backend: HeartRateBackend = {
            switch Settings.hrMode {
            case .session: return HeartRateSession()
            case .kernel:  return HeartRateKernel()
            }
        }()
        hrBackend = backend
        backend.onStatus = { [weak self] msg in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.state.hrError = msg
                self.refresh()
            }
        }
        backend.onHR = { [weak self] bpm in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.state.heartRate = bpm
                self.state.hrError = nil
                self.refresh()
            }
        }
        backend.onSessionEnded = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.state.hrSessionActive = false
                self.state.heartRate = nil
                self.refresh()
            }
        }
        backend.start()
    }

    @objc private func toggleLoginItem() {
        do {
            if LoginItem.isEnabled {
                try LoginItem.disable()
            } else {
                try LoginItem.enable()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "BeatsBar"
        alert.informativeText = """
        Live battery + heart rate from Powerbeats Pro 2.

        Battery: continuous, while paired.
        Heart Rate: session-based via the standard BLE HR profile (0x180D). \
        Apple's always-on AACP path is blocked at the macOS kernel level — \
        see research/JOURNEY.md in the project repo.
        """
        alert.runModal()
    }
}
