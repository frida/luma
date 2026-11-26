import LumaCore
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
    import AppKit
#endif

extension View {
    func offeredFileSaving(engine: Engine) -> some View {
        modifier(OfferedFileSaving(engine: engine))
    }
}

private struct OfferedFileSaving: ViewModifier {
    let engine: Engine

    @State private var saving: OfferedFile?
    @State private var failure: UIError?
    #if os(iOS)
        @State private var folderOffer: OfferedFile?
    #endif

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let saving {
                    SavingBanner(file: saving)
                }
            }
            .onChange(of: failure == nil ? engine.lostOfferedFiles.first?.id : nil, initial: true) {
                guard failure == nil, let lost = engine.lostOfferedFiles.first else { return }
                engine.acknowledgeLostOfferedFile(lost.id)
                failure = UIError(title: lost.file.saveFailureTitle, message: lost.sentence)
            }
            .onChange(of: failure == nil ? engine.refusedLabAdditions.first?.id : nil, initial: true) {
                guard failure == nil, let refused = engine.refusedLabAdditions.first else { return }
                engine.acknowledgeRefusedLabAddition(refused.id)
                failure = UIError(title: refused.title, message: refused.sentence)
            }
            .alert(failure?.title ?? "", isPresented: failureBinding, presenting: failure) { _ in
                Button("OK") { failure = nil }
            } message: { failure in
                Text(failure.message)
            }
            #if os(macOS)
                .background(SavePanelPresenter(offer: nextOffer, settle: settle))
            #else
                .alert(nextOffer?.savePrompt ?? "", isPresented: isOfferingNext, presenting: nextOffer) { offer in
                    Button("Choose Folder\u{2026}") { folderOffer = offer }
                    Button("Cancel", role: .cancel) { engine.declineOfferedFile(offer.id) }
                } message: { _ in
                    Text("Luma saves it in the folder you choose.")
                }
                .fileImporter(isPresented: isChoosingFolderBinding, allowedContentTypes: [.folder], allowsMultipleSelection: false) {
                    [folderOffer] result in
                    self.folderOffer = nil
                    saveInFolder(folderOffer!, result: result.map { $0[0] })
                } onCancellation: { [folderOffer] in
                    self.folderOffer = nil
                    engine.declineOfferedFile(folderOffer!.id)
                }
            #endif
    }

    private var nextOffer: OfferedFile? {
        #if os(iOS)
            guard !isChoosingFolder else { return nil }
        #endif
        return saving == nil && failure == nil ? engine.offeredFiles.first : nil
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    #if os(macOS)
        private func settle(_ offer: OfferedFile, destination: URL?) {
            guard let destination else {
                return engine.declineOfferedFile(offer.id)
            }
            save(offer, to: destination)
        }
    #else
        private var isOfferingNext: Binding<Bool> {
            Binding(get: { nextOffer != nil }, set: { _ in })
        }

        private var isChoosingFolderBinding: Binding<Bool> {
            Binding(get: { isChoosingFolder }, set: { _ in })
        }

        private var isChoosingFolder: Bool {
            folderOffer.map(engine.offeredFiles.contains) ?? false
        }

        private func saveInFolder(_ offer: OfferedFile, result: Result<URL, any Error>) {
            switch result {
            case .success(let folder):
                let isAccessing = folder.startAccessingSecurityScopedResource()
                save(offer, to: vacantURL(named: offer.name, in: folder)) {
                    if isAccessing {
                        folder.stopAccessingSecurityScopedResource()
                    }
                }
            case .failure(let error):
                engine.declineOfferedFile(offer.id)
                failure = UIError(title: offer.saveFailureTitle, message: error.localizedDescription)
            }
        }
    #endif

    private func save(_ offer: OfferedFile, to destination: URL, then finish: @escaping () -> Void = {}) {
        saving = offer
        Task {
            do {
                try await engine.saveOfferedFile(offer.id, to: destination)
            } catch {
                failure = UIError(title: offer.saveFailureTitle, message: error.localizedDescription)
            }
            saving = nil
            finish()
        }
    }

    #if os(iOS)
        private func vacantURL(named name: String, in folder: URL) -> URL {
            let original = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: original.path) else { return original }
            let stem = original.deletingPathExtension().lastPathComponent
            return (2...).lazy
                .map { folder.appendingPathComponent("\(stem) \($0)").appendingPathExtension(original.pathExtension) }
                .first { !FileManager.default.fileExists(atPath: $0.path) }!
        }
    #endif
}

private struct SavingBanner: View {
    let file: OfferedFile

    var body: some View {
        LumaBanner(style: .info) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving “\(file.name)” from \(file.instrumentName)\u{2026}")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if os(macOS)
    private struct SavePanelPresenter: NSViewRepresentable {
        let offer: OfferedFile?
        let settle: (OfferedFile, URL?) -> Void

        func makeNSView(context: Context) -> SavePanelHostView {
            SavePanelHostView()
        }

        func updateNSView(_ view: SavePanelHostView, context: Context) {
            view.settle = settle
            view.offer = offer
        }
    }

    private final class SavePanelHostView: NSView {
        var settle: (OfferedFile, URL?) -> Void = { _, _ in }
        var offer: OfferedFile? {
            didSet { presentOffer() }
        }

        private var presented: (offer: OfferedFile, panel: NSSavePanel)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            presentOffer()
        }

        private func presentOffer() {
            guard offer?.id != presented?.offer.id else { return }
            dismissPresented()
            guard let offer, let window else { return }
            let panel = makePanel(for: offer)
            presented = (offer, panel)
            panel.beginSheetModal(for: window) { [weak self] response in
                self?.panelEnded(panel, offer: offer, response: response)
            }
        }

        private func dismissPresented() {
            guard let presented else { return }
            self.presented = nil
            presented.panel.cancel(nil)
        }

        private func makePanel(for offer: OfferedFile) -> NSSavePanel {
            let panel = NSSavePanel()
            panel.message = offer.savePrompt
            panel.nameFieldStringValue = offer.name
            if let type = UTType(mimeType: offer.mediaType), !type.isDynamic {
                panel.allowedContentTypes = [type]
            }
            return panel
        }

        private func panelEnded(_ panel: NSSavePanel, offer: OfferedFile, response: NSApplication.ModalResponse) {
            if presented?.panel === panel {
                presented = nil
            }
            settle(offer, response == .OK ? panel.url : nil)
        }
    }
#endif

extension OfferedFile {
    fileprivate var savePrompt: String {
        "Save “\(name)” from \(instrumentName)"
    }

    fileprivate var saveFailureTitle: String {
        "Could not save “\(name)” from \(instrumentName)"
    }
}
