import Frida

public struct ApplicationDebuggability: Sendable {
    private let debuggableIdentifiers: Set<String>

    public init(applications: [ApplicationDetails]) {
        debuggableIdentifiers = Set(applications.filter(Self.declaresDebuggable).map(\.identifier))
    }

    public func isDebuggable(_ application: ApplicationDetails) -> Bool {
        Self.declaresDebuggable(application)
    }

    public func isDebuggable(_ process: ProcessDetails) -> Bool {
        let applications = process.parameters["applications"] as? [String] ?? []
        return applications.contains(where: debuggableIdentifiers.contains)
    }

    public func debuggableFirst(_ processes: [ProcessDetails]) -> [ProcessDetails] {
        processes.filter { isDebuggable($0) } + processes.filter { !isDebuggable($0) }
    }

    private static func declaresDebuggable(_ application: ApplicationDetails) -> Bool {
        application.parameters["debuggable"] as? Bool == true
    }
}
