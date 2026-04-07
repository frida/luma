import Gdk
import Gtk

/// Closes the given window when the user presses Escape.
@MainActor
func installEscapeShortcut(on window: Window) {
    let key = EventControllerKey()
    key.onKeyPressed { [window] _, keyval, _, _ in
        MainActor.assumeIsolated {
            if Int32(keyval) == Gdk.keyEscape {
                window.close()
                return true
            }
            return false
        }
    }
    window.install(controller: key)
}
