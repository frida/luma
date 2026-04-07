import CGLib
import Dispatch
import Foundation
import Glibc

// Swift's main-actor executor on Linux dispatches to libdispatch's main queue
// (via swift-corelibs-libdispatch). g_application_run does not call
// dispatch_main(), so without intervention nothing drains pending main-queue
// work and any Task { @MainActor in ... } stalls forever.
//
// libdispatch on Linux exports the same hooks CFRunLoop uses on Apple to
// drain its main queue: _dispatch_get_main_queue_handle_4CF returns an fd
// that becomes readable when the main queue has work, and
// _dispatch_main_queue_callback_4CF drains whatever is pending.
//
// Watch the fd from a low-priority GLib I/O source so the GTK main loop
// drives the dispatch main queue, which in turn drives Swift's main actor.
// The drain priority sits below GTK's render idles so window mapping and
// drawing always run before we hand the main thread over to Swift work.

@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchGetMainQueueHandle() -> Int32

@_silgen_name("_dispatch_main_queue_callback_4CF")
private func dispatchMainQueueCallback(_ msg: UnsafeMutableRawPointer?)

private let drainCallback: GIOFunc = { _, _, _ in
    dispatchMainQueueCallback(nil)
    return 1  // G_SOURCE_CONTINUE
}

enum GLibMainExecutor {
    static func install() {
        // Touch the main queue so libdispatch initializes its handle.
        _ = DispatchQueue.main

        let fd = dispatchGetMainQueueHandle()
        guard fd >= 0 else {
            fatalError("Unable to get libdispatch main queue handle")
        }

        let channel = g_io_channel_unix_new(fd)
        g_io_add_watch_full(
            channel,
            Int32(G_PRIORITY_DEFAULT_IDLE),
            G_IO_IN,
            drainCallback,
            nil,
            nil
        )
        g_io_channel_unref(channel)
    }
}
