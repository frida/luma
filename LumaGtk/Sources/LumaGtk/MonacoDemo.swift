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

        guard let widgetPtr = webkit_web_view_new() else {
            fatalError("webkit_web_view_new returned null")
        }
        let webViewPtr = UnsafeMutableRawPointer(widgetPtr).assumingMemoryBound(to: WebKitWebView.self)

        webkit_web_view_load_uri(webViewPtr, indexURL.absoluteString)

        let widget = WidgetRef(raw: UnsafeMutableRawPointer(widgetPtr))
        widget.hexpand = true
        widget.vexpand = true
        window.set(child: widget)

        let closeHandler: (WindowRef) -> Bool = { _ in true }
        _ = window.onCloseRequest(handler: closeHandler)
        window.present()
    }
}
