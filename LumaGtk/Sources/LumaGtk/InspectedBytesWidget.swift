import Foundation
import Gtk
import LumaCore

@MainActor
final class InspectedBytesWidget {
    let widget: Box
    let rereadButton: Button

    private let bytes: JSInspectValue.Bytes
    private let engine: Engine
    private let sessionID: UUID
    private let stored: StoredValue?
    private let decodeView: PatternDecodeView
    private let problemLabel: Label

    private var data: Data

    init(bytes: JSInspectValue.Bytes, engine: Engine, sessionID: UUID, stored: StoredValue?) {
        self.bytes = bytes
        self.engine = engine
        self.sessionID = sessionID
        self.stored = stored
        data = bytes.data

        let home = bytes.address.flatMap { address in stored.map { (address: address, stored: $0) } }
        decodeView = PatternDecodeView(
            engine: engine, sessionID: sessionID, data: bytes.data, baseAddress: bytes.address,
            placements: home.map { engine.placements(at: $0.address, in: $0.stored) } ?? [], sizing: .capped
        ) { [weak engine] placements in
            guard let home else { return }
            engine?.setPlacements(placements, at: home.address, in: home.stored)
        }
        decodeView.widget.hexpand = true

        rereadButton = Button(iconName: "view-refresh-symbolic")
        rereadButton.add(cssClass: "flat")
        rereadButton.add(cssClass: "luma-pattern-chevron")
        rereadButton.tooltipText = "Reread from memory"
        rereadButton.valign = .center

        problemLabel = Label(str: "")
        problemLabel.add(cssClass: "error")
        problemLabel.add(cssClass: "caption")
        problemLabel.xalign = 0
        problemLabel.wrap = true
        problemLabel.selectable = true
        problemLabel.visible = false

        widget = Box(orientation: .vertical, spacing: 4)
        widget.hexpand = true
        widget.append(child: decodeView.widget)
        widget.append(child: problemLabel)

        let isLive = bytes.address != nil && stored != nil && engine.node(forSessionID: sessionID) != nil
        rereadButton.visible = isLive
        if isLive {
            decodeView.memoryWriter = { [weak self] written, address in try await self?.write(written, at: address) }
        }
        rereadButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reread()
            }
        }
    }

    private func write(_ written: [UInt8], at address: UInt64) async throws {
        guard let stored else { return }
        try await engine.writeMemory(written, at: address, forSessionID: sessionID, updating: stored)
        show(written, at: address)
    }

    private func reread() {
        guard let stored, let address = bytes.address else { return }
        Task { @MainActor [weak self, engine, sessionID, bytes] in
            do {
                let fresh = try await engine.rereadMemory(of: bytes, forSessionID: sessionID, updating: stored)
                self?.show(fresh, at: address)
                self?.showProblem(nil)
            } catch {
                self?.showProblem(error.localizedDescription)
            }
        }
    }

    private func show(_ fresh: [UInt8], at address: UInt64) {
        guard let base = bytes.address else { return }
        let offset = Int(address &- base)
        data.replaceSubrange(offset..<offset + fresh.count, with: fresh)
        decodeView.setData(data, baseAddress: base)
    }

    private func showProblem(_ text: String?) {
        problemLabel.setText(str: text ?? "")
        problemLabel.visible = text != nil
    }
}
