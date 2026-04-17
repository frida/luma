import Foundation

public struct TracerConfig: Codable, Equatable, Sendable {
    public struct Hook: Codable, Equatable, Identifiable, Sendable {
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

public enum TracerHookKind: Sendable {
    case instruction
    case function
}

extension TracerConfig.Hook {
    public var kind: TracerHookKind {
        (code.contains("onEnter") || code.contains("onLeave")) ? .function : .instruction
    }
}

public func defaultTracerCode(kind: TracerHookKind, anchor: AddressAnchor, displayName: String) -> String {
    switch kind {
    case .instruction:
        return instructionStub(displayName: displayName)
    case .function:
        switch anchor {
        case .objcMethod:
            return objcMethodStub(displayName: displayName)
        case .swiftFunc:
            return swiftFuncStub(displayName: displayName)
        case .javaMethod:
            return javaMethodStub(displayName: displayName)
        case .absolute, .moduleOffset, .moduleExport, .debugSymbol:
            return nativeFunctionStub(displayName: displayName)
        }
    }
}

private func nativeFunctionStub(displayName: String) -> String {
    return """
        defineHandler({
            onEnter(log, args) {
                log(`\(displayName)(args[0]=${args[0]})`);
            },

            onLeave(log, retval) {
            }
        });
        """
}

private func instructionStub(displayName: String) -> String {
    return """
        defineHandler(function (log, args) {
            log(`\(displayName) hit! sp=${this.context.sp}`);
        });
        """
}

private func objcMethodStub(displayName: String) -> String {
    return """
        defineHandler({
            onEnter(log, args) {
                log(`\(objcLogPattern(selector: displayName))`);
            },

            onLeave(log, retval) {
            }
        });
        """
}

private func swiftFuncStub(displayName: String) -> String {
    return """
        defineHandler({
            onEnter(log, args) {
                log(`\(displayName)`);
            },

            onLeave(log, retval) {
            }
        });
        """
}

private func javaMethodStub(displayName: String) -> String {
    return """
        defineHandler({
            onEnter(log, args) {
                log(`\(displayName)(${args.map(JSON.stringify).join(', ')})`);
            },

            onLeave(log, retval) {
                if (retval !== undefined) {
                    log(`<= ${JSON.stringify(retval)}`);
                }
            }
        });
        """
}

private func objcLogPattern(selector: String) -> String {
    var argIndex = 2
    var result = ""
    for character in selector {
        if character == ":" {
            result += ":${args[\(argIndex)]} "
            argIndex += 1
        } else {
            result.append(character)
        }
    }
    if result.hasSuffix(" ]") {
        result.removeLast(2)
        result += "]"
    }
    return result
}
