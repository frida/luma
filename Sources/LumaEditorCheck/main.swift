import Foundation
import LumaCore

let hookSource = """
    defineHandler({
      onEnter(log, args) {
        const m = Process.mainModule;
        m.
      },
    });

    """

@MainActor
func check() async -> Int32 {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("luma-editor-check-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let project = TypeScriptProject(root: root)
    do {
        try await project.start(ambientDeclarations: [TracerTypings.handler])
    } catch {
        print("language server failed to start: \(error)")
        return 1
    }
    defer { Task { await project.stop() } }

    let document = project.openDocument(path: "Editor/hook.ts", text: hookSource, languageId: "typescript")
    var complaints: [String] = []

    let diagnostics = await firstDiagnostics(of: document, within: 10)
    print("diagnostics: \(diagnostics.map(\.message))")
    if !diagnostics.contains(where: { $0.code == .number(1003) }) {
        complaints.append("the dangling member access went unreported")
    }
    if diagnostics.contains(where: { $0.message.contains("defineHandler") }) {
        complaints.append("the tracer's ambient declarations were not seen")
    }
    if diagnostics.contains(where: { $0.message.contains("Process") }) {
        complaints.append("the compiler's frida-gum typings were not seen")
    }

    do {
        let completions = try await document.completions(at: LSP.Position(line: 3, character: 6), triggerCharacter: ".")
        print("completions after m.: \(completions.items.count), e.g. \(completions.items.prefix(4).map(\.label))")
        if !completions.items.contains(where: { $0.label == "enumerateExports" }) {
            complaints.append("Module's members were not completed after m.")
        }

        let hover = try await document.hover(at: LSP.Position(line: 2, character: 16))
        print("hover on Process: \(hover?.contents.text.prefix(80) ?? "nothing")")
        if hover == nil {
            complaints.append("no hover for Process")
        }

        let symbols = try await document.symbols()
        print("symbols: \(symbols.map(\.name))")
    } catch {
        complaints.append("request failed: \(error)")
    }

    let indented = SourceIndentation.newline(in: "defineHandler({", atUTF16: 15)
    print("newline after an opening brace: \(indented.text.debugDescription)")
    if indented.text != "\n    " {
        complaints.append("a new line after an opening brace was not indented")
    }
    let split = SourceIndentation.newline(in: "foo({})", atUTF16: 5)
    if split.text != "\n    \n" || split.caretOffset != 5 {
        complaints.append("a closer ahead of the caret was not moved to its own line")
    }
    if SourceIndentation.closerDedent(in: "{\n    ", atUTF16: 6) != 2..<6 {
        complaints.append("a closer on a blank line did not step back out")
    }
    let template = CallTemplate(name: "attach", parameters: ["target", "callbacks"])
    print("call template: \(template.snippet)")
    if template.snippet != "attach(${1:target}, ${2:callbacks})$0" || template.placeholders != [7..<13, 15..<24] {
        complaints.append("the call template did not lay out its arguments")
    }

    for complaint in complaints {
        print("FAIL: \(complaint)")
    }
    return complaints.isEmpty ? 0 : 1
}

@MainActor
func firstDiagnostics(of document: TypeScriptDocument, within seconds: Double) async -> [LSP.Diagnostic] {
    let (stream, continuation) = AsyncStream<[LSP.Diagnostic]>.makeStream()
    document.onDiagnostics = { continuation.yield($0) }
    let deadline = Task {
        try? await Task.sleep(for: .seconds(seconds))
        continuation.finish()
    }
    defer { deadline.cancel() }
    for await diagnostics in stream {
        return diagnostics
    }
    return []
}

setlinebuf(stdout)
exit(await check())
