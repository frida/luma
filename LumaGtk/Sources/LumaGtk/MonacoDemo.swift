import Foundation
import Gtk
import LumaCore

@MainActor
enum MonacoDemo {
    static func present(in app: Application) {
        let window = ApplicationWindow(application: app)
        applyWindowDecoration(window)
        window.title = "Monaco Demo"
        window.setDefaultSize(width: 1100, height: 760)

        var profile = EditorProfile(
            languageId: "typescript",
            theme: .dark,
            fontSize: 14
        )
        if let gum = EditorProfile.fridaGumLib {
            profile.tsExtraLibs.append(gum)
        }

        let initialText = """
        // Frida-aware TypeScript IntelliSense, hosted in WebKitWebView.
        // Try: Interceptor.attach(<Ctrl-Space>
        const onEnter: NativeCallback = new NativeCallback((arg) => {
            console.log('onEnter called with', arg);
        }, 'void', ['pointer']);

        Interceptor.attach(Module.getGlobalExportByName('open'), {
            onEnter(args) {
                const path = args[0].readUtf8String();
                console.log(`open(${path})`);
            }
        });
        """

        let editor = MonacoEditor(profile: profile, initialText: initialText)
        editor.widget.hexpand = true
        editor.widget.vexpand = true
        retainedEditor = editor

        window.set(child: editor.widget)

        let closeHandler: (WindowRef) -> Bool = { _ in true }
        _ = window.onCloseRequest(handler: closeHandler)
        window.present()
    }
}

@MainActor
private var retainedEditor: MonacoEditor?
