import Foundation

@MainActor
final class PatternGlobals {
    private var compiled: [String: CompiledPattern] = [:]
    private var failedTexts: [String: String] = [:]
    private var libraryTexts: [String: String] = [:]
    private var generation = 0
    private let operations = PackageOperationQueue()

    var all: [CompiledPattern] {
        Array(compiled.values)
    }

    func source(ofGlobal global: String) -> String? {
        compiled.values.first { $0.global == global }?.sourceName
    }

    func refresh(from sources: [PatternSource], build: @escaping @MainActor (PatternSource) async throws -> String) async -> Update {
        var update = Update()
        try? await operations.enqueue { [self] in
            update = await performRefresh(from: sources, build: build)
        }
        return update
    }

    private func performRefresh(from sources: [PatternSource], build: (PatternSource) async throws -> String) async -> Update {
        var update = Update()

        var wanted: [String: PatternSource] = [:]
        var sourceIDsByGlobal: [String: String] = [:]
        for source in sources where source.kind == .pattern {
            let global = Self.globalName(for: source.name)
            if let claimant = sourceIDsByGlobal[global] {
                recordFailure(of: source, PatternGlobalError.sharesGlobal(global, with: claimant), in: &update)
                continue
            }
            sourceIDsByGlobal[global] = source.id
            wanted[source.id] = source
        }

        for (id, stale) in compiled where wanted[id] == nil {
            compiled[id] = nil
            update.removed.append(stale.global)
        }
        failedTexts = failedTexts.filter { id, text in sources.contains { $0.id == id && $0.text == text } }

        let currentLibraryTexts = Dictionary(uniqueKeysWithValues: sources.filter { $0.kind == .library }.map { ($0.id, $0.text) })
        let librariesChanged = currentLibraryTexts != libraryTexts
        if librariesChanged {
            libraryTexts = currentLibraryTexts
            failedTexts.removeAll()
        }

        for source in wanted.values
        where librariesChanged || (compiled[source.id]?.text != source.text && failedTexts[source.id] != source.text) {
            do {
                let bundle = try await build(source)
                generation += 1
                let global = Self.globalName(for: source.name)
                let pattern = CompiledPattern(
                    sourceName: source.name, text: source.text, global: global, module: "/patterns/\(generation)/\(global).js",
                    bundle: bundle)
                compiled[source.id] = pattern
                update.installed.append(pattern)
            } catch {
                recordFailure(of: source, error, in: &update)
            }
        }

        return update
    }

    private func recordFailure(of source: PatternSource, _ error: Error, in update: inout Update) {
        guard failedTexts[source.id] != source.text else { return }
        failedTexts[source.id] = source.text
        update.failures.append((source, error))
    }

    static func globalName(for sourceName: String) -> String {
        let identifier = String(sourceName.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" ? $0 : "_" })
        return identifier.first?.isNumber == false ? identifier : "_" + identifier
    }

    struct CompiledPattern {
        let sourceName: String
        let text: String
        let global: String
        let module: String
        let bundle: String

        var agentEntry: [String: Any] {
            ["global": global, "name": module, "bundle": bundle]
        }
    }

    struct Update {
        var installed: [CompiledPattern] = []
        var removed: [String] = []
        var failures: [(source: PatternSource, error: Error)] = []
    }
}

enum PatternGlobalError: LocalizedError {
    case sharesGlobal(String, with: String)
    case wouldReplace(String)

    var errorDescription: String? {
        switch self {
        case .sharesGlobal(let global, let claimant):
            return "\(claimant) is already the REPL's \(global)."
        case .wouldReplace(let global):
            return "The process already has a global named \(global)."
        }
    }
}
