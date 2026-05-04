import XCTest

final class LumaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let cachedLabID: String? = nil

    @MainActor
    func testTracerHookEdit() async throws {
        let alice = try makeUser(label: "alice", tokenEnv: "LUMA_TEST_TOKEN_ALICE")
        addTeardownBlock { alice.cleanup() }

        let observed = try ObservedProcess()
        try observed.launch()
        addTeardownBlock { Task { @MainActor in observed.terminate() } }

        let app = LumaAppHarness(user: alice)
        app.launch()
        addTeardownBlock { Task { @MainActor in app.terminate() } }

        try app.newDocument()
        try app.attach(toProcessNamed: observed.processName)
        try app.addTracerForFunction("printf")
        try app.expandEventStream()

        try await waitUntil(timeout: 30) { @MainActor in
            let count = app.app.descendants(matching: .any)
                .matching(identifier: "event.row").count
            print("[testTracerHookEdit] baseline event rows=\(count)")
            return count > 0
        }

        let modifiedHook = """
        defineHandler({
          onEnter (log, args) {
            log("HOOKED-" + args[0].readUtf8String());
          }
        });
        """
        try app.replaceHookCode(modifiedHook)

        try await waitUntil(timeout: 30) { @MainActor in
            let rows = app.app.descendants(matching: .any)
                .matching(identifier: "event.row").allElementsBoundByIndex
            let hits = rows.filter { ($0.value as? String)?.contains("HOOKED-") == true }
            print("[testTracerHookEdit] event.row total=\(rows.count) HOOKED-=\(hits.count)")
            return !hits.isEmpty
        }
    }

    @MainActor
    func testCollaborativeMachoInspection() async throws {
        let bob = try makeUser(label: "bob", tokenEnv: "LUMA_TEST_TOKEN_BOB")
        addTeardownBlock { bob.cleanup() }

        let labID: String
        let observedProcessName: String
        let aliceApp: LumaAppHarness?
        if let cached = Self.cachedLabID {
            print("[LumaUITests] using cached labID=\(cached); skipping alice flow")
            labID = cached
            observedProcessName = ObservedProcess.processName
            aliceApp = nil
        } else {
            let alice = try makeUser(label: "alice", tokenEnv: "LUMA_TEST_TOKEN_ALICE")
            addTeardownBlock { alice.cleanup() }

            let observed = try ObservedProcess()
            try observed.launch()
            addTeardownBlock { Task { @MainActor in observed.terminate() } }
            observedProcessName = observed.processName

            let app = LumaAppHarness(user: alice)
            app.launch()
            addTeardownBlock { Task { @MainActor in app.terminate() } }

            try aliceCreateNewDocument(app)
            try aliceAttach(app, toProcessNamed: observed.processName)
            try aliceRunRepl(app, code: "Process.mainModule")
            try aliceRunRepl(app, code: "Process.arch")
            try aliceRunRepl(app, code: "Process.mainModule.base.readByteArray(64)")
            try alicePinLastThreeCellsToNotebook(app)
            try aliceSwitchToNotebook(app)
            try aliceAddUserNote(
                app,
                title: "Hmmm",
                body: "Kinda looks like a Mach-O header doesn't it?"
            )
            labID = try aliceEnableCollaboration(app)
            app.captureScreenshot(named: "alice-shared")
            print("[LumaUITests] alice produced labID=\(labID)")
            aliceApp = app
        }

        let bobApp = GtkAppHarness(user: bob, binaryURL: try lumaGtkBinaryURL())
        addTeardownBlock { await bobApp.shutdown() }
        try await bobApp.launchAndAttach()
        try await bobApp.joinLab(labID: labID)

        try await waitUntil(timeout: 30) { [bobApp] in
            let titles = try await bobApp.notebookEntryTitles()
            print("[LumaUITests] bob titles=\(titles)")
            if titles.isEmpty {
                let dump = try await bobApp.debugFirstNotebookEntry()
                print("[LumaUITests] bob first entry tree:\n\(dump)")
            }
            return titles.contains("Process.mainModule")
                && titles.contains("Process.arch")
                && titles.contains { $0.hasPrefix("Process.mainModule.base.readByteArray") }
                && titles.contains("Hmmm")
        }
        try await waitUntil(timeout: 30) { [bobApp] in
            let sessions = try await bobApp.sidebarSessionLabels()
            if sessions.isEmpty {
                let lbs = try await bobApp.debugListBoxes()
                print("[LumaUITests] bob listboxes=\(lbs)")
            }
            print("[LumaUITests] bob sessions=\(sessions)")
            return sessions.contains { $0.contains(observedProcessName) }
        }

        if let aliceApp {
            try aliceSwitchToNotebook(aliceApp)
            try aliceAddUserNote(
                aliceApp,
                title: "macOS confirmed",
                body: "Process.platform reports darwin."
            )
            try await waitUntil(timeout: 30) { [bobApp] in
                let titles = try await bobApp.notebookEntryTitles()
                print("[LumaUITests] bob live titles=\(titles)")
                return titles.contains("macOS confirmed")
            }
        }

        try await bobApp.selectReplRow()
        try await waitUntil(timeout: 30) { [bobApp] in
            let cells = try await bobApp.replCellCodes()
            print("[LumaUITests] bob replCells=\(cells)")
            return cells.contains("Process.mainModule")
                && cells.contains("Process.arch")
                && cells.contains { $0.hasPrefix("Process.mainModule.base.readByteArray") }
        }

        if let aliceApp {
            try aliceSwitchToREPL(aliceApp)
            try aliceRunRepl(aliceApp, code: "Process.platform")
            try await waitUntil(timeout: 30) { [bobApp] in
                let cells = try await bobApp.replCellCodes()
                print("[LumaUITests] bob live replCells=\(cells)")
                return cells.contains("Process.platform")
            }

            try aliceApp.addTracerForFunction("printf")
            try await waitUntil(timeout: 30) { [bobApp] in
                let sessions = try await bobApp.sidebarSessionLabels()
                print("[LumaUITests] bob sidebar (post-tracer)=\(sessions)")
                return sessions.contains("Tracer")
            }

            try aliceApp.expandEventStream()
            try await waitUntil(timeout: 30) { @MainActor in
                let count = aliceApp.app.descendants(matching: .any)
                    .matching(identifier: "event.row").count
                print("[LumaUITests] alice event rows=\(count)")
                return count > 0
            }
            try await bobApp.expandEventStream()
            try await waitUntil(timeout: 30) { [bobApp] in
                let count = try await bobApp.eventCount()
                print("[LumaUITests] bob event rows=\(count)")
                return count > 0
            }

            try await bobApp.selectTracerRow()

            let modifiedHook = """
            defineHandler({
              onEnter (log, args) {
                log("HOOKED-" + args[0].readUtf8String());
              }
            });
            """
            try aliceApp.replaceHookCode(modifiedHook)
            try await waitUntil(timeout: 30) { @MainActor in
                let rows = aliceApp.app.descendants(matching: .any)
                    .matching(identifier: "event.row").allElementsBoundByIndex
                let hits = rows.filter { ($0.value as? String)?.contains("HOOKED-") == true }
                print("[LumaUITests] alice event.row total=\(rows.count) HOOKED-=\(hits.count)")
                return !hits.isEmpty
            }
            try await waitUntil(timeout: 30) { [bobApp] in
                let messages = try await bobApp.eventMessages()
                let hits = messages.filter { $0.contains("HOOKED-") }
                print("[LumaUITests] bob HOOKED- messages=\(hits.count)")
                return !hits.isEmpty
            }
            try await waitUntil(timeout: 30) { [bobApp] in
                let text = try await bobApp.monacoLatestText() ?? ""
                print("[LumaUITests] bob monaco textLen=\(text.count) HOOKED-?=\(text.contains("HOOKED-"))")
                return text.contains("HOOKED-")
            }
        }

        try await bobApp.captureScreenshot(to: scenarioOutputURL(name: "bob-joined"))
    }

    @MainActor private func aliceCreateNewDocument(_ app: LumaAppHarness) throws {
        try app.newDocument()
    }

    @MainActor private func aliceAttach(_ app: LumaAppHarness, toProcessNamed name: String) throws {
        try app.attach(toProcessNamed: name)
    }

    @MainActor private func aliceRunRepl(_ app: LumaAppHarness, code: String) throws {
        try app.runRepl(code)
    }

    @MainActor private func alicePinLastThreeCellsToNotebook(_ app: LumaAppHarness) throws {
        try app.pinAllReplCellsToNotebook()
    }

    @MainActor private func aliceSwitchToNotebook(_ app: LumaAppHarness) throws {
        try app.switchToNotebook()
    }

    @MainActor private func aliceSwitchToREPL(_ app: LumaAppHarness) throws {
        try app.switchToREPL()
    }

    @MainActor private func aliceAddUserNote(_ app: LumaAppHarness, title: String, body: String) throws {
        try app.addUserNote(title: title, body: body)
    }

    @MainActor private func aliceEnableCollaboration(_ app: LumaAppHarness) throws -> String {
        try app.enableCollaboration()
    }

    private func waitUntil(
        timeout: TimeInterval,
        check: @MainActor () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("waitUntil timed out after \(timeout)s")
    }

    private func makeUser(label: String, tokenEnv: String) throws -> TestUser {
        guard let token = ProcessInfo.processInfo.environment[tokenEnv], !token.isEmpty else {
            throw XCTSkip("\(tokenEnv) not set; export a GitHub PAT to run this scenario")
        }
        return try TestUser(label: label, token: token)
    }

    private func lumaGtkBinaryURL() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["LUMA_GTK_BINARY"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = repoRoot.appendingPathComponent("LumaGtk/.build/release/LumaGtk")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            throw XCTSkip("LumaGtk binary not built — run `make -C LumaGtk build SWIFT_BUILD_FLAGS=-c\\ release` (or set LUMA_GTK_BINARY)")
        }
        return candidate
    }

    private func scenarioOutputURL(name: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("luma-scenario-output", isDirectory: true)
            .appendingPathComponent("\(name)-\(stamp)", isDirectory: true)
        return dir.appendingPathComponent("\(name).png")
    }
}
