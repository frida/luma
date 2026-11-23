import Foundation

#if os(macOS)
    import CoreServices
#else
    import Frida
#endif

@MainActor
final class InstrumentFolderMonitor {
    private let folderURL: URL
    private let onChange: @MainActor () -> Void
    private lazy var watch = InstrumentFolderWatch { [weak self] in self?.noteChange() }
    private var settling: Task<Void, Never>?

    init(folderURL: URL, onChange: @escaping @MainActor () -> Void) {
        self.folderURL = folderURL
        self.onChange = onChange
        watchFolder()
    }

    func stop() {
        settling?.cancel()
        watch.stop()
    }

    private func watchFolder() {
        let shared = (try? InstrumentFolder(folderURL: folderURL).sharedDirectories()) ?? []
        watch.watch(folderURL, sharing: shared)
    }

    private func noteChange() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.watchFolder()
            self.onChange()
        }
    }
}

#if os(macOS)
    /// One stream for the whole folder: the file monitor rests on kqueue here,
    /// where a directory's monitor does not hear its files being written, and
    /// watching each file holds descriptors for every one of them.
    typealias InstrumentFolderWatch = InstrumentFolderEventStream

    @MainActor
    final class InstrumentFolderEventStream {
        private let onChange: @MainActor @Sendable () -> Void
        private var stream: FSEventStreamRef?
        private var watched: Scope?

        init(onChange: @escaping @MainActor @Sendable () -> Void) {
            self.onChange = onChange
        }

        func watch(_ folderURL: URL, sharing sharedDirectories: [URL]) {
            let scope = Scope(folder: folderURL, sharedDirectories: sharedDirectories)
            guard scope != watched else { return }
            stop()
            watched = scope
            let listener = Listener(scope: scope, onChange: onChange)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(listener).toOpaque(),
                retain: nil,
                release: { info in Unmanaged<Listener>.fromOpaque(info!).release() },
                copyDescription: nil)
            let stream = FSEventStreamCreate(
                nil,
                { _, info, _, paths, _, _ in
                    let listener = Unmanaged<Listener>.fromOpaque(info!).takeUnretainedValue()
                    listener.hear(unsafeBitCast(paths, to: NSArray.self) as! [String])
                },
                &context,
                scope.roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))!
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
            self.stream = stream
        }

        func stop() {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            watched = nil
        }

        /// The folder and everything under it but its dependencies and hidden
        /// entries, and the files directly inside each shared directory.
        private struct Scope: Equatable, Sendable {
            let folder: String
            let sharedDirectories: Set<String>

            init(folder: URL, sharedDirectories: [URL]) {
                self.folder = Self.realPath(of: folder)
                self.sharedDirectories = Set(sharedDirectories.map(Self.realPath(of:)))
            }

            var roots: [String] {
                [folder] + sharedDirectories.sorted()
            }

            func contains(_ path: String) -> Bool {
                if sharedDirectories.contains((path as NSString).deletingLastPathComponent) {
                    return true
                }
                guard path.hasPrefix(folder + "/") else { return false }
                return !path.dropFirst(folder.count + 1).split(separator: "/").contains {
                    $0 == InstrumentFolder.dependenciesDirectoryName || $0.hasPrefix(".")
                }
            }

            /// The path as the stream reports it, which resolving symlinks through
            /// URL is not: that leaves /tmp where the stream says /private/tmp.
            private static func realPath(of url: URL) -> String {
                guard let resolved = realpath(url.path, nil) else { return url.path }
                defer { free(resolved) }
                return String(cString: resolved)
            }
        }

        private final class Listener: Sendable {
            private let scope: Scope
            private let onChange: @MainActor @Sendable () -> Void

            init(scope: Scope, onChange: @escaping @MainActor @Sendable () -> Void) {
                self.scope = scope
                self.onChange = onChange
            }

            func hear(_ paths: [String]) {
                guard paths.contains(where: scope.contains) else { return }
                MainActor.assumeIsolated { onChange() }
            }
        }
    }
#else
    /// On Linux a directory's monitor also hears the files in it being written;
    /// on iOS it hears only entries coming and going.
    typealias InstrumentFolderWatch = InstrumentFolderDirectoryWatches

    @MainActor
    final class InstrumentFolderDirectoryWatches {
        private let onChange: @MainActor () -> Void
        private var watches: [URL: Task<Void, Never>] = [:]

        init(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }

        func watch(_ folderURL: URL, sharing sharedDirectories: [URL]) {
            let own = (try? InstrumentFolder.directories(in: folderURL)) ?? []
            let directories = Set(own + sharedDirectories)
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
                        self?.onChange()
                    }
                    try? await monitor.disable()
                }
            }
        }

        func stop() {
            for watch in watches.values {
                watch.cancel()
            }
            watches.removeAll()
        }
    }
#endif
