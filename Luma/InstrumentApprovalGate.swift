import LumaCore
import SwiftUI

extension View {
    func instrumentApprovalGate(instanceID: UUID?, icon: InstrumentIcon, name: String, engine: Engine) -> some View {
        modifier(InstrumentApprovalGate(instanceID: instanceID, icon: icon, name: name, engine: engine))
    }
}

private struct InstrumentApprovalGate: ViewModifier {
    let instanceID: UUID?
    let icon: InstrumentIcon
    let name: String
    let engine: Engine

    func body(content: Content) -> some View {
        let origin = instanceID.flatMap { engine.instrumentViews.approvalWanted(byInstance: $0) }
        content
            .disabled(origin != nil)
            .accessibilityHidden(origin != nil)
            .overlay {
                if let origin, let instanceID {
                    ZStack {
                        Color.black.opacity(0.35)
                        ApprovalPrompt(origin: origin, icon: icon, name: name) {
                            engine.instrumentViews.allow(instance: instanceID)
                        }
                    }
                }
            }
    }
}

private struct ApprovalPrompt: View {
    let origin: HostCodeOrigin
    let icon: InstrumentIcon
    let name: String
    let allow: () -> Void

    @FocusState private var isAllowFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            InstrumentIconView(icon: icon, pointSize: 32)
            Text(name)
                .font(.headline)
            Text(HostCodeOrigin.request)
            Text(origin.provenance)
                .foregroundStyle(.secondary)
            Text(HostCodeOrigin.gateNote)
                .foregroundStyle(.secondary)
            Button(HostCodeOrigin.allowLabel, action: allow)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .focused($isAllowFocused)
                .accessibilityIdentifier("instrument.view.allow")
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(maxWidth: 400)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) is waiting for permission")
        .onAppear { isAllowFocused = true }
    }
}
