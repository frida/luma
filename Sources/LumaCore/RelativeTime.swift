import Foundation

/// Compact, UI-friendly "time ago" strings. Bucketed so the numbers
/// don't churn on every tick: rounding is coarse for older timestamps
/// because the exact value stops mattering the further out you go.
///
/// Examples: "just now", "5 min ago", "2 hr ago", "yesterday",
/// "3 days ago", "last week", "Jan 5".
public enum RelativeTime {
    public static func string(from date: Date, now: Date = .now) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 0 { return "just now" }

        let seconds = Int(interval)
        if seconds < 45 { return "just now" }
        if seconds < 90 { return "1 min ago" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }

        let hours = minutes / 60
        if hours < 22 { return "\(hours) hr ago" }

        let days = Int(interval / 86_400)
        if days < 1 { return "yesterday" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 14 { return "last week" }
        if days < 30 { return "\(days / 7) weeks ago" }

        let formatter = Self.absoluteFormatter
        return formatter.string(from: date)
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()
}
