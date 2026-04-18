import CLuma
import Foundation
import GLibObject
import Gtk
import LumaCore

@MainActor
public final class MonacoEditor {
    public let widget: WidgetRef
    private nonisolated(unsafe) let widgetRawPtr: UnsafeMutableRawPointer
    public var onTextChanged: ((String) -> Void)?
    public private(set) var isReady = false
    public var onReady: (() -> Void)?

    private let view: OpaquePointer
    private var profile: EditorProfile
    private var pendingText: String
    private var pendingSnapshot: EditorFSSnapshot?
    private var isLoaded = false

    private static var instances: [ObjectIdentifier: MonacoEditor] = [:]

    public init(profile: EditorProfile = .init(), initialText: String = "") {
        self.profile = profile
        self.pendingText = initialText

        guard let view = luma_monaco_view_new() else {
            fatalError("luma_monaco_view_new returned null")
        }
        guard let widgetRaw = luma_monaco_view_widget(view) else {
            fatalError("luma_monaco_view_widget returned null")
        }
        self.view = view
        _ = GLibObject.ObjectRef(raw: widgetRaw).ref()
        self.widgetRawPtr = widgetRaw
        self.widget = WidgetRef(raw: widgetRaw)
        self.widget.hexpand = true
        self.widget.vexpand = true

        let key = ObjectIdentifier(self)
        Self.instances[key] = self
        let context = Unmanaged.passUnretained(self).toOpaque()

        luma_monaco_view_set_load_finished(view, monacoEditorBootstrap, context)
        luma_monaco_view_set_text_handler(view, monacoEditorTextChanged, context)

        guard let resourceDir = Bundle.module.url(forResource: "MonacoWeb", withExtension: nil) else {
            fatalError("MonacoWeb resources not found in bundle")
        }
        let indexURL = resourceDir.appendingPathComponent("index.html")
        luma_monaco_view_load_uri(view, indexURL.absoluteString)
    }

    deinit {
        let key = ObjectIdentifier(self)
        let widgetPtr = widgetRawPtr
        MainActor.assumeIsolated {
            Self.instances[key] = nil
            GLibObject.ObjectRef(raw: widgetPtr).unref()
        }
    }

    public func reparent(into container: Box) {
        if let parent = widget.parent {
            BoxRef(raw: parent.ptr).remove(child: widget)
        }
        container.append(child: widget)
    }

    /// Install the editor into a host Box, overlaying a centered
    /// spinner until the underlying web view finishes loading.
    ///
    /// WebView2 on Windows only gets a parent HWND once GTK's
    /// realize signal fires, so the widget must enter the live tree
    /// before navigation can start — reparenting has to happen up
    /// front rather than from onReady.
    public func installInto(_ host: Box) {
        let container = Box(orientation: .vertical, spacing: 0)
        container.hexpand = true
        container.vexpand = true

        let spinner = Spinner()
        spinner.halign = .center
        spinner.valign = .center

        let overlay = Overlay()
        overlay.hexpand = true
        overlay.vexpand = true
        overlay.set(child: WidgetRef(container))
        overlay.addOverlay(widget: spinner)
        host.append(child: overlay)

        reparent(into: container)
        if isReady {
            spinner.visible = false
        } else {
            spinner.spinning = true
            spinner.start()
            onReady = { [weak spinner] in
                guard let spinner else { return }
                spinner.spinning = false
                spinner.stop()
                spinner.visible = false
            }
        }
    }

    public func setText(_ text: String) {
        pendingText = text
        if isLoaded {
            evaluate(setTextScript(text))
        }
    }

    public func setFSSnapshot(_ snapshot: EditorFSSnapshot?) {
        pendingSnapshot = snapshot
        if isLoaded, let script = snapshotScript(snapshot) {
            evaluate(script)
        }
    }

    public func setProfile(_ newProfile: EditorProfile) {
        profile = newProfile
        if isLoaded {
            evaluate(reconfigureScript(profile))
        }
    }

    fileprivate func handleLoadFinished() {
        isLoaded = true
        evaluate(initialBootstrapScript())
        isReady = true
        onReady?()
    }

    fileprivate func handleTextChanged(_ base64: String) {
        guard let data = Data(base64Encoded: base64),
            let text = String(data: data, encoding: .utf8)
        else { return }
        pendingText = text
        onTextChanged?(text)
    }

    private func evaluate(_ script: String) {
        luma_monaco_view_evaluate(view, script)
    }

    private func setTextScript(_ text: String) -> String {
        let b64 = text.data(using: .utf8)?.base64EncodedString() ?? ""
        return "editor.setText(atob('\(b64)'));"
    }

    private func snapshotScript(_ snapshot: EditorFSSnapshot?) -> String? {
        guard let snapshot else { return "editor.setFSSnapshot(null);" }
        guard let data = try? JSONEncoder().encode(snapshot),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return "editor.setFSSnapshot(\(json));"
    }

    private func initialBootstrapScript() -> String {
        var lines: [String] = []
        lines.append("editor.updateDefaultTypescriptCompilerOptions(\(profile.tsCompilerOptions.toJavaScriptObjectLiteral()));")
        if !profile.tsExtraLibs.isEmpty {
            lines.append("editor.updateDefaultTypescriptExtraLibs([\(profile.tsExtraLibs.map { $0.toJavaScriptObjectLiteral() }.joined(separator: ", "))]);")
        }
        lines.append("editor.updateDefaultJavascriptCompilerOptions(\(profile.jsCompilerOptions.toJavaScriptObjectLiteral()));")
        if !profile.jsExtraLibs.isEmpty {
            lines.append("editor.updateDefaultJavascriptExtraLibs([\(profile.jsExtraLibs.map { $0.toJavaScriptObjectLiteral() }.joined(separator: ", "))]);")
        }
        if let snapScript = snapshotScript(pendingSnapshot) {
            lines.append(snapScript)
        }
        lines.append("editor.setLanguageId('\(profile.languageId)');")
        lines.append(setTextScript(pendingText))
        let theme = profile.theme == .dark ? "vs-dark" : "vs"
        lines.append("""
        editor.create({
            automaticLayout: true,
            theme: '\(theme)',
            fontSize: \(profile.fontSize),
            minimap: { enabled: \(profile.minimap) },
            readOnly: \(profile.readOnly)
        });
        """)
        lines.append("document.body.style.opacity = '1';")
        return lines.joined(separator: "\n")
    }

    private func reconfigureScript(_ profile: EditorProfile) -> String {
        var lines: [String] = []
        lines.append("editor.updateDefaultTypescriptCompilerOptions(\(profile.tsCompilerOptions.toJavaScriptObjectLiteral()));")
        lines.append("editor.updateDefaultTypescriptExtraLibs([\(profile.tsExtraLibs.map { $0.toJavaScriptObjectLiteral() }.joined(separator: ", "))]);")
        lines.append("editor.updateDefaultJavascriptCompilerOptions(\(profile.jsCompilerOptions.toJavaScriptObjectLiteral()));")
        lines.append("editor.updateDefaultJavascriptExtraLibs([\(profile.jsExtraLibs.map { $0.toJavaScriptObjectLiteral() }.joined(separator: ", "))]);")
        lines.append("editor.setLanguageId('\(profile.languageId)');")
        let theme = profile.theme == .dark ? "vs-dark" : "vs"
        lines.append("editor.updateOptions({ theme: '\(theme)', fontSize: \(profile.fontSize), minimap: { enabled: \(profile.minimap) }, readOnly: \(profile.readOnly) });")
        return lines.joined(separator: "\n")
    }
}

private let monacoEditorBootstrap: @convention(c) (
    OpaquePointer?,
    UnsafeMutableRawPointer?
) -> Void = { _, userData in
    guard let userData else { return }
    let raw = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let editor = Unmanaged<MonacoEditor>.fromOpaque(ptr).takeUnretainedValue()
        editor.handleLoadFinished()
    }
}

private let monacoEditorTextChanged: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { textPtr, userData in
    guard let textPtr, let userData else { return }
    let b64 = String(cString: textPtr)
    let raw = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: raw)!
        let editor = Unmanaged<MonacoEditor>.fromOpaque(ptr).takeUnretainedValue()
        editor.handleTextChanged(b64)
    }
}

// MARK: - JS literal generation for the canonical types

extension EditorCompilerOptions {
    fileprivate func toJavaScriptObjectLiteral() -> String {
        var parts: [String] = []
        if let target { parts.append("target: \(target.rawValue)") }
        if let lib {
            let libJS = lib.map { "'\($0)'" }.joined(separator: ", ")
            parts.append("lib: [\(libJS)]")
        }
        if let module { parts.append("module: \(module.rawValue)") }
        if let moduleResolution { parts.append("moduleResolution: \(moduleResolution.rawValue)") }
        if let typeRoots {
            let rootsJS = typeRoots
                .map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }
                .joined(separator: ", ")
            parts.append("typeRoots: [\(rootsJS)]")
        }
        if let strict { parts.append("strict: \(strict ? "true" : "false")") }
        return "{ \(parts.joined(separator: ", ")) }"
    }
}

extension EditorExtraLib {
    fileprivate func toJavaScriptObjectLiteral() -> String {
        let b64 = content.data(using: .utf8)?.base64EncodedString() ?? ""
        let escapedPath = filePath.replacingOccurrences(of: "'", with: "\\'")
        return "{ content: atob('\(b64)'), filePath: '\(escapedPath)' }"
    }
}
