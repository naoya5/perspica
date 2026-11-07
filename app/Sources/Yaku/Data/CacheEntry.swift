import Foundation
import SwiftData

/// A finished translation keyed by `CacheKey` (SPEC 5.3, 11).
@Model
final class CacheEntry {
    var key: String
    var target: String
    var lastUsed: Date

    init(key: String, target: String, lastUsed: Date) {
        self.key = key
        self.target = target
        self.lastUsed = lastUsed
    }
}
