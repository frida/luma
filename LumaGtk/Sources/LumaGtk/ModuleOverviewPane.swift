import Foundation
import Gtk
import LumaCore

@MainActor
final class ModuleOverviewPane {
    enum Target {
        case symbols(ModuleSymbolCategory)
        case swiftTypes
    }

    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let module: LumaCore.ProcessModule
    private let onNavigate: @MainActor (Target) -> Void
    private let contentsBox: Box

    private var loadTask: Task<Void, Never>?

    init(
        engine: Engine,
        sessionID: UUID,
        module: LumaCore.ProcessModule,
        onNavigate: @escaping @MainActor (Target) -> Void
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.module = module
        self.onNavigate = onNavigate

        widget = Box(orientation: .vertical, spacing: 12)
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12

        let titleLabel = Label(str: module.name)
        titleLabel.halign = .start
        titleLabel.add(cssClass: "heading")

        contentsBox = Box(orientation: .vertical, spacing: 2)
        contentsBox.halign = .start

        widget.append(child: titleLabel)
        widget.append(child: makeFacts())
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: contentsBox)

        renderContents(outline: nil)
        load()
    }

    deinit {
        loadTask?.cancel()
    }

    private func makeFacts() -> Grid {
        let grid = Grid()
        grid.columnSpacing = 12
        grid.rowSpacing = 6
        let facts: [(String, String, Bool)] = [
            ("Path", module.path, false),
            ("Base", String(format: "0x%llx", module.base), true),
            ("Size", String(format: "0x%llx", module.size), true),
            ("Analysis", analysisTitle, false),
        ]
        for (row, (label, value, monospaced)) in facts.enumerated() {
            let key = Label(str: label)
            key.halign = .end
            key.add(cssClass: "dim-label")
            let valueLabel = Label(str: value)
            valueLabel.halign = .start
            valueLabel.selectable = true
            valueLabel.ellipsize = .middle
            if monospaced {
                valueLabel.add(cssClass: "monospace")
            }
            grid.attach(child: key, column: 0, row: row, width: 1, height: 1)
            grid.attach(child: valueLabel, column: 1, row: row, width: 1, height: 1)
        }
        return grid
    }

    private var analysisTitle: String {
        switch engine?.moduleAnalysisStatus(sessionID: sessionID, modulePath: module.path) {
        case .analyzing: return "Analyzing\u{2026}"
        case .analyzed: return "Analyzed"
        case .notAnalyzed, nil: return "Not analyzed"
        }
    }

    private func load() {
        guard let node = engine?.node(forSessionID: sessionID) else { return }
        let moduleName = module.name
        loadTask = Task { @MainActor [weak self] in
            let outline = try? await node.outlineModule(name: moduleName)
            guard let self, !Task.isCancelled else { return }
            self.renderContents(outline: outline)
        }
    }

    private func renderContents(outline: ModuleOutline?) {
        while let child = contentsBox.firstChild {
            contentsBox.remove(child: child)
        }
        for category in ModuleSymbolCategory.allCases {
            contentsBox.append(child: makeLink(category.title, count: outline?.counts[category], target: .symbols(category)))
        }
        switch outline?.swiftTypes {
        case .available(let types):
            contentsBox.append(child: makeLink("Swift Types", count: types.count, target: .swiftTypes))
        case .needsBridge:
            contentsBox.append(child: makeLink("Swift Types", count: nil, target: .swiftTypes))
        case .absent, nil:
            break
        }
    }

    private func makeLink(_ title: String, count: Int?, target: Target) -> Button {
        let button = Button(label: count.map { "\(title) (\($0))" } ?? title)
        button.add(cssClass: "flat")
        button.halign = .start
        let onNavigate = onNavigate
        button.onClicked { _ in
            MainActor.assumeIsolated { onNavigate(target) }
        }
        return button
    }
}
