import Adw
import Foundation
import Gtk
import LumaCore
import Pango

@MainActor
final class MissionDetailPane {
    let widget: Box
    let missionID: UUID

    private weak var engine: Engine?
    private let onCopied: (String) -> Void
    private let onAddNotebookEntry: (NotebookEntry) -> Void
    private let parentWindow: Gtk.Window

    private let header: MissionHeaderBar
    private let transcript: MissionTranscriptView
    private let findings: MissionFindingsView
    private let inputBar: MissionInputBar

    private var observations: [StoreObservation] = []
    private var liveText: String = ""
    private var lastTurnCount: Int = 0
    private var currentMission: Mission

    init(
        engine: Engine,
        mission: Mission,
        parentWindow: Gtk.Window,
        onCopied: @escaping (String) -> Void,
        onAddNotebookEntry: @escaping (NotebookEntry) -> Void
    ) {
        self.engine = engine
        self.parentWindow = parentWindow
        self.missionID = mission.id
        self.currentMission = mission
        self.onCopied = onCopied
        self.onAddNotebookEntry = onAddNotebookEntry

        widget = Box(orientation: .vertical, spacing: 0)

        header = MissionHeaderBar(
            mission: mission,
            onStop: { [weak engine, missionID = mission.id] in
                engine?.cancelMission(missionID: missionID)
            }
        )
        transcript = MissionTranscriptView()
        findings = MissionFindingsView(
            engine: engine,
            missionID: mission.id,
            onAddNotebookEntry: onAddNotebookEntry
        )
        let missionRef = mission
        inputBar = MissionInputBar(
            engine: engine,
            missionID: mission.id,
            getStatus: { [weak engine, id = missionRef.id, fallback = missionRef.status] in
                guard let engine else { return fallback }
                let result = (try? engine.store.fetchMission(id: id)) ?? nil
                return result?.status ?? fallback
            }
        )

        widget.hexpand = true
        widget.vexpand = true
        widget.append(child: header.widget)
        widget.append(child: Separator(orientation: .horizontal))

        let split = Paned(orientation: .horizontal)
        split.hexpand = true
        split.vexpand = true
        split.position = 560
        split.resizeStartChild = true
        split.resizeEndChild = true
        split.shrinkStartChild = false
        split.shrinkEndChild = false
        split.startChild = WidgetRef(transcript.widget)
        split.endChild = WidgetRef(findings.widget)

        widget.append(child: split)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: inputBar.widget)
    }

    func start() {
        guard let engine else { return }
        observations = []
        liveText = engine.missionLiveText(missionID: missionID)
        transcript.setLiveText(liveText)

        let store = engine.store
        let id = missionID

        let initialTurns = (try? store.fetchMissionTurns(missionID: id)) ?? []
        let initialActions = (try? store.fetchMissionActions(missionID: id)) ?? []
        let initialFindings = (try? store.fetchMissionFindings(missionID: id)) ?? []

        lastTurnCount = initialTurns.count
        lastActionsCache = initialActions
        transcript.applyTurns(initialTurns, actions: initialActions)
        findings.update(findings: initialFindings)

        observations.append(
            store.observeMissionTurns(missionID: id) { [weak self] rows in
                Task { @MainActor in
                    guard let self else { return }
                    self.transcript.applyTurns(rows, actions: self.lastActionsCache)
                    if rows.count > self.lastTurnCount {
                        self.liveText = ""
                        self.transcript.setLiveText("")
                    }
                    self.lastTurnCount = rows.count
                }
            })
        observations.append(
            store.observeMissionActions(missionID: id) { [weak self] rows in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastActionsCache = rows
                    self.transcript.applyActions(rows)
                }
            })
        observations.append(
            store.observeMissionFindings(missionID: id) { [weak self] rows in
                Task { @MainActor in
                    self?.findings.update(findings: rows)
                }
            })

        engine.setMissionLiveDeltaSink { [weak self] eventMissionID, event in
            guard eventMissionID == id, let self else { return }
            switch event {
            case .textDelta(let text):
                self.liveText += text
                self.transcript.setLiveText(self.liveText)
            case .liveTextCleared:
                self.liveText = ""
                self.transcript.setLiveText("")
            default:
                break
            }
        }
    }

    func stop() {
        observations = []
        engine?.setMissionLiveDeltaSink(nil)
    }

    func updateMission(_ mission: Mission) {
        currentMission = mission
        header.update(mission: mission)
        inputBar.update(status: mission.status)
    }

    private var lastActionsCache: [MissionAction] = []
}

@MainActor
private final class MissionHeaderBar {
    let widget: Box

    fileprivate struct MetaCell {
        let widget: Box
        let label: Label
    }

    private let titleLabel: Label
    private let goalLabel: Label
    private let statusPillHolder: Box
    private let providerCell: MetaCell
    private let modelCell: MetaCell
    private let inputTokensCell: MetaCell
    private let outputTokensCell: MetaCell
    private let cacheTokensCell: MetaCell
    private let runningSpinner: Gtk.Spinner
    private let stopButton: Button
    private let onStop: () -> Void
    private var currentMission: Mission

    init(mission: Mission, onStop: @escaping () -> Void) {
        self.currentMission = mission
        self.onStop = onStop

        widget = Box(orientation: .horizontal, spacing: 12)
        widget.marginStart = 24
        widget.marginEnd = 24
        widget.marginTop = 16
        widget.marginBottom = 16

        let textColumn = Box(orientation: .vertical, spacing: 6)
        textColumn.hexpand = true

        titleLabel = Label(str: "")
        titleLabel.halign = .start
        titleLabel.add(cssClass: "title-3")
        titleLabel.ellipsize = EllipsizeMode.end
        titleLabel.xalign = 0
        textColumn.append(child: titleLabel)

        goalLabel = Label(str: "")
        goalLabel.halign = .start
        goalLabel.wrap = true
        goalLabel.xalign = 0
        goalLabel.selectable = true
        goalLabel.add(cssClass: "dim-label")
        goalLabel.maxWidthChars = 80
        textColumn.append(child: goalLabel)

        let metaRow = Box(orientation: .horizontal, spacing: 12)

        statusPillHolder = Box(orientation: .horizontal, spacing: 6)
        statusPillHolder.valign = .center
        runningSpinner = Gtk.Spinner()
        runningSpinner.spinning = true
        runningSpinner.visible = false
        statusPillHolder.append(child: runningSpinner)
        metaRow.append(child: statusPillHolder)

        providerCell = MissionHeaderBar.metaCell(icon: "computer-symbolic")
        modelCell = MissionHeaderBar.metaCell(icon: "applications-science-symbolic")
        inputTokensCell = MissionHeaderBar.metaCell(icon: "go-down-symbolic")
        outputTokensCell = MissionHeaderBar.metaCell(icon: "go-up-symbolic")
        cacheTokensCell = MissionHeaderBar.metaCell(icon: "object-select-symbolic")

        for cell in [providerCell, modelCell, inputTokensCell, outputTokensCell, cacheTokensCell] {
            metaRow.append(child: cell.widget)
        }

        textColumn.append(child: metaRow)
        widget.append(child: textColumn)

        stopButton = Button()
        let stopContent = Box(orientation: .horizontal, spacing: 6)
        let stopIcon = Gtk.Image(iconName: "process-stop-symbolic")
        stopIcon.pixelSize = 14
        stopContent.append(child: stopIcon)
        let stopLabel = Label(str: "Stop")
        stopContent.append(child: stopLabel)
        stopButton.set(child: stopContent)
        stopButton.add(cssClass: "destructive-action")
        stopButton.tooltipText =
            "Cancel this mission. Pending tool calls won't be approved or run."
        stopButton.valign = .start
        stopButton.onClicked { _ in
            MainActor.assumeIsolated { onStop() }
        }
        widget.append(child: stopButton)

        update(mission: mission)
    }

    func update(mission: Mission) {
        currentMission = mission
        let title = mission.title?.isEmpty == false ? mission.title! : nil
        if let title {
            titleLabel.label = title
            titleLabel.visible = true
            goalLabel.label = mission.goalText
            goalLabel.visible = !mission.goalText.isEmpty
        } else {
            titleLabel.label = mission.goalText
            titleLabel.visible = !mission.goalText.isEmpty
            goalLabel.visible = false
        }

        rebuildStatusPill(mission.status)

        applyMeta(providerCell, value: mission.providerID)
        applyMeta(modelCell, value: mission.modelID)
        applyMeta(inputTokensCell, value: "\(mission.tokensUsedInput)/\(mission.tokenBudgetInput) in")
        applyMeta(outputTokensCell, value: "\(mission.tokensUsedOutput)/\(mission.tokenBudgetOutput) out")
        if mission.cacheReadTokens > 0 {
            cacheTokensCell.widget.visible = true
            applyMeta(cacheTokensCell, value: "\(mission.cacheReadTokens) cached")
        } else {
            cacheTokensCell.widget.visible = false
        }

        stopButton.visible = mission.status.isLive
    }

    private func rebuildStatusPill(_ status: MissionStatus) {
        while let child = statusPillHolder.firstChild {
            statusPillHolder.remove(child: child)
        }
        if status == .running {
            runningSpinner.spinning = true
            runningSpinner.visible = true
            statusPillHolder.append(child: runningSpinner)
        } else {
            runningSpinner.spinning = false
            runningSpinner.visible = false
        }
        let pill = MissionPill.makeStatus(status)
        statusPillHolder.append(child: pill)
    }

    fileprivate static func metaCell(icon: String) -> MetaCell {
        let row = Box(orientation: .horizontal, spacing: 4)
        let iconImage = Gtk.Image(iconName: icon)
        iconImage.pixelSize = 12
        iconImage.add(cssClass: "dim-label")
        row.append(child: iconImage)
        let label = Label(str: "")
        label.halign = .start
        label.add(cssClass: "dim-label")
        label.add(cssClass: "caption")
        label.maxWidthChars = 28
        label.ellipsize = EllipsizeMode.end
        row.append(child: label)
        return MetaCell(widget: row, label: label)
    }

    private func applyMeta(_ cell: MetaCell, value: String) {
        cell.label.label = value
        cell.label.tooltipText = value
    }
}
