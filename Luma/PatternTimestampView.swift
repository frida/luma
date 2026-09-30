import SwiftUI

struct PatternTimestampView: View {
    let date: Date

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                MonthCalendar(date: date, calendar: Self.calendar)
                AnalogClock(date: date, calendar: Self.calendar)
                    .frame(width: 128, height: 128)
            }
            Text(date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeZone: Self.calendar.timeZone)))
                .textSelection(.enabled)
        }
    }
}

private struct MonthCalendar: View {
    let date: Date
    let calendar: Calendar

    private var title: String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted).month(.wide).year()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var leadingBlanks: Int {
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        return (calendar.component(.weekday, from: firstOfMonth) - calendar.firstWeekday + 7) % 7
    }

    private var days: Range<Int> {
        calendar.range(of: .day, in: .month, for: date)!
    }

    var body: some View {
        let today = calendar.component(.day, from: date)
        VStack(spacing: 6) {
            Text(title)
                .fontWeight(.semibold)
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { symbol in
                        Text(symbol.element)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                    }
                }
                ForEach(weeks, id: \.self) { week in
                    GridRow {
                        ForEach(Array(week.enumerated()), id: \.offset) { cell in
                            if let day = cell.element {
                                Text("\(day)")
                                    .frame(width: 22, height: 18)
                                    .foregroundStyle(day == today ? Color.white : Color.primary)
                                    .background(day == today ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                            } else {
                                Color.clear.frame(width: 22, height: 18)
                            }
                        }
                    }
                }
            }
        }
    }

    private var weeks: [[Int?]] {
        let cells = [Int?](repeating: nil, count: leadingBlanks) + days.map { Optional($0) }
        let padded = cells + [Int?](repeating: nil, count: (7 - cells.count % 7) % 7)
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<$0 + 7]) }
    }
}

private struct AnalogClock: View {
    let date: Date
    let calendar: Calendar

    var body: some View {
        Canvas { canvas, size in
            let radius = min(size.width, size.height) / 2 - 1
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            canvas.stroke(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.secondary), lineWidth: 1)
            for tick in 0..<12 {
                let inner = tick % 3 == 0 ? 0.8 : 0.88
                canvas.stroke(
                    hand(from: center, angle: Double(tick) / 12, length: radius, start: radius * inner), with: .color(.secondary),
                    lineWidth: tick % 3 == 0 ? 2 : 1)
            }
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            let seconds = Double(time.second ?? 0)
            let minutes = Double(time.minute ?? 0) + seconds / 60
            let hours = Double((time.hour ?? 0) % 12) + minutes / 60
            canvas.stroke(
                hand(from: center, angle: hours / 12, length: radius * 0.5), with: .color(.primary),
                style: StrokeStyle(lineWidth: 3, lineCap: .round))
            canvas.stroke(
                hand(from: center, angle: minutes / 60, length: radius * 0.75), with: .color(.primary),
                style: StrokeStyle(lineWidth: 2, lineCap: .round))
            canvas.stroke(hand(from: center, angle: seconds / 60, length: radius * 0.85), with: .color(.red), lineWidth: 1)
        }
    }

    private func hand(from center: CGPoint, angle turns: Double, length: CGFloat, start: CGFloat = 0) -> Path {
        let radians = turns * 2 * .pi
        let direction = CGVector(dx: sin(radians), dy: -cos(radians))
        return Path {
            $0.move(to: CGPoint(x: center.x + direction.dx * start, y: center.y + direction.dy * start))
            $0.addLine(to: CGPoint(x: center.x + direction.dx * length, y: center.y + direction.dy * length))
        }
    }
}
