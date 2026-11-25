import Gtk
import LumaCore

@MainActor
final class InstrumentIconConceptGrid {
    let widget = FlowBox()
    var onChoose: (_ id: String) -> Void = { _ in }

    private var children: [(id: String, child: FlowBoxChild)] = []

    init() {
        widget.selectionMode = .single
        widget.maxChildrenPerLine = 8
        widget.minChildrenPerLine = 8
        widget.homogeneous = true
        widget.columnSpacing = 4
        widget.rowSpacing = 4
        for concept in InstrumentIconCatalog.all {
            let child = FlowBoxChild()
            child.tooltipText = concept.displayName
            child.set(child: InstrumentIconView.makeImage(for: .symbolic(concept.id), pixelSize: 20))
            widget.append(child: child)
            children.append((concept.id, child))
        }
        widget.onSelectedChildrenChanged { [weak self] _ in
            MainActor.assumeIsolated { self?.reportChoice() }
        }
    }

    func show(_ id: String?) {
        guard let child = children.first(where: { $0.id == id })?.child else {
            widget.unselectAll()
            return
        }
        widget.select(child: child)
    }

    private func reportChoice() {
        guard let chosen = children.first(where: { $0.child.isSelected })?.id else { return }
        onChoose(chosen)
    }
}
