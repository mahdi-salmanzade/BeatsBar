import Foundation
import Darwin

// Process-level single-instance lock. Held via a flock() on a file in
// ~/Library/Application Support/BeatsBar/. The lock is automatically released
// when the process exits (whether cleanly or via crash / kill), so we never
// strand the lock.
//
// On startup BeatsBar tries to acquire the lock. If another instance is
// already holding it, we read its PID from the file, log who's running, and
// exit. This is a fast no-op for the duplicate launch — the launchd
// LaunchAgent and a manual run can coexist gracefully.

enum SingleInstance {
    private static var lockFD: Int32 = -1

    static func acquireOrExit() {
        let fs = FileManager.default
        let support = fs.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeatsBar", isDirectory: true)
        try? fs.createDirectory(at: support, withIntermediateDirectories: true)
        let lockURL = support.appendingPathComponent("instance.lock")

        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 {
            // Couldn't open the lock file at all — let the app start anyway.
            return
        }

        // Non-blocking exclusive lock. Released automatically on process exit.
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Someone else holds it. Read the PID they wrote so we can log who.
            var buf = [UInt8](repeating: 0, count: 32)
            let n = read(fd, &buf, buf.count)
            close(fd)
            let other = (n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) ?? "?" : "?")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            FileHandle.standardError.write(Data("[BeatsBar] another instance is already running (pid \(other)). Exiting.\n".utf8))
            exit(0)
        }

        // We hold the lock. Write our PID for the next launch to read.
        ftruncate(fd, 0)
        let pid = String(getpid())
        _ = pid.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
        // Keep the FD open for the lifetime of the process so the lock stays held.
        lockFD = fd
    }
}
