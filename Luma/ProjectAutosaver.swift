#if canImport(AppKit)
import AppKit
#endif
import Foundation
import LumaCore

@MainActor
final class ProjectAutosaver {
    private let workingURL: URL
    private let destinationURL: URL
    private let debounce: Duration
    private var pending: Task<Void, Never>?

    init(workingURL: URL, destinationURL: URL, debounce: Duration = .seconds(30)) {
        self.workingURL = workingURL
        self.destinationURL = destinationURL
        self.debounce = debounce
    }

    func scheduleSnapshot() {
        pending?.cancel()
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            await self.writeSnapshot()
        }
    }

    func flush() async {
        pending?.cancel()
        pending = nil
        await writeSnapshot()
    }

    private func writeSnapshot() async {
        let workingURL = self.workingURL
        let destinationURL = self.destinationURL
        let modificationDate = await Task.detached(priority: .utility) { () -> Date? in
            do {
                try ProjectSnapshot.write(workingURL: workingURL, to: destinationURL)
            } catch {
                return nil
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
            return attrs?[.modificationDate] as? Date
        }.value
        syncDocumentModificationDate(modificationDate)
    }

    private func syncDocumentModificationDate(_ date: Date?) {
        #if canImport(AppKit)
        guard let date,
            let doc = NSDocumentController.shared.documents.first(where: { $0.fileURL == destinationURL })
        else { return }
        doc.fileModificationDate = date
        #endif
    }
}
