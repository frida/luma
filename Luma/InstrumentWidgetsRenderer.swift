import Charts
import LumaCore
import SwiftUI

struct InstrumentWidgetsRenderer: View {
    let widgets: [InstrumentWidget]
    let engine: Engine
    @Environment(\.instrumentInstance) private var instance: LumaCore.InstrumentInstance?

    var body: some View {
        if widgets.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(widgets) { widget in
                    GroupBox {
                        WidgetCanvas(widget: widget, instance: instance, engine: engine)
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
                    engine.clearWidget(instance: instance, widget: widget.id)
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
    let engine: Engine

    @State private var state = WidgetState()

    var body: some View {
        Group {
            switch widget.kind {
            case .counter(let cfg):
                counterView(cfg)
            case .histogram:
                histogramView()
            case .graph(let cfg):
                graphView(cfg)
            case .list(let cfg):
                listView(cfg)
            case .table(let cfg):
                tableView(cfg)
            case .hex:
                hexView()
            case .console(let cfg):
                consoleView(cfg)
            }
        }
        .task(id: instance?.id) { await consumeUpdates() }
    }

    @ViewBuilder
    private func consoleView(_ cfg: InstrumentWidget.ConsoleConfig) -> some View {
        ConsoleWidgetView(
            entries: state.consoleEntries,
            config: cfg,
            onSubmit: { text in submitConsoleInput(text: text) }
        )
    }

    private func submitConsoleInput(text: String) {
        guard let instance else { return }
        let widgetID = widget.id
        let engine = engine
        Task { @MainActor in
            await engine.submitConsoleInput(instance: instance, widget: widgetID, text: text)
        }
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

    @ViewBuilder
    private func tableView(_ cfg: InstrumentWidget.TableConfig) -> some View {
        if cfg.columns.isEmpty {
            Text("No columns defined.").font(.caption).foregroundStyle(.secondary)
        } else if state.tableRows.isEmpty {
            Text("No rows.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                tableHeader(cfg)
                Divider()
                ForEach(state.tableRows) { row in
                    tableRow(row: row, columns: cfg.columns, actions: cfg.actions)
                    Divider().opacity(0.3)
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    private func tableHeader(_ cfg: InstrumentWidget.TableConfig) -> some View {
        HStack(spacing: 8) {
            ForEach(cfg.columns) { col in
                Text(col.name)
                    .frame(maxWidth: .infinity, alignment: alignment(for: col.alignment))
                    .foregroundStyle(.secondary)
            }
            if !cfg.actions.isEmpty {
                Color.clear.frame(width: actionWidth(cfg.actions))
            }
        }
        .padding(.vertical, 4)
    }

    private func tableRow(row: WidgetTableRow, columns: [InstrumentWidget.Column], actions: [InstrumentWidget.Action]) -> some View {
        HStack(spacing: 8) {
            ForEach(columns) { col in
                Text(row.cells[col.id] ?? "")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment(for: col.alignment))
            }
            if !actions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(actions) { action in
                        Button(action.name) { invoke(action: action.id, item: row.id) }
                            .buttonStyle(.borderless)
                    }
                }
                .frame(width: actionWidth(actions), alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private func alignment(for value: InstrumentWidget.Column.Alignment) -> SwiftUI.Alignment {
        value == .leading ? .leading : .trailing
    }

    private func actionWidth(_ actions: [InstrumentWidget.Action]) -> CGFloat {
        CGFloat(actions.count) * 64
    }

    @ViewBuilder
    private func counterView(_ cfg: InstrumentWidget.CounterConfig) -> some View {
        if let value = state.counter {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatCounter(value.value))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                if let unit = value.unit ?? cfg.unit {
                    Text(unit).foregroundStyle(.secondary)
                }
                if let delta = value.delta {
                    Text(formatDelta(delta))
                        .font(.caption)
                        .foregroundStyle(delta >= 0 ? .green : .red)
                }
                Spacer()
            }
        } else {
            Text("No data.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func formatCounter(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int64(value))
        }
        return String(format: "%.2f", value)
    }

    private func formatDelta(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(formatCounter(delta))"
    }

    @ViewBuilder
    private func histogramView() -> some View {
        if state.histogram.isEmpty {
            Text("No data.").font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(state.histogram, id: \.label) { bucket in
                    BarMark(
                        x: .value("bucket", bucket.label),
                        y: .value("count", bucket.count)
                    )
                }
            }
            .frame(height: 180)
        }
    }

    @ViewBuilder
    private func hexView() -> some View {
        if let hex = state.hex {
            HexView(data: hex.bytes)
                .frame(maxHeight: 240)
        } else {
            Text("No data.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func invoke(action: String, item: String) {
        guard let instance else { return }
        let engine = engine
        Task { @MainActor in
            await engine.invokeWidgetAction(instance: instance, widget: widget.id, action: action, item: item)
        }
    }

    @MainActor
    private func consumeUpdates() async {
        guard let instance else { return }
        let widgetID = widget.id
        let instanceID = instance.id
        let engine = engine
        state = engine.widgetState(instanceID: instanceID, widget: widgetID)
        for await update in engine.widgetUpdates
        where update.instanceID == instanceID && update.widget == widgetID {
            state.apply(update.kind)
        }
    }
}

private struct ConsoleWidgetView: View {
    let entries: [WidgetConsoleEntry]
    let config: InstrumentWidget.ConsoleConfig
    let onSubmit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    private var promptGlyph: String { config.prompt ?? "›" }
    private var placeholder: String { config.placeholder ?? "" }
    private var runLabel: String { config.runButtonLabel ?? "Run" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if entries.isEmpty {
                            Text("No entries.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entries) { entry in
                            entryRow(entry)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .onChange(of: entries.count) { _, _ in
                    if let last = entries.last?.id {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Text(promptGlyph)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(submit)
                Button(runLabel, action: submit)
                    .disabled(!canSubmit)
            }
        }
    }

    private func entryRow(_ entry: WidgetConsoleEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch entry.kind {
            case .input:
                Text(promptGlyph)
                    .foregroundStyle(.secondary)
            case .output:
                Text(" ")
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text(entry.text)
                .foregroundStyle(entry.kind == .error ? Color.red : .primary)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSubmit(text)
    }
}
