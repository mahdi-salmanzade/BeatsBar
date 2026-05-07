import Foundation
import AppKit

// LaunchAgent-based login item management. Writes a plist under
// ~/Library/LaunchAgents/ pointing to our executable. Works for any
// CLI binary (no .app bundle / signing requirements). User can toggle
// from the menu.
//
// Plist key reference: https://www.manpagez.com/man/5/launchd.plist/

enum LoginItem {
    static let label = "tech.intzero.beatsbar"
    static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() throws {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let absolute = (exe as NSString).standardizingPath
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [absolute],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/beatsbar.out.log",
            "StandardErrorPath": "/tmp/beatsbar.err.log",
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        // Bootstrap into the user's launchd domain so it starts on next login.
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    static func disable() throws {
        if isEnabled {
            run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let null = Pipe()
        p.standardOutput = null
        p.standardError = null
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
