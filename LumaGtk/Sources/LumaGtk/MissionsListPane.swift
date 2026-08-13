import Adw
import Foundation
import Gtk
import LumaCore
import Pango

@MainActor
final class MissionsListPane {
    let widget: Box

    private weak var engine: Engine?
    private let onSelectMission: (UUID) -> Void
    private let onNewMission: () -> Void
    private let mcpCard: ExternalMCPCard
    private let listBox: ListBox
    private let listScroll: ScrolledWindow
    private let emptyState: Adw.StatusPage
    private let bodyContainer: Box
    private let newButton: Button
    private var rowsByMissionID: [UUID: ListBoxRow] = [:]
    private var orderedMissions: [Mission] = []

    init(
        engine: Engine,
        onSelectMission: @escaping (UUID) -> Void,
        onNewMission: @escaping () -> Void,
        onCopied: @escaping (String) -> Void
    ) {
        self.engine = engine
        self.onSelectMission = onSelectMission
        self.onNewMission = onNewMission
        self.mcpCard = ExternalMCPCard(engine: engine, onCopied: onCopied)

        widget = Box(orientation: .vertical, spacing: 0)
        listBox = ListBox()
        listScroll = ScrolledWindow()
        bodyContainer = Box(orientation: .vertical, spacing: 0)
        newButton = Button()
        emptyState = MainWindow.makeEmptyState(
            icon: "applications-engineering-symbolic",
            title: "No missions yet",
            subtitle: "Give the agent a goal to work on.",
            actionLabel: "New Mission",
            onAction: onNewMission
        )

        widget.hexpand = true
        widget.vexpand = true

        let header = Box(orientation: .horizontal, spacing: 12)
        header.marginStart = 24
        header.marginEnd = 24
        header.marginTop = 18
        header.marginBottom = 6

        let title = Label(str: "Missions")
        title.halign = .start
        title.hexpand = true
        title.add(cssClass: "title-2")
        header.append(child: title)

        newButton.add(cssClass: "suggested-action")
        newButton.add(cssClass: "luma-fab")
        let newButtonContent = Box(orientation: .horizontal, spacing: 6)
        let newButtonIcon = Gtk.Image(iconName: "list-add-symbolic")
        newButtonIcon.pixelSize = 14
        newButtonContent.append(child: newButtonIcon)
        let newButtonLabel = Label(str: "New Mission")
        newButtonContent.append(child: newButtonLabel)
        newButton.set(child: newButtonContent)
        newButton.tooltipText = "Start a new agentic mission"
        header.append(child: newButton)
        widget.append(child: header)

        let mcpHolder = Box(orientation: .vertical, spacing: 0)
        mcpHolder.marginStart = 24
        mcpHolder.marginEnd = 24
        mcpHolder.marginTop = 6
        mcpHolder.marginBottom = 12
        mcpHolder.append(child: mcpCard.widget)
        widget.append(child: mcpHolder)

        listBox.selectionMode = .none
        listBox.add(cssClass: "boxed-list")
        listScroll.hexpand = true
        listScroll.vexpand = true
        listScroll.set(child: listBox)
        listScroll.marginStart = 16
        listScroll.marginEnd = 16
        listScroll.marginTop = 6
        listScroll.marginBottom = 16

        bodyContainer.hexpand = true
        bodyContainer.vexpand = true
        widget.append(child: bodyContainer)

        newButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.onNewMission() }
        }

        listBox.onRowActivated { [weak self] _, row in
            MainActor.assumeIsolated {
                guard let self else { return }
                let index = Int(row.index)
                self.onSelectMission(self.orderedMissions[index].id)
            }
        }
    }

    func refreshExternalMCP() {
        mcpCard.refresh()
    }

    func updateMissions(_ missions: [Mission]) {
        let isEmpty = missions.isEmpty
        newButton.visible = !isEmpty
        replaceBody(empty: isEmpty)
        diffMissionRows(missions)
        orderedMissions = missions
    }

    private func diffMissionRows(_ missions: [Mission]) {
        let previousByID = Dictionary(uniqueKeysWithValues: orderedMissions.map { ($0.id, $0) })
        let nextIDs = Set(missions.map(\.id))

        for id in rowsByMissionID.keys where !nextIDs.contains(id) {
            if let row = rowsByMissionID.removeValue(forKey: id) {
                listBox.remove(child: row)
            }
        }

        let orderChanged = orderedMissions.map(\.id) != missions.map(\.id)
        if orderChanged {
            rebuildMissionRows(missions)
            return
        }

        for (index, mission) in missions.enumerated() {
            if let previous = previousByID[mission.id],
                previous.updatedAt == mission.updatedAt,
                rowsByMissionID[mission.id] != nil {
                continue
            }
            if let stale = rowsByMissionID[mission.id] {
                listBox.remove(child: stale)
            }
            let row = makeMissionRow(for: mission)
            rowsByMissionID[mission.id] = row
            listBox.insert(child: row, position: index)
        }
    }

    private func rebuildMissionRows(_ missions: [Mission]) {
        rowsByMissionID.removeAll()
        listBox.removeAll()
        for mission in missions {
            let row = makeMissionRow(for: mission)
            rowsByMissionID[mission.id] = row
            listBox.append(child: row)
        }
    }

    private func replaceBody(empty: Bool) {
        if listScroll.parent != nil {
            bodyContainer.remove(child: listScroll)
        }
        if emptyState.parent != nil {
            bodyContainer.remove(child: emptyState)
        }
        bodyContainer.append(child: empty ? emptyState : listScroll)
    }

    private func makeMissionRow(for mission: Mission) -> ListBoxRow {
        let row = ListBoxRow()
        row.set(activatable: true)
        let box = Box(orientation: .horizontal, spacing: 12)
        box.marginStart = 12
        box.marginEnd = 12
        box.marginTop = 10
        box.marginBottom = 10

        let avatarSeed = mission.title?.isEmpty == false ? mission.title! : mission.goalText
        let avatar = Adw.Avatar(size: 32, text: avatarSeed, showInitials: true)
        box.append(child: avatar)

        let column = Box(orientation: .vertical, spacing: 4)
        column.hexpand = true

        let titleLabel = Label(str: missionRowTitle(mission))
        titleLabel.halign = .start
        titleLabel.add(cssClass: "heading")
        titleLabel.maxWidthChars = 64
        titleLabel.ellipsize = EllipsizeMode.end
        titleLabel.xalign = 0
        column.append(child: titleLabel)

        if let title = mission.title, !title.isEmpty {
            let goalLine = Label(str: mission.goalText)
            goalLine.halign = .start
            goalLine.maxWidthChars = 80
            goalLine.ellipsize = EllipsizeMode.end
            goalLine.xalign = 0
            goalLine.add(cssClass: "dim-label")
            goalLine.add(cssClass: "caption")
            column.append(child: goalLine)
        }

        let metaRow = Box(orientation: .horizontal, spacing: 12)
        metaRow.append(child: makeMetaLabel(text: mission.providerID, icon: "computer-symbolic"))
        metaRow.append(child: makeMetaLabel(text: mission.modelID, icon: "applications-science-symbolic"))
        metaRow.append(child: makeMetaLabel(text: RelativeTime.string(from: mission.createdAt), icon: "alarm-symbolic"))
        column.append(child: metaRow)

        box.append(child: column)

        let pill = MissionPill.makeStatus(mission.status)
        pill.valign = .start
        box.append(child: pill)

        row.set(child: box)
        return row
    }

    private func missionRowTitle(_ mission: Mission) -> String {
        if let title = mission.title, !title.isEmpty {
            return title
        }
        let trimmed = mission.goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mission" : firstLine(of: trimmed, max: 80)
    }

    private func makeMetaLabel(text: String, icon: String) -> Box {
        let row = Box(orientation: .horizontal, spacing: 4)
        let iconImage = Gtk.Image(iconName: icon)
        iconImage.pixelSize = 12
        iconImage.add(cssClass: "dim-label")
        row.append(child: iconImage)
        let label = Label(str: text)
        label.halign = .start
        label.add(cssClass: "dim-label")
        label.add(cssClass: "caption")
        label.maxWidthChars = 32
        label.ellipsize = EllipsizeMode.end
        row.append(child: label)
        return row
    }

    private func firstLine(of text: String, max: Int) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        if firstLine.count <= max { return firstLine }
        return String(firstLine.prefix(max - 1)) + "…"
    }
}
