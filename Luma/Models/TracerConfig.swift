import Foundation
import SwiftyMonaco

struct TracerConfig: Codable, Equatable {
    struct Hook: Codable, Equatable, Identifiable {
        var id: UUID

        var displayName: String

        var moduleName: String?
        var symbolName: String?

        var isEnabled: Bool

        var code: String

        var isPinned: Bool

        init(
            id: UUID = UUID(),
            displayName: String,
            moduleName: String?,
            symbolName: String?,
            isEnabled: Bool = true,
            code: String,
            isPinned: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.moduleName = moduleName
            self.symbolName = symbolName
            self.isEnabled = isEnabled
            self.code = code
            self.isPinned = isPinned
        }
    }

    var hooks: [Hook]

    init(hooks: [Hook] = []) {
        self.hooks = hooks
    }

    func toJSON() -> JSONObject {
        [
            "hooks": hooks.map { hook in
                var dict: JSONObject = [
                    "id": hook.id.uuidString,
                    "displayName": hook.displayName,
                    "isEnabled": hook.isEnabled,
                    "code": hook.code,
                ]

                if let module = hook.moduleName {
                    dict["moduleName"] = module
                }
                if let symbol = hook.symbolName {
                    dict["symbolName"] = symbol
                }
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
        declare function defineHandler(handler: TraceHandler): TraceHandler;
        declare function log(...args: any[]): void;

        interface TraceHandler {
            onEnter?(this: InvocationContext, args: InvocationArguments): void;
            onLeave?(this: InvocationContext, retval: InvocationReturnValue): void;
        }
        """#
}

let defaultTracerStub = """
    defineHandler({
      onEnter(args) {
        log(`CALL(args[0]=${args[0]})`);
      },

      onLeave(retval) {
      }
    });
    """
