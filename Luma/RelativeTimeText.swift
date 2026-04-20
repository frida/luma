import LumaCore
import SwiftUI

/// Live-updating "time ago" label. Wraps a SwiftUI TimelineView so the
/// rendered string refreshes once a minute — matching the smallest
/// bucket `RelativeTime` emits ("1 min ago"). Longer buckets don't
/// change any faster than every minute either, so this keeps every
/// visible timestamp honest without extra machinery.
struct RelativeTimeText: View {
    let date: Date
    var font: Font = .caption2
    var color: Color = .secondary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(LumaCore.RelativeTime.string(from: date, now: context.date))
                .font(font)
                .foregroundStyle(color)
        }
    }
}
