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
            let object = GLibObject.ObjectRef(raw: dialog.ptr)
            guard let data = object.getData(key: controllerKey) else { return }
            nonisolated(unsafe) let keptUntilResponseIsEmitted = Unmanaged<AnyObject>.fromOpaque(data).takeUnretainedValue()
            object.setData(key: controllerKey, data: nil)
            Task { @MainActor in
                withExtendedLifetime(keptUntilResponseIsEmitted) {}
            }
        }
    }
}

private let controllerKey = "luma-controller"
