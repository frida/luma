import Combine
import LumaCore
import SwiftUI

struct DetailView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    var body: some View {
        Group {
            switch selection {
            case .none:
                NotebookEmptyStateView(workspace: workspace)

            case .some(.notebook):
                NotebookView(workspace: workspace, selection: $selection)

            case .some(.repl(let sessionID)):
                if let session = workspace.engine.sessions.first(where: { $0.id == sessionID }) {
                    REPLView(sessionID: sessionID, workspace: workspace, selection: $selection)
                        .id(session.id)
                }

            case .some(.instrument(let sessionID, let instID)),
                .some(.instrumentComponent(let sessionID, let instID, _, _)):
                if let inst = (try? workspace.store.fetchInstruments(sessionID: sessionID))?.first(where: { $0.id == instID }) {
                    InstrumentDetailView(instance: inst, workspace: workspace, selection: $selection)
                        .id(inst.id)
                }

            case .some(.itraceCapture(let sessionID, let captureID)):
                let session = workspace.engine.sessions.first(where: { $0.id == sessionID })
                if let session,
                    let capture = (try? workspace.store.fetchITraceCaptures(sessionID: sessionID))?.first(where: { $0.id == captureID })
                {
                    ITraceDetailView(
                        capture: capture, session: session, workspace: workspace, selection: $selection)
                        .id(capture.id)
                }

            case .some(.insight(let sessionID, let insightID)):
                let session = workspace.engine.sessions.first(where: { $0.id == sessionID })
                if let session,
                    let insight = (try? workspace.store.fetchInsights(sessionID: sessionID))?.first(where: { $0.id == insightID })
                {
                    AddressInsightDetailView(
                        session: session, insight: insight, workspace: workspace, selection: $selection)
                        .id(insight.id)
                }

            case .some(.package(let packageID)):
                if let package = workspace.engine.installedPackages.first(where: { $0.id == packageID }) {
                    PackageDetailView(package: package, workspace: workspace, selection: $selection)
                        .id(package.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
