import "./console.js";
import * as instrument from "./instrument.js";
import * as pkg from "./pkg.js";
import * as repl from "./repl.js";
import * as resolver from "./resolver.js";

rpc.exports = {
    ...instrument,
    ...pkg,
    ...repl,
    ...resolver,
};
