import LumaCore
import SwiftUI
import SwiftyPharo

struct InstrumentViewWidget: View {
    let key: InstrumentViews.Key
    let name: String
    let engine: Engine

    @State private var declarations: [PharoViewDeclaration] = []
    @State private var shown: String?
    @State private var failure: String?
    @State private var columnPath = PharoColumnPath(includesPage: true)

    @Environment(\.instrumentInstance) private var instance

    var body: some View {
        VStack(spacing: 0) {
            if !columnPath.objects.isEmpty {
                PharoOverviewStrip(path: columnPath, pageName: name)
                Divider()
            }
            columns
        }
        .frame(maxWidth: .infinity)
        .pharoMaximizedPane(runtime: PharoRuntime.shared, path: columnPath, onCloseAll: columnPath.clear)
        .environment(\.engine, engine)
        .environment(\.pharoChatOrigin, chatOrigin)
        .onAppear { views.show(key) }
        .onDisappear { views.hide(key) }
        .task(id: generation) { await load() }
        .task { await inspectSpawned() }
    }

    private var chatOrigin: PharoChatOrigin? {
        instance.map {
            PharoChatOrigin(
                origin: .instrumentView(instanceID: key.instanceID, widget: key.widget, sessionID: $0.sessionID),
                label: "the \(name) view of an instrument",
                source: nil)
        }
    }

    private var columns: some View {
        GeometryReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    content
                        .frame(width: viewWidth(fitting: scroller.size.width))
                        .id(PharoColumnPath.pageID)
                    inspectionSide(fitting: scroller.size.width)
                }
                .frame(height: scroller.size.height - 2 * columnMargin)
                .scrollTargetLayout()
            }
            .contentMargins(columnMargin, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .pharoColumnScrolling(columnPath)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case _ where engine.gate(ofInstance: key.instanceID) != .none:
            Color.clear
        case .failed(let message):
            stopped(message)
        case .running(let generation):
            if let failure {
                stopped(failure)
            } else {
                running(generation)
            }
        default:
            ProgressView()
        }
    }

    private func stopped(_ message: String) -> some View {
        VStack(spacing: 8) {
            Label(InstrumentViews.stoppedTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            ScrollView {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(InstrumentViews.restartLabel) { views.restart(key) }
        }
        .padding()
    }

    private func running(_ generation: Int) -> some View {
        VStack(spacing: 0) {
            if declarations.count > 1 {
                PharoTabBar(tabs: declarations.map { ($0.methodSelector, $0.title) }, selection: $shown)
                Divider()
            }
            if let declaration = declarations.first(where: { $0.methodSelector == shown }) ?? declarations.first {
                PharoDeclaredView(
                    declaration: declaration,
                    source: InstrumentViewSource(instrumentViews: views, key: key),
                    reloadToken: generation,
                    onSelect: { columnPath.startOver(at: $0) })
            }
        }
    }

    private func viewWidth(fitting available: CGFloat) -> CGFloat {
        columnPath.objects.isEmpty ? available : pharoColumnWidth(fitting: available)
    }

    @ViewBuilder
    private func inspectionSide(fitting available: CGFloat) -> some View {
        if !columnPath.objects.isEmpty {
            if !columnPath.isFirstColumnCollapsed {
                PharoDrillArrow()
            }
            pharoColumns(
                runtime: PharoRuntime.shared,
                path: columnPath,
                width: pharoColumnWidth(fitting: available),
                onCloseAll: columnPath.clear)
        }
    }

    private func load() async {
        guard generation != nil else { return }
        do {
            declarations = try await views.declarations(of: key)
            failure = nil
            if !declarations.contains(where: { $0.methodSelector == shown }) {
                shown = declarations.first?.methodSelector
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func inspectSpawned() async {
        for await object in views.spawns(of: key) {
            columnPath.startOver(at: object)
        }
    }

    private var columnMargin: CGFloat {
        columnPath.objects.isEmpty ? 0 : pharoColumnMargin
    }

    private var generation: Int? {
        if case .running(let generation) = phase { generation } else { nil }
    }

    private var phase: InstrumentViews.Phase {
        views.phase(of: key)
    }

    private var views: InstrumentViews {
        engine.instrumentViews
    }
}
