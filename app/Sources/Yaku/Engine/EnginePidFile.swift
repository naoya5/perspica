import Foundation

/// What we remember about the engine we started, so a later launch can tell
/// our own leftover process apart from any other llama-server on the machine.
struct EnginePidRecord: Codable, Sendable, Equatable {
    /// The watchdog shell's pid.
    var pid: Int32
    /// The llama-server pid the watchdog started, when it was known.
    var serverPid: Int32?
    var port: UInt16
    var apiKey: String
    var executable: String
    var model: String
    var startedAt: String
}

enum EnginePidFile {
    static func write(_ record: EnginePidRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: AppPaths.enginePIDFile, options: .atomic)
    }

    static func read() -> EnginePidRecord? {
        guard let data = try? Data(contentsOf: AppPaths.enginePIDFile) else { return nil }
        return try? JSONDecoder().decode(EnginePidRecord.self, from: data)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: AppPaths.enginePIDFile)
    }
}
