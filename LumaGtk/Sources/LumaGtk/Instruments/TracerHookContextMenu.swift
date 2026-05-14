import Adw
import Foundation
import Gtk
import LumaCore

@MainActor
enum TracerHookContextMenu {
    static func present(
        at anchor: Widget,
        x: Double,
        y: Double,
        hook: TracerConfig.Hook,
        engine: Engine,
        sessionID: UUID,
        instrumentID: UUID,
        host: InstrumentUIHost
    ) {
        var sections: [[ContextMenu.Item]] = []

        sections.append([
            .init(hook.state == .enabled ? "Disable Hook" : "Enable Hook") {
                toggleEnabled(hook: hook, engine: engine, sessionID: sessionID)
            }
        ])

        if hook.kind == .function {
            var itraceItems: [ContextMenu.Item] = []
            if hook.itraceArming != nil {
                itraceItems.append(.init("Stop Instruction Trace") {
                    applyITrace(arming: nil, hookID: hook.id, engine: engine, sessionID: sessionID)
                })
                itraceItems.append(.init("Edit Instruction Trace\u{2026}") {
                    presentITraceConfigPopover(
                        anchor: anchor,
                        hook: hook,
                        engine: engine,
                        sessionID: sessionID
                    )
                })
            } else {
                itraceItems.append(.init("Start Instruction Trace\u{2026}") {
                    presentITraceConfigPopover(
                        anchor: anchor,
                        hook: hook,
                        engine: engine,
                        sessionID: sessionID
                    )
                })
            }
            sections.append(itraceItems)
        }

        sections.append([
            .init("Delete Hook", destructive: true) {
                confirmDeleteHook(
                    anchor: anchor,
                    hook: hook,
                    engine: engine,
                    sessionID: sessionID,
                    instrumentID: instrumentID,
                    host: host
                )
            }
        ])

        ContextMenu.present(sections, at: anchor, x: x, y: y)
    }

    private static func toggleEnabled(
        hook: TracerConfig.Hook,
        engine: Engine,
        sessionID: UUID
    ) {
        let newState: TracerConfig.Hook.State = hook.state == .enabled ? .disabled : .enabled
        Task { @MainActor in
            await engine.updateTracerHook(sessionID: sessionID, hookID: hook.id) { hook in
                hook.state = newState
            }
        }
    }

    private static func applyITrace(
        arming: ITraceArming?,
        hookID: UUID,
        engine: Engine,
        sessionID: UUID
    ) {
        Task { @MainActor in
            await engine.updateTracerHook(sessionID: sessionID, hookID: hookID) { hook in
                hook.itraceArming = arming
            }
        }
    }

    private static func confirmDeleteHook(
        anchor: Widget,
        hook: TracerConfig.Hook,
        engine: Engine,
        sessionID: UUID,
        instrumentID: UUID,
        host: InstrumentUIHost
    ) {
        let dialog = Adw.AlertDialog(
            heading: "Delete \u{201C}\(hook.displayName)\u{201D}?",
            body: "This will remove the hook from the tracer."
        )
        dialog.addResponse(id: "cancel", label: "_Cancel")
        dialog.addResponse(id: "delete", label: "Delete Hook")
        dialog.setResponseAppearance(response: "delete", appearance: .destructive)
        dialog.setDefault(response: "cancel")
        dialog.setClose(response: "cancel")
        dialog.onResponse { _, responseID in
            MainActor.assumeIsolated {
                guard responseID == "delete" else { return }
                let isSelected = host.selectedComponentID(
                    sessionID: sessionID,
                    instrumentID: instrumentID
                ) == hook.id
                Task { @MainActor in
                    await engine.removeTracerHook(sessionID: sessionID, hookID: hook.id)
                    if isSelected {
                        host.navigateToInstrument(
                            sessionID: sessionID,
                            instrumentID: instrumentID
                        )
                    }
                }
            }
        }
        dialog.present(parent: WidgetRef(anchor))
    }

    private static func presentITraceConfigPopover(
        anchor: Widget,
        hook: TracerConfig.Hook,
        engine: Engine,
        sessionID: UUID
    ) {
        let popover = ITraceConfigPopover(
            hook: hook,
            captured: itraceCaptured(for: hook.id, sessionID: sessionID, engine: engine),
            onApply: { arming in
                applyITrace(arming: arming, hookID: hook.id, engine: engine, sessionID: sessionID)
            }
        )
        popover.present(anchor: anchor)
    }

    private static func itraceCaptured(for hookID: UUID, sessionID: UUID, engine: Engine) -> Int {
        let traces = engine.tracesBySession[sessionID] ?? []
        return traces.reduce(into: 0) { count, trace in
            if case .functionCall(let id, _) = trace.origin, id == hookID { count += 1 }
        }
    }
}

@MainActor
private final class ITraceConfigPopover {
    private static var active: ITraceConfigPopover?

    private let popover: Popover
    private let invocationsSpin: SpinButton
    private let bytesStepper: BytesStepper
    private let primaryButton: Button
    private let disableButton: Button
    private let isOn: Bool
    private let onApply: (ITraceArming?) -> Void

    init(hook: TracerConfig.Hook, captured: Int, onApply: @escaping (ITraceArming?) -> Void) {
        self.onApply = onApply
        isOn = hook.itraceArming != nil

        popover = Popover()
        popover.autohide = true
        popover.position = .right
        popover.onClosed { _ in
            MainActor.assumeIsolated {
                ITraceConfigPopover.active = nil
            }
        }

        invocationsSpin = SpinButton(range: 1, max: 100, step: 1)
        bytesStepper = BytesStepper(
            value: hook.itraceArming?.maxBytesPerInvocation ?? ITraceArming.defaultMaxBytesPerInvocation,
            lowerBound: 256 * 1024,
            upperBound: 64 * 1024 * 1024,
            step: 256 * 1024
        )
        invocationsSpin.value = Double(hook.itraceArming?.maxInvocations ?? ITraceArming.defaultMaxInvocations)

        disableButton = Button(label: "Disable")
        primaryButton = Button(label: isOn ? "Save caps" : "Enable")

        installLayout(captured: captured)
        wireSignals()
    }

    func present(anchor: Widget) {
        ITraceConfigPopover.active = self
        popover.set(parent: WidgetRef(anchor))
        popover.popup()
    }

    private func installLayout(captured: Int) {
        let body = Box(orientation: .vertical, spacing: 12)
        body.marginStart = 14
        body.marginEnd = 14
        body.marginTop = 12
        body.marginBottom = 12
        body.setSizeRequest(width: 280, height: -1)

        let title = Label(str: "Instruction trace")
        title.halign = .start
        title.add(cssClass: "heading")
        body.append(child: title)

        let hint = Label(str: "Capture every call up to the caps below.")
        hint.halign = .start
        hint.add(cssClass: "dim-label")
        hint.add(cssClass: "caption")
        hint.wrap = true
        hint.xalign = 0
        body.append(child: hint)

        let invocationsRow = Box(orientation: .horizontal, spacing: 8)
        let invocationsLabel = Label(str: "Max calls")
        invocationsLabel.halign = .start
        invocationsLabel.hexpand = true
        invocationsRow.append(child: invocationsLabel)
        invocationsSpin.halign = .end
        invocationsRow.append(child: invocationsSpin)
        body.append(child: invocationsRow)

        let bytesRow = Box(orientation: .horizontal, spacing: 8)
        let bytesLabel = Label(str: "Max per call")
        bytesLabel.halign = .start
        bytesLabel.hexpand = true
        bytesRow.append(child: bytesLabel)
        bytesStepper.widget.halign = .end
        bytesRow.append(child: bytesStepper.widget)
        body.append(child: bytesRow)

        if isOn {
            let capturedLabel = Label(str: "\(captured) of \(Int(invocationsSpin.value)) captured")
            capturedLabel.halign = .start
            capturedLabel.add(cssClass: "dim-label")
            capturedLabel.add(cssClass: "caption")
            body.append(child: capturedLabel)
        }

        let actions = Box(orientation: .horizontal, spacing: 6)
        disableButton.add(cssClass: "destructive-action")
        disableButton.add(cssClass: "flat")
        disableButton.visible = isOn
        actions.append(child: disableButton)
        let spacer = Label(str: "")
        spacer.hexpand = true
        actions.append(child: spacer)
        primaryButton.add(cssClass: "suggested-action")
        actions.append(child: primaryButton)
        body.append(child: actions)

        popover.set(child: body)
    }

    private func wireSignals() {
        primaryButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
        disableButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.disable() }
        }
    }

    private func commit() {
        let arming = ITraceArming(
            maxInvocations: Int(invocationsSpin.value),
            maxBytesPerInvocation: bytesStepper.value
        )
        onApply(arming)
        dismiss()
    }

    private func disable() {
        onApply(nil)
        dismiss()
    }

    private func dismiss() {
        popover.popdown()
        popover.unparent()
    }
}
