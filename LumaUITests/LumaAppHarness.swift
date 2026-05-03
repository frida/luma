import AppKit
import Foundation
import XCTest

@MainActor
final class LumaAppHarness {
    let user: TestUser
    let app: XCUIApplication
    private(set) var documentWindow: XCUIElement?

    init(user: TestUser) {
        self.user = user
        self.app = XCUIApplication()
        app.launchEnvironment = user.launchEnvironment()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
    }

    func launch() {
        app.launch()
    }

    func newDocument(timeout: TimeInterval = 10) throws {
        app.activate()
        app.windows["Welcome to Luma"].buttons["welcome.newProject"].click()

        let candidate = app.windows.matching(NSPredicate(format: "title != 'Welcome to Luma'")).firstMatch
        if !candidate.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.windowNotFound("no document window after clicking New Project within \(timeout)s")
        }
        documentWindow = candidate
    }

    func requireDocumentWindow() throws -> XCUIElement {
        guard let documentWindow else {
            throw LumaAppHarnessError.documentWindowNotOpen
        }
        return documentWindow
    }

    func waitForReplReady(timeout: TimeInterval = 30) throws {
        let input = app.descendants(matching: .any).matching(identifier: "repl.input").firstMatch
        let errorText = app.descendants(matching: .any).matching(identifier: "session.errorText").firstMatch

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if input.exists {
                return
            }
            if errorText.exists {
                throw LumaAppHarnessError.sessionAttachFailed(errorText.value as! String)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw LumaAppHarnessError.elementNotFound("repl.input")
    }

    func runRepl(_ code: String, timeout: TimeInterval = 30) throws {
        try waitForReplReady(timeout: timeout)
        let input = app.descendants(matching: .any).matching(identifier: "repl.input").firstMatch
        input.click()
        input.typeText(code)
        app.typeKey(.return, modifierFlags: [])
    }

    func addUserNote(title: String, body: String, timeout: TimeInterval = 10) throws {
        let newNote = app.descendants(matching: .any).matching(identifier: "notebook.newNote").firstMatch
        if !newNote.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("notebook.newNote")
        }
        newNote.click()

        let titleField = app.descendants(matching: .any).matching(identifier: "notebook.note.title").firstMatch
        if !titleField.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("notebook.note.title")
        }
        titleField.typeText(title)

        let bodyField = app.descendants(matching: .any).matching(identifier: "notebook.note.body").firstMatch
        bodyField.click()
        bodyField.typeText(body)

        app.buttons["Save"].firstMatch.click()
    }

    func enableCollaboration(timeout: TimeInterval = 60) throws -> String {
        app.typeKey("c", modifierFlags: [.command, .option])

        let enableButton = app.descendants(matching: .any).matching(identifier: "collaboration.enable").firstMatch
        if !enableButton.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("collaboration.enable")
        }
        enableButton.click()

        let inviteLink = app.descendants(matching: .any).matching(identifier: "collaboration.inviteLink").firstMatch
        let retryButton = app.descendants(matching: .any).matching(identifier: "collaboration.retry").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if inviteLink.waitForExistence(timeout: 2) {
                break
            }
            if retryButton.exists {
                retryButton.click()
            }
        }
        if !inviteLink.exists {
            throw LumaAppHarnessError.elementNotFound("collaboration.inviteLink")
        }
        let inviteURL = inviteLink.value as! String
        guard let slash = inviteURL.range(of: "/l/", options: .backwards) else {
            throw LumaAppHarnessError.protocolMismatch("invite URL has no /l/ segment: \(inviteURL)")
        }
        let labID = String(inviteURL[slash.upperBound...])
        app.typeKey("c", modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        return labID
    }

    func addTracerForFunction(_ pattern: String, timeout: TimeInterval = 60) throws {
        app.activate()
        let window = try requireDocumentWindow()
        window.click()
        app.typeKey("i", modifierFlags: [.command, .shift])

        let tracerRow = app.descendants(matching: .any)
            .matching(identifier: "addInstrument.descriptor.tracer").firstMatch
        if !tracerRow.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("addInstrument.descriptor.tracer")
        }
        tracerRow.click()

        let search = app.textFields["tracer.searchQuery"]
        if !search.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("tracer.searchQuery")
        }
        search.click()
        search.typeText(pattern)

        let addAll = app.descendants(matching: .any)
            .matching(identifier: "tracer.addAll").firstMatch
        if !addAll.waitForExistence(timeout: timeout) {
            captureScreenshot(named: "addTracer-noResults")
            throw LumaAppHarnessError.elementNotFound("tracer.addAll")
        }
        addAll.click()

        let addButton = app.descendants(matching: .any)
            .matching(identifier: "addInstrument.add").firstMatch
        if !addButton.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("addInstrument.add")
        }
        addButton.click()
    }

    func expandEventStream(timeout: TimeInterval = 10) throws {
        let bar = app.descendants(matching: .any).matching(identifier: "eventStream.expand").firstMatch
        if !bar.waitForExistence(timeout: timeout) { return }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func replaceHookCode(_ code: String, timeout: TimeInterval = 30) throws {
        app.activate()
        let window = try requireDocumentWindow()
        window.click()
        let editor = app.descendants(matching: .any)
            .matching(identifier: "tracer.hookEditor").firstMatch
        if !editor.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("tracer.hookEditor")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)

        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("a", modifierFlags: [.command])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("v", modifierFlags: [.command])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("s", modifierFlags: [.command])
    }

    func switchToREPL(timeout: TimeInterval = 10) throws {
        app.activate()
        let window = try requireDocumentWindow()
        window.click()
        let row = app.outlines.firstMatch.outlineRows
            .containing(.any, identifier: "sidebar.repl").firstMatch
        if !row.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("sidebar.repl")
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func switchToNotebook(timeout: TimeInterval = 10) throws {
        app.activate()
        let window = try requireDocumentWindow()
        window.click()
        let row = app.descendants(matching: .any).matching(identifier: "sidebar.notebook").firstMatch
        if !row.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("sidebar.notebook")
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func pinAllReplCellsToNotebook() throws {
        let cells = app.descendants(matching: .any).matching(identifier: "repl.cell").allElementsBoundByIndex
        if cells.isEmpty {
            throw LumaAppHarnessError.elementNotFound("repl.cell")
        }
        for cell in cells {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).rightClick()
            app.menuItems["Add to Notebook"].click()
        }
    }

    func attach(toProcessNamed name: String, timeout: TimeInterval = 30) throws {
        let window = try requireDocumentWindow()
        window.click()
        app.typeKey("n", modifierFlags: [.command, .option])

        let search = app.textFields["targetPicker.processSearch"]
        if !search.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("targetPicker.processSearch")
        }
        search.click()
        search.typeText(name)

        let row = app.descendants(matching: .any).matching(identifier: "targetPicker.process.\(name)").firstMatch
        if !row.waitForExistence(timeout: timeout) {
            throw LumaAppHarnessError.elementNotFound("targetPicker.process.\(name)")
        }
        row.click()
    }

    func captureScreenshot(named name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Screenshot \(name)") { activity in
            activity.add(attachment)
        }
        let path = NSTemporaryDirectory() + "alice-\(name).png"
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        print("[LumaAppHarness] alice screenshot -> \(path)")
    }

    func terminate() {
        app.terminate()
    }
}

enum LumaAppHarnessError: Swift.Error, CustomStringConvertible {
    case windowNotFound(String)
    case documentWindowNotOpen
    case elementNotFound(String)
    case sessionAttachFailed(String)
    case protocolMismatch(String)

    var description: String {
        switch self {
        case .windowNotFound(let m): return m
        case .documentWindowNotOpen: return "no document window — call newDocument() first"
        case .elementNotFound(let id): return "element not found within timeout: \(id)"
        case .sessionAttachFailed(let msg): return "Frida attach failed: \(msg)"
        case .protocolMismatch(let m): return "protocol mismatch: \(m)"
        }
    }
}
