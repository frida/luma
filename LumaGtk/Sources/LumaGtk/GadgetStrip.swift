import Gtk
import LumaCore
import Observation
import Pango

@MainActor
final class GadgetStrip {
    let widget: Box

    private let engine: Engine
    private var flavor: GadgetFlavor?
    private let statusLabel: Label
    private let offer: Stack
    private let noOffer: Box
    private let progressBar: ProgressBar
    private let downloadButton: Button

    init(engine: Engine) {
        self.engine = engine

        widget = Box(orientation: .vertical, spacing: 0)
        statusLabel = Label(str: "")
        offer = Stack()
        noOffer = Box(orientation: .horizontal, spacing: 0)
        progressBar = ProgressBar()
        downloadButton = Button(label: "")

        statusLabel.halign = .start
        statusLabel.hexpand = true
        statusLabel.xalign = 0
        statusLabel.ellipsize = EllipsizeMode.end
        statusLabel.add(cssClass: "caption")
        progressBar.valign = .center
        progressBar.setSizeRequest(width: 120, height: -1)
        downloadButton.halign = .end
        downloadButton.add(cssClass: "luma-gadget-offer")
        _ = offer.add(child: noOffer)
        _ = offer.add(child: progressBar)
        _ = offer.add(child: downloadButton)

        let explanation = Label(
            str: "Without frida-server running on this device, Luma loads Gadget into the target, which must be debuggable.")
        explanation.halign = .start
        explanation.xalign = 0
        explanation.wrap = true
        explanation.naturalWrapMode = NaturalWrapMode.none
        explanation.add(cssClass: "caption")
        explanation.add(cssClass: "dim-label")

        let status = Box(orientation: .horizontal, spacing: 8)
        status.append(child: statusLabel)
        status.append(child: offer)

        let content = Box(orientation: .vertical, spacing: 0)
        content.marginStart = 12
        content.marginEnd = 12
        content.marginTop = 4
        content.marginBottom = 8
        content.append(child: status)
        content.append(child: explanation)
        widget.append(child: Separator(orientation: .horizontal))
        widget.append(child: content)
        widget.visible = false

        downloadButton.onClicked { [weak self] _ in
            MainActor.assumeIsolated { self?.downloadLatest() }
        }

        observeLibrary()
    }

    func show(_ flavor: GadgetFlavor?) {
        self.flavor = flavor
        widget.visible = flavor != nil
        refresh()
    }

    private func observeLibrary() {
        withObservationTracking {
            _ = engine.gadgets.states
            _ = engine.gadgets.installedVersions
            _ = engine.fridaReleases.releases
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observeLibrary()
            }
        }
    }

    private func refresh() {
        guard let flavor else { return }
        let state = engine.gadgets.state(for: flavor)
        statusLabel.label = detail(of: flavor, in: state).map { "Frida Gadget \u{00b7} \($0)" } ?? "Frida Gadget"
        refreshOffer(of: flavor, in: state)
    }

    private func detail(of flavor: GadgetFlavor, in state: FridaBinaryState) -> String? {
        switch state {
        case .missing:
            return "Not downloaded yet"
        case .downloading(let fraction):
            return fraction.map { "Downloading\u{2026} \(Int($0 * 100))%" } ?? "Downloading\u{2026}"
        case .ready:
            return engine.gadgets.installedVersion(for: flavor)?.displayName
        case .failed(let reason):
            return reason
        }
    }

    private func refreshOffer(of flavor: GadgetFlavor, in state: FridaBinaryState) {
        let gadgets = engine.gadgets
        switch state {
        case .missing, .failed:
            offerDownload(gadgets.latestVersion(for: flavor).map { "Download \($0)" } ?? "Download")
        case .downloading(let fraction):
            showProgress(fraction)
        case .ready:
            if case .available(let version) = gadgets.update(for: flavor) {
                offerDownload("Update to \(version)")
            } else {
                offer.setVisible(child: noOffer)
            }
        }
    }

    private func offerDownload(_ label: String) {
        downloadButton.label = label
        offer.setVisible(child: downloadButton)
    }

    private func showProgress(_ fraction: Double?) {
        if let fraction {
            progressBar.fraction = fraction
        } else {
            progressBar.pulse()
        }
        offer.setVisible(child: progressBar)
    }

    private func downloadLatest() {
        guard let flavor else { return }
        let gadgets = engine.gadgets
        Task { @MainActor in _ = try? await gadgets.downloadLatest(flavor) }
    }
}
