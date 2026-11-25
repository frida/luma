import Foundation
import GIO
import Gtk
import LumaCore
import Observation

@MainActor
final class OfferedFileSaver {
    private let engine: Engine
    private let window: Gtk.Window
    private let toasts: ToastOverlay
    private var turn: Turn = .idle

    private enum Turn {
        case idle
        case choosing(OfferedFile, GIO.Cancellable)
        case saving
    }

    init(engine: Engine, window: Gtk.Window, toasts: ToastOverlay) {
        self.engine = engine
        self.window = window
        self.toasts = toasts
        observe()
    }

    private func observe() {
        withObservationTracking {
            follow(engine.offeredFiles)
        } onChange: { [weak self] in
            _Concurrency.Task { @MainActor in self?.observe() }
        }
    }

    private func follow(_ offers: [OfferedFile]) {
        switch turn {
        case .idle:
            if let next = offers.first {
                present(next)
            }
        case .choosing(let file, let cancellable):
            if !offers.contains(where: { $0.id == file.id }) {
                cancellable.cancel()
            }
        case .saving:
            break
        }
    }

    private func present(_ file: OfferedFile) {
        let cancellable = GIO.Cancellable()
        turn = .choosing(file, cancellable)
        FileDialogRequest.present(.saveAs, title: "Save \u{201C}\(file.name)\u{201D} from \(file.instrumentName)", initialName: file.name,
                                  mediaType: file.mediaType, cancellable: cancellable, parent: window) { [weak self] paths in
            self?.answer(file, destination: paths.first)
        }
    }

    private func answer(_ file: OfferedFile, destination: String?) {
        guard engine.offeredFiles.contains(where: { $0.id == file.id }) else {
            toasts.show("\u{201C}\(file.name)\u{201D} from \(file.instrumentName) is no longer available", durationSeconds: 8)
            return settle()
        }
        guard let destination else {
            engine.declineOfferedFile(file.id)
            return settle()
        }
        save(file, to: URL(fileURLWithPath: destination))
    }

    private func save(_ file: OfferedFile, to url: URL) {
        turn = .saving
        toasts.show("Saving \u{201C}\(file.name)\u{201D}\u{2026}", durationSeconds: 0)
        _Concurrency.Task { @MainActor in
            do {
                try await engine.saveOfferedFile(file.id, to: url)
                toasts.show("Saved \u{201C}\(file.name)\u{201D}")
            } catch {
                toasts.show("Could not save \u{201C}\(file.name)\u{201D}: \(error.localizedDescription)", durationSeconds: 8)
            }
            settle()
        }
    }

    private func settle() {
        turn = .idle
        follow(engine.offeredFiles)
    }
}
