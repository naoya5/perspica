import Darwin
import Foundation

/// Keeps a single Yaku alive (SPEC 7.1).
///
/// The lock is a POSIX `flock` on a file, which the kernel drops when the
/// process exits, however it exits. `flock` is used rather than a pid file
/// because a pid file survives a crash and would need its own staleness check.
enum SingleInstance {
    nonisolated(unsafe) private static var descriptors: [Int32] = []

    /// True when this process may run. False means another Yaku holds the lock.
    static func acquire() -> Bool {
        guard acquire(path: AppPaths.lockFile.path) else { return false }
        let legacy = AppPaths.legacySupportDirectory.appendingPathComponent("Yaku.lock").path
        if FileManager.default.fileExists(atPath: legacy), !acquire(path: legacy) {
            for descriptor in descriptors { close(descriptor) }
            descriptors = []
            return false
        }
        return true
    }

    private static func acquire(path: String) -> Bool {
        let descriptor = open(path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            // Migration must never run without exclusive access.
            return false
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }

        descriptors.append(descriptor)
        ftruncate(descriptor, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
        fsync(descriptor)
        return true
    }
}
