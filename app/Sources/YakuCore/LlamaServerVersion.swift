import Foundation

/// The version `llama-server --version` reports, and whether Perspica supports it.
///
/// llama.cpp prints `version: 0.7.0 (build 11669, commit 620d2225c)` since it
/// moved to numbered releases, and `version: 6123 (abc1234)` before that, when
/// the build number was the only version.
public struct LlamaServerVersion: Equatable, Sendable, CustomStringConvertible {
    /// `major.minor.patch`, when the build has a release number.
    public var release: [Int]?
    /// The build number (the count of commits).
    public var build: Int?

    public init(release: [Int]?, build: Int?) {
        self.release = release
        self.build = build
    }

    /// The oldest llama.cpp Perspica was tested with. Users install it with
    /// Homebrew and upgrade it themselves, so older builds are refused with a
    /// message that says how to upgrade.
    public static let minimum = LlamaServerVersion(release: [0, 7, 0], build: 11669)

    /// Reads the output of `llama-server --version`. Nil when no version line is found.
    public static func parse(_ output: String) -> LlamaServerVersion? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("version:") else { continue }
            let rest = trimmed.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
            let token = rest.prefix { !$0.isWhitespace }
            var version = LlamaServerVersion(release: nil, build: nil)
            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            if parts.count >= 2, parts.allSatisfy({ $0 != nil }) {
                version.release = parts.compactMap { $0 }
            } else if let number = Int(token) {
                version.build = number
            }
            if let range = rest.range(of: #"build (\d+)"#, options: .regularExpression) {
                version.build = Int(rest[range].dropFirst("build ".count))
            }
            return version.release == nil && version.build == nil ? nil : version
        }
        return nil
    }

    /// Whether this build is at least `minimum`. Release numbers are compared
    /// when both have one; a build from before numbered releases is compared by
    /// its build number.
    public func isSupported(minimum: LlamaServerVersion = .minimum) -> Bool {
        if let release, let floor = minimum.release {
            return Self.compare(release, floor) >= 0
        }
        if let build, let floor = minimum.build {
            return build >= floor
        }
        return true
    }

    public var description: String {
        if let release { return release.map(String.init).joined(separator: ".") }
        if let build { return "build \(build)" }
        return "unknown"
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}
