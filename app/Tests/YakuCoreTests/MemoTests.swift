import Foundation
import Testing

@testable import YakuCore

@Suite("Memo")
struct MemoTests {
    @Test("the same key is worked out once")
    func worksOnce() {
        let memo = Memo<String, Int>()
        var calls = 0
        let first = memo.value(for: "a") { calls += 1; return 1 }
        let second = memo.value(for: "a") { calls += 1; return 2 }
        #expect(first == 1)
        #expect(second == 1)
        #expect(calls == 1)
    }

    @Test("different keys are kept apart")
    func keysAreSeparate() {
        let memo = Memo<String, Int>()
        #expect(memo.value(for: "a") { 1 } == 1)
        #expect(memo.value(for: "b") { 2 } == 2)
        #expect(memo.count == 2)
    }

    @Test("the table is dropped once it reaches the limit")
    func bounded() {
        let memo = Memo<Int, Int>(limit: 4)
        for index in 0..<4 { _ = memo.value(for: index) { index } }
        #expect(memo.count == 4)
        // The fifth answer starts a fresh table, so the first key is gone.
        _ = memo.value(for: 99) { 99 }
        #expect(memo.count == 1)
        var recomputed = false
        #expect(memo.value(for: 0) { recomputed = true; return 0 } == 0)
        #expect(recomputed)
    }

    @Test("a limit below one is treated as one")
    func minimumLimit() {
        let memo = Memo<Int, Int>(limit: 0)
        _ = memo.value(for: 1) { 1 }
        _ = memo.value(for: 2) { 2 }
        #expect(memo.count == 1)
    }

    @Test("removeAll forgets everything")
    func clearing() {
        let memo = Memo<Int, Int>()
        _ = memo.value(for: 1) { 1 }
        memo.removeAll()
        #expect(memo.count == 0)
    }

    @Test("answers are the same from several threads")
    func threadSafe() async {
        let memo = Memo<Int, Int>(limit: 64)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    for _ in 0..<50 { _ = memo.value(for: index) { index * 2 } }
                }
            }
        }
        for index in 0..<32 {
            #expect(memo.value(for: index) { -1 } == index * 2)
        }
    }
}
