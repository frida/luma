import LumaCore
import SwiftUI

struct InstrumentWidgetPage<Heading: View>: View {
    let widgets: [InstrumentWidget]
    let layout: InstrumentLayout
    var child: InstrumentChild? = nil
    let gate: InstrumentPageGate
    let engine: Engine
    @Binding var selection: SidebarItemID?
    @ViewBuilder let heading: () -> Heading
    @Environment(\.instrumentInstance) private var instance

    @State private var viewportHeight: CGFloat = 0
    @State private var headingHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.spacing) {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    heading()
                    if let waiting = instance.flatMap({ engine.gate(of: $0).waitingLabel }) {
                        Label(waiting, systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { headingHeight = $0 }

                InstrumentWidgetsRenderer(
                    widgets: widgets,
                    layout: layout,
                    height: widgetAreaHeight,
                    child: child,
                    engine: engine,
                    selection: $selection
                )
                .instrumentApprovalGate(instanceID: gate.instanceID, icon: gate.icon, name: gate.name, engine: engine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Self.margin)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { viewportHeight = $0 }
    }

    private static var spacing: CGFloat { 12 }
    private static var margin: CGFloat { 8 }

    private var widgetAreaHeight: CGFloat {
        viewportHeight - 2 * Self.margin - headingHeight - Self.spacing
    }
}

struct InstrumentPageGate {
    let instanceID: UUID?
    let icon: InstrumentIcon
    let name: String
}
