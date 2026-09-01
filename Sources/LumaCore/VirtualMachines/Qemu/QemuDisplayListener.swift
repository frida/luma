import Foundation
import Frida

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if !os(Windows)

final class QemuDisplayListener: GLib.DBusObjectHandler, @unchecked Sendable {
    var onScanout: (@Sendable (VirtualMachineFrame) -> Void)?
    var onUpdate: (@Sendable () -> Void)?

    private var console: GLib.DBusConnection?
    private var listener: GLib.DBusConnection?
    private var mapping: QemuFrameMapping?

    private let pending: AsyncStream<PointerRequest>
    private let queue: AsyncStream<PointerRequest>.Continuation

    init() {
        (pending, queue) = AsyncStream.makeStream()
        Task { await deliverPending() }
    }

    func attach(to monitor: QemuMonitor) async throws {
        let (hostEnd, guestEnd) = try GLib.Socket.pair()

        _ = try await monitor.execute(
            "getfd",
            arguments: ["fdname": .string(QemuIdentifier.displayFD)],
            passing: guestEnd.fileDescriptor
        )
        guestEnd.close()
        _ = try await monitor.execute(
            "add_client",
            arguments: ["protocol": .string("@dbus-display"), "fdname": .string(QemuIdentifier.displayFD)]
        )

        let console = try await GLib.DBusConnection.connect(to: hostEnd, as: .client)
        self.console = console

        let (listenerEnd, qemuEnd) = try GLib.Socket.pair()

        async let listener = GLib.DBusConnection.connect(to: listenerEnd, as: .client, startingMessageProcessing: false)
        _ = try await console.call(
            at: Self.consolePath,
            interface: "org.qemu.Display1.Console",
            method: "RegisterListener",
            parameters: GLib.Variant(tuple: [.fileDescriptor(at: 0)]),
            fileDescriptors: [qemuEnd.fileDescriptor]
        )
        qemuEnd.close()

        let connection = try await listener
        try await connection.registerObject(at: Self.listenerPath, interfaces: Self.interfaces, handler: self)
        connection.startMessageProcessing()
        self.listener = connection
    }

    func send(_ event: VirtualMachineInputEvent) {
        for request in requests(for: event) {
            send(request)
        }
    }

    private func send(_ request: PointerRequest) {
        queue.yield(request)
    }

    /// One at a time and in the order they happened: a press racing its own
    /// release leaves the guest holding a button nothing let go of.
    private func deliverPending() async {
        for await request in pending {
            guard let console else { continue }

            _ = try? await console.call(
                at: Self.consolePath,
                interface: request.interface,
                method: request.method,
                parameters: GLib.Variant(tuple: request.arguments.map(\.variant))
            )
        }
    }

    func close() {
        queue.finish()
        listener?.close()
        listener = nil
        console?.close()
        console = nil
        mapping = nil
    }

    func handle(_ call: GLib.DBusMethodCall) {
        switch call.method {
        case "ScanoutMap":
            adoptScanout(call)
        case "UpdateMap", "Update":
            onUpdate?()
        default:
            break
        }
        call.complete()
    }

    func property(_ name: String, on interface: String) -> GLib.Variant? {
        switch name {
        case "Interfaces":
            return GLib.Variant([Self.mapInterface])
        case "InterfaceVersion":
            return GLib.Variant(UInt32(1))
        default:
            return nil
        }
    }

    private func adoptScanout(_ call: GLib.DBusMethodCall) {
        let arguments = call.parameters.children
        guard let index = arguments[0].fileDescriptorIndex,
            let fileDescriptor = try? call.fileDescriptor(at: index)
        else {
            return
        }

        let offset = Int(arguments[1].uint32 ?? 0)
        let width = Int(arguments[2].uint32 ?? 0)
        let height = Int(arguments[3].uint32 ?? 0)
        let stride = Int(arguments[4].uint32 ?? 0)
        let format = arguments[5].uint32 ?? 0

        guard let mapping = QemuFrameMapping(fileDescriptor: fileDescriptor, offset: offset, length: stride * height) else {
            return
        }
        self.mapping = mapping

        onScanout?(
            VirtualMachineFrame(
                width: width,
                height: height,
                stride: stride,
                format: Self.frameFormat(pixman: format),
                pixels: mapping.pixels,
                length: mapping.length,
                owner: mapping
            )
        )
    }

    private func requests(for event: VirtualMachineInputEvent) -> [PointerRequest] {
        switch event {
        case .keyDown(let code):
            return [PointerRequest(Self.keyboardInterface, "Press", [.count(code)])]
        case .keyUp(let code):
            return [PointerRequest(Self.keyboardInterface, "Release", [.count(code)])]
        case .pointerMoved(let x, let y):
            return [
                PointerRequest(
                    Self.mouseInterface,
                    "SetAbsPosition",
                    [.count(UInt32(max(x, 0))), .count(UInt32(max(y, 0)))]
                )
            ]
        case .pointerMovedBy(let dx, let dy):
            return [PointerRequest(Self.mouseInterface, "RelMotion", [.offset(Int32(dx)), .offset(Int32(dy))])]
        case .pointerButtonDown(let button):
            return [PointerRequest(Self.mouseInterface, "Press", [.count(button.code)])]
        case .pointerButtonUp(let button):
            return [PointerRequest(Self.mouseInterface, "Release", [.count(button.code)])]
        case .scrolled(_, let deltaY):
            let wheel: UInt32 = (deltaY > 0) ? 3 : 4
            return [
                PointerRequest(Self.mouseInterface, "Press", [.count(wheel)]),
                PointerRequest(Self.mouseInterface, "Release", [.count(wheel)]),
            ]
        }
    }


    private static func frameFormat(pixman format: UInt32) -> VirtualMachineFrameFormat {
        let alphaWidth = (format >> 12) & 0xf
        return (alphaWidth == 0) ? .bgrx8888 : .bgra8888
    }

    private static let consolePath = "/org/qemu/Display1/Console_0"
    private static let listenerPath = "/org/qemu/Display1/Listener"
    private static let keyboardInterface = "org.qemu.Display1.Keyboard"
    private static let mouseInterface = "org.qemu.Display1.Mouse"
    private static let mapInterface = "org.qemu.Display1.Listener.Unix.Map"

    private static let interfaces = """
        <node>
          <interface name='org.qemu.Display1.Listener'>
            <method name='Scanout'>
              <arg type='u' name='width' direction='in'/>
              <arg type='u' name='height' direction='in'/>
              <arg type='u' name='stride' direction='in'/>
              <arg type='u' name='pixman_format' direction='in'/>
              <arg type='ay' name='data' direction='in'/>
            </method>
            <method name='Update'>
              <arg type='i' name='x' direction='in'/>
              <arg type='i' name='y' direction='in'/>
              <arg type='i' name='width' direction='in'/>
              <arg type='i' name='height' direction='in'/>
              <arg type='u' name='stride' direction='in'/>
              <arg type='u' name='pixman_format' direction='in'/>
              <arg type='ay' name='data' direction='in'/>
            </method>
            <method name='Disable'/>
            <method name='MouseSet'>
              <arg type='i' name='x' direction='in'/>
              <arg type='i' name='y' direction='in'/>
              <arg type='i' name='on' direction='in'/>
            </method>
            <property name='Interfaces' type='as' access='read'/>
            <property name='InterfaceVersion' type='u' access='read'/>
          </interface>
          <interface name='org.qemu.Display1.Listener.Unix.Map'>
            <method name='ScanoutMap'>
              <arg type='h' name='handle' direction='in'/>
              <arg type='u' name='offset' direction='in'/>
              <arg type='u' name='width' direction='in'/>
              <arg type='u' name='height' direction='in'/>
              <arg type='u' name='stride' direction='in'/>
              <arg type='u' name='pixman_format' direction='in'/>
            </method>
            <method name='UpdateMap'>
              <arg type='i' name='x' direction='in'/>
              <arg type='i' name='y' direction='in'/>
              <arg type='i' name='width' direction='in'/>
              <arg type='i' name='height' direction='in'/>
            </method>
            <property name='InterfaceVersion' type='u' access='read'/>
          </interface>
        </node>
        """
}

private struct PointerRequest: Sendable {
    let interface: String
    let method: String
    let arguments: [PointerArgument]

    init(_ interface: String, _ method: String, _ arguments: [PointerArgument]) {
        self.interface = interface
        self.method = method
        self.arguments = arguments
    }
}

private enum PointerArgument: Sendable {
    case count(UInt32)
    case offset(Int32)

    var variant: GLib.Variant {
        switch self {
        case .count(let value):
            return GLib.Variant(value)
        case .offset(let value):
            return GLib.Variant(value)
        }
    }
}

private final class QemuFrameMapping: VirtualMachineFrameStorage, @unchecked Sendable {
    let pixels: UnsafeRawPointer
    let length: Int

    private let base: UnsafeMutableRawPointer
    private let mappedLength: Int
    private let fileDescriptor: Int32

    init?(fileDescriptor: Int32, offset: Int, length: Int) {
        let mappedLength = offset + length
        guard let base = mmap(nil, mappedLength, PROT_READ, MAP_SHARED, fileDescriptor, 0),
            base != MAP_FAILED
        else {
            close(fileDescriptor)
            return nil
        }

        self.base = base
        self.mappedLength = mappedLength
        self.fileDescriptor = fileDescriptor
        self.pixels = UnsafeRawPointer(base.advanced(by: offset))
        self.length = length
    }

    deinit {
        munmap(base, mappedLength)
        close(fileDescriptor)
    }
}

extension VirtualMachinePointerButton {
    var code: UInt32 {
        switch self {
        case .left: return 0
        case .middle: return 1
        case .right: return 2
        }
    }
}

#endif
