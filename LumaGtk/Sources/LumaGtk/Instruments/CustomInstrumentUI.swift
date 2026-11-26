import Foundation
import Gtk
import LumaCore
import Observation

extension Notification.Name {
    static let lumaSelectCustomInstrumentDef = Notification.Name("LumaGtk.SelectCustomInstrumentDef")
}

@MainActor
final class CustomUIKind: InstrumentUIKind {
    private var childRows: [UUID: InstrumentChildRows] = [:]

    func makeDetailUI(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> InstrumentDetailUI {
        CustomDetailUI(engine: engine, instrument: instrument)
    }

    func makeSidebarChildren(
        engine: Engine,
        instrument: LumaCore.InstrumentInstance,
        host: InstrumentUIHost
    ) -> [InstrumentSidebarChild] {
        if let rows = childRows[instrument.id], rows.isCurrent {
            return rows.children
        }
        let rows = InstrumentChildRows(engine: engine, instrument: instrument, host: host)
        childRows[instrument.id] = rows
        return rows.children
    }

    func hasSidebarChildren(instrument: LumaCore.InstrumentInstance, engine: Engine) -> Bool {
        !engine.shownChildren(of: instrument.id).isEmpty
    }
}

@MainActor
enum InstrumentChildComponents {
    private static var ids: [UUID: [ChildRef: UUID]] = [:]
    private static var refs: [UUID: ChildRef] = [:]

    static func id(of ref: ChildRef, in instanceID: UUID) -> UUID {
        if let id = ids[instanceID]?[ref] {
            return id
        }
        let id = UUID()
        ids[instanceID, default: [:]][ref] = id
        refs[id] = ref
        return id
    }

    static func ref(of componentID: UUID) -> ChildRef? {
        refs[componentID]
    }
}

@MainActor
private final class InstrumentChildRows {
    private(set) var children: [InstrumentSidebarChild] = []

    private weak var engine: Engine?
    private weak var host: InstrumentUIHost?
    private let sessionID: UUID
    private let instanceID: UUID
    private let defID: UUID?
    private let templates: [InstrumentChildTemplate]
    private var shape: [String] = []
    private var presenters: [ChildRef: InstrumentChildLine] = [:]

    private static let shownPerTemplate = 20

    init(engine: Engine, instrument: LumaCore.InstrumentInstance, host: InstrumentUIHost) {
        self.engine = engine
        self.host = host
        sessionID = instrument.sessionID
        instanceID = instrument.id
        defID = (try? CustomInstrumentConfig.decode(from: instrument.configJSON))?.defID
        templates = defID.flatMap { engine.customInstruments.def(withId: $0)?.children } ?? []
        let current = observe()
        shape = Self.shape(of: current, templates: templates, selected: selectedRef)
        children = makeRows(current)
    }

    var isCurrent: Bool {
        guard let engine, defID.flatMap({ engine.customInstruments.def(withId: $0)?.children }) ?? [] == templates else { return false }
        return Self.shape(of: engine.shownChildren(of: instanceID), templates: templates, selected: selectedRef) == shape
    }

    private var selectedRef: ChildRef? {
        host?.selectedComponentID(sessionID: sessionID, instrumentID: instanceID).flatMap(InstrumentChildComponents.ref(of:))
    }

    private func observe() -> [InstrumentChild] {
        guard let engine else { return [] }
        let instanceID = instanceID
        return withObservationTracking {
            engine.shownChildren(of: instanceID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func follow() {
        let current = observe()
        guard Self.shape(of: current, templates: templates, selected: selectedRef) == shape else {
            host?.reconcileSidebarChildren(sessionID: sessionID, instrumentID: instanceID)
            return
        }
        for child in current {
            presenters[child.ref]?.show(child)
        }
    }

    private func makeRows(_ current: [InstrumentChild]) -> [InstrumentSidebarChild] {
        var rows: [InstrumentSidebarChild] = []
        for template in templates {
            let all = Self.children(of: template, in: current)
            guard !all.isEmpty else { continue }
            if templates.count > 1 {
                rows.append(makeGroupRow(template))
            }
            for child in Self.shown(all, selected: selectedRef) {
                rows.append(makeChildRow(child, template: template))
            }
            if all.count > Self.shownPerTemplate {
                rows.append(makeShowAllRow(all, template: template))
            }
        }
        return rows
    }

    private func makeGroupRow(_ template: InstrumentChildTemplate) -> InstrumentSidebarChild {
        let label = Label(str: template.name)
        label.add(cssClass: "caption-heading")
        label.add(cssClass: "dim-label")
        label.halign = .start
        let (row, _) = SidebarFeatureRow.make(icon: Box(orientation: .horizontal, spacing: 0), content: label)
        row.selectable = false
        row.activatable = false
        return InstrumentSidebarChild(key: "group/\(template.id)", componentID: nil, row: row, onActivate: {})
    }

    private func makeChildRow(_ child: InstrumentChild, template: InstrumentChildTemplate) -> InstrumentSidebarChild {
        let line = InstrumentChildLine(child, arrangement: .subtitleBelow)
        line.widget.hexpand = true
        presenters[child.ref] = line
        let icon = InstrumentIconView.makeImage(for: .symbolic(template.symbol ?? ""), pixelSize: 14)
        let (row, anchor) = SidebarFeatureRow.make(icon: icon, content: line.widget)
        anchor.halign = .fill
        let componentID = InstrumentChildComponents.id(of: child.ref, in: instanceID)
        let sessionID = sessionID
        let instanceID = instanceID
        return InstrumentSidebarChild(
            key: "\(child.ref.template)/\(child.ref.id)", componentID: componentID, row: row,
            onActivate: { [weak host] in
                host?.navigateToInstrumentComponent(sessionID: sessionID, instrumentID: instanceID, componentID: componentID)
            })
    }

    private func makeShowAllRow(_ all: [InstrumentChild], template: InstrumentChildTemplate) -> InstrumentSidebarChild {
        let icon = Gtk.Image(iconName: "view-more-symbolic")
        icon.pixelSize = 12
        icon.hexpand = true
        icon.halign = .center
        icon.add(cssClass: "dim-label")
        let title = Label(str: "Show all \(all.count) \(template.name)")
        title.add(cssClass: "dim-label")
        title.halign = .start
        title.ellipsize = .end
        let (row, anchor) = SidebarFeatureRow.make(icon: icon, content: title)
        row.selectable = false
        let sessionID = sessionID
        let instanceID = instanceID
        return InstrumentSidebarChild(
            key: "browse/\(template.id)", componentID: nil, row: row,
            onActivate: { [weak host, anchor] in
                let browser = SidebarBrowserPopover(
                    items: all,
                    placeholder: "Filter \(template.name)",
                    emptyMessage: "No matching \(template.name)",
                    groupName: { _ in template.name },
                    title: { $0.title },
                    tooltip: { $0.subtitle },
                    matches: { child, query in
                        child.title.localizedCaseInsensitiveContains(query) || (child.subtitle ?? "").localizedCaseInsensitiveContains(query)
                    },
                    onChoose: { child in
                        host?.navigateToInstrumentComponent(
                            sessionID: sessionID, instrumentID: instanceID,
                            componentID: InstrumentChildComponents.id(of: child.ref, in: instanceID))
                    })
                browser.presentAnchored(to: anchor)
            })
    }

    private static func shape(of current: [InstrumentChild], templates: [InstrumentChildTemplate], selected: ChildRef?) -> [String] {
        templates.flatMap { template -> [String] in
            let all = children(of: template, in: current)
            return shown(all, selected: selected).map { "\($0.ref.template)/\($0.ref.id)" } + ["\(template.id):\(all.count)"]
        }
    }

    private static func children(of template: InstrumentChildTemplate, in current: [InstrumentChild]) -> [InstrumentChild] {
        current.filter { $0.ref.template == template.id }.sorted { $0.position < $1.position }
    }

    private static func shown(_ all: [InstrumentChild], selected: ChildRef?) -> [InstrumentChild] {
        let recent = Array(all.suffix(shownPerTemplate))
        guard let selected, !recent.contains(where: { $0.ref == selected }), let kept = all.first(where: { $0.ref == selected }) else {
            return recent
        }
        return (recent + [kept]).sorted { $0.position < $1.position }
    }
}

@MainActor
final class InstrumentChildLine {
    let widget: Box
    private let title = Label(str: "")
    private let subtitle = Label(str: "")
    private let badge = Label(str: "")
    private var tone: ChildBadge.Tone?

    enum Arrangement {
        case oneLine
        case subtitleBelow
    }

    convenience init(_ child: InstrumentChild, titleStyle: String? = nil, arrangement: Arrangement) {
        self.init(titleStyle: titleStyle, arrangement: arrangement)
        show(child)
    }

    init(titleStyle: String?, arrangement: Arrangement) {
        let stacked = arrangement == .subtitleBelow
        widget = Box(orientation: stacked ? .vertical : .horizontal, spacing: stacked ? 0 : 6)
        title.ellipsize = stacked ? .middle : .end
        title.halign = .start
        title.xalign = 0
        if let titleStyle {
            title.add(cssClass: titleStyle)
        }
        subtitle.add(cssClass: "dim-label")
        subtitle.ellipsize = .end
        subtitle.halign = .start
        subtitle.xalign = 0
        subtitle.hexpand = stacked
        badge.add(cssClass: "caption")
        badge.add(cssClass: "luma-mission-pill")
        badge.valign = .center
        if stacked {
            subtitle.add(cssClass: "caption")
            badge.ellipsize = .end
            badge.halign = .end
            widget.append(child: title)
            widget.append(child: badge)
            widget.append(child: subtitle)
            ChildRowLineLayout.install(on: widget)
        } else {
            widget.append(child: title)
            widget.append(child: subtitle)
            widget.append(child: badge)
        }
    }

    func show(_ child: InstrumentChild) {
        show(title: child.title, subtitle: child.subtitle, badge: child.badge.map { badge -> (text: String, tone: ChildBadge.Tone) in (badge.text, badge.tone) })
    }

    func show(title text: String, subtitle detail: String?, badge marker: (text: String, tone: ChildBadge.Tone)?) {
        title.label = text
        subtitle.label = detail ?? ""
        subtitle.visible = detail != nil
        badge.label = marker?.text ?? ""
        badge.visible = marker != nil
        badge.tooltipText = marker?.text
        widget.setAccessibleLabel([text, marker?.text, detail].compactMap { $0 }.joined(separator: ", "))
        if let old = tone.flatMap(Self.styleClass) {
            badge.remove(cssClass: old)
        }
        tone = marker?.tone
        if let new = tone.flatMap(Self.styleClass) {
            badge.add(cssClass: new)
        }
    }

    private static func styleClass(_ tone: ChildBadge.Tone) -> String? {
        switch tone {
        case .neutral: return nil
        case .active: return "success"
        case .waiting: return "warning"
        case .ended: return "dim-label"
        case .failed: return "error"
        }
    }
}

@MainActor
private final class CustomDetailUI: InstrumentDetailUI {
    let widget: Widget

    private weak var engine: Engine?
    private var instrument: LumaCore.InstrumentInstance
    private let outer: Box
    private var settingRows: [InstrumentSettingRow] = []
    private var widgetRenderer: InstrumentWidgetsRenderer?
    private var approvalPrompt: InstrumentApprovalPrompt?
    private var shownChild: ChildRef?
    private var childLine: InstrumentChildLine?
    private let updateBanner: StoreUpdateBanner?

    init(engine: Engine, instrument: LumaCore.InstrumentInstance) {
        self.engine = engine
        self.instrument = instrument

        let outer = Box(orientation: .vertical, spacing: 0)
        outer.hexpand = true
        outer.vexpand = true
        self.outer = outer

        let column = Box(orientation: .vertical, spacing: 0)
        updateBanner = UUID(uuidString: instrument.sourceIdentifier).map { StoreUpdateBanner(storefront: engine.storefront, defID: $0) }
        if let updateBanner {
            column.append(child: updateBanner.widget)
        }
        column.append(child: outer)
        widget = column

        rebuild()
    }

    func update(_ instrument: LumaCore.InstrumentInstance) {
        guard instrument.configJSON != self.instrument.configJSON else { return }
        self.instrument = instrument
        rebuild()
        applySessionState()
    }

    func applySessionState() {
        widgetRenderer?.refreshAgentState()
    }

    func selectComponent(id: UUID) {
        show(child: InstrumentChildComponents.ref(of: id))
    }

    func showConfigurationView() {
        show(child: nil)
    }

    private func show(child: ChildRef?) {
        guard child != shownChild else { return }
        shownChild = child
        rebuild()
    }

    private func rebuild() {
        while let child = outer.firstChild {
            outer.remove(child: child)
        }
        widgetRenderer = nil
        approvalPrompt = nil
        childLine = nil
        settingRows.removeAll()

        guard let engine,
            let config = try? CustomInstrumentConfig.decode(from: instrument.configJSON),
            let def = engine.customInstruments.def(withId: config.defID)
        else {
            let error = InstrumentUIHelpers.errorLabel("Custom instrument not found")
            error.marginStart = Int(Self.margin)
            error.marginTop = Int(Self.margin)
            outer.append(child: error)
            return
        }

        let renderer = makeRenderer(def: def, config: config, engine: engine)
        outer.append(child: renderer.widget)
        widgetRenderer = renderer
        let prompt = InstrumentApprovalPrompt(engine: engine, instanceID: instrument.id, icon: def.icon, name: def.name) {
            [weak renderer] wanted in
            renderer?.setCovered(wanted)
        }
        renderer.cover(with: prompt.widget)
        approvalPrompt = prompt
        renderer.refreshAgentState()
    }

    private func makeRenderer(def: CustomInstrumentDef, config: CustomInstrumentConfig, engine: Engine) -> InstrumentWidgetsRenderer {
        if let ref = shownChild, let template = def.children.first(where: { $0.id == ref.template }),
            let child = engine.children(of: instrument.id).first(where: { $0.ref == ref })
        {
            return InstrumentWidgetsRenderer(
                engine: engine, instance: instrument, child: child, widgets: template.widgets, layout: template.pageLayout,
                above: [makeChildHeader(child, template: template, engine: engine)], margin: Self.margin)
        }
        return InstrumentWidgetsRenderer(
            engine: engine, instance: instrument, child: nil, widgets: def.widgets, layout: def.pageLayout,
            above: [makeHeader(def: def, config: config)], margin: Self.margin)
    }

    private func makeChildHeader(_ child: InstrumentChild, template: InstrumentChildTemplate, engine: Engine) -> Box {
        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: InstrumentIconView.makeImage(for: .symbolic(template.symbol ?? ""), pixelSize: 16))
        let line = InstrumentChildLine(child, titleStyle: "heading", arrangement: .oneLine)
        line.widget.valign = .center
        header.append(child: line.widget)
        childLine = line
        followChild(child.ref, engine: engine)
        return header
    }

    private func followChild(_ ref: ChildRef, engine: Engine) {
        let instanceID = instrument.id
        let child = withObservationTracking {
            engine.children(of: instanceID).first { $0.ref == ref }
        } onChange: { [weak self, weak engine] in
            Task { @MainActor in
                guard let self, let engine, self.shownChild == ref else { return }
                self.followChild(ref, engine: engine)
            }
        }
        if let child {
            childLine?.show(child)
        }
    }

    private func makeHeader(def: CustomInstrumentDef, config: CustomInstrumentConfig) -> Box {
        let header = Box(orientation: .horizontal, spacing: 8)
        header.append(child: InstrumentIconView.makeImage(for: def.icon, pixelSize: 16))
        let title = Label(str: def.name)
        title.add(cssClass: "heading")
        title.halign = .start
        header.append(child: title)
        if !def.settings.isEmpty {
            header.append(child: makeSettingsPill(def: def, config: config))
        }
        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        header.append(child: spacer)
        let editButton = Button(label: "Edit Source\u{2026}")
        let defID = def.id
        editButton.onClicked { _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(
                    name: .lumaSelectCustomInstrumentDef,
                    object: nil,
                    userInfo: ["defID": defID.uuidString]
                )
            }
        }
        header.append(child: editButton)
        return header
    }

    private func makeSettingsPill(def: CustomInstrumentDef, config: CustomInstrumentConfig) -> MenuButton {
        let card = InstrumentSettingRow.makeCard(settings: def.settings, config: config, keeping: &settingRows) { [weak self] id, state in
            self?.mutate { $0.settings[id] = state }
        }
        let scroll = ScrolledWindow()
        scroll.setPolicy(hscrollbarPolicy: .never, vscrollbarPolicy: .automatic)
        scroll.propagateNaturalHeight = true
        scroll.maxContentHeight = Self.settingsMaxHeight
        scroll.setSizeRequest(width: Self.settingsWidth, height: -1)
        scroll.set(child: card)
        let popover = Popover()
        popover.set(child: scroll)

        let label = Label(str: "Settings")
        label.add(cssClass: "caption")
        let pill = MenuButton()
        pill.set(child: label)
        pill.firstChild?.add(cssClass: "luma-itrace-pill")
        pill.valign = .center
        pill.tooltipText = "\(def.name) settings"
        pill.set(popover: popover)
        return pill
    }

    private static let settingsWidth = 400
    private static let settingsMaxHeight = 500
    private static let margin: Int32 = 8

    private func mutate(_ body: (inout CustomInstrumentConfig) -> Void) {
        guard var cfg = try? CustomInstrumentConfig.decode(from: instrument.configJSON) else { return }
        body(&cfg)
        apply(configJSON: cfg.encode())
    }

    private func apply(configJSON: Data) {
        instrument.configJSON = configJSON
        guard let engine else { return }
        let snapshot = instrument
        Task { @MainActor in
            await engine.applyInstrumentConfig(snapshot, configJSON: configJSON)
        }
    }
}
