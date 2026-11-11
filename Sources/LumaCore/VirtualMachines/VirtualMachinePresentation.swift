import Foundation
import Observation

@Observable
@MainActor
public final class VirtualMachinePresentation {
    public private(set) var page: Page = .log
    public private(set) var hasUnseenAlarm = false

    @ObservationIgnored private var console: VirtualMachineConsole?
    @ObservationIgnored private var displayID: ObjectIdentifier?
    @ObservationIgnored private var screenActivity = ScreenActivity()
    @ObservationIgnored private var switchesToScreenOnceLive = true
    @ObservationIgnored private var seenAlarmLineNumber: Int?

    public enum Page: Sendable {
        case log
        case screen
    }

    public init() {}

    public func update(console: VirtualMachineConsole?, display: VirtualMachineDisplay?, isFailed: Bool) {
        if console !== self.console {
            follow(console)
        }
        if display?.identity != displayID {
            displayID = display?.identity
            screenActivity = ScreenActivity()
        }
        if let display {
            screenActivity.observe(display)
        }

        if display == nil || isFailed {
            show(.log)
        } else if switchesToScreenOnceLive, screenActivity.isLive {
            switchesToScreenOnceLive = false
            show(.screen)
        }
        refreshAlarm()
    }

    public func toggle() {
        switchesToScreenOnceLive = false
        show(page == .log ? .screen : .log)
        refreshAlarm()
    }

    private func follow(_ console: VirtualMachineConsole?) {
        self.console = console
        switchesToScreenOnceLive = true
        seenAlarmLineNumber = nil
        show(.log)
    }

    private func show(_ wanted: Page) {
        guard wanted != page else { return }
        page = wanted
    }

    private func refreshAlarm() {
        let lastAlarmLineNumber = console?.lastAlarmLineNumber
        if page == .log {
            seenAlarmLineNumber = lastAlarmLineNumber
        }
        let isUnseen = lastAlarmLineNumber != seenAlarmLineNumber
        guard isUnseen != hasUnseenAlarm else { return }
        hasUnseenAlarm = isUnseen
    }
}

@MainActor
private struct ScreenActivity {
    private(set) var isLive = false
    private var firstFingerprint: Int?
    private var checkedRevision: UInt64?

    mutating func observe(_ display: VirtualMachineDisplay) {
        guard case .frames(let source) = display else {
            isLive = true
            return
        }
        guard !isLive, source.revision != checkedRevision, let frame = source.frame else { return }
        checkedRevision = source.revision
        let fingerprint = frame.fingerprint
        if let firstFingerprint {
            isLive = fingerprint != firstFingerprint
        } else {
            firstFingerprint = fingerprint
        }
    }
}

extension VirtualMachineDisplay {
    fileprivate var identity: ObjectIdentifier {
        switch self {
        case .frames(let source):
            return ObjectIdentifier(source)
        case .hostedWindow(let source):
            return ObjectIdentifier(source)
        #if canImport(Virtualization)
        case .virtualizationGuest(let guest):
            return ObjectIdentifier(guest)
        #endif
        }
    }
}

extension VirtualMachineFrame {
    fileprivate var fingerprint: Int {
        withPixels { pixels in
            var hasher = Hasher()
            hasher.combine(width)
            hasher.combine(height)
            hasher.combine(bytes: pixels)
            return hasher.finalize()
        }
    }
}
