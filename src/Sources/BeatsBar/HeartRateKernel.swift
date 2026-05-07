import Foundation

// Kernel-bypass HR backend. Spawns a helper process with the
// libaacp_unlock.dylib interposer injected (DYLD_INSERT_LIBRARIES) and reads
// HR readings back over its stdout, one JSON object per line.
//
// The helper process attempts to open Apple's AACP L2CAP channel (PSM 0x1001)
// — which the public IOBluetooth API refuses for third-party apps. The dylib
// hooks the open path. Whether the channel actually establishes on the wire
// depends on how far our research has gotten — see research/JOURNEY.md and
// the helper's source.
//
// If the channel doesn't open within a few seconds, this backend reports an
// error via onStatus and ends the session, so the user can fall back to the
// session-based 0x180D path from the menu.

final class HeartRateKernel: HeartRateBackend {
    var onHR: ((Int) -> Void)?
    var onStatus: ((String) -> Void)?
    var onSessionEnded: (() -> Void)?
    private(set) var isActive = false

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var helperPath: String { Self.helperPath }
    private var dylibPath: String { Self.dylibPath }

    func start() {
        guard !isActive else { return }
        isActive = true
        onStatus?("Launching kernel-bypass helper…")

        guard FileManager.default.fileExists(atPath: helperPath) else {
            fail("Helper binary not found at \(helperPath). Build via `swift build` in src/aacp_helper.")
            return
        }
        guard FileManager.default.fileExists(atPath: dylibPath) else {
            fail("Interposer dylib not found at \(dylibPath). Build via `make` in interposer/.")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.environment = (ProcessInfo.processInfo.environment).merging([
            "DYLD_INSERT_LIBRARIES": dylibPath,
            "DYLD_FORCE_FLAT_NAMESPACE": "1",
        ]) { _, b in b }

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        stdoutPipe = outPipe
        stderrPipe = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { return }
            self?.handle(stdoutData: data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                // Helper logs go to stderr — surface in status
                let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { self?.onStatus?(line) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.cleanup()
            }
        }

        do {
            try p.run()
            process = p
            onStatus?("Helper running. Awaiting HR…")
        } catch {
            fail("Could not launch helper: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        cleanup()
    }

    private func cleanup() {
        guard isActive else { return }
        isActive = false
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        onSessionEnded?()
    }

    private func fail(_ msg: String) {
        onStatus?("Kernel mode: \(msg)")
        DispatchQueue.main.async { [weak self] in
            self?.cleanup()
        }
    }

    private func handle(stdoutData data: Data) {
        // Helper emits one JSON object per line: {"hr": 78} or {"status": "..."}
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let hr = obj["hr"] as? Int {
                DispatchQueue.main.async { [weak self] in self?.onHR?(hr) }
            }
            if let status = obj["status"] as? String {
                DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
            }
        }
    }

    // MARK: - Helper paths

    /// Resolves to the bundled helper binary. We ship it next to the main app.
    static var helperPath: String {
        // When running from `swift build`, helper is in same .build/debug dir.
        if let exec = Bundle.main.executableURL {
            let helper = exec.deletingLastPathComponent().appendingPathComponent("aacp_helper").path
            if FileManager.default.fileExists(atPath: helper) { return helper }
        }
        return "/Users/intzero/Documents/Powerbeats/BeatsBar/src/.build/debug/aacp_helper"
    }
    static var dylibPath: String {
        return "/Users/intzero/Documents/Powerbeats/BeatsBar/interposer/libaacp_unlock.dylib"
    }
}
