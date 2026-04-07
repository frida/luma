import LumaCore
import SwiftyMonaco

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
