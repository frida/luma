import Adw
import CAdw
import CGLib
import GIO
import GLib
import Gtk

extension Adw.Application {
    @inlinable convenience init?(id: String, flags: ApplicationFlags = []) {
        let rv: UnsafeMutablePointer<AdwApplication>? = id.withCString { cid in
            GLib.set(applicationName: cid)
            return adw_application_new(cid, flags.value)
        }
        guard let app = rv else { return nil }
        self.init(app)
    }
}
