import LumaCore
import SwiftUI

struct ModuleOverviewView: View {
    let sessionID: UUID
    let module: LumaCore.ProcessModule
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var outline: ModuleOutline?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(module.name)
                .font(.headline)
            facts
            Divider()
            contents
            Spacer()
        }
        .detailPaneInset(.horizontal)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: module.id) {
            outline = try? await engine.node(forSessionID: sessionID)?.outlineModule(name: module.name)
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            factRow("Path", module.path)
            factRow("Base", String(format: "0x%llx", module.base), monospaced: true)
            factRow("Size", String(format: "0x%llx", module.size), monospaced: true)
            factRow("Analysis", analysisTitle)
        }
    }

    private func factRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    private var analysisTitle: String {
        switch engine.moduleAnalysisStatus(sessionID: sessionID, modulePath: module.path) {
        case .notAnalyzed: return "Not analyzed"
        case .analyzing: return "Analyzing\u{2026}"
        case .analyzed: return "Analyzed"
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ModuleSymbolCategory.allCases, id: \.self) { category in
                contentLink(
                    category.title,
                    systemImage: category.symbolName,
                    count: outline?.counts[category],
                    target: .moduleSymbols(sessionID, module.id, category)
                )
            }
            switch outline?.swiftTypes {
            case .available(let types):
                contentLink("Swift Types", systemImage: "swift", count: types.count, target: .swiftTypes(sessionID, module.id))
            case .needsBridge:
                contentLink("Swift Types", systemImage: "swift", count: nil, target: .swiftTypes(sessionID, module.id))
            case .absent, nil:
                EmptyView()
            }
        }
    }

    private func contentLink(_ title: String, systemImage: String, count: Int?, target: SidebarItemID) -> some View {
        Button {
            selection = target
        } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                if let count {
                    Text("\(count)").foregroundStyle(.secondary)
                }
            }
        }
        .platformLinkButtonStyle()
    }
}
