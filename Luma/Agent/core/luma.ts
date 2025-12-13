import "./console.js";
import * as instrument from "./instrument.js";
import * as memory from "./memory.js";
import * as pkg from "./pkg.js";
import * as repl from "./repl.js";
import * as resolver from "./resolver.js";

rpc.exports = {
    ...instrument,
    ...memory,
    ...pkg,
    ...repl,
    ...resolver,
};
