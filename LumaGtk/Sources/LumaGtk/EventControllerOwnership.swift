import GLibObject
import Gtk

// gtk_widget_add_controller takes ownership of the caller's reference
// (no extra g_object_ref). The Swift wrapper for an event controller
// holds the +1 returned by its constructor and will g_object_unref on
// deinit, which would race with the widget's own unref on dispose and
// leave GTK with a freed pointer. Bumping the refcount by one before
// the call gives both the widget and the Swift wrapper their own ref.
//
// Use this everywhere instead of `widget.add(controller: ...)` so the
// controller stays alive for as long as the widget needs it.
@MainActor
extension WidgetProtocol {
    func install<EventControllerT: EventControllerProtocol>(controller: EventControllerT) {
        let object = GLibObject.ObjectRef(raw: controller.ptr)
        _ = object.ref()
        add(controller: controller)
    }
}
