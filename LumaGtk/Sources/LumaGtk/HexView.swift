import Foundation
import Gtk
import LumaCore

@MainActor
final class HexView {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let address: UInt64

    private let spinner: Spinner
    private let bodyLabel: Label
    private let lengthLabel: Label

    private var length: Int = 256
    private var loadTask: Task<Void, Never>?

    private static let minLength: Int = 16
    private static let maxLength: Int = 16384
    private static let lengthStep: Int = 256

    init(engine: Engine, sessionID: UUID, address: UInt64) {
        self.engine = engine
        self.sessionID = sessionID
        self.address = address

        widget = Box(orientation: .vertical, spacing: 8)
        widget.marginStart = 12
        widget.marginEnd = 12
        widget.marginTop = 12
        widget.marginBottom = 12
        widget.hexpand = true
        widget.vexpand = true

        let headerRow = Box(orientation: .horizontal, spacing: 8)

        let addrLabel = Label(str: String(format: "0x%016llx", address))
        addrLabel.add(cssClass: "monospace")
        addrLabel.add(cssClass: "title-4")
        addrLabel.halign = .start
        addrLabel.selectable = true
        headerRow.append(child: addrLabel)

        spinner = Spinner()
        spinner.spinning = false
        headerRow.append(child: spinner)

        let spacer = Box(orientation: .horizontal, spacing: 0)
        spacer.hexpand = true
        headerRow.append(child: spacer)

        lengthLabel = Label(str: "\(length) B")
        lengthLabel.add(cssClass: "dim-label")
        headerRow.append(child: lengthLabel)

        let minusButton = Button(label: "\u{2212} 256")
        minusButton.add(cssClass: "flat")
        headerRow.append(child: minusButton)

        let plusButton = Button(label: "+ 256")
        plusButton.add(cssClass: "flat")
        headerRow.append(child: plusButton)

        let refreshButton = Button(label: "Refresh")
        refreshButton.add(cssClass: "flat")
        headerRow.append(child: refreshButton)

        widget.append(child: headerRow)
        widget.append(child: Separator(orientation: .horizontal))

        bodyLabel = Label(str: "")
        bodyLabel.add(cssClass: "monospace")
        bodyLabel.halign = .start
        bodyLabel.valign = .start
        bodyLabel.selectable = true
        bodyLabel.xalign = 0

        let scroll = ScrolledWindow()
        scroll.hexpand = true
        scroll.vexpand = true
        scroll.setSizeRequest(width: 700, height: 440)
        scroll.set(child: bodyLabel)
        widget.append(child: scroll)

        refreshButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        plusButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.adjustLength(by: Self.lengthStep) }
        }
        minusButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.adjustLength(by: -Self.lengthStep) }
        }

        scheduleRefresh()
    }

    private func adjustLength(by delta: Int) {
        let next = max(Self.minLength, min(Self.maxLength, length + delta))
        guard next != length else { return }
        length = next
        lengthLabel.setText(str: "\(length) B")
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        loadTask?.cancel()
        loadTask = Task { @MainActor in await self.performRefresh() }
    }

    private func performRefresh() async {
        guard let engine else {
            bodyLabel.setText(str: "Engine unavailable.")
            return
        }
        guard let node = engine.node(forSessionID: sessionID) else {
            bodyLabel.setText(str: "Process not attached.")
            return
        }

        spinner.spinning = true
        spinner.start()
        defer {
            spinner.spinning = false
            spinner.stop()
        }

        do {
            let bytes = try await node.readRemoteMemory(at: address, count: length)
            if Task.isCancelled { return }
            bodyLabel.setText(str: Self.formatHexdump(bytes: bytes, baseAddress: address))
        } catch {
            if Task.isCancelled { return }
            bodyLabel.setText(str: "<error: \(error)>")
        }
    }

    private static func formatHexdump(bytes: [UInt8], baseAddress: UInt64) -> String {
        if bytes.isEmpty {
            return "<no data>"
        }
        var out = ""
        var i = 0
        while i < bytes.count {
            let lineAddr = baseAddress &+ UInt64(i)
            out += String(format: "0x%016llx  ", lineAddr)

            var hexPart = ""
            var asciiPart = ""
            for col in 0..<16 {
                let idx = i + col
                if col == 8 {
                    hexPart += " "
                }
                if idx < bytes.count {
                    let b = bytes[idx]
                    hexPart += String(format: "%02x", b)
                    if (0x20...0x7e).contains(b) {
                        asciiPart.append(Character(UnicodeScalar(b)))
                    } else {
                        asciiPart.append(".")
                    }
                } else {
                    hexPart += "  "
                    asciiPart.append(" ")
                }
                if col != 15 {
                    hexPart += " "
                }
            }

            out += hexPart
            out += "  |"
            out += asciiPart
            out += "|\n"

            i += 16
        }
        return out
    }
}

@MainActor
extension HexView {
    static func present(from anchor: Widget, engine: Engine, sessionID: UUID, address: UInt64) {
        let view = HexView(engine: engine, sessionID: sessionID, address: address)

        let window = Window()
        window.title = String(format: "Memory 0x%llx", address)
        window.setDefaultSize(width: 720, height: 520)
        window.modal = false
        window.destroyWithParent = true

        if let rootPtr = anchor.root?.ptr {
            window.setTransientFor(parent: WindowRef(raw: rootPtr))
        }

        let header = HeaderBar()
        let closeButton = Button(label: "Close")
        closeButton.onClicked { [weak window] _ in
            MainActor.assumeIsolated { window?.destroy() }
        }
        header.packEnd(child: closeButton)
        window.set(titlebar: WidgetRef(header))

        window.set(child: WidgetRef(view.widget.widget_ptr))

        Self.retain(view: view, window: window)

        window.present()
    }

    private static var retained: [ObjectIdentifier: HexView] = [:]

    private static func retain(view: HexView, window: Window) {
        let key = ObjectIdentifier(window)
        retained[key] = view
        let handler: (WindowRef) -> Bool = { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
            return false
        }
        window.onCloseRequest(handler: handler)
    }
}
