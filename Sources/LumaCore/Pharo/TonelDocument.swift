import SwiftyPharo

/// A run of a Tonel file the image colors, in the file's own UTF-16 offsets;
/// each color is RRGGBB hex, one for the light theme and one for the dark.
public struct TonelStyleSpan: Equatable, Sendable {
    public let utf16Range: Range<Int>
    public let lightHex: String?
    public let darkHex: String?
    public let bold: Bool

    public func shifted(by delta: Int) -> TonelStyleSpan {
        TonelStyleSpan(
            utf16Range: (utf16Range.lowerBound + delta)..<(utf16Range.upperBound + delta),
            lightHex: lightHex,
            darkHex: darkHex,
            bold: bold)
    }
}

/// An instrument's Tonel file open in an editor, colored and completed by the
/// image the way the playground's Smalltalk is. The instrument's own classes
/// live in an environment of their own, which the image's completion does not
/// look in, so what the instrument's files define is offered beside it.
@MainActor
public final class TonelDocument {
    public var onStyleSpans: (([TonelStyleSpan]) -> Void)?

    private let runtime: PharoRuntime
    private let siblings: [TonelSource]
    private var text = ""
    private var styling: Task<Void, Never>?
    private var isStyleStale = false
    private var styled: [StyleRequest: [PharoStyleSpan]] = [:]

    public init(siblings: [String], runtime: PharoRuntime = .shared) {
        self.siblings = siblings.map(TonelSource.init)
        self.runtime = runtime
    }

    /// Styles the text once the image answers, and afresh whenever it has moved
    /// on by the time it did, so edits made while the image was busy or still
    /// starting are coalesced into one more pass.
    public func replaceText(_ newText: String) {
        text = newText
        guard styling == nil else {
            isStyleStale = true
            return
        }
        styling = Task { [weak self] in await self?.styleUntilCurrent() }
    }

    public func close() {
        styling?.cancel()
        onStyleSpans = nil
    }

    public func completions(in text: String, atUTF16 caret: Int) async -> [String] {
        let source = TonelSource(text)
        guard let method = source.method(enclosingUTF16: caret) else { return [] }
        let methodSource = source.methodSource(of: method)
        let position = ScalarOffsets(methodSource).scalarOffset(ofUTF16: caret - method.source.lowerBound)
        let fromImage = try? await whenRunning {
            try await runtime.completions(for: String(utf16CodeUnits: methodSource, count: methodSource.count), at: position)
        }
        let own = ownCompletions(at: caret, in: source, within: method)
        var seen: Set<String> = []
        return (own + (fromImage?.completions ?? [])).filter { seen.insert($0).inserted }
    }

    private func styleUntilCurrent() async {
        defer { styling = nil }
        repeat {
            isStyleStale = false
            let styledText = text
            guard let spans = await styleSpans(of: TonelSource(styledText)), !Task.isCancelled else { return }
            if styledText == text {
                onStyleSpans?(spans)
            }
        } while isStyleStale && !Task.isCancelled
    }

    private func styleSpans(of source: TonelSource) async -> [TonelStyleSpan]? {
        guard (try? await runtime.runningState()) != nil else { return nil }
        let parts = [StylePart(base: 0, units: source.frameExpression, isMethod: false)]
            + source.methods.map { StylePart(base: $0.source.lowerBound, units: source.methodSource(of: $0), isMethod: true) }
        var answered: [StyleRequest: [PharoStyleSpan]] = [:]
        var spans: [TonelStyleSpan] = []
        for part in parts {
            let request = StyleRequest(source: String(utf16CodeUnits: part.units, count: part.units.count), isMethod: part.isMethod)
            let found: [PharoStyleSpan]
            if let known = answered[request] ?? styled[request] {
                found = known
            } else {
                found = (try? await runtime.styleSpans(in: request.source, isMethod: request.isMethod)) ?? []
            }
            answered[request] = found
            spans += part.place(found)
        }
        styled = answered
        return spans
    }

    private func ownCompletions(at caret: Int, in source: TonelSource, within method: TonelMethod) -> [String] {
        let units = source.units
        var start = caret
        while start > method.source.lowerBound, isWordUnit(units[start - 1]) { start -= 1 }
        let prefix = String(utf16CodeUnits: Array(units[start..<caret]), count: caret - start)
        let outlines = [source] + siblings
        var names: [String]
        if followsReceiver(at: start, in: units, within: method) {
            names = outlines.flatMap { $0.methods.map(\.selector) }
        } else if prefix.first?.isUppercase == true {
            names = outlines.flatMap { $0.classes.flatMap { [$0.name] + $0.classVariables } }
        } else {
            names = outlines.flatMap(\.classes).filter { $0.name == method.className }.flatMap { $0.variables(on: method.side) }
        }
        names = names.filter { !$0.isEmpty && $0.hasPrefix(prefix) }
        return Array(Set(names)).sorted()
    }

    /// A word that follows a name, a literal or a closing bracket is a message
    /// sent to it; one that follows a keyword, an operator or an opening
    /// bracket names a variable.
    private func followsReceiver(at start: Int, in units: [UTF16.CodeUnit], within method: TonelMethod) -> Bool {
        var index = start
        while index > method.source.lowerBound, isSpace(units[index - 1]) { index -= 1 }
        guard index > method.source.lowerBound else { return false }
        let previous = units[index - 1]
        return isWordUnit(previous) || previous == 0x29 || previous == 0x5D || previous == 0x7D || previous == 0x27
    }

    private func whenRunning<Answer>(_ request: () async throws -> Answer) async throws -> Answer {
        try await runtime.runningState()
        return try await request()
    }

    private func isWordUnit(_ unit: UTF16.CodeUnit) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
    }

    private func isSpace(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

private struct StyleRequest: Hashable {
    let source: String
    let isMethod: Bool
}

private struct StylePart {
    let base: Int
    let units: [UTF16.CodeUnit]
    let isMethod: Bool

    /// The image counts characters from one, and its stop is inclusive.
    func place(_ spans: [PharoStyleSpan]) -> [TonelStyleSpan] {
        let offsets = ScalarOffsets(units)
        return spans.compactMap { span in
            let lower = offsets.utf16Offset(ofScalar: span.start - 1)
            let upper = offsets.utf16Offset(ofScalar: span.stop)
            guard lower < upper else { return nil }
            return TonelStyleSpan(utf16Range: (base + lower)..<(base + upper), lightHex: span.light, darkHex: span.dark, bold: span.bold)
        }
    }
}

/// The image counts a string in characters, which a character outside the
/// Basic Multilingual Plane makes fewer than its UTF-16 units.
private struct ScalarOffsets {
    private let utf16Offsets: [Int]

    init(_ units: [UTF16.CodeUnit]) {
        utf16Offsets = units.indices.filter { !UTF16.isTrailSurrogate(units[$0]) } + [units.count]
    }

    func utf16Offset(ofScalar scalar: Int) -> Int {
        utf16Offsets[max(0, min(scalar, utf16Offsets.count - 1))]
    }

    func scalarOffset(ofUTF16 offset: Int) -> Int {
        utf16Offsets.firstIndex { $0 >= offset } ?? utf16Offsets.count - 1
    }
}
