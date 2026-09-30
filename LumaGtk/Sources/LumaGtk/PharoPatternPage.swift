import Foundation
import Gtk
import LumaCore

struct PharoPatternTarget {
    let decoding: PharoPatternDecoding
    let node: DecodedPattern

    init?(reference: String) {
        let parts = reference.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let decoding = PharoPatternRegistry.shared.decoding(withID: parts[0]),
            let node = decoding.root.descendant(withNodeID: UInt(parts[1]))
        else { return nil }
        self.decoding = decoding
        self.node = node
    }
}

@MainActor
final class PharoPatternBytesPage {
    let widget: ScrolledWindow

    private let hexView: HexView
    private var pendingReveal: (top: Double, height: Double)?

    init(target: PharoPatternTarget) {
        let root = target.decoding.root
        var locations: [UUID: PatternLocation] = [:]
        PatternLocation.locateFields(of: root, under: root.id, base: target.decoding.address, into: &locations)
        let emphasis = locations[target.node.id]

        hexView = HexView(bytes: target.decoding.data, baseAddress: target.decoding.address)
        hexView.annotations = locations.values.filter(\.isLeaf).map(\.annotation)
        hexView.emphasis = emphasis?.annotation
        hexView.widget.marginStart = 8
        hexView.widget.marginTop = 8

        widget = ScrolledWindow()
        widget.setPolicy(hscrollbarPolicy: .automatic, vscrollbarPolicy: .automatic)
        widget.hexpand = true
        widget.vexpand = true
        widget.set(child: hexView.widget)

        pendingReveal = emphasis.map { hexView.rowSpan(containing: $0.range.lowerBound) }
        widget.vadjustment?.onChanged { [weak self] adjustment in
            MainActor.assumeIsolated {
                self?.revealEmphasis(in: adjustment)
            }
        }
    }

    private func revealEmphasis(in adjustment: AdjustmentRef) {
        guard let span = pendingReveal, adjustment.upper >= span.top + span.height else { return }
        pendingReveal = nil
        adjustment.value = span.top
    }
}
