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
            arrow
            inspected
        }
    }

    private var arrow: some View {
        Image(systemName: "arrowtriangle.right.fill")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: 18)
            .frame(maxHeight: .infinity)
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
