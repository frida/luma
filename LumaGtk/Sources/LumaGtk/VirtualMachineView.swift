import Gtk
import LumaCore

@MainActor
final class VirtualMachineView {
    let widget: Stack
    let pageToggle: Overlay

    var isHidden = false {
        didSet { refresh() }
    }

    var onScreenAppeared: (() -> Void)?

    private weak var engine: Engine?
    private let record: VirtualMachineRecord
    private let sizing: VirtualMachineScreen.Sizing

    private let pageButton: Button
    private let alarmDot: Box
    private let logHost: Box
    private let screenHost: Box
    private let presentation = VirtualMachinePresentation()

    private var log: VirtualMachineLog?
    private var screen: VirtualMachineScreen?
    private var shownSourceID: ObjectIdentifier?
    private var shownPage: VirtualMachinePresentation.Page = .log

    init(engine: Engine, record: VirtualMachineRecord, sizing: VirtualMachineScreen.Sizing, fillsHeight: Bool) {
        self.engine = engine
        self.record = record
        self.sizing = sizing

        pageButton = Button()
        pageButton.add(cssClass: "flat")
        alarmDot = Box(orientation: .horizontal, spacing: 0)
        alarmDot.add(cssClass: "luma-alarm-dot")
        alarmDot.halign = .end
        alarmDot.valign = .start
        alarmDot.canTarget = false
        pageToggle = Overlay()
        pageToggle.set(child: pageButton)
        pageToggle.addOverlay(widget: alarmDot)

        logHost = Box(orientation: .vertical, spacing: 0)
        screenHost = Box(orientation: .vertical, spacing: 0)
        widget = Stack()
        widget.transitionType = .crossfade
        widget.vexpand = fillsHeight
        _ = widget.addNamed(child: logHost, name: Self.logPageName)
        _ = widget.addNamed(child: screenHost, name: Self.screenPageName)

        pageButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePage() }
        }

        refresh()
        startRefreshing()
    }

    private func togglePage() {
        presentation.toggle()
        refreshPage()
    }

    private func startRefreshing() {
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.refresh()
            }
        }
    }

    private func refresh() {
        refreshLog()
        refreshScreen()
        refreshPage()
    }

    private func refreshLog() {
        let console = engine?.virtualMachines.console(for: record)
        if console !== log?.console {
            showLog(of: console)
        }
        log?.catchUp()
    }

    private func showLog(of console: VirtualMachineConsole?) {
        if let log {
            logHost.remove(child: log.widget)
        }
        log = console.map(VirtualMachineLog.init)
        if let log {
            logHost.append(child: log.widget)
        }
    }

    private func refreshScreen() {
        let source = frameSource
        let sourceID = source.map { ObjectIdentifier($0) }
        if sourceID != shownSourceID {
            showScreen(of: source)
        }
    }

    private func showScreen(of source: (any VirtualMachineFrameSource)?) {
        shownSourceID = source.map { ObjectIdentifier($0) }
        if let screen {
            screenHost.remove(child: screen.widget)
        }
        screen = source.map { VirtualMachineScreen(source: $0, sizing: sizing) }
        if let screen {
            screenHost.append(child: screen.widget)
            onScreenAppeared?()
        }
    }

    private func refreshPage() {
        presentation.update(
            console: log?.console, display: machine?.display, isFailed: machine?.state.isFailed == true)
        show(presentation.page)

        widget.visible = !isHidden && (log != nil || screen != nil)
        pageToggle.visible = screen != nil
        pageButton.iconName = (shownPage == .log) ? "video-display-symbolic" : "utilities-terminal-symbolic"
        pageButton.tooltipText = (shownPage == .log) ? "Show Screen" : "Show Log"
        alarmDot.visible = presentation.hasUnseenAlarm
    }

    private func show(_ page: VirtualMachinePresentation.Page) {
        guard page != shownPage else { return }
        shownPage = page
        widget.setVisibleChild(name: page == .log ? Self.logPageName : Self.screenPageName)
        if page == .log {
            log?.scrollToBottom()
        }
    }

    private var frameSource: (any VirtualMachineFrameSource)? {
        guard case .frames(let source)? = machine?.display else { return nil }
        return source
    }

    private var machine: (any VirtualMachine)? {
        engine?.virtualMachines.machine(for: record)
    }

    private static let logPageName = "log"
    private static let screenPageName = "screen"
}
