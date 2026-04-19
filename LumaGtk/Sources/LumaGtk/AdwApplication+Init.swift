import Adw
import CAdw
import CGLib
import GIO
import GLib
import Gtk

extension Adw.Application {
    @inlinable convenience init?(id: String, flags: ApplicationFlags = []) {
        GLib.set(applicationName: id)
        let rv: UnsafeMutablePointer<AdwApplication>? = adw_application_new(id, flags.value)
        guard let app = rv else { return nil }
        self.init(app)
    }
}
