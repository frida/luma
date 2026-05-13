import Combine
import LumaCore
import SwiftUI

struct DetailView: View {
    let engine: Engine
    @Binding var selection: SidebarItemID?

    var body: some View {
        Group {
            switch selection {
            case .none:
                NotebookEmptyStateView(
                    engine: engine,
                    onAddNote: {
                        let note = LumaCore.NotebookEntry(
                            kind: .note,
                            title: "",
                            details: "",
                            binaryData: nil,
                            processName: nil
                        )
                        engine.addNotebookEntry(note, after: nil)
                        selection = .notebook
                    }
                )

            case .some(.notebook):
                NotebookView(engine: engine, selection: $selection)

            case .some(.missions):
                MissionsListView(engine: engine, selection: $selection)

            case .some(.mission(let missionID)):
                MissionView(engine: engine, missionID: missionID, selection: $selection)
                    .id(missionID)

            case .some(.session(let sessionID)):
                if engine.sessions.contains(where: { $0.id == sessionID }) {
                    SessionContent(sessionID: sessionID, engine: engine) {
                        SessionDetailView(sessionID: sessionID, engine: engine, selection: $selection)
                    }
                    .id(sessionID)
                }

            case .some(.repl(let sessionID)):
                if let session = engine.sessions.first(where: { $0.id == sessionID }) {
                    SessionContent(sessionID: sessionID, engine: engine) {
                        REPLView(sessionID: sessionID, engine: engine, selection: $selection)
                    }
                    .id(session.id)
                }

            case .some(.instrument(let sessionID, let instID)),
                .some(.instrumentComponent(let sessionID, let instID, _)):
                if (try? engine.store.fetchInstrument(id: instID)) != nil {
                    SessionContent(sessionID: sessionID, engine: engine) {
                        InstrumentDetailView(
                            instanceID: instID,
                            sessionID: sessionID,
                            engine: engine,
                            selection: $selection
                        )
                    }
                    .id(instID)
                }

            case .some(.itrace(let sessionID, let traceID)):
                let session = engine.sessions.first(where: { $0.id == sessionID })
                if let session,
                    let trace = (try? engine.store.fetchITraces(sessionID: sessionID))?.first(where: { $0.id == traceID })
                {
                    SessionContent(sessionID: sessionID, engine: engine) {
                        ITraceDetailView(
                            trace: trace, session: session, engine: engine, selection: $selection)
                    }
                    .id(trace.id)
                }

            case .some(.insight(let sessionID, let insightID)):
                let session = engine.sessions.first(where: { $0.id == sessionID })
                if let session,
                    let insight = (try? engine.store.fetchInsights(sessionID: sessionID))?.first(where: { $0.id == insightID })
                {
                    SessionContent(sessionID: sessionID, engine: engine) {
                        AddressInsightDetailView(
                            session: session, insight: insight, engine: engine, selection: $selection)
                    }
                    .id(insight.id)
                }

            case .some(.customInstrumentDef(let defID)):
                CustomInstrumentEditorView(defID: defID, path: nil, engine: engine)
                    .id(defID)

            case .some(.customInstrumentFile(let defID, let path)):
                CustomInstrumentEditorView(defID: defID, path: path, engine: engine)
                    .id(defID)

            case .some(.package(let packageID)):
                if let package = engine.installedPackages.first(where: { $0.id == packageID }) {
                    PackageDetailView(package: package, engine: engine, selection: $selection)
                        .id(package.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
