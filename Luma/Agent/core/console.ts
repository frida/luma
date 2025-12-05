import { encodeValues } from "./value.js";

type ConsoleLevel = "info" | "debug" | "warning" | "error";

const proto = Object.getPrototypeOf(console);
proto.info = (...args: unknown[]) => { emitLogMessage("info", args); };
proto.log = (...args: unknown[]) => { emitLogMessage("info", args); };
proto.debug = (...args: unknown[]) => { emitLogMessage("debug", args); };
proto.warn = (...args: unknown[]) => { emitLogMessage("warning", args); };
proto.error = (...args: unknown[]) => { emitLogMessage("error", args); };

function emitLogMessage(level: ConsoleLevel, args: unknown[]) {
    const [trees, blob] = encodeValues(args);
    send({ type: "console", level, args: trees }, blob);
}
