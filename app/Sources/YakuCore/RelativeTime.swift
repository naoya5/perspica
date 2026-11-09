import Foundation

/// How long ago a history row was.
///
/// Recent rows read as 「3 分前」; anything older than a week falls back to the
/// date, so a long list is not a wall of 「1 か月前」. The wording is written out
/// rather than taken from `RelativeDateTimeFormatter`: the formatter is not
/// `Sendable`, and a handful of Japanese suffixes is less machinery than
/// hopping to the main actor for a string.
public enum RelativeTime {
    /// The boundary between the relative wording and the plain date.
    public static let recentWindow: TimeInterval = 7 * 24 * 3600
    /// Below this the wording is 「たった今」, not 「0 分前」.
    public static let justNowWindow: TimeInterval = 60

    /// The relative wording for anything within a week, the date after that.
    /// `now` is a parameter so the boundaries can be tested.
    public static func text(for date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < justNowWindow { return "たった今" }
        if interval < 3600 { return "\(Int(interval / 60)) 分前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 時間前" }
        if interval < recentWindow { return "\(Int(interval / 86400)) 日前" }
        return date.formatted(.dateTime.year().month().day())
    }
}
