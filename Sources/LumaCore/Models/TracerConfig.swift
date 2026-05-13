import Foundation

public enum TracerHookKind: String, Codable, Sendable {
    case instruction
    case function
}

public struct ITraceArming: Codable, Equatable, Sendable {
    public static let defaultMaxInvocations: Int = 5
    public static let defaultMaxBytesPerInvocation: Int = 1_000_000

    public var maxInvocations: Int
    public var maxBytesPerInvocation: Int

    public init(
        maxInvocations: Int = ITraceArming.defaultMaxInvocations,
        maxBytesPerInvocation: Int = ITraceArming.defaultMaxBytesPerInvocation
    ) {
        self.maxInvocations = maxInvocations
        self.maxBytesPerInvocation = maxBytesPerInvocation
    }
}

public struct TracerConfig: Codable, Equatable, Sendable {
    public struct Hook: Codable, Equatable, Identifiable, Sendable {
        public enum State: String, Codable, Sendable, Equatable {
            case enabled
            case disabled
        }

        public var id: UUID

        public var displayName: String

        public var addressAnchor: AddressAnchor

        public var kind: TracerHookKind

        public var state: State

        public var code: String

        public var itraceArming: ITraceArming?

        public var lastEditedAt: Date?

        public init(
            id: UUID = UUID(),
            displayName: String,
            addressAnchor: AddressAnchor,
            kind: TracerHookKind,
            state: State = .enabled,
            code: String,
            itraceArming: ITraceArming? = nil,
            lastEditedAt: Date? = .now
        ) {
            self.id = id
            self.displayName = displayName
            self.addressAnchor = addressAnchor
            self.kind = kind
            self.state = state
            self.code = code
            self.itraceArming = itraceArming
            self.lastEditedAt = lastEditedAt
        }

        public mutating func updateCode(_ newCode: String, at date: Date = .now) {
            code = newCode
            lastEditedAt = date
        }
    }

    public var hooks: [Hook]

    public init(hooks: [Hook] = []) {
        self.hooks = hooks
    }

    public func hooksByMostRecentlyEdited() -> [Hook] {
        return hooks.enumerated()
            .map { (originalIndex: $0.offset, hook: $0.element) }
            .sorted(by: hookRecencyComesFirst)
            .map(\.hook)
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
                    "kind": hook.kind.rawValue,
                    "state": hook.state.rawValue,
                    "code": hook.code,
                ]

                if let arming = hook.itraceArming {
                    dict["itraceArming"] = [
                        "maxInvocations": arming.maxInvocations,
                        "maxBytesPerInvocation": arming.maxBytesPerInvocation,
                    ] as JSONObject
                }

                return dict
            }
        ]
    }
}

private func hookRecencyComesFirst(
    _ lhs: (originalIndex: Int, hook: TracerConfig.Hook),
    _ rhs: (originalIndex: Int, hook: TracerConfig.Hook)
) -> Bool {
    if let l = lhs.hook.lastEditedAt, let r = rhs.hook.lastEditedAt, l != r {
        return l > r
    }
    let lhsHasTimestamp = lhs.hook.lastEditedAt != nil
    let rhsHasTimestamp = rhs.hook.lastEditedAt != nil
    if lhsHasTimestamp != rhsHasTimestamp {
        return lhsHasTimestamp
    }
    let nameComparison = lhs.hook.displayName.localizedCaseInsensitiveCompare(rhs.hook.displayName)
    if nameComparison != .orderedSame {
        return nameComparison == .orderedAscending
    }
    return lhs.originalIndex < rhs.originalIndex
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
