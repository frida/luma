import Foundation
import SwiftProtobuf

struct EmulatorControlClient: Sendable {
    private static let controller = "/android.emulation.control.EmulatorController"
    private static let snapshots = "/android.emulation.control.SnapshotService"

    private let connection: GRPCConnection

    init(connection: GRPCConnection) {
        self.connection = connection
    }

    func close() async {
        await connection.close()
    }

    func displayConfigurations() async throws -> Android_Emulation_Control_DisplayConfigurations {
        try await connection.unary("\(Self.controller)/getDisplayConfigurations", Google_Protobuf_Empty())
    }

    func notifications() -> AsyncThrowingStream<Android_Emulation_Control_Notification, any Error> {
        connection.serverStream("\(Self.controller)/streamNotification", Google_Protobuf_Empty())
    }

    func screenshots(
        format: Android_Emulation_Control_ImageFormat
    ) -> AsyncThrowingStream<Android_Emulation_Control_Image, any Error> {
        connection.serverStream("\(Self.controller)/streamScreenshot", format)
    }

    func sendMouse(_ event: Android_Emulation_Control_MouseEvent) async throws {
        let _: Google_Protobuf_Empty = try await connection.unary("\(Self.controller)/sendMouse", event)
    }

    enum SnapshotVerb: String {
        case save = "SaveSnapshot"
        case load = "LoadSnapshot"
        case delete = "DeleteSnapshot"
    }

    func runSnapshot(_ verb: SnapshotVerb, name: String) async throws {
        var package = Android_Emulation_Control_SnapshotPackage()
        package.snapshotID = name
        let reply: Android_Emulation_Control_SnapshotPackage =
            try await connection.unary("\(Self.snapshots)/\(verb.rawValue)", package)
        if !reply.success {
            let reason = String(data: reply.err, encoding: .utf8) ?? "the emulator refused the snapshot"
            throw VirtualMachineError.snapshotFailed(reason: reason)
        }
    }
}
