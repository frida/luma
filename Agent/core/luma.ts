import "./console.js";
import * as env from "./env.js";
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
    ...env,
    ...instrument,
    ...memory,
    ...modules,
    ...patterns,
    ...pkg,
    ...repl,
    ...resolver,
    ...symbolicate,
    ...threads,
};