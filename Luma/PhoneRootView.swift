#if canImport(UIKit)

import LumaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhoneRootView: View {
    @State private var dbURL: URL?
    @State private var isShowingOpenPicker = false
    @State private var isShowingSaveAsPicker = false
    private var welcome: WelcomeModel { sharedWelcomeModel }
    @State private var isWelcomeOpenPickerVisible = false

    private static let lumaUTI = "re.frida.luma"

    var body: some View {
        Group {
            if let dbURL {
                PhoneMainView(
                    projectURL: dbURL,
                    documentActions: PhoneDocumentActions(
                        currentDisplayName: Self.displayName(for: dbURL),
                        new: returnToWelcome,
                        open: { isShowingOpenPicker = true },
                        saveAs: { isShowingSaveAsPicker = true }
                    )
                )
                .id(dbURL)
            } else {
                WelcomeView(
                    welcome: welcome,
                    onCreateBlank: openFreshUntitled,
                    onOpenExisting: { isWelcomeOpenPickerVisible = true },
                    onCreateFromLab: openFromLab
                )
                .fileImporter(
                    isPresented: $isWelcomeOpenPickerVisible,
                    allowedContentTypes: [UTType(exportedAs: Self.lumaUTI)]
                ) { result in
                    if case .success(let url) = result {
                        importExternal(url)
                    }
                }
            }
        }
        .task(id: "welcome-bootstrap") {
            await welcome.bootstrap()
        }
        .onOpenURL(perform: handleIncomingURL)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                handleIncomingURL(url)
            }
        }
        .fileImporter(
            isPresented: $isShowingOpenPicker,
            allowedContentTypes: [UTType(exportedAs: Self.lumaUTI)]
        ) { result in
            if case .success(let url) = result {
                importExternal(url)
            }
        }
        .fileExporter(
            isPresented: $isShowingSaveAsPicker,
            document: dbURL.map(LumaExportDocument.init(sourceURL:)),
            contentType: UTType(exportedAs: Self.lumaUTI),
            defaultFilename: dbURL.map(Self.displayName(for:))
        ) { _ in }
    }

    @MainActor
    private func returnToWelcome() {
        dbURL = nil
        Task { await welcome.refreshLabs() }
    }

    @MainActor
    private func openFromLab(_ lab: WelcomeModel.LabSummary) {
        let url = Self.untitledURL(named: lab.title)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        CollaborationJoinQueue.shared.enqueue(labID: lab.id)
        dbURL = url
        LumaAppState.shared.lastDocumentPath = url.path
    }

    @MainActor
    private func openFreshUntitled() {
        let url = Self.nextUntitledURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dbURL = url
        LumaAppState.shared.lastDocumentPath = url.path
    }

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "luma" {
            LumaAppDelegate.handle(url: url)
            return
        }
        if let labID = BackendConfig.labID(fromInviteLink: url) {
            joinLab(labID: labID)
            return
        }
        guard url.isFileURL else { return }
        importExternal(url)
    }

    @MainActor
    private func joinLab(labID: String) {
        CollaborationJoinQueue.shared.enqueue(labID: labID)
        guard dbURL == nil else { return }
        let url = Self.untitledURL(named: "Shared Lab")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dbURL = url
        LumaAppState.shared.lastDocumentPath = url.path
    }

    @MainActor
    private func importExternal(_ sourceURL: URL) {
        if sourceURL.path == dbURL?.path { return }

        let started = sourceURL.startAccessingSecurityScopedResource()
        defer { if started { sourceURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        do {
            let destURL = Self.workingCopyURL(for: sourceURL)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)
            dbURL = destURL
            LumaAppState.shared.lastDocumentPath = destURL.path
        } catch {
            assertionFailure("Failed to import \(sourceURL.path): \(error)")
        }
    }

    private static func nextUntitledURL() -> URL {
        let dir = LumaAppPaths.shared.untitledDirectory
        let fm = FileManager.default
        for index in 0..<4096 {
            let name = index == 0 ? "Untitled.luma" : "Untitled \(index).luma"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dir.appendingPathComponent("Untitled-\(UUID().uuidString).luma")
    }

    private static func untitledURL(named rawTitle: String) -> URL {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = rawTitle.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = sanitized.isEmpty ? "Lab" : sanitized
        let dir = LumaAppPaths.shared.untitledDirectory
        let fm = FileManager.default
        let primary = dir.appendingPathComponent("\(base).luma")
        if !fm.fileExists(atPath: primary.path) {
            return primary
        }
        for index in 1..<4096 {
            let candidate = dir.appendingPathComponent("\(base) \(index).luma")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dir.appendingPathComponent("\(base)-\(UUID().uuidString).luma")
    }

    private static func workingCopyURL(for sourceURL: URL) -> URL {
        let dir = LumaAppPaths.shared.untitledDirectory.appendingPathComponent(".working", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(baseName)-\(UUID().uuidString).luma")
    }

    private static let uuidSuffixPattern = #"-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    private static func displayName(for url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        if let range = raw.range(of: uuidSuffixPattern, options: .regularExpression) {
            return String(raw[..<range.lowerBound])
        }
        return raw
    }
}

struct PhoneNotebookSheet: View {
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotebookView(engine: engine, selection: .constant(nil))
                .navigationTitle("Notebook")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct PhonePlaygroundSheet: View {
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PharoPlaygroundView(engine: engine)
                .navigationTitle("Playground")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct PhoneMissionsSheet: View {
    let engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            MissionsListView(
                engine: engine,
                selection: Binding(
                    get: { nil },
                    set: { newValue in
                        if case .mission(let id) = newValue {
                            path.append(id)
                        }
                    }
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: UUID.self) { missionID in
                MissionView(
                    engine: engine,
                    missionID: missionID,
                    selection: .constant(.mission(missionID))
                )
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

struct PhoneCustomInstrumentsSheet: View {
    let engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var path: [CustomInstrumentRoute] = []

    enum CustomInstrumentRoute: Hashable {
        case file(UUID, String?)
    }

    var body: some View {
        NavigationStack(path: $path) {
            CustomInstrumentsBrowser(
                engine: engine,
                onPick: { defID, entrypoint in
                    path.append(.file(defID, entrypoint))
                },
                onCreate: { def in
                    path.append(.file(def.id, def.entrypoint))
                }
            )
            .navigationTitle("Custom Instruments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: CustomInstrumentRoute.self) { route in
                switch route {
                case .file(let defID, let filePath):
                    CustomInstrumentEditorView(
                        defID: defID,
                        path: filePath,
                        engine: engine,
                        selection: Binding(
                            get: { nil },
                            set: { newValue in
                                guard let newValue else { return }
                                switch newValue {
                                case .customInstrumentFile(let id, let p):
                                    path.append(.file(id, p))
                                case .customInstrumentDef(let id):
                                    path.append(.file(id, nil))
                                default:
                                    break
                                }
                            }
                        )
                    )
                    .navigationTitle(engine.customInstruments.def(withId: defID)?.name ?? "Custom Instrument")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}

private struct CustomInstrumentsBrowser: View {
    let engine: Engine
    let onPick: (UUID, String) -> Void
    let onCreate: (CustomInstrumentDef) -> Void

    private var defs: [CustomInstrumentDef] { engine.customInstruments.defs }

    var body: some View {
        Group {
            if defs.isEmpty {
                ContentUnavailableView {
                    Label("No custom instruments yet", systemImage: "hammer")
                } description: {
                    Text("Create one to write inline TypeScript that runs in the target.")
                } actions: {
                    Button {
                        createNew()
                    } label: {
                        Label("New Custom Instrument", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(defs) { def in
                        Button {
                            onPick(def.id, def.entrypoint)
                        } label: {
                            HStack(spacing: 12) {
                                InstrumentIconView(icon: def.icon, pointSize: 18)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(def.name).font(.body)
                                    Text(def.entrypoint)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            createNew()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New Custom Instrument")
                    }
                }
            }
        }
    }

    private func createNew() {
        let def = engine.createCustomInstrument()
        onCreate(def)
    }
}

struct PhoneDocumentActions {
    let currentDisplayName: String
    let new: () -> Void
    let open: () -> Void
    let saveAs: () -> Void

    static let noop = PhoneDocumentActions(
        currentDisplayName: "",
        new: {},
        open: {},
        saveAs: {}
    )
}

private struct LumaExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [UTType(exportedAs: "re.frida.luma")]

    let sourceURL: URL

    init() {
        self.sourceURL = URL(fileURLWithPath: "/dev/null")
    }

    init(configuration: ReadConfiguration) throws {
        self.sourceURL = URL(fileURLWithPath: "/dev/null")
    }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("luma-export-\(UUID().uuidString).luma", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let dbSource = sourceURL.appendingPathComponent("db.sqlite")
        let dbDest = staging.appendingPathComponent("db.sqlite")
        try ProjectStore.exportSnapshot(from: dbSource, to: dbDest)

        let tracesSource = sourceURL.appendingPathComponent("traces", isDirectory: true)
        let tracesDest = staging.appendingPathComponent("traces", isDirectory: true)
        if fm.fileExists(atPath: tracesSource.path) {
            try fm.copyItem(at: tracesSource, to: tracesDest)
        }

        let eventsSource = sourceURL.appendingPathComponent("events.log")
        let eventsDest = staging.appendingPathComponent("events.log")
        if fm.fileExists(atPath: eventsSource.path) {
            try fm.copyItem(at: eventsSource, to: eventsDest)
        }

        return try FileWrapper(url: staging, options: .immediate)
    }
}

#endif
