import { encodeValue } from "./value.js";

export function evaluate(
    code: string,
    { raw }: { raw: boolean }
): any {
    try {
        // eslint-disable-next-line no-eval
        const result = eval(code);

        if (raw) {
            return result;
        }

        return encodeValue(result);
    } catch (e) {
        return encodeValue(e);
    }
}

export function complete(
    code: string,
    cursor: number
): string[] {
    const context = getContextAtCursor(code, cursor);
    const baseExpr = context.baseExpr;
    const fragment = context.fragment;

    let candidates: string[] = [];

    if (baseExpr !== null) {
        const base = resolveBase(baseExpr);

        if (base !== null) {
            try {
                candidates = Object.getOwnPropertyNames(base as object).map(String);
            } catch {
                candidates = [];
            }
        }

        if (candidates.length === 0) {
            try {
                candidates = Object.getOwnPropertyNames(globalThis as any).map(String);
            } catch {
                candidates = [];
            }
        }
    } else {
        try {
            candidates = Object.getOwnPropertyNames(globalThis as any).map(String);
        } catch {
            candidates = [];
        }
    }

    if (baseExpr === null && fragment === "") {
        return [];
    }

    const uniq = Array.from(new Set(candidates));

    let filtered = uniq;

    if (fragment !== "") {
        filtered = uniq.filter(name => name.startsWith(fragment));
    }

    return filtered.slice(0, 256);
}

interface CompletionContext {
    baseExpr: string | null;
    fragment: string;
}

function getContextAtCursor(code: string, cursor: number): CompletionContext {
    const before = code.slice(0, cursor);

    let i = before.length - 1;
    while (i >= 0) {
        const ch = before[i];
        if (!/[A-Za-z0-9_$\\.]/.test(ch)) {
            break;
        }
        i -= 1;
    }

    const token = before.slice(i + 1);
    if (token === "") {
        return { baseExpr: null, fragment: "" };
    }

    const dotIndex = token.lastIndexOf(".");

    if (dotIndex === -1) {
        return {
            baseExpr: null,
            fragment: token
        };
    }

    const baseExpr = token.slice(0, dotIndex);
    const fragment = token.slice(dotIndex + 1);

    return {
        baseExpr,
        fragment
    };
}

function resolveBase(baseExpr: string | null): unknown {
    if (baseExpr === null) {
        return null;
    }

    try {
        // eslint-disable-next-line no-eval
        const base = eval(baseExpr);
        if (base === null || base === undefined) {
            return null;
        }
        return base;
    } catch {
        return null;
    }
}
