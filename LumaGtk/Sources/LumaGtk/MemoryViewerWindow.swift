import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
final class MemoryViewerWindow {
    let widget: Box

    private weak var engine: Engine?
    private let sessionID: UUID
    private let address: UInt64

    private let spinner: Adw.Spinner
    private let statusLabel: Label
    private let lengthLabel: Label
    private let hexView: HexView

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

        spinner = Adw.Spinner()
        spinner.visible = false
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

        statusLabel = Label(str: "")
        statusLabel.add(cssClass: "dim-label")
        statusLabel.halign = .start
        statusLabel.visible = false
        widget.append(child: statusLabel)

        hexView = HexView(bytes: Data(), baseAddress: address)
        hexView.widget.setSizeRequest(width: 700, height: 440)
        widget.append(child: hexView.widget)

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

    private func setStatus(_ text: String?) {
        if let text {
            statusLabel.setText(str: text)
            statusLabel.visible = true
        } else {
            statusLabel.visible = false
        }
    }

    private func scheduleRefresh() {
        loadTask?.cancel()
        loadTask = Task { @MainActor in await self.performRefresh() }
    }

    private func performRefresh() async {
        guard let engine else {
            hexView.setBytes(Data(), baseAddress: address)
            setStatus("Engine unavailable.")
            return
        }
        guard let node = engine.node(forSessionID: sessionID) else {
            hexView.setBytes(Data(), baseAddress: address)
            setStatus("Process not attached.")
            return
        }

        spinner.visible = true
        defer {
            spinner.visible = false
        }

        do {
            let bytes = try await node.readRemoteMemory(at: address, count: length)
            if Task.isCancelled { return }
            setStatus(nil)
            hexView.setBytes(Data(bytes), baseAddress: address)
        } catch {
            if Task.isCancelled { return }
            hexView.setBytes(Data(), baseAddress: address)
            setStatus("<error: \(error)>")
        }
    }
}

@MainActor
extension MemoryViewerWindow {
    static func present(from anchor: Widget, engine: Engine, sessionID: UUID, address: UInt64) {
        let view = MemoryViewerWindow(engine: engine, sessionID: sessionID, address: address)

        let window = Adw.Window()
        window.title = String(format: "Memory 0x%llx", address)
        window.setDefaultSize(width: 760, height: 560)
        window.destroyWithParent = true

        if let rootPtr = anchor.root?.ptr {
            window.setTransientFor(parent: Gtk.WindowRef(raw: rootPtr))
        }

        let header = Adw.HeaderBar()

        let toolbarView = Adw.ToolbarView()
        toolbarView.addTopBar(widget: header)
        toolbarView.set(content: view.widget)
        window.set(content: toolbarView)

        Self.retain(view: view, window: window)

        installEscapeShortcut(on: window)
        window.present()
    }

    private static var retained: [ObjectIdentifier: MemoryViewerWindow] = [:]

    private static func retain(view: MemoryViewerWindow, window: Adw.Window) {
        let key = ObjectIdentifier(window)
        retained[key] = view
        let handler: (Gtk.WindowRef) -> Bool = { _ in
            MainActor.assumeIsolated {
                _ = retained.removeValue(forKey: key)
            }
            return false
        }
        window.onCloseRequest(handler: handler)
    }
}
