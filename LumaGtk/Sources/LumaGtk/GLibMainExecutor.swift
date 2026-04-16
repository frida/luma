import CGLib
import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Swift's main-actor executor on Linux dispatches to libdispatch's main queue
// (via swift-corelibs-libdispatch). g_application_run does not call
// dispatch_main(), so without intervention nothing drains pending main-queue
// work and any Task { @MainActor in ... } stalls forever.
//
// libdispatch on Linux exports the same hooks CFRunLoop uses on Apple to
// drain its main queue: _dispatch_get_main_queue_handle_4CF returns a unix
// file descriptor that becomes readable when the main queue has work, and
// _dispatch_main_queue_callback_4CF drains whatever is pending.
//
// Watch the fd from a low-priority GLib I/O source so the GTK main loop
// drives the dispatch main queue, which in turn drives Swift's main actor.
// The drain priority sits below GTK's render idles so window mapping and
// drawing always run before we hand the main thread over to Swift work.
//
// macOS doesn't need any of this: the GDK macOS backend pumps NSApplication
// from inside g_application_run, which spins CFRunLoop, which already drains
// libdispatch's main queue. The 4CF handle on Apple platforms is a Mach
// port name, not a unix fd, so feeding it to g_io_channel_unix_new would
// just produce a Bad-file-descriptor warning.

#if os(Linux) || os(Windows)

@_silgen_name("_dispatch_main_queue_callback_4CF")
private func dispatchMainQueueCallback(_ msg: UnsafeMutableRawPointer?)

#endif

#if os(Linux)

@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchGetMainQueueHandle() -> Int32

private let drainCallback: GIOFunc = { channel, _, _ in
    var value: UInt64 = 0
    let fd = g_io_channel_unix_get_fd(channel)
    _ = withUnsafeMutablePointer(to: &value) { ptr -> Int in
        read(fd, UnsafeMutableRawPointer(ptr), MemoryLayout<UInt64>.size)
    }
    dispatchMainQueueCallback(nil)
    return 1  // G_SOURCE_CONTINUE
}

#endif

#if os(Windows)

// On Windows, libdispatch's main-queue handle is a win32 HANDLE that becomes
// signaled when work is pending. GLib supports waiting on win32 HANDLEs by
// storing them (cast to gint) in a GPollFD; g_poll feeds them straight into
// WaitForMultipleObjects. Wrap it in a custom GSource so the drain is
// event-driven rather than polled.

@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchGetMainQueueHandle() -> UnsafeMutableRawPointer

private nonisolated(unsafe) var windowsDispatchPollFd = GPollFD()

private let windowsDispatchSourcePrepare: @convention(c) (
    UnsafeMutablePointer<GSource>?, UnsafeMutablePointer<Int32>?
) -> gboolean = { _, timeout in
    timeout?.pointee = -1
    return 0
}

private let windowsDispatchSourceCheck: @convention(c) (
    UnsafeMutablePointer<GSource>?
) -> gboolean = { _ in
    (windowsDispatchPollFd.revents & UInt16(G_IO_IN.rawValue)) != 0 ? 1 : 0
}

private let windowsDispatchSourceDispatch: @convention(c) (
    UnsafeMutablePointer<GSource>?, GSourceFunc?, gpointer?
) -> gboolean = { _, _, _ in
    dispatchMainQueueCallback(nil)
    return 1  // G_SOURCE_CONTINUE
}

private nonisolated(unsafe) var windowsDispatchSourceFuncs = GSourceFuncs(
    prepare: windowsDispatchSourcePrepare,
    check: windowsDispatchSourceCheck,
    dispatch: windowsDispatchSourceDispatch,
    finalize: nil,
    closure_callback: nil,
    closure_marshal: nil
)

#endif

enum GLibMainExecutor {
    static func install() {
        #if os(Linux)
        // Touch the main queue so libdispatch initializes its handle.
        _ = DispatchQueue.main

        let fd = dispatchGetMainQueueHandle()
        guard fd >= 0 else {
            fatalError("Unable to get libdispatch main queue handle")
        }

        let channel = g_io_channel_unix_new(fd)
        g_io_add_watch_full(
            channel,
            Int32(G_PRIORITY_LOW),
            G_IO_IN,
            drainCallback,
            nil,
            nil
        )
        g_io_channel_unref(channel)
        #elseif os(Windows)
        _ = DispatchQueue.main

        let handle = dispatchGetMainQueueHandle()
        windowsDispatchPollFd.fd = Int64(Int(bitPattern: handle))
        windowsDispatchPollFd.events = UInt16(G_IO_IN.rawValue)
        windowsDispatchPollFd.revents = 0

        let source = g_source_new(
            &windowsDispatchSourceFuncs,
            UInt32(MemoryLayout<GSource>.size)
        )
        g_source_set_priority(source, Int32(G_PRIORITY_LOW))
        g_source_add_poll(source, &windowsDispatchPollFd)
        g_source_attach(source, nil)
        g_source_unref(source)
        #endif
    }
}
