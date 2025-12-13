import Combine
import SwiftData
import SwiftUI

struct DetailView: View {
    @ObservedObject var workspace: Workspace
    @Binding var selection: SidebarItemID?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            switch selection {
            case .none:
                NotebookEmptyStateView(workspace: workspace)

            case .some(.notebook):
                NotebookView(workspace: workspace, selection: $selection)

            case .some(.repl(let sessionID)):
                if let session = try? modelContext.fetch(FetchDescriptor<ProcessSession>(predicate: #Predicate { $0.id == sessionID }))
                    .first
                {
                    REPLView(session: session, workspace: workspace, selection: $selection)
                        .id(session.id)
                } else {
                    EmptyView()
                }

            case .some(.instrument(let sessionID, let instID)),
                .some(.instrumentComponent(let sessionID, let instID, _, _)):
                if let session = try? modelContext.fetch(FetchDescriptor<ProcessSession>(predicate: #Predicate { $0.id == sessionID }))
                    .first
                {
                    let inst = session.instruments.first(where: { $0.id == instID })!
                    InstrumentDetailView(instance: inst, workspace: workspace, selection: $selection)
                        .id(inst.id)
                } else {
                    EmptyView()
                }

            case .some(.insight(let sessionID, let insightID)):
                if let session =
                    try? modelContext
                    .fetch(FetchDescriptor<ProcessSession>(predicate: #Predicate { $0.id == sessionID }))
                    .first,
                    let insight = session.insights.first(where: { $0.id == insightID })
                {
                    AddressInsightDetailView(session: session, insight: insight, workspace: workspace, selection: $selection)
                        .id(insight.id)
                } else {
                    EmptyView()
                }

            case .some(.package(let packageID)):
                if let pkg =
                    try? modelContext
                    .fetch(FetchDescriptor<InstalledPackage>(predicate: #Predicate { $0.id == packageID }))
                    .first
                {
                    PackageDetailView(package: pkg, workspace: workspace, selection: $selection)
                } else {
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
