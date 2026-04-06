import Combine
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
                if let node = workspace.processNodes.first(where: { $0.sessionRecord.id == sessionID }) {
                    REPLView(session: node.sessionRecord, workspace: workspace, selection: $selection)
                        .id(node.sessionRecord.id)
                } else {
                    EmptyView()
                }

            case .some(.instrument(let sessionID, let instID)),
                .some(.instrumentComponent(let sessionID, let instID, _, _)):
                if let node = workspace.processNodes.first(where: { $0.sessionRecord.id == sessionID }) {
                    let inst = node.sessionRecord.instruments.first(where: { $0.id == instID })!
                    InstrumentDetailView(instance: inst, workspace: workspace, selection: $selection)
                        .id(inst.id)
                } else {
                    EmptyView()
                }

            case .some(.itraceCapture(let sessionID, let captureID)):
                if let node = workspace.processNodes.first(where: { $0.sessionRecord.id == sessionID }),
                    let capture = node.sessionRecord.itraceCaptures.first(where: { $0.id == captureID })
                {
                    ITraceDetailView(capture: capture, session: node.sessionRecord, workspace: workspace, selection: $selection)
                        .id(capture.id)
                } else {
                    EmptyView()
                }

            case .some(.insight(let sessionID, let insightID)):
                if let node = workspace.processNodes.first(where: { $0.sessionRecord.id == sessionID }),
                    let insight = node.sessionRecord.insights.first(where: { $0.id == insightID })
                {
                    AddressInsightDetailView(
                        session: node.sessionRecord, insight: insight, workspace: workspace, selection: $selection)
                        .id(insight.id)
                } else {
                    EmptyView()
                }

            case .some(.package(_)):
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
