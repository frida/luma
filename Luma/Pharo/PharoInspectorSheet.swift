import LumaCore
import SwiftUI
import SwiftyPharo

struct PharoInspectorSheet: View {
    let engine: Engine
    let first: @MainActor () async throws -> PharoObject
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(8)
            Divider()
            PharoInspectorPane(engine: engine, first: first, overviewName: nil, onCloseAll: onDone)
        }
        .frame(minWidth: 640, minHeight: 480)
        .errorAlertHost()
    }
}

struct PharoInspectorPane: View {
    let engine: Engine
    let first: @MainActor () async throws -> PharoObject
    let overviewName: String?
    let onCloseAll: () -> Void

    @State private var path = PharoColumnPath()
    @State private var failure: String?

    private let runtime = PharoRuntime.shared

    var body: some View {
        VStack(spacing: 0) {
            if let failure {
                PharoFailureView(message: failure)
            }
            if let overviewName, path.objects.count > 1 {
                PharoOverviewStrip(path: path, pageName: overviewName)
                Divider()
            }
            columns
        }
        .background(.pharoGutter)
        .pharoMaximizedPane(runtime: runtime, path: path, onCloseAll: onCloseAll)
        .environment(\.engine, engine)
        .task { await open() }
    }

    private var columns: some View {
        GeometryReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    pharoColumns(
                        runtime: runtime, path: path, width: pharoColumnWidth(fitting: scroller.size.width), onCloseAll: onCloseAll)
                }
                .frame(height: scroller.size.height - 2 * pharoColumnMargin)
                .coordinateSpace(.named(PharoColumnPath.coordinateSpace))
                .scrollTargetLayout()
            }
            .contentMargins(pharoColumnMargin, for: .scrollContent)
            .pharoColumnScrolling(path)
        }
    }

    private func open() async {
        do {
            try await runtime.startBundledImage(for: engine)
            path.startOver(at: try await first())
        } catch {
            failure = error.localizedDescription
        }
    }
}
