import LumaCore
import SwiftUI
import SwiftyPharo

/// What a page is showing to its right: the object a cell just produced, or
/// what its last run captured when there is no VM to ask again.
enum PharoInspection {
    case live(PharoObject)
    case captured(PharoSnapshot)
}

/// The pane a page opens its values into, kept beside the page rather than
/// under the cell so drilling has somewhere to go.
struct PharoInspectionPane: View {
    let inspection: PharoInspection
    let onClose: () -> Void

    private let runtime = PharoRuntime.shared

    var body: some View {
        HStack(spacing: 0) {
            PharoDrillArrow()
            inspected
        }
    }

    @ViewBuilder
    private var inspected: some View {
        switch inspection {
        case .live(let object):
            PharoInspectorView(runtime: runtime, root: object)
                .overlay(alignment: .topTrailing) { closeButton }
        case .captured(let snapshot):
            PharoSnapshotView(snapshot: snapshot)
                .overlay(alignment: .topTrailing) { closeButton }
                .pharoPane()
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(8)
        .accessibilityIdentifier("pharo.inspection.close")
    }
}

/// Marks a step from what was inspected to what came out of it, the way
/// Glamorous Toolkit points from a page into its inspector and on down.
struct PharoDrillArrow: View {
    var body: some View {
        Image(systemName: "arrowtriangle.right.fill")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: 24)
            .frame(maxHeight: .infinity)
    }
}

extension View {
    /// Lepiter floats each pane as a card, which is what tells one apart from
    /// the next once the arrow between them is all that separates them.
    func pharoPane() -> some View {
        background(.pharoPane).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension ShapeStyle where Self == Color {
    static var pharoPane: Color {
        #if canImport(AppKit)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var pharoGutter: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}
