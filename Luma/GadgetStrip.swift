import LumaCore
import SwiftUI

struct GadgetStrip: View {
    let gadgets: GadgetLibrary
    let flavor: GadgetFlavor

    private static let explanation =
        "Without frida-server running on this device, Luma loads Gadget into the target, which must be debuggable."

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(summary)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(summary)

                Spacer()

                ZStack(alignment: .trailing) {
                    downloadButton("Download")
                        .hidden()

                    offer
                }
            }

            Text(Self.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityIdentifier("targetPicker.gadget")
    }

    private var summary: String {
        guard let detail else { return "Frida Gadget" }
        return "Frida Gadget · \(detail)"
    }

    private var detail: String? {
        switch gadgets.state(for: flavor) {
        case .missing:
            return "Not downloaded yet"
        case .downloading(let fraction):
            return downloadingLabel(fraction)
        case .ready:
            return gadgets.installedVersion(for: flavor)?.displayName
        case .failed(let reason):
            return reason
        }
    }

    private func downloadingLabel(_ fraction: Double?) -> String {
        guard let fraction else { return "Downloading…" }
        return "Downloading… \(Int(fraction * 100))%"
    }

    @ViewBuilder
    private var offer: some View {
        switch gadgets.state(for: flavor) {
        case .missing, .failed:
            downloadButton(gadgets.latestVersion(for: flavor).map { "Download \($0)" } ?? "Download")
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .frame(width: 120)
        case .ready:
            if case .available(let version) = gadgets.update(for: flavor) {
                downloadButton("Update to \(version)")
            }
        }
    }

    private func downloadButton(_ title: String) -> some View {
        Button(title) {
            Task { _ = try? await gadgets.downloadLatest(flavor) }
        }
        .controlSize(.small)
    }
}
