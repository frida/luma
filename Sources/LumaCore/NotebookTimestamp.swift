import Foundation

/// Notebook-style timestamp: "14:32", "Yesterday", "Monday",
/// "Apr 20", "Apr 20, 2025". Deliberately anchored to absolute
/// dates rather than elapsed durations, so the notebook reads like
/// a log of findings instead of a chat transcript.
public enum NotebookTimestamp {
    public static func string(
        from date: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.locale(locale).hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day,
            (0..<7).contains(daysAgo)
        {
            return date.formatted(.dateTime.locale(locale).weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.locale(locale).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.locale(locale).year().month(.abbreviated).day())
    }
}
