export function symbolicate(addresses: string[]): (
  | null
  | [string, string]
  | [string, string, string, number]
  | [string, string, string, number, number]
)[] {
    return addresses.map(address => {
        const sym = DebugSymbol.fromAddress(ptr(address));

        const name = sym.name;
        if (name === null) {
            return null;
        }

        const { moduleName, fileName, lineNumber, column } = sym as any;

        if (lineNumber === 0) {
            return [moduleName, name];
        }

        if (column === 0) {
            return [moduleName, name, fileName, lineNumber];
        }

        return [moduleName, name, fileName, lineNumber, column];
    });
}
