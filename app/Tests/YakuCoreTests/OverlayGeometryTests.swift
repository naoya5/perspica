import Foundation
import Testing
@testable import YakuCore

@Suite("Overlay event and widening geometry")
struct OverlayGeometryTests {
    @Test("right-hand columns use a relative width bounded by the neighbor")
    func rightColumn() {
        let frame = CGRect(x: 700, y: 200, width: 90, height: 20)
        let neighbor = CGRect(x: 920, y: 205, width: 80, height: 20)
        #expect(OverlayGeometry.wideningWidth(frame: frame, neighbors: [neighbor], captureRight: 1200) == 212)
    }

    @Test("a selected capture bounds widening, not the full display")
    func selectedCapture() {
        let frame = CGRect(x: 700, y: 200, width: 90, height: 20)
        #expect(OverlayGeometry.wideningWidth(frame: frame, neighbors: [], captureRight: 850) == 150)
        #expect(OverlayGeometry.wideningWidth(frame: frame, neighbors: [], captureRight: 790) == nil)
    }

    @Test("blocks on other rows do not limit widening")
    func otherRows() {
        let frame = CGRect(x: 700, y: 200, width: 90, height: 20)
        let other = CGRect(x: 800, y: 300, width: 90, height: 20)
        #expect(OverlayGeometry.wideningWidth(frame: frame, neighbors: [other], captureRight: 1000) == 300)
    }

    @Test("overflow retains the original top and the entire downward extension")
    func fullHitTarget() {
        let frame = CGRect(x: 700, y: 200, width: 90, height: 20)
        let hit = OverlayGeometry.hitRect(frame: frame, width: 140, height: 80)
        #expect(hit.contains(CGPoint(x: 705, y: 219)))
        #expect(hit.contains(CGPoint(x: 835, y: 141)))
        #expect(hit.maxY == 222)
        #expect(hit.minY == 138)
    }
}
