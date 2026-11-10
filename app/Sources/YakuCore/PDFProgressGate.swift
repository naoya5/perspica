/// Coalesces progress before observable/persistent models are mutated.
public struct PDFProgressGate: Sendable {
    private var value = -1.0
    private var stage = ""

    public init() {}

    public mutating func accepts(value: Double, stage: String) -> Bool {
        guard value.isFinite else { return false }
        let value = min(max(value, 0), 1)
        guard abs(value - self.value) >= 0.01 || stage != self.stage || value == 1 else { return false }
        guard value != self.value || stage != self.stage else { return false }
        self.value = value
        self.stage = stage
        return true
    }
}
