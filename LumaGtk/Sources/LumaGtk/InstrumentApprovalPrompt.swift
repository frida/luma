import Foundation
import Gtk
import LumaCore
import Observation

@MainActor
final class InstrumentApprovalPrompt {
    let widget: Box

    private weak var engine: Engine?
    private let instanceID: UUID
    private let request = Label(str: "")
    private let provenance = Label(str: "")
    private let note = Label(str: "")
    private let allow = Button(label: HostCodeOrigin.allowLabel)
    private let onWanted: (_ wanted: Bool) -> Void

    init(engine: Engine, instanceID: UUID, icon: InstrumentIcon, name: String, onWanted: @escaping (_ wanted: Bool) -> Void) {
        self.engine = engine
        self.instanceID = instanceID
        self.onWanted = onWanted

        widget = Box(orientation: .vertical, spacing: 0)
        widget.add(cssClass: "luma-approval-scrim")
        widget.hexpand = true
        widget.vexpand = true

        let card = Box(orientation: .vertical, spacing: 10)
        card.add(cssClass: "card")
        card.add(cssClass: "luma-approval-card")
        card.halign = .center
        card.valign = .center
        card.vexpand = true

        let image = InstrumentIconView.makeImage(for: icon, pixelSize: 32)
        image.halign = .center
        card.append(child: image)

        let nameLabel = Self.paragraph(name)
        nameLabel.add(cssClass: "heading")
        card.append(child: nameLabel)
        Self.shape(request)
        card.append(child: request)
        provenance.add(cssClass: "dim-label")
        Self.shape(provenance)
        card.append(child: provenance)
        note.add(cssClass: "dim-label")
        Self.shape(note)
        card.append(child: note)

        allow.add(cssClass: "suggested-action")
        allow.halign = .center
        allow.onClicked { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine?.instrumentViews.allow(instance: self.instanceID)
            }
        }
        card.append(child: allow)
        widget.append(child: card)

        widget.onMap { [weak self] _ in
            Task { @MainActor in self?.focusAllow() }
        }
        observe()
    }

    private static let maxWidthChars = 44

    private func observe() {
        guard let engine else { return }
        let instanceID = instanceID
        let gate = withObservationTracking {
            engine.gate(ofInstance: instanceID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        switch gate {
        case .none:
            break
        case .awaitingHost:
            request.label = gate.hostCardLine ?? ""
            provenance.visible = false
            note.label = Engine.InstrumentGate.hostGateNote
            allow.visible = false
        case .awaitingYou(let origin):
            request.label = HostCodeOrigin.request
            provenance.label = origin.provenance
            provenance.visible = true
            note.label = HostCodeOrigin.gateNote
            allow.visible = true
        }
        widget.visible = gate != .none
        onWanted(gate != .none)
        focusAllow()
    }

    private func focusAllow() {
        guard widget.visible, widget.mapped, allow.visible else { return }
        _ = allow.grabFocus()
    }

    private static func paragraph(_ text: String) -> Label {
        let label = Label(str: text)
        shape(label)
        return label
    }

    private static func shape(_ label: Label) {
        label.justify = .center
        label.wrap = true
        label.wrapMode = .wordChar
        label.maxWidthChars = maxWidthChars
    }
}
