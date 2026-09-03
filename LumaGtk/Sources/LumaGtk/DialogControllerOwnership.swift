import Adw
import GLibObject
import Gtk

@MainActor
extension Adw.DialogProtocol {
    func own(_ controller: AnyObject) {
        let object = GLibObject.ObjectRef(raw: ptr)
        object.setDataFull(
            key: controllerKey,
            data: Unmanaged.passRetained(controller).toOpaque(),
            destroy: { data in Unmanaged<AnyObject>.fromOpaque(data!).release() })
        onClosed(flags: .after) { dialog in
            GLibObject.ObjectRef(raw: dialog.ptr).setData(key: controllerKey, data: nil)
        }
    }
}

private let controllerKey = "luma-controller"
