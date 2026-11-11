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

    private var log: VirtualMachineLog?
    private var screen: VirtualMachineScreen?
    private var shownSourceID: ObjectIdentifier?
    private var screenActivity = VirtualMachineScreenActivity()
    private var page: Page = .log
    private var switchesToScreenOnceLive = true
    private var seenAlarmLineNumber: Int?

    private enum Page: String {
        case log
        case screen
    }

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
        _ = widget.addNamed(child: logHost, name: Page.log.rawValue)
        _ = widget.addNamed(child: screenHost, name: Page.screen.rawValue)

        pageButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePage() }
        }

        refresh()
        startRefreshing()
    }

    private func togglePage() {
        switchesToScreenOnceLive = false
        show(page == .log ? .screen : .log)
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
        show(.log)
        switchesToScreenOnceLive = true
        seenAlarmLineNumber = nil
    }

    private func refreshScreen() {
        let source = frameSource
        let sourceID = source.map { ObjectIdentifier($0) }
        if sourceID != shownSourceID {
            showScreen(of: source)
        }
        if let source {
            screenActivity.observe(source)
        }
    }

    private func showScreen(of source: (any VirtualMachineFrameSource)?) {
        shownSourceID = source.map { ObjectIdentifier($0) }
        screenActivity = VirtualMachineScreenActivity()
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
        if screen == nil || machine?.state.isFailed == true {
            show(.log)
        } else if switchesToScreenOnceLive, screenActivity.isLive {
            switchesToScreenOnceLive = false
            show(.screen)
        }

        widget.visible = !isHidden && (log != nil || screen != nil)
        pageToggle.visible = screen != nil
        pageButton.iconName = (page == .log) ? "video-display-symbolic" : "utilities-terminal-symbolic"
        pageButton.tooltipText = (page == .log) ? "Show Screen" : "Show Log"

        let lastAlarmLineNumber = log?.console.lastAlarmLineNumber
        if page == .log {
            seenAlarmLineNumber = lastAlarmLineNumber
        }
        alarmDot.visible = lastAlarmLineNumber != seenAlarmLineNumber
    }

    private func show(_ wanted: Page) {
        guard wanted != page else { return }
        page = wanted
        widget.setVisibleChild(name: page.rawValue)
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
}
