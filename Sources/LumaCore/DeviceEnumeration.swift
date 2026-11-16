import Frida

extension Device {
    public func enumerateProcessesWithIcons() async throws -> [ProcessDetails] {
        do {
            return try await enumerateProcesses(scope: .full)
        } catch {
            return try await enumerateProcesses(scope: .metadata)
        }
    }

    public func enumerateApplicationsWithIcons() async throws -> [ApplicationDetails] {
        do {
            return try await enumerateApplications(scope: .full)
        } catch {
            return try await enumerateApplications(scope: .metadata)
        }
    }
}
