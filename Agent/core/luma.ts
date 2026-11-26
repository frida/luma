import "./console.js";
import * as env from "./env.js";
import * as fs from "./fs.js";
import * as instrument from "./instrument.js";
import * as memory from "./memory.js";
import * as modules from "./modules.js";
import * as patterns from "./patterns.js";
import * as pkg from "./pkg.js";
import * as repl from "./repl.js";
import * as resolver from "./resolver.js";
import * as symbolicate from "./symbolicate.js";
import * as threads from "./threads.js";

rpc.exports = {
    getProcessInfo: env.getProcessInfo,

    getFilesystemRoots: fs.getFilesystemRoots,
    listDirectory: fs.listDirectory,
    walkTree: fs.walkTree,
    makeDirectory: fs.makeDirectory,
    removePath: fs.removePath,
    pullFile: fs.pullFile,
    cancelPull: fs.cancelPull,
    pushFile: fs.pushFile,

    loadInstrument: instrument.loadInstrument,
    updateInstrumentConfig: instrument.updateInstrumentConfig,
    disposeInstrument: instrument.disposeInstrument,
    invokeWidgetAction: instrument.invokeWidgetAction,
    submitConsoleInput: instrument.submitConsoleInput,

    readMemory: memory.readMemory,
    writeMemory: memory.writeMemory,

    enumerateModuleRanges: modules.enumerateModuleRanges,
    findRangeByAddress: modules.findRangeByAddress,
    getModuleIdentity: modules.getModuleIdentity,
    enumerateModuleFunctions: modules.enumerateModuleFunctions,
    enumerateModuleSymbols: modules.enumerateModuleSymbols,
    queryModuleSymbols: modules.queryModuleSymbols,
    outlineModule: modules.outlineModule,
    describeSwiftType: modules.describeSwiftType,

    installPatternGlobals: patterns.installPatternGlobals,

    loadPackages: pkg.loadPackages,

    evaluate: repl.evaluate,
    complete: repl.complete,

    resolveTargets: resolver.resolveTargets,
    lookupAnchorAddress: resolver.lookupAnchorAddress,

    symbolicate: symbolicate.symbolicate,

    getThreadSnapshot: threads.getThreadSnapshot,
};
