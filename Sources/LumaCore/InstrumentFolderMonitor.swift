import Foundation
import Frida

@MainActor
final class InstrumentFolderMonitor {
    private let folderURL: URL
    private let onChange: @MainActor () -> Void
    private var watches: [URL: Task<Void, Never>] = [:]
    private var settling: Task<Void, Never>?

    init(folderURL: URL, onChange: @escaping @MainActor () -> Void) {
        self.folderURL = folderURL
        self.onChange = onChange
        watchDirectories()
    }

    func stop() {
        settling?.cancel()
        for watch in watches.values {
            watch.cancel()
        }
        watches.removeAll()
    }

    private func watchDirectories() {
        let directories = Set((try? InstrumentFolder.directories(in: folderURL)) ?? [])
        for (directory, watch) in watches where !directories.contains(directory) {
            watch.cancel()
            watches.removeValue(forKey: directory)
        }
        for directory in directories where watches[directory] == nil {
            watches[directory] = Task { [weak self] in
                let monitor = FileMonitor(path: directory.path)
                let events = monitor.events
                guard (try? await monitor.enable()) != nil else { return }
                for await _ in events {
                    self?.noteChange()
                }
                try? await monitor.disable()
            }
        }
    }

    private func noteChange() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.watchDirectories()
            self.onChange()
        }
    }
}
