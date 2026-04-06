import Foundation

public struct TracerConfig: Codable, Equatable {
    public struct Hook: Codable, Equatable, Identifiable {
        public var id: UUID

        public var displayName: String

        public var addressAnchor: AddressAnchor

        public var isEnabled: Bool

        public var code: String

        public var isPinned: Bool

        public var itraceEnabled: Bool

        public init(
            id: UUID = UUID(),
            displayName: String,
            addressAnchor: AddressAnchor,
            isEnabled: Bool = true,
            code: String,
            isPinned: Bool = false,
            itraceEnabled: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.addressAnchor = addressAnchor
            self.isEnabled = isEnabled
            self.code = code
            self.isPinned = isPinned
            self.itraceEnabled = itraceEnabled
        }
    }

    public var hooks: [Hook]

    public init(hooks: [Hook] = []) {
        self.hooks = hooks
    }

    public static func decode(from data: Data) throws -> TracerConfig {
        try JSONDecoder().decode(TracerConfig.self, from: data)
    }

    public func encode() -> Data {
        try! JSONEncoder().encode(self)
    }

    public func toJSON() -> JSONObject {
        [
            "hooks": hooks.map { hook in
                var dict: JSONObject = [
                    "id": hook.id.uuidString,
                    "displayName": hook.displayName,
                    "addressAnchor": hook.addressAnchor.toJSON(),
                    "isEnabled": hook.isEnabled,
                    "code": hook.code,
                ]

                if hook.isPinned {
                    dict["isPinned"] = true
                }

                if hook.itraceEnabled {
                    dict["itraceEnabled"] = true
                }

                return dict
            }
        ]
    }
}

public let defaultTracerNativeStub = """
    defineHandler({
        onEnter(log, args) {
            log(`CALL(args[0]=${args[0]})`);
        },

        onLeave(log, retval) {
        }
    });
    """

public let defaultTracerInstructionStub = """
    defineHandler(function (log, args) {
        log(`INSTRUCTION hit! sp=${this.context.sp}`);
    });
    """
