import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class MissionFindingsView {
    let widget: Box

    private weak var engine: Engine?
    private let missionID: UUID
    private let onAddNotebookEntry: (NotebookEntry) -> Void

    private let countLabel: Label
    private let bodyContainer: Box
    private let listScroll: ScrolledWindow
    private let listBox: Box
    private let placeholder: Label

    private var cardsByFindingID: [UUID: FindingCard] = [:]

    init(
        engine: Engine?,
        missionID: UUID,
        onAddNotebookEntry: @escaping (NotebookEntry) -> Void
    ) {
        self.engine = engine
        self.missionID = missionID
        self.onAddNotebookEntry = onAddNotebookEntry

        widget = Box(orientation: .vertical, spacing: 0)
        widget.hexpand = true
        widget.vexpand = true

        let header = Box(orientation: .horizontal, spacing: 8)
        header.marginStart = 16
        header.marginEnd = 16
        header.marginTop = 14
        header.marginBottom = 6

        let icon = Gtk.Image(iconName: "object-select-symbolic")
        icon.pixelSize = 16
        icon.add(cssClass: "success")
        header.append(child: icon)

        let title = Label(str: "Findings")
        title.halign = .start
        title.hexpand = true
        title.add(cssClass: "heading")
        header.append(child: title)

        countLabel = Label(str: "0")
        countLabel.add(cssClass: "dim-label")
        countLabel.add(cssClass: "caption")
        header.append(child: countLabel)
        widget.append(child: header)

        placeholder = Label(str: "None recorded yet.")
        placeholder.halign = .start
        placeholder.add(cssClass: "dim-label")
        placeholder.marginStart = 16
        placeholder.marginEnd = 16
        placeholder.marginBottom = 12

        listBox = Box(orientation: .vertical, spacing: 8)
        listBox.marginStart = 16
        listBox.marginEnd = 16
        listBox.marginBottom = 12
        listBox.hexpand = true

        listScroll = ScrolledWindow()
        listScroll.hexpand = true
        listScroll.vexpand = true
        listScroll.set(child: listBox)

        bodyContainer = Box(orientation: .vertical, spacing: 0)
        bodyContainer.hexpand = true
        bodyContainer.vexpand = true
        widget.append(child: bodyContainer)
    }

    func update(findings: [MissionFinding]) {
        countLabel.label = "\(findings.count)"

        var seen: Set<UUID> = []
        var lastWidget: Widget? = nil

        for finding in findings {
            seen.insert(finding.id)
            if let card = cardsByFindingID[finding.id] {
                card.update(finding: finding)
                lastWidget = card.widget
            } else {
                let card = FindingCard(
                    engine: engine,
                    finding: finding,
                    onAccept: { [weak self] id in
                        self?.engine?.acceptFinding(findingID: id)
                    },
                    onRefute: { [weak self] id in
                        self?.engine?.refuteFinding(findingID: id)
                    },
                    onAddToNotebook: { [weak self] finding in
                        self?.addToNotebook(finding: finding)
                    }
                )
                cardsByFindingID[finding.id] = card
                if let last = lastWidget {
                    listBox.insertChildAfter(child: card.widget, sibling: last)
                } else {
                    listBox.prepend(child: card.widget)
                }
                lastWidget = card.widget
            }
        }

        for (id, card) in cardsByFindingID where !seen.contains(id) {
            if card.widget.parent != nil { listBox.remove(child: card.widget) }
            cardsByFindingID.removeValue(forKey: id)
        }

        while let child = bodyContainer.firstChild {
            bodyContainer.remove(child: child)
        }
        if findings.isEmpty {
            bodyContainer.append(child: placeholder)
        } else {
            bodyContainer.append(child: listScroll)
        }
    }

    private func addToNotebook(finding: MissionFinding) {
        guard let engine else { return }
        let processName = finding.sessionID.flatMap { sid in
            engine.sessions.first(where: { $0.id == sid })?.processName
        }
        let entry = NotebookEntry(
            kind: .note,
            title: finding.title,
            details: finding.bodyMarkdown,
            sessionID: finding.sessionID,
            processName: processName
        )
        onAddNotebookEntry(entry)
    }
}

@MainActor
private final class FindingCard {
    let widget: Box

    private weak var engine: Engine?
    private let titleLabel: Label
    private let bodySlot: Box
    private let confidenceSlot: Box
    private let statusSlot: Box
    private let evidenceSection: Box
    private let evidenceList: Box
    private let evidenceCountLabel: Label
    private let actionsRow: Box
    private let acceptButton: Button
    private let refuteButton: Button
    private let addToNotebookButton: Button
    private let onAccept: (UUID) -> Void
    private let onRefute: (UUID) -> Void
    private let onAddToNotebook: (MissionFinding) -> Void
    private var currentFinding: MissionFinding

    init(
        engine: Engine?,
        finding: MissionFinding,
        onAccept: @escaping (UUID) -> Void,
        onRefute: @escaping (UUID) -> Void,
        onAddToNotebook: @escaping (MissionFinding) -> Void
    ) {
        self.engine = engine
        self.currentFinding = finding
        self.onAccept = onAccept
        self.onRefute = onRefute
        self.onAddToNotebook = onAddToNotebook

        widget = Box(orientation: .vertical, spacing: 6)
        widget.add(cssClass: "card")
        widget.add(cssClass: "luma-mission-finding-card")

        let inner = Box(orientation: .vertical, spacing: 8)
        inner.marginStart = 12
        inner.marginEnd = 12
        inner.marginTop = 10
        inner.marginBottom = 10
        widget.append(child: inner)

        let header = Box(orientation: .horizontal, spacing: 8)
        titleLabel = Label(str: "")
        titleLabel.halign = .start
        titleLabel.hexpand = true
        titleLabel.add(cssClass: "heading")
        titleLabel.wrap = true
        titleLabel.xalign = 0
        header.append(child: titleLabel)

        confidenceSlot = Box(orientation: .horizontal, spacing: 0)
        header.append(child: confidenceSlot)
        inner.append(child: header)

        bodySlot = Box(orientation: .vertical, spacing: 0)
        bodySlot.halign = .fill
        bodySlot.add(cssClass: "caption")
        inner.append(child: bodySlot)

        evidenceList = Box(orientation: .vertical, spacing: 4)
        evidenceCountLabel = Label(str: "0 evidence")
        evidenceSection =
            MissionFindingsView.evidenceDisclosure(
                titleLabel: evidenceCountLabel,
                child: evidenceList
            )
        evidenceSection.visible = false
        inner.append(child: evidenceSection)

        actionsRow = Box(orientation: .horizontal, spacing: 6)
        statusSlot = Box(orientation: .horizontal, spacing: 0)
        actionsRow.append(child: statusSlot)
        let spacer = Label(str: "")
        spacer.hexpand = true
        actionsRow.append(child: spacer)
        addToNotebookButton = Button()
        addToNotebookButton.add(cssClass: "flat")
        let addContent = Box(orientation: .horizontal, spacing: 4)
        let addIcon = Gtk.Image(iconName: "document-edit-symbolic")
        addIcon.pixelSize = 14
        addContent.append(child: addIcon)
        let addLabel = Label(str: "Add to Notebook")
        addContent.append(child: addLabel)
        addToNotebookButton.set(child: addContent)
        addToNotebookButton.visible = false
        actionsRow.append(child: addToNotebookButton)

        refuteButton = Button(label: "Refute")
        refuteButton.add(cssClass: "flat")
        refuteButton.visible = false
        actionsRow.append(child: refuteButton)
        acceptButton = Button(label: "Accept")
        acceptButton.add(cssClass: "suggested-action")
        acceptButton.visible = false
        actionsRow.append(child: acceptButton)
        inner.append(child: actionsRow)

        addToNotebookButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onAddToNotebook(self.currentFinding)
            }
        }
        acceptButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onAccept(self.currentFinding.id)
            }
        }
        refuteButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onRefute(self.currentFinding.id)
            }
        }

        update(finding: finding)
    }

    func update(finding: MissionFinding) {
        currentFinding = finding
        titleLabel.label = finding.title
        replaceContents(of: bodySlot, with: MarkdownWidget.make(markdown: finding.bodyMarkdown))

        replaceContents(of: confidenceSlot, with: MissionPill.makeConfidence(finding.confidence))
        replaceContents(of: statusSlot, with: MissionPill.makeFindingStatus(finding.status))

        switch finding.status {
        case .proposed:
            acceptButton.visible = true
            refuteButton.visible = true
            addToNotebookButton.visible = false
        case .accepted:
            acceptButton.visible = false
            refuteButton.visible = false
            addToNotebookButton.visible = true
        case .refuted, .superseded:
            acceptButton.visible = false
            refuteButton.visible = false
            addToNotebookButton.visible = false
        }

        loadEvidence(findingID: finding.id)
    }

    private func loadEvidence(findingID: UUID) {
        guard let engine else { return }
        let store = engine.store
        Task { @MainActor in
            let evidence = (try? store.fetchMissionEvidence(findingID: findingID)) ?? []
            self.applyEvidence(evidence)
        }
    }

    private func applyEvidence(_ evidence: [MissionEvidence]) {
        while let child = evidenceList.firstChild {
            evidenceList.remove(child: child)
        }
        if evidence.isEmpty {
            evidenceSection.visible = false
            return
        }
        evidenceSection.visible = true
        evidenceCountLabel.label = "\(evidence.count) evidence"
        for ev in evidence {
            let row = Box(orientation: .horizontal, spacing: 6)
            let icon = Gtk.Image(iconName: iconName(for: ev.kind))
            icon.pixelSize = 12
            icon.add(cssClass: "accent")
            row.append(child: icon)
            let label = Label(str: ev.refJSON)
            label.halign = .fill
            label.xalign = 0
            label.wrap = true
            label.selectable = true
            label.add(cssClass: "monospace")
            label.add(cssClass: "caption")
            row.append(child: label)
            evidenceList.append(child: row)
        }
    }

    private func iconName(for kind: MissionEvidenceKind) -> String {
        switch kind {
        case .event: return "network-wireless-symbolic"
        case .hookHit: return "applications-engineering-symbolic"
        case .disasmSpan: return "view-list-symbolic"
        case .memoryRead: return "drive-harddisk-symbolic"
        case .symbolMatch: return "applications-development-symbolic"
        case .insight: return "edit-find-symbolic"
        case .action: return "applications-utilities-symbolic"
        }
    }

    private func replaceContents(of slot: Box, with widget: Widget) {
        while let child = slot.firstChild {
            slot.remove(child: child)
        }
        slot.append(child: widget)
    }
}

extension MissionFindingsView {
    fileprivate static func evidenceDisclosure(titleLabel: Label, child: Widget) -> Box {
        let outer = Box(orientation: .vertical, spacing: 0)
        let expander = Expander(label: "")
        let titleBox = Box(orientation: .horizontal, spacing: 4)
        let icon = Gtk.Image(iconName: "view-list-symbolic")
        icon.pixelSize = 12
        titleBox.append(child: icon)
        titleLabel.add(cssClass: "caption")
        titleLabel.halign = .start
        titleBox.append(child: titleLabel)
        expander.set(labelWidget: titleBox)
        let bodyBox = Box(orientation: .vertical, spacing: 4)
        bodyBox.marginStart = 6
        bodyBox.marginTop = 4
        bodyBox.marginBottom = 4
        bodyBox.append(child: child)
        expander.set(child: bodyBox)
        outer.append(child: expander)
        return outer
    }
}
