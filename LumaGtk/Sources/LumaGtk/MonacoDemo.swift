import CWebKit
import Foundation
import Gtk

@MainActor
enum MonacoDemo {
    static func present(in app: Application) {
        let window = ApplicationWindow(application: app)
        window.title = "Monaco Demo"
        window.setDefaultSize(width: 1100, height: 760)

        guard let resourceDir = Bundle.module.url(forResource: "MonacoWeb", withExtension: nil) else {
            fatalError("MonacoWeb resources not found in bundle")
        }
        let indexURL = resourceDir.appendingPathComponent("index.html")

        guard let view = luma_monaco_view_new() else {
            fatalError("luma_monaco_view_new returned null")
        }
        guard let widgetRaw = luma_monaco_view_widget(view) else {
            fatalError("luma_monaco_view_widget returned null")
        }

        luma_monaco_view_set_load_finished(view, monacoBootstrap, UnsafeMutableRawPointer(view))
        luma_monaco_view_set_text_handler(view, monacoTextReceived, nil)

        luma_monaco_view_load_uri(view, indexURL.absoluteString)

        let widget = WidgetRef(raw: widgetRaw)
        widget.hexpand = true
        widget.vexpand = true
        window.set(child: widget)

        let closeHandler: (WindowRef) -> Bool = { _ in true }
        _ = window.onCloseRequest(handler: closeHandler)
        window.present()
    }
}

private let bootstrapJS = """
editor.setLanguageId('typescript');
editor.setText('// Welcome to Monaco in LumaGtk\\nfunction hello(name: string): string {\\n    return `Hi ${name}`;\\n}\\n\\nhello("world");\\n');
editor.create({ automaticLayout: true, theme: 'vs-dark', fontSize: 14 });
document.body.style.opacity = '1';
console.log('[monaco] editor.create dispatched');
"""

private let monacoBootstrap: @convention(c) (
    OpaquePointer?,
    UnsafeMutableRawPointer?
) -> Void = { view, _ in
    guard let view else { return }
    luma_monaco_view_evaluate(view, bootstrapJS)
}

private let monacoTextReceived: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { textPtr, _ in
    guard let textPtr else { return }
    let b64 = String(cString: textPtr)
    guard let data = Data(base64Encoded: b64),
        let text = String(data: data, encoding: .utf8)
    else { return }
    FileHandle.standardError.write("[monaco] text changed (\(text.count) chars)\n".data(using: .utf8)!)
}
