import Foundation

/// File sizes in the units the model cards use (SPEC 7.5).
public enum ByteCount {
    /// A tenth of a gigabyte is where GB becomes more readable than MB, which
    /// is also where the model cards switch for the 0.8B file (0.57 GB).
    private static let gigabyteThreshold: Int64 = 100_000_000
    private static let megabyteThreshold: Int64 = 1_000_000

    public static func format(_ bytes: Int64) -> String {
        if bytes >= gigabyteThreshold {
            return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
        }
        if bytes >= megabyteThreshold {
            return String(format: "%.0f MB", Double(bytes) / 1_000_000)
        }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }
}
