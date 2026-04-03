import SwiftUI

struct ITraceTimeline: View {
    let functionCalls: [TraceFunctionCall]
    let totalEntryCount: Int
    @Binding var selectedCallIndex: Int?

    @Environment(\.colorScheme) private var colorScheme

    private let stripHeight: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            Canvas { context, size in
                guard !functionCalls.isEmpty, totalEntryCount > 0 else { return }

                var x: CGFloat = 0
                for (i, call) in functionCalls.enumerated() {
                    let w = max(2, CGFloat(call.entryCount) / CGFloat(totalEntryCount) * width)
                    let isSelected = selectedCallIndex == i

                    let hue = functionHue(call.functionName)
                    let color = Color(
                        hue: hue,
                        saturation: colorScheme == .dark ? 0.7 : 0.6,
                        brightness: colorScheme == .dark ? 0.55 : 0.7
                    )

                    let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                    context.fill(Path(rect), with: .color(color))

                    // Separator line.
                    if i > 0 {
                        let sep = CGRect(x: x, y: 2, width: 0.5, height: size.height - 4)
                        context.fill(
                            Path(sep),
                            with: .color(colorScheme == .dark ? .black.opacity(0.3) : .white.opacity(0.3))
                        )
                    }

                    // Selection indicator.
                    if isSelected {
                        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
                        let borderColor: Color = colorScheme == .dark ? .white.opacity(0.9) : .black.opacity(0.7)
                        context.stroke(Path(roundedRect: inset, cornerRadius: 2), with: .color(borderColor), lineWidth: 1.5)
                    }

                    // Draw label if segment is wide enough.
                    if w > 30 {
                        let label = call.shortName
                        let textRect = CGRect(x: x + 6, y: 2, width: w - 12, height: size.height - 4)
                        var labelCtx = context
                        labelCtx.clip(to: Path(textRect))
                        let resolved = labelCtx.resolve(
                            Text(label)
                                .font(.system(size: 9, weight: isSelected ? .bold : .regular, design: .monospaced))
                                .foregroundStyle(isSelected ? .white : (colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6)))
                        )
                        labelCtx.draw(resolved, at: CGPoint(x: textRect.maxX, y: textRect.midY), anchor: .trailing)
                    }

                    x += w
                }
            }
            .background(colorScheme == .dark ? Color.black.opacity(0.7) : Color(white: 0.9))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                TimelineTooltipOverlay(
                    functionCalls: functionCalls,
                    totalEntryCount: totalEntryCount,
                    width: width,
                    height: stripHeight
                )
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                selectedCallIndex = callIndex(at: location.x, width: width)
            }
        }
        .frame(height: stripHeight)
    }

    private func segmentFrame(index: Int, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        var accX: CGFloat = 0
        for (i, call) in functionCalls.enumerated() {
            let w = max(2, CGFloat(call.entryCount) / CGFloat(max(1, totalEntryCount)) * width)
            if i == index { return (accX, w) }
            accX += w
        }
        return (0, 0)
    }

    private func callIndex(at x: CGFloat, width: CGFloat) -> Int {
        guard !functionCalls.isEmpty, totalEntryCount > 0 else { return 0 }

        var accX: CGFloat = 0
        for (i, call) in functionCalls.enumerated() {
            let w = max(2, CGFloat(call.entryCount) / CGFloat(totalEntryCount) * width)
            if x < accX + w {
                return i
            }
            accX += w
        }
        return functionCalls.count - 1
    }

    private func functionHue(_ name: String) -> Double {
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Double(hash % 360) / 360.0
    }
}

private struct TimelineTooltipOverlay: NSViewRepresentable {
    let functionCalls: [TraceFunctionCall]
    let totalEntryCount: Int
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> TimelineTooltipNSView {
        let view = TimelineTooltipNSView()
        view.update(functionCalls: functionCalls, totalEntryCount: totalEntryCount, width: width)
        return view
    }

    func updateNSView(_ view: TimelineTooltipNSView, context: Context) {
        view.update(functionCalls: functionCalls, totalEntryCount: totalEntryCount, width: width)
    }
}

class TimelineTooltipNSView: NSView {
    private var tooltipTags: [NSView.ToolTipTag] = []
    private var owners: [TooltipOwner] = []
    private var trackingArea: NSTrackingArea?

    func update(functionCalls: [TraceFunctionCall], totalEntryCount: Int, width: CGFloat) {
        for tag in tooltipTags {
            removeToolTip(tag)
        }
        tooltipTags.removeAll()
        owners.removeAll()

        guard totalEntryCount > 0 else { return }

        let h = max(bounds.height, 32)

        var x: CGFloat = 0
        for call in functionCalls {
            let w = max(2, CGFloat(call.entryCount) / CGFloat(totalEntryCount) * width)
            let rect = NSRect(x: x, y: 0, width: w, height: h)
            let owner = TooltipOwner(text: call.functionName)
            owners.append(owner)
            let tag = addToolTip(rect, owner: owner, userData: nil)
            tooltipTags.append(tag)
            x += w
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
}

private class TooltipOwner: NSObject, NSViewToolTipOwner {
    let text: String

    init(text: String) {
        self.text = text
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        text
    }
}
