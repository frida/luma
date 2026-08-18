import Foundation
import GRDB

public struct VirtualMachineRecord: Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "virtual_machine"

    public var id: UUID
    public var name: String
    public var templateID: String
    public var parametersJSON: String
    public var agentPath: String?
    public var hasReadySnapshot: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        templateID: String,
        parameters: [String: VirtualMachineParameterValue],
        agentPath: String? = nil,
        hasReadySnapshot: Bool = false
    ) {
        self.id = id
        self.name = name
        self.templateID = templateID
        self.parametersJSON = Self.encode(parameters)
        self.agentPath = agentPath
        self.hasReadySnapshot = hasReadySnapshot
    }

    public var parameters: [String: VirtualMachineParameterValue] {
        get { Self.decode(parametersJSON) }
        set { parametersJSON = Self.encode(newValue) }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case templateID = "template_id"
        case parametersJSON = "parameters_json"
        case agentPath = "agent_path"
        case hasReadySnapshot = "has_ready_snapshot"
    }

    private static func encode(_ parameters: [String: VirtualMachineParameterValue]) -> String {
        guard let data = try? JSONEncoder().encode(parameters) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ json: String) -> [String: VirtualMachineParameterValue] {
        guard let values = try? JSONDecoder().decode([String: VirtualMachineParameterValue].self, from: Data(json.utf8))
        else {
            return [:]
        }
        return values
    }
}
