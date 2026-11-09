import Foundation

/// A small, bounded memo for expensive pure work.
///
/// The panel asks for the source text's height on every redraw and the reveal
/// animation redraws at 30Hz, so the same string was measured dozens of times a
/// second. A profile showed that work as CoreText shaping on the main thread,
/// and removing it took the translating CPU from 18.5% to 12.3%.
///
/// The whole table is dropped once it reaches `limit`, rather than evicting one
/// entry at a time: the callers here have a handful of live keys (the panel's
/// source, its translation, a few demo strings), so the table stays small and
/// the policy stays simple.
public final class Memo<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Key: Value] = [:]
    private let limit: Int

    public init(limit: Int = 16) {
        self.limit = max(1, limit)
    }

    /// How many answers are held. Only for tests.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// The stored answer for `key`, or the result of `work` (which is then
    /// stored). `work` runs outside the lock, so two callers asking for the
    /// same missing key may both compute it; that is fine for the pure work
    /// this is used for, and it keeps the lock off the main thread's drawing.
    public func value(for key: Key, _ work: () -> Value) -> Value {
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached { return cached }

        let computed = work()

        lock.lock()
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = computed
        lock.unlock()
        return computed
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
