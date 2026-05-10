import Charts
import LumaCore
import SwiftUI

struct InstrumentWidgetsRenderer: View {
    let widgets: [InstrumentWidget]
    @ObservedObject var workspace: Workspace
    @Environment(\.instrumentInstance) private var instance: LumaCore.InstrumentInstance?

    var body: some View {
        if widgets.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(widgets) { widget in
                    GroupBox {
                        WidgetCanvas(widget: widget, instance: instance, workspace: workspace)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        widgetHeader(widget: widget)
                    }
                }
            }
        }
    }

    private func widgetHeader(widget: InstrumentWidget) -> some View {
        HStack(spacing: 8) {
            Text(widget.name)
            Spacer()
            if let instance {
                Button {
                    workspace.engine.clearWidget(instance: instance, widget: widget.id)
                } label: {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
    }
}

private struct WidgetCanvas: View {
    let widget: InstrumentWidget
    let instance: LumaCore.InstrumentInstance?
    @ObservedObject var workspace: Workspace

    @State private var state = WidgetState()

    var body: some View {
        Group {
            switch widget.kind {
            case .graph(let cfg):
                graphView(cfg)
            case .list(let cfg):
                listView(cfg)
            }
        }
        .task(id: instance?.id) { await consumeUpdates() }
    }

    @ViewBuilder
    private func graphView(_ cfg: InstrumentWidget.GraphConfig) -> some View {
        if cfg.series.isEmpty {
            Text("No series defined.").font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(cfg.series) { series in
                    let points = state.graphSeries[series.id] ?? []
                    ForEach(points.indices, id: \.self) { i in
                        LineMark(
                            x: .value("x", points[i].x),
                            y: .value("y", points[i].y),
                            series: .value("series", series.name)
                        )
                    }
                }
            }
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private func listView(_ cfg: InstrumentWidget.ListConfig) -> some View {
        if state.listItems.isEmpty {
            Text("No items.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.listItems) { item in
                    listRow(item: item, actions: cfg.actions)
                }
            }
        }
    }

    private func listRow(item: WidgetListItem, actions: [InstrumentWidget.Action]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let accessory = item.accessory {
                Text(accessory).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(actions) { action in
                Button(action.name) { invoke(action: action.id, item: item.id) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func invoke(action: String, item: String) {
        guard let instance else { return }
        let engine = workspace.engine
        Task { @MainActor in
            await engine.invokeWidgetAction(instance: instance, widget: widget.id, action: action, item: item)
        }
    }

    @MainActor
    private func consumeUpdates() async {
        guard let instance else { return }
        let widgetID = widget.id
        let instanceID = instance.id
        let engine = workspace.engine
        state = engine.widgetState(instanceID: instanceID, widget: widgetID)
        for await update in engine.widgetUpdates
        where update.instanceID == instanceID && update.widget == widgetID {
            state.apply(update.kind)
        }
    }
}
