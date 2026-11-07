import Darwin
import Foundation

/// Keeps a single Yaku alive (SPEC 7.1).
///
/// The lock is a POSIX `flock` on a file, which the kernel drops when the
/// process exits, however it exits. `flock` is used rather than a pid file
/// because a pid file survives a crash and would need its own staleness check.
enum SingleInstance {
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    /// True when this process may run. False means another Yaku holds the lock.
    static func acquire() -> Bool {
        let path = AppPaths.lockFile.path
        let descriptor = open(path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            // If the lock file cannot even be opened, run anyway rather than
            // refusing to start; the app is still usable without the guard.
            AppLog.write("single instance: could not open \(path); continuing")
            return true
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let holder = readPid(from: descriptor)
            close(descriptor)
            AppLog.write("single instance: another Yaku is already running"
                + (holder.map { " (pid=\($0))" } ?? ""))
            return false
        }

        Self.descriptor = descriptor
        ftruncate(descriptor, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
        fsync(descriptor)
        return true
    }

    private static func readPid(from descriptor: Int32) -> pid_t? {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(text)
    }
}
