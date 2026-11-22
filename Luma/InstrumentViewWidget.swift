import LumaCore
import SwiftUI
import SwiftyPharo

struct InstrumentViewWidget: View {
    let key: InstrumentViews.Key
    let config: InstrumentWidget.ViewConfig
    let engine: Engine

    @State private var declarations: [PharoViewDeclaration] = []
    @State private var shown: String?
    @State private var failure: String?
    @State private var inspected: InspectedObject?

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(config.height))
            .onAppear { views.show(key) }
            .onDisappear { views.hide(key) }
            .task(id: generation) { await load() }
            .sheet(item: $inspected) { inspector(of: $0.object) }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .checking, .starting:
            ProgressView()
        case .awaitingApproval(let origin):
            approval(origin)
        case .failed(let message):
            stopped(message)
        case .running(let generation):
            if let failure {
                stopped(failure)
            } else {
                running(generation)
            }
        }
    }

    private func approval(_ origin: HostCodeOrigin) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(HostCodeOrigin.request)
                .font(.headline)
            Text(origin.provenance)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(HostCodeOrigin.allowLabel) { views.allow(key) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("instrument.view.allow")
        }
        .padding()
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
                    onSelect: { inspected = InspectedObject(object: $0) })
            }
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

    private func inspector(of object: PharoObject) -> some View {
        PharoObjectColumn(
            runtime: PharoRuntime.shared,
            object: object,
            onSelect: { inspected = InspectedObject(object: $0) },
            onClose: { inspected = nil })
            .frame(minWidth: 420, minHeight: 360)
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

private struct InspectedObject: Identifiable {
    let object: PharoObject

    var id: Int {
        object.handle
    }
}
