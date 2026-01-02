import Foundation
import SwiftyMonaco

struct TracerConfig: Codable, Equatable {
    struct Hook: Codable, Equatable, Identifiable {
        var id: UUID

        var displayName: String

        var addressAnchor: AddressAnchor

        var isEnabled: Bool

        var code: String

        var isPinned: Bool

        init(
            id: UUID = UUID(),
            displayName: String,
            addressAnchor: AddressAnchor,
            isEnabled: Bool = true,
            code: String,
            isPinned: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.addressAnchor = addressAnchor
            self.isEnabled = isEnabled
            self.code = code
            self.isPinned = isPinned
        }
    }

    var hooks: [Hook]

    init(hooks: [Hook] = []) {
        self.hooks = hooks
    }

    static func decode(from data: Data) throws -> TracerConfig {
        try JSONDecoder().decode(TracerConfig.self, from: data)
    }

    func encode() -> Data {
        try! JSONEncoder().encode(self)
    }

    func toJSON() -> JSONObject {
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

                return dict
            }
        ]
    }
}

enum TracerEditorProfile {
    static let typescript: MonacoEditorProfile = MonacoEditorProfileBuilder()
        .syntax(.monaco(languageId: "typescript"))
        .typescriptCompilerOptions(TypeScriptEnvironment.defaultCompilerOptions)
        .typescriptExtraLibs([
            TypeScriptEnvironment.gumTypeLib,
            .init(tracerDeclarations, filePath: "@types/frida-luma/tracer.d.ts"),
        ])
        .build()

    private static let tracerDeclarations = #"""
        declare function defineHandler(h: Handler): void;

        type Handler = FunctionHandlers | InstructionHandler;

        interface FunctionHandlers {
            onEnter?: EnterHandler;
            onLeave?: LeaveHandler;
        }

        type EnterHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
        type LeaveHandler = (this: InvocationContext, log: LogHandler, retval: InvocationReturnValue) => any;
        type InstructionHandler = (this: InvocationContext, log: LogHandler, args: InvocationArguments) => void;
        type LogHandler = (...args: any[]) => void;
        """#
}

let defaultTracerNativeStub = """
    defineHandler({
        onEnter(log, args) {
            log(`CALL(args[0]=${args[0]})`);
        },

        onLeave(log, retval) {
        }
    });
    """

let defaultTracerInstructionStub = """
    defineHandler(function (log, args) {
        log(`INSTRUCTION hit! sp=${this.context.sp}`);
    });
    """
