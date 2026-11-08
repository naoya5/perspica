import Foundation
import Testing
@testable import YakuCore

@Suite("Relative time")
struct RelativeTimeTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func text(secondsAgo: TimeInterval) -> String {
        RelativeTime.text(for: base.addingTimeInterval(-secondsAgo), now: base)
    }

    @Test("under a minute is たった今")
    func justNow() {
        #expect(text(secondsAgo: 0) == "たった今")
        #expect(text(secondsAgo: 59) == "たった今")
    }

    @Test("minutes, hours and days each get their own wording")
    func units() {
        #expect(text(secondsAgo: 60) == "1 分前")
        #expect(text(secondsAgo: 3 * 60) == "3 分前")
        #expect(text(secondsAgo: 59 * 60) == "59 分前")
        #expect(text(secondsAgo: 3600) == "1 時間前")
        #expect(text(secondsAgo: 23 * 3600) == "23 時間前")
        #expect(text(secondsAgo: 86400) == "1 日前")
        #expect(text(secondsAgo: 6 * 86400) == "6 日前")
    }

    @Test("a week or more is a date, not a count of days")
    func olderThanAWeek() {
        let week = text(secondsAgo: RelativeTime.recentWindow)
        #expect(week != "7 日前")
        // The date form's own output for that day, which is what the row shows.
        let expected = base.addingTimeInterval(-RelativeTime.recentWindow)
            .formatted(.dateTime.year().month().day())
        #expect(week == expected)
    }
}
