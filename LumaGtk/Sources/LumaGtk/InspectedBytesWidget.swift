import Foundation
import Gtk
import LumaCore

@MainActor
final class InspectedBytesWidget {
    let widget: Box

    private let bytes: JSInspectValue.Bytes
    private let engine: Engine
    private let sessionID: UUID
    private let stored: StoredValue?
    private let hexView: HexView
    private let liveRow: Box
    private let problemLabel: Label

    private var data: Data

    init(bytes: JSInspectValue.Bytes, engine: Engine, sessionID: UUID, stored: StoredValue?) {
        self.bytes = bytes
        self.engine = engine
        self.sessionID = sessionID
        self.stored = stored
        data = bytes.data

        hexView = HexView(bytes: bytes.data, baseAddress: bytes.address ?? 0)
        hexView.widget.hexpand = true
        let rows = max(1, (bytes.data.count + 15) / 16)
        hexView.widget.setSizeRequest(width: -1, height: min(220, rows * 18 + 20))

        let hintLabel = Label(str: HexView.editingHint)
        hintLabel.add(cssClass: "dim-label")
        hintLabel.add(cssClass: "caption")
        hintLabel.xalign = 0
        hintLabel.hexpand = true
        hintLabel.wrap = true

        let rereadButton = Button(iconName: "view-refresh-symbolic")
        rereadButton.add(cssClass: "flat")
        rereadButton.tooltipText = "Reread from memory"

        liveRow = Box(orientation: .horizontal, spacing: 8)
        liveRow.append(child: hintLabel)
        liveRow.append(child: rereadButton)

        problemLabel = Label(str: "")
        problemLabel.add(cssClass: "error")
        problemLabel.add(cssClass: "caption")
        problemLabel.xalign = 0
        problemLabel.wrap = true
        problemLabel.selectable = true
        problemLabel.visible = false

        widget = Box(orientation: .vertical, spacing: 4)
        widget.hexpand = true
        widget.halign = .start
        widget.append(child: hexView.widget)
        widget.append(child: liveRow)
        widget.append(child: problemLabel)

        let isLive = bytes.address != nil && stored != nil && engine.node(forSessionID: sessionID) != nil
        liveRow.visible = isLive
        hexView.onWrite = isLive ? { [weak self] offset, bytes in self?.write(bytes, atOffset: offset) } : nil
        rereadButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reread()
            }
        }
    }

    private func write(_ bytes: [UInt8], atOffset offset: Int) {
        guard let address = self.bytes.address, let stored else { return }
        attempt { [engine, sessionID] in
            try await engine.writeMemory(bytes, at: address &+ UInt64(offset), forSessionID: sessionID, updating: stored)
            return (bytes, offset)
        }
    }

    private func reread() {
        guard let stored else { return }
        attempt { [engine, sessionID, bytes] in
            let fresh = try await engine.rereadMemory(of: bytes, forSessionID: sessionID, updating: stored)
            return (fresh, 0)
        }
    }

    private func attempt(_ operation: @escaping () async throws -> (bytes: [UInt8], offset: Int)) {
        Task { @MainActor [weak self] in
            do {
                let (bytes, offset) = try await operation()
                self?.show(bytes, atOffset: offset)
                self?.showProblem(nil)
            } catch {
                self?.showProblem(error.localizedDescription)
            }
        }
    }

    private func show(_ written: [UInt8], atOffset offset: Int) {
        data.replaceSubrange(offset..<offset + written.count, with: written)
        hexView.setBytes(data, baseAddress: bytes.address ?? 0)
    }

    private func showProblem(_ text: String?) {
        problemLabel.setText(str: text ?? "")
        problemLabel.visible = text != nil
    }
}
